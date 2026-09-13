// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

// The fake monitor's synthetic GMRS carriers, from internal/fakedaemon/monitor.go.
const (
	monWeak   = "462.562 MHz" // ch1, 12 dB: --min-snr hides it
	monMedium = "462.600 MHz" // ch17
	monStrong = "462.625 MHz" // ch18, the strongest
)

func monitorOpts() fakedaemon.Options {
	// A brisk telemetry cadence, so a short watch still sees its carriers appear and be held.
	return fakedaemon.Options{MeterInterval: 20 * time.Millisecond}
}

// The report is the answer and goes to stdout, sorted by first appearance, with the channel
// labels a GMRS radio shares; the live feed and the summary are the person's and go to stderr.
func TestMonitorReportsTransmissions(t *testing.T) {
	sock, _ := harness(t, monitorOpts())
	out, errOut, err := run(t, t.Context(), sock, "monitor", "gmrs", "--for", "1s")
	if err != nil {
		t.Fatalf("ley monitor: %v\n%s\n%s", err, out, errOut)
	}
	for _, want := range []string{"TIME", "FREQUENCY", "CHANNEL", "HELD", "PEAK SNR", monMedium, monStrong, "ch17", "ch18"} {
		if !strings.Contains(out, want) {
			t.Errorf("report lacks %q:\n%s", want, out)
		}
	}
	// The live feed and the summary are for the person, on stderr.
	if !strings.Contains(errOut, "watching 462.500 MHz to 462.750 MHz") {
		t.Errorf("stderr lacks the watching banner:\n%s", errOut)
	}
	if !strings.Contains(errOut, monStrong) {
		t.Errorf("stderr lacks the live feed:\n%s", errOut)
	}
	if !strings.Contains(errOut, "carrier") || !strings.Contains(errOut, "strongest ch18") {
		t.Errorf("stderr lacks the summary:\n%s", errOut)
	}
	// The banner and summary are prose; they must not reach the report a pipe reads.
	if strings.Contains(out, "watching") || strings.Contains(out, "strongest") {
		t.Errorf("prose reached stdout:\n%s", out)
	}
}

// --json prints one snake_case object per carrier at the end, and nothing before it.
func TestMonitorJSON(t *testing.T) {
	sock, _ := harness(t, monitorOpts())
	out := mustRun(t, sock, "--json", "monitor", "gmrs", "--for", "1s")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) == 0 || lines[0] == "" {
		t.Fatalf("no carriers in NDJSON:\n%s", out)
	}
	var sawStrong bool
	for _, line := range lines {
		var c map[string]any
		if err := json.Unmarshal([]byte(line), &c); err != nil {
			t.Fatalf("%v\n%s", err, line)
		}
		for _, k := range []string{"detection_id", "center_hz", "channel", "first_s", "held_s", "peak_snr_db", "bandwidth_hz"} {
			if _, ok := c[k]; !ok {
				t.Errorf("carrier lacks %q: %s", k, line)
			}
		}
		if c["channel"] == "ch18" {
			sawStrong = true
			if snr, _ := c["peak_snr_db"].(float64); snr < 30 {
				t.Errorf("ch18 peak_snr_db = %v, want the strong carrier", c["peak_snr_db"])
			}
		}
	}
	if !sawStrong {
		t.Errorf("no ch18 carrier in:\n%s", out)
	}
}

// --min-snr hides a carrier whose peak never cleared the threshold from the report, but a genuinely
// heard weak carrier is not the same as an empty band.
func TestMonitorMinSNR(t *testing.T) {
	sock, _ := harness(t, monitorOpts())
	all := mustRun(t, sock, "monitor", "gmrs", "--for", "1s")
	if !strings.Contains(all, monWeak) {
		t.Fatalf("want the weak ch1 carrier in the report:\n%s", all)
	}
	// The report (stdout) hides the weak carrier; the strong one stays.
	filtered := mustRun(t, sock, "monitor", "gmrs", "--for", "1s", "--min-snr", "20")
	if strings.Contains(filtered, monWeak) {
		t.Errorf("--min-snr 20 should have hidden the 12 dB carrier:\n%s", filtered)
	}
	if !strings.Contains(filtered, monStrong) {
		t.Errorf("--min-snr 20 should have kept the 34 dB carrier:\n%s", filtered)
	}
}

// A band name in the positional resolves like scan's, so `ley monitor gmrs` watches the GMRS band.
func TestMonitorBandName(t *testing.T) {
	sock, _ := harness(t, monitorOpts())
	out := mustSay(t, sock, "monitor", "gmrs", "--for", "1s")
	if !strings.Contains(out, "watching 462.500 MHz to 462.750 MHz") {
		t.Errorf("a band name should resolve to the GMRS range:\n%s", out)
	}
}

// A quiet band says so rather than printing an empty table.
func TestMonitorEmpty(t *testing.T) {
	sock, _ := harness(t, monitorOpts())
	out := mustSay(t, sock, "monitor", "462.700M..462.740M", "--for", "1s")
	if !strings.Contains(out, "nothing heard on 462.700M..462.740M in") {
		t.Errorf("a quiet band must say so:\n%s", out)
	}
}
