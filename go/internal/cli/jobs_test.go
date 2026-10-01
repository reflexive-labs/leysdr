// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// startSweep starts a sweep wide enough to still be running while the test looks at it. It is
// started from the harness client, which stays connected for the whole test: the daemon cancels a
// sweep whose client has gone.
func startSweep(t *testing.T, c *leyline.Client) string {
	t.Helper()
	job, err := c.Jobs.StartJob(t.Context(), &leylinev1.StartJobRequest{
		Config: &leylinev1.StartJobRequest_Scan{Scan: &leylinev1.ScanConfig{
			Range:    &leylinev1.FrequencyRange{MinHz: 88_000_000, MaxHz: 200_000_000},
			DwellMs:  200,
			Schedule: &leylinev1.ScanConfig_Once{Once: true},
		}},
	})
	if err != nil {
		t.Fatalf("StartJob: %v", err)
	}
	return job.JobId
}

func TestJobsListsAFinishedSweep(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "scan", "145M..147M")

	out := mustRun(t, sock, "jobs")
	for _, want := range []string{"WHAT", "RANGE", "STATE", "AGE", "DETAIL", "scan", "145.000 MHz to 147.000 MHz", "completed"} {
		if !strings.Contains(out, want) {
			t.Errorf("jobs table lacks %q:\n%s", want, out)
		}
	}
	// The id is behind --wide, as it is in ley devices.
	if strings.Contains(out, "job_") {
		t.Errorf("the default table must not lead with ids:\n%s", out)
	}
	if wide := mustRun(t, sock, "jobs", "--wide"); !strings.Contains(wide, "job_") {
		t.Errorf("--wide lacks the id column:\n%s", wide)
	}
}

func TestJobsJSONIsTheListJobsResponse(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	mustRun(t, sock, "scan", "145M..147M")

	out := mustRun(t, sock, "--json", "jobs")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 1 {
		t.Fatalf("want one ListJobsResponse, got %d lines:\n%s", len(lines), out)
	}
	var resp map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &resp); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	jobs, _ := resp["jobs"].([]any)
	if len(jobs) != 1 {
		t.Fatalf("want one job: %s", lines[0])
	}
	// The proto3 JSON mapping: lowerCamelCase, enums by name, 64-bit integers as strings.
	j := jobs[0].(map[string]any)
	for _, k := range []string{"jobId", "state", "createdAtNs", "scan", "resultUris"} {
		if _, ok := j[k]; !ok {
			t.Errorf("Job lacks %q: %s", k, lines[0])
		}
	}
	if j["state"] != "COMPLETED" {
		t.Errorf("want a COMPLETED job: %s", lines[0])
	}
}

func TestJobsWithNothingRunning(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "jobs")
	if !strings.Contains(out, "no jobs") {
		t.Errorf("an empty table should say so:\n%s", out)
	}
	if out := mustRun(t, sock, "--json", "jobs"); strings.TrimSpace(out) != "{}" {
		t.Errorf("--json with no jobs should print an empty response, got %q", out)
	}
}

// The point of the verb: a sweep started somewhere else can be seen and stopped from here.
func TestJobsCancelStopsARunningSweep(t *testing.T) {
	sock, c := harness(t, fakedaemon.Options{PresenceGrace: 30 * time.Second})
	id := startSweep(t, c)

	out := mustRun(t, sock, "jobs")
	if !strings.Contains(out, "running") {
		t.Fatalf("the sweep is not listed as running:\n%s", out)
	}
	// By row number, the way the table names it.
	if out := mustRun(t, sock, "jobs", "cancel", "1"); !strings.Contains(out, id) || !strings.Contains(out, "cancelled") {
		t.Errorf("cancel said %q, want %s cancelled", strings.TrimSpace(out), id)
	}
	if out := mustRun(t, sock, "jobs"); strings.Contains(out, "running") {
		t.Errorf("the sweep is still running:\n%s", out)
	}
	// Cancelling what has already stopped is not an error: the reader asked for it to be stopped
	// and it is stopped.
	out = mustRun(t, sock, "--json", "jobs", "cancel", id)
	var j map[string]any
	if err := json.Unmarshal([]byte(out), &j); err != nil {
		t.Fatalf("%v\n%s", err, out)
	}
	if j["state"] != "CANCELLED" || j["jobId"] != id {
		t.Errorf("want the Job the daemon left: %s", out)
	}
}

func TestJobsCancelNamesTheWayOut(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	// Nothing has ever run: the hint is the verb that starts a job, not an empty list.
	_, _, err := run(t, t.Context(), sock, "jobs", "cancel", "1")
	if err == nil || !strings.Contains(err.Error(), "ley scan") {
		t.Errorf("a daemon with no jobs should say where one comes from: %v", err)
	}
	mustRun(t, sock, "scan", "145M..147M")
	_, _, err = run(t, t.Context(), sock, "jobs", "cancel", "job_nosuchthing")
	if err == nil {
		t.Fatal("cancelling a job that is not there should fail")
	}
	if !strings.Contains(err.Error(), "ley jobs") {
		t.Errorf("the error should say where the list is: %v", err)
	}
	// A job has no frequency of its own, so the hint must not offer one.
	if strings.Contains(err.Error(), "frequency") {
		t.Errorf("a job cannot be named by frequency: %v", err)
	}
}
