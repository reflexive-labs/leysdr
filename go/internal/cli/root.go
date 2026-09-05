// Package cli implements the `ley` command tree: Cobra verbs over the
// leyline.v1 client library. Every verb honours --json (proto3 JSON, NDJSON for
// streams) and --socket, and renders human output with text/tabwriter.
package cli

import (
	"context"
	"fmt"
	"io"
	"os"
	"text/tabwriter"

	"github.com/spf13/cobra"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Version is the ley build version; overridden at link time with
// -ldflags "-X github.com/dpup/leysdr/go/internal/cli.Version=...".
var Version = "0.1.0-dev"

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
	root := &cobra.Command{
		Use:           "ley",
		Short:         "Leyline SDR command line",
		Long:          "ley drives the Leyline daemon over its gRPC socket: tune, adjust, inspect and stream.",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.SetOut(app.Stdout)
	root.SetErr(app.Stderr)
	root.PersistentFlags().BoolVar(&app.JSON, "json", false, "machine output: proto3 JSON (NDJSON for streams)")
	root.PersistentFlags().StringVar(&app.Socket, "socket", "", "daemon socket path (default: user daemon UDS, $LEYLINE_SOCKET)")
	root.AddCommand(
		newDevicesCommand(app),
		newTuneCommand(app),
		newSetCommand(app),
		newFFTCommand(app),
		newPlayCommand(app),
		newStateCommand(app),
		newDaemonCommand(app),
		newVersionCommand(app),
	)
	return root
}

// Execute runs the command tree with args and returns the verb's error.
func Execute(ctx context.Context, app *App, args []string) error {
	root := NewRootCommand(app)
	root.SetArgs(args)
	return root.ExecuteContext(ctx)
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

// Exit statuses beyond the generic 1.
const (
	// ExitNotRunning is returned by `daemon status` when no daemon answers.
	ExitNotRunning = 3
	// ExitInterrupted is used when the user interrupted the verb (SIGINT).
	ExitInterrupted = 130
)

// ExitError carries a process exit status. An empty Message means the verb
// already reported the condition on stdout and main should print nothing.
type ExitError struct {
	Code    int
	Message string
}

func (e *ExitError) Error() string { return e.Message }

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

// table returns a tabwriter over stdout; callers must Flush.
func (a *App) table() *tabwriter.Writer {
	return tabwriter.NewWriter(a.Stdout, 0, 8, 2, ' ', 0)
}

// notRunning wraps a dial/RPC failure so users see the socket they tried.
func (a *App) notRunning(err error) error {
	return fmt.Errorf("daemon not reachable at %s: %w", a.socketPath(), err)
}
