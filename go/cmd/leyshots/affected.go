// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"reflect"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// sourcesDir, checksDir and packageFile are where --affected looks for changes, from the
// checkout's root. A scene's covers and the file's shared globs are relative to sourcesDir, and
// the package manifest is matched as `Package.swift` (globPath).
const (
	sourcesDir  = "app/Sources"
	checksDir   = "app/checks"
	packageFile = "app/Package.swift"
)

// globPath is the path a changed file is matched against covers and shared with: relative to
// app/Sources, or `Package.swift` for the manifest, which builds both targets. ok is false for
// any other file.
func globPath(file string) (rel string, ok bool) {
	if file == packageFile {
		return path.Base(packageFile), true
	}
	return strings.CutPrefix(file, sourcesDir+"/")
}

// tierKeys are a scene's keys that choose when it runs rather than what it does: a change to
// them alone does not make the scene affected.
var tierKeys = []string{"covers", "smoke", "serial"}

// validGlobs checks that each glob is a path.Match pattern relative to app/Sources.
func validGlobs(globs []string) error {
	for _, g := range globs {
		if g == "" || strings.HasPrefix(g, "/") || strings.HasPrefix(g, "../") {
			return fmt.Errorf("%q is not a glob relative to app/Sources", g)
		}
		if _, err := path.Match(g, ""); err != nil {
			return fmt.Errorf("%q: %w", g, err)
		}
	}
	return nil
}

// matchesAny reports whether one of the globs matches rel, a path relative to app/Sources. A
// glob without a / matches the file's name in any directory, as a .gitignore pattern does.
func matchesAny(globs []string, rel string) bool {
	for _, g := range globs {
		target := rel
		if !strings.Contains(g, "/") {
			target = path.Base(rel)
		}
		if ok, _ := path.Match(g, target); ok { // the globs were validated on load
			return true
		}
	}
	return false
}

// selection is what --affected picks: the scenes in the file's order, the changed files that
// brought each in, and the changed files no scene covers.
type selection struct {
	base string
	// note is a line printed before the others: why base is not the one asked for.
	note      string
	changed   []string
	scenes    []*CheckScene
	why       map[string][]string
	uncovered []string
}

func (sel *selection) add(s *CheckScene, reason string) {
	if !slices.Contains(sel.why[s.Name], reason) {
		sel.why[s.Name] = append(sel.why[s.Name], reason)
	}
}

// affected picks the scenes a change touches. changed are paths from root, the checkout;
// edited names the scenes whose definition in scenes.yaml changed. A file under app/Sources
// brings in the scenes whose covers match it, and a shared one the smoke scenes too; a file
// under app/checks brings in the scenes that read it (a script, bookmarks, a CHIRP import), and
// scenes.yaml the edited scenes. A changed file nothing brings in is uncovered.
func (f *CheckFile) affected(root string, changed []string, edited map[string]bool) *selection {
	sel := &selection{changed: changed, why: map[string][]string{}}
	for _, file := range changed {
		found := false
		if rel, ok := globPath(file); ok {
			name := path.Base(rel)
			shared := matchesAny(f.Shared, rel)
			if shared {
				name += " (shared)"
			}
			for i := range f.Scenes {
				s := &f.Scenes[i]
				if matchesAny(s.Covers, rel) || (shared && s.Smoke) {
					sel.add(s, name)
					found = true
				}
			}
		} else if file == checksDir+"/scenes.yaml" {
			for i := range f.Scenes {
				if edited[f.Scenes[i].Name] {
					sel.add(&f.Scenes[i], "scenes.yaml")
				}
			}
			found = true // an edit that changes no scene (a comment, a covers glob) needs no run
		} else {
			abs, _ := filepath.Abs(filepath.Join(root, file))
			for i := range f.Scenes {
				if slices.Contains(f.Scenes[i].inputs(f.Path), abs) {
					sel.add(&f.Scenes[i], path.Base(file))
					found = true
				}
			}
		}
		if !found {
			sel.uncovered = append(sel.uncovered, file)
		}
	}
	for i := range f.Scenes {
		if len(sel.why[f.Scenes[i].Name]) > 0 {
			sel.scenes = append(sel.scenes, &f.Scenes[i])
		}
	}
	return sel
}

// inputs are the absolute paths of the files the scene reads from beside scenes.yaml or
// elsewhere in the checkout: its bookmarks, its assistant's script and each CHIRP import.
func (s *CheckScene) inputs(resolve func(string) string) []string {
	var out []string
	add := func(p string) {
		if p == "" {
			return
		}
		if abs, err := filepath.Abs(resolve(p)); err == nil {
			out = append(out, abs)
		}
	}
	add(s.Bookmarks)
	if s.AI != nil {
		add(s.AI.Script)
	}
	if s.Stage != nil {
		add(s.Stage.ImportChirp)
	}
	for i := range s.App {
		if s.App[i].Stage != nil {
			add(s.App[i].Stage.ImportChirp)
		}
	}
	return out
}

// print writes the selection: the note, a line on the change, one per scene with what brought
// it in, and one per uncovered file.
func (sel *selection) print(w io.Writer) {
	if sel.note != "" {
		fmt.Fprintln(w, sel.note)
	}
	fmt.Fprintf(w, "since %s: %d changed under %s and %s, %d scenes affected\n",
		sel.base, len(sel.changed), sourcesDir, checksDir, len(sel.scenes))
	for _, s := range sel.scenes {
		why := sel.why[s.Name]
		if len(why) > 4 {
			why = append(why[:4:4], fmt.Sprintf("%d more", len(sel.why[s.Name])-4))
		}
		fmt.Fprintf(w, "affected %s: %s\n", s.Name, strings.Join(why, ", "))
	}
	for _, file := range sel.uncovered {
		fmt.Fprintf(w, "uncovered: %s\n", file)
	}
}

// uncoveredResults are the failures the uncovered files make: a file nothing checks fails the
// run, so --affected never passes having checked less than changed.
func (sel *selection) uncoveredResults() []checkResult {
	var out []checkResult
	for _, file := range sel.uncovered {
		out = append(out, checkResult{
			Status: "fail", Scene: "-", Size: "-", Item: "uncovered", Path: file,
			Detail: "no scene covers it: give the scene that checks it a covers glob, or the file a scene that reads it",
		})
	}
	return out
}

// emptyError is the error for a selection of no scene, which checks nothing and so cannot pass.
func (sel *selection) emptyError() error {
	if len(sel.uncovered) > 0 {
		return fmt.Errorf("--affected selected no scene: no scene covers what changed since %s (the uncovered lines above)", sel.base)
	}
	return fmt.Errorf("--affected selected no scene: nothing a scene checks changed since %s; give an earlier --base, or name the scenes with --only", sel.base)
}

// affectedScenes finds what changed in the checkout at root since base (the merge base with
// main when empty), committed or not, untracked files included, and picks the scenes it touches.
// A base that is HEAD with nothing changed since, as on main with the work committed, would
// check nothing, so the comparison is with the commit before HEAD, and a note says so.
func affectedScenes(ctx context.Context, root, base string, f *CheckFile, checks string) (*selection, error) {
	if base == "" {
		mb, err := gitOutput(ctx, root, "merge-base", "HEAD", "main")
		if err != nil {
			return nil, fmt.Errorf("no merge base with main: %w; name the base with --base", err)
		}
		base = strings.TrimSpace(mb)
	}
	sha, err := shortCommit(ctx, root, base)
	if err != nil {
		return nil, fmt.Errorf("--base %s: %w", base, err)
	}
	changed, err := changedSince(ctx, root, sha)
	if err != nil {
		return nil, err
	}
	note := ""
	if head, err := shortCommit(ctx, root, "HEAD"); err == nil && head == sha && len(changed) == 0 {
		prev, err := shortCommit(ctx, root, "HEAD~1")
		if err != nil {
			return nil, fmt.Errorf("the base %s is HEAD, nothing has changed since, and HEAD has no commit before it to compare with; name scenes with --only", sha)
		}
		note = fmt.Sprintf("the base %s is HEAD and nothing has changed since: comparing with the commit before, %s", sha, prev)
		sha = prev
		if changed, err = changedSince(ctx, root, sha); err != nil {
			return nil, err
		}
	}
	var edited map[string]bool
	if slices.Contains(changed, checksDir+"/scenes.yaml") {
		if edited, err = editedScenes(ctx, root, sha, checks); err != nil {
			return nil, err
		}
	}
	sel := f.affected(root, changed, edited)
	sel.base, sel.note = sha, note
	return sel, nil
}

// shortCommit is ref's commit, abbreviated.
func shortCommit(ctx context.Context, root, ref string) (string, error) {
	sha, err := gitOutput(ctx, root, "rev-parse", "--verify", "--short", ref+"^{commit}")
	return strings.TrimSpace(sha), err
}

// changedSince lists the files under app/Sources and app/checks, and the package manifest, that
// differ from sha in the working tree, untracked ones included, sorted.
func changedSince(ctx context.Context, root, sha string) ([]string, error) {
	paths := []string{sourcesDir, checksDir, packageFile}
	diff, err := gitOutput(ctx, root, append([]string{"diff", "--name-only", "--no-renames", sha, "--"}, paths...)...)
	if err != nil {
		return nil, err
	}
	untracked, err := gitOutput(ctx, root, append([]string{"ls-files", "--others", "--exclude-standard", "--full-name", "--"}, paths...)...)
	if err != nil {
		return nil, err
	}
	var changed []string
	for _, l := range strings.Split(diff+"\n"+untracked, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			changed = append(changed, l)
		}
	}
	slices.Sort(changed)
	return slices.Compact(changed), nil
}

// editedScenes names the scenes in the scenes file at checks whose definition differs from the
// one at base, or which base lacks; a change to a scene's tier keys alone does not count.
func editedScenes(ctx context.Context, root, base, checks string) (map[string]bool, error) {
	now, err := os.ReadFile(checks)
	if err != nil {
		return nil, err
	}
	cur, err := scenesByName(now)
	if err != nil {
		return nil, fmt.Errorf("%s: %w", checks, err)
	}
	// A base without the file, or with one that does not parse, has none of the scenes.
	before := map[string]map[string]any{}
	if old, err := gitOutput(ctx, root, "show", base+":"+checksDir+"/scenes.yaml"); err == nil {
		if m, err := scenesByName([]byte(old)); err == nil {
			before = m
		}
	}
	edited := map[string]bool{}
	for name, s := range cur {
		if old, ok := before[name]; !ok || !reflect.DeepEqual(old, s) {
			edited[name] = true
		}
	}
	return edited, nil
}

// scenesByName reads a scenes file's scenes as plain values by name, without their tier keys.
func scenesByName(b []byte) (map[string]map[string]any, error) {
	var doc struct {
		Scenes []map[string]any `yaml:"scenes"`
	}
	if err := yaml.Unmarshal(b, &doc); err != nil {
		return nil, err
	}
	out := map[string]map[string]any{}
	for _, s := range doc.Scenes {
		for _, k := range tierKeys {
			delete(s, k)
		}
		if name, ok := s["name"].(string); ok {
			out[name] = s
		}
	}
	return out, nil
}

// gitOutput runs git in dir and returns its standard output; a failure carries its stderr.
func gitOutput(ctx context.Context, dir string, args ...string) (string, error) {
	cmd := exec.CommandContext(ctx, "git", args...)
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			return "", fmt.Errorf("git %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(ee.Stderr)))
		}
		return "", fmt.Errorf("git %s: %w", strings.Join(args, " "), err)
	}
	return string(out), nil
}
