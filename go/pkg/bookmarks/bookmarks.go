// SPDX-License-Identifier: Apache-2.0

// Package bookmarks is the client-side store of the frequencies a person wants to come back to.
// A bookmark is user data, not daemon state: the daemon never sees bookmarks, because a user's
// choice of frequencies cannot be derived from captures and channels
// (docs/design/app-design-handoff.md, "Bands and bookmarks are files"). Both clients share the
// file -- `ley bookmarks` writes it and the Mac app's sidebar reads it -- so a bookmark added
// from a terminal appears in the window. go/pkg/labels uses the same pattern.
package bookmarks

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// BookmarksEnv overrides the store path; tests set it to a temp file.
const BookmarksEnv = "LEYLINE_BOOKMARKS"

// Bookmark is one kept frequency. Mode is the DemodMode enum's own name (NFM, AM, WFM, USB, LSB,
// CW), so the file reads the way the contract spells it and neither client needs a number table
// to understand it; BandwidthHz 0 means the mode's default, which is what the daemon would pick
// anyway and what keeps a bookmark right when a default changes.
type Bookmark struct {
	// ID is the map key on disk rather than a field of the record, so the file cannot hold a
	// bookmark whose id disagrees with where it is filed.
	ID          string `json:"-"`
	Name        string `json:"name"`
	Hz          uint64 `json:"hz"`
	Mode        string `json:"mode"`
	BandwidthHz uint32 `json:"bandwidth_hz"`
	UpdatedNs   int64  `json:"updated_ns"`
	// Extra holds the entry's keys this version does not know, as the file spelled them, and
	// save writes them back beside the known fields: the app and ley share one file, and an
	// older ley must never strip a newer app's fields (docs/design/channels.md, "Bookmarks gain
	// three fields"). Nil when the entry has none. Kept out of the JSON mapping so the known
	// fields cannot be shadowed by a stray copy under the same key.
	Extra map[string]json.RawMessage `json:"-"`
}

// storeFile is the on-disk shape: a map keyed by bookmark id, so a read-modify-write of one
// bookmark leaves the rest untouched and encoding/json writes the keys sorted, giving a stable
// file two clients can diff. Each entry is kept raw here and decoded twice by Open, once into a
// Bookmark and once into a map, because that is the only way encoding/json will say which keys
// it did not use.
type storeFile struct {
	Bookmarks map[string]json.RawMessage `json:"bookmarks"`
}

// knownKeys are the JSON keys Bookmark's own fields take, read off the struct so the list
// cannot drift from its tags when a field is added.
var knownKeys = func() map[string]bool {
	b, err := json.Marshal(Bookmark{})
	if err != nil {
		panic(err)
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		panic(err)
	}
	keys := make(map[string]bool, len(m))
	for k := range m {
		keys[k] = true
	}
	return keys
}()

// decodeEntry reads one on-disk entry into a Bookmark, filing whatever keys the struct did not
// take under Extra.
func decodeEntry(id string, raw json.RawMessage) (Bookmark, error) {
	var bm Bookmark
	if err := json.Unmarshal(raw, &bm); err != nil {
		return Bookmark{}, err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return Bookmark{}, err
	}
	for k := range all {
		if knownKeys[k] {
			delete(all, k)
		}
	}
	bm.ID = id
	if len(all) > 0 {
		bm.Extra = all
	}
	return bm, nil
}

// encodeEntry is decodeEntry's inverse: the known fields, then the extras under any key the
// known fields did not take, so a field this version owns is always written from the struct.
func encodeEntry(bm Bookmark) (map[string]json.RawMessage, error) {
	b, err := json.Marshal(bm)
	if err != nil {
		return nil, err
	}
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return nil, err
	}
	for k, v := range bm.Extra {
		if _, known := m[k]; !known {
			m[k] = v
		}
	}
	return m, nil
}

// Store is the bookmarks file loaded into memory. Each ley invocation opens it, mutates it and
// saves the whole file, so there is no long-lived writer to coordinate.
type Store struct {
	path      string
	bookmarks map[string]Bookmark
	// Now is the clock Add and Move stamp with, so a test can hold time still; nil means time.Now.
	Now func() time.Time
}

// DefaultPath is where bookmarks live when LEYLINE_BOOKMARKS is unset: beside labels.json, in
// ~/Library/Application Support/Leyline on macOS and $XDG_DATA_HOME (or ~/.local/share)
// elsewhere. The app reads this path, so the two clients share one file by sharing this rule.
func DefaultPath(goos string, getenv func(string) (string, bool)) string {
	if goos == "darwin" {
		return filepath.Join(homeDir(), "Library", "Application Support", "Leyline", "bookmarks.json")
	}
	if dir, ok := getenv("XDG_DATA_HOME"); ok && dir != "" {
		return filepath.Join(dir, "leyline", "bookmarks.json")
	}
	return filepath.Join(homeDir(), ".local", "share", "leyline", "bookmarks.json")
}

// ResolvePath is DefaultPath unless LEYLINE_BOOKMARKS overrides it.
func ResolvePath(getenv func(string) (string, bool)) string {
	if p, ok := getenv(BookmarksEnv); ok && p != "" {
		return p
	}
	return DefaultPath(runtime.GOOS, getenv)
}

// Open loads the store at path. A missing file is an empty store, not an error: nobody has kept
// a frequency yet. A malformed file is an error rather than silently discarded, because
// overwriting it on the next Add would lose the list a person built by hand.
func Open(path string) (*Store, error) {
	s := &Store{path: path, bookmarks: map[string]Bookmark{}}
	b, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return s, nil
	}
	if err != nil {
		return nil, err
	}
	var f storeFile
	if err := json.Unmarshal(b, &f); err != nil {
		return nil, err
	}
	for id, raw := range f.Bookmarks {
		bm, err := decodeEntry(id, raw)
		if err != nil {
			return nil, fmt.Errorf("bookmark %s: %w", id, err)
		}
		s.bookmarks[id] = bm
	}
	return s, nil
}

// Get returns the bookmark with an id, and false when there is none.
func (s *Store) Get(id string) (Bookmark, bool) {
	bm, ok := s.bookmarks[id]
	return bm, ok
}

// List returns every bookmark, ordered by frequency and then by name: the dial's own order, so
// the list reads as a band plan rather than as the order somebody happened to add them in, and
// two runs never reshuffle it.
func (s *Store) List() []Bookmark {
	out := make([]Bookmark, 0, len(s.bookmarks))
	for _, bm := range s.bookmarks {
		out = append(out, bm)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Hz != out[j].Hz {
			return out[i].Hz < out[j].Hz
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// Add keeps a frequency under a name and persists the file. A name is required: the list is read
// by a person, and "146.940 MHz" is what the frequency column already shows.
//
// Adding the same name at the same frequency updates that bookmark rather than making a second
// one, so running the same command twice, as a shell history or a script does, does not fill
// the sidebar with duplicates. Two names at one frequency are kept, because a
// repeater and its net are two things a person may want listed separately.
func (s *Store) Add(name string, hz uint64, mode leylinev1.DemodMode, bandwidthHz uint32) (Bookmark, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return Bookmark{}, errors.New("a bookmark needs a name: what you would look for in the list")
	}
	if mode == leylinev1.DemodMode_DEMOD_MODE_UNSPECIFIED {
		return Bookmark{}, fmt.Errorf("a bookmark needs a mode: one of %s", strings.Join(ModeNames(), ", "))
	}
	bm := Bookmark{
		ID:          leyline.NewID("bm_"),
		Name:        name,
		Hz:          hz,
		Mode:        mode.String(),
		BandwidthHz: bandwidthHz,
		UpdatedNs:   s.now().UnixNano(),
	}
	// An update in place replaces the record, so it carries the old entry's extras with its id:
	// re-running the add that named a bookmark is not a request to drop the app's fields on it.
	for _, old := range s.bookmarks {
		if old.Hz == hz && old.Name == name {
			bm.ID = old.ID
			bm.Extra = old.Extra
			break
		}
	}
	s.bookmarks[bm.ID] = bm
	return bm, s.save()
}

// Remove deletes the bookmark an argument names and persists the file. An id is exact; failing
// that a name is, and failing that a name in any case, provided exactly one bookmark matches. An
// argument that matches several names is refused with those names rather than removing a guess,
// because the store has no undo for a delete.
func (s *Store) Remove(idOrName string) (Bookmark, error) {
	bm, err := s.resolve(idOrName, "remove")
	if err != nil {
		return Bookmark{}, err
	}
	delete(s.bookmarks, bm.ID)
	return bm, s.save()
}

// Move re-files the bookmark an argument names at another frequency and persists the file. The
// id, name, mode and width stay -- it is the same bookmark, on a new spot of the dial, which is
// what a repeater that changed its output or a station kept from a mistyped number needs -- and
// the stamp moves with it. The argument is resolved the way Remove resolves one.
//
// Two names at one frequency are allowed, as Add allows them; one name twice at one frequency is
// not, because Add folds that case into a single bookmark and Move must not bypass that rule.
func (s *Store) Move(idOrName string, hz uint64) (Bookmark, error) {
	bm, err := s.resolve(idOrName, "move")
	if err != nil {
		return Bookmark{}, err
	}
	for _, other := range s.bookmarks {
		if other.ID != bm.ID && other.Hz == hz && other.Name == bm.Name {
			return Bookmark{}, fmt.Errorf("%q is already kept at %s (%s); remove one of them first",
				bm.Name, leyline.FormatFrequency(hz), other.ID)
		}
	}
	bm.Hz = hz
	bm.UpdatedNs = s.now().UnixNano()
	s.bookmarks[bm.ID] = bm
	return bm, s.save()
}

// resolve finds the one bookmark an argument names: an id exactly, failing that a name exactly,
// failing that a name in any case, provided exactly one bookmark matches. The verb is for the
// refusal when several do, which tells the person to pick one by id.
func (s *Store) resolve(idOrName, verb string) (Bookmark, error) {
	arg := strings.TrimSpace(idOrName)
	if bm, ok := s.bookmarks[arg]; ok {
		return bm, nil
	}
	var exact, fold []Bookmark
	for _, bm := range s.List() {
		switch {
		case bm.Name == arg:
			exact = append(exact, bm)
		case strings.EqualFold(bm.Name, arg):
			fold = append(fold, bm)
		}
	}
	match := exact
	if len(match) == 0 {
		match = fold
	}
	switch len(match) {
	case 1:
		return match[0], nil
	case 0:
		return Bookmark{}, fmt.Errorf("no bookmark called %q; ley bookmarks lists them", idOrName)
	default:
		names := make([]string, 0, len(match))
		for _, bm := range match {
			names = append(names, fmt.Sprintf("%s (%s)", bm.ID, leyline.FormatFrequency(bm.Hz)))
		}
		return Bookmark{}, fmt.Errorf("%q names %d bookmarks; %s one by id: %s",
			idOrName, len(match), verb, strings.Join(names, ", "))
	}
}

// ModeNames lists the modes a bookmark may carry, in the spelling the file uses.
func ModeNames() []string {
	return []string{
		leylinev1.DemodMode_NFM.String(),
		leylinev1.DemodMode_AM.String(),
		leylinev1.DemodMode_WFM.String(),
		leylinev1.DemodMode_USB.String(),
		leylinev1.DemodMode_LSB.String(),
		leylinev1.DemodMode_CW.String(),
	}
}

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// save writes the whole file atomically: a temp file in the same directory then a rename, so a
// crash mid-write can never leave a half-written file that Open would then reject -- and the app,
// which reloads when the file changes, never reads a truncated one.
func (s *Store) save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	entries := make(map[string]map[string]json.RawMessage, len(s.bookmarks))
	for id, bm := range s.bookmarks {
		m, err := encodeEntry(bm)
		if err != nil {
			return err
		}
		entries[id] = m
	}
	b, err := json.MarshalIndent(struct {
		Bookmarks map[string]map[string]json.RawMessage `json:"bookmarks"`
	}{entries}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".bookmarks-*.tmp")
	if err != nil {
		return err
	}
	tmpName := tmp.Name()
	defer func() { _ = os.Remove(tmpName) }()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpName, s.path)
}

func homeDir() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	return os.TempDir()
}
