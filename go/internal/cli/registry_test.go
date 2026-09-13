// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/pkg/labels"
)

// runLabels runs ley with a temp labels file, so `label` and `devices-seen` share one store the
// test controls through $LEYLINE_LABELS (the override the store reads).
func runLabels(t *testing.T, sock, labelsPath string, args ...string) (string, string, error) {
	t.Helper()
	app := &App{
		Socket: sock,
		LookupEnv: func(k string) (string, bool) {
			if k == labels.LabelsEnv {
				return labelsPath, true
			}
			return "", false
		},
	}
	return runApp(t, app, args...)
}

func mustLabels(t *testing.T, sock, labelsPath string, args ...string) string {
	t.Helper()
	out, errOut, err := runLabels(t, sock, labelsPath, args...)
	if err != nil {
		t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
	}
	return out
}

// TestLabelRoundTrips: a name set is a name read back, --json prints the record, and a clear
// removes it -- all against a temp store, because labels are user data in the client (docs/design/
// decoders.md, "The state boundary").
func TestLabelRoundTrips(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	path := filepath.Join(t.TempDir(), "labels.json")

	none := mustLabels(t, sock, path, "label", "LEYTST-1")
	if !strings.Contains(none, "no label") {
		t.Fatalf("an unnamed device must say so:\n%s", none)
	}
	if set := mustLabels(t, sock, path, "label", "LEYTST-1", "greenhouse"); !strings.Contains(set, "greenhouse") {
		t.Fatalf("set must confirm the name:\n%s", set)
	}
	if got := mustLabels(t, sock, path, "label", "LEYTST-1"); !strings.Contains(got, "greenhouse") {
		t.Fatalf("the name must read back:\n%s", got)
	}
	out := mustLabels(t, sock, path, "--json", "label", "LEYTST-1")
	var l labels.Label
	if err := json.Unmarshal([]byte(out), &l); err != nil || l.Name != "greenhouse" || l.DeviceID != "LEYTST-1" {
		t.Fatalf("json label: %v %s", err, out)
	}
	if cleared := mustLabels(t, sock, path, "label", "LEYTST-1", "--clear"); !strings.Contains(cleared, "no label") {
		t.Fatalf("--clear must remove the name:\n%s", cleared)
	}
	if got := mustLabels(t, sock, path, "label", "LEYTST-1"); !strings.Contains(got, "no label") {
		t.Fatalf("a cleared label must stay cleared:\n%s", got)
	}
	// An empty name is a clear too: set then clear with "".
	mustLabels(t, sock, path, "label", "LEYTST-2", "car")
	if got := mustLabels(t, sock, path, "label", "LEYTST-2", ""); !strings.Contains(got, "no label") {
		t.Fatalf(`label id "" must clear:\n%s`, got)
	}
}

// TestDevicesSeenListsAndCounts: the registry is one row per transmitter the kept records heard,
// with a count that grows as the fake emits (a record every RecordInterval), newest first.
func TestDevicesSeenListsAndCounts(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	path := filepath.Join(t.TempDir(), "labels.json")

	empty := mustLabels(t, sock, path, "devices-seen")
	if !strings.Contains(empty, "no devices seen") || !strings.Contains(empty, "--job") {
		t.Fatalf("an empty registry must say how to fill it:\n%s", empty)
	}
	keptJob(t, sock, c, 8*fakedaemon.RecordInterval)

	out := mustLabels(t, sock, path, "devices-seen")
	if head := strings.Fields(out)[0]; head != "DEVICE" {
		t.Fatalf("unexpected table:\n%s", out)
	}
	for _, want := range []string{"LABEL", "PROTOCOL", "SEEN", "FIRST", "LAST", "LEYTST-1", "LEYTST-2", "LEYTST-3", "aprs"} {
		if !strings.Contains(out, want) {
			t.Errorf("the table lacks %q:\n%s", want, out)
		}
	}
	// One protocol only, and counts are at least one each.
	page := devicesSeenJSON(t, sock, path)
	if len(page.Devices) != 3 {
		t.Fatalf("want 3 transmitters, got %d:\n%+v", len(page.Devices), page.Devices)
	}
	for _, d := range page.Devices {
		if d.Seen < 1 || d.Protocol != "aprs" || d.LastNs == 0 {
			t.Errorf("device row: %+v", d)
		}
	}
}

// TestDevicesSeenQuietSince: --quiet-since is the absence question. After a kept job stops and
// time passes, a window shorter than the gap shows the transmitters, and one hour of quiet shows
// none, because they were all heard within the hour.
func TestDevicesSeenQuietSince(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	path := filepath.Join(t.TempDir(), "labels.json")
	job := keptJob(t, sock, c, 6*fakedaemon.RecordInterval)
	// Stop the job so nothing new is heard, then let the last-seen ages grow past the window.
	if _, err := c.Jobs.CancelJob(context.Background(), &leylinev1.JobRef{JobId: job.JobId}); err != nil {
		t.Fatalf("cancel: %v", err)
	}
	time.Sleep(600 * time.Millisecond)

	quiet := devicesSeenJSONArgs(t, sock, path, "--quiet-since", "300ms")
	if len(quiet.Devices) == 0 {
		t.Fatalf("transmitters silent longer than the window must appear under --quiet-since:\n%+v", quiet)
	}
	loud := devicesSeenJSONArgs(t, sock, path, "--quiet-since", "1h")
	if len(loud.Devices) != 0 {
		t.Errorf("nothing heard within the hour has gone quiet for an hour: %+v", loud.Devices)
	}
	out := mustLabels(t, sock, path, "devices-seen", "--quiet-since", "1h")
	if !strings.Contains(out, "gone quiet") {
		t.Errorf("an empty absence list must say so:\n%s", out)
	}
}

// TestDevicesSeenShowsLabels: a labelled transmitter shows the name in the registry, the join the
// verb makes between the fold and the labels store.
func TestDevicesSeenShowsLabels(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	path := filepath.Join(t.TempDir(), "labels.json")
	keptJob(t, sock, c, 6*fakedaemon.RecordInterval)
	mustLabels(t, sock, path, "label", "LEYTST-1", "greenhouse")

	out := mustLabels(t, sock, path, "devices-seen")
	if !strings.Contains(out, "greenhouse") {
		t.Fatalf("a labelled device must show its name:\n%s", out)
	}
	page := devicesSeenJSON(t, sock, path)
	for _, d := range page.Devices {
		if d.DeviceID == "LEYTST-1" && d.Label != "greenhouse" {
			t.Errorf("json must carry the label: %+v", d)
		}
	}
}

func devicesSeenJSON(t *testing.T, sock, path string) DevicesSnapshot {
	t.Helper()
	return devicesSeenJSONArgs(t, sock, path)
}

func devicesSeenJSONArgs(t *testing.T, sock, path string, args ...string) DevicesSnapshot {
	t.Helper()
	out := mustLabels(t, sock, path, append([]string{"--json", "devices-seen"}, args...)...)
	var snap DevicesSnapshot
	if err := json.Unmarshal([]byte(out), &snap); err != nil {
		t.Fatalf("devices-seen --json: %v\n%s", err, out)
	}
	return snap
}

// A friendly alias resolves to the decoder that claims it: the fake's aprs decoder answers to
// "packets", so `ley decode packets` and `ley track packets` reach it and its records.
func TestDecodeResolvesAnAlias(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "decode", "packets", "--json", "--count", "1")
	if err != nil {
		t.Fatalf("ley decode packets: %v\n%s", err, errOut)
	}
	var rec map[string]any
	if uerr := json.Unmarshal([]byte(strings.TrimSpace(out)), &rec); uerr != nil {
		t.Fatalf("NDJSON is not JSON (%v): %s", uerr, out)
	}
	if rec["protocol"] != "aprs" {
		t.Fatalf("the alias did not resolve to aprs: %s", out)
	}
}

func TestTrackResolvesAnAlias(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "track", "packets", "--count", "3")
	if err != nil {
		t.Fatalf("ley track packets: %v\n%s", err, errOut)
	}
	if !strings.Contains(out, "LEYTST-1") {
		t.Fatalf("track via the alias saw no records:\n%s", out)
	}
	// The banner names the decoder actually running (the canonical name), which is how a reader
	// learns the alias resolved: `ley track packets` says "tracking aprs".
	if !strings.Contains(errOut, "tracking aprs") {
		t.Errorf("the banner should name the resolved decoder:\n%s", errOut)
	}
}

// The decoders table shows the friendly names beside the canonical one, so an alias is discoverable.
func TestDecodersTableShowsAliases(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "decoders")
	if !strings.Contains(out, "aprs") || !strings.Contains(out, "packets") {
		t.Errorf("the table should show the alias beside the name:\n%s", out)
	}
}
