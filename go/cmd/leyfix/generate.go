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

	"github.com/dpup/leysdr/go/pkg/iqfile"
)

const genBlock = 1 << 16

// genOptions controls fixture generation.
type genOptions struct {
	out      string
	rate     float64
	duration float64
	seed     uint64
	only     []string
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
	if err := os.MkdirAll(o.out, 0o755); err != nil {
		return err
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
		if len(selected) > 0 && !selected[f.name] {
			continue
		}
		if f.minDurationS > 0 && o.duration < f.minDurationS {
			if selected[f.name] {
				return fmt.Errorf("generate: %s needs at least %.0f s, not %g", f.name, f.minDurationS, o.duration)
			}
			fmt.Fprintf(w, "skip %s: needs at least %.0f s\n", f.name, f.minDurationS)
			continue
		}
		if !f.fits(o.rate) {
			if selected[f.name] {
				return fmt.Errorf("generate: %s does not fit in %.0f Hz", f.name, o.rate)
			}
			fmt.Fprintf(w, "skip %s: does not fit in %.0f Hz\n", f.name, o.rate)
			continue
		}
		path := filepath.Join(o.out, f.name+".cf32")
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

// generateOne streams a single fixture (samples + sidecar) to path.
func generateOne(f *fixture, o genOptions, path string) error {
	total := int64(o.rate*o.duration + 0.5)
	sources := f.build(o.rate)
	noise := newNoise(o.seed)
	wr, err := iqfile.NewWriter(path)
	if err != nil {
		return err
	}
	buf := make([]complex128, genBlock)
	for n0 := int64(0); n0 < total; n0 += genBlock {
		blk := buf[:min(genBlock, int(total-n0))]
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
	descs := make([]map[string]any, 0, len(sources))
	for _, s := range sources {
		descs = append(descs, s.describe())
	}
	gen, err := json.Marshal(map[string]any{
		"tool": "leyfix", "version": version, "seed": o.seed,
		"signals": descs, "noise_dbfs": noiseDBFS,
	})
	if err != nil {
		return err
	}
	sc := &iqfile.Sidecar{
		Format: iqfile.FormatCF32, SampleRate: o.rate, CenterHz: f.centerHz, Samples: total,
		Description: f.description, Generator: gen, Expect: f.expect(o.rate), Metadata: f.metadata,
	}
	return iqfile.WriteSidecar(path, sc)
}
