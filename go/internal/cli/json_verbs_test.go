// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// jsonVerbCase is one command and what --json must give a script that types
// it: either machine output on stdout, or a usage error saying so. Nothing
// else is allowed.
type jsonVerbCase struct {
	// path is the command path under `ley`, as the tree spells it.
	path string
	// args run the verb far enough to answer; the path leads them.
	args []string
	// refuse is a fragment of the usage error the verb must exit 2 with.
	// Empty means it prints JSON instead.
	refuse string
	// prep runs before the verb against the same fake daemon and appends
	// arguments the daemon only just minted (a job id, a device id, a file).
	prep func(t *testing.T, sock string, c *leyline.Client) []string
	// noDaemon points the verb at a socket nothing answers on.
	noDaemon bool
	// env is the environment the verb runs with, built per run: a verb that writes a user's
	// store is pointed at a temp file here rather than at the machine's.
	env func(t *testing.T) map[string]string
	// timeout bounds a verb that otherwise streams until Ctrl-C.
	timeout time.Duration
}

// jsonNoOutput is the refusal shared by every verb whose output is a script, a
// file or a launchd action rather than data.
const jsonNoOutput = "no --json output"

var jsonVerbs = []jsonVerbCase{
	// The bare `ley` is the orientation screen, and a script asking it where
	// things stand gets the state snapshot.
	{path: "ley", args: nil},
	{path: "bands", args: []string{"bands"}},
	{path: "bookmarks", args: []string{"bookmarks"}, env: tempBookmarks},
	{path: "bookmarks add", args: []string{"bookmarks", "add", "146.94", "--name", "Local repeater"}, env: tempBookmarks},
	{path: "bookmarks move", args: []string{"bookmarks", "move", "Local repeater", "147.0"}, env: seededBookmarks},
	{path: "bookmarks remove", args: []string{"bookmarks", "remove", "Local repeater"}, env: seededBookmarks},
	{path: "bookmarks import", args: []string{"bookmarks", "import", "../../../fixtures/chirp/sample.csv"}, env: tempBookmarks},
	{path: "completion", args: []string{"completion"}, refuse: jsonNoOutput},
	{path: "completion bash", args: []string{"completion", "bash"}, refuse: jsonNoOutput},
	{path: "completion fish", args: []string{"completion", "fish"}, refuse: jsonNoOutput},
	{path: "completion powershell", args: []string{"completion", "powershell"}, refuse: jsonNoOutput},
	{path: "completion zsh", args: []string{"completion", "zsh"}, refuse: jsonNoOutput},
	{path: "daemon install", args: []string{"daemon", "install"}, refuse: jsonNoOutput},
	{path: "daemon logs", args: []string{"daemon", "logs"}, refuse: jsonNoOutput},
	{path: "daemon uninstall", args: []string{"daemon", "uninstall"}, refuse: jsonNoOutput},
	{path: "decode", args: []string{"decode", "aprs", "--count", "2"}},
	{path: "decoders", args: []string{"decoders"}},
	// start against a daemon already answering reports it rather than
	// spawning a second one; stop is the one verb that must not find one,
	// because the pid the fake reports is this test process.
	{path: "daemon start", args: []string{"daemon", "start"}},
	{path: "daemon status", args: []string{"daemon", "status"}},
	{path: "daemon stop", args: []string{"daemon", "stop"}, noDaemon: true},
	{path: "devices", args: []string{"devices"}},
	{path: "devices attach", args: []string{"devices", "attach", "rtltcp", "pi.local:1234"}},
	{path: "devices detach", args: []string{"devices", "detach"}, prep: prepPlaybackDevice},
	{path: "fft", args: []string{"fft", "--freq", "146.52", "--count", "2"}},
	{path: "help", args: []string{"help"}, refuse: jsonNoOutput},
	{path: "jobs", args: []string{"jobs"}, prep: prepSweepOnly},
	{path: "jobs cancel", args: []string{"jobs", "cancel"}, prep: prepSweep},
	{path: "levels", args: []string{"levels", "146.52", "--count", "2"}},
	{path: "listen", args: []string{"listen", "146.52", "--count", "2"}},
	{path: "mcp", args: []string{"mcp"}, refuse: jsonNoOutput},
	{path: "monitor", args: []string{"monitor", "gmrs-462", "--for", "1s"}},
	{path: "phosphor", args: []string{"phosphor", "146.52", "--count", "1", "--bins", "32", "--levels", "8"}},
	{path: "play", args: []string{"play"}, prep: prepIQFile, timeout: 2 * time.Second},
	{path: "presets", args: []string{"presets"}},
	{path: "record", args: []string{"record", "146.52", "--for", "300ms"}},
	{path: "recordings", args: []string{"recordings"}, prep: prepRecordingOnly},
	{path: "recordings show", args: []string{"recordings", "show"}, prep: prepRecording},
	{path: "recordings path", args: []string{"recordings", "path"}, prep: prepRecording},
	{path: "recordings delete", args: []string{"recordings", "delete", "--yes"}, prep: prepRecording},
	{path: "records", args: []string{"records"}, prep: prepKeptDecode},
	{path: "track", args: []string{"track", "aprs", "--count", "1"}},
	{path: "devices-seen", args: []string{"devices-seen"}, prep: prepKeptDecode},
	{path: "label", args: []string{"label", "LEYTST-1"}},
	{path: "scan", args: []string{"scan", "145M..147M"}},
	{path: "scope", args: []string{"scope", "146.52", "--count", "2"}},
	{path: "set", args: []string{"set"}, prep: prepChannel},
	{path: "spectrum", args: []string{"spectrum", "146.52"}},
	{path: "state", args: []string{"state"}},
	{path: "stop", args: []string{"stop", "all"}, prep: prepChannel},
	{path: "tune", args: []string{"tune", "146.52", "--no-audio"}, timeout: 2 * time.Second},
	{path: "version", args: []string{"version"}},
	{path: "watch", args: []string{"watch", "aprs", "--where", "device_id=LEYTST-1", "--count", "2"}},
	{path: "waveform", args: []string{"waveform", "146.52", "--seconds", "2", "--count", "2"}},
	{path: "waterfall", args: []string{"waterfall", "146.52", "--count", "2", "--rate", "10"}},
}

// tempBookmarks points the bookmarks verbs at a store of their own: add and remove write a file
// a person keeps, and a test must not write the one on this machine.
func tempBookmarks(t *testing.T) map[string]string {
	t.Helper()
	return map[string]string{bookmarks.BookmarksEnv: filepath.Join(t.TempDir(), "bookmarks.json")}
}

// seededBookmarks is tempBookmarks with one bookmark already in it, for the verbs that move or
// forget one.
func seededBookmarks(t *testing.T) map[string]string {
	t.Helper()
	env := tempBookmarks(t)
	s, err := bookmarks.Open(env[bookmarks.BookmarksEnv])
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Add("Local repeater", 146_940_000, leylinev1.DemodMode_NFM, 0); err != nil {
		t.Fatal(err)
	}
	return env
}

// prepChannel leaves a channel running for the verbs that adjust or stop one.
func prepChannel(t *testing.T, sock string, _ *leyline.Client) []string {
	t.Helper()
	mustRun(t, sock, "tune", "146.52", "--no-audio", "--persistent")
	return nil
}

// prepSweep leaves a job in the list, and names it for `jobs cancel`. The
// harness client starts it: the daemon cancels a sweep whose client has gone.
func prepSweep(t *testing.T, _ string, c *leyline.Client) []string {
	t.Helper()
	return []string{startSweep(t, c)}
}

// prepSweepOnly leaves the same job for a verb that takes no id.
func prepSweepOnly(t *testing.T, sock string, c *leyline.Client) []string {
	t.Helper()
	prepSweep(t, sock, c)
	return nil
}

// prepRecording leaves one finished recording in the store, and names it for
// the verbs that take an id.
func prepRecording(t *testing.T, sock string, _ *leyline.Client) []string {
	t.Helper()
	out := mustRun(t, sock, "--json", "record", "146.52", "--for", "300ms")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var job struct {
		JobID string `json:"jobId"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &job); err != nil || job.JobID == "" {
		t.Fatalf("ley record --json: no job id in %q (%v)", lines[0], err)
	}
	return []string{job.JobID}
}

// prepRecordingOnly leaves the same recording for a verb that takes no id.
func prepRecordingOnly(t *testing.T, sock string, c *leyline.Client) []string {
	t.Helper()
	prepRecording(t, sock, c)
	return nil
}

// prepKeptDecode leaves a kept decode job running, so the store has something for `ley records`
// to answer with. The harness client starts it: a kept job outlives its client either way.
func prepKeptDecode(t *testing.T, _ string, c *leyline.Client) []string {
	t.Helper()
	job, err := c.StartDecode(t.Context(), &leylinev1.DecodeConfig{Decoder: "aprs", Keep: true})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = c.Jobs.CancelJob(context.Background(), &leylinev1.JobRef{JobId: job.JobId})
	})
	waitFor(t, "two records in the store", func() bool {
		page, err := c.QueryRecords(t.Context(), &leylinev1.RecordQuery{Protocol: "aprs"})
		return err == nil && len(page.GetRecords()) >= 2
	})
	return nil
}

// prepIQFile writes the smallest file `ley play` will open, and names it.
func prepIQFile(t *testing.T, _ string, _ *leyline.Client) []string {
	t.Helper()
	dir := t.TempDir()
	iq := filepath.Join(dir, "tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	side := `{"format":"cf32","sample_rate":2400000,"center_hz":146520000}`
	if err := os.WriteFile(filepath.Join(dir, "tone.json"), []byte(side), 0o644); err != nil {
		t.Fatal(err)
	}
	return []string{iq, "--no-audio"}
}

// prepPlaybackDevice leaves a file playback device attached, and names it:
// detach refuses a real radio, so there has to be one to remove.
func prepPlaybackDevice(t *testing.T, sock string, c *leyline.Client) []string {
	t.Helper()
	args := prepIQFile(t, sock, c)
	mustRun(t, sock, "play", args[0], "--no-audio", "--persistent")
	st, err := c.State(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	for _, d := range st.Devices {
		if d.Driver == "file" {
			return []string{d.DeviceId}
		}
	}
	t.Fatal("ley play --persistent left no playback device to detach")
	return nil
}

// Every verb answers --json or refuses it. A verb that draws a picture under
// --json and exits 0 hands a script unparseable text with no way to tell that
// anything went wrong.
func TestEveryVerbAnswersOrRefusesJSON(t *testing.T) {
	t.Parallel()
	for _, c := range jsonVerbs {
		t.Run(c.path, func(t *testing.T) {
			sock := testutil.SocketPath(t, "gone.sock")
			var client *leyline.Client
			if !c.noDaemon {
				sock, client = harness(t, fakedaemon.Options{})
			}
			args := append([]string{"--json"}, c.args...)
			if c.prep != nil {
				args = append(args, c.prep(t, sock, client)...)
			}
			// A verb that streams until Ctrl-C is stopped the way Ctrl-C
			// stops it, by cancelling: a deadline reaches the daemon as
			// DEADLINE_EXCEEDED, which is a real error rather than the
			// clean exit this checks for.
			ctx := t.Context()
			if c.timeout > 0 {
				var cancel context.CancelFunc
				ctx, cancel = context.WithCancel(ctx)
				defer cancel()
				time.AfterFunc(c.timeout, cancel)
			}
			var env map[string]string
			if c.env != nil {
				env = c.env(t)
			}
			out, errOut, err := runEnv(t, ctx, sock, env, args...)
			if c.refuse != "" {
				if exitCode(err) != ExitUsage || err == nil || !strings.Contains(err.Error(), c.refuse) {
					t.Fatalf("ley %v: want exit %d saying %q, got exit %d (%v)", args, ExitUsage, c.refuse, exitCode(err), err)
				}
				if out != "" {
					t.Errorf("a refused verb writes nothing to stdout, got:\n%s", out)
				}
				return
			}
			if err != nil {
				t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
			}
			lines := strings.Split(strings.TrimSpace(out), "\n")
			if strings.TrimSpace(out) == "" {
				t.Fatalf("ley %v printed nothing on stdout; stderr:\n%s", args, errOut)
			}
			for _, l := range lines {
				var found any
				if err := json.Unmarshal([]byte(l), &found); err != nil {
					t.Fatalf("ley %v: stdout is not NDJSON (%v): %q", args, err, l)
				}
			}
		})
	}
}

// The table above must cover the whole tree, so the tree is walked and every
// command that runs has to be in it, the root included. The help
// topics are left out: they are `ley help <topic>` under another name, print
// prose whatever the flags, and never reach the daemon.
func TestJSONVerbTableCoversTheTree(t *testing.T) {
	root := NewRootCommand(&App{LookupEnv: func(string) (string, bool) { return "", false }})
	root.InitDefaultHelpCmd()
	listed := map[string]bool{}
	for _, c := range jsonVerbs {
		listed[c.path] = true
	}
	found := map[string]bool{}
	var walk func(c *cobra.Command)
	walk = func(c *cobra.Command) {
		for _, sub := range c.Commands() {
			walk(sub)
		}
		if !c.Runnable() {
			return
		}
		path := strings.TrimPrefix(c.CommandPath(), "ley ")
		found[path] = true
		if !listed[path] {
			t.Errorf("`ley %s` runs but no jsonVerbs row says what --json does with it", path)
		}
	}
	walk(root)
	for path := range listed {
		if !found[path] {
			t.Errorf("jsonVerbs names %q, which the command tree no longer has", path)
		}
	}
}
