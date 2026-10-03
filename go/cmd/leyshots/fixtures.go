// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"

	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

// cacheDir is where generated scene fixtures are kept between runs: the platform's cache
// directory, because they are a few hundred megabytes each and rebuilt from a seed.
func cacheDir(goos string, getenv func(string) string, home string) string {
	if goos == "darwin" {
		return filepath.Join(home, "Library", "Caches", "leyline-shots", "iq")
	}
	if x := getenv("XDG_CACHE_HOME"); x != "" {
		return filepath.Join(x, "leyline-shots", "iq")
	}
	return filepath.Join(home, ".cache", "leyline-shots", "iq")
}

func defaultCacheDir() string {
	home, _ := os.UserHomeDir()
	return cacheDir(runtime.GOOS, os.Getenv, home)
}

// fixtureFile is a fixture ready to play: its sample file and the generator record its sidecar
// carries, which shots.json keeps.
type fixtureFile struct {
	Path      string
	Generator json.RawMessage
}

// planned is one line of `leyfix generate --dry-run`.
type planned struct {
	Name    string         `json:"name"`
	File    string         `json:"file"`
	Sidecar iqfile.Sidecar `json:"sidecar"`
}

func leyfixArgs(ref FixtureRef, dir string) []string {
	args := []string{"generate", "--out", dir, "--only", ref.Name}
	if ref.Rate > 0 {
		args = append(args, "--rate", strconv.FormatFloat(ref.Rate, 'f', -1, 64))
	}
	if ref.Duration > 0 {
		args = append(args, "--duration", strconv.FormatFloat(ref.Duration, 'f', -1, 64))
	}
	return args
}

// ensureFixture returns the fixture in dir, generating it with leyfix unless the copy there was
// generated the same way: the same format, rate, centre, length, label and generator record,
// and a sample file of the size those imply.
func ensureFixture(ctx context.Context, leyfix, dir string, ref FixtureRef, logf func(string, ...any)) (*fixtureFile, error) {
	out, err := exec.CommandContext(ctx, leyfix, append(leyfixArgs(ref, dir), "--dry-run")...).Output()
	if err != nil {
		return nil, fmt.Errorf("leyfix --dry-run for %s: %w", ref.Name, err)
	}
	var want planned
	if err := json.Unmarshal(bytes.TrimSpace(out), &want); err != nil {
		return nil, fmt.Errorf("leyfix --dry-run for %s printed %q: %w", ref.Name, out, err)
	}
	path := filepath.Join(dir, want.File)
	if current(path, &want.Sidecar) {
		logf("fixture %s: cached at %s", ref.Name, path)
		return &fixtureFile{Path: path, Generator: want.Sidecar.Generator}, nil
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	logf("fixture %s: generating into %s", ref.Name, dir)
	cmd := exec.CommandContext(ctx, leyfix, leyfixArgs(ref, dir)...)
	if b, err := cmd.CombinedOutput(); err != nil {
		return nil, fmt.Errorf("leyfix generate %s: %w\n%s", ref.Name, err, b)
	}
	if !current(path, &want.Sidecar) {
		return nil, fmt.Errorf("leyfix wrote %s, but it does not match its own dry run", path)
	}
	return &fixtureFile{Path: path, Generator: want.Sidecar.Generator}, nil
}

// current reports whether the fixture at path was generated as want describes.
func current(path string, want *iqfile.Sidecar) bool {
	have, err := iqfile.ReadSidecar(path)
	if err != nil {
		return false
	}
	if have.Format != want.Format || have.SampleRate != want.SampleRate || have.CenterHz != want.CenterHz ||
		have.Samples != want.Samples || have.Label != want.Label || !sameJSON(have.Generator, want.Generator) {
		return false
	}
	st, err := os.Stat(iqfile.SamplesPath(path, have.Format))
	return err == nil && st.Size() == have.Samples*int64(iqfile.BytesPerSample(have.Format))
}

// sameJSON compares two JSON documents as values, so key order and spacing do not matter.
func sameJSON(a, b json.RawMessage) bool {
	var va, vb any
	if json.Unmarshal(a, &va) != nil || json.Unmarshal(b, &vb) != nil {
		return false
	}
	ja, _ := json.Marshal(va)
	jb, _ := json.Marshal(vb)
	return bytes.Equal(ja, jb)
}
