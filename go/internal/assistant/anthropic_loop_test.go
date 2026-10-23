// SPDX-License-Identifier: Apache-2.0

package assistant_test

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

const loopKey = "sk-ant-loop-SECRET-4242"

// The worker on the Anthropic model: the key arrives on stdin and goes out in the header only;
// the tool results go back in the order the calls were made; a rejected key fails the
// conversation in the provider's words with the key cut out, and the key is never on the
// worker's stdout or stderr.
func TestAnthropicThroughTheLoop(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var bodies []string
	step := 0
	api := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		bodies = append(bodies, string(body))
		if r.Header.Get("x-api-key") != loopKey {
			t.Errorf("x-api-key %q", r.Header.Get("x-api-key"))
		}
		step++
		switch step {
		case 1:
			_, _ = io.WriteString(w, `{"content":[{"type":"text","text":"Checking."},
				{"type":"tool_use","id":"toolu_1","name":"list_devices","input":{}},
				{"type":"tool_use","id":"toolu_2","name":"get_state","input":{}}],
				"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":5}}`)
		case 2:
			_, _ = io.WriteString(w, `{"content":[{"type":"text","text":"One radio, idle."}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":4}}`)
		default:
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = io.WriteString(w, `{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key: `+loopKey+`"}}`)
		}
	}))
	t.Cleanup(api.Close)

	w := startWorker(t, workerConfig{provider: "anthropic", endpoint: api.URL, key: loopKey})
	w.say("t1", "what radios are there?")
	turn := w.doneTurn()
	if turn.GetText() != "Checking.\n\nOne radio, idle." || len(turn.GetTools()) != 2 {
		t.Errorf("turn: %v", turn)
	}

	mu.Lock()
	var second struct {
		Messages []struct {
			Role    string
			Content []struct {
				Type      string
				ToolUseID string `json:"tool_use_id"`
				Content   string
			}
		}
	}
	if err := json.Unmarshal([]byte(bodies[1]), &second); err != nil {
		t.Fatal(err)
	}
	mu.Unlock()
	last := second.Messages[len(second.Messages)-1]
	if last.Role != "user" || len(last.Content) != 2 || last.Content[0].ToolUseID != "toolu_1" || last.Content[1].ToolUseID != "toolu_2" ||
		last.Content[0].Type != "tool_result" || !strings.Contains(last.Content[0].Content, "devices") {
		t.Errorf("the results message: %+v", last)
	}

	w.say("t2", "again")
	var failure *leylinev1.WorkerFailure
	for failure == nil {
		failure = w.next().GetFailure()
	}
	if failure.GetError().GetCode() != leyline.CodeCredentialRejected || !strings.Contains(failure.GetError().GetMessage(), "invalid x-api-key") {
		t.Errorf("failure: %v", failure.GetError())
	}
	if err := <-w.done; err == nil {
		t.Error("the worker exited 0 after a failure")
	}
	w.done <- nil // for the cleanup
	for where, text := range map[string]string{"stdout": w.raw.String(), "stderr": w.stderr.String()} {
		if strings.Contains(text, loopKey) {
			t.Errorf("the key is on the worker's %s", where)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	for _, b := range bodies {
		if strings.Contains(b, loopKey) {
			t.Error("the key is in a request body")
		}
	}
}

// Without a key the Anthropic model is not started, and the conversation fails saying how to add
// one.
func TestAnthropicWithoutAKey(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{provider: "anthropic", endpoint: "http://127.0.0.1:9"})
	m := w.next()
	if m.GetFailure().GetError().GetCode() != leyline.CodeCredentialMissing || !strings.Contains(m.GetFailure().GetError().GetMessage(), "ley ai add anthropic") {
		t.Errorf("got %v", m)
	}
	<-w.done
	w.done <- nil
}

// A provider the worker cannot call, one it has no API for and no endpoint, fails at start.
func TestUnknownProvider(t *testing.T) {
	t.Parallel()
	w := startWorker(t, workerConfig{provider: "mistral", key: "k"})
	m := w.next()
	if m.GetFailure().GetError().GetCode() != leyline.CodeProviderUnavailable {
		t.Errorf("got %v", m)
	}
	<-w.done
	w.done <- nil
}
