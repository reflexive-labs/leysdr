// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// daemonBinEnv names the environment variable that overrides daemon discovery.
const daemonBinEnv = "LEYLINE_DAEMON_BIN"

// daemonFlags are shared by the daemon subcommands.
type daemonFlags struct {
	bin, log string
	follow   bool
}

func newDaemonCommand(app *App) *cobra.Command {
	var f daemonFlags
	cmd := &cobra.Command{
		Use:   "daemon",
		Short: "Start, stop and check the process that owns the radio",
		Long: `The daemon (leylined) is the background process that owns your SDR and does
all the radio work; every ley command talks to it. 'start' launches it,
'status' says whether it is answering, 'logs' shows what it has been doing.

On macOS 'install' writes a LaunchAgent (~/Library/LaunchAgents/
com.leyline.daemon.plist) so the daemon starts at login; start and stop then
drive launchctl. Without a LaunchAgent, start spawns leylined detached
(stdout/stderr to the log file, pid in the pidfile beside the socket) and stop
sends SIGTERM via the pidfile.

The daemon binary is found from --bin, $LEYLINE_DAEMON_BIN, a 'leylined' next
to the ley executable, then PATH.`,
		Example: `  ley daemon start         # start it now
  ley daemon status        # is it running? (exit 3 when not)
  ley daemon logs -f       # follow the log
  ley daemon install       # macOS: start at login`,
		GroupID: GroupDaemon,
	}
	cmd.PersistentFlags().StringVar(&f.bin, "bin", "", "path to the leylined binary")
	cmd.PersistentFlags().StringVar(&f.log, "log", "", "daemon log file (default: ~/Library/Logs/Leyline/leylined.log)")
	// sub builds one subcommand; jsonOK false makes --json a usage error (the
	// verb has no JSON shape: its output is a file or a launchd action).
	sub := func(use, short, long, example string, jsonOK bool, run func(context.Context, *daemonFlags) error) *cobra.Command {
		return &cobra.Command{Use: use, Short: short, Long: long, Example: example, Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
			if app.JSON && !jsonOK {
				return noJSONErrorf("daemon "+use, "ley daemon status --json reports the daemon")
			}
			return run(cmd.Context(), &f)
		}}
	}
	logs := sub("logs", "Print the daemon's log",
		"logs prints the daemon's log file (where it reports the radios it found,\nwhat it is doing and why something failed). -f keeps printing as it grows.",
		"  ley daemon logs          # the whole log so far\n  ley daemon logs -f       # follow it while you try something", false, app.daemonLogs)
	logs.Flags().BoolVarP(&f.follow, "follow", "f", false, "keep printing as the log grows")
	cmd.AddCommand(
		sub("install", "Start the daemon at login (macOS LaunchAgent)",
			"install writes a LaunchAgent (a macOS launchd job file in\n~/Library/LaunchAgents/com.leyline.daemon.plist) and loads it, so the daemon\nstarts now and at every login and is restarted if it crashes. It returns once\nthe daemon answers on its socket, or points at the log when it does not.",
			"  ley daemon install       # start at login from now on\n  ley daemon install --bin /opt/leyline/bin/leylined", false, app.daemonInstall),
		sub("uninstall", "Stop starting the daemon at login (macOS)",
			"uninstall unloads and removes the LaunchAgent that 'ley daemon install'\nwrote. The daemon stops; 'ley daemon start' still works without it.",
			"  ley daemon uninstall", false, app.daemonUninstall),
		sub("start", "Start the daemon",
			"start launches the daemon and prints its pid (process id). With a LaunchAgent\ninstalled it asks launchd; otherwise it spawns leylined in the background\nwith its output in the log file. Already running is not an error.\n--json prints the running daemon's DaemonInfo, as 'ley daemon status --json' does.",
			"  ley daemon start         # started leylined (pid 12345); check with: ley daemon status\n  ley daemon start --log /tmp/leylined.log\n  ley daemon start --json  # the DaemonInfo of the daemon now running", true, app.daemonStart),
		sub("stop", "Stop the daemon (and clear a stale socket)",
			"stop asks the daemon to exit and waits until the socket stops answering.\nA socket file left behind by a crashed daemon is removed so the next start\nis clean. --json prints the DaemonInfo the daemon last reported (its pid),\nor only socketPath when nothing was running.",
			"  ley daemon stop\n  ley daemon stop && ley daemon start   # restart", true, app.daemonStop),
		sub("status", "Say whether the daemon is running (exit 3 when not)",
			"status prints the daemon's pid, version and socket when it answers, and\nexits 3 with the command to start it when it does not. Scripts can use the\nexit code alone.",
			"  ley daemon status\n  ley daemon status --json # a DaemonInfo message; only socketPath when not running", true, app.daemonStatus),
		logs,
	)
	return cmd
}

// findDaemonBin resolves the leylined binary per the documented order.
func (a *App) findDaemonBin(flag string) (string, error) {
	if flag != "" {
		return flag, nil
	}
	if v, ok := a.LookupEnv(daemonBinEnv); ok && v != "" {
		return v, nil
	}
	if a.Executable != "" {
		cand := filepath.Join(filepath.Dir(a.Executable), "leylined")
		if st, err := os.Stat(cand); err == nil && !st.IsDir() {
			return cand, nil
		}
	}
	if p, err := exec.LookPath("leylined"); err == nil {
		return p, nil
	}
	return "", fmt.Errorf("leylined not found: pass --bin, set $%s, or put leylined beside ley or on PATH", daemonBinEnv)
}

// pidPath is the pidfile beside the effective socket, named after it.
func (a *App) pidPath() string {
	return leyline.PidPathFor(a.socketPath())
}

func (a *App) logPath(f *daemonFlags) string {
	if f.log != "" {
		return f.log
	}
	return leyline.DefaultLogPath()
}

// launchAgentInstalled reports whether the plist exists (macOS only).
func launchAgentInstalled() bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	_, err := os.Stat(leyline.DefaultLaunchAgentPath())
	return err == nil
}

func launchTarget() string {
	return fmt.Sprintf("gui/%d/%s", os.Getuid(), leyline.LaunchAgentLabel)
}

// launchctl runs launchctl with args, surfacing its combined output on error.
func launchctl(ctx context.Context, args ...string) error {
	out, err := exec.CommandContext(ctx, "launchctl", args...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("launchctl %v: %w: %s", args, err, out)
	}
	return nil
}

// plist renders the LaunchAgent for bin/socket/log. The paths are XML-escaped:
// a home directory with & or < in it must not break the plist.
func plist(bin, socket, logPath string) string {
	bin, socket, logPath = xmlEscape(bin), xmlEscape(socket), xmlEscape(logPath)
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>%s</string>
	<key>ProgramArguments</key>
	<array>
		<string>%s</string>
		<string>--socket</string>
		<string>%s</string>
	</array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key><false/>
	</dict>
	<key>StandardOutPath</key><string>%s</string>
	<key>StandardErrorPath</key><string>%s</string>
</dict>
</plist>
`, leyline.LaunchAgentLabel, bin, socket, logPath, logPath)
}

// xmlEscape escapes s for use as XML character data.
func xmlEscape(s string) string {
	var b strings.Builder
	_ = xml.EscapeText(&b, []byte(s))
	return b.String()
}

func (a *App) daemonInstall(ctx context.Context, f *daemonFlags) error {
	if runtime.GOOS != "darwin" {
		return errors.New("daemon install needs launchd (macOS); use 'ley daemon start' here")
	}
	bin, err := a.findDaemonBin(f.bin)
	if err != nil {
		return err
	}
	if bin, err = filepath.Abs(bin); err != nil {
		return err
	}
	// launchd runs the job from / so every path in the plist must be absolute.
	logPath, err := filepath.Abs(a.logPath(f))
	if err != nil {
		return err
	}
	socket, err := filepath.Abs(a.socketPath())
	if err != nil {
		return err
	}
	for _, p := range []string{leyline.DefaultLaunchAgentPath(), logPath, socket} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
	}
	// An ad-hoc `daemon start` instance would make the launchd job crash-loop
	// on SOCKET_IN_USE: stop ours, refuse anyone else's.
	info := a.daemonInfo(ctx)
	if pid := a.ownedPid(ctx, info); pid != 0 {
		if err := a.stopPid(ctx, pid); err != nil {
			return err
		}
	} else if info != nil {
		return fmt.Errorf("another daemon is serving %s; stop it before installing", socket)
	}
	path := leyline.DefaultLaunchAgentPath()
	if err := os.WriteFile(path, []byte(plist(bin, socket, logPath)), 0o644); err != nil {
		return err
	}
	_ = launchctl(ctx, "bootout", launchTarget())
	// bootout is asynchronous; bootstrap fails with EIO / "already" until the
	// old job is gone.
	var err2 error
	for i := 0; i < 10; i++ {
		err2 = launchctl(ctx, "bootstrap", fmt.Sprintf("gui/%d", os.Getuid()), path)
		if err2 == nil || (!strings.Contains(err2.Error(), "Input/output error") && !strings.Contains(err2.Error(), "already")) {
			break
		}
		time.Sleep(200 * time.Millisecond)
	}
	if err2 != nil {
		return err2
	}
	fmt.Fprintf(a.Stdout, "installed %s (%s)\n", path, bin)
	// bootstrap returns as soon as launchd has the job; the daemon itself needs a moment to
	// open its socket, and a status check that runs in that moment says "not running". Wait
	// for it the way start does, and say so, or point at the log when it never answers.
	return a.awaitDaemon(ctx, f, nil, "started leylined")
}

func (a *App) daemonUninstall(ctx context.Context, _ *daemonFlags) error {
	if runtime.GOOS != "darwin" {
		return errors.New("daemon uninstall needs launchd (macOS)")
	}
	path := leyline.DefaultLaunchAgentPath()
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("not installed: %s", path)
	}
	_ = launchctl(ctx, "bootout", launchTarget())
	if err := os.Remove(path); err != nil {
		return err
	}
	fmt.Fprintf(a.Stdout, "removed %s\n", path)
	return nil
}

// readPid returns the pid from the pidfile, 0 when absent or stale.
func (a *App) readPid() int {
	b, err := os.ReadFile(a.pidPath())
	if err != nil {
		return 0
	}
	pid, err := strconv.Atoi(string(trimSpace(b)))
	if err != nil || pid <= 0 || syscall.Kill(pid, 0) != nil {
		return 0
	}
	return pid
}

func trimSpace(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == ' ' || b[len(b)-1] == '\r') {
		b = b[:len(b)-1]
	}
	return b
}

// reachable reports whether a daemon answers on the socket.
func (a *App) reachable(ctx context.Context) bool {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	c, err := a.dial(ctx)
	if err != nil {
		return false
	}
	defer c.Close()
	_, err = c.State(ctx)
	return err == nil
}

// startTimeout bounds how long start waits for the daemon to answer.
const startTimeout = 5 * time.Second

func (a *App) daemonStart(ctx context.Context, f *daemonFlags) error {
	if a.reachable(ctx) {
		return a.reportStarted(ctx, "already running")
	}
	if launchAgentInstalled() {
		if err := launchctl(ctx, "kickstart", "-k", launchTarget()); err != nil {
			return err
		}
		return a.awaitDaemon(ctx, f, nil, "started leylined")
	}
	bin, err := a.findDaemonBin(f.bin)
	if err != nil {
		return err
	}
	logPath := a.logPath(f)
	for _, p := range []string{logPath, a.socketPath(), a.pidPath()} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
	}
	// A pidfile instance that is alive but not answering yet (still booting)
	// would only be doubled by a second spawn that dies on SOCKET_IN_USE: wait
	// for it instead. Same for a daemon that came up since the probe above.
	if pid := a.ownedPid(ctx, nil); pid != 0 || a.reachable(ctx) {
		return a.awaitDaemon(ctx, f, nil, "already running")
	}
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return err
	}
	defer logFile.Close()
	cmd := exec.Command(bin, "--socket", a.socketPath(), "--pidfile", a.pidPath())
	cmd.Stdout, cmd.Stderr, cmd.Stdin = logFile, logFile, nil
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return startFailure(bin, err)
	}
	return a.awaitDaemon(ctx, f, &child{cmd: cmd, exited: reap(cmd)}, "started leylined")
}

// startFailure words a failure to launch the daemon binary in the house
// shape -- one sentence, then what to do next -- instead of leaking
// os/exec's "fork/exec <path>: ..." with the path repeated. The three ways
// to point ley at a binary are the remedy `ley daemon --help` documents.
func startFailure(bin string, err error) error {
	reason := err.Error()
	var xe *exec.Error
	var pe *fs.PathError
	switch {
	case errors.As(err, &xe):
		reason = xe.Err.Error()
	case errors.As(err, &pe):
		reason = pe.Err.Error()
	}
	return fmt.Errorf("cannot run the daemon binary %s: %s. Pass --bin, set $%s, or put leylined on PATH", bin, reason, daemonBinEnv)
}

// child is a daemon this process spawned and has not yet handed over to the
// pidfile: exited fires when it dies.
type child struct {
	cmd    *exec.Cmd
	exited <-chan error
}

// reap waits for cmd in the background so a daemon that dies immediately is
// reaped (tests, or a crash at startup) and its exit is observable.
func reap(cmd *exec.Cmd) <-chan error {
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	return done
}

// kill SIGTERMs the child and waits for it to exit (SIGKILL after 5 s), so a
// start that failed leaves no orphan behind.
func (c *child) kill() {
	_ = c.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case <-c.exited:
	case <-time.After(5 * time.Second):
		_ = c.cmd.Process.Kill()
		<-c.exited
	}
}

// awaitDaemon waits up to startTimeout for the daemon to answer on the socket,
// then reports it with verb. A spawned child is only recorded in the pidfile
// once it answers; if it dies first, or the pidfile cannot be written, the
// child is stopped and the error says why so nothing runs unrecorded.
func (a *App) awaitDaemon(ctx context.Context, f *daemonFlags, c *child, verb string) error {
	deadline := time.Now().Add(startTimeout)
	for {
		if a.reachable(ctx) {
			if c != nil {
				if err := os.WriteFile(a.pidPath(), []byte(strconv.Itoa(c.cmd.Process.Pid)+"\n"), 0o644); err != nil {
					c.kill()
					return fmt.Errorf("write pidfile %s: %w (stopped the daemon again)", a.pidPath(), err)
				}
			}
			return a.reportStarted(ctx, verb)
		}
		if c != nil {
			select {
			case err := <-c.exited:
				return fmt.Errorf("leylined exited during startup (%v). Look at its log: ley daemon logs (%s)", exitReason(err), a.logPath(f))
			default:
			}
		}
		if time.Now().After(deadline) {
			if c != nil {
				c.kill()
			}
			return fmt.Errorf("leylined did not answer on %s within %v. Look at its log: ley daemon logs (%s)", a.socketPath(), startTimeout, a.logPath(f))
		}
		time.Sleep(100 * time.Millisecond)
	}
}

// exitReason words a cmd.Wait error ("exit status 1", or "exit status 0").
func exitReason(err error) string {
	if err == nil {
		return "exit status 0"
	}
	return err.Error()
}

// reportStarted prints the running daemon: its DaemonInfo under --json (as
// status does), otherwise "<verb> (pid N); check with: ley daemon status".
func (a *App) reportStarted(ctx context.Context, verb string) error {
	if a.JSON {
		return a.printDaemonInfo(ctx)
	}
	fmt.Fprintf(a.Stdout, "%s%s; check with: ley daemon status\n", verb, a.pidSuffix(ctx))
	return nil
}

func (a *App) daemonStop(ctx context.Context, _ *daemonFlags) error {
	// The daemon cannot be asked afterwards, so its last report (pid and all)
	// is what --json prints once it is gone.
	last := a.daemonInfo(ctx)
	if launchAgentInstalled() {
		if last == nil {
			a.reportNotRunningForStop()
			return nil
		}
		if err := launchctl(ctx, "kill", "SIGTERM", launchTarget()); err != nil {
			return err
		}
		// KeepAlive.SuccessfulExit=false keeps a clean exit down; confirm the
		// socket actually went away before claiming so.
		deadline := time.Now().Add(5 * time.Second)
		for a.reachable(ctx) {
			if time.Now().After(deadline) {
				return fmt.Errorf("daemon still answering on %s after 5 s", a.socketPath())
			}
			time.Sleep(100 * time.Millisecond)
		}
	} else {
		pid := a.ownedPid(ctx, last)
		if pid == 0 {
			// No (valid) pidfile: a daemon answering on the socket is still
			// ours to stop, by the pid it reports. Only silence means not running.
			pid = int(last.GetPid())
		}
		if pid == 0 {
			a.reportNotRunningForStop()
			return nil
		}
		if err := a.stopPid(ctx, pid); err != nil {
			return err
		}
	}
	if a.JSON {
		if last == nil {
			last = &leylinev1.DaemonInfo{SocketPath: a.socketPath()}
		}
		return a.printJSON(last)
	}
	fmt.Fprintln(a.Stdout, "stopped")
	return nil
}

// daemonInfo is the running daemon's DaemonInfo from a fresh GetState, nil
// when nothing answers on the socket within a second.
func (a *App) daemonInfo(ctx context.Context) *leylinev1.DaemonInfo {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	c, err := a.dial(ctx)
	if err != nil {
		return nil
	}
	defer c.Close()
	st, err := c.State(ctx)
	if err != nil {
		return nil
	}
	return st.GetDaemon()
}

// printDaemonInfo prints the DaemonInfo `daemon status --json` prints, from a
// fresh GetState; a daemon that stopped answering in between is an error.
func (a *App) printDaemonInfo(ctx context.Context) error {
	info := a.daemonInfo(ctx)
	if info == nil {
		return fmt.Errorf("leylined stopped answering on %s; check with: ley daemon status", a.socketPath())
	}
	return a.printJSON(info)
}

// ownedPid returns the pidfile's pid when that process is our daemon, 0 when
// there is none. A pidfile a crashed daemon left behind can name a pid the
// system has since reused, so the pid must be vouched for: when the socket
// answers (info non-nil) the daemon's own DaemonInfo.pid must match; otherwise
// the process's command name must be leylined. A mismatch removes the stale
// pidfile so nothing else is ever signalled through it.
func (a *App) ownedPid(ctx context.Context, info *leylinev1.DaemonInfo) int {
	pid := a.readPid()
	if pid == 0 {
		return 0
	}
	if info != nil {
		if int(info.GetPid()) == pid {
			return pid
		}
	} else if out, err := exec.CommandContext(ctx, "ps", "-o", "comm=", "-p", strconv.Itoa(pid)).Output(); err == nil && isDaemonComm(string(out)) {
		return pid
	}
	_ = os.Remove(a.pidPath())
	return 0
}

// isDaemonComm reports whether `ps -o comm=` output names leylined (macOS
// prints the full executable path, Linux the bare name).
func isDaemonComm(out string) bool {
	return filepath.Base(strings.TrimSpace(out)) == "leylined"
}

// stopTimeout bounds the wait for a signalled daemon to go away.
const stopTimeout = 5 * time.Second

// stopPid SIGTERMs a pidfile instance (vouched for by ownedPid), waits for it
// to exit, and removes the pidfile.
func (a *App) stopPid(ctx context.Context, pid int) error {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("cannot signal the daemon (pid %d): %v. Check what that process is with: ps -p %d", pid, err, pid)
	}
	deadline := time.Now().Add(stopTimeout)
	for i := 0; !processGone(ctx, pid, i%10 == 0); i++ {
		if time.Now().After(deadline) {
			return fmt.Errorf("the daemon (pid %d) has not exited yet; it may be finishing a write. Check with: ley daemon status", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = os.Remove(a.pidPath())
	return nil
}

// processGone reports whether pid has stopped running. A process nothing has
// reaped yet is a zombie: it has exited and its socket is already gone, but
// kill(pid, 0) still succeeds, so stop must also check for a zombie state or
// it would wait the full timeout and report a false failure for a daemon
// started from the same shell that ran ley. The zombie check costs a `ps`,
// so callers ask for it a few times a second rather than on every poll.
func processGone(ctx context.Context, pid int, checkZombie bool) bool {
	if syscall.Kill(pid, 0) != nil {
		return true
	}
	return checkZombie && isZombie(ctx, pid)
}

// isZombie reports whether pid is an exited process waiting to be reaped
// (state Z on both macOS and Linux). /proc answers on Linux without a
// fork; macOS has no /proc, so there it asks ps, as ownedPid does.
func isZombie(ctx context.Context, pid int) bool {
	if b, err := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid)); err == nil {
		// "<pid> (<comm>) <state> ...", and comm may hold spaces or a ")".
		if i := strings.LastIndex(string(b), ")"); i >= 0 {
			return strings.HasPrefix(strings.TrimLeft(string(b)[i+1:], " "), "Z")
		}
		return false
	}
	out, err := exec.CommandContext(ctx, "ps", "-o", "state=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return false
	}
	st := strings.TrimSpace(string(out))
	return st != "" && st[0] == 'Z'
}

// daemonStatusLine answers the question the verb was asked -- is it up? --
// with its first word, then the build, the pid, the uptime and the socket.
// The state is a word before it is a colour, so a pipe or NO_COLOR loses
// nothing; the socket path is Muted because it is the field a reader checks
// least and the one that costs the most room.
func daemonStatusLine(st ui.Style, d *leylinev1.DaemonInfo) string {
	if d == nil {
		return st.Ok("running") + "  (no info)"
	}
	up := time.Since(time.Unix(0, d.GetStartedAtNs())).Truncate(time.Second)
	return fmt.Sprintf("%s  %s  %s %d  %s %s  %s %s",
		st.Ok("running"), d.GetVersion(),
		st.Label("pid"), d.GetPid(),
		st.Label("up"), up,
		st.Label("socket"), st.Muted(d.GetSocketPath()))
}

func (a *App) daemonStatus(ctx context.Context, _ *daemonFlags) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	c, err := a.dial(ctx)
	if err == nil {
		defer c.Close()
		var resp *leylinev1.GetStateResponse
		if resp, err = c.State(ctx); err == nil {
			if a.JSON {
				return a.printJSON(resp.Daemon)
			}
			fmt.Fprintln(a.Stdout, daemonStatusLine(a.Style, resp.GetDaemon()))
			return nil
		}
	}
	// A daemon that answers with an error is running but unwell: that error,
	// with its [CODE], is the report (exit 1). Only nothing listening is "not
	// running": the same DaemonInfo shape with pid absent (0), and exit 3 so
	// scripts can key on it without parsing.
	if err = a.notRunning(err); !isNotRunning(err) {
		return err
	}
	if a.JSON {
		if err := a.printJSON(&leylinev1.DaemonInfo{SocketPath: a.socketPath()}); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(a.Stdout, inkMessage(a.Style, a.notRunningMessage()))
	}
	return &ExitError{Code: ExitNotRunning}
}

func (a *App) daemonLogs(ctx context.Context, f *daemonFlags) error {
	path := a.logPath(f)
	file, err := os.Open(path)
	if errors.Is(err, os.ErrNotExist) {
		return fileMissing(path, "the daemon writes it once started with: ley daemon start (or pass the file it logs to with --log)")
	}
	if err != nil {
		return fmt.Errorf("cannot read the log %s: %v", path, err)
	}
	defer file.Close()
	// Piped, the log is this daemon's own format passed through byte-for-byte
	// so `ley daemon logs | grep` keeps working. Only a terminal gets the
	// re-laid columns, and only for the lines that parse.
	if !a.IsTTY() {
		return a.copyLog(ctx, file, f.follow, func(r io.Reader) error {
			_, err := io.Copy(a.Stdout, r)
			return err
		})
	}
	relay := &logRelay{st: a.Style, w: a.Stdout}
	read := func(r io.Reader) error { return relay.copy(r) }
	if err := read(file); err != nil {
		return err
	}
	if !f.follow {
		return nil
	}
	fmt.Fprintln(a.Stdout, relay.followLine(path))
	return a.copyLog(ctx, file, true, read)
}

// copyLog drains src with drain, then keeps draining it every 250 ms while
// follow is set, until the context ends.
func (a *App) copyLog(ctx context.Context, src io.Reader, follow bool, drain func(io.Reader) error) error {
	if err := drain(src); err != nil {
		return err
	}
	for follow {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(250 * time.Millisecond):
		}
		if err := drain(src); err != nil {
			return err
		}
	}
	return nil
}

// pidSuffix is " (pid N)" when the running daemon reports one.
func (a *App) pidSuffix(ctx context.Context) string {
	if pid := a.daemonInfo(ctx).GetPid(); pid != 0 {
		return fmt.Sprintf(" (pid %d)", pid)
	}
	return ""
}

// reportNotRunningForStop prints the stop verdict when nothing is running and
// clears a socket file a dead daemon left behind, so the next start is clean.
// Under --json the verdict is a DaemonInfo with only socketPath (the status
// shape) on stdout and the sentence goes to stderr.
func (a *App) reportNotRunningForStop() {
	sock := a.socketPath()
	out := a.Stdout
	if a.JSON {
		out = a.Stderr
		_ = a.printJSON(&leylinev1.DaemonInfo{SocketPath: sock})
	}
	if _, err := os.Stat(sock); err == nil {
		if err := os.Remove(sock); err == nil {
			fmt.Fprintf(out, "not running; removed the stale socket %s. Start it with: ley daemon start\n", sock)
			return
		}
	}
	fmt.Fprintln(out, "not running. Start it with: ley daemon start")
}
