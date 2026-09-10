package cli

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The fake daemon's synthetic band, from internal/fakedaemon/jobs.go.
const (
	fakeStrongest = "146.520 MHz"
	fakeWide      = "101.100 MHz"
)

func TestScanTable(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, t.Context(), sock, "scan", "145M..147M")
	if err != nil {
		t.Fatalf("ley scan: %v\n%s\n%s", err, out, errOut)
	}
	for _, want := range []string{"FREQUENCY", "WIDTH", "SNR", "SEEN", "BAND", "145.230 MHz", fakeStrongest} {
		if !strings.Contains(out, want) {
			t.Errorf("table lacks %q:\n%s", want, out)
		}
	}
	// Out of range, and therefore not in the answer.
	if strings.Contains(out, fakeWide) {
		t.Errorf("101.1 MHz is outside 145-147 MHz:\n%s", out)
	}
	// The table is the answer and goes to stdout; the prose is for the person.
	for _, want := range []string{"sweeping 145.000 MHz to 147.000 MHz", "floor", "ley listen"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("stderr lacks %q:\n%s", want, errOut)
		}
	}
	if strings.Contains(out, "sweeping") || strings.Contains(out, "signals,") {
		t.Errorf("prose reached stdout:\n%s", out)
	}
}

// SEEN is the evidence a reader needs to tell a carrier from a burst, and it is never used to
// hide a row -- an intermittent signal is exactly what somebody might be scanning for.
func TestScanShowsTheEvidence(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "scan", "145M..147M")
	if !strings.Contains(out, "/") {
		t.Errorf("no SEEN counts in:\n%s", out)
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.Contains(line, "145.230") && !strings.Contains(line, "8/8") {
			t.Errorf("want a look count on the row: %q", line)
		}
	}
}

func TestScanJSONIsTheScanMessageAlone(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "--json", "scan", "145M..147M")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 1 {
		t.Fatalf("want exactly one Scan object, got %d lines:\n%s", len(lines), out)
	}
	var scan map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &scan); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	// The proto3 JSON mapping: lowerCamelCase, 64-bit integers as strings.
	for _, k := range []string{"scanId", "config", "detections", "noiseFloor"} {
		if _, ok := scan[k]; !ok {
			t.Errorf("Scan lacks %q: %s", k, lines[0])
		}
	}
	dets, _ := scan["detections"].([]any)
	if len(dets) == 0 {
		t.Fatalf("no detections: %s", lines[0])
	}
	first, _ := dets[0].(map[string]any)
	for _, k := range []string{"centerHz", "bandwidthHz", "snrDb", "looks", "looksPossible", "floorDbfs"} {
		if _, ok := first[k]; !ok {
			t.Errorf("detection lacks %q: %v", k, first)
		}
	}
	if _, ok := first["centerHz"].(string); !ok {
		t.Errorf("centerHz must be a string (proto3 JSON, 64-bit): %v", first["centerHz"])
	}
}

func TestScanSortsBySNR(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	byFreq := mustRun(t, sock, "scan", "145M..147M")
	bySNR := mustRun(t, sock, "scan", "145M..147M", "--sort", "snr")
	if firstFreq(byFreq) != "145.230" {
		t.Errorf("freq order starts at %q:\n%s", firstFreq(byFreq), byFreq)
	}
	if firstFreq(bySNR) != "146.520" {
		t.Errorf("snr order starts at %q:\n%s", firstFreq(bySNR), bySNR)
	}
}

func TestScanMinSNRHides(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	all := mustRun(t, sock, "scan", "160M..163M")
	if !strings.Contains(all, "162.400 MHz") {
		t.Fatalf("want the weak NOAA carrier:\n%s", all)
	}
	filtered := mustSay(t, sock, "scan", "160M..163M", "--min-snr", "20")
	if strings.Contains(filtered, "162.400 MHz") {
		t.Errorf("--min-snr 20 should have hidden a 12 dB signal:\n%s", filtered)
	}
	// Hiding what was found is a different answer from finding nothing, and needs a different
	// remedy: a longer dwell will not bring back a row the filter removed.
	if !strings.Contains(filtered, "below 20 dB") {
		t.Errorf("must say the filter hid them:\n%s", filtered)
	}
	if strings.Contains(filtered, "nothing stood above the noise floor") {
		t.Errorf("the band was not empty; the filter emptied the table:\n%s", filtered)
	}
	if strings.Contains(filtered, "--dwell") {
		t.Errorf("a longer dwell is the wrong remedy for a filtered table:\n%s", filtered)
	}
	// A genuinely empty band still says so.
	empty := mustSay(t, sock, "scan", "170M..172M")
	if !strings.Contains(empty, "nothing stood above the noise floor") {
		t.Errorf("an empty band must say so:\n%s", empty)
	}
}

// A band is named with --band because "2m" is 2 MHz everywhere a frequency is accepted.
func TestScanBandFlag(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustSay(t, sock, "scan", "--band", "2m")
	if !strings.Contains(out, "144.000 MHz to 148.000 MHz") {
		t.Errorf("--band 2m should sweep the whole band:\n%s", out)
	}
	if !strings.Contains(out, fakeStrongest) {
		t.Errorf("want the 2 m carriers:\n%s", out)
	}
}

// The daemon's refusal is a sentence with a way forward, not a code.
func TestScanReportsWhoHasTheRadio(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	listening(t, c)
	_, errOut, err := run(t, t.Context(), sock, "scan", "145M..147M")
	if err == nil {
		t.Fatalf("a busy radio must refuse:\n%s", errOut)
	}
	msg := err.Error()
	if !strings.Contains(msg, "--take-over") {
		t.Errorf("the refusal must name the way through: %q", msg)
	}
	if strings.Contains(msg, "DEVICE_BUSY:") {
		t.Errorf("the stable code belongs in --json, not in the sentence: %q", msg)
	}
	// The code the sentence leaves out is a field on the job, so a client that wants to branch on
	// it does not have to split prose.
	st, serr := c.State(t.Context())
	if serr != nil {
		t.Fatalf("state: %v", serr)
	}
	var failed *leylinev1.Job
	for _, j := range st.Jobs {
		if j.State == leylinev1.JobState_FAILED {
			failed = j
		}
	}
	if failed == nil {
		t.Fatalf("the refused scan left no failed job: %v", st.Jobs)
	}
	if failed.GetError().GetCode() != leyline.CodeDeviceBusy {
		t.Errorf("want %s in job.error, got %+v", leyline.CodeDeviceBusy, failed.GetError())
	}
	if strings.Contains(failed.StatusDetail, "DEVICE_BUSY") || failed.StatusDetail == "" {
		t.Errorf("status_detail is prose: %q", failed.StatusDetail)
	}
	// And --take-over gets through.
	out := mustRun(t, sock, "scan", "145M..147M", "--take-over")
	if !strings.Contains(out, fakeStrongest) {
		t.Errorf("--take-over should have swept:\n%s", out)
	}
}

// Strip-to-plain: the styled screen must differ from the plain one in ink alone.
func TestScanStripsToPlain(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	plain := mustSay(t, sock, "--color", "never", "scan", "145M..147M")
	inked := mustSay(t, sock, "--color", "always", "scan", "145M..147M")
	if got := ui.Strip(inked); got != plain {
		t.Errorf("styled != plain:\n plain  %q\n styled %q", plain, got)
	}
}

func firstFreq(table string) string {
	for _, line := range strings.Split(table, "\n") {
		if strings.Contains(line, " MHz") && !strings.Contains(line, "FREQUENCY") {
			return strings.TrimSpace(strings.SplitN(strings.TrimSpace(line), " ", 2)[0])
		}
	}
	return ""
}

// The fake daemon is what every test above runs against, so a fake that disagrees with the Swift
// daemon makes them worthless. These pin the behaviours that diverged.
func TestScanContractParityWithTheDaemon(t *testing.T) {
	t.Run("a missing radio fails the job, not the RPC", func(t *testing.T) {
		sock, _ := harness(t, fakedaemon.Options{})
		// Far outside the fake RTL-SDR's tuning range.
		_, errOut, err := run(t, t.Context(), sock, "scan", "2400M..2410M")
		if err == nil {
			t.Fatalf("an unreachable range must fail:\n%s", errOut)
		}
		// The daemon always returns a RUNNING job and fails it from the allocator, so the message
		// is the job's reason and not a raw gRPC error.
		if !strings.Contains(err.Error(), "tune") {
			t.Errorf("want the allocator's reason, got %q", err)
		}
	})

	t.Run("a scan owns the radio while it runs", func(t *testing.T) {
		sock, c := harness(t, fakedaemon.Options{})
		st, serr := c.State(t.Context())
		if serr != nil || len(st.Devices) == 0 {
			t.Fatalf("state: %v", serr)
		}
		// A long sweep, then try to join the radio while it is walking.
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _, _ = run(t, ctx, sock, "scan", "145M..147M", "--dwell", "150")
		}()
		// Wait for the job to say it has the radio: a fixed pause races the
		// sweep's start on a loaded machine and its finish on a quick one.
		deadline := time.Now().Add(5 * time.Second)
		for {
			js, jerr := c.State(t.Context())
			if jerr == nil && len(js.Jobs) > 0 && js.Jobs[0].State == leylinev1.JobState_RUNNING {
				break
			}
			if time.Now().After(deadline) {
				cancel()
				<-done
				t.Fatal("the scan never reported RUNNING")
			}
			time.Sleep(10 * time.Millisecond)
		}
		_, _, err := run(t, t.Context(), sock, "tune", "146.52", "--no-audio", "--persistent")
		// The sweep has served its purpose: stop it before asserting, so a
		// failure leaves no runner calling into t.
		cancel()
		<-done
		if err == nil {
			t.Fatal("tune must not join a capture a scan is sweeping")
		}
		if !strings.Contains(err.Error(), "scan is sweeping") {
			t.Errorf("want the sweeping reason, got %q", err)
		}
	})

	t.Run("GetState carries the job table", func(t *testing.T) {
		sock, c := harness(t, fakedaemon.Options{})
		mustRun(t, sock, "scan", "145M..147M")
		st, err := c.State(t.Context())
		if err != nil {
			t.Fatal(err)
		}
		if len(st.Jobs) == 0 {
			t.Fatal("a finished scan must still be in GetState: that is what makes reconnect work")
		}
		if st.Jobs[0].State.String() != "COMPLETED" {
			t.Errorf("job state %v", st.Jobs[0].State)
		}
	})

	t.Run("the Scan says how finely it looked and what it covered", func(t *testing.T) {
		sock, _ := harness(t, fakedaemon.Options{})
		out := mustRun(t, sock, "--json", "scan", "145M..147M")
		var scan map[string]any
		if err := json.Unmarshal([]byte(strings.TrimSpace(out)), &scan); err != nil {
			t.Fatal(err)
		}
		if scan["resolutionHz"] == nil {
			t.Error("no resolutionHz: every dB in the message is per bin, and a bin needs a width")
		}
		if scan["covered"] == nil {
			t.Error("no covered range: a client cannot tell what was searched from what was asked")
		}
		cfg, _ := scan["config"].(map[string]any)
		if cfg["stepHz"] == nil {
			t.Error("no stepHz")
		}
	})
}

func TestScanIDOf(t *testing.T) {
	tests := []struct {
		name    string
		uris    []string
		want    string
		wantErr string
	}{
		{"scan uri", []string{"ley://scans/scan_01"}, "scan_01", ""},
		{"among others", []string{"ley://recordings/rec_01", "ley://scans/scan_02"}, "scan_02", ""},
		{"no uris", nil, "", "the daemon named no scan"},
		// A singular prefix is a daemon that named something this build cannot
		// fetch; reporting it beats showing a band with no detections in it.
		{"wrong kind", []string{"ley://scan/scan_03"}, "", "only ley://scan/scan_03"},
		{"no id", []string{"ley://scans/"}, "", "only ley://scans/"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			id, err := scanIDOf(&leylinev1.Job{ResultUris: tc.uris})
			if id != tc.want {
				t.Errorf("id %q, want %q", id, tc.want)
			}
			switch {
			case tc.wantErr == "" && err != nil:
				t.Errorf("unexpected error: %v", err)
			case tc.wantErr != "" && (err == nil || !strings.Contains(err.Error(), tc.wantErr)):
				t.Errorf("error %v, want one saying %q", err, tc.wantErr)
			}
		})
	}
}
