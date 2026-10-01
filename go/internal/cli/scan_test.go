// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/bandplan"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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

// The rows fewer than half the looks saw are named in a sentence, and the rows every look saw
// are not: the SEEN column is the evidence, the sentence what it means.
func TestScanNamesTheUnconfirmed(t *testing.T) {
	var errb bytes.Buffer
	app := &App{Stdout: &bytes.Buffer{}, Stderr: &errb, Style: ui.Style{}, ErrStyle: ui.Style{}, styled: true}
	det := func(hz uint64, looks, possible uint32) *leylinev1.Detection {
		return &leylinev1.Detection{CenterHz: hz, SnrDb: 20, Looks: looks, LooksPossible: possible}
	}
	unconfirmedNote(app, []*leylinev1.Detection{det(145_200_000, 4, 4), det(145_397_656, 1, 4), det(146_400_000, 2, 4)})
	if out := errb.String(); !strings.Contains(out, "145.398 MHz (1/4)") || strings.Contains(out, "145.200") || strings.Contains(out, "146.400") {
		t.Errorf("the one-look row and no other:\n%s", out)
	}
	errb.Reset()
	unconfirmedNote(app, []*leylinev1.Detection{det(145_200_000, 4, 4), det(146_400_000, 1, 1)})
	if errb.Len() != 0 {
		t.Errorf("nothing to say when every row held:\n%s", errb.String())
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
	// The counts are the sweep's own arithmetic -- rows per step, and the steps whose windows
	// covered the frequency -- so the assertion is the invariant, not a number: something was
	// looked at, and nothing was found more often than it was looked for.
	seen := regexp.MustCompile(`\s(\d+)/(\d+)\s`)
	var checked bool
	for _, line := range strings.Split(ui.Strip(out), "\n") {
		if !strings.Contains(line, "145.230") {
			continue
		}
		m := seen.FindStringSubmatch(line)
		if m == nil {
			t.Fatalf("want a look count on the row: %q", line)
		}
		looks, _ := strconv.Atoi(m[1])
		possible, _ := strconv.Atoi(m[2])
		if looks < 2 || looks > possible {
			t.Errorf("looks %d of %d: %q", looks, possible, line)
		}
		checked = true
	}
	if !checked {
		t.Fatalf("no row for the carrier:\n%s", out)
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
		waitForSweep(t, c, cancel, done)
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

	t.Run("a write to a swept capture is refused", func(t *testing.T) {
		sock, c := harness(t, fakedaemon.Options{})
		listening(t, c)
		ctx, cancel := context.WithCancel(t.Context())
		done := make(chan struct{})
		go func() {
			defer close(done)
			_, _, _ = run(t, ctx, sock, "scan", "145M..147M", "--dwell", "150", "--take-over")
		}()
		waitForSweep(t, c, cancel, done)
		// A retune of the capture the sweep is walking, not a new one: the daemon refuses the
		// write itself, so this is the path that prints the sweeping reason for a write.
		_, _, err := run(t, t.Context(), sock, "set", "freq", "145.0")
		cancel()
		<-done
		if err == nil {
			t.Fatal("a capture retune must not land while a scan owns the radio")
		}
		if !strings.Contains(err.Error(), "scan is sweeping") {
			t.Errorf("want the sweeping reason, got %q", err)
		}
	})

	t.Run("a stopped sweep answers with the part that ran", func(t *testing.T) {
		sock, c := harness(t, fakedaemon.Options{})
		ctx, cancel := context.WithCancel(t.Context())
		type result struct {
			out, errOut string
			err         error
		}
		res := make(chan result, 1)
		go func() {
			out, errOut, err := run(t, ctx, sock, "scan", "145M..147M", "--dwell", "150")
			res <- result{out, errOut, err}
		}()
		// Stop it once it has something to keep: the point is that Ctrl-C answers with the
		// detections the sweep had already made, not an empty scan.
		deadline := time.Now().Add(10 * time.Second)
		for {
			st, err := c.State(t.Context())
			if err == nil && len(st.Jobs) > 0 && strings.Contains(st.Jobs[0].StatusDetail, "found") &&
				!strings.Contains(st.Jobs[0].StatusDetail, "0 found") {
				break
			}
			if time.Now().After(deadline) {
				cancel()
				<-res
				t.Fatal("the sweep never reported a detection")
			}
			time.Sleep(10 * time.Millisecond)
		}
		cancel()
		got := <-res
		if got.err != nil {
			t.Fatalf("an interrupted scan still prints what it found: %v\n%s\n%s", got.err, got.out, got.errOut)
		}
		if !strings.Contains(got.errOut, "stopped early: stopped in step ") {
			t.Errorf("the summary must say how far it got:\n%s", got.errOut)
		}
		if !strings.Contains(got.out, " MHz") {
			t.Errorf("the partial scan must carry its detections:\n%s", got.out)
		}
	})

	t.Run("a radio somebody just tuned is not free", func(t *testing.T) {
		sock, c := harness(t, fakedaemon.Options{})
		ctx := t.Context()
		listening(t, c)
		st, err := c.State(ctx)
		if err != nil || len(st.Channels) != 1 {
			t.Fatalf("state: %v %v", err, st)
		}
		// The channel goes, so nobody is listening; the capture keeps the moment it was made,
		// which is the don't-disturb window the allocator applies.
		if _, err := c.Control.DestroyChannel(ctx, &leylinev1.DestroyChannelRequest{ChannelId: st.Channels[0].ChannelId}); err != nil {
			t.Fatal(err)
		}
		_, errOut, err := run(t, ctx, sock, "scan", "145M..147M")
		if err == nil {
			t.Fatalf("a radio touched seconds ago must be left alone:\n%s", errOut)
		}
		if !strings.Contains(err.Error(), "was tuning this radio") {
			t.Errorf("want the recent-write reason, got %q", err)
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

// waitForSweep blocks until a scan reports RUNNING, so a test that needs the radio busy does not
// race the sweep's start on a loaded machine or its finish on a quick one.
func waitForSweep(t *testing.T, c *leyline.Client, cancel context.CancelFunc, done chan struct{}) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		st, err := c.State(t.Context())
		if err == nil && len(st.Jobs) > 0 && st.Jobs[0].State == leylinev1.JobState_RUNNING {
			return
		}
		if time.Now().After(deadline) {
			cancel()
			<-done
			t.Fatal("the scan never reported RUNNING")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// --gain says where the sweep pins the tuner, and the Scan says it ran there: only sweeps at a
// known gain can be compared. A gain that is not a gain is a usage error before
// anything is sent; an element the radio lacks fails the job with the daemon's code.
func TestScanRunsAtTheGainAskedFor(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	js := mustRun(t, sock, "--json", "scan", "145M..147M", "--gain", "30")
	var scan struct {
		Gains []struct {
			Element string  `json:"element"`
			Db      float64 `json:"db"`
			Auto    bool    `json:"auto"`
		} `json:"gains"`
		Config struct {
			Gains []map[string]any `json:"gains"`
		} `json:"config"`
	}
	if err := json.Unmarshal([]byte(js), &scan); err != nil {
		t.Fatalf("%v\n%s", err, js)
	}
	if len(scan.Gains) == 0 || scan.Gains[0].Auto || math.Abs(scan.Gains[0].Db-30) > 1 {
		t.Errorf("the sweep did not run at 30 dB: %+v", scan.Gains)
	}
	if len(scan.Config.Gains) != 1 || scan.Config.Gains[0]["db"] != 30.0 {
		t.Errorf("the Scan's config should echo the gain asked for: %v", scan.Config.Gains)
	}
	_, errOut, err := run(t, t.Context(), sock, "scan", "145M..147M", "--gain", "auto")
	if err != nil || !oneStageGain.MatchString(errOut) {
		t.Errorf("--gain auto: %v\n%s", err, errOut)
	}
	if _, _, err := run(t, t.Context(), sock, "scan", "145M..147M", "--gain", "loud"); exitCode(err) != ExitUsage {
		t.Errorf("--gain loud should be a usage error, got %v", err)
	}
}

// oneStageGain is a one-stage radio's gain as every screen prints it: the level alone, a decimal
// only when it has one (plans/v1-release.md, R-23).
var oneStageGain = regexp.MustCompile(`, gain \d+(\.\d)? dB\n`)

// --gain on a sweep takes the syntax every verb takes: stages by name, any case, in order, and
// the summary names every stage the sweep ran at with a switch as on or off. A stage the radio
// does not have fails the sweep with the ones it has (plans/v1-release.md, R-23).
func TestScanPinsEveryStageNamed(t *testing.T) {
	hackrf := fakedaemon.HackRFPro()
	sock, _ := harness(t, fakedaemon.Options{ExtraDevices: []*leylinev1.DeviceDescriptor{hackrf}})
	_, errOut, err := run(t, t.Context(), sock, "scan", "145M..147M", "--device", hackrf.DeviceId, "--gain", "lna=0,VGA=20,amp=11")
	if err != nil {
		t.Fatalf("ley scan: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, ", gain LNA 0 dB, VGA 20 dB, AMP on\n") {
		t.Errorf("the summary should name every stage as the device spells it:\n%s", errOut)
	}
	_, errOut, err = run(t, t.Context(), sock, "scan", "145M..147M", "--device", hackrf.DeviceId, "--gain", "LNA=0,IF=0")
	if err == nil || !strings.Contains(err.Error(), "no gain element named IF; this radio's are LNA, VGA and AMP") {
		t.Errorf("an unknown stage should fail the sweep with the stages the radio has, got %v\n%s", err, errOut)
	}
}

// Two scans are comparable only if taken at the same gain. The sweep pins the tuner for its
// duration and reports where, so two scans of a band can be read against each other.
func TestScanSaysWhatGainItRanAt(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out, errOut, err := run(t, t.Context(), sock, "scan", "145M..147M")
	if err != nil {
		t.Fatalf("ley scan: %v\n%s", err, errOut)
	}
	if !oneStageGain.MatchString(errOut) {
		t.Errorf("the summary should name the gain the sweep ran at:\n%s", errOut)
	}
	if oneStageGain.MatchString(out) {
		t.Errorf("prose reached stdout:\n%s", out)
	}
	// And the machine-readable answer carries it as a GainState, with the automatic gain frozen.
	js := mustRun(t, sock, "--json", "scan", "145M..147M")
	var scan struct {
		Gains []struct {
			Element string  `json:"element"`
			Db      float64 `json:"db"`
			Auto    bool    `json:"auto"`
		} `json:"gains"`
		Detections []struct {
			FirstSeen struct {
				CaptureID   string `json:"captureId"`
				SampleIndex string `json:"sampleIndex"`
			} `json:"firstSeen"`
			LastSeen struct {
				SampleIndex string `json:"sampleIndex"`
			} `json:"lastSeen"`
		} `json:"detections"`
	}
	if err := json.Unmarshal([]byte(strings.TrimSpace(js)), &scan); err != nil {
		t.Fatalf("%v\n%s", err, js)
	}
	if len(scan.Gains) != 1 || scan.Gains[0].Element != "TUNER" || scan.Gains[0].Db <= 0 || scan.Gains[0].Auto {
		t.Fatalf("scan gains = %+v", scan.Gains)
	}
	// When a detection was seen is part of the evidence: a carrier heard once at the start of a
	// sweep and a carrier heard throughout are not the same finding.
	if len(scan.Detections) == 0 {
		t.Fatal("no detections")
	}
	for _, d := range scan.Detections {
		first, _ := strconv.ParseUint(d.FirstSeen.SampleIndex, 10, 64)
		last, _ := strconv.ParseUint(d.LastSeen.SampleIndex, 10, 64)
		if first == 0 || last < first {
			t.Errorf("detection seen from %d to %d", first, last)
		}
	}
}

// A sweep does not look at the middle of its own span, because the radio's DC spike sits there,
// and a request that fits entirely inside that hole is a range nothing can see. A file device has
// one tuning point and so no neighbouring step to cover the hole, which is where this happens:
// the daemon refuses with BLIND_SPOT rather than reporting an empty band as a quiet one.
func TestScanRefusesTheBlindSpot(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{})
	dir := t.TempDir()
	iq := filepath.Join(dir, "tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	side := `{"format":"cf32","sample_rate":2400000,"center_hz":146520000}`
	if err := os.WriteFile(filepath.Join(dir, "tone.json"), []byte(side), 0o644); err != nil {
		t.Fatal(err)
	}
	dev, err := c.Control.AttachFileDevice(t.Context(), &leylinev1.AttachFileDeviceRequest{Path: iq, Loop: true})
	if err != nil {
		t.Fatal(err)
	}
	_, _, err = run(t, t.Context(), sock, "scan", "146.45M..146.59M", "--device", dev.DeviceId)
	if err == nil {
		t.Fatal("a scan of nothing but the DC guard should fail")
	}
	for _, want := range []string{"DC spike", "146.520 MHz", "ley spectrum"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("blind-spot refusal lacks %q: %v", want, err)
		}
	}
}

// `ley scan gmrs` resolves a band name in the positional, and the name is the whole service:
// both halves and the 5 MHz between them, so a repeater's transmit is found whichever half it
// sits in and however it is paired. A half answers to its own name.
func TestScanResolvesABandName(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	_, errOut, err := run(t, t.Context(), sock, "scan", "gmrs")
	if err != nil {
		t.Fatalf("ley scan gmrs: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "462.5375 MHz to 467.7375 MHz") {
		t.Errorf("scan did not sweep the whole GMRS service:\n%s", errOut)
	}
	_, errOut, err = run(t, t.Context(), sock, "scan", "gmrs-462")
	if err != nil || !strings.Contains(errOut, "462.5375 MHz to 462.7375 MHz") {
		t.Errorf("ley scan gmrs-462: %v\n%s", err, errOut)
	}
}

// The scan labels every GMRS detection with its channel number (ch1..ch22), the numbering every
// GMRS radio shares, so a row is unambiguous. The eight repeater outputs are ch15..ch22 (rpt1..8
// still tune them). presetAt takes the nearest within 6 kHz, since the channels are only 12.5 kHz
// apart, and a tie goes to the earlier plan entry (the plan's KTD2).
func TestScanLabelsGMRSChannels(t *testing.T) {
	cases := []struct {
		hz    uint64
		label string
	}{
		{462_625_000, "ch18"},      // the repeater output the owner found
		{462_562_500, "ch1"},       // a 462 interstitial
		{462_600_000, "ch17"},      // RPT3's frequency, labelled by channel number
		{467_562_500, "ch8"},       // a 467 interstitial (the inputs band)
		{462_628_000, "ch18"},      // 3 kHz off ch18: nearest wins
		{462_664_000, "ch5"},       // 1.5 kHz above ch5
		{462_660_000, "ch5"},       // 2.5 kHz below ch5
		{162_475_000, "wx3"},       // the plan-prefixed alias is what the column prints
		{157_100_000, "marine22a"}, // a tie: the US variant is entered before ITU 22
		{161_975_000, "marine87b"}, // AIS 1
		{27_185_000, "cb19"},
		{151_820_000, "murs1"},
		{156_807_000, ""}, // 7 kHz above marine 16 and 18 below 17: on nothing
	}
	for _, c := range cases {
		if got := presetAt(c.hz); got != c.label {
			t.Errorf("presetAt(%d) = %q, want %q", c.hz, got, c.label)
		}
	}
	// Marine channel 16 keeps its own name after ceding the bare "ch16" alias to GMRS.
	if p, err := bandplan.ResolvePreset("ch16"); err != nil || p.Hz != 462_575_000 {
		t.Errorf("ch16 should now be GMRS channel 16: %+v %v", p, err)
	}
	if p, err := bandplan.ResolvePreset("marine16"); err != nil || p.Hz != 156_800_000 {
		t.Errorf("marine16 must still resolve: %+v %v", p, err)
	}
}
