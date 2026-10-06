// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
)

// Manifest is shots.json (docs/plans/site-shots.md, "shots.json"): one entry per image.
type Manifest struct {
	Shots []Shot `json:"shots"`
}

// Shot is one image's entry.
type Shot struct {
	Asset  string `json:"asset"`
	Width  int    `json:"width"`
	Height int    `json:"height"`
	Scale  int    `json:"scale"`
	Alt    string `json:"alt"`
	Scene  string `json:"scene"`
	// Fixtures are the generator records of the fixtures the scene played, by fixture name.
	Fixtures map[string]json.RawMessage `json:"fixtures,omitempty"`
	// LeyVersion is `ley --version` and Commit the commit the image was taken from.
	LeyVersion string `json:"ley_version,omitempty"`
	Commit     string `json:"commit,omitempty"`
	// Tag is the shots-* release the image was first published in; empty until it is.
	Tag string `json:"tag,omitempty"`
	// PNGSHA256 is the sha256 of the PNG `leyshots run` wrote, before oxipng. A release keeps
	// it, so the next publish can tell which images changed (refreshSet).
	PNGSHA256 string `json:"png_sha256,omitempty"`
}

// simulatedSuffix ends the alt text of every shot with fixtures: their signals are generated.
const simulatedSuffix = " Simulated signals."

// altText is a scene's alt text as shots.json carries it.
func altText(alt string, simulated bool) string {
	alt = strings.Join(strings.Fields(alt), " ")
	if !simulated || strings.HasSuffix(alt, simulatedSuffix) {
		return alt
	}
	return alt + simulatedSuffix
}

func readManifest(path string) (*Manifest, error) {
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return &Manifest{}, nil
	}
	if err != nil {
		return nil, err
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &m, nil
}

func (m *Manifest) write(path string) error {
	m.sort()
	b, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(b, '\n'), 0o644)
}

func (m *Manifest) sort() {
	sort.Slice(m.Shots, func(i, j int) bool { return m.Shots[i].Asset < m.Shots[j].Asset })
}

// retire removes every shot whose asset is not in scenes and returns the removed assets, sorted.
// A scene dropped from scenes.yaml must not travel forward from release to release, so publish
// retires the previous release's manifest and this run's against the current scenes file.
func (m *Manifest) retire(scenes map[string]bool) []string {
	var kept []Shot
	var gone []string
	for _, s := range m.Shots {
		if scenes[s.Asset] {
			kept = append(kept, s)
		} else {
			gone = append(gone, s.Asset)
		}
	}
	m.Shots = kept
	sort.Strings(gone)
	return gone
}

// put replaces the entry for s.Asset, or adds it.
func (m *Manifest) put(s Shot) {
	for i := range m.Shots {
		if m.Shots[i].Asset == s.Asset {
			m.Shots[i] = s
			return
		}
	}
	m.Shots = append(m.Shots, s)
}

func (m *Manifest) get(asset string) (Shot, bool) {
	for _, s := range m.Shots {
		if s.Asset == asset {
			return s, true
		}
	}
	return Shot{}, false
}

// merge is the release a publish makes: every entry of prev, with the refreshed entries of cur
// in place of theirs and tagged with tag. An entry of cur not named in refresh is left as prev
// has it, so a run of every scene publishes only what was reviewed.
func merge(prev, cur *Manifest, refresh []string, tag string) (*Manifest, error) {
	out := &Manifest{Shots: slices.Clone(prev.Shots)}
	for _, asset := range refresh {
		s, ok := cur.get(asset)
		if !ok {
			return nil, fmt.Errorf("%s is not in this run's shots.json; take it with: make shots ONLY=%s", asset, strings.TrimSuffix(asset, ".png"))
		}
		s.Tag = tag
		out.put(s)
	}
	out.sort()
	return out, nil
}

// refreshSet is what a publish without --only refreshes: every shot of cur whose PNG exists
// and whose png_sha256 or alt text differs from prev's entry for it, or that prev does not have.
func refreshSet(cur, prev *Manifest, exists func(asset string) bool) []string {
	var out []string
	for _, s := range cur.Shots {
		if !exists(s.Asset) {
			continue
		}
		if p, ok := prev.get(s.Asset); ok && p.PNGSHA256 != "" && p.PNGSHA256 == s.PNGSHA256 && p.Alt == s.Alt {
			continue
		}
		out = append(out, s.Asset)
	}
	sort.Strings(out)
	return out
}

func fileSHA256(path string) (string, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	return sum(b), nil
}

// validate checks a release directory against its manifest: every entry has its PNG at the
// stated size and scale, an alt text ending in the simulated-signals sentence when the shot has
// fixtures, and every PNG
// in the directory has an entry.
func (m *Manifest) validate(dir string) error {
	var errs []error
	listed := map[string]bool{}
	for _, s := range m.Shots {
		listed[s.Asset] = true
		w, h, err := pngSize(filepath.Join(dir, s.Asset))
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if w != s.Width || h != s.Height {
			errs = append(errs, fmt.Errorf("%s is %d×%d and shots.json says %d×%d", s.Asset, w, h, s.Width, s.Height))
		}
		if s.Scale != 2 {
			errs = append(errs, fmt.Errorf("%s has scale %d; every shot is 2×", s.Asset, s.Scale))
		}
		if len(s.Fixtures) > 0 && !strings.HasSuffix(s.Alt, simulatedSuffix) {
			errs = append(errs, fmt.Errorf("%s's alt text does not end %q", s.Asset, simulatedSuffix))
		}
	}
	pngs, err := filepath.Glob(filepath.Join(dir, "*.png"))
	if err != nil {
		return err
	}
	for _, p := range pngs {
		if !listed[filepath.Base(p)] {
			errs = append(errs, fmt.Errorf("%s is in %s and not in shots.json", filepath.Base(p), dir))
		}
	}
	return errors.Join(errs...)
}
