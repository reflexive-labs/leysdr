package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/testutil"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// harness starts a fake daemon on a temp UDS and returns its socket path plus
// a helper client for assertions.
func harness(t *testing.T, opts fakedaemon.Options) (string, *leyline.Client) {
	t.Helper()
	sock := testutil.SocketPath(t, "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	if opts.PresenceGrace == 0 {
		opts.PresenceGrace = 200 * time.Millisecond
	}
	d := fakedaemon.New(opts)
	served := make(chan error, 1)
	go func() { served <- d.Serve(ctx, sock) }()
	c, err := leyline.Dial(ctx, sock, leyline.WithKind("cli"), leyline.WithLabel("test"), leyline.WithClientID("cli_test"))
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := c.State(ctx); err == nil || time.Now().After(deadline) {
			if err != nil {
				t.Fatalf("daemon never came up: %v", err)
			}
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		_ = c.Close()
		cancel()
		<-served
	})
	return sock, c
}

// run executes ley in-process with captured output.
func run(t *testing.T, ctx context.Context, sock string, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	app := &App{Stdout: &out, Stderr: &errb, LookupEnv: func(string) (string, bool) { return "", false }}
	err := Execute(ctx, app, append([]string{"--socket", sock}, args...))
	return out.String(), errb.String(), err
}

// mustSay is mustRun for an assertion about prose. A live verb's prose is on
// stderr and its ids are on stdout, so "what a person saw" is both streams.
func mustSay(t *testing.T, sock string, args ...string) string {
	t.Helper()
	out, errOut, err := run(t, context.Background(), sock, args...)
	if err != nil {
		t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
	}
	return out + errOut
}

func mustRun(t *testing.T, sock string, args ...string) string {
	t.Helper()
	out, errOut, err := run(t, context.Background(), sock, args...)
	if err != nil {
		t.Fatalf("ley %v: %v\nstdout: %s\nstderr: %s", args, err, out, errOut)
	}
	return out
}

func TestDevicesTableAndJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "devices")
	// MODEL leads and STATE follows it: the ids and serials are behind --wide.
	if head := strings.Fields(out)[0]; head != "MODEL" || !strings.Contains(out, "RTL") {
		t.Fatalf("unexpected table:\n%s", out)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 {
		t.Fatalf("want header + 1 device, got:\n%s", out)
	}
	if strings.Contains(out, "dev_") {
		t.Fatalf("the default table must not lead with ids:\n%s", out)
	}
	wide := mustRun(t, sock, "devices", "--wide")
	if !strings.Contains(wide, "DRIVER") || !strings.Contains(wide, "SERIAL") || !strings.Contains(wide, "rtlsdr") {
		t.Fatalf("--wide must add driver, serial and id:\n%s", wide)
	}
	out = mustRun(t, sock, "--json", "devices")
	var resp struct {
		Devices []map[string]any `json:"devices"`
	}
	if err := json.Unmarshal([]byte(out), &resp); err != nil || len(resp.Devices) != 1 {
		t.Fatalf("json devices: %v %s", err, out)
	}
	if resp.Devices[0]["deviceId"] == nil || resp.Devices[0]["state"] != "AVAILABLE" {
		t.Fatalf("json shape: %s", out)
	}

	// A dongle another program holds: the daemon never opened it, so its gain
	// table is unreadable and the STATE column must say who has it.
	held := fakedaemon.HeldRTLSDR()
	sock, _ = harness(t, fakedaemon.Options{ExtraDevices: []*leylinev1.DeviceDescriptor{held}})
	out = mustRun(t, sock, "devices")
	lines = strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 3 {
		t.Fatalf("want header + 2 devices, got:\n%s", out)
	}
	var heldLine string
	for _, l := range lines {
		if strings.Contains(l, "IN_USE") {
			heldLine = l
		}
	}
	if !strings.Contains(heldLine, "IN_USE (other program)") || !strings.Contains(heldLine, "TUNER unknown") || strings.Contains(heldLine, "0..0dB") {
		t.Fatalf("held device row must read IN_USE (other program) / TUNER unknown, got:\n%s", out)
	}
	if !strings.Contains(out, "TUNER 0..49.6dB(auto)") || strings.Contains(out, "AVAILABLE (other program)") {
		t.Fatalf("built-in device row must be unchanged:\n%s", out)
	}
	if out = mustRun(t, sock, "state", "--wide"); !strings.Contains(out, "IN_USE (other program)") || !strings.Contains(out, "TUNER unknown") {
		t.Fatalf("ley state --wide devices block must match ley devices:\n%s", out)
	}
	if out = mustRun(t, sock, "state"); !strings.Contains(out, "in use (other program)") {
		t.Fatalf("ley state tree must say what holds the radio:\n%s", out)
	}
	// --json stays the plain proto3 mapping: no invented strings.
	out = mustRun(t, sock, "--json", "devices")
	if err := json.Unmarshal([]byte(out), &resp); err != nil || len(resp.Devices) != 2 {
		t.Fatalf("json devices: %v %s", err, out)
	}
	if strings.Contains(out, "other program") || strings.Contains(out, "unknown") {
		t.Fatalf("--json must not carry table-only wording: %s", out)
	}
	for _, d := range resp.Devices {
		if d["deviceId"] == held.DeviceId && (d["state"] != "IN_USE" || d["features"].(map[string]any)["held_externally"].(map[string]any)["flag"] != true) {
			t.Fatalf("held device json shape: %s", out)
		}
	}
}

// TestDevicesWatchJSON: `devices --watch --json` prints the same wrapped
// ListDevicesResponse `devices --json` prints as its first line, then Event
// lines (never bare DeviceDescriptors).
func TestDevicesWatchJSON(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, errOut, err := run(t, ctx, sock, "--json", "devices", "--watch")
	if err != nil || errOut != "" {
		t.Fatalf("devices --watch --json: %v stderr=%q", err, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	var resp struct {
		Devices []map[string]any `json:"devices"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &resp); err != nil || len(resp.Devices) != 1 || resp.Devices[0]["deviceId"] == nil {
		t.Fatalf("first line must be the wrapped list: %v %s", err, lines[0])
	}
	for _, l := range lines[1:] {
		var ev map[string]any
		if err := json.Unmarshal([]byte(l), &ev); err != nil || ev["device"] == nil {
			t.Fatalf("later lines must be device Events: %v %s", err, l)
		}
	}
}

// gainsString reports an unreadable table as "unknown" only when both the
// table and the range are empty; a real 0..0 table or a stepped range keeps
// the numeric rendering.
func TestGainsStringUnknownTable(t *testing.T) {
	cases := []struct {
		el   *leylinev1.GainElement
		want string
	}{
		{&leylinev1.GainElement{Name: "TUNER", SupportsAuto: true}, "TUNER unknown"},
		{&leylinev1.GainElement{Name: "TUNER"}, "TUNER unknown"},
		{&leylinev1.GainElement{Name: "TUNER", ValidDb: []float64{0}}, "TUNER 0..0dB"},
		{&leylinev1.GainElement{Name: "LNA", MaxDb: 40, StepDb: 8}, "LNA 0..40dB"},
		{&leylinev1.GainElement{Name: "TUNER", MaxDb: 49.6, SupportsAuto: true, ValidDb: fakedaemon.R820TGains}, "TUNER 0..49.6dB(auto)"},
	}
	for _, c := range cases {
		if got := gainsString([]*leylinev1.GainElement{c.el}); got != c.want {
			t.Errorf("gainsString(%v) = %q, want %q", c.el, got, c.want)
		}
	}
	if got := gainsString(nil); got != "-" {
		t.Errorf("gainsString(nil) = %q", got)
	}
	held := &leylinev1.DeviceDescriptor{State: leylinev1.DeviceState_IN_USE, Features: map[string]*leylinev1.FeatureValue{"held_externally": {Value: &leylinev1.FeatureValue_Flag{Flag: true}}}}
	if got := deviceStateString(held); got != "IN_USE (other program)" {
		t.Errorf("deviceStateString(held) = %q", got)
	}
	if got := deviceStateString(&leylinev1.DeviceDescriptor{State: leylinev1.DeviceState_IN_USE}); got != "IN_USE" {
		t.Errorf("deviceStateString(in use by us) = %q", got)
	}
}

func TestState(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	out := mustRun(t, sock, "state", "--wide")
	for _, want := range []string{"daemon fake-0.1", "Devices", "Captures", "Channels", "Sinks"} {
		if !strings.Contains(out, want) {
			t.Fatalf("state missing %q:\n%s", want, out)
		}
	}
	out = mustRun(t, sock, "--json", "state")
	var st map[string]any
	if err := json.Unmarshal([]byte(out), &st); err != nil || st["daemon"] == nil {
		t.Fatalf("json state: %v %s", err, out)
	}
	if out := mustRun(t, sock, "version"); !strings.HasPrefix(out, "ley ") {
		t.Fatalf("version: %s", out)
	}
}

// runApp executes ley in-process with a caller-built App (captured writers
// are installed) and returns stdout, stderr and the error.
func runApp(t *testing.T, app *App, args ...string) (string, string, error) {
	t.Helper()
	var out, errb bytes.Buffer
	app.Stdout, app.Stderr = &out, &errb
	if app.LookupEnv == nil {
		app.LookupEnv = func(string) (string, bool) { return "", false }
	}
	if app.Socket != "" {
		args = append([]string{"--socket", app.Socket}, args...)
	}
	err := Execute(context.Background(), app, args)
	return out.String(), errb.String(), err
}

// ttyApp is an App that believes stdout is an 80-column terminal.
func ttyApp(sock string) *App {
	return &App{Socket: sock, IsTTY: func() bool { return true }, TermWidth: func() int { return 80 }}
}

// exitCode extracts the ExitError code; plain errors are 1, nil is 0.
func exitCode(err error) int {
	if err == nil {
		return 0
	}
	var ee *ExitError
	if errors.As(err, &ee) {
		return ee.Code
	}
	return 1
}

// listening puts the fake daemon in the "one persistent channel" state.
func listening(t *testing.T, c *leyline.Client) {
	t.Helper()
	ctx := context.Background()
	st, err := c.State(ctx)
	if err != nil || len(st.Devices) == 0 {
		t.Fatalf("state: %v", err)
	}
	cap, err := c.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.Devices[0].DeviceId, CenterHz: 146_520_000})
	if err != nil {
		t.Fatalf("create capture: %v", err)
	}
	if _, err := c.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: cap.CaptureId, Mode: leylinev1.DemodMode_NFM, BandwidthHz: 12_500, Persistent: true}); err != nil {
		t.Fatalf("create channel: %v", err)
	}
}

func TestExitCodesUsage(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{})
	dir := t.TempDir()
	iq := filepath.Join(dir, "tone.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	missing := filepath.Join(dir, "x.cf32")
	cases := []struct {
		args []string
		want string
	}{
		{[]string{"nosuchverb"}, `no command or topic named "nosuchverb"`},
		{[]string{"spectrun"}, "Did you mean this?\n  spectrum"},
		{[]string{"state", "extra"}, "unknown command \"extra\""},
		{[]string{"devices", "--bogus"}, "unknown flag: --bogus"},
		{[]string{"fft", "--format", "xml"}, "--format must be json or bin"},
		{[]string{"spectrum", "146,52"}, "frequency:"},
		{[]string{"record"}, "record is not implemented yet (Milestone C.12). Today:"},
		{[]string{"record", "--audio", "--duration", "10"}, "record is not implemented yet (Milestone C.12). Today:"},
		{[]string{"scan", "146.52"}, "scan is not implemented yet (Milestone D). Today: ley spectrum"},
		{[]string{"watch"}, "watch is not implemented yet (V0.5)"},
		// tune's positional and flags are parsed before anything reaches the daemon.
		{[]string{"tune"}, "tune needs a frequency or preset"},
		{[]string{"tune", "146,52"}, "frequency"},
		{[]string{"tune", "nooa"}, "or give a frequency such as 146.52 (MHz)"},
		{[]string{"tune", "146.52", "--mode", "morse"}, "--mode:"},
		{[]string{"play", iq, "--freq", "1,1"}, "--freq:"},
		// A recording that is not there is a usage error said in plain words.
		{[]string{"play", missing}, "there is no file at " + missing},
	}
	for _, tc := range cases {
		_, _, err := run(t, context.Background(), sock, tc.args...)
		if exitCode(err) != ExitUsage {
			t.Errorf("ley %v: exit %d (%v), want %d", tc.args, exitCode(err), err, ExitUsage)
		}
		if err == nil || !strings.Contains(err.Error(), tc.want) {
			t.Errorf("ley %v: message %q lacks %q", tc.args, err, tc.want)
		}
	}
	// Runtime errors from the daemon stay exit 1.
	_, _, err := run(t, context.Background(), sock, "devices", "detach", "dev_nope")
	if exitCode(err) != 1 {
		t.Errorf("runtime error: exit %d (%v), want 1", exitCode(err), err)
	}
	// A real radio is not a playback file: detach says how to free it instead.
	_, _, err = run(t, context.Background(), sock, "devices", "detach", "1")
	if exitCode(err) != 1 || err == nil || !strings.Contains(err.Error(), "is a real radio") || !strings.Contains(err.Error(), "free it with: ley stop --all") || strings.Contains(err.Error(), "DEVICE_NOT_FOUND") {
		t.Errorf("detach a real radio: exit %d (%v)", exitCode(err), err)
	}
	// A missing log file is said in plain words with the next step.
	missing = filepath.Join(t.TempDir(), "none.log")
	_, _, err = run(t, context.Background(), sock, "daemon", "logs", "--log", missing)
	if exitCode(err) != 1 || err == nil || !strings.Contains(err.Error(), "there is no file at "+missing) || !strings.Contains(err.Error(), "ley daemon start") || strings.Contains(err.Error(), "no such file or directory") {
		t.Errorf("daemon logs without a file: exit %d (%v)", exitCode(err), err)
	}
}

// Daemon errors reach the user as "<message> [CODE]", the code last so
// scripts can grep for it; exit 2/3 errors and plain errors pass through.
func TestWithCode(t *testing.T) {
	le := &leyline.Error{Code: leyline.CodeDeviceBusy, Message: "another client holds it", Target: "dev_1"}
	got := withCode(le)
	if got.Error() != "another client holds it (dev_1) [DEVICE_BUSY]" || exitCode(got) != 1 || leyline.Code(got) != leyline.CodeDeviceBusy {
		t.Errorf("withCode(daemon error) = %q (exit %d, code %s)", got, exitCode(got), leyline.Code(got))
	}
	wrapped := withCode(&friendlyError{msg: "the radio is busy; ley state shows who", cause: le})
	if wrapped.Error() != "the radio is busy; ley state shows who [DEVICE_BUSY]" {
		t.Errorf("withCode(friendly) = %q", wrapped)
	}
	if e := usageErrorf("bad flag"); withCode(e) != e {
		t.Errorf("withCode changed a usage error")
	}
	if e := errors.New("plain"); withCode(e) != e || withCode(nil) != nil {
		t.Errorf("withCode changed a plain error")
	}
}

func TestExitCodeNotRunning(t *testing.T) {
	dead := testutil.SocketPath(t, "nobody.sock")
	for _, args := range [][]string{{"state"}, {"devices"}, {"spectrum", "101.1"}, {"fft", "--freq", "101.1M"}, {"daemon", "status"}} {
		_, _, err := run(t, context.Background(), dead, args...)
		if exitCode(err) != ExitNotRunning {
			t.Errorf("ley %v: exit %d (%v), want %d", args, exitCode(err), err, ExitNotRunning)
		}
		if args[0] != "daemon" {
			want := "the Leyline daemon is not running (socket " + dead + "). Start it with: ley daemon start"
			if err == nil || err.Error() != want {
				t.Errorf("ley %v: message %q, want %q", args, err, want)
			}
		}
	}
	// A socket file nobody answers on is the stale variant.
	stale := testutil.SocketPath(t, "stale.sock")
	if err := os.WriteFile(stale, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, context.Background(), stale, "state")
	if exitCode(err) != ExitNotRunning || !strings.Contains(err.Error(), "stale socket "+stale) || !strings.Contains(err.Error(), "ley daemon stop && ley daemon start") {
		t.Errorf("stale socket: exit %d, message %q", exitCode(err), err)
	}
	out, _, err := run(t, context.Background(), stale, "daemon", "status")
	if exitCode(err) != ExitNotRunning || err.Error() != "" || !strings.Contains(out, "stale socket") {
		t.Errorf("daemon status stale: %d %q out %q", exitCode(err), err, out)
	}
	out, _, err = run(t, context.Background(), stale, "daemon", "stop")
	if err != nil || !strings.Contains(out, "removed the stale socket") {
		t.Errorf("daemon stop stale: %v out %q", err, out)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Errorf("stale socket not removed")
	}
}

func TestDevicesEmptyChecklist(t *testing.T) {
	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	out, _, err := runApp(t, ttyApp(sock), "devices")
	if err != nil || !strings.Contains(out, "rtl_test") || !strings.Contains(out, "ley daemon logs") {
		t.Fatalf("tty checklist: %v\n%s", err, out)
	}
	out, _, err = run(t, context.Background(), sock, "devices")
	if err != nil || strings.Contains(out, "rtl_test") {
		t.Fatalf("piped output must not carry the checklist: %v\n%s", err, out)
	}
	out, _, err = runApp(t, &App{Socket: sock, IsTTY: func() bool { return true }}, "--json", "devices")
	if err != nil || strings.Contains(out, "rtl_test") || !strings.HasPrefix(out, "{") {
		t.Fatalf("--json must stay JSON: %v\n%s", err, out)
	}
}

func TestOrientationPerState(t *testing.T) {
	dead := testutil.SocketPath(t, "nobody.sock")
	out, _, err := runApp(t, ttyApp(dead))
	if err != nil || !strings.Contains(out, "Daemon    not running") || !strings.Contains(out, "ley daemon start") {
		t.Fatalf("no daemon: %v\n%s", err, out)
	}

	sock, _ := harness(t, fakedaemon.Options{NoDevice: true})
	out, _, err = runApp(t, ttyApp(sock))
	if err != nil || !strings.Contains(out, "Devices   none found") || !strings.Contains(out, "rtl_test") || !strings.Contains(out, "ley devices") {
		t.Fatalf("no device: %v\n%s", err, out)
	}

	sock, c := harness(t, fakedaemon.Options{})
	out, _, err = runApp(t, ttyApp(sock))
	if err != nil || !strings.Contains(out, "Playing   nothing") || !strings.Contains(out, "ley tune 146.52") || !strings.Contains(out, "ley spectrum") {
		t.Fatalf("idle: %v\n%s", err, out)
	}
	if !strings.Contains(out, "Daemon    daemon fake-0.1") || !strings.Contains(out, "Devices   ") {
		t.Fatalf("idle header: %s", out)
	}

	listening(t, c)
	out, _, err = runApp(t, ttyApp(sock))
	if err != nil || !strings.Contains(out, "Playing   146.520 MHz NFM") || !strings.Contains(out, "ley set squelch") || !strings.Contains(out, "ley spectrum") {
		t.Fatalf("listening: %v\n%s", err, out)
	}

	// Piped: the same orientation block, unstyled, so `ley | tee log` answers
	// the question the Long text promises it answers. --json: a pointer to
	// state --json, nothing on stdout.
	out, _, err = run(t, context.Background(), sock)
	if err != nil || !strings.Contains(out, "Playing   146.520 MHz NFM") || !strings.Contains(out, "Next:") {
		t.Fatalf("piped: %v\n%s", err, out)
	}
	if strings.Contains(out, "Available Commands") || strings.Contains(out, "\x1b[") {
		t.Fatalf("piped orientation must be the block, unstyled:\n%s", out)
	}
	out, errOut, err := run(t, context.Background(), sock, "--json")
	if err != nil || out != "" || !strings.Contains(errOut, "ley state --json") {
		t.Fatalf("--json: %v out %q err %q", err, out, errOut)
	}
	// Bare ley never fails, whatever the daemon state.
	if _, _, err := runApp(t, ttyApp(dead), "--json"); err != nil {
		t.Fatalf("--json no daemon: %v", err)
	}
}

func TestRenderOrientationStates(t *testing.T) {
	if s := renderOrientation(ui.Style{}, nil, &ExitError{Code: ExitNotRunning, Message: "the Leyline daemon is not running (socket x). Start it with: ley daemon start"}); !strings.Contains(s, "ley daemon start") || !strings.Contains(s, "ley daemon logs") {
		t.Errorf("not running:\n%s", s)
	}
	if s := renderOrientation(ui.Style{}, nil, errors.New("boom")); !strings.Contains(s, "Daemon    error: boom") {
		t.Errorf("other error:\n%s", s)
	}
	st := &leylinev1.GetStateResponse{Daemon: &leylinev1.DaemonInfo{Version: "v", Pid: 1}}
	if s := renderOrientation(ui.Style{}, st, nil); !strings.Contains(s, "none found") {
		t.Errorf("no device:\n%s", s)
	}
}

func TestStubsHiddenAndListed(t *testing.T) {
	root := NewRootCommand(&App{})
	for _, name := range []string{"record", "scan", "watch"} {
		cmd, _, err := root.Find([]string{name})
		if err != nil || cmd.Name() != name || !cmd.Hidden {
			t.Errorf("stub %s: %v hidden=%v", name, err, cmd != nil && cmd.Hidden)
		}
	}
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetArgs([]string{"--help"})
	if err := root.Execute(); err != nil || regexp.MustCompile(`(?m)^\s+(record|scan|watch)\s`).MatchString(out.String()) {
		t.Errorf("stubs must be hidden from --help: %v\n%s", err, out.String())
	}
}

// pickDevice skips a dongle another program holds (held_externally) so the
// default lands on a radio a capture can actually open, and still falls back
// to the held one when nothing else is connected.
func TestPickDeviceSkipsExternallyHeld(t *testing.T) {
	held := &leylinev1.DeviceDescriptor{
		DeviceId: "dev_held", Driver: "rtlsdr", Model: "NESDR", State: leylinev1.DeviceState_IN_USE,
		Features: map[string]*leylinev1.FeatureValue{"held_externally": {Value: &leylinev1.FeatureValue_Flag{Flag: true}}},
	}
	remote := &leylinev1.DeviceDescriptor{DeviceId: "dev_remote", Driver: "rtltcp", Model: "rtl_tcp", State: leylinev1.DeviceState_AVAILABLE}
	file := &leylinev1.DeviceDescriptor{DeviceId: "dev_file", Driver: "file", State: leylinev1.DeviceState_AVAILABLE}

	got, err := pickDevice(&leylinev1.GetStateResponse{Devices: []*leylinev1.DeviceDescriptor{file, held, remote}}, "")
	if err != nil || got.DeviceId != "dev_remote" {
		t.Fatalf("expected the rtl_tcp radio, got %v (err %v)", got.GetDeviceId(), err)
	}
	got, err = pickDevice(&leylinev1.GetStateResponse{Devices: []*leylinev1.DeviceDescriptor{file, held}}, "")
	if err != nil || got.DeviceId != "dev_held" {
		t.Fatalf("expected the held radio as the only fallback, got %v (err %v)", got.GetDeviceId(), err)
	}
	got, err = pickDevice(&leylinev1.GetStateResponse{Devices: []*leylinev1.DeviceDescriptor{held, remote}}, "1")
	if err != nil || got.DeviceId != "dev_held" {
		t.Fatalf("an explicit --device must still win, got %v (err %v)", got.GetDeviceId(), err)
	}
}
