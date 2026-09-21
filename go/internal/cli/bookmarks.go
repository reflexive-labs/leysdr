// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/bookmarks"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// bookmarkJSON is the `--json` shape of `ley bookmarks`: the fields the file holds, plus the id
// it is filed under. Like presets and bands it is client-local data with no proto message, so it
// goes out through encoding/json; unlike them, it is the table a person writes.
type bookmarkJSON struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Hz          uint64 `json:"hz"`
	Mode        string `json:"mode"`
	BandwidthHz uint32 `json:"bandwidth_hz"`
	UpdatedNs   int64  `json:"updated_ns"`
}

func bookmarkRow(b bookmarks.Bookmark) bookmarkJSON {
	return bookmarkJSON{ID: b.ID, Name: b.Name, Hz: b.Hz, Mode: b.Mode, BandwidthHz: b.BandwidthHz, UpdatedNs: b.UpdatedNs}
}

// newBookmarksCommand builds `ley bookmarks`, the third client-local table and the only one a
// person writes. It is one file both clients own: `ley` writes it here and the Mac app's sidebar
// reads it, so a frequency kept from a terminal is in the window (docs/design/
// app-design-handoff.md, "Bands and bookmarks are files").
func newBookmarksCommand(app *App) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "bookmarks",
		Short: "List the frequencies you have kept",
		Long: `bookmarks lists the frequencies you asked ley to remember, lowest first,
with the mode and bandwidth to tune each one with. They are your data, not the
daemon's: they live in a small JSON file ($LEYLINE_BOOKMARKS overrides its
path) that the Mac app reads too, so a frequency kept here is in its sidebar
and one kept there is in this list.

'ley bookmarks add' keeps one, 'ley bookmarks move' re-files it at another
frequency and 'ley bookmarks remove' forgets it. A bookmark is a name, a
frequency, a mode and a bandwidth; nothing is tuned, started or measured by
any of the four.

--json prints an array of {id, name, hz, mode, bandwidth_hz, updated_ns} in
the same order, the fields the file holds: mode is the contract's spelling
(NFM), and bandwidth_hz 0 means the mode's usual width.`,
		Example: `  ley bookmarks                                      # the table
  ley bookmarks add 146.94 --name "Local repeater"   # keep one
  ley bookmarks move "Local repeater" 147.0          # same bookmark, new frequency
  ley bookmarks remove "Local repeater"              # forget it
  ley bookmarks --json | jq -r '.[] | "\(.hz) \(.name)"'`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			store, err := openBookmarks(app)
			if err != nil {
				return err
			}
			list := store.List()
			if app.JSON {
				out := make([]bookmarkJSON, 0, len(list))
				for _, b := range list {
					out = append(out, bookmarkRow(b))
				}
				return app.printArray(out)
			}
			return printBookmarkTable(app, list)
		},
	}
	cmd.AddCommand(newBookmarksAddCommand(app), newBookmarksMoveCommand(app), newBookmarksRemoveCommand(app))
	return cmd
}

func newBookmarksAddCommand(app *App) *cobra.Command {
	var name, mode, bw string
	cmd := &cobra.Command{
		Use:   "add <frequency|preset> --name NAME",
		Short: "Keep a frequency under a name",
		Long: `add keeps a frequency so you can find it again by name. The frequency is
read the way 'ley tune' reads one: a bare number is MHz (146.94), a unit is
exact (162550k), and a preset name (noaa, marine16) stands for its frequency.

The mode comes from the band table when --mode is not given, the same lookup
tune does, and the bandwidth is left as the mode's usual width unless --bw
says otherwise -- so a bookmark keeps following the defaults rather than
freezing today's.

Adding the same name at the same frequency updates that bookmark instead of
making a second one.`,
		Example: `  ley bookmarks add 146.94 --name "Local repeater"
  ley bookmarks add noaa --name "Weather"
  ley bookmarks add 121.5 --name Guard --mode am --bw 10
  ley bookmarks add 145.8 --name "ISS" --json | jq -r .id`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			return runBookmarkAdd(app, arg, name, mode, bw)
		},
	}
	cmd.Flags().StringVar(&name, "name", "", "what to call it in the list, e.g. --name \"Local repeater\" (required)")
	cmd.Flags().StringVar(&mode, "mode", "", "how to decode it: nfm, wfm, am, usb, lsb, cw (default: by band, as tune does)")
	cmd.Flags().StringVar(&bw, "bw", "", "how wide a slice to listen to: a bare number is kHz (12.5), or 200k (default: the mode's usual width)")
	return cmd
}

func newBookmarksMoveCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "move <id|name> <frequency|preset>",
		Short: "Re-file a bookmark at another frequency",
		Long: `move gives a bookmark a new frequency and keeps everything else: the id,
the name, the mode and the bandwidth. It is for a repeater that changed its
output and a number that was typed wrong, where forgetting the bookmark and
keeping it again would hand it a new id.

The bookmark is named the way remove names one, by id or by name in any
case, and the frequency is read the way add reads one: a bare number is MHz
(147.0), a unit is exact (147000k), and a preset name stands for its
frequency. Moving onto a frequency another bookmark holds is fine; moving
onto one the same name already holds is refused, because that is one
bookmark twice.`,
		Example: `  ley bookmarks move "Local repeater" 147.0
  ley bookmarks move bm_01J8Z6R9TC7QK3W4M5N6P7Q8R9 146940k`,
		Args: cobra.ExactArgs(2),
		RunE: func(_ *cobra.Command, args []string) error {
			return runBookmarkMove(app, args[0], args[1])
		},
	}
}

func newBookmarksRemoveCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "remove <id|name>",
		Short: "Forget a bookmark",
		Long: `remove takes a bookmark's id or its name. A name in any case is enough
while only one bookmark answers to it; when two do, remove names them and
removes nothing, because this is the one thing here that cannot be undone.`,
		Example: `  ley bookmarks remove "Local repeater"
  ley bookmarks remove bm_01J8Z6R9TC7QK3W4M5N6P7Q8R9`,
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			return runBookmarkRemove(app, args[0])
		},
	}
}

// openBookmarks loads the store, naming the file when it cannot be read: a malformed file is
// refused rather than overwritten, so the message has to say which one to fix.
func openBookmarks(app *App) (*bookmarks.Store, error) {
	path := bookmarks.ResolvePath(app.LookupEnv)
	store, err := bookmarks.Open(path)
	if err != nil {
		return nil, fmt.Errorf("cannot read the bookmarks file %s: %w", path, err)
	}
	return store, nil
}

// runBookmarkAdd resolves the frequency and mode the way `ley tune` does, so a bookmark tunes to
// what tuning the same argument would have done.
func runBookmarkAdd(app *App, arg, nameFlag, modeFlag, bwFlag string) error {
	if nameFlag == "" {
		return usageErrorf("a bookmark needs a name: ley bookmarks add %s --name \"Local repeater\"", orDefault(arg, "146.94"))
	}
	t, err := resolveDialTarget(arg, "bookmarks add", "ley bookmarks add 146.94 --name \"Local repeater\"", "146.94 (MHz)")
	if err != nil {
		return err
	}
	mode, reason, err := bookmarkMode(t, modeFlag)
	if err != nil {
		return err
	}
	var bw uint32
	if bwFlag != "" {
		bw, err = leyline.ParseBandwidth(bwFlag)
		if err != nil {
			return usageError(fmt.Errorf("--bw %w (examples: 12.5, 12.5k, 200k, 12500)", err))
		}
	}
	store, err := openBookmarks(app)
	if err != nil {
		return err
	}
	b, err := store.Add(nameFlag, t.Hz, mode, bw)
	if err != nil {
		return usageError(err)
	}
	if app.JSON {
		return app.printArray(bookmarkRow(b))
	}
	s := app.Style
	fmt.Fprintf(app.Stdout, "%s  %s  %s  %s\n", b.Name, leyline.FormatFrequency(b.Hz),
		leyline.ModeName(mode), bookmarkBandwidth(s, b))
	if reason != "" {
		fmt.Fprintf(app.Stdout, "  %s\n", s.Muted(reason))
	}
	// The next command echoes what was typed rather than the formatted frequency: "146.940 MHz"
	// is two arguments at a prompt, and a preset name is shorter than either.
	fmt.Fprintf(app.Stdout, "  %s\n", s.Cmd("ley tune "+arg))
	return nil
}

// bookmarkMode applies tune's precedence: --mode, then a preset's own mode, then the band table.
// The reason is kept so the screen says where an unasked-for mode came from.
func bookmarkMode(t dialTarget, modeFlag string) (leylinev1.DemodMode, string, error) {
	if modeFlag != "" {
		m, reason, err := leyline.ResolveMode(modeFlag, t.Hz)
		if err != nil {
			return 0, "", usageError(fmt.Errorf("--mode %w", err))
		}
		return m, reason, nil
	}
	if t.Preset != nil && t.Preset.Mode != leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		return t.Preset.Mode, "preset " + t.Preset.Name + ": " + t.Preset.Description, nil
	}
	m, band := leyline.DefaultMode(t.Hz)
	if band != nil {
		return m, band.Name + " band default", nil
	}
	return m, "no band recognised, using NFM", nil
}

func runBookmarkRemove(app *App, arg string) error {
	store, err := openBookmarks(app)
	if err != nil {
		return err
	}
	b, err := store.Remove(arg)
	if err != nil {
		return usageError(err)
	}
	if app.JSON {
		return app.printArray(bookmarkRow(b))
	}
	fmt.Fprintf(app.Stdout, "%s\n", app.Style.Muted(fmt.Sprintf("forgot %s (%s)", b.Name, leyline.FormatFrequency(b.Hz))))
	return nil
}

// runBookmarkMove resolves the frequency the way add does, so the bookmark lands where tuning the
// same argument would; the store resolves the bookmark the way remove does.
func runBookmarkMove(app *App, arg, freq string) error {
	t, err := resolveDialTarget(freq, "bookmarks move", `ley bookmarks move "Local repeater" 147.0`, "147.0 (MHz)")
	if err != nil {
		return err
	}
	store, err := openBookmarks(app)
	if err != nil {
		return err
	}
	b, err := store.Move(arg, t.Hz)
	if err != nil {
		return usageError(err)
	}
	if app.JSON {
		return app.printArray(bookmarkRow(b))
	}
	s := app.Style
	fmt.Fprintf(app.Stdout, "%s  %s  %s  %s\n", b.Name, leyline.FormatFrequency(b.Hz),
		bookmarkModeName(b), bookmarkBandwidth(s, b))
	fmt.Fprintf(app.Stdout, "  %s\n", s.Cmd("ley tune "+freq))
	return nil
}

// printBookmarkTable renders `ley bookmarks`. The name leads, because it is what the list is for;
// the id is last and droppable, since remove takes the name whenever one bookmark answers to it.
func printBookmarkTable(app *App, list []bookmarks.Bookmark) error {
	s := tableStyle(app)
	cols := []column{
		{head: "NAME"},
		{head: "FREQUENCY"},
		{head: "MODE"},
		{head: "BANDWIDTH", drop: 1},
		{head: "ID", min: 8, drop: 2},
	}
	for _, b := range list {
		add(cols, b.Name, leyline.FormatFrequency(b.Hz), bookmarkModeName(b),
			bookmarkBandwidth(s, b), s.Muted(b.ID))
	}
	if _, err := printColumns(app.Stdout, s, cols, nil); err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted(`(no bookmarks; ley bookmarks add 146.94 --name "Local repeater" keeps one)`))
	}
	return nil
}

// bookmarkModeName prints the mode the way every other ley table does (lower case); the file and
// --json keep the contract's own spelling, which is what the app parses.
func bookmarkModeName(b bookmarks.Bookmark) string {
	m, err := leyline.ParseMode(b.Mode)
	if err != nil {
		return b.Mode
	}
	return leyline.ModeName(m)
}

// bookmarkBandwidth shows what tuning this bookmark would use. A stored 0 is "the mode's usual
// width", so the width is printed Muted rather than left as a dash: the number is real, it is
// just not one the person chose.
func bookmarkBandwidth(s ui.Style, b bookmarks.Bookmark) string {
	if b.BandwidthHz > 0 {
		return formatBandwidth(b.BandwidthHz)
	}
	m, err := leyline.ParseMode(b.Mode)
	if err != nil {
		return s.Glyphs().Absent
	}
	return s.Muted(formatBandwidth(leyline.DefaultBandwidth(m)))
}

// orDefault is the argument to echo back in a usage error, or an example when there was none.
func orDefault(arg, example string) string {
	if arg == "" {
		return example
	}
	return arg
}
