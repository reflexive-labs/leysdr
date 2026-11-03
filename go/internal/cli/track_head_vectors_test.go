// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/records"
)

// TestColumnHeadVectors: testdata/decoders/head-cases.json pins how `ley track` heads a display
// column: the hint's label when it has one, else the field's name, with the hint's unit.
func TestColumnHeadVectors(t *testing.T) {
	b, err := os.ReadFile(filepath.Join("..", "..", "..", "testdata", "decoders", "head-cases.json"))
	if err != nil {
		t.Fatal(err)
	}
	var file struct {
		Cases []struct {
			Name   string `json:"name"`
			Column string `json:"column"`
			Hint   *struct {
				Name  string `json:"name"`
				Label string `json:"label"`
				Type  string `json:"type"`
				Unit  string `json:"unit"`
			} `json:"hint"`
			Head    string `json:"head"`
			Numeric bool   `json:"numeric"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(b, &file); err != nil {
		t.Fatal(err)
	}
	if len(file.Cases) == 0 {
		t.Fatal("no cases")
	}
	for _, c := range file.Cases {
		m := &leylinev1.DecoderManifest{}
		if h := c.Hint; h != nil {
			typ, ok := leylinev1.FieldType_value[h.Type]
			if !ok {
				t.Fatalf("%s: type %q is not a FieldType", c.Name, h.Type)
			}
			m.Fields = []*leylinev1.FieldHint{{Name: h.Name, Label: h.Label, Type: leylinev1.FieldType(typ), Unit: h.Unit}}
		}
		head, numeric := fieldColumnHead(m, records.ColumnName(c.Column))
		if head != c.Head || numeric != c.Numeric {
			t.Errorf("%s: %q, numeric %v; want %q, numeric %v", c.Name, head, numeric, c.Head, c.Numeric)
		}
	}
}
