// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/spf13/pflag"
	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
)

// workerSecret is distinctive, so a leak into the output is found by substring.
const workerSecret = "sk-WORKERCANARY-5678"

// provider is a scripted model API: it answers /v1/models with status and body, and keeps the
// headers of the last request.
type provider struct {
	mu      sync.Mutex
	headers http.Header
	path    string
}

func newProvider(t *testing.T, status int, body string) (*httptest.Server, *provider) {
	t.Helper()
	p := &provider{}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p.mu.Lock()
		p.headers, p.path = r.Header.Clone(), r.URL.Path
		p.mu.Unlock()
		w.WriteHeader(status)
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(srv.Close)
	return srv, p
}

// last is the path and headers of the last request.
func (p *provider) last() (string, http.Header) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.path, p.headers
}

// runWorker runs `ley worker check` with the key on stdin and returns the parsed line.
func runWorker(t *testing.T, sock, stdin string, args ...string) (checkResult, string, string, error) {
	t.Helper()
	out, errOut, err := runEnvIn(t, t.Context(), sock, nil, stdin, append([]string{"worker", "check"}, args...)...)
	var res checkResult
	if err == nil {
		if jerr := json.Unmarshal([]byte(out), &res); jerr != nil || strings.Count(out, "\n") != 1 {
			t.Fatalf("stdout is not one JSON line: %q (%v)", out, jerr)
		}
	}
	return res, out, errOut, err
}

// The status maps to the outcome, a refusal carries the provider's own words, and every answer
// is one line and exit 0.
func TestWorkerCheckOutcomes(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	cases := []struct {
		name, body, outcome, message string
		status                       int
	}{
		{"accepted", `{"data":[]}`, "accepted", "", 200},
		{"rejected", `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}`, "rejected", "invalid x-api-key", 401},
		{"forbidden", "account\n  suspended", "rejected", "account suspended", 403},
		{"server error", `{"error":{"message":"overloaded"}}`, "unavailable", "500 Internal Server Error: overloaded", 500},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			srv, _ := newProvider(t, tc.status, tc.body)
			res, out, errOut, err := runWorker(t, sock, workerSecret+"\n", "--provider", "anthropic", "--endpoint", srv.URL)
			if err != nil {
				t.Fatalf("exit %d: %v", exitCode(err), err)
			}
			if res.Outcome != tc.outcome || res.Message != tc.message {
				t.Errorf("got %+v, want %s %q", res, tc.outcome, tc.message)
			}
			if strings.Contains(out+errOut, "WORKERCANARY") {
				t.Errorf("the key was printed: %q %q", out, errOut)
			}
		})
	}
}

// Anthropic gets its own headers; OpenAI and an OpenAI-compatible server get a bearer token,
// and a base URL ending in /v1 is not given a second one. The check is counted in the ledger.
func TestWorkerCheckRequests(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	srv, p := newProvider(t, 200, `{}`)
	if _, _, _, err := runWorker(t, sock, workerSecret, "--provider", "anthropic", "--endpoint", srv.URL+"/"); err != nil {
		t.Fatal(err)
	}
	path, h := p.last()
	if path != "/v1/models" || h.Get("x-api-key") != workerSecret || h.Get("anthropic-version") != "2023-06-01" || h.Get("Authorization") != "" {
		t.Errorf("anthropic request: %s %v", path, h)
	}
	if _, _, _, err := runWorker(t, sock, workerSecret, "--provider", "ollama", "--endpoint", srv.URL+"/v1"); err != nil {
		t.Fatal(err)
	}
	path, h = p.last()
	if path != "/v1/models" || h.Get("Authorization") != "Bearer "+workerSecret || h.Get("x-api-key") != "" {
		t.Errorf("compatible request: %s %v", path, h)
	}
	usage, err := c.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{Feature: "check"})
	if err != nil {
		t.Fatal(err)
	}
	if len(usage.Lines) != 2 || usage.Lines[0].Model != "/v1/models" || usage.Lines[0].Requests != 1 {
		t.Errorf("ledger: %v", usage.Lines)
	}
}

// A provider the check does not know, and a server that does not answer, are unavailable: the
// line is printed, nothing is counted, and the exit status is 0.
func TestWorkerCheckUnavailable(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})
	res, _, _, err := runWorker(t, sock, workerSecret, "--provider", "deepgram")
	if err != nil || res.Outcome != "unavailable" || res.Message != "no check for provider deepgram" {
		t.Errorf("unknown provider: %+v %v", res, err)
	}
	srv, _ := newProvider(t, 200, "")
	srv.Close()
	res, _, _, err = runWorker(t, sock, workerSecret, "--provider", "openai", "--endpoint", srv.URL)
	if err != nil || res.Outcome != "unavailable" || res.Message == "" {
		t.Errorf("closed server: %+v %v", res, err)
	}
	usage, _ := c.Usage.GetUsage(t.Context(), &leylinev1.GetUsageRequest{})
	if len(usage.GetLines()) != 0 {
		t.Errorf("a call that reached no provider was counted: %v", usage.Lines)
	}
}

// With no daemon to report to, the outcome stands and stderr says the usage was not counted.
func TestWorkerCheckWithoutDaemon(t *testing.T) {
	t.Parallel()
	srv, _ := newProvider(t, 200, `{}`)
	res, _, errOut, err := runWorker(t, testutil.SocketPath(t, "gone.sock"), workerSecret, "--provider", "openai", "--endpoint", srv.URL)
	if err != nil || res.Outcome != "accepted" || !strings.Contains(errOut, "usage was not reported") {
		t.Errorf("%+v %v %q", res, err, errOut)
	}
}

// The key arrives on stdin and nowhere else: no flag takes it, and an empty stdin is a usage
// error that prints no line.
func TestWorkerKeyOnlyOnStdin(t *testing.T) {
	t.Parallel()
	cmd := newWorkerCheckCommand(&App{})
	cmd.Flags().VisitAll(func(f *pflag.Flag) {
		for _, word := range []string{"key", "secret", "token"} {
			if strings.Contains(f.Name, word) {
				t.Errorf("--%s would put the key on the command line", f.Name)
			}
		}
	})
	_, out, _, err := runWorker(t, testutil.SocketPath(t, "gone.sock"), "\n", "--provider", "anthropic")
	if exitCode(err) != ExitUsage || out != "" {
		t.Errorf("empty stdin: exit %d, stdout %q", exitCode(err), out)
	}
	_, out, _, err = runWorker(t, testutil.SocketPath(t, "gone.sock"), workerSecret)
	if exitCode(err) != ExitUsage || out != "" {
		t.Errorf("no --provider: exit %d, stdout %q", exitCode(err), out)
	}
}

// A gateway that echoes the request in its refusal does not get the key into the line: every
// occurrence is cut, so nothing downstream (last_check, listings, events) can carry it.
func TestWorkerCheckScrubsTheKey(t *testing.T) {
	t.Parallel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_, _ = w.Write([]byte(`{"error":{"message":"bad header ` + r.Header.Get("Authorization") + ` for key ` + workerSecret + `"}}`))
	}))
	t.Cleanup(srv.Close)
	res, out, errOut, err := runWorker(t, testutil.SocketPath(t, "gone.sock"), workerSecret, "--provider", "openai", "--endpoint", srv.URL)
	if err != nil || res.Outcome != "rejected" {
		t.Fatalf("%+v %v", res, err)
	}
	if strings.Contains(out+errOut, "WORKERCANARY") || res.Message != "bad header Bearer … for key …" {
		t.Errorf("the key reached the line: %q", out)
	}
}

// A redirect is not followed, so the key's header never reaches another host.
func TestWorkerCheckRefusesRedirects(t *testing.T) {
	t.Parallel()
	elsewhere, p := newProvider(t, 200, `{}`)
	srv := httptest.NewServer(http.RedirectHandler(elsewhere.URL+"/v1/models", http.StatusFound))
	t.Cleanup(srv.Close)
	res, _, _, err := runWorker(t, testutil.SocketPath(t, "gone.sock"), workerSecret, "--provider", "anthropic", "--endpoint", srv.URL)
	host := strings.TrimPrefix(elsewhere.URL, "http://")
	if err != nil || res.Outcome != "unavailable" || res.Message != "redirected to "+host {
		t.Errorf("%+v %v", res, err)
	}
	if path, _ := p.last(); path != "" {
		t.Errorf("the redirect was followed to %s", path)
	}
}

// `ley worker assistant` takes the key on stdin only, plays a scripted turn on the worker
// protocol, and exits 0 when stdin closes.
func TestWorkerAssistantCommand(t *testing.T) {
	t.Parallel()
	newWorkerAssistantCommand(&App{}).Flags().VisitAll(func(f *pflag.Flag) {
		for _, word := range []string{"key", "secret", "token"} {
			if strings.Contains(f.Name, word) {
				t.Errorf("--%s would put the key on the command line", f.Name)
			}
		}
	})
	sock, _ := harness(t, fakedaemon.Options{})
	script := filepath.Join(t.TempDir(), "script.jsonl")
	if err := os.WriteFile(script, []byte(`{"text": "hello"}`+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{
		"LEYLINE_KEY_ON_STDIN": "1", "LEY_ASSISTANT_SCRIPT": script,
		"LEYLINE_BOOKMARKS": filepath.Join(t.TempDir(), "b.json"),
	}
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	var errb bytes.Buffer
	app := &App{Stdout: outW, Stderr: &errb, Stdin: inR, LookupEnv: func(k string) (string, bool) { v, ok := env[k]; return v, ok }}
	done := make(chan error, 1)
	go func() {
		done <- Execute(t.Context(), app, []string{"--socket", sock, "worker", "assistant", "--conversation", "conv_cli"})
		_ = outW.Close()
	}()
	for _, m := range []proto.Message{
		&leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: workerSecret},
		&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_Start{Start: &leylinev1.WorkerStart{ConversationId: "conv_cli", Provider: "anthropic", Socket: sock}}},
		&leylinev1.WorkerEvent{Event: &leylinev1.WorkerEvent_User{User: &leylinev1.UserMessage{TurnId: "t1", Text: "hi"}}},
	} {
		if _, err := protodelim.MarshalTo(inW, m); err != nil {
			t.Fatal(err)
		}
	}
	br := bufio.NewReader(outR)
	for {
		var m leylinev1.WorkerMessage
		if err := protodelim.UnmarshalFrom(br, &m); err != nil {
			t.Fatalf("stdout ended before the turn did: %v; stderr: %s", err, errb.String())
		}
		if m.GetTurn().GetDone() {
			if m.GetTurn().GetText() != "hello" || m.GetTurn().GetTurnId() != "t2" {
				t.Errorf("turn: %v", m.GetTurn())
			}
			break
		}
	}
	_ = inW.Close()
	if err := <-done; err != nil {
		t.Errorf("exit after stdin closed: %v", err)
	}
	if strings.Contains(errb.String(), workerSecret) {
		t.Error("the key is on stderr")
	}
}

func TestOneLineCapped(t *testing.T) {
	long := strings.Repeat("a", 300)
	if got := oneLineCapped("x\n\ty  " + long); len([]rune(got)) != 200 || !strings.HasPrefix(got, "x y a") {
		t.Errorf("%q", got)
	}
}
