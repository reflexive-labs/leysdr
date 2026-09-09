// Package cli implements the `ley` command tree: Cobra verbs over the
// leyline.v1 client library. Every verb honours --json (proto3 JSON, NDJSON for
// streams) and --socket, and renders human output with text/tabwriter.
package cli

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"
	"unsafe"

	"github.com/spf13/cobra"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Version is the ley build version; overridden at link time with
// -ldflags "-X github.com/dpup/leysdr/go/internal/cli.Version=...".
var Version = "0.1.0-dev"

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
	if app.IsTTY == nil {
		app.IsTTY = func() bool { return isTerminal(app.Stdout) }
	}
	if app.TermWidth == nil {
		app.TermWidth = func() int { return terminalWidth(app.Stdout) }
	}
	if app.IsErrTTY == nil {
		app.IsErrTTY = func() bool { return isTerminal(app.Stderr) }
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
		return app.resolveStyles(cmd)
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
		newFFTCommand(app),
		newListenCommand(app),
		newPresetsCommand(app),
		newBandsCommand(app),
		newPlayCommand(app),
		newStateCommand(app),
		newDaemonCommand(app),
		newVersionCommand(app),
	)
	root.AddCommand(newStubCommands(app)...)
	// A topic whose name is also a verb (presets) keeps its prose under
	// `ley help <topic>` but registers no bare command: the verb owns the name.
	root.AddCommand(newTopicCommands(commandNames(root))...)
	root.SetHelpCommand(newHelpCommand())
	root.SetHelpCommandGroupID(GroupLooking)
	root.SetCompletionCommandGroupID(GroupData)
	// `ley --help` ends with the help topics; children inherit the template
	// and the HasParent guard keeps the block off their help.
	root.SetUsageTemplate(strings.Replace(root.UsageTemplate(),
		`{{if .HasAvailableSubCommands}}

Use "{{.CommandPath}} [command] --help" for more information about a command.{{end}}`,
		`{{if not .HasParent}}

Help topics ("ley help <topic>"):
`+topicList()+`{{end}}{{if .HasAvailableSubCommands}}

Use "{{.CommandPath}} [command] --help" for more information about a command.{{end}}`, 1))
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

// rootArgs reproduces Cobra's unknown-command error (with its "did you mean"
// suggestions) for `ley <not-a-verb>`, so the root's own RunE only runs for a
// bare `ley`.
func rootArgs(cmd *cobra.Command, args []string) error {
	if len(args) == 0 {
		return nil
	}
	msg := fmt.Sprintf("unknown command %q for %q", args[0], cmd.CommandPath())
	if s := cmd.SuggestionsFor(args[0]); len(s) > 0 {
		msg += "\n\nDid you mean this?\n"
		for _, name := range s {
			msg += "\t" + name + "\n"
		}
	}
	msg += fmt.Sprintf("\nRun '%s --help' for usage.", cmd.CommandPath())
	return &ExitError{Code: ExitUsage, Message: msg}
}

// Execute runs the command tree with args and returns the verb's error.
func Execute(ctx context.Context, app *App, args []string) error {
	root := NewRootCommand(app)
	root.SetArgs(args)
	return withCode(root.ExecuteContext(ctx))
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

// dial connects to the daemon with the CLI identity.
func (a *App) dial(ctx context.Context) (*leyline.Client, error) {
	c, err := leyline.Dial(ctx, a.socketPath(), leyline.WithKind("cli"), leyline.WithLabel("ley"))
	if err != nil {
		return nil, err
	}
	return c, nil
}

// Exit statuses (documented in interfaces.md and `ley help scripting`).
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
func (a *App) table() *tabwriter.Writer {
	out := a.Stdout
	if a.Style.Color {
		out = &headerInk{w: a.Stdout, ink: a.Style.Label}
	}
	return tabwriter.NewWriter(out, 0, 8, 2, ' ', 0)
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

// resolveStyles decides stdout's and stderr's look once, before cmd runs.
// Machine output on stdout (--json, a bulk row stream, --format bin) turns
// stdout's colour off before any renderer exists; stderr keeps its ink so a
// person still gets prose and warnings in colour.
func (a *App) resolveStyles(cmd *cobra.Command) error {
	switch a.color {
	case "", "auto", "always", "never":
	default:
		return usageErrorf("--color must be auto, always or never (got %q)", a.color)
	}
	o := ui.Options{
		Color:       a.color,
		ASCII:       a.ascii,
		Width:       widthFlag(cmd),
		Machine:     a.machineStdout(cmd),
		StdoutTTY:   a.IsTTY(),
		StderrTTY:   a.IsErrTTY(),
		StdoutWidth: a.TermWidth(),
		StderrWidth: a.ErrTermWidth(),
		LookupEnv:   a.LookupEnv,
	}
	a.Style = ui.Resolve(o)
	o.Stderr = true
	a.ErrStyle = ui.Resolve(o)
	return nil
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

// terminalWidth returns w's column count, or 0 when it is not a terminal or
// the size is unknown.
func terminalWidth(w io.Writer) int {
	f, ok := w.(*os.File)
	if !ok {
		return 0
	}
	return ttyColumns(f)
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

// ttyColumns asks the terminal for its width with TIOCGWINSZ; 0 when f is not
// a terminal.
func ttyColumns(f *os.File) int {
	var ws struct{ rows, cols, x, y uint16 }
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&ws)))
	if errno != 0 {
		return 0
	}
	return int(ws.cols)
}

// orientDialTimeout bounds the bare-`ley` daemon probe: orientation must
// never hang on a dead socket.
const orientDialTimeout = 300 * time.Millisecond

// runOrientation is the bare `ley`: on a terminal it shows where things stand
// and what to type next; piped it prints the verb list; --json points at the
// machine-readable state. Exit 0 in every state.
func runOrientation(ctx context.Context, app *App, cmd *cobra.Command) error {
	if app.JSON {
		fmt.Fprintln(app.Stderr, "ley: the orientation screen is for terminals; for machine output use: ley state --json")
		return nil
	}
	if !app.IsTTY() {
		return cmd.Help()
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
	fmt.Fprint(app.Stdout, renderOrientation(state, err))
	return nil
}

// renderOrientation renders the orientation screen for one state snapshot:
// daemon status, devices, what is playing, and the next commands chosen from
// the state. err is the daemon probe's failure (state is nil then). The V0.5
// dashboard reuses this for its no-daemon/no-device states.
func renderOrientation(state *leylinev1.GetStateResponse, err error) string {
	var b strings.Builder
	next := func(pairs ...string) {
		b.WriteString("\nNext:\n")
		for i := 0; i+1 < len(pairs); i += 2 {
			fmt.Fprintf(&b, "  %-28s %s\n", pairs[i], pairs[i+1])
		}
	}
	if err != nil {
		if isNotRunning(err) {
			fmt.Fprintf(&b, "Daemon    not running\n  %s\n", err.Error())
			next("ley daemon start", "start the daemon (it owns the radio)",
				"ley daemon logs", "read its log if starting fails",
				"ley help", "list every command")
		} else {
			fmt.Fprintf(&b, "Daemon    error: %v\n", err)
			next("ley daemon status", "check the daemon", "ley daemon logs", "read its log")
		}
		return b.String()
	}
	fmt.Fprintf(&b, "Daemon    %s\n", daemonLine(state.GetDaemon()))
	if len(state.GetDevices()) == 0 {
		b.WriteString("Devices   none found\n")
		b.WriteString(indentLines(noDeviceChecklist, "  ") + "\n")
		next("ley devices", "look again after plugging in", "ley daemon logs", "see what the daemon saw")
		return b.String()
	}
	for i, d := range state.Devices {
		label := "Devices"
		if i > 0 {
			label = ""
		}
		fmt.Fprintf(&b, "%-9s %s\n", label, deviceSummary(d))
	}
	if len(state.GetChannels()) == 0 {
		b.WriteString("Playing   nothing\n")
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
		fmt.Fprintf(&b, "%-9s %s\n", label, orientChannelLine(state, ch))
	}
	next("ley set squelch -40", "mute the audio below a level (or: auto)",
		"ley set gain 30", "change the radio's gain (or: auto)",
		"ley spectrum", "see the band around what is playing",
		"ley state", "everything the daemon knows")
	return b.String()
}

// deviceSummary is one line per device: model, driver, serial and state.
func deviceSummary(d *leylinev1.DeviceDescriptor) string {
	name := d.Model
	if name == "" {
		name = d.DeviceId
	}
	s := fmt.Sprintf("%s (%s", name, d.Driver)
	if d.Serial != "" {
		s += ", serial " + d.Serial
	}
	return fmt.Sprintf("%s) %s, tunes %s", s, strings.ReplaceAll(strings.ToLower(enumName(d.State.String())), "_", " "), rangesString(d.TuningRanges))
}

// orientChannelLine is one line per channel: frequency, mode, squelch, owner.
func orientChannelLine(state *leylinev1.GetStateResponse, ch *leylinev1.Channel) string {
	freq := channelFreqLabel(state, ch)
	return fmt.Sprintf("%s %s, squelch %s, %s (%s)", freq, strings.ToUpper(leyline.ModeName(ch.Mode)),
		squelchString(ch.SquelchDb), strings.ToLower(enumName(ch.State.String())), ch.ChannelId)
}
