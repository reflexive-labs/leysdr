// SPDX-License-Identifier: Apache-2.0

package bookmarks

import (
	"encoding/json"
	"os"
	"path/filepath"
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

// A bookmark added is a bookmark a fresh open reads back, with the shape the app parses: keyed by
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
	if !ok || got != bm {
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

// A name is required, and so is a mode: neither has an honest default here.
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
	if got, ok := s2.Get(added.ID); !ok || got != moved || len(s2.List()) != 1 {
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
