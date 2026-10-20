// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"bytes"
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The assistant as the agent: `ley ask --yes --json` on the eval daemon, which starts the
// assistant's worker with the key the runner added, the worker calls the model and the same
// tools `ley mcp` serves, and the Conversation lines are the log (conversation.go).
//
// --yes starts the conversation in AUTO, where every call the gate would ask about runs, because
// the eval grades what the model does and not what the operator would have refused: an injected
// write the gate stopped would leave no event for no_write to find. The transcript still shows
// each such call, by the reason the worker keeps on it.

// KeyEnv is the environment variable the runner reads the assistant's provider key from. The
// key goes to `ley ai add` on stdin and nowhere else: never an argument, a file or a log line.
const KeyEnv = "LEYEVAL_KEY"

// ScriptEnv is what the daemon's environment names the scripted model's file with
// (go/internal/assistant, ScriptEnv). The worker inherits it from the daemon.
const ScriptEnv = "LEY_ASSISTANT_SCRIPT"

// DefaultAssistantModel is the model the assistant calls when --model names none.
const DefaultAssistantModel = "claude-sonnet-5-5"

// scriptedProvider is the provider a scripted run files its placeholder key under: not a real
// provider, so on a Mac, where the daemon keeps keys in the login keychain whatever its data
// directory, the placeholder never replaces a real provider's key. A provider the default table
// does not list serves the assistant only at its key's endpoint (pkg/leyline, FeatureRefusal), so
// the key is added at scriptedEndpoint's address; the scripted worker never calls it.
const scriptedProvider = "leyeval-scripted"

// scriptedEndpoint serves, on this machine only, the one call `ley ai add` makes with a key at an
// endpoint, the models list, so the check is accepted and nothing leaves the machine. stop closes
// it.
func scriptedEndpoint() (url string, stop func(), err error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", nil, err
	}
	srv := &http.Server{Handler: http.HandlerFunc(serveScriptedModels), ReadHeaderTimeout: 5 * time.Second}
	go func() { _ = srv.Serve(ln) }()
	return "http://" + ln.Addr().String() + "/v1", func() { _ = srv.Close() }, nil
}

// serveScriptedModels answers GET /v1/models with 200 and an empty list, which the key check
// (`ley worker check`, checkKey) takes as accepted, and anything else with 404.
func serveScriptedModels(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet || r.URL.Path != "/v1/models" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"data":[]}`))
}

// assistantSkip is why assistant mode cannot run with this Env, or "".
func (env Env) assistantSkip() string {
	if env.Script == "" && env.Key == "" {
		return "assistant mode needs a key in $" + KeyEnv + " or a script with --scripted"
	}
	return ""
}

// Tokens is what the daemon's ledger holds for a conversation: the provider's own counts, summed
// over its days.
type Tokens struct {
	Requests         uint64 `json:"requests"`
	InputTokens      uint64 `json:"input_tokens"`
	OutputTokens     uint64 `json:"output_tokens"`
	CacheReadTokens  uint64 `json:"cache_read_tokens"`
	CacheWriteTokens uint64 `json:"cache_write_tokens"`
}

// runAssistant adds the key, chooses the model, asks, and reads the conversation's tokens back
// from the ledger. It returns the log, the raw `ley ask --json` output, and the tokens (nil when
// the ledger could not be read).
func runAssistant(ctx context.Context, env Env, d *daemon, dir, prompt string) (*Log, []byte, *Tokens, error) {
	provider, key := "anthropic", env.Key
	if env.Script != "" {
		provider, key = scriptedProvider, "scripted"
	}
	model := env.Model
	if model == "" {
		model = DefaultAssistantModel
	}
	if runtime.GOOS == "darwin" && env.Script == "" {
		env.Log("on macOS a daemon that does not honour LEYLINE_SECRETS=file keeps keys in the login keychain: $%s replaces the %s key the app uses, and the run removes it at the end", KeyEnv, provider)
	}
	add := []string{"ai", "add", provider}
	if env.Script != "" {
		endpoint, stop, err := scriptedEndpoint()
		if err != nil {
			return nil, nil, nil, fmt.Errorf("serve the scripted provider's endpoint: %w", err)
		}
		defer stop()
		add = append(add, "--endpoint", endpoint)
	}
	if _, _, err := d.ley(ctx, dir, key+"\n", add...); err != nil {
		return nil, nil, nil, fmt.Errorf("ley ai add %s: %s", provider, strings.ReplaceAll(err.Error(), key, "…"))
	}
	// Whatever happens next, the key goes when the run does: a daemon that still writes the
	// keychain would otherwise leave it there.
	defer removeKey(env, d, dir, provider)
	if _, _, err := d.ley(ctx, dir, "", "ai", "use", "assistant", provider, model); err != nil {
		return nil, nil, nil, fmt.Errorf("ley ai use: %w", err)
	}
	started := time.Now()
	stdout, stderr, askErr := d.ley(ctx, dir, "", "ask", "--yes", "--json", prompt)
	if len(stderr) > 0 {
		_ = os.WriteFile(filepath.Join(dir, "agent-stderr.txt"), stderr, 0o644)
	}
	log, err := ParseStream(bytes.NewReader(stdout))
	if err != nil {
		return log, stdout, nil, err
	}
	log.DurationMs = time.Since(started).Milliseconds()
	if askErr != nil && log.ConversationID == "" {
		return log, stdout, nil, fmt.Errorf("ley ask: %w", askErr)
	}
	tokens, err := conversationTokens(ctx, d, dir, log.ConversationID)
	if err != nil {
		env.Log("reading the ledger: %v", err)
	}
	return log, stdout, tokens, nil
}

// removeKey is `ley ai remove` on the run's daemon, on a context of its own, since the run's may
// have timed out.
func removeKey(env Env, d *daemon, dir, provider string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if _, _, err := d.ley(ctx, dir, "", "ai", "remove", provider); err != nil {
		env.Log("removing the %s key: %v", provider, err)
	}
}

// conversationTokens sums the ledger's assistant lines for one conversation.
func conversationTokens(ctx context.Context, d *daemon, dir, convID string) (*Tokens, error) {
	out, _, err := d.ley(ctx, dir, "", "ai", "usage", "--json", "--since", "0")
	if err != nil {
		return nil, err
	}
	resp := &leylinev1.GetUsageResponse{}
	if err := (protojson.UnmarshalOptions{DiscardUnknown: true}).Unmarshal(out, resp); err != nil {
		return nil, fmt.Errorf("ley ai usage --json: %w", err)
	}
	t := &Tokens{}
	for _, l := range resp.GetLines() {
		if l.GetFeature() != "assistant" || l.GetScopeId() != convID {
			continue
		}
		t.Requests += l.GetRequests()
		t.InputTokens += l.GetInputTokens()
		t.OutputTokens += l.GetOutputTokens()
		t.CacheReadTokens += l.GetCacheReadTokens()
		t.CacheWriteTokens += l.GetCacheWriteTokens()
	}
	return t, nil
}

// ley runs a `ley` verb against the eval daemon in dir, with stdin, and returns its stdout and
// stderr. A failure's error carries stderr, which never holds a key (`ley ai add` prints only
// the last four characters).
func (d *daemon) ley(ctx context.Context, dir, stdin string, args ...string) ([]byte, []byte, error) {
	cmd := exec.CommandContext(ctx, d.env.Ley, append([]string{"--socket", d.socket}, args...)...)
	cmd.Dir = dir
	cmd.Stdin = strings.NewReader(stdin)
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		return stdout.Bytes(), stderr.Bytes(), fmt.Errorf("%w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return stdout.Bytes(), stderr.Bytes(), nil
}
