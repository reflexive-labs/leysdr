// SPDX-License-Identifier: Apache-2.0

package main

import (
	"io/fs"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// Every file in LeylineApp is covered by a scene or is shared, every glob matches a file, and
// the smoke and serial scenes are the ones ML-11 names. A file no scene covers is fixed by
// covering it, with a glob on the scene that checks it or a scene that does.
func TestCheckCoverage(t *testing.T) {
	f, err := LoadChecks(checksPath)
	if err != nil {
		t.Fatal(err)
	}
	sources := filepath.Join("..", "..", "..", sourcesDir)
	var files []string
	err = filepath.WalkDir(sources, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return err
		}
		rel, err := filepath.Rel(sources, p)
		files = append(files, filepath.ToSlash(rel))
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	covered := func(rel string) bool {
		if matchesAny(f.Shared, rel) {
			return true
		}
		for i := range f.Scenes {
			if matchesAny(f.Scenes[i].Covers, rel) {
				return true
			}
		}
		return false
	}
	for _, rel := range files {
		if strings.HasPrefix(rel, "LeylineApp/") && !covered(rel) {
			t.Errorf("app/Sources/%s is covered by no scene in app/checks/scenes.yaml: add it to the covers of the scenes that check it", rel)
		}
	}
	unused := func(where string, globs []string) {
		for _, g := range globs {
			if !slices.ContainsFunc(files, func(rel string) bool { return matchesAny([]string{g}, rel) }) {
				t.Errorf("%s: %q matches no file under app/Sources", where, g)
			}
		}
	}
	unused("shared", f.Shared)
	var smoke, serial []string
	for i := range f.Scenes {
		s := &f.Scenes[i]
		unused("scene "+s.Name, s.Covers)
		if s.Smoke {
			smoke = append(smoke, s.Name)
		}
		if s.Serial {
			serial = append(serial, s.Name)
		}
	}
	if got := strings.Join(smoke, " "); got != "radio-2m goto-bookmark identifiers" {
		t.Errorf("smoke scenes: %s", got)
	}
	if got := strings.Join(serial, " "); got != "vhf-wide sweep-lifecycle sweep-quiet" {
		t.Errorf("serial scenes: %s", got)
	}
}
