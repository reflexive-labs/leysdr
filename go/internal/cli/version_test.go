package cli

import (
	"encoding/json"
	"fmt"
	"runtime"
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
