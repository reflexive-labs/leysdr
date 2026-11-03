// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// TestWatchVectors: testdata/decoders/watch-cases.json pins the predicate `ley watch` sends for
// its filter flags, and the Mac app's Notify Me… sheet builds its predicate by the same rules
// from the same file (WatchPredicateTests), so a watch made in either client filters alike.
func TestWatchVectors(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "decoders", "watch-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []struct {
			Name      string          `json:"name"`
			Where     []string        `json:"where"`
			County    []string        `json:"county"`
			Near      string          `json:"near"`
			Radius    string          `json:"radius"`
			Predicate json.RawMessage `json:"predicate"`
			Error     bool            `json:"error"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range file.Cases {
		got, _, err := buildPredicate(c.Where, c.County, c.Near, c.Radius)
		if c.Error {
			if err == nil {
				t.Errorf("%s: built %v, want a refusal", c.Name, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("%s: %v", c.Name, err)
			continue
		}
		var want *leylinev1.Predicate
		if len(c.Predicate) > 0 && string(c.Predicate) != "null" {
			want = &leylinev1.Predicate{}
			if err := protojson.Unmarshal(c.Predicate, want); err != nil {
				t.Fatalf("%s: the case's predicate: %v", c.Name, err)
			}
		}
		if (got == nil) != (want == nil) || (got != nil && !proto.Equal(got, want)) {
			t.Errorf("%s: built %v, want %v", c.Name, got, want)
		}
	}
}
