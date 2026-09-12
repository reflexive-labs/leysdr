// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
)

// TestWatchFiltersByWhere: a --where filter is evaluated in the daemon, so an attached watch
// streams only the matching records and its banner says what the filter is.
func TestWatchFiltersByWhere(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "watch", "aprs", "--where", "device_id=LEYTST-1", "--count", "3")
	if err != nil {
		t.Fatalf("ley watch: %v\n%s", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want three matching records, got:\n%s", out)
	}
	for _, l := range lines {
		if !strings.Contains(l, "LEYTST-1") {
			t.Errorf("a non-matching record reached stdout: %q", l)
		}
	}
	if !strings.Contains(errOut, "watching aprs") || !strings.Contains(errOut, "device_id = LEYTST-1") {
		t.Errorf("the banner must name the decoder and the filter: %q", errOut)
	}
}

// TestWatchCountyMatchesFips: --county is a CONTAINS test on the fips field, so it matches the
// station whose FIPS list names the code and no other.
func TestWatchCountyMatchesFips(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "watch", "aprs", "--county", "006001", "--count", "2")
	if err != nil {
		t.Fatalf("ley watch --county: %v\n%s", err, errOut)
	}
	for _, l := range strings.Split(strings.TrimSpace(out), "\n") {
		if !strings.Contains(l, "LEYTST-1") {
			t.Errorf("only the station carrying the FIPS list matches --county: %q", l)
		}
	}
	if !strings.Contains(errOut, "fips names one of 006001") {
		t.Errorf("the banner must describe the county filter: %q", errOut)
	}
}

// TestWatchNotifyShellFires: a detached watch's shell notifier runs in the daemon with the
// record's device id in the environment, so it fires with no client attached. The command writes
// the device ids to a file the test reads back.
func TestWatchNotifyShellFires(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	hits := filepath.Join(t.TempDir(), "hits.txt")
	cmd := fmt.Sprintf("printf '%%s\\n' \"$LEYLINE_DEVICE_ID\" >> %s", hits)
	_, errOut, err := run(t, ctx, sock, "watch", "aprs", "--where", "device_id=LEYTST-1",
		"--notify="+"shell:"+cmd, "--detach")
	if err != nil {
		t.Fatalf("ley watch --detach: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "left running") || !strings.Contains(errOut, "shell:") {
		t.Errorf("stderr must say the job is kept and name the notifier: %q", errOut)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		b, _ := os.ReadFile(hits)
		if strings.Contains(string(b), "LEYTST-1") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the shell notifier never fired: %q", string(b))
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Only matching records fire it: nothing but LEYTST-1 is in the file.
	b, _ := os.ReadFile(hits)
	for _, l := range strings.Fields(string(b)) {
		if l != "LEYTST-1" {
			t.Errorf("a non-matching record fired the notifier: %q", l)
		}
	}
	jobs, _ := c.ListJobs(ctx)
	for _, j := range jobs {
		_, _ = c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
	}
}

// TestWatchJSON: --json is NDJSON of the matching DecodeRecords and nothing else on stdout; the
// banner stays on stderr.
func TestWatchJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "--json", "watch", "aprs", "--where", "device_id=LEYTST-1", "--count", "2")
	if err != nil {
		t.Fatalf("ley watch --json: %v", err)
	}
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		var rec map[string]any
		if err := json.Unmarshal([]byte(line), &rec); err != nil {
			t.Fatalf("NDJSON line is not JSON (%v): %s", err, line)
		}
		if rec["deviceId"] != "LEYTST-1" || rec["protocol"] != "aprs" {
			t.Errorf("record shape or filter: %s", line)
		}
	}
	if strings.Contains(out, "watching aprs") || !strings.Contains(errOut, "watching aprs") {
		t.Errorf("the banner belongs on stderr, whatever the format")
	}
}

// TestWatchDetachedLeavesJobRunning: --detach keeps the job in the daemon after ley exits, past
// the presence grace, and prints how to stop it.
func TestWatchDetachedLeavesJobRunning(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 100 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "watch", "aprs", "--where", "device_id=LEYTST-1", "--detach")
	if err != nil {
		t.Fatalf("ley watch --detach: %v", err)
	}
	if strings.TrimSpace(out) != "" {
		t.Errorf("a detached watch streams nothing on stdout:\n%s", out)
	}
	if !strings.Contains(errOut, "left running") || !strings.Contains(errOut, "ley jobs cancel") {
		t.Errorf("stderr must say the job is kept and how to stop it: %q", errOut)
	}
	time.Sleep(400 * time.Millisecond)
	jobs, err := c.ListJobs(ctx)
	if err != nil || len(jobs) != 1 {
		t.Fatalf("jobs: %v (%v)", jobs, err)
	}
	if jobs[0].GetState() != leylinev1.JobState_RUNNING {
		t.Fatalf("the kept watch is %s, want RUNNING", jobs[0].GetState())
	}
	if _, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: jobs[0].GetJobId()}); err != nil {
		t.Fatal(err)
	}
}

// A watch with no filter flags is decode with a notifier: the predicate is nil (matches
// everything) and the banner says so.
func TestWatchNoFilterMatchesEverything(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "watch", "aprs", "--count", "3")
	if err != nil {
		t.Fatalf("ley watch: %v\n%s", err, errOut)
	}
	if len(strings.Split(strings.TrimSpace(out), "\n")) != 3 {
		t.Fatalf("want three records:\n%s", out)
	}
	if !strings.Contains(errOut, "everything (no filter)") {
		t.Errorf("the banner must say there is no filter: %q", errOut)
	}
}

// A --where token with no operator is a usage error before the daemon is touched.
func TestWatchBadWhere(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	_, _, err := run(t, context.Background(), sock, "watch", "aprs", "--where", "device_id")
	if exitCode(err) != 2 {
		t.Fatalf("exit %d (%v), want 2", exitCode(err), err)
	}
}
