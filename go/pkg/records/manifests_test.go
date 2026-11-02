// SPDX-License-Identifier: Apache-2.0

package records

import (
	"os"
	"path/filepath"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Every shipped manifest's templates parse, so a broken template fails here rather than falling
// back to the client's own line on every record.
func TestShippedManifestTemplatesParse(t *testing.T) {
	paths, err := filepath.Glob("../../../decoders/*/manifest.json")
	if err != nil || len(paths) == 0 {
		t.Fatalf("no manifests under decoders/ (%v)", err)
	}
	for _, path := range paths {
		data, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		var m leylinev1.DecoderManifest
		if err := protojson.Unmarshal(data, &m); err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if err := ValidateDisplay(m.GetDisplay()); err != nil {
			t.Errorf("%s: %v", path, err)
		}
	}
}

// ValidateDisplay finds a malformed template, which Render would only ever fall back from.
func TestValidateDisplayReportsAMalformedTemplate(t *testing.T) {
	bad := &leylinev1.DecoderDisplay{Summaries: map[string]string{"position": "{position}[ x"}}
	if ValidateDisplay(bad) == nil {
		t.Error("an unclosed group must be reported")
	}
	if ValidateDisplay(&leylinev1.DecoderDisplay{EntityName: "{name"}) == nil {
		t.Error("an unclosed name in entity_name must be reported")
	}
}
