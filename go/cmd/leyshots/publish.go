// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"
)

// releasePrefix starts every shots release's tag.
const releasePrefix = "shots-"

// release is one row of `gh release list --json tagName,createdAt`.
type release struct {
	TagName   string    `json:"tagName"`
	CreatedAt time.Time `json:"createdAt"`
}

// latestShots is the newest shots-* release, or "" when there is none.
func latestShots(rels []release) string {
	var shots []release
	for _, r := range rels {
		if strings.HasPrefix(r.TagName, releasePrefix) {
			shots = append(shots, r)
		}
	}
	if len(shots) == 0 {
		return ""
	}
	sort.Slice(shots, func(i, j int) bool { return shots[i].CreatedAt.After(shots[j].CreatedAt) })
	return shots[0].TagName
}

// nextTag is shots-YYYY-MM-DD for day, with -2, -3 and so on when that tag is taken.
func nextTag(day time.Time, rels []release) string {
	taken := map[string]bool{}
	for _, r := range rels {
		taken[r.TagName] = true
	}
	base := releasePrefix + day.Format("2006-01-02")
	tag := base
	for n := 2; taken[tag]; n++ {
		tag = fmt.Sprintf("%s-%d", base, n)
	}
	return tag
}

// releaseNotes lists what a release refreshed and what it carried forward.
func releaseNotes(m *Manifest, refreshed []string, prevTag string) string {
	var b strings.Builder
	b.WriteString("Screenshots for leysdr.com, taken with `make shots` against synthetic IQ (docs/plans/site-shots.md).\n\n")
	b.WriteString("Refreshed:\n")
	for _, a := range refreshed {
		s, _ := m.get(a)
		fmt.Fprintf(&b, "- %s (%d×%d, commit %s)\n", a, s.Width, s.Height, s.Commit)
	}
	if prevTag != "" {
		var kept []string
		for _, s := range m.Shots {
			if !slices.Contains(refreshed, s.Asset) {
				kept = append(kept, s.Asset)
			}
		}
		if len(kept) > 0 {
			fmt.Fprintf(&b, "\nCarried forward from %s: %s.\n", prevTag, strings.Join(kept, ", "))
		}
	}
	return b.String()
}

// publishOptions are `leyshots publish`'s flags.
type publishOptions struct {
	out    string // the run's output directory, holding shots.json and the PNGs
	only   []string
	repo   string
	dryRun bool
	gh     string
	oxipng string
	now    time.Time
	stdout io.Writer
	logf   func(string, ...any)
}

// publish merges the reviewed images with the latest shots-* release and creates the next one.
func publish(ctx context.Context, o publishOptions) error {
	cur, err := readManifest(filepath.Join(o.out, "shots.json"))
	if err != nil {
		return err
	}
	if len(cur.Shots) == 0 {
		return fmt.Errorf("%s lists no shots; take them first with: make shots", filepath.Join(o.out, "shots.json"))
	}
	// An entry written before shots.json carried png_sha256 takes it from its file.
	exists := func(asset string) bool {
		_, err := os.Stat(filepath.Join(o.out, asset))
		return err == nil
	}
	for i := range cur.Shots {
		if s := &cur.Shots[i]; s.PNGSHA256 == "" && exists(s.Asset) {
			if s.PNGSHA256, err = fileSHA256(filepath.Join(o.out, s.Asset)); err != nil {
				return err
			}
		}
	}
	refresh := slices.Clone(o.only)
	for i, a := range refresh {
		if !strings.HasSuffix(a, ".png") {
			refresh[i] = a + ".png"
		}
	}
	listJSON, err := exec.CommandContext(ctx, o.gh, "release", "list", "--repo", o.repo, "--limit", "200", "--json", "tagName,createdAt").Output()
	if err != nil {
		return fmt.Errorf("gh release list: %w", err)
	}
	var rels []release
	if err := json.Unmarshal(listJSON, &rels); err != nil {
		return fmt.Errorf("gh release list printed %q: %w", listJSON, err)
	}
	prevTag := latestShots(rels)
	tag := nextTag(o.now, rels)
	dir := filepath.Join(o.out, "publish", tag)
	if err := os.RemoveAll(dir); err != nil {
		return err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	download := func(pattern ...string) error {
		args := []string{"release", "download", prevTag, "--repo", o.repo, "--dir", dir, "--clobber"}
		for _, p := range pattern {
			args = append(args, "--pattern", p)
		}
		if b, err := exec.CommandContext(ctx, o.gh, args...).CombinedOutput(); err != nil {
			return fmt.Errorf("gh release download %s: %w\n%s", prevTag, err, b)
		}
		return nil
	}
	prev := &Manifest{}
	if prevTag != "" {
		if err := download("shots.json"); err != nil {
			return err
		}
		if prev, err = readManifest(filepath.Join(dir, "shots.json")); err != nil {
			return err
		}
	}
	if len(refresh) == 0 {
		refresh = refreshSet(cur, prev, exists)
		if len(refresh) == 0 && prevTag != "" {
			fmt.Fprintf(o.stdout, "%s is up to date; nothing to publish\n", prevTag)
			return os.RemoveAll(dir)
		}
		if len(refresh) == 0 {
			return fmt.Errorf("no image listed in %s is in %s; take them first with: make shots", filepath.Join(o.out, "shots.json"), o.out)
		}
	}
	if prevTag != "" {
		o.logf("merging with %s", prevTag)
		if err := download(); err != nil {
			return err
		}
	}
	merged, err := merge(prev, cur, refresh, tag)
	if err != nil {
		return err
	}
	for _, a := range refresh {
		if err := copyFile(filepath.Join(o.out, a), filepath.Join(dir, a)); err != nil {
			return err
		}
	}
	if err := compress(ctx, o.oxipng, dir, refresh, o.logf); err != nil {
		return err
	}
	// oxipng changes the bytes and never the pixels, so the sizes still match; validate reads
	// them back from the files rather than trusting that.
	for _, a := range refresh {
		s, _ := merged.get(a)
		w, h, err := pngSize(filepath.Join(dir, a))
		if err != nil {
			return err
		}
		s.Width, s.Height = w, h
		merged.put(s)
	}
	if err := merged.write(filepath.Join(dir, "shots.json")); err != nil {
		return err
	}
	if err := merged.validate(dir); err != nil {
		return fmt.Errorf("the release in %s does not match its shots.json:\n%w", dir, err)
	}
	notes := releaseNotes(merged, refresh, prevTag)
	files := []string{filepath.Join(dir, "shots.json")}
	for _, s := range merged.Shots {
		files = append(files, filepath.Join(dir, s.Asset))
	}
	target, err := releaseTarget(ctx)
	if err != nil && !o.dryRun {
		return err
	}
	args := append([]string{"release", "create", tag, "--repo", o.repo, "--title", tag, "--notes", notes, "--target", target}, files...)
	if o.dryRun {
		if err != nil {
			fmt.Fprintf(o.stdout, "the release would be refused: %v\n", err)
		}
		fmt.Fprintf(o.stdout, "would run: %s release create %s --repo %s --title %s --target %s with %d files from %s\n\n%s",
			o.gh, tag, o.repo, tag, target, len(files), dir, notes)
		return nil
	}
	cmd := exec.CommandContext(ctx, o.gh, args...)
	cmd.Stdout, cmd.Stderr = o.stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("gh release create %s: %w", tag, err)
	}
	fmt.Fprintf(o.stdout, "published %s: %d refreshed, %d in all\n", tag, len(refresh), len(merged.Shots))
	return nil
}

// compress runs oxipng over the refreshed PNGs: lossless, because quantising bands the
// waterfall's gradients. Without oxipng the images go out as Go's encoder wrote them.
func compress(ctx context.Context, oxipng, dir string, assets []string, logf func(string, ...any)) error {
	path, err := exec.LookPath(oxipng)
	if err != nil {
		logf("warning: %s is not installed, so the PNGs are published uncompressed; install it with: brew install oxipng", oxipng)
		return nil
	}
	args := []string{"-o", "4", "--strip", "safe"}
	for _, a := range assets {
		args = append(args, filepath.Join(dir, a))
	}
	if b, err := exec.CommandContext(ctx, path, args...).CombinedOutput(); err != nil {
		return fmt.Errorf("oxipng: %w\n%s", err, b)
	}
	return nil
}

func copyFile(src, dst string) error {
	b, err := os.ReadFile(src)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("%s is missing; take it with: make shots ONLY=%s", src, strings.TrimSuffix(filepath.Base(src), ".png"))
	}
	if err != nil {
		return err
	}
	return os.WriteFile(dst, b, 0o644)
}

// releaseTarget is the commit the release's tag points at: the checkout's HEAD, whose scenes.yaml
// and tools made the images. GitHub can only tag a commit it has, so HEAD must already be on a
// branch of origin; without --target it would tag the default branch's tip instead, which may
// predate the scenes.
func releaseTarget(ctx context.Context) (string, error) {
	out, err := exec.CommandContext(ctx, "git", "rev-parse", "HEAD").Output()
	if err != nil {
		return "", fmt.Errorf("git rev-parse HEAD: %w", err)
	}
	head := strings.TrimSpace(string(out))
	if err := exec.CommandContext(ctx, "git", "fetch", "--quiet", "origin").Run(); err != nil {
		return head, fmt.Errorf("git fetch origin: %w", err)
	}
	out, err = exec.CommandContext(ctx, "git", "branch", "-r", "--contains", head).Output()
	if err != nil {
		return head, fmt.Errorf("git branch -r --contains %s: %w", head, err)
	}
	if strings.TrimSpace(string(out)) == "" {
		return head, fmt.Errorf("commit %.12s is not on GitHub yet, and the release's tag must point at it; push it first with: git push", head)
	}
	return head, nil
}
