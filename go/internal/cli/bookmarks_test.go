// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"

	"github.com/dpup/leysdr/go/pkg/bookmarks"
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
