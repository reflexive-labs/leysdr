// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/pkg/bookmarks"
	"github.com/dpup/leysdr/go/pkg/chirp"
)

// runBookmarks runs ley against a temp bookmarks file, the store's own override, and never dials:
// bookmarks are client-local data and no verb of the three reaches the daemon.
func runBookmarks(t *testing.T, path string, args ...string) (string, string, error) {
	t.Helper()
	app := &App{
		Socket: "/nonexistent/leyline-bookmarks.sock",
		LookupEnv: func(k string) (string, bool) {
			if k == bookmarks.BookmarksEnv {
				return path, true
			}
			return "", false
		},
	}
	return runApp(t, app, args...)
}

func mustBookmarks(t *testing.T, path string, args ...string) string {
	t.Helper()
	out, errOut, err := runBookmarks(t, path, args...)
	if err != nil {
		t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
	}
	return out
}

// The three verbs round-trip: an empty list says how to make one, add takes tune's frequencies
// and the band table's mode, the list is in frequency order, and remove takes the name.
func TestBookmarksRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")

	empty := mustBookmarks(t, path, "bookmarks")
	if !strings.Contains(empty, "NAME") || !strings.Contains(empty, "no bookmarks") {
		t.Fatalf("an empty list keeps its headers and says what to type:\n%s", empty)
	}

	added := mustBookmarks(t, path, "bookmarks", "add", "146.94", "--name", "Local repeater")
	if !strings.Contains(added, "146.940 MHz") || !strings.Contains(added, "nfm") {
		t.Fatalf("add must confirm what it kept:\n%s", added)
	}
	if !strings.Contains(added, "2 m amateur band default") {
		t.Fatalf("add must say where an unasked-for mode came from:\n%s", added)
	}
	// The next command has to be typable: "ley tune 146.940 MHz" is two arguments.
	if !strings.Contains(added, "ley tune 146.94\n") {
		t.Fatalf("add must end with a command that parses:\n%s", added)
	}
	// A preset resolves like tune's positional, mode included.
	if out := mustBookmarks(t, path, "bookmarks", "add", "noaa", "--name", "Weather"); !strings.Contains(out, "162.550 MHz") {
		t.Fatalf("a preset must resolve:\n%s", out)
	}
	if out := mustBookmarks(t, path, "bookmarks", "add", "121.5", "--name", "Guard"); !strings.Contains(out, " am ") {
		t.Fatalf("the airband default is AM:\n%s", out)
	}
	// Under --band the positional is a channel of that band's plan (the plan's KTD8).
	if out := mustBookmarks(t, path, "bookmarks", "add", "5", "--band", "gmrs", "--name", "x"); !strings.Contains(out, "462.6625 MHz") || !strings.Contains(out, "preset ch5") {
		t.Fatalf("5 under --band gmrs is GMRS channel 5:\n%s", out)
	}
	if _, _, err := runBookmarks(t, path, "bookmarks", "add", "99", "--band", "gmrs", "--name", "y"); err == nil || !strings.Contains(err.Error(), "GMRS") {
		t.Fatalf("a channel the plan lacks is refused with the band named: %v", err)
	}
	// A channel's own width is kept (MURS 1 is 11.25 kHz, not the band's 12.5), where a band's
	// default is left at 0 so the bookmark keeps following the table.
	if out := mustBookmarks(t, path, "bookmarks", "add", "1", "--band", "murs", "--name", "m"); !strings.Contains(out, "11.25 kHz") || !strings.Contains(out, "ley tune 1 --band murs\n") {
		t.Fatalf("MURS 1 keeps its own width:\n%s", out)
	}
	mustBookmarks(t, path, "bookmarks", "remove", "x")
	mustBookmarks(t, path, "bookmarks", "remove", "m")

	list := mustBookmarks(t, path, "bookmarks")
	rows := strings.Split(strings.TrimSpace(list), "\n")
	if len(rows) != 4 {
		t.Fatalf("want a header and three rows:\n%s", list)
	}
	if !strings.HasPrefix(rows[1], "Guard") || !strings.Contains(rows[3], "Weather") {
		t.Fatalf("the list is ordered by frequency:\n%s", list)
	}

	out := mustBookmarks(t, path, "--json", "bookmarks")
	var got []bookmarkJSON
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("bookmarks --json: %v\n%s", err, out)
	}
	if len(got) != 3 || got[0].Name != "Guard" || got[0].Hz != 121_500_000 {
		t.Fatalf("bookmarks --json: %+v", got)
	}
	// The JSON carries the file's own spelling of the mode, which is what the app parses.
	if got[0].Mode != "AM" || got[0].BandwidthHz != 0 || !strings.HasPrefix(got[0].ID, "bm_") {
		t.Fatalf("bookmarks --json record: %+v", got[0])
	}

	if out := mustBookmarks(t, path, "bookmarks", "remove", "weather"); !strings.Contains(out, "Weather") {
		t.Fatalf("remove must name what it forgot:\n%s", out)
	}
	if left := mustBookmarks(t, path, "--json", "bookmarks"); strings.Contains(left, "Weather") {
		t.Fatalf("the removed bookmark is still listed: %s", left)
	}
}

// An empty list is an empty array, not null: a script that iterates gets nothing rather than an
// error. And a name is required, with the command to run spelled out.
func TestBookmarksEmptyJSONAndMissingName(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	if out := mustBookmarks(t, path, "--json", "bookmarks"); strings.TrimSpace(out) != "[]" {
		t.Errorf("an empty store prints [], got %q", out)
	}
	_, errOut, err := runBookmarks(t, path, "bookmarks", "add", "146.94")
	if err == nil {
		t.Fatalf("add without a name must fail; stderr=%q", errOut)
	}
	if !strings.Contains(err.Error(), "--name") {
		t.Errorf("the error must show the flag: %v", err)
	}
	// A refused add writes nothing, so a mistyped command does not create the file.
	if out := mustBookmarks(t, path, "--json", "bookmarks"); strings.TrimSpace(out) != "[]" {
		t.Errorf("a refused add must leave the store empty, got %q", out)
	}
}

// move keeps the bookmark's id, name, mode and width and changes the frequency, in every spelling
// add reads: bare MHz, a unit, bare Hz. The list shows it at the new spot, and an unknown name
// is refused the way remove refuses one.
func TestBookmarksMove(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	mustBookmarks(t, path, "bookmarks", "add", "146.94", "--name", "Local repeater", "--bw", "12.5")
	mustBookmarks(t, path, "bookmarks", "add", "noaa", "--name", "Weather")

	var before []bookmarkJSON
	if err := json.Unmarshal([]byte(mustBookmarks(t, path, "--json", "bookmarks")), &before); err != nil {
		t.Fatal(err)
	}

	moved := mustBookmarks(t, path, "bookmarks", "move", "local repeater", "147.0")
	if !strings.Contains(moved, "Local repeater") || !strings.Contains(moved, "147.000 MHz") || !strings.Contains(moved, "nfm") {
		t.Fatalf("move must confirm what it kept and where:\n%s", moved)
	}
	if !strings.Contains(moved, "ley tune 147.0\n") {
		t.Fatalf("move must end with a command that parses:\n%s", moved)
	}
	if out := mustBookmarks(t, path, "bookmarks", "move", "Local repeater", "147500k"); !strings.Contains(out, "147.500 MHz") {
		t.Fatalf("a unit is exact:\n%s", out)
	}
	if out := mustBookmarks(t, path, "bookmarks", "move", "Local repeater", "147600000"); !strings.Contains(out, "147.600 MHz") {
		t.Fatalf("a bare number over 100 kHz is Hz:\n%s", out)
	}

	list := mustBookmarks(t, path, "bookmarks")
	rows := strings.Split(strings.TrimSpace(list), "\n")
	if len(rows) != 3 || !strings.HasPrefix(rows[1], "Local repeater") || !strings.Contains(rows[1], "147.600 MHz") {
		t.Fatalf("the list shows the bookmark at its new frequency, in order:\n%s", list)
	}

	var after []bookmarkJSON
	if err := json.Unmarshal([]byte(mustBookmarks(t, path, "--json", "bookmarks")), &after); err != nil {
		t.Fatal(err)
	}
	was, is := before[0], after[0]
	if was.Name != "Local repeater" || is.Name != "Local repeater" {
		t.Fatalf("before %+v, after %+v", before, after)
	}
	if is.ID != was.ID || is.Mode != was.Mode || is.BandwidthHz != 12_500 || is.Hz != 147_600_000 {
		t.Fatalf("a move keeps the id, mode and width: %+v became %+v", was, is)
	}
	if is.UpdatedNs <= was.UpdatedNs {
		t.Errorf("the stamp must move: %d then %d", was.UpdatedNs, is.UpdatedNs)
	}
	if len(after) != 2 || after[1].Name != "Weather" || after[1].Hz != 162_550_000 {
		t.Errorf("the other bookmark is untouched: %+v", after)
	}

	out := mustBookmarks(t, path, "--json", "bookmarks", "move", "Weather", "162.4")
	var one bookmarkJSON
	if err := json.Unmarshal([]byte(out), &one); err != nil || one.Hz != 162_400_000 || one.ID != after[1].ID {
		t.Fatalf("move --json prints the record it touched: %v\n%s", err, out)
	}

	_, _, err := runBookmarks(t, path, "bookmarks", "move", "Guard", "121.5")
	if err == nil || !strings.Contains(err.Error(), `no bookmark called "Guard"`) {
		t.Errorf("an unknown name is refused the way remove refuses it, got %v", err)
	}
	_, _, err = runBookmarks(t, path, "bookmarks", "move", "Weather", "1,2")
	if err == nil || !strings.Contains(err.Error(), "147.0") {
		t.Errorf("a frequency that does not parse shows what one looks like, got %v", err)
	}
}

// add --tone, --note and --tag write the fields; the list grows the TONE, NOTE and TAGS columns
// only once some bookmark has them, --tag filters, --json carries the fields, and an invalid tone
// is refused with the sentence the app's validator shares, before the file is touched.
func TestBookmarksToneNoteAndTags(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	mustBookmarks(t, path, "bookmarks", "add", "noaa", "--name", "Weather")
	plain := mustBookmarks(t, path, "bookmarks")
	for _, head := range []string{"TONE", "NOTE", "TAGS"} {
		if strings.Contains(plain, head) {
			t.Errorf("a list with no %s shows no %s column:\n%s", strings.ToLower(head), head, plain)
		}
	}

	_, _, err := runBookmarks(t, path, "bookmarks", "add", "146.94", "--name", "r", "--tone", "100")
	if err == nil || err.Error() != "tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N" {
		t.Fatalf("--tone 100 is refused with the shared sentence, got %v", err)
	}
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != ExitUsage {
		t.Errorf("an invalid tone is a usage error, got %#v", err)
	}
	if out := mustBookmarks(t, path, "--json", "bookmarks"); strings.Contains(out, `"r"`) {
		t.Fatalf("a refused add writes nothing:\n%s", out)
	}

	added := mustBookmarks(t, path, "bookmarks", "add", "146.94", "--name", "r", "--tone", "100.0", "--note", "club", "--tag", "home", "--tag", "vhf")
	if !strings.Contains(added, "PL 100.0") || !strings.Contains(added, "146.940 MHz") {
		t.Fatalf("the confirmation names the tone:\n%s", added)
	}

	list := mustBookmarks(t, path, "bookmarks")
	rows := strings.Split(strings.TrimSpace(list), "\n")
	if len(rows) != 3 || !strings.Contains(rows[0], "TONE") || !strings.Contains(rows[0], "NOTE") || !strings.Contains(rows[0], "TAGS") {
		t.Fatalf("the list shows the three columns once a bookmark has them:\n%s", list)
	}
	if !strings.Contains(rows[1], "PL 100.0") || !strings.Contains(rows[1], "club") || !strings.Contains(rows[1], "home, vhf") {
		t.Fatalf("the row carries the tone in words, the note and the tags:\n%s", list)
	}

	filtered := mustBookmarks(t, path, "bookmarks", "--tag", "home")
	if strings.Contains(filtered, "Weather") || !strings.Contains(filtered, "146.940 MHz") {
		t.Fatalf("--tag home lists only the bookmarks tagged home:\n%s", filtered)
	}
	if out := mustBookmarks(t, path, "--json", "bookmarks", "--tag", "nobody"); strings.TrimSpace(out) != "[]" {
		t.Errorf("a tag nothing carries lists nothing, got %q", out)
	}

	var got []bookmarkJSON
	if err := json.Unmarshal([]byte(mustBookmarks(t, path, "--json", "bookmarks")), &got); err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Tone != "100.0" || got[0].Note != "club" || len(got[0].Tags) != 2 || got[0].Tags[0] != "home" {
		t.Fatalf("--json carries the fields: %+v", got)
	}
	// A bookmark without the fields carries no keys for them, so the shape stays the older one.
	raw := mustBookmarks(t, path, "--json", "bookmarks", "--tag", "home")
	for _, k := range []string{`"tone":"100.0"`, `"note":"club"`, `"tags":["home","vhf"]`} {
		if !strings.Contains(raw, k) {
			t.Errorf("--json lacks %s:\n%s", k, raw)
		}
	}
	if strings.Contains(raw, "offset_hz") || strings.Contains(raw, "duplex") {
		t.Errorf("fields nothing set are left out of --json:\n%s", raw)
	}

	// Re-running the add keeps what was set; a second --tag joins the set.
	again := mustBookmarks(t, path, "--json", "bookmarks", "add", "146.94", "--name", "r", "--tag", "uhf")
	var one bookmarkJSON
	if err := json.Unmarshal([]byte(again), &one); err != nil || one.Tone != "100.0" || one.Note != "club" || len(one.Tags) != 3 {
		t.Fatalf("an update keeps the fields and adds the tag: %v\n%s", err, again)
	}
}

// import reads a CHIRP export into the store: the counts go to stderr with one line per skipped
// row, --json is {added, updated, skipped, warnings}, --dry-run prints the same and writes
// nothing, and a file with no Frequency column is refused with the file untouched.
func TestBookmarksImport(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	const sample = "../../../fixtures/chirp/sample.csv"

	out, errOut, err := runBookmarks(t, path, "bookmarks", "import", sample, "--dry-run")
	if err != nil {
		t.Fatalf("dry run: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "8 added, 1 updated, 1 skipped") || !strings.Contains(errOut, "sample.csv") || !strings.Contains(errOut, "nothing written") {
		t.Fatalf("a dry run prints the counts and says it wrote nothing:\nstdout: %s\nstderr: %s", out, errOut)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("a dry run must not write the file: %v", err)
	}

	out, errOut, err = runBookmarks(t, path, "bookmarks", "import", sample)
	if err != nil {
		t.Fatalf("import: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "Imported 9 from sample.csv") || !strings.Contains(errOut, "8 added, 1 updated, 1 skipped") {
		t.Fatalf("the counts go to stderr:\nstdout: %s\nstderr: %s", out, errOut)
	}
	if !strings.Contains(errOut, `line 9: frequency "abc" is not a number`) || !strings.Contains(errOut, `line 10: mode "DV"`) {
		t.Fatalf("each skipped row and each warning is one line with its line number:\n%s", errOut)
	}
	if !strings.Contains(errOut, "ley bookmarks --tag sample") {
		t.Fatalf("the import ends with the command that lists what it filed:\n%s", errOut)
	}
	if out != "" {
		t.Errorf("stdout carries nothing without --json: %q", out)
	}
	list := mustBookmarks(t, path, "bookmarks", "--tag", "sample")
	for _, want := range []string{"Club", "PL 100.0", "club repeater", "ch5", "445.925 MHz", "DCS 754"} {
		if !strings.Contains(list, want) {
			t.Errorf("the list lacks %q:\n%s", want, list)
		}
	}

	// A second import updates every row and adds nothing; --json carries the rows.
	out, _, err = runBookmarks(t, path, "--json", "bookmarks", "import", sample)
	if err != nil {
		t.Fatal(err)
	}
	var got struct {
		Added    []bookmarkJSON  `json:"added"`
		Updated  []bookmarkJSON  `json:"updated"`
		Skipped  []chirp.Skipped `json:"skipped"`
		Warnings []chirp.Skipped `json:"warnings"`
	}
	if err := json.Unmarshal([]byte(out), &got); err != nil {
		t.Fatalf("--json: %v\n%s", err, out)
	}
	if len(got.Added) != 0 || len(got.Updated) != 9 || len(got.Skipped) != 1 || len(got.Warnings) != 1 {
		t.Fatalf("--json counts: %+v", got)
	}
	if got.Skipped[0].Line != 9 || got.Skipped[0].Reason != `frequency "abc" is not a number` {
		t.Errorf("skipped = %+v", got.Skipped)
	}
	if got.Updated[0].Name != "Club" || got.Updated[0].Tone != "100.0" || got.Updated[0].OffsetHz != -600_000 || got.Updated[0].Duplex != "-" {
		t.Errorf("the rows are in bookmarks' --json shape: %+v", got.Updated[0])
	}
	if !strings.HasPrefix(out, `{"added":[],"updated":[{"id":"bm_`) {
		t.Errorf("an empty list is [], and the keys are in the documented order:\n%s", out)
	}

	// Not a CHIRP export: refused as a usage error, with the store as it was.
	before, _ := os.ReadFile(path)
	notCSV := filepath.Join(t.TempDir(), "memories.csv")
	if err := os.WriteFile(notCSV, []byte("Name,Mode\nA,FM\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err = runBookmarks(t, path, "bookmarks", "import", notCSV)
	var ee *ExitError
	if err == nil || !errors.As(err, &ee) || ee.Code != ExitUsage {
		t.Fatalf("a file with no Frequency column is a usage error, got %#v", err)
	}
	if want := notCSV + " has no Frequency column; is it a CHIRP CSV export?"; err.Error() != want {
		t.Errorf("refusal = %q, want %q", err.Error(), want)
	}
	if after, _ := os.ReadFile(path); string(after) != string(before) {
		t.Errorf("a refused import must leave the file as it was")
	}
	if _, _, err := runBookmarks(t, path, "bookmarks", "import", filepath.Join(t.TempDir(), "missing.csv")); err == nil || !errors.As(err, &ee) || ee.Code != ExitUsage {
		t.Errorf("a missing file is a usage error, got %v", err)
	}
}
