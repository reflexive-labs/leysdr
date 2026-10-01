// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
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

// ley play follows the position from the event stream alone: the daemon publishes the playback
// four times a second while it plays, and the tombstone ends the command.
func TestPlayFollowsThePositionOnTheEventPlane(t *testing.T) {
	sock, _ := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "2s"))
	_, errOut, err := run(t, t.Context(), sock, "play", uri)
	if err != nil {
		t.Fatalf("play: %v\n%s", err, errOut)
	}
	for _, want := range []string{"0:00 / ", "0:01 / "} {
		if !strings.Contains(errOut, want) {
			t.Errorf("the position must move while it plays; no %q in:\n%s", want, errOut)
		}
	}
}

// Deleting a recording stops a playback of its part, and the tombstone ends the ley play holding
// it: nothing is left playing a file that is gone.
func TestDeletingARecordingEndsItsPlay(t *testing.T) {
	sock, dir := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "3s"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)
	done := make(chan error, 1)
	go func() {
		_, _, err := run(t, t.Context(), sock, "play", uri)
		done <- err
	}()
	for i := 0; !strings.Contains(mustRun(t, sock, "state", "--json"), "playbackId"); i++ {
		if i == 100 {
			t.Fatal("the playback never appeared in the daemon's state")
		}
		time.Sleep(20 * time.Millisecond)
	}
	mustRun(t, sock, "recordings", "delete", jobID, "--yes")
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("play ended by a delete is not a failure: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("ley play still holds a playback whose recording was deleted")
	}
	if st := mustRun(t, sock, "state", "--json"); strings.Contains(st, "playbackId") {
		t.Errorf("the playback outlived its recording:\n%s", st)
	}
	if _, serr := os.Stat(filepath.Join(dir, jobID)); !os.IsNotExist(serr) {
		t.Errorf("the directory is still there: %v", serr)
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
	// recording runs.
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

// The V0 user story spells the pair `ley record --iq` and `--audio`
// (docs/plans/user-stories.md), so `--audio` is accepted as the default record already writes
// rather than failing with "unknown flag". Passing both is a usage error.
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

	// recordings delete prints one stderr line; two recordings, one deleted plain and one inked,
	// differ only in their ids and, by a tick of the fake's clock, their sizes.
	var lines []string
	for _, color := range []bool{false, true} {
		u := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
		id, _, _ := leyline.ParseRecordingURI(u)
		out, errOut := runStyled(t, sock, color, "recordings", "delete", id, "--yes")
		if out != "" {
			t.Errorf("recordings delete printed on stdout: %q", out)
		}
		line := strings.Replace(errOut, id, "job_", 1)
		if i, j := strings.Index(line, ", "), strings.Index(line, " freed"); i >= 0 && j > i {
			line = line[:i] + ", N" + line[j:]
		}
		lines = append(lines, line)
	}
	if !strings.Contains(lines[1], "\033[") {
		t.Errorf("the delete line was not inked: %q", lines[1])
	}
	if ui.Strip(lines[1]) != lines[0] {
		t.Errorf("recordings delete: stripped ink differs from plain\n%q\n%q", lines[0], ui.Strip(lines[1]))
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

// --gain names stages on a radio with several: each pair is its own write, in the order typed,
// the names go to the daemon as typed, and the banner lists every stage the take started at
// (plans/app.md, M2-10). A stage the radio does not have fails the job with the ones it does.
func TestRecordGainSetsEachStageNamed(t *testing.T) {
	hackrf := fakedaemon.HackRFPro()
	dir := t.TempDir()
	sock, c := harness(t, fakedaemon.Options{RecordingsDir: dir, ExtraDevices: []*leylinev1.DeviceDescriptor{hackrf}})
	out, errOut, err := run(t, t.Context(), sock, "record", "462.5625", "--device", hackrf.DeviceId, "--for", "300ms", "--gain", "LNA=0,vga=0")
	if err != nil {
		t.Fatalf("ley record: %v\n%s\n%s", err, out, errOut)
	}
	if !strings.Contains(errOut, "Radio     HackRF Pro, gain LNA 0 dB, VGA 0 dB, AMP off\n") {
		t.Errorf("the banner does not list the stages the take started at:\n%s", errOut)
	}
	jobID, _, _ := leyline.ParseRecordingURI(strings.TrimSpace(out))
	// recordings show prints the manifest's stages as the banner does, not the first alone.
	if show := mustRun(t, sock, "recordings", "show", jobID); !strings.Contains(show, "Radio     HackRF Pro (hackrf), gain LNA 0 dB, VGA 0 dB, AMP off\n") {
		t.Errorf("recordings show should name every stage:\n%s", show)
	}
	job, err := c.Jobs.GetJob(t.Context(), &leylinev1.JobRef{JobId: jobID})
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	for _, g := range job.GetRecord().GetGains() {
		got = append(got, fmt.Sprintf("%s=%g", g.GetElement(), g.GetDb()))
	}
	if strings.Join(got, ",") != "LNA=0,vga=0" || job.GetRecord().GetGain() != nil {
		t.Errorf("the job's writes are %v (gain %v), want LNA=0,vga=0 in gains alone", got, job.GetRecord().GetGain())
	}

	// A bare level is one write with no element: the daemon's first stage.
	if cfg := (&recordOptions{gain: "30"}).config(); len(cfg.GetGains()) != 1 || cfg.GetGains()[0].GetElement() != "" || cfg.GetGains()[0].GetDb() != 30 {
		t.Errorf("--gain 30 is %v, want one write of 30 dB with no element", cfg.GetGains())
	}
	if cfg := (&recordOptions{}).config(); cfg.GetGains() != nil || cfg.GetGain() != nil {
		t.Errorf("no --gain leaves the radio alone, got %v %v", cfg.GetGains(), cfg.GetGain())
	}

	_, errOut, err = run(t, t.Context(), sock, "record", "462.5625", "--device", hackrf.DeviceId, "--for", "300ms", "--gain", "IF=0")
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 1 {
		t.Fatalf("a stage the radio does not have should fail the job (exit 1), got %v\n%s", err, errOut)
	}
	if want := "the gain asked for could not be set: no gain element named IF; this radio's are LNA, VGA and AMP [GAIN_ELEMENT_UNKNOWN]"; ee.Message != want {
		t.Errorf("the refusal is %q, want %q", ee.Message, want)
	}
	if strings.Contains(errOut, "Recording") {
		t.Errorf("a job that failed before writing should print no banner:\n%s", errOut)
	}

	if _, _, err := run(t, t.Context(), sock, "record", "462.5625", "--gain", "LNA=0,20"); err == nil || !strings.Contains(err.Error(), "name each stage") {
		t.Errorf("a bare value in a list is a usage error, got %v", err)
	}
}

// runWithStdin is run with a terminal on stdin that answers with input, so the
// confirmation path is taken.
func runWithStdin(t *testing.T, sock, input string, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	app := &App{
		Stdout: &out, Stderr: &errb, Stdin: strings.NewReader(input), IsInTTY: func() bool { return true },
		LookupEnv: func(string) (string, bool) { return "", false },
	}
	err := Execute(t.Context(), app, append([]string{"--socket", sock}, args...))
	return out.String(), errb.String(), err
}

// ley recordings delete asks on a terminal, naming the recording, and goes on a y; anything else
// keeps it. The prose is on stderr and stdout is empty, or the DeletedResource under --json.
func TestRecordingsDeleteConfirmsThenDeletes(t *testing.T) {
	sock, dir := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "462.5625", "--for", "300ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	out, errOut, err := runWithStdin(t, sock, "n\n", "recordings", "delete", jobID)
	if err != nil {
		t.Fatalf("declining is not an error: %v\n%s", err, errOut)
	}
	if !strings.HasPrefix(errOut, "Delete 462.5625 MHz NFM, ") || !strings.Contains(errOut, " in 1 part, ") ||
		!strings.Contains(errOut, "? [y/N] ") || !strings.Contains(errOut, "nothing was deleted") || out != "" {
		t.Errorf("the question and the answer:\nstdout %q\nstderr %q", out, errOut)
	}
	if _, serr := os.Stat(filepath.Join(dir, jobID)); serr != nil {
		t.Fatalf("a declined delete removed the recording: %v", serr)
	}

	out, errOut, err = runWithStdin(t, sock, "y\n", "recordings", "delete", jobID[:12])
	if err != nil {
		t.Fatalf("ley recordings delete: %v\n%s", err, errOut)
	}
	if out != "" || !strings.Contains(errOut, "Deleted "+jobID+", ") || !strings.HasSuffix(errOut, " freed\n") {
		t.Errorf("stdout %q\nstderr %q", out, errOut)
	}
	if _, serr := os.Stat(filepath.Join(dir, jobID)); !os.IsNotExist(serr) {
		t.Errorf("the directory is still there: %v", serr)
	}
	if table := mustRun(t, sock, "recordings"); strings.Contains(table, jobID) {
		t.Errorf("ley recordings still lists it:\n%s", table)
	}
	// The job is left as it was: jobs are never tombstoned.
	if jobs := mustRun(t, sock, "jobs"); !strings.Contains(jobs, "record") {
		t.Errorf("the job went with the recording:\n%s", jobs)
	}
	_, _, err = run(t, t.Context(), sock, "recordings", "delete", jobID, "--yes")
	if err == nil || !strings.Contains(err.Error(), "no recording called") || !strings.Contains(err.Error(), "[JOB_NOT_FOUND]") {
		t.Errorf("deleting it again: %v", err)
	}
}

// --yes skips the question, is required when stdin is not a terminal, and --json prints the
// DeletedResource on stdout.
func TestRecordingsDeleteYesAndJSON(t *testing.T) {
	sock, dir := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)

	_, _, err := run(t, t.Context(), sock, "recordings", "delete", jobID)
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != ExitUsage || !strings.Contains(err.Error(), "ley recordings delete "+jobID+" --yes") {
		t.Fatalf("no terminal and no --yes must be a usage error naming --yes: %v", err)
	}
	if _, serr := os.Stat(filepath.Join(dir, jobID)); serr != nil {
		t.Fatalf("the refusal removed the recording: %v", serr)
	}
	// A part is refused by the daemon: a recording is deleted whole.
	_, _, err = run(t, t.Context(), sock, "recordings", "delete", uri+"/1", "-y")
	if err == nil || !strings.Contains(err.Error(), "deleted whole") || !strings.Contains(err.Error(), "[INVALID_ARGUMENT]") {
		t.Errorf("a part uri: %v", err)
	}
	out, errOut, err := run(t, t.Context(), sock, "--json", "recordings", "delete", uri, "-y")
	if err != nil {
		t.Fatalf("--json delete: %v\n%s", err, errOut)
	}
	var deleted struct {
		URI        string `json:"uri"`
		FreedBytes string `json:"freedBytes"`
	}
	if jerr := json.Unmarshal([]byte(out), &deleted); jerr != nil || deleted.URI != uri || deleted.FreedBytes == "" || deleted.FreedBytes == "0" {
		t.Errorf("--json prints the DeletedResource (%v): %s", jerr, out)
	}
}

// A running recording is refused with the daemon's sentence and the command that stops it.
func TestRecordingsDeleteRefusesARunningRecording(t *testing.T) {
	sock, dir := recordHarness(t)
	fields := strings.Fields(mustRun(t, sock, "record", "146.52", "--detach"))
	jobID := fields[0]
	t.Cleanup(func() { _, _, _ = run(t, context.Background(), sock, "jobs", "cancel", jobID) })
	_, _, err := run(t, t.Context(), sock, "recordings", "delete", jobID, "--yes")
	want := jobID + " is still recording; cancel the job first, then delete it. Run: ley jobs cancel " + jobID + " [FAILED_PRECONDITION]"
	if err == nil || err.Error() != want {
		t.Fatalf("got  %v\nwant %s", err, want)
	}
	if _, serr := os.Stat(filepath.Join(dir, jobID)); serr != nil {
		t.Fatalf("the refusal removed the recording: %v", serr)
	}
	// Long enough for the fake to have written some audio: a recording cancelled before it heard
	// anything is discarded at the cancel and there would be nothing left to delete.
	time.Sleep(200 * time.Millisecond)
	mustRun(t, sock, "jobs", "cancel", jobID)
	mustRun(t, sock, "recordings", "delete", jobID, "--yes")
}

// A gated recording whose squelch never opens is discarded by the daemon: ley record says so in
// one sentence, prints no URI (there is nothing at it) and exits 0, because the recording did
// what it was asked.
func TestRecordThatHearsNothingSaysSo(t *testing.T) {
	// The fake's squelch opens an hour in: never, for a test.
	sock, dir := recordHarness(t, 3_600_000)
	out, errOut, err := run(t, t.Context(), sock, "record", "146.52", "--gate", "squelch", "--for", "400ms")
	if err != nil {
		t.Fatalf("a recording that heard nothing is not a failure: %v\n%s", err, errOut)
	}
	if !strings.Contains(errOut, "Recorded nothing: the squelch never opened.") {
		t.Errorf("the closing line must say nothing was heard:\n%s", errOut)
	}
	if strings.TrimSpace(out) != "" {
		t.Errorf("stdout must not name a recording that is not kept: %q", out)
	}
	if entries, _ := os.ReadDir(dir); len(entries) != 0 {
		t.Errorf("the store still holds %d entries", len(entries))
	}
}

// The part table gains a CLIP column only when a part clipped, with the clipped time from the
// manifest's clipped_ms.
func TestRecordingsShowClipsOnlyWhenAPartClipped(t *testing.T) {
	dir := t.TempDir()
	var clean atomic.Bool
	sock, _ := harness(t, fakedaemon.Options{RecordingsDir: dir, Clipping: func(string) (uint64, uint64, float64) {
		if clean.Load() {
			return 0, 600_000, -12
		}
		return 600, 600_000, 0
	}})
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "400ms"))
	jobID, _, _ := leyline.ParseRecordingURI(uri)
	show := mustRun(t, sock, "recordings", "show", jobID)
	if !strings.Contains(show, "CLIP") || !regexp.MustCompile(`\b0\.[3-5] s\b`).MatchString(show) {
		t.Errorf("a part that clipped shows for how long:\n%s", show)
	}
	clean.Store(true)
	uri = strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "300ms"))
	jobID, _, _ = leyline.ParseRecordingURI(uri)
	if show := mustRun(t, sock, "recordings", "show", jobID); strings.Contains(show, "CLIP") {
		t.Errorf("a clean recording's table has no CLIP column:\n%s", show)
	}
}

// Space pauses and resumes a daemon playback that ley play follows on a terminal, and the
// progress line says paused. A pipe on stdin takes no keys.
func TestPlaySpacePausesAndResumes(t *testing.T) {
	sock, _ := recordHarness(t)
	uri := strings.TrimSpace(mustRun(t, sock, "record", "146.52", "--for", "1s"))
	keys, press := io.Pipe()
	var out, errb syncBuffer
	app := &App{
		Stdout: &out, Stderr: &errb, Stdin: keys, IsInTTY: func() bool { return true },
		LookupEnv: func(string) (string, bool) { return "", false },
	}
	done := make(chan error, 1)
	go func() { done <- Execute(t.Context(), app, []string{"--socket", sock, "play", uri}) }()
	waitFor(t, "the key hint", func() bool { return strings.Contains(errb.String(), "Space pauses") })
	time.Sleep(200 * time.Millisecond)
	_, _ = press.Write([]byte(" "))
	waitFor(t, "the paused line", func() bool { return strings.Contains(errb.String(), ", paused; space resumes") })
	paused := mustRun(t, sock, "state", "--json")
	time.Sleep(500 * time.Millisecond)
	if again := mustRun(t, sock, "state", "--json"); positionOf(again) != positionOf(paused) || positionOf(paused) == "" {
		t.Errorf("paused, the position moved: %s then %s", positionOf(paused), positionOf(again))
	}
	_, _ = press.Write([]byte(" "))
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("play: %v\n%s", err, errb.String())
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("resumed, the playback never finished:\n%s", errb.String())
	}
	_ = press.Close()
}

// positionOf pulls the one playback's position out of `ley state --json`.
func positionOf(stateJSON string) string {
	m := regexp.MustCompile(`"position":\s*"?(\d+)`).FindStringSubmatch(stateJSON)
	if m == nil {
		return ""
	}
	return m[1]
}
