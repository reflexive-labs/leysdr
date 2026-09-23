// SPDX-License-Identifier: Apache-2.0

package labels

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// A name that is set is read back by a fresh open, a clear removes it, and an empty name is a
// clear too, so `ley label id ""` and --clear reach one place.
func TestStoreSetGetDeleteAndReload(t *testing.T) {
	path := filepath.Join(t.TempDir(), "labels.json")
	s, err := Open(path)
	if err != nil {
		t.Fatalf("open empty: %v", err)
	}
	if _, ok := s.Get("LEYTST-1"); ok {
		t.Fatalf("an empty store has no labels")
	}
	if _, err := s.Set("LEYTST-1", "greenhouse", "aprs"); err != nil {
		t.Fatalf("set: %v", err)
	}
	// A fresh open reads the file, proving the write persisted.
	s2, err := Open(path)
	if err != nil {
		t.Fatalf("reopen: %v", err)
	}
	l, ok := s2.Get("LEYTST-1")
	if !ok || l.Name != "greenhouse" || l.Protocol != "aprs" || l.DeviceID != "LEYTST-1" {
		t.Fatalf("reloaded label = %+v (ok=%v)", l, ok)
	}
	if l.UpdatedNs == 0 {
		t.Errorf("a set label carries when it was set")
	}
	// An empty name deletes.
	if _, err := s2.Set("LEYTST-1", "", ""); err != nil {
		t.Fatalf("clear via empty name: %v", err)
	}
	if _, ok := s2.Get("LEYTST-1"); ok {
		t.Errorf("an empty name must clear the label")
	}
}

// Delete reports whether there was a label to remove, so a caller can say "there was none".
func TestStoreDeleteReports(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "labels.json"))
	if had, _ := s.Delete("nobody"); had {
		t.Errorf("delete of an absent label reports false")
	}
	_, _ = s.Set("LEYTST-2", "car", "")
	if had, _ := s.Delete("LEYTST-2"); !had {
		t.Errorf("delete of a present label reports true")
	}
}

// All is sorted by device id, so a listing is stable between runs.
func TestStoreAllSorted(t *testing.T) {
	s, _ := Open(filepath.Join(t.TempDir(), "labels.json"))
	_, _ = s.Set("LEYTST-3", "c", "")
	_, _ = s.Set("LEYTST-1", "a", "")
	_, _ = s.Set("LEYTST-2", "b", "")
	all := s.All()
	if len(all) != 3 || all[0].DeviceID != "LEYTST-1" || all[2].DeviceID != "LEYTST-3" {
		t.Fatalf("All is not sorted: %+v", all)
	}
}

// A missing file is an empty store, not an error; a malformed file is an error rather than a
// silent overwrite that would lose a user's labels.
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

// DefaultPath follows the platform data dir, and ResolvePath lets $LEYLINE_LABELS override it.
func TestPathResolution(t *testing.T) {
	getenv := func(m map[string]string) func(string) (string, bool) {
		return func(k string) (string, bool) { v, ok := m[k]; return v, ok }
	}
	mac := DefaultPath("darwin", getenv(nil))
	if filepath.Base(mac) != "labels.json" || !strings.Contains(mac, "Application Support") || !strings.Contains(mac, "Leyline") {
		t.Errorf("darwin path = %q", mac)
	}
	xdg := DefaultPath("linux", getenv(map[string]string{"XDG_DATA_HOME": "/x"}))
	if xdg != "/x/leyline/labels.json" {
		t.Errorf("xdg path = %q", xdg)
	}
	if got := ResolvePath(getenv(map[string]string{"LEYLINE_LABELS": "/tmp/l.json"})); got != "/tmp/l.json" {
		t.Errorf("override = %q", got)
	}
}
