// SPDX-License-Identifier: Apache-2.0

package wer

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestParseTranscript(t *testing.T) {
	in := strings.Join([]string{
		"# recording job_01, 146.940 MHz NFM",
		"",
		"# 14:03:00, 4.2 s",
		"1/1\tthis is whiskey six alpha bravo charlie",
		"1/3\tW6ABC, go ahead  ",
		"  # an indented comment",
		"2/1\t",
		"2/2\t?",
		"2/4 written with a space",
	}, "\n")
	got, err := ParseTranscript(strings.NewReader(in), "t.txt")
	if err != nil {
		t.Fatal(err)
	}
	want := &Transcript{
		Overs: []Over{
			{Key: Key{1, 1}, Text: "this is whiskey six alpha bravo charlie"},
			{Key: Key{1, 3}, Text: "W6ABC, go ahead"},
			{Key: Key{2, 1}, Text: ""},
			{Key: Key{2, 4}, Text: "written with a space"},
		},
		Skipped: []Over{{Key: Key{2, 2}}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("got %+v\nwant %+v", got, want)
	}
}

func TestParseTranscriptRefuses(t *testing.T) {
	for _, tc := range []struct{ in, want string }{
		{"1-1\thello", `t.txt:1: "1-1" is not part/over`},
		{"0/1\thello", `t.txt:1: "0/1" is not part/over`},
		{"x/1\thello", `"x/1" is not part/over`},
		{"1/1\ta\n# c\n1/1\tb", "t.txt:3: 1/1 is already on line 1"},
	} {
		_, err := ParseTranscript(strings.NewReader(tc.in), "t.txt")
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("ParseTranscript(%q) = %v, want an error containing %q", tc.in, err, tc.want)
		}
	}
}

func TestLoadTranscript(t *testing.T) {
	path := filepath.Join(t.TempDir(), TranscriptFile)
	if err := os.WriteFile(path, []byte("1/1\thello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := LoadTranscript(path)
	if err != nil || len(got.Overs) != 1 || got.Overs[0].Text != "hello" {
		t.Errorf("LoadTranscript = %+v, %v", got, err)
	}
	if _, err := LoadTranscript(filepath.Join(t.TempDir(), "none.txt")); !os.IsNotExist(err) {
		t.Errorf("a missing file: %v, want not-exist", err)
	}
}
