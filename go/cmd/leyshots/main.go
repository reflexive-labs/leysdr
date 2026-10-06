// SPDX-License-Identifier: Apache-2.0

// Command leyshots takes the screenshots for leysdr.com from the real app and the real `ley`,
// each scene against its own `leylined --no-hardware` playing synthetic IQ, and publishes them
// as a GitHub release (docs/plans/site-shots.md).
//
//	leyshots run [--only a,b] [--out tmp/shots]
//	leyshots publish [--only a,b] [--out tmp/shots] [--dry-run]
//	leyshots list
//	leyshots keys [--out tmp/shots/keys] [--leyfix PATH]
//	leyshots makefile
//
// The programs it drives come from the environment, defaulting to the Makefile's build outputs:
// LEYLINED_BIN (engine/.build/debug/leylined), LEY_BIN (go/bin/ley), LEYFIX_BIN (go/bin/leyfix)
// and LEYLINE_APP (app/dist/Leyline.app).
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

func usage(w io.Writer) {
	fmt.Fprintln(w, "usage: leyshots run [--only a,b] [--out DIR]       take the scenes in site/shots/scenes.yaml")
	fmt.Fprintln(w, "       leyshots publish [--only a,b] [--out DIR] [--dry-run]")
	fmt.Fprintln(w, "                                                 release the reviewed images as shots-YYYY-MM-DD")
	fmt.Fprintln(w, "       leyshots list                             the scenes, their kind and what they need")
	fmt.Fprintln(w, "       leyshots keys [--out DIR] [--leyfix PATH] write each scene's input hash, for make shots")
	fmt.Fprintln(w, "       leyshots makefile                         print the make rules make shots includes")
}

func main() { os.Exit(realMain(os.Args[1:])) }

// realMain runs a subcommand and returns the exit status: 2 for a usage error, 1 for a failure.
func realMain(args []string) int {
	if len(args) < 1 {
		usage(os.Stderr)
		return 2
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	var err error
	switch args[0] {
	case "run":
		err = cmdRun(ctx, args[1:], os.Stdout)
	case "publish":
		err = cmdPublish(ctx, args[1:], os.Stdout)
	case "list":
		err = cmdList(args[1:], os.Stdout)
	case "keys":
		err = cmdKeys(ctx, args[1:])
	case "makefile":
		err = cmdMakefile(args[1:], os.Stdout)
	case "-h", "--help", "help":
		usage(os.Stdout)
		return 0
	default:
		usage(os.Stderr)
		return 2
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "leyshots:", err)
		return 1
	}
	return 0
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "leyshots: "+format+"\n", args...)
}

// findRoot is the repository root: the nearest directory at or above dir holding
// site/shots/scenes.yaml.
func findRoot(dir string) (string, error) {
	for d := dir; ; d = filepath.Dir(d) {
		if _, err := os.Stat(filepath.Join(d, "site", "shots", "scenes.yaml")); err == nil {
			return d, nil
		}
		if filepath.Dir(d) == d {
			return "", errors.New("no site/shots/scenes.yaml here or above; run leyshots from the leysdr checkout")
		}
	}
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func splitList(s string) []string {
	var out []string
	for _, v := range strings.Split(s, ",") {
		if v = strings.TrimSpace(v); v != "" {
			out = append(out, v)
		}
	}
	return out
}

func cmdRun(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("run", flag.ContinueOnError)
	only := fs.String("only", "", "comma-separated scenes to take, by asset name, e.g. app-radio-2m,scan-2m (default: all)")
	out := fs.String("out", "", "output directory for the images and shots.json (default: tmp/shots in the checkout)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err := findRoot(cwd)
	if err != nil {
		return err
	}
	o := runOptions{
		root:     root,
		scenes:   filepath.Join(root, "site", "shots", "scenes.yaml"),
		out:      *out,
		cache:    defaultCacheDir(),
		only:     splitList(*only),
		leylined: envOr("LEYLINED_BIN", filepath.Join(root, "engine", ".build", "debug", "leylined")),
		ley:      envOr("LEY_BIN", filepath.Join(root, "go", "bin", "ley")),
		leyfix:   envOr("LEYFIX_BIN", filepath.Join(root, "go", "bin", "leyfix")),
		app:      envOr("LEYLINE_APP", filepath.Join(root, "app", "dist", "Leyline.app")),
		tmux:     envOr("TMUX_BIN", "tmux"),
		python:   envOr("PYTHON", "python3"),
		swift:    envOr("SWIFT", "swift"),
		decoders: filepath.Join(root, "decoders"),
		goos:     runtime.GOOS,
		stdout:   stdout,
		logf:     logf,
	}
	if o.out == "" {
		o.out = filepath.Join(root, "tmp", "shots")
	}
	if o.out, err = filepath.Abs(o.out); err != nil {
		return err
	}
	return runScenes(ctx, o)
}

func cmdPublish(ctx context.Context, args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("publish", flag.ContinueOnError)
	only := fs.String("only", "", "comma-separated assets to refresh in the release, e.g. app-radio-2m (default: every image in shots.json whose png_sha256 differs from the latest release's)")
	out := fs.String("out", "", "the run's output directory (default: tmp/shots in the checkout)")
	dryRun := fs.Bool("dry-run", false, "merge, compress and check the release in <out>/publish/<tag>, and create nothing")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err := findRoot(cwd)
	if err != nil {
		return err
	}
	f, err := Load(filepath.Join(root, "site", "shots", "scenes.yaml"))
	if err != nil {
		return err
	}
	scenes := map[string]bool{}
	for _, s := range f.Scenes {
		scenes[s.Asset] = true
	}
	o := publishOptions{
		out: *out, only: splitList(*only), scenes: scenes, repo: f.Repo, dryRun: *dryRun,
		gh: envOr("GH", "gh"), oxipng: envOr("OXIPNG", "oxipng"), now: time.Now(), stdout: stdout, logf: logf,
	}
	if o.out == "" {
		o.out = filepath.Join(root, "tmp", "shots")
	}
	if _, err := f.Select(o.only); err != nil {
		return err
	}
	return publish(ctx, o)
}

func cmdList(args []string, stdout io.Writer) error {
	if len(args) > 0 {
		return fmt.Errorf("list takes no arguments")
	}
	cwd, err := os.Getwd()
	if err != nil {
		return err
	}
	root, err := findRoot(cwd)
	if err != nil {
		return err
	}
	f, err := Load(filepath.Join(root, "site", "shots", "scenes.yaml"))
	if err != nil {
		return err
	}
	listScenes(f, stdout)
	return nil
}

// listScenes prints one row per scene: its name, kind, fixtures and where it can be taken.
func listScenes(f *File, w io.Writer) {
	fmt.Fprintf(w, "%-22s %-10s %-24s %s\n", "SCENE", "KIND", "FIXTURES", "TAKEN ON")
	for _, s := range f.Scenes {
		var fx []string
		for _, ref := range s.Fixtures {
			fx = append(fx, ref.Name)
		}
		where := "macOS"
		switch s.Kind {
		case kindTerminal, kindTable:
			where = "macOS (HTML elsewhere)"
		}
		fixtures := strings.Join(fx, ",")
		if fixtures == "" {
			fixtures = "-"
		}
		fmt.Fprintf(w, "%-22s %-10s %-24s %s\n", s.Name(), s.Kind, fixtures, where)
	}
}

// loadFromCheckout finds the checkout above the working directory and loads its scenes file.
func loadFromCheckout() (root string, f *File, err error) {
	cwd, err := os.Getwd()
	if err != nil {
		return "", nil, err
	}
	if root, err = findRoot(cwd); err != nil {
		return "", nil, err
	}
	f, err = Load(filepath.Join(root, "site", "shots", "scenes.yaml"))
	return root, f, err
}

func cmdKeys(ctx context.Context, args []string) error {
	fs := flag.NewFlagSet("keys", flag.ContinueOnError)
	out := fs.String("out", "", "directory for the <scene>.key files (default: tmp/shots/keys in the checkout)")
	leyfix := fs.String("leyfix", "", "the leyfix whose dry run gives each fixture's generator record (default: $LEYFIX_BIN or go/bin/leyfix)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	root, f, err := loadFromCheckout()
	if err != nil {
		return err
	}
	if *out == "" {
		*out = filepath.Join(root, "tmp", "shots", "keys")
	}
	if *leyfix == "" {
		*leyfix = envOr("LEYFIX_BIN", filepath.Join(root, "go", "bin", "leyfix"))
	}
	src, err := leyfixSourceHash(root)
	if err != nil {
		return err
	}
	cache := defaultCacheDir()
	plan := leyfixPlanner(func(ref FixtureRef) (*planned, error) { return planFixture(ctx, *leyfix, cache, ref) })
	changed, err := writeKeys(*out, f, plan, src)
	if err != nil {
		return err
	}
	if len(changed) > 0 {
		logf("inputs changed for %s", strings.Join(changed, ", "))
	}
	return nil
}

func cmdMakefile(args []string, stdout io.Writer) error {
	if len(args) > 0 {
		return fmt.Errorf("makefile takes no arguments")
	}
	_, f, err := loadFromCheckout()
	if err != nil {
		return err
	}
	return writeMakefile(stdout, f)
}
