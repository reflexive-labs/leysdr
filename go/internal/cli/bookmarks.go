// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"
	"slices"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/bookmarks"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// bookmarkJSON is the `--json` shape of `ley bookmarks`: the fields the file holds, plus the id
// it is filed under. Like presets and bands it is client-local data with no proto message, so it
// goes out through encoding/json; unlike them, the user edits it. The optional fields are left
// out as the file leaves them out, so a record without them keeps the older shape.
type bookmarkJSON struct {
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Hz          uint64   `json:"hz"`
	Mode        string   `json:"mode"`
	BandwidthHz uint32   `json:"bandwidth_hz"`
	UpdatedNs   int64    `json:"updated_ns"`
	Tone        string   `json:"tone,omitempty"`
	Note        string   `json:"note,omitempty"`
	Tags        []string `json:"tags,omitempty"`
	OffsetHz    int64    `json:"offset_hz,omitempty"`
	Duplex      string   `json:"duplex,omitempty"`
}

func bookmarkRow(b bookmarks.Bookmark) bookmarkJSON {
	return bookmarkJSON{
		ID: b.ID, Name: b.Name, Hz: b.Hz, Mode: b.Mode, BandwidthHz: b.BandwidthHz, UpdatedNs: b.UpdatedNs,
		Tone: b.Tone, Note: b.Note, Tags: b.Tags, OffsetHz: b.OffsetHz, Duplex: b.Duplex,
	}
}

// bookmarkFields are the optional fields `add` sets after the bookmark is kept: a tone and a
// note when the flag was given, and the tags to join the bookmark's set.
type bookmarkFields struct {
	tone, note string
	tags       []string
}

func (f bookmarkFields) empty() bool {
	return f.tone == "" && f.note == "" && len(f.tags) == 0
}

// newBookmarksCommand builds `ley bookmarks`, the third client-local table and the only one the
// user edits. Both clients share one file: `ley` writes it here and the Mac app's sidebar reads
// it, so a bookmark added from the terminal shows up in the app (docs/design/
// app-design-handoff.md, "Bands and bookmarks are files").
func newBookmarksCommand(app *App) *cobra.Command {
	var tag string
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
frequency, a mode and a bandwidth, and can carry the tone a repeater
requires, a note and tags (add --tone, --note and --tag). The TONE, NOTE and
TAGS columns appear once a bookmark has one, and --tag lists only the
bookmarks filed under that word. Nothing is tuned, started or measured by
any of the four verbs, and a tone is a record of what the repeater uses:
ley does not gate audio on it.

--json prints an array of {id, name, hz, mode, bandwidth_hz, updated_ns} in
the same order, the fields the file holds: mode is the contract's spelling
(NFM), and bandwidth_hz 0 means the mode's usual width. A record that has
them carries tone (as CHIRP spells it: 100.0, D023N), note, tags, offset_hz
and duplex as well.`,
		Example: `  ley bookmarks                                      # the table
  ley bookmarks --tag home                           # only those filed under home
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
			if tag != "" {
				list = slices.DeleteFunc(list, func(b bookmarks.Bookmark) bool {
					return !slices.Contains(b.Tags, tag)
				})
			}
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
	cmd.Flags().StringVar(&tag, "tag", "", "list only the bookmarks filed under this tag, spelled as add --tag gave it")
	cmd.AddCommand(newBookmarksAddCommand(app), newBookmarksMoveCommand(app), newBookmarksRemoveCommand(app))
	return cmd
}

func newBookmarksAddCommand(app *App) *cobra.Command {
	var name, mode, bw, band string
	var fields bookmarkFields
	cmd := &cobra.Command{
		Use:   "add <frequency|preset|channel --band BAND> --name NAME",
		Short: "Keep a frequency under a name",
		Long: `add keeps a frequency so you can find it again by name. The frequency is
read the way 'ley tune' reads one: a bare number is MHz (146.94), a unit is
exact (162550k), and a preset name (noaa, marine16) stands for its frequency.
With --band the argument is a channel of that band's plan as its radios print
it: 'ley bookmarks add 5 --band gmrs' is GMRS channel 5.

The mode comes from the band table when --mode is not given, the same lookup
tune does, and the bandwidth is left as the mode's usual width unless --bw
says otherwise -- so a bookmark keeps following the defaults rather than
freezing today's.

--tone records the tone the repeater requires on its input, spelled as
CHIRP spells one: a CTCSS tone with one decimal (100.0) or a DCS code as
D023N or D023I. It is kept beside the frequency and nothing gates audio on
it. --note is free text, and --tag, given once per word, files the bookmark
under words 'ley bookmarks --tag' lists by.

Adding the same name at the same frequency updates that bookmark instead of
making a second one, and keeps the tone, note and tags it had; a --tag joins
them.`,
		Example: `  ley bookmarks add 146.94 --name "Local repeater"
  ley bookmarks add 146.94 --name "Local repeater" --tone 100.0 --note "600 kHz down" --tag home
  ley bookmarks add noaa --name "Weather"
  ley bookmarks add 5 --band gmrs --name "Channel 5"
  ley bookmarks add 121.5 --name Guard --mode am --bw 10
  ley bookmarks add 145.8 --name "ISS" --json | jq -r .id`,
		Args: cobra.MaximumNArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			arg := ""
			if len(args) == 1 {
				arg = args[0]
			}
			return runBookmarkAdd(app, arg, name, mode, bw, band, fields)
		},
	}
	cmd.Flags().StringVar(&name, "name", "", "what to call it in the list, e.g. --name \"Local repeater\" (required)")
	cmd.Flags().StringVar(&band, "band", "", "read the argument as a channel of this band's plan, as its radios print it: --band marine 16, --band gmrs 5 (ley bands)")
	cmd.Flags().StringVar(&mode, "mode", "", "how to decode it: nfm, wfm, am, usb, lsb, cw (default: by band, as tune does)")
	cmd.Flags().StringVar(&bw, "bw", "", "how wide a slice to listen to: a bare number is kHz (12.5), or 200k (default: the mode's usual width)")
	cmd.Flags().StringVar(&fields.tone, "tone", "", "the tone the repeater requires, as CHIRP spells it: a CTCSS tone (100.0) or a DCS code (D023N, D023I)")
	cmd.Flags().StringVar(&fields.note, "note", "", "free text kept beside it, e.g. --note \"600 kHz down, club net Tuesdays\"")
	cmd.Flags().StringArrayVar(&fields.tags, "tag", nil, "a word to file it under; repeat for more: --tag home --tag vhf (ley bookmarks --tag home)")
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
func runBookmarkAdd(app *App, arg, nameFlag, modeFlag, bwFlag, bandFlagValue string, fields bookmarkFields) error {
	if nameFlag == "" {
		return usageErrorf("a bookmark needs a name: ley bookmarks add %s --name \"Local repeater\"", orDefault(arg, "146.94"))
	}
	// The tone is checked before the store is opened, so a mistyped one leaves the file as it
	// was; the sentence is the one the app's validator prints (docs/design/channels.md,
	// "Bookmarks gain three fields").
	if fields.tone != "" {
		if _, err := leyline.ParseTone(fields.tone); err != nil {
			return usageError(err)
		}
	}
	band, err := bandFlag(bandFlagValue)
	if err != nil {
		return err
	}
	t, err := resolveDialTarget(arg, "bookmarks add", "ley bookmarks add 146.94 --name \"Local repeater\"", "146.94 (MHz)", band)
	if err != nil {
		return err
	}
	mode, reason, err := bookmarkMode(t, modeFlag)
	if err != nil {
		return err
	}
	var bw uint32
	switch {
	case bwFlag != "":
		bw, err = leyline.ParseBandwidth(bwFlag)
		if err != nil {
			return usageError(fmt.Errorf("--bw %w (examples: 12.5, 12.5k, 200k, 12500)", err))
		}
	case t.Preset != nil && mode == t.Preset.Mode:
		// A channel's own width is part of what the channel is (MURS 1 is
		// 11.25 kHz) and is kept; a band's default is left at 0 so the bookmark
		// keeps following the table (docs/design/channels.md, "The plan is data
		// in the band table").
		if _, c, ok := leyline.ChannelAt(t.Hz); ok && c.BandwidthHz != 0 {
			bw = c.BandwidthHz
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
	if !fields.empty() {
		var tone, note *string
		if fields.tone != "" {
			tone = &fields.tone
		}
		if fields.note != "" {
			note = &fields.note
		}
		if b, err = store.SetFields(b.ID, tone, note, fields.tags); err != nil {
			return usageError(err)
		}
	}
	if app.JSON {
		return app.printArray(bookmarkRow(b))
	}
	s := app.Style
	line := []string{b.Name, leyline.FormatFrequency(b.Hz), leyline.ModeName(mode), bookmarkBandwidth(s, b)}
	if b.Tone != "" {
		line = append(line, bookmarkTone(b))
	}
	fmt.Fprintln(app.Stdout, strings.Join(line, "  "))
	if reason != "" {
		fmt.Fprintf(app.Stdout, "  %s\n", s.Muted(reason))
	}
	// The next command echoes what was typed rather than the formatted frequency: "146.940 MHz"
	// is two arguments at a prompt, and a preset name is shorter than either. A channel named
	// under --band needs the band again.
	next := "ley tune " + arg
	if band != nil {
		next += " --band " + bandFlagValue
	}
	fmt.Fprintf(app.Stdout, "  %s\n", s.Cmd(next))
	return nil
}

// bookmarkMode applies tune's precedence: --mode, then a preset's own mode, then the band table.
// The reason is kept so the output shows where a mode the user did not pass came from.
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
	t, err := resolveDialTarget(freq, "bookmarks move", `ley bookmarks move "Local repeater" 147.0`, "147.0 (MHz)", nil)
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

// printBookmarkTable renders `ley bookmarks`. The name comes first because users look bookmarks
// up by name; the id is last and droppable, since remove accepts the name whenever it matches
// exactly one bookmark. TONE, NOTE and TAGS are shown only when some bookmark has one, so a
// list that never used them keeps its width (docs/design/channels.md, "The CLI"); on a narrow
// terminal the note goes before the tags and the id before both, the free text being the widest
// and the least often read.
func printBookmarkTable(app *App, list []bookmarks.Bookmark) error {
	s := tableStyle(app)
	cols := []column{
		{head: "NAME"},
		{head: "FREQUENCY"},
		{head: "MODE"},
		{head: "BANDWIDTH", drop: 1},
		{head: "TONE", hideEmpty: true},
		{head: "NOTE", min: 14, drop: 3, hideEmpty: true},
		{head: "TAGS", min: 8, drop: 2, hideEmpty: true},
		{head: "ID", min: 8, drop: 4},
	}
	absent := s.Glyphs().Absent
	for _, b := range list {
		tone, note, tags := absent, absent, absent
		if b.Tone != "" {
			tone = bookmarkTone(b)
		}
		if b.Note != "" {
			note = b.Note
		}
		if len(b.Tags) > 0 {
			tags = strings.Join(b.Tags, ", ")
		}
		add(cols, b.Name, leyline.FormatFrequency(b.Hz), bookmarkModeName(b),
			bookmarkBandwidth(s, b), tone, note, tags, s.Muted(b.ID))
	}
	if _, err := printColumns(app.Stdout, s, cols, nil); err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Fprintln(app.Stdout, s.Muted(`(no bookmarks; ley bookmarks add 146.94 --name "Local repeater" keeps one)`))
	}
	return nil
}

// bookmarkTone is a bookmark's tone in words, "PL 100.0" or "DCS 023 inverted", the words the
// app shows for a heard tone. A spelling this build cannot read (the file is shared, and the
// other client may be newer) is printed as the file has it rather than hidden.
func bookmarkTone(b bookmarks.Bookmark) string {
	t, err := leyline.ParseTone(b.Tone)
	if err != nil {
		return b.Tone
	}
	return t.Words()
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
// width", so the width is printed Muted rather than left as a dash: the value is real but was
// not set by the user.
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
