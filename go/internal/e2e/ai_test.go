// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The keys and the ledger end to end: the real daemon holds a key `ley ai add` gave it, runs a
// scripted `ley` as its check worker, and keeps the usage a real `ley worker check` reports.
// The keys carry aiCanary, so a leak into any output, file or event is found by substring.
const (
	aiCanary       = "SECRETMARKER7e1"
	anthropicKey   = "sk-ant-test-" + aiCanary + "-0042"
	openaiKey      = "sk-oa-test-" + aiCanary + "-0099"
	rejectedReason = "invalid x-api-key"
)

// Scripted check workers. The daemon runs `<ley> worker check --provider P` with the key on
// stdin; the accepted one also proves the key it was handed is one of the test's.
var aiWorkerScripts = map[string]string{
	"accepted": `#!/bin/sh
read -r key
case "$key" in
  "` + anthropicKey + `"|"` + openaiKey + `") echo '{"outcome":"accepted","message":""}' ;;
  *) echo '{"outcome":"rejected","message":"the worker was handed a key the test never gave"}' ;;
esac
`,
	"rejected": `#!/bin/sh
read -r key
echo '{"outcome":"rejected","message":"` + rejectedReason + `"}'
`,
	"failing": `#!/bin/sh
read -r key
exit 1
`,
}

// aiRig is one daemon with its data directory, store and log file, the scripted worker it runs,
// and a transcript of everything every `ley` of the test wrote.
type aiRig struct {
	*env
	t                  *testing.T
	dir, data, store   string
	logFile, workerBin string
	daemon             *exec.Cmd
	daemonArgs         []string

	mu         sync.Mutex
	transcript bytes.Buffer
}

// newAIRig starts a daemon whose worker is ley (a path the test controls, or one that does not
// exist).
func newAIRig(t *testing.T, ley string) *aiRig {
	t.Helper()
	dir := t.TempDir()
	r := &aiRig{
		t: t, dir: dir, data: filepath.Join(dir, "data"), store: filepath.Join(dir, "store"),
		logFile: filepath.Join(dir, "leylined.log"), workerBin: ley,
	}
	r.daemonArgs = []string{"--data", r.data, "--store", r.store, "--ley", ley, "--log-file", r.logFile}
	t.Cleanup(func() {
		if t.Failed() {
			b, _ := os.ReadFile(r.logFile)
			t.Logf("leylined log file:\n%s\nley transcript:\n%s", b, r.transcript.String())
		}
	})
	r.start()
	return r
}

func (r *aiRig) start() {
	r.env, r.daemon = setup(r.t, r.daemonArgs...)
}

// restart stops the daemon as launchd would and starts another on the same data and store.
func (r *aiRig) restart() {
	r.t.Helper()
	_ = r.daemon.Process.Signal(syscall.SIGTERM)
	done := make(chan struct{})
	go func() { _ = r.daemon.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(10 * time.Second):
		_ = r.daemon.Process.Kill()
		<-done
	}
	r.start()
}

// useWorker points the daemon's --ley at one of aiWorkerScripts: --ley names a symlink, so the
// outcome can change without a restart.
func (r *aiRig) useWorker(outcome string) {
	r.t.Helper()
	script := filepath.Join(r.dir, "ley-"+outcome)
	if _, err := os.Stat(script); err != nil {
		if err := os.WriteFile(script, []byte(aiWorkerScripts[outcome]), 0o755); err != nil {
			r.t.Fatal(err)
		}
	}
	_ = os.Remove(r.workerBin)
	if err := os.Symlink(script, r.workerBin); err != nil {
		r.t.Fatal(err)
	}
}

// call runs one ley verb with stdin, records both streams in the transcript, and returns them with
// the exit status.
func (r *aiRig) call(stdin string, extraEnv []string, args ...string) (stdout, stderr string, code int) {
	r.t.Helper()
	cmd := exec.Command(r.ley, append([]string{"--socket", r.socket}, args...)...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = append(os.Environ(), extraEnv...)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	var exitErr *exec.ExitError
	switch {
	case err == nil:
	case errors.As(err, &exitErr):
		code = exitErr.ExitCode()
	default:
		r.t.Fatalf("ley %v: %v", args, err)
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	r.transcript.WriteString("$ ley " + strings.Join(args, " ") + "\n" + out.String() + errOut.String())
	// Off a terminal ley writes the ellipsis before a key's last four as "..."; on one, as "…".
	return out.String(), strings.ReplaceAll(errOut.String(), "…", "..."), code
}

// mustLey is call that fails the test on a non-zero exit.
func (r *aiRig) mustLey(stdin string, args ...string) (stdout, stderr string) {
	r.t.Helper()
	out, errOut, code := r.call(stdin, nil, args...)
	if code != 0 {
		r.t.Fatalf("ley %s: exit %d\nstdout: %s\nstderr: %s", strings.Join(args, " "), code, out, errOut)
	}
	return out, errOut
}

func (r *aiRig) aiState() map[string]any {
	r.t.Helper()
	out, _ := r.mustLey("", "ai", "--json")
	return parseJSON(r.t, out)
}

// credential is the provider's entry in `ley ai --json`, or nil.
func (r *aiRig) credential(provider string) map[string]any {
	r.t.Helper()
	for _, c := range list(r.aiState(), "credentials") {
		if m := c.(map[string]any); m["provider"] == provider {
			return m
		}
	}
	return nil
}

func lastCheck(cred map[string]any) map[string]any {
	m, _ := cred["lastCheck"].(map[string]any)
	return m
}

// assertNoCanary looks for the key's text everywhere it must not be: what every `ley` printed,
// the daemon's log, `ley ai --json`, `ley state --json`, and every file under the data directory
// and the store but the key file, which must hold it (so the test knows it read the right file).
func (r *aiRig) assertNoCanary() {
	r.t.Helper()
	r.aiState()
	r.mustLey("", "state", "--json")
	r.mu.Lock()
	transcript := r.transcript.String()
	r.mu.Unlock()
	if strings.Contains(transcript, aiCanary) {
		r.t.Errorf("a ley printed the key:\n%s", transcript)
	}
	keyFile := filepath.Join(r.data, "secrets", "credentials.json")
	for _, root := range []string{r.data, r.store, r.logFile} {
		if _, err := os.Stat(root); os.IsNotExist(err) && root == r.store {
			continue // the store is made at the first ledger report
		}
		err := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err != nil || d.IsDir() || path == keyFile {
				return err
			}
			b, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			if bytes.Contains(b, []byte(aiCanary)) {
				r.t.Errorf("%s holds the key", path)
			}
			return nil
		})
		if err != nil {
			r.t.Errorf("walk %s: %v", root, err)
		}
	}
	if b, err := os.ReadFile(filepath.Join(r.data, "ai.json")); err != nil || len(b) == 0 {
		r.t.Errorf("the daemon wrote no ai.json in --data (%v), so the listing was not checked", err)
	}
	if b, err := os.ReadFile(keyFile); err != nil || !bytes.Contains(b, []byte(aiCanary)) {
		r.t.Errorf("%s does not hold the key (%v), so the test read the wrong place", keyFile, err)
	}
	for path, want := range map[string]os.FileMode{keyFile: 0o600, filepath.Dir(keyFile): 0o700} {
		if fi, err := os.Stat(path); err != nil || fi.Mode().Perm() != want {
			r.t.Errorf("%s: mode %v (%v), want %v", path, fi.Mode().Perm(), err, want)
		}
	}
}

// eventLog collects every event a WatchEvents subscriber from seq 0 receives.
type eventLog struct {
	mu     sync.Mutex
	events []*leyline.Event
}

func (l *eventLog) snapshot() []*leyline.Event {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]*leyline.Event(nil), l.events...)
}

// watchEvents subscribes with the Go client from seq 0 and collects until the test ends.
func (r *aiRig) watchEvents() *eventLog {
	r.t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	c, err := leyline.Dial(ctx, r.socket, leyline.WithLabel("e2e"))
	if err != nil {
		r.t.Fatal(err)
	}
	evs, _, err := c.Events(ctx, leyline.ScopeSince(nil, 0))
	if err != nil {
		r.t.Fatal(err)
	}
	l := &eventLog{}
	done := make(chan struct{})
	go func() {
		defer close(done)
		for ev := range evs {
			l.mu.Lock()
			l.events = append(l.events, ev)
			l.mu.Unlock()
		}
	}()
	r.t.Cleanup(func() { cancel(); <-done; c.Close() })
	return l
}

// waitAI waits for an Event.ai that what accepts.
func (l *eventLog) waitAI(t *testing.T, desc string, what func(*leylinev1.AIState) bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for {
		for _, ev := range l.snapshot() {
			if ai := ev.GetAi(); ai != nil && what(ai) {
				return
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("no Event.ai with %s among %d events", desc, len(l.snapshot()))
		}
		time.Sleep(50 * time.Millisecond)
	}
}

func TestAIKeysAgainstRealDaemon(t *testing.T) {
	r := newAIRig(t, filepath.Join(t.TempDir(), "ley"))
	r.useWorker("accepted")

	// A key is stored and checked, and a second client sees its description and never its text.
	out, errOut := r.mustLey(anthropicKey+"\n", "ai", "add", "anthropic", "--label", "work")
	if !strings.Contains(errOut, "anthropic key ...0042 added; the provider accepted it") {
		t.Errorf("ley ai add said %q", errOut)
	}
	if out != "" {
		t.Errorf("ley ai add without --json printed on stdout: %q", out)
	}
	cred := r.credential("anthropic")
	if cred == nil || cred["lastFour"] != "0042" || cred["label"] != "work" || cred["addedAtNs"] == nil ||
		cred["addedAtNs"] == "0" || lastCheck(cred)["outcome"] != "ACCEPTED" {
		t.Fatalf("ley ai --json shows %v", cred)
	}

	// The key reached the event plane as a description: a subscriber from seq 0 is sent it.
	events := r.watchEvents()
	events.waitAI(t, "the anthropic key", func(ai *leylinev1.AIState) bool {
		for _, c := range ai.GetCredentials() {
			if c.GetProvider() == "anthropic" && c.GetLastFour() == "0042" && c.GetLabel() == "work" {
				return true
			}
		}
		return false
	})

	// The provider refuses the key: check says so in the provider's words and exits 1.
	r.useWorker("rejected")
	_, errOut, code := r.call("", nil, "ai", "check", "anthropic")
	if code != 1 || !strings.Contains(errOut, "rejected") || !strings.Contains(errOut, rejectedReason) ||
		!strings.Contains(errOut, "Paste a working key with: ley ai add anthropic") {
		t.Errorf("ley ai check (rejected): exit %d, %q", code, errOut)
	}
	if strings.Contains(errOut, "[CREDENTIAL_REJECTED]") {
		t.Errorf("a refused key is a check outcome, not an error code: %q", errOut)
	}
	if chk := lastCheck(r.credential("anthropic")); chk["outcome"] != "REJECTED" || chk["message"] != rejectedReason {
		t.Errorf("ley ai --json after a refusal: %v", chk)
	}

	// The worker dies without a word: the check could not run, which says nothing about the key.
	r.useWorker("failing")
	_, errOut, code = r.call("", nil, "ai", "check", "anthropic")
	if code != 1 || !strings.Contains(errOut, "could not check the anthropic key ...0042") ||
		!strings.Contains(errOut, "Run: ley ai check anthropic") {
		t.Errorf("ley ai check (failing worker): exit %d, %q", code, errOut)
	}
	if chk := lastCheck(r.credential("anthropic")); chk["outcome"] != "UNAVAILABLE" || chk["message"] == "" {
		t.Errorf("ley ai --json after a failed worker: %v", chk)
	}

	// A model chosen for a feature is daemon state every client sees.
	r.mustLey("", "ai", "use", "assistant", "anthropic", "claude-sonnet-5-5")
	features := list(r.aiState(), "features")
	if len(features) != 1 {
		t.Fatalf("ley ai --json features: %v", features)
	}
	if fm := features[0].(map[string]any); fm["feature"] != "assistant" || fm["provider"] != "anthropic" || fm["model"] != "claude-sonnet-5-5" {
		t.Errorf("ley ai --json feature: %v", fm)
	}

	r.assertNoCanary()

	// Removing the key leaves no credential; removing it again names the command that adds one.
	r.mustLey("", "ai", "remove", "anthropic")
	if creds := list(r.aiState(), "credentials"); len(creds) != 0 {
		t.Errorf("ley ai --json after remove: %v", creds)
	}
	_, errOut, code = r.call("", nil, "ai", "remove", "anthropic")
	if code != 1 || !strings.Contains(errOut, "[CREDENTIAL_MISSING]") || !strings.Contains(errOut, "ley ai add anthropic") {
		t.Errorf("second ley ai remove: exit %d, %q", code, errOut)
	}

	// No event the daemon sent, the replay and the live ones after it, carried the key.
	events.waitAI(t, "no keys", func(ai *leylinev1.AIState) bool { return len(ai.GetCredentials()) == 0 })
	for _, ev := range events.snapshot() {
		if b, _ := protojson.Marshal(ev); bytes.Contains(b, []byte(aiCanary)) {
			t.Errorf("an event carries the key: %s", b)
		}
	}
	r.mu.Lock()
	leaked := strings.Contains(r.transcript.String(), aiCanary)
	r.mu.Unlock()
	if leaked {
		t.Errorf("a ley printed the key")
	}
}

// A daemon whose `ley` does not exist stores the key and reports every check as one that could
// not run, never as an RPC error.
func TestAIKeyWithNoWorker(t *testing.T) {
	r := newAIRig(t, "/nonexistent/ley")
	_, errOut := r.mustLey(anthropicKey+"\n", "ai", "add", "anthropic")
	if !strings.Contains(errOut, "added; the check could not run") {
		t.Errorf("ley ai add with no worker said %q", errOut)
	}
	_, errOut, code := r.call("", nil, "ai", "check", "anthropic")
	if code != 1 || !strings.Contains(errOut, "could not check the anthropic key ...0042") {
		t.Errorf("ley ai check with no worker: exit %d, %q", code, errOut)
	}
	if chk := lastCheck(r.credential("anthropic")); chk["outcome"] != "UNAVAILABLE" || chk["message"] == "" {
		t.Errorf("ley ai --json with no worker: %v", chk)
	}
	r.assertNoCanary()
}

// The ledger: a real `ley worker check`, run by the test against an httptest provider, reports
// one request per check; the daemon folds them into one line per day and keeps it across a
// restart, with the key's description.
func TestAIUsageAgainstRealDaemon(t *testing.T) {
	r := newAIRig(t, filepath.Join(t.TempDir(), "ley"))
	r.useWorker("accepted")
	r.mustLey(openaiKey+"\n", "ai", "add", "openai", "--label", "personal")
	if cred := r.credential("openai"); cred["lastUsedAtNs"] != nil {
		t.Fatalf("a scripted check reports no usage, yet the key was used: %v", cred)
	}

	provider := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		if req.URL.Path != "/v1/models" || req.Header.Get("Authorization") != "Bearer "+openaiKey {
			http.Error(w, `{"error":{"message":"wrong request"}}`, http.StatusUnauthorized)
			return
		}
		_, _ = w.Write([]byte(`{"data":[]}`))
	}))
	defer provider.Close()

	dayBefore := time.Now().UTC().Format(time.DateOnly)
	for i := 1; i <= 2; i++ {
		out, errOut, code := r.call(openaiKey+"\n", []string{leyline.SocketEnv + "=" + r.socket},
			"worker", "check", "--provider", "openai", "--endpoint", provider.URL)
		if code != 0 || strings.TrimSpace(out) != `{"outcome":"accepted","message":""}` || errOut != "" {
			t.Fatalf("ley worker check #%d: exit %d, stdout %q, stderr %q", i, code, out, errOut)
		}
		assertUsageLine(t, r, dayBefore, i)
	}
	if cred := r.credential("openai"); cred["lastUsedAtNs"] == nil || cred["lastUsedAtNs"] == "0" {
		t.Errorf("the reported check did not mark the key used: %v", cred)
	}

	// Without --json: the header on stderr says what a day is, the table is on stdout.
	out, errOut := r.mustLey("", "ai", "usage")
	if !strings.Contains(errOut, "Days are UTC") || !strings.Contains(errOut, "what the workers reported") {
		t.Errorf("ley ai usage header on stderr: %q", errOut)
	}
	for _, want := range []string{"PROVIDER", "REQUESTS", "openai", "/v1/models", "check"} {
		if !strings.Contains(out, want) {
			t.Errorf("ley ai usage table lacks %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "Days are UTC") {
		t.Errorf("the header is on stdout too:\n%s", out)
	}

	r.mustLey("", "ai", "use", "speech", "openai", "whisper-1")
	r.restart()

	cred := r.credential("openai")
	if cred == nil || cred["lastFour"] != "0099" || cred["label"] != "personal" || cred["lastUsedAtNs"] == nil ||
		lastCheck(cred)["outcome"] != "ACCEPTED" {
		t.Errorf("after a restart ley ai --json shows %v", cred)
	}
	if fs := list(r.aiState(), "features"); len(fs) != 1 || fs[0].(map[string]any)["model"] != "whisper-1" {
		t.Errorf("after a restart the feature model is %v", fs)
	}
	assertUsageLine(t, r, dayBefore, 2)
	r.assertNoCanary()
}

// assertUsageLine asserts `ley ai usage --json` is the one check line with requests on today's
// UTC day (or the next, should the test cross midnight).
func assertUsageLine(t *testing.T, r *aiRig, dayBefore string, requests int) {
	t.Helper()
	out, _ := r.mustLey("", "ai", "usage", "--json")
	lines := list(parseJSON(t, out), "lines")
	if len(lines) != 1 {
		t.Fatalf("ley ai usage --json: want one line, got %s", out)
	}
	l := lines[0].(map[string]any)
	day, _ := l["day"].(string)
	if l["provider"] != "openai" || l["model"] != "/v1/models" || l["feature"] != "check" ||
		l["requests"] != strconv.Itoa(requests) || l["scopeId"] != nil ||
		(day != dayBefore && day != time.Now().UTC().Format(time.DateOnly)) {
		t.Errorf("ley ai usage --json line: %v", l)
	}
}
