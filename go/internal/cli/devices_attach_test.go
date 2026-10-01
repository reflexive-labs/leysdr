// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// TestDevicesAttachRTLTCP: the id is machine output on stdout, the sentence about it is prose on
// stderr, and the sentence says both that the daemon keeps the radio and how to get rid of it.
func TestDevicesAttachRTLTCP(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{NoDevice: true})
	out, errOut, err := run(t, context.Background(), sock, "devices", "attach", "rtltcp", "pi.local:1234")
	if err != nil {
		t.Fatalf("attach: %v stderr=%q", err, errOut)
	}
	st, serr := c.State(context.Background())
	if serr != nil {
		t.Fatal(serr)
	}
	if len(st.Devices) != 1 {
		t.Fatalf("want one attached radio, got %d", len(st.Devices))
	}
	id := st.Devices[0].DeviceId
	if strings.TrimSpace(out) != "device "+id {
		t.Errorf("stdout = %q, want the device id alone", out)
	}
	for _, want := range []string{"attached rtl_tcp pi.local:1234 (R820T) as " + id, "the daemon remembers it", "ley devices detach 1"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("stderr %q lacks %q", errOut, want)
		}
	}
	// Once attached, the radio is listed like any other.
	if table := mustRun(t, sock, "devices"); !strings.Contains(table, "rtl_tcp pi.local:1234") {
		t.Errorf("the attached radio is not in ley devices:\n%s", table)
	}
}

// TestDevicesAttachJSON: --json is the descriptor and nothing else, so a script can read the id.
func TestDevicesAttachJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	out, errOut, err := run(t, context.Background(), sock, "--json", "devices", "attach", "rtltcp", "10.0.0.5:1234")
	if err != nil {
		t.Fatalf("attach --json: %v stderr=%q", err, errOut)
	}
	var dev struct {
		DeviceID string `json:"deviceId"`
		Driver   string `json:"driver"`
		Serial   string `json:"serial"`
	}
	if err := json.Unmarshal([]byte(out), &dev); err != nil {
		t.Fatalf("stdout is not one DeviceDescriptor (%v): %q", err, out)
	}
	if !strings.HasPrefix(dev.DeviceID, "dev_") || dev.Driver != "rtltcp" || dev.Serial != "10.0.0.5:1234" {
		t.Errorf("descriptor = %+v", dev)
	}
}

// TestDevicesAttachDuplicate: one endpoint is one radio, so attaching it twice is not an error --
// the second run hands back the same id and says the daemon already has it.
func TestDevicesAttachDuplicate(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	first := mustRun(t, sock, "devices", "attach", "rtltcp", "pi.local:1234")
	out, errOut, err := run(t, context.Background(), sock, "devices", "attach", "rtltcp", "pi.local:1234")
	if err != nil {
		t.Fatalf("a duplicate attach must succeed: %v stderr=%q", err, errOut)
	}
	if out != first {
		t.Errorf("second attach printed %q, want the same device as the first (%q)", out, first)
	}
	if !strings.Contains(errOut, "is already attached as dev_") {
		t.Errorf("stderr %q does not say the daemon already has it", errOut)
	}
	if strings.Contains(errOut, "the daemon remembers it") {
		t.Errorf("a duplicate must not read as a fresh attach: %q", errOut)
	}
}

// TestDevicesAttachUnreachable: a radio never reached is usually a typo, so the daemon remembers
// nothing and the failure is the daemon's own sentence, exit 1.
func TestDevicesAttachUnreachable(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{NoDevice: true})
	out, _, err := run(t, context.Background(), sock, "devices", "attach", "rtltcp", "nosuch.invalid:1234")
	if exitCode(err) != 1 || err == nil {
		t.Fatalf("unreachable host: exit %d (%v)", exitCode(err), err)
	}
	if !strings.Contains(err.Error(), "nosuch.invalid:1234") {
		t.Errorf("message %q does not name the endpoint", err)
	}
	if out != "" {
		t.Errorf("nothing was attached, so stdout must be empty, got %q", out)
	}
	st, serr := c.State(context.Background())
	if serr != nil {
		t.Fatal(serr)
	}
	if len(st.Devices) != 0 {
		t.Errorf("a failed attach left %d devices behind", len(st.Devices))
	}
}

// TestDevicesAttachUsage: the kind and the endpoint are the caller's to get right, so a mistake in
// either is exit 2 with the shape spelled out, before anything reaches the daemon.
func TestDevicesAttachUsage(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"devices", "attach", "hackrf", "pi.local:1234"}, "the kinds are: rtltcp"},
		{[]string{"devices", "attach", "rtltcp", "pi.local"}, "is not a host:port"},
		{[]string{"devices", "attach", "rtltcp", "pi.local:0"}, "is not a port between 1 and 65535"},
		{[]string{"devices", "attach", "rtltcp"}, "accepts 2 arg"},
	}
	for _, tc := range cases {
		_, _, err := run(t, context.Background(), sock, tc.args...)
		if exitCode(err) != ExitUsage || err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("ley %v: exit %d (%v), want %d saying %q", tc.args, exitCode(err), err, ExitUsage, tc.want)
		}
	}
}
