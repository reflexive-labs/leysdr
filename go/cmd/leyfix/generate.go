// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

const genBlock = 1 << 16

// genOptions controls fixture generation.
type genOptions struct {
	out      string
	rate     float64
	duration float64
	seed     uint64
	only     []string
	// set picks the catalog set when only is empty: "" for the default fixtures, "scenes" for
	// the site's screenshot scenes. only names fixtures from any set.
	set string
	// dryRun prints each selected fixture's file name and sidecar as one JSON line instead of
	// writing anything, so a caller can tell whether a copy it already has is current.
	dryRun bool
}

func runGenerate(args []string, w io.Writer) error {
	fs := flag.NewFlagSet("generate", flag.ContinueOnError)
	var o genOptions
	var only string
	fs.StringVar(&o.out, "out", "", "output directory (required)")
	fs.Float64Var(&o.rate, "rate", refRate, "sample rate in Hz")
	fs.Float64Var(&o.duration, "duration", 1, "duration in seconds")
	fs.Uint64Var(&o.seed, "seed", 1, "noise seed")
	fs.StringVar(&only, "only", "", "comma-separated fixture names to generate")
	fs.StringVar(&o.set, "set", "", "catalog set to generate when --only is not given: scenes for the site's screenshot scenes (default: the fixtures make fixtures writes)")
	fs.BoolVar(&o.dryRun, "dry-run", false, "print each fixture's file name and sidecar as a JSON line and write nothing")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if o.out == "" {
		return errors.New("generate: --out is required")
	}
	if only != "" {
		o.only = strings.Split(only, ",")
	}
	return generate(o, w)
}

// generate writes every selected catalog fixture into o.out.
func generate(o genOptions, w io.Writer) error {
	if o.rate <= 0 || o.duration <= 0 {
		return errors.New("generate: rate and duration must be positive")
	}
	if o.set != "" && o.set != "scenes" {
		return fmt.Errorf("generate: unknown set %q; the sets are the default and scenes", o.set)
	}
	if !o.dryRun {
		if err := os.MkdirAll(o.out, 0o755); err != nil {
			return err
		}
	}
	selected := map[string]bool{}
	for _, n := range o.only {
		selected[strings.TrimSpace(n)] = true
	}
	for name := range selected {
		if findFixture(name) == nil {
			return fmt.Errorf("generate: unknown fixture %q", name)
		}
	}
	for i := range catalog {
		f := &catalog[i]
		if len(selected) > 0 && !selected[f.name] || len(selected) == 0 && f.set != o.set {
			continue
		}
		rate := f.rateFor(o.rate)
		if f.minDurationS > 0 && f.fixedDurationS == 0 && o.duration < f.minDurationS {
			if selected[f.name] {
				return fmt.Errorf("generate: %s needs at least %.0f s, not %g", f.name, f.minDurationS, o.duration)
			}
			fmt.Fprintf(w, "skip %s: needs at least %.0f s\n", f.name, f.minDurationS)
			continue
		}
		if !f.fits(rate) {
			if selected[f.name] {
				return fmt.Errorf("generate: %s does not fit in %.0f Hz", f.name, rate)
			}
			fmt.Fprintf(w, "skip %s: does not fit in %.0f Hz\n", f.name, rate)
			continue
		}
		path := filepath.Join(o.out, f.name+"."+f.sampleFormat())
		if o.dryRun {
			sc, err := planSidecar(f, o)
			if err != nil {
				return fmt.Errorf("generate %s: %w", f.name, err)
			}
			line, err := json.Marshal(map[string]any{"name": f.name, "file": filepath.Base(path), "sidecar": sc})
			if err != nil {
				return err
			}
			fmt.Fprintf(w, "%s\n", line)
			continue
		}
		if err := generateOne(f, o, path); err != nil {
			return fmt.Errorf("generate %s: %w", f.name, err)
		}
		fmt.Fprintf(w, "wrote %s\n", path)
	}
	return nil
}

func findFixture(name string) *fixture {
	for i := range catalog {
		if catalog[i].name == name {
			return &catalog[i]
		}
	}
	return nil
}

// durationFor is the length the fixture is generated at under o.
func (f *fixture) durationFor(o genOptions) float64 {
	if f.fixedDurationS > 0 {
		return f.fixedDurationS
	}
	return o.duration
}

// planSidecar is the sidecar generateOne writes for f under o, everything but the samples:
// the generator record names every parameter of every source, so two runs that would write
// the same file produce the same sidecar.
func planSidecar(f *fixture, o genOptions) (*iqfile.Sidecar, error) {
	rate := f.rateFor(o.rate)
	total := int64(rate*f.durationFor(o) + 0.5)
	sources := f.build(rate)
	descs := make([]map[string]any, 0, len(sources))
	for _, s := range sources {
		descs = append(descs, s.describe())
	}
	gen, err := json.Marshal(map[string]any{
		"tool": "leyfix", "version": version, "seed": o.seed,
		"signals": descs, "noise_dbfs": f.noise(),
	})
	if err != nil {
		return nil, err
	}
	return &iqfile.Sidecar{
		Format: f.sampleFormat(), SampleRate: rate, CenterHz: f.centerHz, Samples: total,
		Description: f.description, Generator: gen, Expect: f.expect(rate), Metadata: f.metadata,
		Label: f.label,
	}, nil
}

// generateOne streams a single fixture (samples + sidecar) to path.
func generateOne(f *fixture, o genOptions, path string) error {
	sc, err := planSidecar(f, o)
	if err != nil {
		return err
	}
	sources := f.build(sc.SampleRate)
	noise := newNoiseAt(o.seed, f.noise())
	wr, err := iqfile.NewFormatWriter(path, sc.Format)
	if err != nil {
		return err
	}
	buf := make([]complex128, genBlock)
	for n0 := int64(0); n0 < sc.Samples; n0 += genBlock {
		blk := buf[:min(genBlock, int(sc.Samples-n0))]
		clear(blk)
		noise.fill(blk, n0)
		for _, s := range sources {
			s.fill(blk, n0)
		}
		if err := wr.WriteComplex128(blk); err != nil {
			_ = wr.Close() // cleanup after a failed write
			return err
		}
	}
	if err := wr.Close(); err != nil {
		return err
	}
	return iqfile.WriteSidecar(path, sc)
}
