// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"gopkg.in/yaml.v3"
)

// CheckFile is app/checks/scenes.yaml: the app's check scenes (docs/plans/mac-loop.md, ML-4).
type CheckFile struct {
	Scenes []CheckScene `yaml:"scenes"`
	// dir is the directory the file was read from; scene paths are relative to it.
	dir string
}

// CheckScene is one state of the app to check: a site scene's inputs, the window sizes to take it
// at, and the commands sent to the running app over its command file (ML-3).
type CheckScene struct {
	Name      string       `yaml:"name"`
	Fixtures  []FixtureRef `yaml:"fixtures"`
	Clock     string       `yaml:"clock"`
	Bookmarks string       `yaml:"bookmarks"`
	Steps     []Step       `yaml:"steps"`
	// Stage is applied at launch. Its window comes from Sizes, so it may not set one.
	Stage *Stage `yaml:"stage"`
	// Sizes are the window sizes in points; the scene runs once per size, each with its own
	// daemon and app. Empty is defaultCheckSize.
	Sizes []Size       `yaml:"sizes"`
	App   []AppCommand `yaml:"app"`
	// Threshold is the percentage of compared pixels a snapshot may change and still pass;
	// nil is defaultThreshold.
	Threshold *float64 `yaml:"threshold"`
	// AI puts the assistant on a scripted model, with a made-up key (ai.go).
	AI *AISetup `yaml:"ai"`
	// SweepDwell is the dwell in seconds of a scan on the scene's file radio when it asks for less
	// (leylined --file-scan-dwell): its one step lasts about that long, so a sweep in progress can
	// be seen and stopped. 0 leaves the scan's own.
	SweepDwell float64 `yaml:"sweep_dwell"`
}

// defaultCheckSize is the site shots' window.
var defaultCheckSize = Size{Width: 1440, Height: 820}

// defaultMask is what a snapshot or an ax tree leaves out of the comparison unless the command
// names its own mask: live signal pixels and readings never repeat exactly. The spectrum and the
// waterfall draw the radio; readings is the inspector's figures and audio ladder; transmissions
// is its log's rows, which gain one whenever an over ends, and log_day the day over them, blank
// until the first; heard is the tone the channel last heard, which shows once the decoder has
// measured one; squelch is the squelch's words and the level in its track, which follow the noise
// between overs. A name the app does not report is skipped.
var defaultMask = []string{"spectrum", "waterfall", "readings", "transmissions", "log_day", "heard", "squelch"}

// AppCommand is one command of the command-file protocol (mac-loop.md, ML-3, "The protocol"),
// with the runner's own keys: Name, Expect and Mask. The runner assigns the id.
type AppCommand struct {
	Cmd        string  `yaml:"cmd"`
	Stage      *Stage  `yaml:"stage"`
	Settle     float64 `yaml:"settle"`
	Keys       string  `yaml:"keys"`
	Text       string  `yaml:"text"`
	Identifier string  `yaml:"identifier"`
	Seconds    float64 `yaml:"seconds"`
	// Window is the window an ax tree or a snapshot is read from: main (the default), settings,
	// and for ax also popover or sheet, the main window's open popover or sheet alone.
	Window string `yaml:"window"`
	// X and Y are a hover's or a click's point in points from the window's top-left corner,
	// toolbar included, as the regions and the ax frames are; the identifier's centre otherwise.
	X *float64 `yaml:"x"`
	Y *float64 `yaml:"y"`
	// Button is a click's left (the default) or right.
	Button string `yaml:"button"`
	// Menu is a menu command's item, its titles from the menu bar joined by >:
	// View>Show Assistant.
	Menu string `yaml:"menu"`
	// Read has a menu command read the item (enabled, checked, its menu's items in order)
	// rather than press it.
	Read bool `yaml:"read"`
	// Name names a snapshot's or an ax tree's artefact and its golden.
	Name string `yaml:"name"`
	// Expect maps dotted paths into a state answer's result to the scalar each must hold.
	Expect map[string]any `yaml:"expect"`
	// Mask names the regions a snapshot or an ax tree leaves out of the comparison; nil is
	// defaultMask, [] none.
	Mask []string `yaml:"mask"`
	// ExpectLog is what the app's log must (or, with !, must not) hold among the lines it wrote
	// from the moment the command before was sent until a state or wait is answered.
	ExpectLog patterns `yaml:"expect_log"`

	// The runner's own commands (local.go), which never reach the app.
	// Args are a ley or ley_bg command's arguments, without ley.
	Args []string `yaml:"args"`
	// ExpectStdout is what a ley command's standard output must (or, with !, must not) match.
	ExpectStdout patterns `yaml:"expect_stdout"`
	// ExpectExit is a ley command's exit status; nil is 0.
	ExpectExit *int `yaml:"expect_exit"`
	// ID names a ley_bg process for the kill that ends it.
	ID string `yaml:"id"`
	// Path is a file command's file, relative to the run directory (bookmarks.json, app.log).
	Path string `yaml:"path"`
	// Contains is what a file command's file must (or, with !, must not) match.
	Contains patterns `yaml:"contains"`
	// Op is a daemon command's stop or start.
	Op string `yaml:"op"`
}

// wireCommand is one line of commands.jsonl.
type wireCommand struct {
	ID         int      `json:"id"`
	Cmd        string   `json:"cmd"`
	Stage      *Stage   `json:"stage,omitempty"`
	Settle     float64  `json:"settle,omitempty"`
	Keys       string   `json:"keys,omitempty"`
	Text       string   `json:"text,omitempty"`
	Identifier string   `json:"identifier,omitempty"`
	Seconds    float64  `json:"seconds,omitempty"`
	Window     string   `json:"window,omitempty"`
	X          *float64 `json:"x,omitempty"`
	Y          *float64 `json:"y,omitempty"`
	Button     string   `json:"button,omitempty"`
	Menu       string   `json:"menu,omitempty"`
	Read       bool     `json:"read,omitempty"`
}

// LoadChecks reads and validates a check scenes file.
func LoadChecks(path string) (*CheckFile, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f CheckFile
	dec := yaml.NewDecoder(strings.NewReader(string(b)))
	dec.KnownFields(true)
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	f.dir = filepath.Dir(path)
	var errs []error
	seen := map[string]bool{}
	for i := range f.Scenes {
		s := &f.Scenes[i]
		if err := s.validate(f.Path); err != nil {
			errs = append(errs, fmt.Errorf("scene %s: %w", s.Name, err))
		}
		if seen[s.Name] {
			errs = append(errs, fmt.Errorf("scene %s appears twice", s.Name))
		}
		seen[s.Name] = true
	}
	if err := errors.Join(errs...); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &f, nil
}

// Path resolves a path in the file against its directory.
func (f *CheckFile) Path(p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(f.dir, p)
}

// Select returns the scenes named in only, or every scene when only is empty.
func (f *CheckFile) Select(only []string) ([]*CheckScene, error) {
	var out []*CheckScene
	for i := range f.Scenes {
		if len(only) == 0 {
			out = append(out, &f.Scenes[i])
		}
	}
	for _, n := range only {
		found := false
		for i := range f.Scenes {
			if f.Scenes[i].Name == n {
				out = append(out, &f.Scenes[i])
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("no check scene called %q; leyshots check --list shows them", n)
		}
	}
	return out, nil
}

// sizes is the scene's window sizes, or the default one.
func (s *CheckScene) sizes() []Size {
	if len(s.Sizes) == 0 {
		return []Size{defaultCheckSize}
	}
	return s.Sizes
}

// threshold is the scene's diff threshold in percent.
func (s *CheckScene) threshold() float64 {
	if s.Threshold == nil {
		return defaultThreshold
	}
	return *s.Threshold
}

func (s *CheckScene) validate(path func(string) string) error {
	if s.Name == "" || filepath.Base(s.Name) != s.Name || strings.ContainsAny(s.Name, " .") {
		return fmt.Errorf("name must be one word usable as a directory name, not %q", s.Name)
	}
	if len(s.Fixtures) == 0 {
		// A staged run does not reopen a band: the app needs a channel tuned before it starts.
		return errors.New("a check scene needs fixtures")
	}
	if len(s.App) == 0 {
		return errors.New("a check scene needs at least one app command")
	}
	if s.Stage != nil {
		if s.Stage.Window != nil {
			return errors.New("the stage's window comes from sizes; set sizes instead")
		}
		if err := s.Stage.validate(path); err != nil {
			return err
		}
	}
	for _, z := range s.Sizes {
		if z.Width <= 0 || z.Height <= 0 {
			return fmt.Errorf("size %s is not a window", z)
		}
	}
	if s.Threshold != nil && (*s.Threshold < 0 || *s.Threshold > 100) {
		return fmt.Errorf("threshold %g is not a percentage", *s.Threshold)
	}
	if s.SweepDwell < 0 || s.SweepDwell > 60 {
		return fmt.Errorf("sweep_dwell %g is not between 0 and 60 seconds", s.SweepDwell)
	}
	if err := validateSetup(path, s.Bookmarks, s.Steps); err != nil {
		return err
	}
	if s.AI != nil {
		if err := s.AI.validate(path); err != nil {
			return err
		}
	}
	names := map[string]bool{}
	bg := map[string]bool{}
	for i := range s.App {
		c := &s.App[i]
		if err := c.validate(path); err != nil {
			return fmt.Errorf("app command %d (%s): %w", i+1, c.Cmd, err)
		}
		if c.isLocal() {
			if err := c.validateLocal(bg); err != nil {
				return fmt.Errorf("app command %d (%s): %w", i+1, c.Cmd, err)
			}
		}
		if c.Name != "" {
			key := c.Cmd + " " + c.Name
			if names[key] {
				return fmt.Errorf("app command %d: a second %s named %q", i+1, c.Cmd, c.Name)
			}
			names[key] = true
		}
	}
	return nil
}

// validate checks that a command has the fields its kind needs and none it does not use.
func (c *AppCommand) validate(path func(string) string) error {
	set := map[string]bool{
		"stage": c.Stage != nil, "settle": c.Settle != 0, "keys": c.Keys != "", "text": c.Text != "",
		"identifier": c.Identifier != "", "seconds": c.Seconds != 0, "name": c.Name != "",
		"expect": len(c.Expect) > 0, "mask": c.Mask != nil, "window": c.Window != "",
		"args": len(c.Args) > 0, "expect_stdout": len(c.ExpectStdout) > 0, "expect_exit": c.ExpectExit != nil,
		"id": c.ID != "", "path": c.Path != "", "contains": len(c.Contains) > 0, "op": c.Op != "",
		"expect_log": len(c.ExpectLog) > 0, "x": c.X != nil, "y": c.Y != nil, "button": c.Button != "",
		"menu": c.Menu != "", "read": c.Read,
	}
	var need, may []string
	switch c.Cmd {
	case "stage":
		need = []string{"stage"}
	case "snapshot":
		need, may = []string{"name"}, []string{"settle", "mask", "window"}
		if c.Window != "" && c.Window != "main" && c.Window != "settings" {
			return fmt.Errorf("snapshot window is main or settings, not %q", c.Window)
		}
	case "state":
		may = []string{"expect", "expect_log"}
	case "ax":
		need, may = []string{"name"}, []string{"mask", "window"}
		if !slices.Contains([]string{"", "main", "settings", "popover", "sheet"}, c.Window) {
			return fmt.Errorf("ax window is main, settings, popover or sheet, not %q", c.Window)
		}
	case "key":
		need = []string{"keys"}
	case "type":
		need = []string{"text"}
	case "press":
		need = []string{"identifier"}
	case "wait":
		need, may = []string{"seconds"}, []string{"expect_log"}
	case "menu":
		need, may = []string{"menu"}, []string{"read", "expect"}
	case "hover", "click":
		may = []string{"identifier", "x", "y"}
		if c.Cmd == "hover" {
			may = append(may, "expect")
		}
		if c.Cmd == "click" {
			may = append(may, "button")
		}
		if (c.Identifier != "") == (c.X != nil || c.Y != nil) || (c.X == nil) != (c.Y == nil) {
			return fmt.Errorf("%s needs an identifier, or x and y", c.Cmd)
		}
		if c.Button != "" && c.Button != "left" && c.Button != "right" {
			return fmt.Errorf("click button is left or right, not %q", c.Button)
		}
	case "relaunch":
		may = []string{"stage"}
	case "ley":
		need, may = []string{"args"}, []string{"expect_stdout", "expect_exit"}
	case "ley_bg":
		need = []string{"id", "args"}
	case "kill":
		need = []string{"id"}
	case "file":
		need = []string{"path", "contains"}
	case "daemon":
		need = []string{"op"}
	case "quit":
		return errors.New("the runner sends quit after the last command")
	default:
		return fmt.Errorf("unknown command %q", c.Cmd)
	}
	allowed := map[string]bool{}
	for _, k := range need {
		if !set[k] {
			return fmt.Errorf("%s needs %s", c.Cmd, k)
		}
		allowed[k] = true
	}
	for _, k := range may {
		allowed[k] = true
	}
	for k, on := range set {
		if on && !allowed[k] {
			return fmt.Errorf("%s does not take %s", c.Cmd, k)
		}
	}
	if c.Menu != "" && slices.Contains(strings.Split(c.Menu, ">"), "") {
		return fmt.Errorf("menu %q has an empty title; join the titles with >", c.Menu)
	}
	if c.Settle < 0 || c.Seconds < 0 {
		return errors.New("settle and seconds are not negative")
	}
	if c.Name != "" && (filepath.Base(c.Name) != c.Name || strings.ContainsAny(c.Name, " .")) {
		return fmt.Errorf("name must be one word usable as a file name, not %q", c.Name)
	}
	for _, m := range c.Mask {
		if !regionNames[m] {
			return fmt.Errorf("unknown region %q in mask", m)
		}
	}
	if err := c.ExpectLog.validate(); err != nil {
		return fmt.Errorf("expect_log: %w", err)
	}
	for p, v := range c.Expect {
		switch v.(type) {
		case string, int, float64, bool, nil:
		default:
			return fmt.Errorf("expect %s: want a string, number, boolean or null, not %T", p, v)
		}
	}
	if c.Stage != nil {
		if c.Stage.Window != nil {
			// The window is the scene's size, the dimension the goldens are kept by.
			return errors.New("a stage command may not set the window; the scene's sizes do")
		}
		return c.Stage.validate(path)
	}
	return nil
}

// wire is the command as its line in commands.jsonl, with the stage's CHIRP import made absolute.
func (c *AppCommand) wire(id int, path func(string) string) (wireCommand, error) {
	w := wireCommand{
		ID: id, Cmd: c.Cmd, Settle: c.Settle, Keys: c.Keys, Text: c.Text,
		Identifier: c.Identifier, Seconds: c.Seconds, Window: c.Window,
		X: c.X, Y: c.Y, Button: c.Button, Menu: c.Menu, Read: c.Read,
	}
	if c.Stage != nil {
		st, err := resolveStage(path, c.Stage)
		if err != nil {
			return wireCommand{}, err
		}
		w.Stage = &st
	}
	return w, nil
}

// label is how a command is named in the output: its artefact name, or its kind and number.
func (c *AppCommand) label(n int) string {
	switch c.Cmd {
	case "snapshot":
		return c.Name
	case "ax":
		return c.Name + ".ax"
	}
	return fmt.Sprintf("%s#%d", c.Cmd, n)
}
