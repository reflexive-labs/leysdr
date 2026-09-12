// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/dpup/leysdr/go/internal/ui"
)

// logFixture is one line of each shape ley daemon logs has to survive: the
// daemon's own format at three levels, a second day, and a line that is not
// a log line at all.
const logFixture = `2026-09-09T04:12:54+0000 info leyline.daemon: [LeylineDaemon] leylined 0.1.0-dev listening on /tmp/leyline.sock
2026-09-09T04:13:01+0000 warning leyline.capture: [LeylineDaemon] rtl_tcp 127.0.0.1:1234: connection refused
2026-09-09T04:13:09+0000 error leyline.daemon: [LeylineDaemon] device dev_01 vanished mid-capture
2026-09-10T06:00:00+0000 debug leyline.audio: [LeylineDaemon] audio sink drained
Fatal error: something the daemon printed before the logger existed
`

func TestParseLogLine(t *testing.T) {
	tests := []struct {
		name   string
		line   string
		want   logLine
		wantOK bool
	}{
		{
			"swift-log", "2026-09-09T04:12:54+0000 info leyline.daemon: [LeylineDaemon] listening on /tmp/a.sock",
			logLine{date: "2026-09-09", clock: "04:12:54", level: "info", label: "leyline.daemon", subsys: "daemon", msg: "listening on /tmp/a.sock"},
			true,
		},
		{
			// The label and the source name different parts of the daemon:
			// the source is still the module, so it still goes.
			"other subsystem", "2026-09-09T04:13:01+0000 warning leyline.capture: [LeylineDaemon] rtl_tcp died",
			logLine{date: "2026-09-09", clock: "04:13:01", level: "warning", label: "leyline.capture", subsys: "capture", msg: "rtl_tcp died"},
			true,
		},
		{
			// A bracket that is not the module is part of the message.
			"foreign bracket", "2026-09-09T04:13:01+0000 info leyline.daemon: [dev_01] tuned",
			logLine{date: "2026-09-09", clock: "04:13:01", level: "info", label: "leyline.daemon", subsys: "daemon", msg: "[dev_01] tuned"},
			true,
		},
		{
			"space before colon", "2026-09-09T04:13:01+0000 info leyline.daemon : ready",
			logLine{date: "2026-09-09", clock: "04:13:01", level: "info", label: "leyline.daemon", subsys: "daemon", msg: "ready"},
			true,
		},
		{
			"no label", "2026-09-09T04:13:01+0000 info plain words follow",
			logLine{date: "2026-09-09", clock: "04:13:01", level: "info", msg: "plain words follow"},
			true,
		},
		{"continuation indent", "  2026-09-09T04:13:09+0000 info leyline.daemon: [LeylineDaemon] shutting down", logLine{
			date: "2026-09-09", clock: "04:13:09", level: "info", label: "leyline.daemon", subsys: "daemon", msg: "shutting down",
		}, true},
		{
			// A short tag is not the module repeating itself: "io" ends
			// "leyline.audio" by accident, and dropping it would lose what the
			// line came to say.
			"short source that says something new",
			"2026-09-09T04:13:01+0000 info leyline.audio: [IO] device stalled",
			logLine{date: "2026-09-09", clock: "04:13:01", level: "info", label: "leyline.audio", subsys: "audio", msg: "[IO] device stalled"},
			true,
		},
		{"not a log line", "Fatal error: boom", logLine{}, false},
		{"no level", "2026-09-09T04:13:09+0000 leyline.daemon: hello there", logLine{}, false},
		{"empty", "", logLine{}, false},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseLogLine(tc.line)
			if ok != tc.wantOK || got != tc.want {
				t.Errorf("parseLogLine(%q) = %+v, %v; want %+v, %v", tc.line, got, ok, tc.want, tc.wantOK)
			}
		})
	}
}

// renderLog relays the fixture through one style and returns what a terminal
// would receive.
func renderLog(st ui.Style) string {
	var buf bytes.Buffer
	r := &logRelay{st: st, w: &buf}
	_ = r.copy(strings.NewReader(logFixture))
	buf.WriteString(r.followLine("/tmp/leylined.log") + "\n")
	return buf.String()
}

// TestLogRelayPlainAndStyled is the mechanical proof of principle 1: the
// coloured relay is the plain relay plus SGR, nothing else.
func TestLogRelayPlainAndStyled(t *testing.T) {
	// Same alphabet, colour off and on: the ink is the only difference.
	plain := renderLog(ui.Style{Unicode: true, Width: 80})
	styled := renderLog(ui.Style{Color: true, Unicode: true, Width: 80})
	if styled == plain {
		t.Fatal("a coloured style left the log unstyled")
	}
	if got := ui.Strip(styled); got != plain {
		t.Fatalf("Strip(styled) = %q, want %q", got, plain)
	}
	for _, want := range []string{
		"2026-09-09\n",
		"04:12:54  info      daemon    leylined 0.1.0-dev listening on /tmp/leyline.sock\n",
		"04:13:01  warning   capture   rtl_tcp 127.0.0.1:1234: connection refused\n",
		"2026-09-10\n",
		"Fatal error: something the daemon printed before the logger existed\n",
	} {
		if !strings.Contains(plain, want) {
			t.Errorf("relayed log lacks %q:\n%s", want, plain)
		}
	}
	// The date is printed when it changes, never twice in a row.
	if n := strings.Count(plain, "2026-09-09\n"); n != 1 {
		t.Errorf("date printed %d times, want 1:\n%s", n, plain)
	}
	// ASCII draws the same screen with the fallback rule.
	if ascii := renderLog(ui.Style{Width: 80}); !strings.Contains(ascii, "Ctrl-C stops ---") {
		t.Errorf("ASCII relay lacks the fallback rule:\n%s", ascii)
	}
}

// TestLogRelayWidths: the re-laid line fits the terminal it was measured for,
// and a narrow one spends its columns on the message, not on the subsystem.
func TestLogRelayWidths(t *testing.T) {
	for _, w := range []int{40, 80, 160} {
		st := ui.Style{Color: true, Unicode: true, Width: w}
		out := renderLog(st)
		for _, line := range strings.Split(strings.TrimRight(out, "\n"), "\n") {
			// The message itself is content and is never truncated; the
			// prefix and the follow rule are what must fit.
			if strings.HasPrefix(line, "\x1b[2mfollowing") && ui.Visible(line) > w {
				t.Errorf("width %d: follow line is %d columns: %q", w, ui.Visible(line), line)
			}
		}
		hasSubsys := strings.Contains(ui.Strip(out), "  daemon    ")
		if want := w >= logWideMin; hasSubsys != want {
			t.Errorf("width %d: subsystem column present = %v, want %v", w, hasSubsys, want)
		}
	}
}

// TestDaemonLogsPipedIsVerbatim: piped, ley is a cat. Anything else breaks
// `ley daemon logs | grep`.
func TestDaemonLogsPipedIsVerbatim(t *testing.T) {
	path := filepath.Join(t.TempDir(), "leylined.log")
	if err := os.WriteFile(path, []byte(logFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	app := &App{IsTTY: func() bool { return false }}
	out, _, err := runApp(t, app, "daemon", "logs", "--log", path)
	if err != nil {
		t.Fatalf("daemon logs: %v", err)
	}
	if out != logFixture {
		t.Errorf("piped output is not the log verbatim:\n%q", out)
	}
}

// TestDaemonLogsTerminalRelays: on a terminal the same log comes back in
// columns, and every line of it is still in there.
func TestDaemonLogsTerminalRelays(t *testing.T) {
	path := filepath.Join(t.TempDir(), "leylined.log")
	if err := os.WriteFile(path, []byte(logFixture), 0o644); err != nil {
		t.Fatal(err)
	}
	app := ttyApp("")
	out, _, err := runApp(t, app, "daemon", "logs", "--log", path)
	if err != nil {
		t.Fatalf("daemon logs: %v", err)
	}
	if strings.Contains(out, "[LeylineDaemon]") {
		t.Errorf("the duplicated module label survived:\n%s", out)
	}
	if !strings.Contains(out, "04:13:09  error     daemon    device dev_01 vanished mid-capture") {
		t.Errorf("the error line is not in columns:\n%s", out)
	}
}

// A daemon whose pid is not a process at all has plainly gone.
func TestProcessGone(t *testing.T) {
	if !processGone(context.Background(), 0x7ffffff, true) {
		t.Error("an unused pid should read as gone")
	}
	if processGone(context.Background(), os.Getpid(), true) {
		t.Error("this test's own process should not read as gone")
	}
}

// TestProcessGoneSeesAZombie covers a daemon whose parent shell has exited
// but is not yet reaped: kill(pid, 0) still finds it, so processGone must
// recognize the zombie state as gone.
func TestProcessGoneSeesAZombie(t *testing.T) {
	ctx := context.Background()
	cmd := exec.Command("/bin/sh", "-c", "exit 0")
	if err := cmd.Start(); err != nil {
		t.Skipf("cannot start a child here: %v", err)
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() { _ = cmd.Wait() })
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(pid, 0) == nil && !isZombie(ctx, pid) {
		if time.Now().After(deadline) {
			t.Skip("this host reports no process state (no /proc, no ps)")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !processGone(ctx, pid, true) {
		t.Error("a zombie should read as gone; stop would wait out its timeout")
	}
}
