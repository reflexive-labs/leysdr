// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// recordHarness is a fake daemon whose recordings land in a directory the test
// owns, so a test can read what was written as well as what was reported.
func recordHarness(t *testing.T, gateAt ...int64) (string, string) {
	t.Helper()
	dir := t.TempDir()
	sock, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, RecordGateAt: gateAt})
	return sock, dir
}

// A recording is a job whose output is a resource: the banner states the decisions, the URI is
// on stdout for a script, and the files are where the daemon says they are.
func TestRecordWritesAResourceAndSaysWhereItIs(t *testing.T) {
	sock, dir := recordHarness(t)
	out, errOut, err := run(t, t.Context(), sock, "record", "146.52", "--for", "400ms")
	if err != nil {
		t.Fatalf("ley record: %v\n%s\n%s", err, out, errOut)
	}
	uri := strings.TrimSpace(out)
	if !strings.HasPrefix(uri, "ley://recordings/job_") {
		t.Fatalf("stdout must be the recording's uri, got %q", uri)
	}
	// The banner is for the person and belongs on stderr, with the decisions the daemon made.
	for _, want := range []string{"Recording", "146.520 MHz", "NFM", "audio WAV, 48 kHz mono", "Until"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("the banner does not say %q:\n%s", want, errOut)
		}
	}
	jobID, _, ok := leyline.ParseRecordingURI(uri)
	if !ok {
		t.Fatalf("not a recording uri: %q", uri)
	}
	m, err := leyline.ReadRecordingManifest(filepath.Join(dir, jobID))
	if err != nil {
		t.Fatalf("the manifest the daemon wrote: %v", err)
	}
	if m.Kind != "audio" || m.Format != "wav-s16" || m.Mode != "NFM" {
		t.Errorf("manifest: %+v", m)
	}
	if m.EndedBy != "duration" {
		t.Errorf("ended_by: %q, want duration", m.EndedBy)
	}
	if len(m.Parts) != 1 {
		t.Fatalf("a continuous recording is one part, got %d", len(m.Parts))
	}
	// The part is a real file whose WAV header agrees with its length.
	data, err := os.ReadFile(filepath.Join(dir, jobID, m.Parts[0].File))
	if err != nil {
		t.Fatal(err)
	}
	if string(data[:4]) != "RIFF" || uint64(len(data)) != m.Parts[0].Bytes {
		t.Errorf("part file: %d bytes, manifest says %d", len(data), m.Parts[0].Bytes)
	}
}

// ley recordings lists what was written, show prints the manifest and path composes into a
// shell command. All three take an id prefix.
func TestRecordingsListShowAndPath(t *testing.T) {
	sock, dir := recordHarness(t)
	empty := mustRun(t, sock, "recordings")
	if !strings.Contains(empty, "no recordings") || !strings.Contains(empty, "ley record") {
		t.Fatalf("an empty store must say how to fill it:\n%s", empty)
	}
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	table := mustRun(t, sock, "recordings")
	for _, want := range []string{"STARTED", "FREQUENCY", "146.520 MHz", "NFM", jobID} {
		if !strings.Contains(table, want) {
			t.Errorf("the table does not say %q:\n%s", want, table)
		}
	}
	// An id prefix is enough, as it is everywhere else in ley.
	show := mustRun(t, sock, "recordings", "show", jobID[:12])
	for _, want := range []string{"Recording", "NFM audio", "146.520 MHz", "wav-s16", "1 part", "PART", "FILE"} {
		if !strings.Contains(show, want) {
			t.Errorf("show does not say %q:\n%s", want, show)
		}
	}
	path := strings.TrimSpace(mustRun(t, sock, "recordings", "path", jobID))
	if path != filepath.Join(dir, jobID) {
		t.Errorf("path: %q, want the recording's directory %q", path, filepath.Join(dir, jobID))
	}
	partPath := strings.TrimSpace(mustRun(t, sock, "recordings", "path", jobID, "--part", "1"))
	if filepath.Dir(partPath) != path || !strings.HasSuffix(partPath, ".wav") {
		t.Errorf("--part 1: %q", partPath)
	}
	if _, err := os.Stat(partPath); err != nil {
		t.Errorf("the path does not name a file: %v", err)
	}
	// --json is the contract's own shape, so a script reads a path without parsing prose.
	var local struct {
		Path string `json:"path"`
	}
	if err := json.Unmarshal([]byte(mustRun(t, sock, "--json", "recordings", "path", jobID)), &local); err != nil || local.Path != path {
		t.Errorf("--json path: %v %q", err, local.Path)
	}
	// The manifest --json prints is the document on disk, not a re-rendering of it.
	raw := mustRun(t, sock, "--json", "recordings", "show", jobID)
	var onDisk, printed map[string]any
	disk, err := os.ReadFile(filepath.Join(dir, jobID, "recording.json"))
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(disk, &onDisk); err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal([]byte(raw), &printed); err != nil {
		t.Fatalf("show --json is not JSON (%v): %s", err, raw)
	}
	if printed["job_id"] != onDisk["job_id"] || printed["ended_by"] != onDisk["ended_by"] {
		t.Errorf("show --json differs from recording.json:\n%v\n%v", printed, onDisk)
	}
}

// A gated recording writes one part per exchange and states the gaps between them, rather than
// editing the silence out of one long file.
func TestRecordGateWritesOnePartPerExchange(t *testing.T) {
	// The fake's squelch opens at 100 ms, closes at 250, opens at 400, closes at 600.
	sock, dir := recordHarness(t, 100, 250, 400, 600)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--gate", "squelch", "--for", "900ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)
	m, err := leyline.ReadRecordingManifest(filepath.Join(dir, jobID))
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Parts) != 2 {
		t.Fatalf("two transmissions, %d parts", len(m.Parts))
	}
	if len(m.Gaps) != 1 {
		t.Errorf("the quiet between them is stated, not hidden: %+v", m.Gaps)
	}
	if m.Gate == nil || m.Gate.Kind != "squelch" || m.Gate.HangMs == 0 {
		t.Errorf("gate: %+v", m.Gate)
	}
	show := mustRun(t, sock, "recordings", "show", jobID)
	if !strings.Contains(show, "squelch,") || !strings.Contains(show, "where nothing was recorded") {
		t.Errorf("show does not report the gate and the gap:\n%s", show)
	}
}

// --detach hands a script the job id and the URI and leaves the job running.
func TestRecordDetachLeavesTheJobRunning(t *testing.T) {
	sock, _ := recordHarness(t)
	out := mustRun(t, sock, "record", "146.52", "--detach")
	lines := strings.Fields(strings.TrimSpace(out))
	t.Cleanup(func() {
		if len(lines) > 0 {
			_, _, _ = run(t, context.Background(), sock, "jobs", "cancel", lines[0])
		}
	})
	if len(lines) != 2 || !strings.HasPrefix(lines[0], "job_") || !strings.HasPrefix(lines[1], "ley://recordings/") {
		t.Fatalf("--detach prints the job id then the uri, got %q", out)
	}
	jobs := mustRun(t, sock, "jobs")
	if !strings.Contains(jobs, "record") || !strings.Contains(jobs, "running") {
		t.Errorf("the job is not in the list as a running recording:\n%s", jobs)
	}
	if !strings.Contains(jobs, "146.520 MHz") {
		t.Errorf("the row does not say where it is recording:\n%s", jobs)
	}
	mustRun(t, sock, "jobs", "cancel", lines[0])
}

// ley play on a recording resolves the part through the daemon. An audio recording holds what a
// demodulator already produced, so there is no signal left in it to tune: play hands it to the
// machine's own player instead, and --json hands a script the path.
func TestPlayOnAnAudioRecording(t *testing.T) {
	sock, _ := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	// The daemon owns the speakers, so play holds the terminal while the daemon plays and the
	// sound comes out where the radio is.
	out, errOut, err := run(t, t.Context(), sock, "play", uri)
	if err != nil {
		t.Fatalf("play on an audio recording: %v\n%s\n%s", err, out, errOut)
	}
	if !strings.Contains(errOut, "through the daemon's audio") || !strings.Contains(errOut, jobID) {
		t.Errorf("play must say the daemon has it:\n%s", errOut)
	}
	if !strings.Contains(errOut, "Ctrl-C stops") {
		t.Errorf("a playback this terminal holds must say how to stop it:\n%s", errOut)
	}
	// The playback belongs to that terminal and is gone with it, leaving no daemon state behind.
	if st := mustRun(t, sock, "state", "--json"); strings.Contains(st, "playbackId") {
		t.Errorf("the playback outlived the command:\n%s", st)
	}

	// A script gets the path and no window: the LocalPath shape ley recordings path prints.
	var local struct {
		Path string `json:"path"`
	}
	raw, _, err := run(t, t.Context(), sock, "--json", "play", jobID)
	if err != nil {
		t.Fatalf("play --json: %v", err)
	}
	if uerr := json.Unmarshal([]byte(raw), &local); uerr != nil || !strings.HasSuffix(local.Path, ".wav") {
		t.Errorf("play --json: %v %q", uerr, raw)
	}

	_, _, err = run(t, t.Context(), sock, "play", "ley://recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB")
	if err == nil || !strings.Contains(err.Error(), "no recording called") {
		t.Errorf("a recording nobody made: %v", err)
	}
}

// A daemon with no audio device -- a headless one, which is usually the one on this machine --
// leaves the file to the machine's own player rather than refusing.
func TestPlayFallsBackToTheLocalPlayer(t *testing.T) {
	dir := t.TempDir()
	sock, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, NoSystemAudio: true})
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	played := filepath.Join(t.TempDir(), "played")
	out, errOut, err := runWithEnv(t, sock, map[string]string{"LEYLINE_PLAYER": playerStub(t, played)}, "play", jobID)
	if err != nil {
		t.Fatalf("play with no daemon audio: %v\n%s\n%s", err, out, errOut)
	}
	if !strings.Contains(errOut, "the daemon has no audio device") {
		t.Errorf("the fallback must say why it happened:\n%s", errOut)
	}
	handed := waitForFile(t, played)
	if !strings.HasSuffix(strings.TrimSpace(handed), ".wav") {
		t.Errorf("the player was handed %q, want the part's wav", handed)
	}
}

// playerStub writes a script that records the file it was handed, so a test can assert what play
// passed to the player without a window opening anywhere.
func playerStub(t *testing.T, log string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "player.sh")
	script := "#!/bin/sh\nprintf '%s' \"$1\" > " + log + "\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// waitForFile reads a path the player stub writes from its own process.
func waitForFile(t *testing.T, path string) string {
	t.Helper()
	for range 100 {
		if b, err := os.ReadFile(path); err == nil && len(b) > 0 {
			return string(b)
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("the player was never run (%s)", path)
	return ""
}

// runWithEnv runs a verb with an environment the test dictates.
func runWithEnv(t *testing.T, sock string, env map[string]string, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	app := &App{Stdout: &out, Stderr: &errb, LookupEnv: func(name string) (string, bool) {
		v, ok := env[name]
		return v, ok
	}}
	err := Execute(context.Background(), app, append([]string{"--socket", sock}, args...))
	return out.String(), errb.String(), err
}

// --audio puts this terminal's speakers on the channel the recording is writing from, so what is
// heard is what is going into the file rather than a second demodulator's idea of it.
func TestRecordAudioPlaysWhatIsBeingRecorded(t *testing.T) {
	sock, _ := recordHarness(t)
	out, errOut, err := run(t, t.Context(), sock, "record", "146.52", "--for", "500ms", "--listen")
	if err != nil {
		t.Fatalf("ley record --listen: %v\n%s\n%s", err, out, errOut)
	}
	// This container has no CoreAudio, so the daemon refuses the sink and the run says so
	// instead of claiming to play; on a Mac the banner carries the Audio line. Either way the
	// recording is the point and it ran.
	if !strings.Contains(errOut, "Audio") && !strings.Contains(errOut, "system audio is not available") {
		t.Errorf("neither playing nor saying why not:\n%s", errOut)
	}
	// The sink belongs to this terminal and goes when it exits, leaving the radio as it was.
	st := mustRun(t, sock, "state", "--json")
	if strings.Contains(st, "systemAudio") {
		t.Errorf("the speakers outlived the recording:\n%s", st)
	}

	// The combinations that cannot work are refused rather than half-done.
	_, _, err = run(t, t.Context(), sock, "record", "146.52", "--iq", "--listen")
	if err == nil || !strings.Contains(err.Error(), "nothing to play") {
		t.Errorf("--listen --iq: %v", err)
	}
	_, _, err = run(t, t.Context(), sock, "record", "146.52", "--listen", "--detach")
	if err == nil || !strings.Contains(err.Error(), "belong to this terminal") {
		t.Errorf("--listen --detach: %v", err)
	}
}

// The V0 story spells the pair `ley record --iq` and `--audio`
// (docs/plans/user-stories.md), so `--audio` has to name what record already writes rather than
// meeting somebody with "unknown flag". Asking for both is the one way to mean it wrongly.
func TestRecordAudioIsTheDefaultSpelledOut(t *testing.T) {
	sock, dir := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--audio", "--for", "300ms"))
	jobID, _, ok := leyline.ParseRecordingURI(uri)
	if !ok {
		t.Fatalf("ley record --audio: %q", uri)
	}
	m, err := leyline.ReadRecordingManifest(filepath.Join(dir, jobID))
	if err != nil {
		t.Fatal(err)
	}
	if m.Kind != "audio" {
		t.Errorf("--audio recorded %q", m.Kind)
	}
	_, _, err = run(t, t.Context(), sock, "record", "146.52", "--audio", "--iq")
	if err == nil || !strings.Contains(err.Error(), "two different recordings") {
		t.Errorf("--audio --iq: %v", err)
	}
}

// A retune over a running recording is warned about, not silently done: the daemon degrades the
// job and logs the gap, and ley asks first.
func TestTuneOverARunningRecordingIsRefusedUntilRetune(t *testing.T) {
	sock, _ := recordHarness(t)
	out := mustRun(t, sock, "record", "146.52", "--detach")
	jobID := strings.Fields(strings.TrimSpace(out))[0]
	t.Cleanup(func() { _, _, _ = run(t, t.Context(), sock, "jobs", "cancel", jobID) })

	// Far enough away that the capture has to move.
	_, _, err := run(t, t.Context(), sock, "tune", "155.0", "--no-audio", "--persistent")
	if err == nil || !strings.Contains(err.Error(), "recording on this radio") {
		t.Fatalf("tune over a recording: %v", err)
	}
	if !strings.Contains(err.Error(), jobID) || !strings.Contains(err.Error(), "--retune") {
		t.Errorf("the refusal must name the job and the flag: %v", err)
	}
}

// Principle 1 of docs/dev/cli-style.md: styling adds SGR and nothing else. Every screen record
// and recordings draw is rendered twice, once plain and once inked, and stripping the inked one
// must give back the plain one byte for byte.
func TestRecordScreensStyleIsSGROnly(t *testing.T) {
	sock, _ := recordHarness(t, 100, 250, 400, 600)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--gate", "squelch", "--for", "700ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	for _, tc := range []struct {
		name string
		args []string
	}{
		{"recordings", []string{"recordings"}},
		{"recordings show", []string{"recordings", "show", jobID}},
		{"recordings path", []string{"recordings", "path", jobID}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			plainOut, plainErr := runStyled(t, sock, false, tc.args...)
			inkOut, inkErr := runStyled(t, sock, true, tc.args...)
			if got, want := ui.Strip(inkOut), plainOut; got != want {
				t.Errorf("stdout: stripped ink differs from plain\n--- plain\n%s\n--- stripped\n%s", want, got)
			}
			if got, want := ui.Strip(inkErr), plainErr; got != want {
				t.Errorf("stderr: stripped ink differs from plain\n--- plain\n%s\n--- stripped\n%s", want, got)
			}
			if tc.name != "recordings path" && !strings.Contains(inkOut, "\033[") {
				t.Errorf("nothing was inked at all:\n%s", inkOut)
			}
		})
	}

	// The record banner is stderr prose, so it is rendered through the verb itself.
	plainOut, plainErr := runStyled(t, sock, false, "record", "146.52", "--for", "400ms")
	inkOut, inkErr := runStyled(t, sock, true, "record", "146.52", "--for", "400ms")
	// The uri on stdout carries a fresh job id each run, so compare the shape rather than the id.
	if strings.Count(plainOut, "\n") != strings.Count(inkOut, "\n") {
		t.Errorf("record stdout lines differ: %q vs %q", plainOut, inkOut)
	}
	if !strings.Contains(inkErr, "\033[") {
		t.Errorf("the record banner was not inked:\n%s", inkErr)
	}
	stripped, plain := recordScrub(ui.Strip(inkErr)), recordScrub(plainErr)
	if stripped != plain {
		t.Errorf("record banner: stripped ink differs from plain\n--- plain\n%s\n--- stripped\n%s", plain, stripped)
	}
}

// recordScrub removes what differs between two runs of the same recording: the job id, the
// directory it lands in and the live counters, which move with the clock.
func recordScrub(s string) string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if strings.Contains(line, "job_") || strings.HasPrefix(line, "recording ") {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

// runStyled runs a verb with colour forced on or off and returns both streams.
func runStyled(t *testing.T, sock string, color bool, args ...string) (string, string) {
	t.Helper()
	mode := "--color=never"
	if color {
		mode = "--color=always"
	}
	out, errOut, err := run(t, context.Background(), sock, append([]string{mode}, args...)...)
	if err != nil {
		t.Fatalf("ley %v: %v\n%s\n%s", args, err, out, errOut)
	}
	return out, errOut
}
