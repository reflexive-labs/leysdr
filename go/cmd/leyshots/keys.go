// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// leyfixSourceDirs are the packages whose code decides what leyfix writes: the command and the
// go/pkg packages it imports, directly or through each other. TestLeyfixSourceDirs keeps the list
// equal to `go list -deps ./cmd/leyfix`. go/gen is left out: the generated contract shapes no
// sample, and counting it would regenerate every cached fixture on any proto change.
var leyfixSourceDirs = []string{
	"go/cmd/leyfix",
	"go/pkg/dcs",
	"go/pkg/decoders/afsk",
	"go/pkg/decoders/ais",
	"go/pkg/decoders/ax25",
	"go/pkg/decoders/same",
	"go/pkg/iqfile",
}

// leyfixSourceHash is a sha256 over the non-test Go files of leyfixSourceDirs under root, so a
// change to the generator's code is seen even when the generator record it prints is the same.
func leyfixSourceHash(root string) (string, error) {
	h := sha256.New()
	for _, dir := range leyfixSourceDirs {
		files, err := filepath.Glob(filepath.Join(root, filepath.FromSlash(dir), "*.go"))
		if err != nil {
			return "", err
		}
		if len(files) == 0 {
			return "", fmt.Errorf("no Go files in %s; leyshots runs from the leysdr checkout", filepath.Join(root, dir))
		}
		sort.Strings(files)
		for _, p := range files {
			if strings.HasSuffix(p, "_test.go") {
				continue
			}
			b, err := os.ReadFile(p)
			if err != nil {
				return "", err
			}
			fmt.Fprintf(h, "%s/%s %d\n", dir, filepath.Base(p), len(b))
			h.Write(b)
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// fixturePlanner returns the canonical JSON of what `leyfix generate --dry-run` prints for a
// fixture: its file name and sidecar, generator record included.
type fixturePlanner func(FixtureRef) ([]byte, error)

// sceneKey is the content of a scene's key file: a sha256 over everything the scene's image
// depends on that is particular to it, then one line per input. The inputs are the scene as
// parsed, every file it reads (bookmarks, the stage's CHIRP import, a table's source), each
// fixture's dry run and the leyfix source hash. What every scene of a kind shares (ley, the
// engine, the app, the render scripts) is the Makefile's SHOTS_DEPS_* instead.
func sceneKey(f *File, s *Scene, plan fixturePlanner, leyfixSrc string) (string, error) {
	var lines strings.Builder
	scene, err := json.Marshal(s)
	if err != nil {
		return "", err
	}
	fmt.Fprintf(&lines, "scene %s %s\n", s.Asset, sum(scene))
	var refs []string
	if s.Bookmarks != "" {
		refs = append(refs, s.Bookmarks)
	}
	if s.Stage != nil && s.Stage.ImportChirp != "" {
		refs = append(refs, s.Stage.ImportChirp)
	}
	if s.Table != nil && s.Table.Source != "" {
		refs = append(refs, s.Table.Source)
	}
	for _, r := range refs {
		b, err := os.ReadFile(f.Path(r))
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&lines, "file %s %s\n", r, sum(b))
	}
	for _, ref := range s.Fixtures {
		b, err := plan(ref)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&lines, "fixture %s %s\n", ref.Name, sum(b))
	}
	if len(s.Fixtures) > 0 {
		fmt.Fprintf(&lines, "leyfix-source %s\n", leyfixSrc)
	}
	body := lines.String()
	return "sha256 " + sum([]byte(body)) + "\n" + body, nil
}

func sum(b []byte) string {
	h := sha256.Sum256(b)
	return hex.EncodeToString(h[:])
}

// writeKeys writes <dir>/<scene>.key for every scene in f and removes the key of any scene f no
// longer has. A key file is written only when its content changes, so its mtime, which make
// compares against the image's, moves only when an input did. It returns the scenes whose key
// changed.
func writeKeys(dir string, f *File, plan fixturePlanner, leyfixSrc string) ([]string, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	var changed []string
	keep := map[string]bool{}
	for i := range f.Scenes {
		s := &f.Scenes[i]
		key, err := sceneKey(f, s, plan, leyfixSrc)
		if err != nil {
			return nil, fmt.Errorf("scene %s: %w", s.Name(), err)
		}
		path := filepath.Join(dir, s.Name()+".key")
		keep[filepath.Base(path)] = true
		have, err := os.ReadFile(path)
		if err == nil && bytes.Equal(have, []byte(key)) {
			continue
		}
		if err != nil && !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		if err := os.WriteFile(path, []byte(key), 0o644); err != nil {
			return nil, err
		}
		changed = append(changed, s.Name())
	}
	old, err := filepath.Glob(filepath.Join(dir, "*.key"))
	if err != nil {
		return nil, err
	}
	for _, p := range old {
		if !keep[filepath.Base(p)] {
			if err := os.Remove(p); err != nil {
				return nil, err
			}
		}
	}
	return changed, nil
}

// leyfixPlanner runs `leyfix generate --dry-run` once per distinct fixture reference.
func leyfixPlanner(plan func(FixtureRef) (*planned, error)) fixturePlanner {
	memo := map[FixtureRef][]byte{}
	return func(ref FixtureRef) ([]byte, error) {
		if b, ok := memo[ref]; ok {
			return b, nil
		}
		p, err := plan(ref)
		if err != nil {
			return nil, err
		}
		b, err := json.Marshal(p)
		if err != nil {
			return nil, err
		}
		memo[ref] = b
		return b, nil
	}
}

// makeKinds are the scene kinds in the order the generated rules name their SHOTS_DEPS_* lists.
var makeKinds = []string{kindApp, kindTerminal, kindTable, kindComposite, kindScreen, kindIcon}

// writeMakefile prints the make rules `make shots` includes (Makefile, "shots"): the list of
// images, the images of each kind, and one rule per image whose prerequisites are its key and
// its kind's shared sources, and whose recipe takes that one scene.
func writeMakefile(w io.Writer, f *File) error {
	byKind := map[string][]string{}
	var all []string
	for i := range f.Scenes {
		s := &f.Scenes[i]
		target := "$(SHOTS_OUT)/" + s.Asset
		all = append(all, target)
		byKind[s.Kind] = append(byKind[s.Kind], target)
	}
	var b strings.Builder
	b.WriteString("# Written by `leyshots makefile` from site/shots/scenes.yaml at every `make shots`; do not edit.\n\n")
	writeList(&b, "SHOTS_ASSETS", all)
	for _, k := range makeKinds {
		writeList(&b, "SHOTS_ASSETS_"+strings.ToUpper(k), byKind[k])
	}
	for i := range f.Scenes {
		s := &f.Scenes[i]
		fmt.Fprintf(&b, "\n$(SHOTS_OUT)/%s: $(SHOTS_OUT)/keys/%s.key $(SHOTS_DEPS_%s)\n\t$(SHOTS_RUN) --only %s\n",
			s.Asset, s.Name(), strings.ToUpper(s.Kind), s.Asset)
	}
	_, err := io.WriteString(w, b.String())
	return err
}

func writeList(b *strings.Builder, name string, items []string) {
	b.WriteString(name + " :=")
	for _, it := range items {
		b.WriteString(" \\\n\t" + it)
	}
	b.WriteString("\n")
}
