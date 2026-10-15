// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// speechLiveOpts is a fake whose live speech job hears these words, one over each, in order.
func speechLiveOpts(t *testing.T) fakedaemon.Options {
	t.Helper()
	return fakedaemon.Options{
		RecordingsDir: t.TempDir(),
		SpeechScript:  []string{"alpha one", "this is net control, go ahead", "bravo two"},
	}
}

// Speech has no frequency of its own, so decode and watch refuse it without --freq, naming the
// flag, before any job starts.
func TestSpeechNeedsAFrequency(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, speechLiveOpts(t))
	for _, verb := range []string{"decode", "watch"} {
		_, _, err := run(t, t.Context(), sock, verb, "speech")
		if exitCode(err) != ExitUsage || !strings.Contains(err.Error(), "--freq") ||
			!strings.Contains(err.Error(), "speech has no frequency of its own") {
			t.Errorf("ley %s speech: exit %d (%v), want a usage error naming --freq", verb, exitCode(err), err)
		}
	}
	if jobs, _ := c.ListJobs(t.Context()); len(jobs) != 0 {
		t.Errorf("a refused decode started jobs: %v", jobs)
	}
}

// overLinePattern is a live speech line: the clock, the part and over, two spaces, the words.
var overLinePattern = regexp.MustCompile(`^\d\d:\d\d:\d\d part (\d+) over 1  (.+)$`)

// A live speech decode prints each over as transcribe does and says where the clips are; an
// unkept job's clips go when it ends.
func TestDecodeSpeechOnTheAir(t *testing.T) {
	t.Parallel()
	opts := speechLiveOpts(t)
	sock, c := harness(t, opts)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "decode", "speech", "--freq", "146.94", "--count", "2")
	if err != nil {
		t.Fatalf("ley decode speech: %v\n%s", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want two overs, got:\n%s", out)
	}
	for i, l := range lines {
		m := overLinePattern.FindStringSubmatch(l)
		if m == nil || m[1] != fmt.Sprint(i+1) || m[2] != opts.SpeechScript[i] {
			t.Errorf("line %d: %q, want part %d over 1 and %q", i, l, i+1, opts.SpeechScript[i])
		}
	}
	if !strings.Contains(errOut, "decoding speech on 146.940 MHz") ||
		!regexp.MustCompile(`The overs are recorded as ley://recordings/job_\w+ until the job ends\.`).MatchString(errOut) {
		t.Errorf("the banner must say where the clips are and that they go with the job:\n%s", errOut)
	}
	jobs, _ := c.ListJobs(ctx)
	if len(jobs) != 1 || jobs[0].GetState() != leylinev1.JobState_CANCELLED {
		t.Fatalf("jobs: %v", jobs)
	}
	if _, err := os.Stat(filepath.Join(opts.RecordingsDir, jobs[0].GetJobId())); !os.IsNotExist(err) {
		t.Errorf("an unkept job's clips must be gone when it ends: %v", err)
	}
}

// A kept job's clips stay a resource: ley recordings lists them, and ley records shows each
// record's CLIP as part/over beside its words.
func TestDecodeSpeechKeepsItsClips(t *testing.T) {
	t.Parallel()
	opts := speechLiveOpts(t)
	sock, c := harness(t, opts)
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "--json", "decode", "speech", "--freq", "146.94", "--job", "--count", "3")
	if err != nil {
		t.Fatalf("ley decode speech --job: %v\n%s", err, errOut)
	}
	jobs, _ := c.ListJobs(ctx)
	if len(jobs) != 1 {
		t.Fatalf("jobs: %v", jobs)
	}
	id := jobs[0].GetJobId()
	if got := jobs[0].GetResultUris(); len(got) != 2 || got[0] != "ley://records/"+id || got[1] != "ley://recordings/"+id {
		t.Errorf("result uris %v, want the records and the clips", got)
	}
	if !strings.Contains(out, `"clipUri":"ley://recordings/`+id+`/1"`) || !strings.Contains(out, `"over":1`) {
		t.Errorf("--json records lack their clip and over:\n%s", out)
	}
	if _, err := c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: id}); err != nil {
		t.Fatal(err)
	}
	listed := mustRun(t, sock, "recordings")
	if !strings.Contains(listed, id[:12]) && !strings.Contains(listed, id) {
		t.Errorf("ley recordings does not list the kept job's clips:\n%s", listed)
	}
	table := mustRun(t, sock, "records", "--protocol", "speech")
	for _, want := range []string{"CLIP", "1/1", "2/1", "3/1", "net control", "bravo two"} {
		if !strings.Contains(table, want) {
			t.Errorf("ley records --protocol speech lacks %q:\n%s", want, table)
		}
	}
	plain := mustRun(t, sock, "records", "--protocol", "aprs")
	if strings.Contains(plain, "CLIP") {
		t.Errorf("a page with no clips has no CLIP column:\n%s", plain)
	}
}

// ley watch speech --where 'text~net control' passes only the over that says it, to the stream
// and to the notifier, and a detached one runs on with the notifier and the clips named.
func TestWatchSpeechForAPhrase(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{
		RecordingsDir: t.TempDir(), PresenceGrace: 100 * time.Millisecond,
		SpeechScript: []string{"alpha one", "this is net control, go ahead", "bravo two", "net check-in"},
	})
	ctx, cancel := context.WithTimeout(t.Context(), 10*time.Second)
	defer cancel()
	hits := filepath.Join(t.TempDir(), "hits.json")
	_, errOut, err := run(t, ctx, sock, "watch", "speech", "--freq", "146.52", "--where", "text~net control",
		"--notify=shell:cat >> "+hits+"; echo >> "+hits, "--detach")
	if err != nil {
		t.Fatalf("ley watch speech --detach: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "text contains net control") || !strings.Contains(errOut, "overs recorded as ley://recordings/job_") ||
		!strings.Contains(errOut, "left running") {
		t.Errorf("the banner must give the filter, the clips and how to stop it:\n%s", errOut)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		b, _ := os.ReadFile(hits)
		if strings.Contains(string(b), "net control") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the notifier never fired: %q", b)
		}
		time.Sleep(20 * time.Millisecond)
	}
	// Past the next three overs, none of which says it.
	time.Sleep(4 * fakedaemon.RecordInterval)
	b, _ := os.ReadFile(hits)
	if strings.Count(string(b), "net control") != 1 || strings.Contains(string(b), "alpha one") || strings.Contains(string(b), "net check-in") {
		t.Errorf("only the over that says net control fires the notifier:\n%s", b)
	}
	jobs, _ := c.ListJobs(ctx)
	for _, j := range jobs {
		if j.GetState() != leylinev1.JobState_RUNNING || !j.GetDecode().GetKeep() {
			t.Errorf("a detached watch is a kept running job: %v", j)
		}
		_, _ = c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
	}

	// Bare --notify is the macOS notification; the daemon takes it whatever it runs on.
	_, errOut, err = run(t, ctx, sock, "watch", "speech", "--freq", "146.52", "--where", "text~net control", "--notify", "--detach")
	if err != nil || !strings.Contains(errOut, "notify: macOS notification") {
		t.Errorf("--notify --detach: %v\n%s", err, errOut)
	}
	jobs, _ = c.ListJobs(ctx)
	for _, j := range jobs {
		_, _ = c.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
	}
}
