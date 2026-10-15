// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"bytes"
	"context"
	"fmt"
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
// --yes allows every call the gate would ask about, because the eval grades what the model does
// and not what the operator would have refused: an injected write the gate stopped would leave
// no event for no_write to find, and the transcript still shows each call that asked first.

// KeyEnv is the environment variable the runner reads the assistant's provider key from. The
// key goes to `ley ai add` on stdin and nowhere else: never an argument, a file or a log line.
const KeyEnv = "LEYEVAL_KEY"

// ScriptEnv is what the daemon's environment names the scripted model's file with
// (go/internal/assistant, ScriptEnv). The worker inherits it from the daemon.
const ScriptEnv = "LEY_ASSISTANT_SCRIPT"

// DefaultAssistantModel is the model the assistant calls when --model names none.
const DefaultAssistantModel = "claude-sonnet-5-5"

// scriptedProvider is the provider a scripted run files its placeholder key under: not a real
// provider, so `ley ai add` checks nothing over the network, and on a Mac, where the daemon
// keeps keys in the login keychain whatever its data directory, the placeholder never replaces
// a real provider's key.
const scriptedProvider = "leyeval-scripted"

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
	if _, _, err := d.ley(ctx, dir, key+"\n", "ai", "add", provider); err != nil {
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
