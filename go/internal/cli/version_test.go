// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestVersionJSONGolden pins `ley version --json`: the client-local document
// docs/interfaces.md names as the second exception to the proto3 mapping,
// with exactly these four keys in this order.
func TestVersionJSONGolden(t *testing.T) {
	old := Version
	Version = "1.2.3-golden"
	t.Cleanup(func() { Version = old })
	want := fmt.Sprintf("{\"version\":\"1.2.3-golden\",\"go\":%q,\"os\":%q,\"arch\":%q}\n", runtime.Version(), runtime.GOOS, runtime.GOARCH)
	out, errOut, err := runApp(t, &App{}, "--json", "version")
	if err != nil || errOut != "" {
		t.Fatalf("version --json: %v stderr=%q", err, errOut)
	}
	if out != want {
		t.Fatalf("version --json golden mismatch:\n got %q\nwant %q", out, want)
	}
	if out, _, err := runApp(t, &App{}, "version"); err != nil || out != "ley 1.2.3-golden ("+runtime.Version()+" "+runtime.GOOS+"/"+runtime.GOARCH+")\n" {
		t.Fatalf("version: %v %q", err, out)
	}
	// The document is JSON, not Go %q: a version string carrying a control
	// character (DEL) must round-trip through encoding/json (%q would print
	// the invalid escape \x7f).
	Version = "1.2.3+\x7f"
	out, _, err = runApp(t, &App{}, "--json", "version")
	if err != nil {
		t.Fatalf("version --json: %v", err)
	}
	var doc map[string]string
	if err := json.Unmarshal([]byte(out), &doc); err != nil || doc["version"] != Version {
		t.Fatalf("version --json is not JSON-encoded: %v %q", err, out)
	}
}

// TestVersionMatchesTheSourceOfTruth holds the three copies of the version
// together: the root VERSION file both build steps read, the constant
// scripts/gen-version.sh writes for the engine, and the literal an unstamped
// `go build` falls back to. A number that drifts here ships a daemon and a
// client that disagree about which build a bug report came from.
func TestVersionMatchesTheSourceOfTruth(t *testing.T) {
	root := "../../.."
	raw, err := os.ReadFile(filepath.Join(root, "VERSION"))
	if err != nil {
		// The module also builds extracted from the repo (a module cache
		// entry carries go/ alone), where there is nothing to compare.
		t.Skipf("no repo root beside the module: %v", err)
	}
	want := strings.TrimSpace(string(raw))
	if want == "" {
		t.Fatal("VERSION is empty")
	}
	if defaultVersion != want {
		t.Errorf("go fallback literal is %q, VERSION says %q — edit cli.defaultVersion", defaultVersion, want)
	}
	swift, err := os.ReadFile(filepath.Join(root, "engine", "Sources", "LeylineDaemon", "Version.swift"))
	if err != nil {
		t.Fatalf("engine version constant: %v", err)
	}
	if got := `let leylinedVersion = "` + want + `"`; !strings.Contains(string(swift), got) {
		t.Errorf("engine version constant does not say %s — run `make version`:\n%s", got, swift)
	}
}
