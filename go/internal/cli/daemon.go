package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
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
	sub := func(use, short, long, example string, run func(context.Context, *daemonFlags) error) *cobra.Command {
		return &cobra.Command{Use: use, Short: short, Long: long, Example: example, Args: cobra.NoArgs, RunE: func(cmd *cobra.Command, _ []string) error {
			return run(cmd.Context(), &f)
		}}
	}
	logs := sub("logs", "Print the daemon's log",
		"logs prints the daemon's log file (where it reports the radios it found,\nwhat it is doing and why something failed). -f keeps printing as it grows.",
		"  ley daemon logs          # the whole log so far\n  ley daemon logs -f       # follow it while you try something", app.daemonLogs)
	logs.Flags().BoolVarP(&f.follow, "follow", "f", false, "keep printing as the log grows")
	cmd.AddCommand(
		sub("install", "Start the daemon at login (macOS LaunchAgent)",
			"install writes a LaunchAgent (a macOS launchd job file in\n~/Library/LaunchAgents/com.leyline.daemon.plist) and loads it, so the daemon\nstarts now and at every login and is restarted if it crashes.",
			"  ley daemon install       # start at login from now on\n  ley daemon install --bin /opt/leyline/bin/leylined", app.daemonInstall),
		sub("uninstall", "Stop starting the daemon at login (macOS)",
			"uninstall unloads and removes the LaunchAgent that 'ley daemon install'\nwrote. The daemon stops; 'ley daemon start' still works without it.",
			"  ley daemon uninstall", app.daemonUninstall),
		sub("start", "Start the daemon",
			"start launches the daemon and prints its pid (process id). With a LaunchAgent\ninstalled it asks launchd; otherwise it spawns leylined in the background\nwith its output in the log file. Already running is not an error.",
			"  ley daemon start         # started leylined (pid 12345); check with: ley daemon status\n  ley daemon start --log /tmp/leylined.log", app.daemonStart),
		sub("stop", "Stop the daemon (and clear a stale socket)",
			"stop asks the daemon to exit and waits until the socket stops answering.\nA socket file left behind by a crashed daemon is removed so the next start\nis clean.",
			"  ley daemon stop\n  ley daemon stop && ley daemon start   # restart", app.daemonStop),
		sub("status", "Say whether the daemon is running (exit 3 when not)",
			"status prints the daemon's pid, version and socket when it answers, and\nexits 3 with the command to start it when it does not. Scripts can use the\nexit code alone.",
			"  ley daemon status\n  ley daemon status --json # a DaemonInfo message; only socketPath when not running", app.daemonStatus),
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

// pidPath is the pidfile beside the effective socket.
func (a *App) pidPath() string {
	if a.Socket != "" {
		return filepath.Join(filepath.Dir(a.Socket), "leylined.pid")
	}
	return leyline.DefaultPidPath()
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

// plist renders the LaunchAgent for bin/socket/log.
func plist(bin, socket, logPath string) string {
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
	logPath := a.logPath(f)
	for _, p := range []string{leyline.DefaultLaunchAgentPath(), logPath, a.socketPath()} {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return err
		}
	}
	// An ad-hoc `daemon start` instance would make the launchd job crash-loop
	// on SOCKET_IN_USE: stop ours, refuse anyone else's.
	if pid := a.readPid(); pid != 0 {
		if err := a.stopPid(pid); err != nil {
			return err
		}
	} else if a.reachable(ctx) {
		return fmt.Errorf("another daemon is serving %s; stop it before installing", a.socketPath())
	}
	path := leyline.DefaultLaunchAgentPath()
	if err := os.WriteFile(path, []byte(plist(bin, a.socketPath(), logPath)), 0o644); err != nil {
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
	return nil
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

func (a *App) daemonStart(ctx context.Context, f *daemonFlags) error {
	if a.reachable(ctx) {
		fmt.Fprintf(a.Stdout, "already running%s; check with: ley daemon status\n", a.pidSuffix(ctx))
		return nil
	}
	if launchAgentInstalled() {
		if err := launchctl(ctx, "kickstart", "-k", launchTarget()); err != nil {
			return err
		}
	} else {
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
		logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if err != nil {
			return err
		}
		defer logFile.Close()
		cmd := exec.Command(bin, "--socket", a.socketPath())
		cmd.Stdout, cmd.Stderr, cmd.Stdin = logFile, logFile, nil
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("spawn %s: %w", bin, err)
		}
		if err := os.WriteFile(a.pidPath(), []byte(strconv.Itoa(cmd.Process.Pid)+"\n"), 0o644); err != nil {
			return err
		}
		// Reap the child if it exits while this process is still alive (tests,
		// or a daemon that dies immediately) so the pidfile check sees a dead pid.
		go func() { _ = cmd.Wait() }()
	}
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if a.reachable(ctx) {
			fmt.Fprintf(a.Stdout, "started leylined%s; check with: ley daemon status\n", a.pidSuffix(ctx))
			return nil
		}
		time.Sleep(100 * time.Millisecond)
	}
	return fmt.Errorf("leylined did not answer on %s within 5 s. Look at its log: ley daemon logs (%s)", a.socketPath(), a.logPath(f))
}

func (a *App) daemonStop(ctx context.Context, _ *daemonFlags) error {
	if launchAgentInstalled() {
		if !a.reachable(ctx) {
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
		pid := a.readPid()
		if pid == 0 {
			a.reportNotRunningForStop()
			return nil
		}
		if err := a.stopPid(pid); err != nil {
			return err
		}
	}
	fmt.Fprintln(a.Stdout, "stopped")
	return nil
}

// stopPid SIGTERMs a pidfile instance, waits for it to exit, and removes the pidfile.
func (a *App) stopPid(pid int) error {
	if err := syscall.Kill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("signal pid %d: %w", pid, err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for syscall.Kill(pid, 0) == nil {
		if time.Now().After(deadline) {
			return fmt.Errorf("pid %d did not exit within 5 s", pid)
		}
		time.Sleep(50 * time.Millisecond)
	}
	_ = os.Remove(a.pidPath())
	return nil
}

func (a *App) daemonStatus(ctx context.Context, _ *daemonFlags) error {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	c, err := a.dial(ctx)
	if err == nil {
		defer c.Close()
		if resp, err := c.State(ctx); err == nil {
			if a.JSON {
				return a.printJSON(resp.Daemon)
			}
			fmt.Fprintln(a.Stdout, daemonLine(resp.Daemon))
			return nil
		}
	}
	// Not running: same DaemonInfo shape with pid absent (0), and a non-zero
	// status so scripts can key on it without parsing.
	if a.JSON {
		if err := a.printJSON(&leylinev1.DaemonInfo{SocketPath: a.socketPath()}); err != nil {
			return err
		}
	} else {
		fmt.Fprintln(a.Stdout, a.notRunningMessage())
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
	if _, err := io.Copy(a.Stdout, file); err != nil {
		return err
	}
	if !f.follow {
		return nil
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(250 * time.Millisecond):
		}
		if _, err := io.Copy(a.Stdout, file); err != nil {
			return err
		}
	}
}

// pidSuffix is " (pid N)" when the running daemon reports one.
func (a *App) pidSuffix(ctx context.Context) string {
	ctx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	c, err := a.dial(ctx)
	if err != nil {
		return ""
	}
	defer c.Close()
	st, err := c.State(ctx)
	if err != nil || st.GetDaemon().GetPid() == 0 {
		return ""
	}
	return fmt.Sprintf(" (pid %d)", st.Daemon.Pid)
}

// reportNotRunningForStop prints the stop verdict when nothing is running and
// clears a socket file a dead daemon left behind, so the next start is clean.
func (a *App) reportNotRunningForStop() {
	sock := a.socketPath()
	if _, err := os.Stat(sock); err == nil {
		if err := os.Remove(sock); err == nil {
			fmt.Fprintf(a.Stdout, "not running; removed the stale socket %s. Start it with: ley daemon start\n", sock)
			return
		}
	}
	fmt.Fprintln(a.Stdout, "not running. Start it with: ley daemon start")
}
