// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/spf13/cobra"
	"google.golang.org/protobuf/proto"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// `ley mcp` is the MCP adapter of docs/plans/mcp.md: an MCP server an agent's
// client spawns, speaking MCP on stdin and stdout and leyline.v1 to the
// daemon over the same socket every other client uses. It is a client of the
// daemon, not a second surface on it (AGENTS.md invariant 1), and every tool
// is a `ley` verb seen from an agent: the same protos, the same proto3 JSON
// `--json` prints, the same decisions and refusals. The daemon computes;
// this process renders (invariant 2) -- the one picture it draws, the
// snapshot PNG, is drawn from rows the daemon already made.

func newMCPCommand(app *App) *cobra.Command {
	var logPath string
	cmd := &cobra.Command{
		Use:   "mcp",
		Short: "Serve the radio to an agent over MCP (stdin and stdout)",
		Long: `mcp runs a Model Context Protocol server for a coding agent or an assistant:
the agent's MCP client starts 'ley mcp' as a subprocess and speaks MCP over
its stdin and stdout, and mcp speaks to the daemon the way every other ley
verb does. Each tool is a ley verb seen from an agent -- list_devices is
'ley devices', tune is 'ley tune', scan is 'ley scan', query_records is
'ley records' -- and returns the same proto3 JSON '--json' prints, plus a
short text summary so the agent spends its context on reasoning.

Tools: list_devices, get_state, daemon_logs, tune, scan, listen_summary,
snapshot, list_decoders, query_records, list_entities, start_decode_job,
record, find_recordings, get_recording, delete_recording, list_jobs, get_job,
cancel_job. The resources ley://recordings/<job_id> and ley://records/<job_id>
read a recording's manifest and a kept decode job's records. Anything an agent
starts here (a channel from tune, a decode job without keep) ends when the
agent disconnects, the way a ley verb's ends at Ctrl-C; keep: true on a tool
leaves it running, and a recording always outlives the call that made it.

The socket has no authentication, so an agent that can start 'ley mcp' can
do anything a shell running ley can: tune, take a radio over, cancel jobs.
That is the same trust a local shell already has. There is no network
transport; a remote agent waits on the remote-access milestone.

Configure it in an MCP client as the command 'ley' with the argument 'mcp'
(and '--socket PATH' when the daemon is not on the default socket; --log
PATH when its log is not the default one, so daemon_logs reads the right
file). --json is refused: the whole conversation is JSON already.`,
		Example: `  ley mcp                     # what an MCP client runs; not for typing at a prompt
  claude mcp add leyline -- ley mcp
  {"mcpServers": {"leyline": {"command": "ley", "args": ["mcp"]}}}`,
		GroupID: GroupData,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if app.JSON {
				return noJSONErrorf("mcp", "it speaks MCP over stdin and stdout; ley state --json is the snapshot")
			}
			app.logFile = logPath
			return runMCP(cmd.Context(), app)
		},
	}
	cmd.Flags().StringVar(&logPath, "log", "", "the daemon's log file the daemon_logs tool reads (default: the log ley daemon start writes; a daemon started by hand logs where it was told)")
	return cmd
}

// runMCP serves MCP on stdin and stdout until the client hangs up or the
// process is interrupted. The daemon is dialled first so a missing daemon is
// the ordinary exit-3 line on stderr rather than a tool error the agent
// discovers one call in.
func runMCP(ctx context.Context, app *App) error {
	app.clientKind, app.clientLabel = "mcp", "ley mcp"
	srv, err := newMCPServer(ctx, app)
	if err != nil {
		return err
	}
	defer srv.close()
	if app.IsTTY() {
		fmt.Fprintln(app.Stderr, "ley mcp speaks MCP on stdin and stdout; an agent's MCP client starts it. Ctrl-C stops.")
	}
	if err := srv.server.Run(ctx, &mcp.StdioTransport{}); err != nil && ctx.Err() == nil {
		return err
	}
	// Interrupted, or the client closed stdin: both are the end of a
	// conversation, not a failure, so the exit is 0 as a live verb's is.
	return nil
}

// mcpServer is one `ley mcp` process: the MCP server, the long-lived
// connection that keeps this process present on the daemon, and the App the
// tools were started with.
type mcpServer struct {
	app    *App
	client *leyline.Client
	server *mcp.Server
	// presenceDone closes when the presence loop has stopped.
	presenceDone chan struct{}
	// recent is when this server last wrote to each capture (a tune, a listen, a snapshot),
	// by capture id. The daemon's don't-disturb grace refuses a sweep or a decode for a minute
	// after an interactive write and says "somebody was tuning"; when that somebody was this
	// server's own earlier call, the refusal protects no one and the tools skip it.
	recentMu sync.Mutex
	recent   map[string]time.Time
}

// touched records an interactive write of this server's own on a capture.
func (srv *mcpServer) touched(captureID string) {
	if captureID == "" {
		return
	}
	srv.recentMu.Lock()
	defer srv.recentMu.Unlock()
	if srv.recent == nil {
		srv.recent = map[string]time.Time{}
	}
	srv.recent[captureID] = time.Now()
}

// ownGraceSlack is how far apart this server's own write and the daemon's last-write stamp may
// be and still be the same write.
const ownGraceSlack = 3 * time.Second

// ownGrace reports whether the only thing in the way of a job on the device (any device, when
// deviceID is empty) is the daemon's grace after a write this server made itself: no channel is
// listening on the capture, no audio plays from it, and its last interactive write is one of
// ours to within ownGraceSlack. A job may then take the radio over without silencing anyone.
func (srv *mcpServer) ownGrace(state *leylinev1.GetStateResponse, deviceID string) bool {
	srv.recentMu.Lock()
	defer srv.recentMu.Unlock()
	for _, capture := range state.GetCaptures() {
		if deviceID != "" && capture.GetDeviceId() != deviceID {
			continue
		}
		last := capture.GetActivity().GetLastInteractiveWriteNs()
		if last == 0 || capture.GetActivity().GetLiveAudioSinks() > 0 {
			continue
		}
		listening := false
		for _, ch := range state.GetChannels() {
			if ch.GetCaptureId() == capture.GetCaptureId() && ch.GetState() == leylinev1.ChannelState_CHANNEL_ACTIVE {
				listening = true
			}
		}
		if listening {
			continue
		}
		mine, ok := srv.recent[capture.GetCaptureId()]
		if !ok {
			continue
		}
		if d := mine.Sub(time.Unix(0, last)); d < ownGraceSlack && d > -ownGraceSlack {
			return true
		}
	}
	return false
}

// ownGraceNote is what the text says when a job went ahead over this server's own grace.
const ownGraceNote = "the radio's grace after a tune was this server's own earlier call, so this went ahead without take_over.\n"

// mcpInstructions is what the agent reads about the server before its first
// call: the shape of the answers, what is not here yet, and the honesty rule.
const mcpInstructions = `Leyline is a software-defined radio: one daemon owns the radio, and these tools drive it the way the ley command does. Every tool's result is two text blocks: first what the ley verb would have said (the decisions a tune made, the scan table, the squelch that never opened), then the proto3 JSON mapping of the leyline.v1 messages (the same shapes 'ley <verb> --json' prints). Read the sentences; parse the JSON. A bare frequency number is MHz (146.52); add a unit to be exact (1010k, 146520000); presets such as noaa and calling are accepted where a frequency is.

A daemon restart shows in get_state: DaemonInfo.pid and startedAtNs change and the event sequence starts over; daemon_logs says why. A job started before a restart is gone with it, except a decode job started with keep, which comes back as the same job.

Only one thing can use the radio at a time. tune, scan, snapshot, start_decode_job and record refuse to move a radio somebody is listening on and say who; take_over: true insists. A channel tune makes, or a decode job started without keep, ends when this server exits; a recording does not -- it is written to disk and stays there.

The detector does not overclaim: a detection is a carrier that stood above the measured noise floor with the looks that saw it; nothing here names a protocol or a station unless a decoder decoded it. Audio and samples never cross this connection: record writes files on the daemon's machine and get_recording hands back their paths, for another tool to open. Not available yet: snapshot resources (ley:// store), transcripts of watched audio, signal identification, and external identity lookups.`

// newMCPServer dials the daemon, opens the presence stream and registers the
// tool table. A daemon that is not running is reported the way every verb
// reports it.
func newMCPServer(ctx context.Context, app *App) (*mcpServer, error) {
	c, err := app.dial(ctx)
	if err != nil {
		return nil, app.notRunning(err)
	}
	if _, err := c.State(ctx); err != nil {
		c.Close()
		return nil, app.notRunning(err)
	}
	srv := &mcpServer{app: app, client: c, presenceDone: make(chan struct{})}
	srv.server = mcp.NewServer(&mcp.Implementation{Name: "leyline", Title: "Leyline SDR", Version: Version},
		&mcp.ServerOptions{Instructions: mcpInstructions})
	srv.registerTools()
	srv.registerResources()
	go srv.keepPresence(ctx)
	return srv, nil
}

// close ends the presence stream and the connection behind it. Whatever this
// process owned on the daemon (channels tune made, decode jobs started
// without keep) is torn down by the daemon after its presence grace.
func (srv *mcpServer) close() {
	srv.client.Close()
	<-srv.presenceDone
}

// keepPresence holds a WatchEvents stream open for the life of the server.
// Presence is per client id and every session this process opens shares the
// process id (docs/dev/engine-internals.md, "Presence"), so a channel a
// tool made on its own short-lived session outlives that session as long as
// this stream is up: it ends when the agent's conversation does, which is
// invariant 8's "ephemeral unless explicitly kept" seen from an agent. A
// stream the daemon closes (a restart) is reopened, since the tools dial
// afresh and would otherwise keep working while their channels were torn down.
func (srv *mcpServer) keepPresence(ctx context.Context) {
	defer close(srv.presenceDone)
	for {
		events, errs, err := srv.client.Events(ctx, leyline.DaemonScope())
		if err == nil {
			// The mirror is not kept: every tool reads a fresh snapshot,
			// because two tools may run at once and a shared mirror would
			// need a lock the session was not written for.
			for range events { //nolint:revive // drained only to keep the stream, and so the presence, open
			}
			err = <-errs
		}
		if ctx.Err() != nil || errors.Is(err, context.Canceled) {
			return
		}
		if leyline.Code(err) == leyline.CodeCanceled {
			// Close() ended the connection: the server is shutting down.
			return
		}
		fmt.Fprintf(srv.app.Stderr, "the daemon closed the event stream (%v); reconnecting so channels made here stay up\n", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(time.Second):
		}
	}
}

// toolApp is the App a tool runs its session with: the same socket and
// environment, prose captured into buffers rather than written to this
// process's stderr, and plain styles, because the captured prose goes back
// to the agent as text and an SGR byte there is noise. What ley would have
// printed on stderr -- "using NFM: 2 m amateur band default", the squelch it
// measured, a retune -- is the list of decisions an agent needs.
func (srv *mcpServer) toolApp() (*App, *bytes.Buffer, *bytes.Buffer) {
	var out, errb bytes.Buffer
	app := &App{
		Stdout: &out, Stderr: &errb,
		Socket: srv.app.Socket, Executable: srv.app.Executable, LookupEnv: srv.app.LookupEnv,
		IsTTY: func() bool { return false }, IsErrTTY: func() bool { return false },
		TermWidth: func() int { return 0 }, TermHeight: func() int { return 0 }, ErrTermWidth: func() int { return 0 },
		Style: ui.Style{}, ErrStyle: ui.Style{}, styled: true,
		clientKind: srv.app.clientKind, clientLabel: srv.app.clientLabel, logFile: srv.app.logFile,
	}
	return app, &out, &errb
}

// toolError is the sentence a failed tool call carries: the daemon's own
// message with its stable code in brackets, the way `ley` prints it, minus
// the `ley:` prefix an agent has no use for.
func toolError(err error) error {
	if err == nil {
		return nil
	}
	return errors.New(withCode(err).Error())
}

// protoJSON is one message as the canonical proto3 JSON mapping, the shape
// `--json` prints and the shape every tool returns.
func protoJSON(m proto.Message) (json.RawMessage, error) {
	b, err := jsonMarshal.Marshal(m)
	if err != nil {
		return nil, err
	}
	return json.RawMessage(b), nil
}

// protoResult is the result of a tool whose answer is one message: the text
// beside the proto3 JSON, both as content.
func protoResult(m proto.Message, text string) (*mcp.CallToolResult, any, error) {
	raw, err := protoJSON(m)
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(text, raw), nil, nil
}

// jsonResult is every tool's result: the text a verb would have printed, then
// the JSON, as two text blocks, and no structuredContent. The MCP way would be
// the JSON as structuredContent with the text beside it, and that is how this
// server began; but Claude Code hands the model only structuredContent when
// there is one and drops the content blocks (anthropics/claude-code#55677),
// so all the text the tools returned -- the tune's decisions, the scan's
// table, the squelch that never opened -- reached no agent. Content is what
// every client shows, so everything goes there. text may be empty: a list an
// agent reads whole needs no sentence. The text keeps one trailing newline:
// Claude Code joins the blocks with nothing between, and a table's last row
// ran straight into the JSON's first brace.
func jsonResult(text string, raw json.RawMessage) *mcp.CallToolResult {
	res := &mcp.CallToolResult{}
	if text = strings.TrimRight(text, "\n"); text != "" {
		res.Content = append(res.Content, &mcp.TextContent{Text: text + "\n"})
	}
	res.Content = append(res.Content, &mcp.TextContent{Text: string(raw)})
	return res
}

// composite assembles a structured result out of several messages -- tune's
// capture, channel and sink; listen_summary's channel and transcript -- each
// under its own key and each still the proto3 JSON of its message. The keys
// are the envelope; the values follow the contract.
func composite(parts map[string]any) (json.RawMessage, error) {
	out := make(map[string]json.RawMessage, len(parts))
	for k, v := range parts {
		switch x := v.(type) {
		case nil:
			out[k] = json.RawMessage("null")
		case json.RawMessage:
			out[k] = x
		case proto.Message:
			raw, err := protoJSON(x)
			if err != nil {
				return nil, err
			}
			out[k] = raw
		default:
			b, err := json.Marshal(x)
			if err != nil {
				return nil, err
			}
			out[k] = b
		}
	}
	return json.Marshal(out)
}

// mcpNoArgs is the input of a tool that takes none: an object with no
// properties, which is what the MCP schema requires of every tool.
type mcpNoArgs struct{}

// boolPtr is for the SDK's tool annotations, which take pointers so that
// "unset" can be told from "false".
func boolPtr(b bool) *bool { return &b }
