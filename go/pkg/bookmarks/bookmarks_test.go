// SPDX-License-Identifier: Apache-2.0

package bookmarks

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// fixed is a clock held still, so a test can assert the stamp a bookmark carries.
func fixed(s *Store) *Store {
	s.Now = func() time.Time { return time.Unix(1_758_200_000, 0) }
	return s
}

// sameBookmark compares the fields a bookmark is made of. Bookmark holds a map, so it is not
// comparable with ==; the extras' round trip is asserted on the file, where it matters.
func sameBookmark(a, b Bookmark) bool {
	return a.ID == b.ID && a.Name == b.Name && a.Hz == b.Hz && a.Mode == b.Mode &&
		a.BandwidthHz == b.BandwidthHz && a.UpdatedNs == b.UpdatedNs
}

// foreignFixture is one entry carrying three keys this store does not know. The Swift store's
// test loads the identical literal, so both readers are held to one file
// (docs/design/channels.md, "Bookmarks gain three fields"): "tone" is a field a later version
// adopts, the other two are anything a newer client might write.
const foreignFixture = `{"bookmarks": {"bm_01J8ZZZZZZZZZZZZZZZZZZZZZ1": {"name": "Local repeater", "hz": 146940000, "mode": "NFM", "bandwidth_hz": 12500, "updated_ns": 1700000000000000000, "tone": "100.0", "lists": ["x"], "zzz": {"a": 1}}}}`

const foreignID = "bm_01J8ZZZZZZZZZZZZZZZZZZZZZ1"

// openForeign writes the fixture to a temp path and opens it with a held clock.
func openForeign(t *testing.T) (*Store, string) {
	t.Helper()
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	if err := os.WriteFile(path, []byte(foreignFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	return fixed(s), path
}

// rawEntries reads the file back through encoding/json alone, so the assertion is on what the
// other client will see and not on what this package thinks it wrote.
func rawEntries(t *testing.T, path string) map[string]map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Bookmarks map[string]map[string]any `json:"bookmarks"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("the file must be JSON: %v\n%s", err, b)
	}
	return f.Bookmarks
}

// wantForeign asserts the fixture's three foreign keys are in a record with their values.
func wantForeign(t *testing.T, rec map[string]any) {
	t.Helper()
	want := map[string]any{"tone": "100.0", "lists": []any{"x"}, "zzz": map[string]any{"a": float64(1)}}
	for k, v := range want {
		if got, ok := rec[k]; !ok || !reflect.DeepEqual(got, v) {
			t.Errorf("foreign key %q = %v (present=%v), want %v", k, got, ok, v)
		}
	}
}

// A fresh open reads back an added bookmark, with the shape the app parses: keyed by
// a bm_ ULID, the mode spelled as the enum names it, and a bandwidth of 0 for "the mode's default".
func TestAddReloadAndFileShape(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open empty: %v", err)
	}
	if len(s.List()) != 0 {
		t.Fatalf("an empty store has no bookmarks")
	}
	bm, err := fixed(s).Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 12_500)
	if err != nil {
		t.Fatalf("add: %v", err)
	}
	if !strings.HasPrefix(bm.ID, "bm_") || len(bm.ID) != len("bm_")+26 {
		t.Errorf("id = %q, want a bm_ ULID", bm.ID)
	}
	if bm.Mode != "NFM" || bm.UpdatedNs != time.Unix(1_758_200_000, 0).UnixNano() {
		t.Errorf("bookmark = %+v", bm)
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	got, ok := s2.Get(bm.ID)
	if !ok || !sameBookmark(got, bm) {
		t.Fatalf("reloaded = %+v (ok=%v), want %+v", got, ok, bm)
	}

	// The file is the contract the app reads, so its keys are asserted rather than inferred.
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Bookmarks map[string]map[string]any `json:"bookmarks"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatalf("the file must be JSON: %v\n%s", err, b)
	}
	rec, ok := f.Bookmarks[bm.ID]
	if !ok {
		t.Fatalf("the file is keyed by bookmark id:\n%s", b)
	}
	for _, k := range []string{"name", "hz", "mode", "bandwidth_hz", "updated_ns"} {
		if _, ok := rec[k]; !ok {
			t.Errorf("the record has no %q: %v", k, rec)
		}
	}
	if len(rec) != 5 {
		t.Errorf("the record carries five fields, got %v", rec)
	}
}

// The same name at the same frequency updates the one bookmark, so running a command twice does
// not make two rows; the same name elsewhere is a second bookmark, because a net and a repeater
// are two entries.
func TestAddIsIdempotentOnNameAndFrequency(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "bookmarks.json"))
	first, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 0)
	if err != nil {
		t.Fatal(err)
	}
	again, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 12_500)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != first.ID || len(s.List()) != 1 {
		t.Fatalf("a repeat must update in place: %+v then %+v (%d bookmarks)", first, again, len(s.List()))
	}
	if again.BandwidthHz != 12_500 {
		t.Errorf("the update must carry the new bandwidth: %+v", again)
	}
	if _, err := s.Add("Local repeater", 147_000_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	if len(s.List()) != 2 {
		t.Errorf("the same name elsewhere is a second bookmark: %+v", s.List())
	}
}

// A name is required, and so is a mode: neither has a sensible default here.
func TestAddRefusesAnEmptyNameOrMode(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "bookmarks.json"))
	if _, err := s.Add("  ", 146_940_000, leylinev1.DemodMode_NFM, 0); err == nil {
		t.Errorf("an empty name must be refused")
	}
	if _, err := s.Add("x", 146_940_000, leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED, 0); err == nil {
		t.Errorf("an unspecified mode must be refused")
	}
}

// List is ordered by frequency and then by name: the dial's order, stable between runs.
func TestListSortedByFrequencyThenName(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "bookmarks.json"))
	_, _ = s.Add("net", 146_940_000, leylinev1.DemodMode_NFM, 0)
	_, _ = s.Add("calling", 146_520_000, leylinev1.DemodMode_NFM, 0)
	_, _ = s.Add("Alpha", 146_940_000, leylinev1.DemodMode_NFM, 0)
	got := s.List()
	if len(got) != 3 || got[0].Name != "calling" || got[1].Name != "Alpha" || got[2].Name != "net" {
		t.Fatalf("List order = %+v", got)
	}
}

// Remove takes an id, an exact name, or a name in any case when only one answers to it; an
// ambiguous name names the candidates instead of deleting a guess.
func TestRemoveByIDNameAndCase(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "bookmarks.json"))
	byID, _ := s.Add("one", 146_520_000, leylinev1.DemodMode_NFM, 0)
	if _, err := s.Remove(byID.ID); err != nil {
		t.Fatalf("remove by id: %v", err)
	}
	_, _ = s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 0)
	if _, err := s.Remove("local REPEATER"); err != nil {
		t.Fatalf("remove by name, any case: %v", err)
	}
	if len(s.List()) != 0 {
		t.Fatalf("both removes should have landed: %+v", s.List())
	}

	a, _ := s.Add("Repeater", 146_940_000, leylinev1.DemodMode_NFM, 0)
	b, _ := s.Add("repeater", 147_000_000, leylinev1.DemodMode_NFM, 0)
	_, err := s.Remove("REPEATER")
	if err == nil {
		t.Fatalf("an ambiguous name must be refused")
	}
	if !strings.Contains(err.Error(), a.ID) || !strings.Contains(err.Error(), b.ID) {
		t.Errorf("the error must name the candidates: %v", err)
	}
	// The exact spelling is not ambiguous, even when another differs only in case.
	if _, err := s.Remove("repeater"); err != nil {
		t.Errorf("an exact name wins over a case-insensitive one: %v", err)
	}
	if _, err := s.Remove("nobody"); err == nil {
		t.Errorf("removing what is not there must be an error")
	}
}

// Move keeps the bookmark -- its id, name, mode and width -- and changes only the frequency and
// the stamp; the argument resolves the way Remove's does, and the same refusal names a bookmark
// that is not there.
func TestMoveKeepsTheBookmarkAndChangesTheFrequency(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	s, _ := Open(path)
	fixed(s)
	added, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 12_500)
	if err != nil {
		t.Fatal(err)
	}
	s.Now = func() time.Time { return time.Unix(1_758_200_060, 0) }
	moved, err := s.Move("local REPEATER", 147_000_000)
	if err != nil {
		t.Fatalf("move by name, any case: %v", err)
	}
	if moved.ID != added.ID || moved.Name != added.Name || moved.Mode != added.Mode || moved.BandwidthHz != added.BandwidthHz {
		t.Errorf("a move keeps the bookmark: %+v became %+v", added, moved)
	}
	if moved.Hz != 147_000_000 {
		t.Errorf("hz = %d, want 147000000", moved.Hz)
	}
	if moved.UpdatedNs != time.Unix(1_758_200_060, 0).UnixNano() {
		t.Errorf("the stamp must move with the bookmark: %+v", moved)
	}
	s2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if got, ok := s2.Get(added.ID); !ok || !sameBookmark(got, moved) || len(s2.List()) != 1 {
		t.Fatalf("reloaded = %+v (ok=%v, %d bookmarks), want %+v", got, ok, len(s2.List()), moved)
	}
	if _, err := s.Move(added.ID, 146_520_000); err != nil {
		t.Errorf("move by id: %v", err)
	}

	_, err = s.Move("Weather", 162_550_000)
	if err == nil || !strings.Contains(err.Error(), `no bookmark called "Weather"`) {
		t.Errorf("an unknown name is refused the way remove refuses it, got %v", err)
	}
	// Another name at the target frequency is fine, as Add allows; the same name there is not,
	// because Add would have folded the two into one.
	if _, err := s.Add("Calling", 146_520_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	if _, err := s.Move("Calling", 146_940_000); err != nil {
		t.Errorf("two names at one frequency are kept: %v", err)
	}
	if _, err := s.Move(added.ID, 146_940_000); err == nil {
		t.Errorf("one name twice at one frequency must be refused")
	}
}

// A key this store does not know rides through load and save untouched, so an older ley never
// strips a newer app's fields (docs/design/channels.md, "Bookmarks gain three fields"). Adding
// another bookmark rewrites the whole file, which is where the fixture's keys would be lost; the
// new entry gains nothing it was not given.
func TestUnknownKeysSurviveAddingAnother(t *testing.T) {
	s, path := openForeign(t)
	second, err := s.Add("Calling", 146_520_000, leylinev1.DemodMode_NFM, 0)
	if err != nil {
		t.Fatal(err)
	}
	recs := rawEntries(t, path)
	first, ok := recs[foreignID]
	if !ok {
		t.Fatalf("the fixture's entry is gone: %v", recs)
	}
	wantForeign(t, first)
	rec := recs[second.ID]
	for _, k := range []string{"tone", "lists", "zzz"} {
		if _, ok := rec[k]; ok {
			t.Errorf("the new entry must not carry %q: %v", k, rec)
		}
	}
	if len(rec) != 5 {
		t.Errorf("an entry with no extras carries five fields, got %v", rec)
	}
}

// Add's update-in-place replaces the record, and must carry the extras across: a person who
// re-runs the add that named the entry has not asked for its tone to go.
func TestUnknownKeysSurviveAddUpdateInPlace(t *testing.T) {
	s, path := openForeign(t)
	again, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 25_000)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != foreignID {
		t.Fatalf("the same name and frequency updates in place, got %+v", again)
	}
	recs := rawEntries(t, path)
	rec := recs[foreignID]
	wantForeign(t, rec)
	if rec["bandwidth_hz"] != float64(25_000) {
		t.Errorf("the update must land beside the extras: %v", rec)
	}
}

// Move changes the frequency and the stamp; everything else in the record, known or not, stays.
func TestUnknownKeysSurviveMove(t *testing.T) {
	s, path := openForeign(t)
	if _, err := s.Move(foreignID, 147_000_000); err != nil {
		t.Fatal(err)
	}
	rec := rawEntries(t, path)[foreignID]
	wantForeign(t, rec)
	if rec["hz"] != float64(147_000_000) {
		t.Errorf("the move must land beside the extras: %v", rec)
	}
}

// A foreign key is written back byte-for-byte, so a version that adopts it as a known key
// ("tone" is one, docs/design/channels.md, "Bookmarks gain three fields") reads the file this
// version wrote without a migration: the string stays a string, and a number a number.
func TestUnknownKeyWrittenBackByteForByte(t *testing.T) {
	s, path := openForeign(t)
	if _, err := s.Add("Calling", 146_520_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var f struct {
		Bookmarks map[string]map[string]json.RawMessage `json:"bookmarks"`
	}
	if err := json.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	rec := f.Bookmarks[foreignID]
	if got := string(rec["tone"]); got != `"100.0"` {
		t.Errorf("tone = %s, want the string \"100.0\" as the fixture spelled it", got)
	}
	var compact bytes.Buffer
	for _, k := range []string{"lists", "zzz"} {
		if err := json.Compact(&compact, rec[k]); err != nil {
			t.Fatalf("%s: %v", k, err)
		}
	}
	if compact.String() != `["x"]{"a":1}` {
		t.Errorf("lists and zzz = %s, want the fixture's values", compact.String())
	}
}

// A missing file is an empty store, not an error; a malformed one is an error rather than a
// silent reset that would lose the list.
func TestOpenMissingAndMalformed(t *testing.T) {
	if _, err := Open(filepath.Join(t.TempDir(), "nope.json")); err != nil {
		t.Errorf("a missing file must open empty: %v", err)
	}
	bad := filepath.Join(t.TempDir(), "bad.json")
	_ = os.WriteFile(bad, []byte("{not json"), 0o644)
	if _, err := Open(bad); err == nil {
		t.Errorf("a malformed file must be an error, not a silent reset")
	}
}

// DefaultPath puts bookmarks.json beside labels.json, and $LEYLINE_BOOKMARKS overrides it.
func TestPathResolution(t *testing.T) {
	getenv := func(m map[string]string) func(string) (string, bool) {
		return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
	}
	mac := DefaultPath("darwin", getenv(nil))
	if filepath.Base(mac) != "bookmarks.json" || !strings.Contains(mac, "Application Support") || !strings.Contains(mac, "Leyline") {
		t.Errorf("darwin path = %q", mac)
	}
	if xdg := DefaultPath("linux", getenv(map[string]string{"XDG_DATA_HOME": "/x"})); xdg != "/x/leyline/bookmarks.json" {
		t.Errorf("xdg path = %q", xdg)
	}
	if got := ResolvePath(getenv(map[string]string{"LEYLINE_BOOKMARKS": "/tmp/b.json"})); got != "/tmp/b.json" {
		t.Errorf("override = %q", got)
	}
}

// A key an older build filed under Extra is read into its field once the struct knows it: the
// fixture's "tone" is the case the design names (docs/design/channels.md, "Bookmarks gain three
// fields"), and the other two keys stay foreign. knownKeys is read off the struct's tags, so
// this is the test that an omitempty field is known even when its zero value is not written.
func TestForeignToneBecomesKnownOnLoad(t *testing.T) {
	s, _ := openForeign(t)
	bm, ok := s.Get(foreignID)
	if !ok {
		t.Fatal("the fixture's entry is missing")
	}
	if bm.Tone != "100.0" {
		t.Errorf("tone = %q, want the fixture's 100.0 read into the field", bm.Tone)
	}
	if _, still := bm.Extra["tone"]; still {
		t.Errorf("a known key must not also be filed under Extra: %v", bm.Extra)
	}
	for _, k := range []string{"lists", "zzz"} {
		if _, ok := bm.Extra[k]; !ok {
			t.Errorf("the foreign key %q must still be under Extra: %v", k, bm.Extra)
		}
	}
	for _, k := range []string{"tone", "note", "tags", "offset_hz", "duplex"} {
		if !knownKeys[k] {
			t.Errorf("%q must be a known key", k)
		}
	}
}

// SetFields writes the fields a person edits and the file carries them back: the tone is
// validated as the CLI and the app validate it, an empty string clears, nil leaves alone, and
// tags are a set, sorted and without repeats, whatever order they were given in.
func TestSetFieldsRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	s, _ := Open(path)
	fixed(s)
	added, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 0)
	if err != nil {
		t.Fatal(err)
	}
	tone, note := "D023N", "club repeater"
	got, err := s.SetFields("local REPEATER", &tone, &note, []string{"vhf", "home", "vhf", " home "})
	if err != nil {
		t.Fatalf("set fields: %v", err)
	}
	if got.ID != added.ID || got.Tone != "D023N" || got.Note != "club repeater" {
		t.Errorf("set fields = %+v", got)
	}
	if !reflect.DeepEqual(got.Tags, []string{"home", "vhf"}) {
		t.Errorf("tags = %v, want the sorted set [home vhf]", got.Tags)
	}
	// offset_hz and duplex are the import's fields; the store carries them as it carries the rest.
	got.OffsetHz, got.Duplex = -600_000, "-"
	s.bookmarks[got.ID] = got
	if err := s.save(); err != nil {
		t.Fatal(err)
	}

	s2, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	back, _ := s2.Get(added.ID)
	if back.Tone != "D023N" || back.Note != "club repeater" || !reflect.DeepEqual(back.Tags, []string{"home", "vhf"}) ||
		back.OffsetHz != -600_000 || back.Duplex != "-" || back.Extra != nil {
		t.Errorf("reloaded = %+v", back)
	}
	rec := rawEntries(t, path)[added.ID]
	for k, v := range map[string]any{"tone": "D023N", "note": "club repeater", "tags": []any{"home", "vhf"}, "offset_hz": float64(-600_000), "duplex": "-"} {
		if !reflect.DeepEqual(rec[k], v) {
			t.Errorf("file %q = %v, want %v", k, rec[k], v)
		}
	}

	// nil leaves a field alone, an empty string clears it, and more tags join the set.
	empty := ""
	got, err = s2.SetFields(added.ID, &empty, nil, []string{"uhf"})
	if err != nil {
		t.Fatal(err)
	}
	if got.Tone != "" || got.Note != "club repeater" || !reflect.DeepEqual(got.Tags, []string{"home", "uhf", "vhf"}) {
		t.Errorf("after clearing the tone = %+v", got)
	}
	if rec := rawEntries(t, path)[added.ID]; rec["tone"] != nil {
		t.Errorf("a cleared tone is written as no key, got %v", rec)
	}

	bad := "100"
	if _, err := s2.SetFields(added.ID, &bad, nil, nil); err == nil ||
		err.Error() != "tone must be a CTCSS tone such as 100.0 or a DCS code such as D023N" {
		t.Errorf("an invalid tone is refused with the shared sentence, got %v", err)
	}
	if bm, _ := s2.Get(added.ID); bm.Note != "club repeater" || bm.Tone != "" {
		t.Errorf("a refused edit changes nothing: %+v", bm)
	}
	if _, err := s2.SetFields("nobody", nil, nil, nil); err == nil {
		t.Errorf("an unknown bookmark is refused")
	}
}

// Add's update in place keeps the fields a person set, as it keeps the extras: re-running the
// add that named a bookmark is not a request to drop its tone or its tags.
func TestAddUpdateKeepsTheFields(t *testing.T) {
	s, path := openForeign(t)
	note := "club"
	if _, err := s.SetFields(foreignID, nil, &note, []string{"home"}); err != nil {
		t.Fatal(err)
	}
	again, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 25_000)
	if err != nil {
		t.Fatal(err)
	}
	if again.ID != foreignID || again.Tone != "100.0" || again.Note != "club" || !reflect.DeepEqual(again.Tags, []string{"home"}) {
		t.Errorf("the update must keep tone, note and tags: %+v", again)
	}
	rec := rawEntries(t, path)[foreignID]
	wantForeign(t, rec)
	if rec["note"] != "club" || rec["bandwidth_hz"] != float64(25_000) {
		t.Errorf("the update lands beside the fields: %v", rec)
	}
}
