// SPDX-License-Identifier: Apache-2.0

// Package cli implements the `ley` command tree: Cobra verbs over the
// leyline.v1 client library. Every verb answers --json (proto3 JSON, NDJSON for
// streams) or refuses the flag with a usage error when its output is a script,
// a file or a launchd action rather than data; every verb takes --socket, and
// human output is rendered with text/tabwriter.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"
	"unsafe"

	"github.com/spf13/cobra"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// defaultVersion mirrors the root VERSION file, the single source of truth both
// languages read: `make go` stamps it into Version at link time and
// scripts/gen-version.sh writes the same number into the engine's constant.
// TestVersionMatchesTheSourceOfTruth holds the three together.
const defaultVersion = "0.1.0-dev"

// Version is the ley build version; overridden at link time with
// -ldflags "-X github.com/reflexive-labs/leysdr/go/internal/cli.Version=...".
var Version = defaultVersion

// A binary built outside the Makefile — `go install ...@v0.2.0` — gets no
// ldflags, so the version comes from the module metadata instead of the
// literal. Go stamps "(devel)" for a build from a working tree, which carries
// no version, so that case keeps the literal.
func init() {
	if Version != defaultVersion {
		return
	}
	if info, ok := debug.ReadBuildInfo(); ok && info.Main.Version != "" && info.Main.Version != "(devel)" {
		Version = strings.TrimPrefix(info.Main.Version, "v")
	}
}

// Command groups, in the order `ley --help` lists them.
const (
	GroupListening = "listening"
	GroupAdjusting = "adjusting"
	GroupLooking   = "looking"
	GroupData      = "data"
	GroupDaemon    = "daemon"
)

// App carries the global flags and I/O streams shared by every verb. Tests
// construct one with captured writers; main uses os.Stdout/os.Stderr.
type App struct {
	Stdout io.Writer
	Stderr io.Writer
	// Stdin is where a confirmation is read from (`ley recordings delete`);
	// nil means os.Stdin. IsInTTY reports whether it is a terminal, so a verb
	// that asks knows whether anyone can answer; nil means "detect from
	// Stdin", and a test sets it to take either path.
	Stdin   io.Reader
	IsInTTY func() bool
	// JSON switches every verb to machine output (proto3 JSON mapping).
	JSON bool
	// Socket is the daemon's UDS path; empty means leyline.DefaultSocketPath().
	Socket string
	// Executable is the path of the running ley binary (daemon binary discovery).
	Executable string
	// LookupEnv resolves environment variables; defaults to os.LookupEnv.
	LookupEnv func(string) (string, bool)
	// IsTTY reports whether Stdout is an interactive terminal. nil means
	// "detect from Stdout"; tests set it to force either path.
	IsTTY func() bool
	// TermWidth returns the terminal width in columns, 0 when unknown. nil
	// means "detect from Stdout".
	TermWidth func() int
	// IsErrTTY reports whether Stderr is an interactive terminal; colour is
	// decided per stream, so prose keeps its ink when stdout is a pipe. nil
	// means "detect from Stderr".
	IsErrTTY func() bool
	// TermHeight returns the terminal height in rows, 0 when unknown. nil
	// means measure Stdout. A redraw-in-place chart needs it: cursor-up
	// clamps at the top of the screen, so a block taller than the terminal
	// cannot be addressed and has to scroll instead.
	TermHeight func() int
	// ErrTermWidth returns Stderr's column count, 0 when unknown. nil means
	// "detect from Stderr".
	ErrTermWidth func() int
	// Style is stdout's resolved look and ErrStyle is stderr's. Both are
	// resolved once, before any verb runs (see NewRootCommand). The zero
	// value is plain, ASCII and unknown-width, so an App literal built by a
	// test renders exactly what the golden files hold.
	Style    ui.Style
	ErrStyle ui.Style
	// color is --color ("auto", "always", "never") and ascii is --ascii.
	color string
	ascii bool
	// styled records that resolveStyles has run: the help path never reaches
	// the pre-run hook, so it resolves the styles itself, once.
	styled bool
	// clientKind and clientLabel are what dial sends as leyline-client-kind
	// and leyline-client-label, so the daemon's event log names who did what.
	// Empty means the CLI's own ("cli", "ley"); `ley mcp` sets them so a
	// channel an agent made is attributed to the adapter, not to a shell.
	clientKind, clientLabel string
	// logFile, when set, is the daemon log `ley daemon logs` and the MCP
	// daemon_logs tool read in place of the default path; tests point it at
	// a file they wrote.
	logFile string
}

// NewRootCommand builds the full `ley` command tree bound to app.
func NewRootCommand(app *App) *cobra.Command {
	if app.Stdout == nil {
		app.Stdout = os.Stdout
	}
	if app.Stderr == nil {
		app.Stderr = os.Stderr
	}
	if app.LookupEnv == nil {
		app.LookupEnv = os.LookupEnv
	}
	if app.Stdin == nil {
		app.Stdin = os.Stdin
	}
	if app.IsInTTY == nil {
		app.IsInTTY = func() bool { return isTerminalReader(app.Stdin) }
	}
	if app.IsTTY == nil {
		app.IsTTY = func() bool { return isTerminal(app.Stdout) }
	}
	if app.TermWidth == nil {
		app.TermWidth = func() int { return terminalWidth(app.Stdout) }
	}
	if app.IsErrTTY == nil {
		app.IsErrTTY = func() bool { return isTerminal(app.Stderr) }
	}
	if app.TermHeight == nil {
		app.TermHeight = func() int { return terminalHeight(app.Stdout) }
	}
	if app.ErrTermWidth == nil {
		app.ErrTermWidth = func() int { return terminalWidth(app.Stderr) }
	}
	root := &cobra.Command{
		Use:   "ley",
		Short: "Listen to and look at radio with a Leyline SDR",
		Long: `ley drives the Leyline daemon, the background process that owns your SDR
(software-defined radio). Run it with no arguments to see where things
stand, 'ley tune <frequency>' to hear a station, 'ley set' to adjust it
while it plays, 'ley spectrum' to see what is on the air, and 'ley help
<topic>' for the longer explanations (squelch, frequencies, modes, ...).`,
		Example: `  ley                      # what is the daemon doing right now?
  ley devices              # is my radio visible?
  ley tune 146.52          # listen to 146.520 MHz (a bare number is MHz)
  ley spectrum 101.1       # what is on the air around the FM broadcast band?`,
		SilenceUsage:  true,
		SilenceErrors: true,
		// Cobra only sets this inside its own unknown-command path; rootArgs
		// needs it for SuggestionsFor.
		SuggestionsMinimumDistance: 2,
		Args:                       rootArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runOrientation(cmd.Context(), app, cmd)
		},
	}
	root.SetOut(app.Stdout)
	root.SetErr(app.Stderr)
	root.PersistentFlags().BoolVar(&app.JSON, "json", false, "machine output: proto3 JSON (NDJSON for streams)")
	root.PersistentFlags().StringVar(&app.Socket, "socket", "", "daemon socket path (default: user daemon UDS, $LEYLINE_SOCKET)")
	root.PersistentFlags().StringVar(&app.color, "color", "auto", "colour output: auto, always or never")
	root.PersistentFlags().BoolVar(&app.ascii, "ascii", false, "draw with ASCII only (no box, bar or tree glyphs)")
	// Capabilities are resolved once, before any verb runs, and carried on
	// the App: no renderer re-derives them. Help never reaches this hook, so
	// the help snapshots stay plain whatever the terminal is.
	root.PersistentPreRunE = func(cmd *cobra.Command, _ []string) error {
		return app.resolveStyles(cmd, app.machineStdout(cmd))
	}
	root.AddGroup(
		&cobra.Group{ID: GroupListening, Title: "Listening:"},
		&cobra.Group{ID: GroupAdjusting, Title: "Adjusting:"},
		&cobra.Group{ID: GroupLooking, Title: "Looking around:"},
		&cobra.Group{ID: GroupData, Title: "Data for tools:"},
		&cobra.Group{ID: GroupDaemon, Title: "Daemon:"},
	)
	root.AddCommand(
		newDevicesCommand(app),
		newTuneCommand(app),
		newSetCommand(app),
		newStopCommand(app),
		newSpectrumCommand(app),
		newWaterfallCommand(app),
		newPhosphorCommand(app),
		newScopeCommand(app),
		newLevelsCommand(app),
		newWaveformCommand(app),
		newScanCommand(app),
		newMonitorCommand(app),
		newJobsCommand(app),
		newDecodersCommand(app),
		newDecodeCommand(app),
		newWatchCommand(app),
		newRecordCommand(app),
		newRecordingsCommand(app),
		newRecordsCommand(app),
		newTrackCommand(app),
		newDevicesSeenCommand(app),
		newLabelCommand(app),
		newFFTCommand(app),
		newListenCommand(app),
		newMCPCommand(app),
		newPresetsCommand(app),
		newBandsCommand(app),
		newBookmarksCommand(app),
		newPlayCommand(app),
		newStateCommand(app),
		newDaemonCommand(app),
		newVersionCommand(app),
	)
	root.AddCommand(newStubCommands(app)...)
	// A topic whose name is also a verb (presets) keeps its prose under
	// `ley help <topic>` but registers no bare command: the verb owns the name.
	root.AddCommand(newTopicCommands(app, commandNames(root))...)
	root.SetHelpCommand(newHelpCommand(app))
	root.SetHelpCommandGroupID(GroupLooking)
	root.SetCompletionCommandGroupID(GroupData)
	// Cobra builds the completion verb, so the refusal every verb without
	// machine output makes has to be wrapped around it: a shell script is not
	// JSON, and a pipeline asking for one should stop here rather than feed
	// jq a function definition.
	root.InitDefaultCompletionCmd()
	for _, c := range root.Commands() {
		if c.Name() != compCmdName {
			continue
		}
		refuseJSON(app, c, "completion writes a shell script for your shell to source")
		for _, shell := range c.Commands() {
			refuseJSON(app, shell, "completion writes a shell script for your shell to source")
		}
	}
	// `ley --help` ends with the help topics; children inherit the template
	// and the HasParent guard keeps the block off their help.
	root.SetUsageTemplate(strings.Replace(root.UsageTemplate(),
		`{{if .HasAvailableSubCommands}}

Use "{{.CommandPath}} [command] --help" for more information about a command.{{end}}`,
		`{{if not .HasParent}}

Help topics ("ley help <topic>"):
`+topicList()+`{{end}}{{if .HasAvailableSubCommands}}

Use "{{.CommandPath}} [command] --help" for more information about a command.{{end}}`, 1))
	// Every help screen, the subcommands' included (they inherit the root's
	// help func), goes through the style before it is printed.
	root.SetHelpFunc(app.helpFunc(root.HelpFunc()))
	// Flag errors and argument-count errors are usage errors (exit 2) for
	// every verb, including ones that return Cobra's own messages.
	root.SetFlagErrorFunc(func(_ *cobra.Command, err error) error { return usageError(err) })
	wrapArgs(root)
	return root
}

// commandNames is the set of verb names already registered on cmd.
func commandNames(cmd *cobra.Command) map[string]bool {
	names := make(map[string]bool)
	for _, sub := range cmd.Commands() {
		names[sub.Name()] = true
	}
	return names
}

// wrapArgs turns every verb's positional-argument error into a usage error.
func wrapArgs(cmd *cobra.Command) {
	if orig := cmd.Args; orig != nil {
		cmd.Args = func(c *cobra.Command, args []string) error {
			if err := orig(c, args); err != nil {
				return usageError(err)
			}
			return nil
		}
	}
	for _, sub := range cmd.Commands() {
		wrapArgs(sub)
	}
}

// rootArgs handles `ley <not-a-verb>`, so the root's own RunE only runs for a
// bare `ley`. It prints what `ley help <not-a-topic>` prints: the failure,
// then what to try -- Cobra's "did you mean" when the name is close to a
// verb, the topic list when it is not, and the command list either way.
func rootArgs(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return nil
	}
	msg := fmt.Sprintf("no command or topic named %q.", args[0])
	if s := cmd.SuggestionsFor(args[0]); len(s) > 0 {
		msg += "\n\nDid you mean this?\n"
		for _, name := range s {
			msg += "  " + name + "\n"
		}
	} else {
		msg += "\n\nTopics:\n" + topicList() + "\n"
	}
	msg += fmt.Sprintf("\nRun '%s --help' for the commands.", cmd.CommandPath())
	return &ExitError{Code: ExitUsage, Message: msg}
}

// Execute runs the command tree with args and returns the verb's error.
func Execute(ctx context.Context, app *App, args []string) error {
	root := NewRootCommand(app)
	root.SetArgs(args)
	err := withCode(root.ExecuteContext(ctx))
	// A verb that finished its work by handing it to something else -- `ley play` on an audio
	// recording, which opens it in the machine's own player -- has nothing left to run and
	// nothing to report. It is a success with an early return, not a failure.
	if errors.Is(err, errDone) {
		return nil
	}
	if err != nil && !app.styled {
		// A usage error (unknown verb, bad flag) is raised before the pre-run
		// hook resolves the styles, and the error line still wants stderr's
		// ink. A --color the flag parser rejected leaves the styles plain.
		_ = app.resolveStyles(root, app.machineStdout(root))
	}
	return err
}

// withCode gives a daemon error its final shape: "<message> [CODE]", the
// code in brackets at the end so scripts can grep for it, as `ley help
// scripting` promises. The *leyline.Error stays reachable through Unwrap.
// Errors that already carry an exit status pass through unchanged.
func withCode(err error) error {
	if err == nil {
		return nil
	}
	var ee *ExitError
	if errors.As(err, &ee) {
		return err
	}
	var le *leyline.Error
	if !errors.As(err, &le) || le.Code == "" {
		return err
	}
	msg := strings.Replace(err.Error(), le.Code+": ", "", 1)
	return &ExitError{Code: 1, Message: msg + " [" + le.Code + "]", Err: err}
}

// fileMissing is the error for a file a verb needs that is not there: the
// path in plain words, then hint (what to do next). Callers use it for
// os.ErrNotExist; other open failures keep their own reason.
func fileMissing(path, hint string) error {
	return fmt.Errorf("there is no file at %s; %s", path, hint)
}

// socketPath resolves the effective socket path.
func (a *App) socketPath() string {
	if a.Socket != "" {
		return a.Socket
	}
	return leyline.DefaultSocketPath()
}

// dial connects to the daemon with the CLI identity (or the one clientKind
// and clientLabel name).
func (a *App) dial(ctx context.Context) (*leyline.Client, error) {
	kind, label := a.clientKind, a.clientLabel
	if kind == "" {
		kind = "cli"
	}
	if label == "" {
		label = "ley"
	}
	c, err := leyline.Dial(ctx, a.socketPath(), leyline.WithKind(kind), leyline.WithLabel(label))
	if err != nil {
		return nil, err
	}
	return c, nil
}

// Exit statuses (documented in docs/reference/cli.md and `ley help scripting`).
const (
	// ExitUsage is a usage error: bad flag, wrong arguments, unknown verb or
	// parameter. Nothing was sent to the daemon.
	ExitUsage = 2
	// ExitNotRunning means no daemon answered on the socket, from any verb.
	ExitNotRunning = 3
	// ExitInterrupted is used when the user interrupted the verb (SIGINT).
	ExitInterrupted = 130
)

// ExitError carries a process exit status. An empty Message means the verb
// already reported the condition on stdout and main should print nothing.
type ExitError struct {
	Code    int
	Message string
	// Err is the underlying error, if any, for errors.Is/As.
	Err error
}

func (e *ExitError) Error() string { return e.Message }

func (e *ExitError) Unwrap() error { return e.Err }

// usageError wraps err as an exit-2 usage error (idempotent for ExitErrors).
func usageError(err error) error {
	if err == nil {
		return nil
	}
	var ee *ExitError
	if errors.As(err, &ee) {
		return err
	}
	return &ExitError{Code: ExitUsage, Message: err.Error(), Err: err}
}

// compCmdName is Cobra's name for the completion verb.
const compCmdName = "completion"

// noJSONErrorf is the refusal a verb with no machine output makes. The flag is
// a usage error rather than a no-op so a script that pipes the verb through jq
// fails at the verb, and instead names the command that gives the same answer.
func noJSONErrorf(verb, instead string) error {
	return usageErrorf("%s has no --json output; drop the flag (%s)", verb, instead)
}

// refuseJSON wraps a command Cobra owns so --json is refused before it runs.
// A command with no RunE of its own (the bare `ley completion`) prints its
// help, which is what Cobra does with it.
func refuseJSON(app *App, cmd *cobra.Command, instead string) {
	run := cmd.RunE
	name := strings.TrimPrefix(cmd.CommandPath(), "ley ")
	cmd.RunE = func(c *cobra.Command, args []string) error {
		if app.JSON {
			return noJSONErrorf(name, instead)
		}
		if run == nil {
			return c.Help()
		}
		return run(c, args)
	}
}

// usageErrorf builds an exit-2 usage error from a format string.
func usageErrorf(format string, args ...any) error {
	return &ExitError{Code: ExitUsage, Message: fmt.Sprintf(format, args...)}
}

// jsonMarshal is the canonical proto3 JSON mapping (lowerCamelCase keys).
var jsonMarshal = protojson.MarshalOptions{}

// printJSON writes one proto message as a single JSON line.
func (a *App) printJSON(m proto.Message) error {
	b, err := jsonMarshal.Marshal(m)
	if err != nil {
		return err
	}
	_, err = fmt.Fprintf(a.Stdout, "%s\n", b)
	return err
}

// table returns a tabwriter over stdout; callers must Flush. The first line
// written through it is the header row and takes Label ink: tabwriter still
// measures the plain text, so the SGR bytes cannot misalign a column.
func (a *App) table() *tableWriter {
	out := a.Stdout
	var ink *headerInk
	if a.Style.Color {
		ink = &headerInk{w: a.Stdout, ink: a.Style.Label}
		out = ink
	}
	return &tableWriter{Writer: tabwriter.NewWriter(out, 0, 8, 2, ' ', 0), ink: ink}
}

// tableWriter is a tabwriter whose Flush also drains the header inker, so a
// header row written without a trailing newline still reaches stdout.
type tableWriter struct {
	*tabwriter.Writer
	ink *headerInk
}

func (t *tableWriter) Flush() error {
	if err := t.Writer.Flush(); err != nil {
		return err
	}
	if t.ink != nil {
		return t.ink.flush()
	}
	return nil
}

// headerInk applies one ink role to the first line written through it and
// passes everything after it through untouched. It sits between the
// tabwriter and stdout so the escape bytes are added after the columns are
// measured; trailing padding stays outside the ink so a selection of the
// header does not pick up the run of spaces.
type headerInk struct {
	w    io.Writer
	ink  func(string) string
	buf  []byte
	done bool
}

func (h *headerInk) Write(p []byte) (int, error) {
	if h.done {
		return h.w.Write(p)
	}
	for i, b := range p {
		if b != '\n' {
			continue
		}
		h.buf = append(h.buf, p[:i]...)
		line := string(h.buf)
		h.buf, h.done = nil, true
		text := strings.TrimRight(line, " ")
		if _, err := io.WriteString(h.w, h.ink(text)+line[len(text):]+"\n"); err != nil {
			return 0, err
		}
		if rest := p[i+1:]; len(rest) > 0 {
			if _, err := h.w.Write(rest); err != nil {
				return 0, err
			}
		}
		return len(p), nil
	}
	h.buf = append(h.buf, p...)
	return len(p), nil
}

// flush writes any buffered partial line, inked, and stops further inking.
func (h *headerInk) flush() error {
	if h.done || len(h.buf) == 0 {
		return nil
	}
	line := string(h.buf)
	h.buf, h.done = nil, true
	text := strings.TrimRight(line, " ")
	_, err := io.WriteString(h.w, h.ink(text)+line[len(text):])
	return err
}

// resolveStyles decides stdout's and stderr's look once, before cmd runs.
// Machine output on stdout (--json, a bulk row stream, --format bin) turns
// stdout's colour off before any renderer exists; stderr keeps its ink so a
// person still gets prose and warnings in colour.
func (a *App) resolveStyles(cmd *cobra.Command, machine bool) error {
	switch a.color {
	case "", "auto", "always", "never":
	default:
		return usageErrorf("--color must be auto, always or never (got %q)", a.color)
	}
	o := ui.Options{
		Color:        a.color,
		ASCII:        a.ascii,
		Width:        widthFlag(cmd),
		Machine:      machine,
		StdoutTTY:    a.IsTTY(),
		StderrTTY:    a.IsErrTTY(),
		StdoutWidth:  a.TermWidth(),
		StdoutHeight: a.TermHeight(),
		StderrWidth:  a.ErrTermWidth(),
		LookupEnv:    a.LookupEnv,
	}
	a.Style = ui.Resolve(o)
	o.Stderr = true
	a.ErrStyle = ui.Resolve(o)
	a.styled = true
	return nil
}

// helpFunc wraps Cobra's help renderer (def) so the finished screen goes
// through styleHelp. Help never reaches PersistentPreRunE, so the styles are
// resolved here when nothing else has; through a pipe -- which is how the
// snapshots in testdata/help are captured -- the style is plain and the
// screen comes out byte-identical.
func (a *App) helpFunc(def func(*cobra.Command, []string)) func(*cobra.Command, []string) {
	return func(c *cobra.Command, args []string) {
		out := a.helpStyle(c)
		var buf strings.Builder
		c.SetOut(&buf)
		def(c, args)
		c.SetOut(out)
		fmt.Fprint(out, styleHelp(a.Style, buf.String()))
	}
}

// printHelpText writes one already-rendered help screen (a topic's prose)
// through the resolved style.
func (a *App) printHelpText(c *cobra.Command, text string) {
	out := a.helpStyle(c)
	fmt.Fprint(out, styleHelp(a.Style, strings.TrimRight(text, "\n")+"\n"))
}

// helpStyle resolves the styles if the pre-run hook has not, and returns the
// writer help is printed to.
func (a *App) helpStyle(c *cobra.Command) io.Writer {
	if !a.styled {
		// Help is a screen even for the verbs whose stdout is a row stream
		// (`ley fft --help` is read by a person), so it is never machine
		// output. A bad --color is reported by the verb, not by help.
		_ = a.resolveStyles(c, false)
	}
	return c.OutOrStdout()
}

// bulkRowVerbs are the verbs whose stdout is a row stream for a tool, not a
// screen: they are never styled, whatever the terminal says.
var bulkRowVerbs = map[string]bool{"fft": true, "listen": true}

// machineStdout reports whether cmd writes machine output on stdout.
func (a *App) machineStdout(cmd *cobra.Command) bool {
	if a.JSON || bulkRowVerbs[cmd.Name()] {
		return true
	}
	f := cmd.Flags().Lookup("format")
	return f != nil && f.Value.String() == "bin"
}

// widthFlag reads cmd's own --width, for the verbs that have one; 0 when the
// verb has no such flag or the user did not set it.
func widthFlag(cmd *cobra.Command) int {
	f := cmd.Flags().Lookup("width")
	if f == nil || !f.Changed {
		return 0
	}
	n, err := strconv.Atoi(f.Value.String())
	if err != nil || n < 0 {
		return 0
	}
	return n
}

// notRunning turns a dial/RPC failure into what the user should do next. A
// transport failure (nothing listening on the socket) becomes an exit-3
// ExitError with the start command; every other daemon error passes through
// unchanged so its [CODE] and message reach the user.
func (a *App) notRunning(err error) error {
	if err == nil {
		return nil
	}
	var ee *ExitError
	if errors.As(err, &ee) {
		return err
	}
	if leyline.Code(err) != leyline.CodeUnavailable {
		return err
	}
	return &ExitError{Code: ExitNotRunning, Message: a.notRunningMessage(), Err: err}
}

// notRunningMessage is the one-line "daemon is not running" sentence with the
// exact next command; a socket file nobody answers on gets the stale variant.
func (a *App) notRunningMessage() string {
	sock := a.socketPath()
	if _, err := os.Stat(sock); err == nil {
		return fmt.Sprintf("the Leyline daemon is not running (stale socket %s; a previous daemon left it behind). Run: ley daemon stop && ley daemon start", sock)
	}
	return fmt.Sprintf("the Leyline daemon is not running (socket %s). Start it with: ley daemon start", sock)
}

// isNotRunning reports whether err is the exit-3 "daemon not running" error.
func isNotRunning(err error) bool {
	var ee *ExitError
	return errors.As(err, &ee) && ee.Code == ExitNotRunning
}

// isTerminal reports whether w is an interactive terminal (a character device).
func isTerminal(w io.Writer) bool {
	f, ok := w.(*os.File)
	if !ok {
		return false
	}
	st, err := f.Stat()
	return err == nil && st.Mode()&os.ModeCharDevice != 0
}

// isTerminalReader reports whether r is a terminal someone can type into.
// A character device is not enough: /dev/null is one, and a confirmation
// read from it would take the empty answer for the person's. The window-size
// ioctl succeeds on a terminal alone (a pty with no size set reports zero
// columns, and still succeeds).
func isTerminalReader(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	var ws struct{ rows, cols, x, y uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	return errno == 0
}

// terminalWidth returns w's column count, or 0 when it is not a terminal or
// the size is unknown.
func terminalWidth(w io.Writer) int {
	f, ok := w.(*os.File)
	if !ok {
		return 0
	}
	return ttyColumns(f)
}

// terminalHeight is the row count of w's terminal, 0 when it is not one.
func terminalHeight(w io.Writer) int {
	f, ok := w.(*os.File)
	if !ok {
		return 0
	}
	return ttyRows(f)
}

// indentLines indents every line of s by indent; it keeps the caller's line
// breaks (help texts are hand-wrapped) and only adds the prefix.
func indentLines(s, indent string) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	for i, l := range lines {
		if l != "" {
			lines[i] = indent + l
		}
	}
	return strings.Join(lines, "\n")
}

// ttySize asks the terminal for its size with TIOCGWINSZ; zeroes when f is not
// a terminal. Rows matter as well as columns: a chart that redraws in place
// with cursor-up cannot address a block taller than the screen, because the
// cursor clamps at the top and the first lines are stranded.
func ttySize(f *os.File) (cols, rows int) {
	var ws struct{ rows, cols, x, y uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 0, 0
	}
	return int(ws.cols), int(ws.rows)
}

// ttyColumns is ttySize's width alone.
func ttyColumns(f *os.File) int {
	c, _ := ttySize(f)
	return c
}

// ttyRows is ttySize's height alone.
func ttyRows(f *os.File) int {
	_, r := ttySize(f)
	return r
}

// orientDialTimeout bounds the bare-`ley` daemon probe: orientation must
// never hang on a dead socket.
const orientDialTimeout = 300 * time.Millisecond

// runOrientation is the bare `ley`: it shows where things stand and what to
// type next, styled on a terminal and plain in a pipe. The Long text documents
// "run it with no arguments to see where things stand", so `ley | tee log`
// prints the same screen and `ley --help` stays the verb list. Under --json it
// prints `ley state --json`'s snapshot.
// Exit 0 in every state the screen can draw.
func runOrientation(ctx context.Context, app *App, _ *cobra.Command) error {
	if app.JSON {
		st, err := stateSnapshot(ctx, app)
		if err != nil {
			return err
		}
		return app.printJSON(st)
	}
	dctx, cancel := context.WithTimeout(ctx, orientDialTimeout)
	defer cancel()
	var state *leylinev1.GetStateResponse
	c, err := app.dial(dctx)
	if err == nil {
		defer c.Close()
		state, err = c.State(dctx)
	}
	if err != nil {
		err = app.notRunning(err)
	}
	fmt.Fprint(app.Stdout, renderOrientation(app.Style, state, err))
	return nil
}

// orientLabel is the orientation screen's left column: one Label-inked word
// padded to nine visible columns, so the ink cannot move the text beside it.
func orientLabel(s ui.Style, word string) string {
	if word == "" {
		return strings.Repeat(" ", 9)
	}
	return s.Pad(s.Label(word), 9)
}

// orientNow is the clock the orientation screen ages the daemon against; a
// test freezes it so two renders of one state cannot differ by a second.
var orientNow = time.Now

// orientDaemonLine is daemonLine with its diagnostics dimmed: same bytes, less
// weight on the pid and the socket path.
func orientDaemonLine(s ui.Style, d *leylinev1.DaemonInfo) string {
	if d == nil {
		return daemonLine(d)
	}
	up := orientNow().Sub(time.Unix(0, d.StartedAtNs)).Truncate(time.Second)
	return fmt.Sprintf("daemon %s %s", d.Version, s.Muted(fmt.Sprintf("pid %d up %s socket %s", d.Pid, up, d.SocketPath)))
}

// renderOrientation renders the orientation screen for one state snapshot:
// daemon status, devices, what is playing, and the next commands chosen from
// the state. err is the daemon probe's failure (state is nil then).
func renderOrientation(s ui.Style, state *leylinev1.GetStateResponse, err error) string {
	var b strings.Builder
	next := func(pairs ...string) {
		fmt.Fprintf(&b, "\n%s\n", s.Label("Next:"))
		for i := 0; i+1 < len(pairs); i += 2 {
			fmt.Fprintf(&b, "  %s %s\n", s.Pad(s.Cmd(pairs[i]), 28), s.Muted(pairs[i+1]))
		}
	}
	if err != nil {
		if isNotRunning(err) {
			fmt.Fprintf(&b, "%s %s\n  %s\n", orientLabel(s, "Daemon"), s.Err("not running"), err.Error())
			next("ley daemon start", "start the daemon (it owns the radio)",
				"ley daemon logs", "read its log if starting fails",
				"ley help", "list every command")
		} else {
			fmt.Fprintf(&b, "%s %s\n", orientLabel(s, "Daemon"), s.Err(fmt.Sprintf("error: %v", err)))
			next("ley daemon status", "check the daemon", "ley daemon logs", "read its log")
		}
		return b.String()
	}
	fmt.Fprintf(&b, "%s %s\n", orientLabel(s, "Daemon"), orientDaemonLine(s, state.GetDaemon()))
	if len(state.GetDevices()) == 0 {
		fmt.Fprintf(&b, "%s %s\n", orientLabel(s, "Devices"), s.Warn("none found"))
		b.WriteString(indentLines(noDeviceChecklist, "  ") + "\n")
		next("ley devices", "look again after plugging in", "ley daemon logs", "see what the daemon saw")
		return b.String()
	}
	for i, d := range state.Devices {
		label := "Devices"
		if i > 0 {
			label = ""
		}
		fmt.Fprintf(&b, "%s %s\n", orientLabel(s, label), deviceSummary(s, d))
	}
	if len(state.GetChannels()) == 0 {
		fmt.Fprintf(&b, "%s %s\n", orientLabel(s, "Playing"), s.Muted("nothing"))
		next("ley tune 146.52", "listen (a bare number is MHz; presets: ley help presets)",
			"ley spectrum 101.1", "see what is on the air around a frequency",
			"ley help frequencies", "how to write frequencies")
		return b.String()
	}
	for i, ch := range state.Channels {
		label := "Playing"
		if i > 0 {
			label = ""
		}
		fmt.Fprintf(&b, "%s %s\n", orientLabel(s, label), orientChannelLine(s, state, ch))
	}
	next("ley set squelch -40", "mute the audio below a level (or: auto)",
		"ley set gain 30", "change the radio's gain (or: auto)",
		"ley spectrum", "see the band around what is playing",
		"ley state", "everything the daemon knows")
	return b.String()
}

// deviceSummary is one line per device: model, driver, serial and state. The
// model leads plain, the driver and serial are diagnostics and dim, and the
// state word is inked by its meaning.
func deviceSummary(s ui.Style, d *leylinev1.DeviceDescriptor) string {
	name := d.Model
	if name == "" {
		name = d.DeviceId
	}
	about := "(" + d.Driver
	if d.Serial != "" {
		about += ", serial " + d.Serial
	}
	return fmt.Sprintf("%s %s %s, %s", name, s.Muted(about+")"), inkState(s, stateWord(d.State.String())),
		s.Muted("tunes "+absentIfEmpty(s, rangesPhrase(d.TuningRanges))))
}

// orientChannelLine is one line per channel: frequency, mode, squelch, owner.
func orientChannelLine(s ui.Style, state *leylinev1.GetStateResponse, ch *leylinev1.Channel) string {
	freq := channelFreqLabel(state, ch)
	return fmt.Sprintf("%s %s, squelch %s, %s %s", freq, strings.ToUpper(leyline.ModeName(ch.Mode)),
		squelchString(ch.SquelchDb), inkState(s, stateWord(ch.State.String())), s.Muted("("+ch.ChannelId+")"))
}
