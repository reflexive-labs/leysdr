// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// The kinds of scene (site/shots/scenes.yaml, the header comment).
const (
	kindApp       = "app"
	kindTerminal  = "terminal"
	kindTable     = "table"
	kindComposite = "composite"
	kindIcon      = "icon"
)

// File is site/shots/scenes.yaml.
type File struct {
	// Repo is the GitHub repository the shots-* releases live on.
	Repo   string  `yaml:"repo"`
	Scenes []Scene `yaml:"scenes"`
	// dir is the directory the file was read from; scene paths are relative to it.
	dir string
}

// Scene is one published image and how it is made.
type Scene struct {
	Asset    string       `yaml:"asset"`
	Kind     string       `yaml:"kind"`
	Alt      string       `yaml:"alt"`
	Fixtures []FixtureRef `yaml:"fixtures"`
	// Clock is leylined --wall-clock, HH:MM. Only app scenes set it.
	Clock string `yaml:"clock"`
	// Bookmarks is a CHIRP CSV imported into the scene's own bookmarks file before anything runs.
	Bookmarks string    `yaml:"bookmarks"`
	Steps     []Step    `yaml:"steps"`
	Stage     *Stage    `yaml:"stage"`
	Crop      *Crop     `yaml:"crop"`
	Terminal  *Terminal `yaml:"terminal"`
	Table     *Table    `yaml:"table"`
	// Settle is the seconds a terminal waits after its last pane starts before it is read.
	Settle float64 `yaml:"settle"`
	// AI puts the assistant on a scripted model with a made-up key, as a check scene's ai does
	// (ai.go).
	AI *AISetup `yaml:"ai"`
	// Speech makes the scene's speech decoder the scripted engine (speech.go).
	Speech *SpeechSetup `yaml:"speech"`
	// App are commands sent to the running app over its command file once it is ready, as a
	// check scene's are (app/checks/scenes.yaml): the shot is the last snapshot's picture,
	// cropped, and nothing takes the focus. Without them the window is taken with screencapture
	// once its stage has settled.
	App []AppCommand `yaml:"app"`
}

// Name is the scene's name: its asset without the extension.
func (s *Scene) Name() string { return strings.TrimSuffix(s.Asset, filepath.Ext(s.Asset)) }

// FixtureRef is a leyfix catalog entry a scene plays. Rate and Duration apply to a fixture
// outside the scenes set, whose rate and length leyfix otherwise takes from its flags.
type FixtureRef struct {
	Name     string  `yaml:"name"`
	Rate     float64 `yaml:"rate"`
	Duration float64 `yaml:"duration"`
}

// Step is one thing a scene does before its shot: a `ley` command or a wait.
type Step struct {
	Ley  []string `yaml:"ley"`
	Wait float64  `yaml:"wait"`
}

// Size is a width and height in points.
type Size struct {
	Width  float64 `yaml:"width" json:"width"`
	Height float64 `yaml:"height" json:"height"`
}

// String is the size as a directory name: 1440x820.
func (s Size) String() string { return fmt.Sprintf("%gx%g", s.Width, s.Height) }

// Stage is the app's stage file (docs/dev/app.md, "Staged runs"). The JSON is what the app
// reads; ImportChirp is relative to scenes.yaml here and absolute in the file.
type Stage struct {
	Window         *Size   `yaml:"window" json:"window,omitempty"`
	Place          string  `yaml:"place" json:"place,omitempty"`
	Inspector      *bool   `yaml:"inspector" json:"inspector,omitempty"`
	ExpandedBand   string  `yaml:"expanded_band" json:"expanded_band,omitempty"`
	SelectBookmark string  `yaml:"select_bookmark" json:"select_bookmark,omitempty"`
	SelectPart     *int    `yaml:"select_part" json:"select_part,omitempty"`
	ImportChirp    string  `yaml:"import_chirp" json:"import_chirp,omitempty"`
	Settle         float64 `yaml:"settle" json:"settle,omitempty"`
	// OnAir holds the shot, after Settle, until the tuned channel's squelch is open.
	OnAir bool `yaml:"on_air" json:"on_air,omitempty"`
	// Zoom is the spectrum and waterfall's zoom, as the − and + buttons set it: 1, 2, 4 or 8.
	Zoom int `yaml:"zoom" json:"zoom,omitempty"`
	// ScanBand presses the expanded band row's Scan band and waits for the sweep to end.
	ScanBand bool `yaml:"scan_band" json:"scan_band,omitempty"`
	// PlayPart plays the selected part and pauses it, so the Library draws it as current.
	PlayPart bool `yaml:"play_part" json:"play_part,omitempty"`
	// Assistant shows or hides the assistant's panel, as its toolbar button does.
	Assistant *bool `yaml:"assistant" json:"assistant,omitempty"`
	// ChannelsPicker opens this sidebar row's Channels… popover, by the row's id.
	ChannelsPicker string `yaml:"channels_picker" json:"channels_picker,omitempty"`
	// FocusFilter gives the sidebar's filter the focus after Settle, as Go to… does.
	FocusFilter bool `yaml:"focus_filter" json:"focus_filter,omitempty"`
	// Settings opens the Settings window (true) or closes it (false), as ⌘, and its close
	// button do.
	Settings *bool `yaml:"settings" json:"settings,omitempty"`
}

// Crop says which part of the window an app shot keeps: the union of Regions, or a box of Size
// inside that union at Anchor.
type Crop struct {
	Regions []string `yaml:"regions"`
	Size    *Size    `yaml:"size"`
	// Anchor is top-left (the default), top-right, bottom-left, bottom-right or center.
	Anchor string `yaml:"anchor"`
}

// Terminal is the tmux window a terminal scene runs in.
type Terminal struct {
	Cols int `yaml:"cols"`
	Rows int `yaml:"rows"`
	// Split is horizontal (panes side by side) or vertical (stacked); empty for one pane.
	Split string `yaml:"split"`
	Panes []Pane `yaml:"panes"`
}

// Pane is one command in a terminal scene, typed at a prompt Delay seconds after the previous.
type Pane struct {
	Command string  `yaml:"command"`
	Delay   float64 `yaml:"delay"`
	// AfterApp types a composite's first pane once the app is showing, as the others are, rather
	// than before it starts: for a command the app is to be seen following.
	AfterApp bool `yaml:"after_app"`
}

// Table draws the first Rows rows of a CSV.
type Table struct {
	Source  string   `yaml:"source"`
	Rows    int      `yaml:"rows"`
	Columns []string `yaml:"columns"`
	// Width is the page width in points.
	Width float64 `yaml:"width"`
}

// regionNames are the regions regions.json can hold.
var regionNames = map[string]bool{
	"window": true, "toolbar": true, "sidebar": true, "inspector": true, "waterfall": true, "library": true, "notice": true, "parts": true,
	"spectrum": true, "readings": true, "transmissions": true, "heard": true, "log_day": true,
	"squelch": true,
}

// Load reads and validates a scenes file.
func Load(path string) (*File, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var f File
	dec := yaml.NewDecoder(strings.NewReader(string(b)))
	dec.KnownFields(true)
	if err := dec.Decode(&f); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	f.dir = filepath.Dir(path)
	if err := f.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &f, nil
}

// Path resolves a path in the scenes file against its directory.
func (f *File) Path(p string) string {
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	return filepath.Join(f.dir, p)
}

func (f *File) validate() error {
	if f.Repo == "" {
		return errors.New("repo is required")
	}
	seen := map[string]bool{}
	var errs []error
	for i := range f.Scenes {
		s := &f.Scenes[i]
		if err := s.validate(f); err != nil {
			errs = append(errs, fmt.Errorf("scene %s: %w", s.Asset, err))
		}
		if seen[s.Asset] {
			errs = append(errs, fmt.Errorf("scene %s appears twice", s.Asset))
		}
		seen[s.Asset] = true
	}
	return errors.Join(errs...)
}

func (s *Scene) validate(f *File) error {
	if s.Asset == "" || filepath.Ext(s.Asset) != ".png" || filepath.Base(s.Asset) != s.Asset {
		return fmt.Errorf("asset must be a file name ending .png, not %q", s.Asset)
	}
	if strings.TrimSpace(s.Alt) == "" {
		return errors.New("alt text is required")
	}
	needs := func(what string, ok bool) error {
		if !ok {
			return fmt.Errorf("a %s scene needs %s", s.Kind, what)
		}
		return nil
	}
	var err error
	switch s.Kind {
	case kindApp:
		err = errors.Join(needs("a stage", s.Stage != nil), needs("a crop", s.Crop != nil), needs("fixtures", len(s.Fixtures) > 0))
	case kindTerminal:
		err = errors.Join(needs("a terminal", s.Terminal != nil), needs("fixtures", len(s.Fixtures) > 0))
	case kindComposite:
		err = errors.Join(needs("a stage", s.Stage != nil), needs("a crop", s.Crop != nil),
			needs("a terminal", s.Terminal != nil), needs("fixtures", len(s.Fixtures) > 0))
	case kindTable:
		err = needs("a table with a source", s.Table != nil && s.Table.Source != "")
		if err == nil {
			if _, serr := os.Stat(f.Path(s.Table.Source)); serr != nil {
				err = serr
			}
		}
	case kindIcon:
	default:
		return fmt.Errorf("unknown kind %q", s.Kind)
	}
	if err != nil {
		return err
	}
	if s.Clock != "" && s.tracks() {
		// `ley track --since` seeds from the real clock, so a shifted daemon can open a track
		// empty.
		return errors.New("a scene whose terminal runs ley track may not set clock")
	}
	if s.Clock != "" && s.Kind != kindApp && s.Kind != kindComposite && s.Kind != kindTerminal {
		return fmt.Errorf("a %s scene has no daemon to set the clock of", s.Kind)
	}
	if s.AI != nil {
		if err := s.AI.validate(f.Path); err != nil {
			return err
		}
	}
	if s.Speech != nil {
		if err := s.Speech.validate(f.Path); err != nil {
			return err
		}
	}
	if err := s.validateApp(f.Path); err != nil {
		return err
	}
	if s.Terminal != nil {
		t := s.Terminal
		if t.Cols <= 0 || t.Rows <= 0 || len(t.Panes) == 0 {
			return errors.New("a terminal needs cols, rows and at least one pane")
		}
		if len(t.Panes) > 1 && t.Split != "horizontal" && t.Split != "vertical" {
			return errors.New("a terminal with two panes needs split: horizontal or vertical")
		}
	}
	if s.Crop != nil {
		if len(s.Crop.Regions) == 0 {
			return errors.New("a crop needs at least one region")
		}
		for _, r := range s.Crop.Regions {
			if !regionNames[r] {
				return fmt.Errorf("unknown region %q", r)
			}
		}
		switch s.Crop.Anchor {
		case "", "top-left", "top-right", "bottom-left", "bottom-right", "center":
		default:
			return fmt.Errorf("unknown crop anchor %q", s.Crop.Anchor)
		}
	}
	if s.Stage != nil {
		if err := s.Stage.validate(f.Path); err != nil {
			return err
		}
	}
	return validateSetup(f.Path, s.Bookmarks, s.Steps)
}

// tracks reports whether one of the scene's panes runs ley track.
func (s *Scene) tracks() bool {
	if s.Terminal == nil {
		return false
	}
	for _, p := range s.Terminal.Panes {
		if f := strings.Fields(p.Command); len(f) >= 2 && f[0] == "ley" && f[1] == "track" {
			return true
		}
	}
	return false
}

// validateApp checks the scene's app commands: only an app or composite scene has them, each is
// a check scene's command, a snapshot gives the shot, and a composite's first pane waits for the
// app only when the app is driven.
func (s *Scene) validateApp(path func(string) string) error {
	if s.Terminal != nil && len(s.Terminal.Panes) > 0 && s.Terminal.Panes[0].AfterApp && (s.Kind != kindComposite || len(s.App) == 0) {
		return errors.New("after_app is for the first pane of a composite scene with app commands")
	}
	if len(s.App) == 0 {
		return nil
	}
	if s.Kind != kindApp && s.Kind != kindComposite {
		return fmt.Errorf("a %s scene has no app to send commands to", s.Kind)
	}
	snapshot := false
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
		switch c.Cmd {
		case "snapshot":
			snapshot = true
		case "ax", "relaunch":
			// An ax tree is compared with a golden, which a shot has none of; a relaunch would
			// leave the shot's app another process.
			return fmt.Errorf("app command %d: a site scene does not take %s", i+1, c.Cmd)
		}
	}
	if !snapshot {
		return errors.New("app commands need a snapshot, whose picture is the shot")
	}
	return nil
}

// validate checks a stage's place and that its CHIRP import exists, resolved by path.
func (st *Stage) validate(path func(string) string) error {
	if p := st.Place; p != "" && p != "radio" && p != "library" {
		return fmt.Errorf("place is radio or library, not %q", p)
	}
	if c := st.ImportChirp; c != "" {
		if _, err := os.Stat(path(c)); err != nil {
			return err
		}
	}
	return nil
}

// validateSetup checks that a scene's bookmarks file exists and that each step is one thing.
func validateSetup(path func(string) string, bookmarks string, steps []Step) error {
	if bookmarks != "" {
		if _, err := os.Stat(path(bookmarks)); err != nil {
			return err
		}
	}
	for i, st := range steps {
		if (len(st.Ley) > 0) == (st.Wait > 0) {
			return fmt.Errorf("step %d needs exactly one of ley and wait", i+1)
		}
	}
	return nil
}

// Select returns the scenes named in only (asset names with or without .png), or every scene
// when only is empty. An unknown name is an error, so a typo does not silently shoot nothing.
func (f *File) Select(only []string) ([]*Scene, error) {
	if len(only) == 0 {
		out := make([]*Scene, 0, len(f.Scenes))
		for i := range f.Scenes {
			out = append(out, &f.Scenes[i])
		}
		return out, nil
	}
	var out []*Scene
	for _, n := range only {
		n = strings.TrimSuffix(strings.TrimSpace(n), ".png")
		found := false
		for i := range f.Scenes {
			if f.Scenes[i].Name() == n {
				out = append(out, &f.Scenes[i])
				found = true
				break
			}
		}
		if !found {
			return nil, fmt.Errorf("no scene called %q; leyshots list shows them", n)
		}
	}
	return out, nil
}
