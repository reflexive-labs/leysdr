// SPDX-License-Identifier: Apache-2.0

// Package labels is the client-side store of the human names a person gives the transmitters a
// decoder discovers. Labels are user data, not daemon state: the design boundary keeps the
// registry a deterministic fold over the record log and puts the one piece a fold cannot derive
// -- what a person decided a device is -- in the client (docs/design/decoders.md, "The state
// boundary" and section 5, "Registry devices"). A label is keyed by device_id alone, because the
// ids protocols carry (ICAO hex, MMSI, callsign-SSID, Acurite-Tower/2937) are globally meaningful,
// so "that's the greenhouse" holds whichever decoder next hears it; the protocol is kept only as
// a note of where it was first named.
package labels

import (
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"time"
)

// LabelsEnv overrides the store path; tests set it to a temp file.
const LabelsEnv = "LEYLINE_LABELS"

// Label is one transmitter's user-given name. Protocol is a note of the protocol it was named
// under, not part of the key. UpdatedNs is when it was last set, wall clock.
type Label struct {
	DeviceID  string `json:"device_id"`
	Name      string `json:"name"`
	Protocol  string `json:"protocol,omitempty"`
	UpdatedNs int64  `json:"updated_ns"`
}

// storeFile is the on-disk shape: a map keyed by device id, so a read-modify-write of one label
// leaves the rest untouched and encoding/json writes the keys sorted, giving a stable file.
type storeFile struct {
	Labels map[string]Label `json:"labels"`
}

// Store is the labels file loaded into memory. Each ley invocation opens it, mutates it and saves
// the whole file, so there is no long-lived writer to coordinate.
type Store struct {
	path   string
	labels map[string]Label
	// Now is the clock Set stamps with, so a test can hold time still; nil means time.Now.
	Now func() time.Time
}

// DefaultPath is where labels live when LEYLINE_LABELS is unset: beside the daemon's other data,
// ~/Library/Application Support/Leyline on macOS and $XDG_DATA_HOME (or ~/.local/share) elsewhere,
// mirroring the store and decoders paths (docs/design/decoders.md, "Decisions").
func DefaultPath(goos string, getenv func(string) (string, bool)) string {
	if goos == "darwin" {
		return filepath.Join(homeDir(), "Library", "Application Support", "Leyline", "labels.json")
	}
	if dir, ok := getenv("XDG_DATA_HOME"); ok && dir != "" {
		return filepath.Join(dir, "leyline", "labels.json")
	}
	return filepath.Join(homeDir(), ".local", "share", "leyline", "labels.json")
}

// ResolvePath is DefaultPath unless LEYLINE_LABELS overrides it.
func ResolvePath(getenv func(string) (string, bool)) string {
	if p, ok := getenv(LabelsEnv); ok && p != "" {
		return p
	}
	return DefaultPath(runtime.GOOS, getenv)
}

// Open loads the store at path. A missing file is an empty store, not an error: nobody has
// labelled anything yet. A malformed file is an error rather than silently discarded, because
// overwriting a user's labels on the next Set would lose data the person meant to keep.
func Open(path string) (*Store, error) {
	s := &Store{path: path, labels: map[string]Label{}}
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
	for id, l := range f.Labels {
		l.DeviceID = id
		s.labels[id] = l
	}
	return s, nil
}

// Get returns the label for a device id, and false when there is none.
func (s *Store) Get(deviceID string) (Label, bool) {
	l, ok := s.labels[deviceID]
	return l, ok
}

// Set gives a device id a name, keeping the protocol as a note, and persists the file. An empty
// name is a delete, so `ley label id ""` and `--clear` reach the same code.
func (s *Store) Set(deviceID, name, protocol string) (Label, error) {
	if name == "" {
		_, err := s.Delete(deviceID)
		return Label{DeviceID: deviceID}, err
	}
	l := Label{DeviceID: deviceID, Name: name, Protocol: protocol, UpdatedNs: s.now().UnixNano()}
	s.labels[deviceID] = l
	return l, s.save()
}

// Delete removes a label and persists the file, reporting whether one was there to remove.
func (s *Store) Delete(deviceID string) (bool, error) {
	if _, ok := s.labels[deviceID]; !ok {
		return false, nil
	}
	delete(s.labels, deviceID)
	return true, s.save()
}

// All returns every label, sorted by device id so a listing does not reshuffle between runs.
func (s *Store) All() []Label {
	out := make([]Label, 0, len(s.labels))
	for _, l := range s.labels {
		out = append(out, l)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].DeviceID < out[j].DeviceID })
	return out
}

func (s *Store) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

// save writes the whole file atomically: a temp file in the same directory then a rename, so a
// crash mid-write can never leave a half-written labels file that Open would then reject.
func (s *Store) save() error {
	if err := os.MkdirAll(filepath.Dir(s.path), 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(storeFile{Labels: s.labels}, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".labels-*.tmp")
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
