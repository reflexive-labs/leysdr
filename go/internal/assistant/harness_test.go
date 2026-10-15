// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
	"github.com/reflexive-labs/leysdr/go/internal/cli"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

const convID = "conv_test"

// worker is the loop running in process against a fake daemon, with pipes on both sides: the test
// plays the daemon's half of the worker protocol.
type worker struct {
	t      *testing.T
	daemon *fakedaemon.Daemon
	sock   string
	client *leyline.Client // another client, "the user's" own ley
	stdin  *io.PipeWriter
	msgs   chan *leylinev1.WorkerMessage
	// raw is every byte the worker wrote on stdout, so a test can search it for the key.
	raw    *lockedBuffer
	stderr *lockedBuffer
	done   chan error
	last   *leylinev1.Turn
	// bookmarksPath is the worker's bookmarks file.
	bookmarksPath string
}

// workerConfig is what a test varies.
type workerConfig struct {
	script []string // scripted model responses; nil uses the provider
	// setup runs on the daemon before the worker starts and returns the script, for a script that
	// names something setup made.
	setup     func(w *worker) []string
	daemon    fakedaemon.Options
	provider  string
	endpoint  string
	key       string // sent first on stdin when set, with LEYLINE_KEY_ON_STDIN=1
	viewTools []*leylinev1.ViewTool
	http      *http.Client
}

type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// startWorker starts a fake daemon and the worker on it, and sends the key and WorkerStart.
func startWorker(t *testing.T, cfg workerConfig) *worker {
	t.Helper()
	sock := testutil.SocketPath(t, "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	if cfg.daemon.PresenceGrace == 0 {
		cfg.daemon.PresenceGrace = 200 * time.Millisecond
	}
	d := fakedaemon.New(cfg.daemon)
	served := make(chan error, 1)
	go func() { served <- d.Serve(ctx, sock) }()
	c, err := leyline.Dial(ctx, sock, leyline.WithKind("cli"), leyline.WithLabel("ley tune"), leyline.WithClientID("cli_user"))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := c.State(ctx); err == nil {
			break
		} else if time.Now().After(deadline) {
			t.Fatalf("daemon never came up: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}

	w := &worker{
		t: t, daemon: d, sock: sock, client: c, msgs: make(chan *leylinev1.WorkerMessage, 256),
		raw: &lockedBuffer{}, stderr: &lockedBuffer{}, done: make(chan error, 1),
		bookmarksPath: filepath.Join(t.TempDir(), "bookmarks.json"),
	}
	if cfg.setup != nil {
		cfg.script = cfg.setup(w)
	}
	env := map[string]string{bookmarks.BookmarksEnv: w.bookmarksPath}
	if cfg.script != nil {
		path := filepath.Join(t.TempDir(), "script.jsonl")
		if err := os.WriteFile(path, []byte(strings.Join(cfg.script, "\n")+"\n"), 0o600); err != nil {
			t.Fatal(err)
		}
		env[assistant.ScriptEnv] = path
	}
	if cfg.key != "" {
		env[plugin.KeyOnStdinEnv] = "1"
	}
	lookup := func(k string) (string, bool) { v, ok := env[k]; return v, ok }

	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	w.stdin = inW
	go func() {
		err := assistant.Run(ctx, assistant.Options{
			Stdin: inR, Stdout: outW, Stderr: w.stderr, LookupEnv: lookup, Conversation: convID, HTTP: cfg.http,
			NewToolServer: func(ctx context.Context, socket string) (*mcp.Server, func(), error) {
				return cli.NewAssistantToolServer(ctx, socket, lookup, w.stderr)
			},
		})
		_ = outW.Close()
		w.done <- err
	}()
	go func() {
		defer close(w.msgs)
		br := bufio.NewReader(io.TeeReader(outR, w.raw))
		for {
			m := &leylinev1.WorkerMessage{}
			if err := protodelim.UnmarshalFrom(br, m); err != nil {
				return
			}
			w.msgs <- m
		}
	}()
	t.Cleanup(func() {
		_ = inW.Close()
		select {
		case <-w.done:
		case <-time.After(5 * time.Second):
			t.Error("the worker did not exit when stdin closed")
		}
		_ = c.Close()
		cancel()
		<-served
	})

	if cfg.key != "" {
		w.write(&leylinev1.SetCredentialRequest{Provider: cfg.provider, Secret: cfg.key})
	}
	provider := cfg.provider
	if provider == "" {
		provider = "anthropic"
	}
	w.send(&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_Start{Start: &leylinev1.WorkerStart{
		ConversationId: convID, Provider: provider, Model: "claude-test", Endpoint: cfg.endpoint,
		ViewTools: cfg.viewTools, Socket: sock,
	}}})
	return w
}

func (w *worker) write(m proto.Message) {
	w.t.Helper()
	if _, err := protodelim.MarshalTo(w.stdin, m); err != nil {
		w.t.Fatalf("write to the worker: %v", err)
	}
}

func (w *worker) send(ev *leylinev1.WorkerEvent) { w.t.Helper(); w.write(ev) }

// say starts a user turn.
func (w *worker) say(turnID, text string) {
	w.t.Helper()
	w.send(&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_User{User: &leylinev1.UserMessage{TurnId: turnID, Text: text}}})
}

func (w *worker) resolve(callID string, approve bool) {
	w.t.Helper()
	w.send(&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_Resolved{Resolved: &leylinev1.ActionResolved{CallId: callID, Approved: approve}}})
}

func (w *worker) stop() {
	w.t.Helper()
	w.send(&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_Stop{Stop: &leylinev1.WorkerStop{}}})
}

// next is the next message the worker writes.
func (w *worker) next() *leylinev1.WorkerMessage {
	w.t.Helper()
	select {
	case m, ok := <-w.msgs:
		if !ok {
			w.t.Fatalf("the worker's stdout closed; stderr:\n%s", w.stderr.String())
		}
		if m.GetTurn() != nil {
			w.last = m.GetTurn()
		}
		return m
	case <-time.After(15 * time.Second):
		w.t.Fatalf("no message from the worker; stderr:\n%s", w.stderr.String())
	}
	return nil
}

// until reads turns until one satisfies ok, and returns it.
func (w *worker) until(ok func(*leylinev1.Turn) bool) *leylinev1.Turn {
	w.t.Helper()
	for {
		m := w.next()
		if f := m.GetFailure(); f != nil {
			w.t.Fatalf("the worker failed: %v", f.GetError())
		}
		if turn := m.GetTurn(); turn != nil && ok(turn) {
			return turn
		}
	}
}

// doneTurn waits for the turn to end.
func (w *worker) doneTurn() *leylinev1.Turn {
	w.t.Helper()
	return w.until(func(t *leylinev1.Turn) bool { return t.GetDone() })
}

// asking waits for the turn to wait on the user, and returns the call it waits on.
func (w *worker) asking() *leylinev1.ToolCall {
	w.t.Helper()
	turn := w.until(func(t *leylinev1.Turn) bool {
		if t.GetDone() {
			w.t.Fatalf("the turn ended without asking: %v", t)
		}
		return lastCall(t).GetState() == leylinev1.ToolCallState_TOOL_CALL_AWAITING_APPROVAL
	})
	return lastCall(turn)
}

func lastCall(t *leylinev1.Turn) *leylinev1.ToolCall {
	if n := len(t.GetTools()); n > 0 {
		return t.GetTools()[n-1]
	}
	return nil
}

func callNamed(t *leylinev1.Turn, tool string) *leylinev1.ToolCall {
	for _, c := range t.GetTools() {
		if c.GetTool() == tool {
			return c
		}
	}
	return nil
}

// state is the daemon's state as the user's client reads it.
func (w *worker) state() *leylinev1.GetStateResponse {
	w.t.Helper()
	st, err := w.client.State(w.t.Context())
	if err != nil {
		w.t.Fatal(err)
	}
	return st
}

// listening puts another client's channel on the radio at 146.52 MHz.
func (w *worker) listening() *leylinev1.Channel {
	w.t.Helper()
	ctx := w.t.Context()
	st := w.state()
	capture, err := w.client.Control.CreateCapture(ctx, &leylinev1.CreateCaptureRequest{DeviceId: st.GetDevices()[0].GetDeviceId(), CenterHz: 146_520_000})
	if err != nil {
		w.t.Fatal(err)
	}
	ch, err := w.client.Control.CreateChannel(ctx, &leylinev1.CreateChannelRequest{CaptureId: capture.GetCaptureId(), Mode: leylinev1.DemodMode_NFM, BandwidthHz: 12_500, Persistent: true})
	if err != nil {
		w.t.Fatal(err)
	}
	return ch
}

// jobs is every job the daemon lists.
func (w *worker) jobs() []*leylinev1.Job {
	w.t.Helper()
	jobs, err := w.client.ListJobs(w.t.Context())
	if err != nil {
		w.t.Fatal(err)
	}
	return jobs
}

// hasRecording reports whether the daemon still has the recording.
func (w *worker) hasRecording(jobID string) bool {
	_, err := w.client.Resources.GetResource(w.t.Context(), &leylinev1.ResourceRef{Uri: "ley://recordings/" + jobID})
	return err == nil
}

// bookmarks is the bookmarks file as the worker's tools left it.
func (w *worker) bookmarks() string {
	raw, _ := os.ReadFile(w.bookmarksPath)
	return string(raw)
}

// line is one scripted response.
func line(v map[string]any) string {
	b, err := json.Marshal(v)
	if err != nil {
		panic(err)
	}
	return string(b)
}

func toolLine(tool string, args map[string]any) string {
	return line(map[string]any{"tool": tool, "args": args})
}
