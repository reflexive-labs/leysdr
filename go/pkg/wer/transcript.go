// SPDX-License-Identifier: Apache-2.0

package wer

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
)

// TranscriptFile is the hand transcript's name beside a recording's parts.
const TranscriptFile = "transcript.txt"

// Unheard is the text that marks an over not transcribed yet: the score leaves it out, with the
// record that starts there. A template starts every over with it.
const Unheard = "?"

// ParseTranscript reads a hand transcript: one line per over, `part/over`, a tab, and the words
// as spoken. A callsign may be written as spoken or compactly ("whiskey six alpha bravo charlie"
// or "W6ABC"); Normalise makes the two one word. A line with no words is an over in which nobody
// said anything a person could make out, so any word an engine writes there is an insertion; a
// line whose text is "?" has not been transcribed and is left out. Blank lines and lines starting
// with # are ignored. name is used in errors.
func ParseTranscript(r io.Reader, name string) (*Transcript, error) {
	t := &Transcript{}
	seen := map[Key]int{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for n := 1; sc.Scan(); n++ {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		field, text, _ := strings.Cut(line, "\t")
		if strings.ContainsAny(field, " ") {
			// A space instead of the tab, as an editor that expands tabs writes it.
			field, text, _ = strings.Cut(line, " ")
		}
		key, err := parseKey(field)
		if err != nil {
			return nil, fmt.Errorf("%s:%d: %w", name, n, err)
		}
		if first, ok := seen[key]; ok {
			return nil, fmt.Errorf("%s:%d: %s is already on line %d; put all of an over's words on one line", name, n, key, first)
		}
		seen[key] = n
		text = strings.TrimSpace(text)
		if text == Unheard {
			t.Skipped = append(t.Skipped, key)
			continue
		}
		t.Overs = append(t.Overs, Over{Key: key, Text: text})
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("%s: %w", name, err)
	}
	return t, nil
}

// LoadTranscript reads the hand transcript at path.
func LoadTranscript(path string) (*Transcript, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ParseTranscript(f, path)
}

func parseKey(s string) (Key, error) {
	p, o, ok := strings.Cut(s, "/")
	part, perr := strconv.Atoi(p)
	over, oerr := strconv.Atoi(o)
	if !ok || perr != nil || oerr != nil || part < 1 || over < 1 {
		return Key{}, fmt.Errorf("%q is not part/over, such as 1/2 for the second over of part 1", s)
	}
	return Key{Part: part, Over: over}, nil
}
