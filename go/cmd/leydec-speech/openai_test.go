// SPDX-License-Identifier: Apache-2.0

package main

import (
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"math"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// runMainEnv makes the test binary run main() instead of the tests, so a test can run the plugin
// as the daemon does, as a process, and see its exit status.
const runMainEnv = "LEYDEC_SPEECH_TEST_RUN_MAIN"

func TestMain(m *testing.M) {
	if os.Getenv(runMainEnv) == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// testKey is the key the tests hand the plugin. It must turn up in the Authorization header and
// nowhere a person or a file can see.
const testKey = "sk-test-CANARY-0123456789"

// verboseBody is a verbose_json response as OpenAI writes it.
const verboseBody = `{"task":"transcribe","language":"english","duration":1.0,` +
	`"text":"  This is whiskey six alpha bravo charlie.  ",` +
	`"segments":[{"id":0,"text":"This is whiskey six","no_speech_prob":0.1,"avg_logprob":-0.2},` +
	`{"id":1,"text":"alpha bravo charlie.","no_speech_prob":0.3,"avg_logprob":-0.4}]}`

// transcriptionCall is what the fake provider saw of one request.
type transcriptionCall struct {
	path, auth                      string
	model, format, language, prompt string
	wav                             []byte
}

// fakeProvider is an httptest server standing in for the transcription endpoint. answer picks the
// status and body for the n-th call (1-based).
type fakeProvider struct {
	*httptest.Server
	mu    sync.Mutex
	calls []transcriptionCall
}

func newFakeProvider(t *testing.T, answer func(n int, c transcriptionCall) (int, string)) *fakeProvider {
	t.Helper()
	p := &fakeProvider{}
	p.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c := transcriptionCall{path: r.URL.Path, auth: r.Header.Get("Authorization")}
		if err := r.ParseMultipartForm(64 << 20); err != nil {
			t.Errorf("the request is not a multipart form: %v", err)
		} else {
			c.model, c.format = r.FormValue("model"), r.FormValue("response_format")
			c.language, c.prompt = r.FormValue("language"), r.FormValue("prompt")
			if f, h, err := r.FormFile("file"); err != nil {
				t.Errorf("no file part: %v", err)
			} else {
				c.wav, _ = io.ReadAll(f)
				if ct := h.Header.Get("Content-Type"); ct != "audio/wav" {
					t.Errorf("the file part is %q, want audio/wav", ct)
				}
			}
		}
		p.mu.Lock()
		p.calls = append(p.calls, c)
		n := len(p.calls)
		p.mu.Unlock()
		status, body := answer(n, c)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		_, _ = io.WriteString(w, body)
	}))
	t.Cleanup(p.Close)
	return p
}

func (p *fakeProvider) seen() []transcriptionCall {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]transcriptionCall(nil), p.calls...)
}

// runOpenAI runs the openai engine in-process over segments of the given lengths, against the
// endpoint, and returns the records and what it wrote on stderr. An exit fails the test.
func runOpenAI(t *testing.T, args []string, endpoint string, lengths ...int) ([]*leylinev1.DecodeRecord, string) {
	t.Helper()
	opts, err := parseArgs(append([]string{"--engine", "openai"}, args...), func(string) string { return "" }, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	cred := &leylinev1.SetCredentialRequest{Provider: "openai", Secret: testKey, Endpoint: endpoint}
	var out, stderr bytes.Buffer
	err = plugin.RunSegmentedStreams(t.Context(), bytes.NewReader(segmentStream(t, cred, lengths...)), &out, "openai",
		func(rate uint32, cred *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
			eng, err := newEngine(opts.engine, opts.config, cred)
			if err != nil {
				t.Fatal(err)
			}
			return newDecoder(eng, float64(rate), &stderr, func(code int) { t.Errorf("the plugin exited %d: %s", code, stderr.String()) })
		})
	if err != nil {
		t.Fatal(err)
	}
	return readRecords(out.Bytes()), stderr.String()
}

// One over goes out as a multipart form with the key as a bearer token, and comes back as a
// record with the trimmed text, the language as a code, the confidence from no_speech_prob, the
// callsigns, the response as raw, and the usage under the endpoint's host.
func TestOpenAIRequestAndRecord(t *testing.T) {
	p := newFakeProvider(t, func(int, transcriptionCall) (int, string) { return http.StatusOK, verboseBody })
	recs, stderr := runOpenAI(t, nil, p.URL+"/v1/", testAudioRate)
	if len(recs) != 1 {
		t.Fatalf("got %d records, want 1; stderr: %s", len(recs), stderr)
	}
	calls := p.seen()
	if len(calls) != 1 {
		t.Fatalf("the provider saw %d calls, want 1", len(calls))
	}
	c := calls[0]
	if c.path != "/v1/audio/transcriptions" || c.auth != "Bearer "+testKey {
		t.Errorf("request: path %q auth %q", c.path, c.auth)
	}
	if c.model != "whisper-1" || c.format != "verbose_json" || c.language != "en" {
		t.Errorf("form: model %q response_format %q language %q", c.model, c.format, c.language)
	}
	rate, samples := decodeTestWAV(t, c.wav)
	if rate != testAudioRate || len(samples) != testAudioRate {
		t.Errorf("the WAV is %d samples at %d Hz, want %d at %d", len(samples), rate, testAudioRate, testAudioRate)
	}

	rec := recs[0]
	f := rec.GetFields()
	if f["text"].GetText() != "This is whiskey six alpha bravo charlie." || f["language"].GetText() != "en" ||
		f["model"].GetText() != "whisper-1" || f["callsigns"].GetText() != "W6ABC" {
		t.Errorf("fields: %v", f)
	}
	if got := f["confidence"].GetNumber(); math.Abs(got-0.8) > 1e-9 {
		t.Errorf("confidence %v, want 1 - mean(0.1, 0.3) = 0.8", got)
	}
	if string(rec.GetRaw()) != verboseBody {
		t.Errorf("raw is not the response body: %q", rec.GetRaw())
	}
	u := rec.GetUsage()
	if u.GetProvider() != "127.0.0.1" || u.GetModel() != "whisper-1" || u.GetRequests() != 1 || math.Abs(u.GetAudioSeconds()-1) > 1e-9 {
		t.Errorf("usage %v, want the endpoint's host, whisper-1, 1 request, 1 s", u)
	}
	if strings.Contains(stderr, testKey) {
		t.Errorf("the key is on stderr: %s", stderr)
	}
}

// --model is what is asked for and recorded; an empty --language lets the provider detect it, and
// the record then carries what it detected.
func TestOpenAIModelAndLanguage(t *testing.T) {
	p := newFakeProvider(t, func(int, transcriptionCall) (int, string) {
		return http.StatusOK, `{"text":"hallo","language":"german","segments":[]}`
	})
	recs, _ := runOpenAI(t, []string{"--model", "whisper-large-v3", "--language", ""}, p.URL, 4800)
	c := p.seen()[0]
	if c.model != "whisper-large-v3" || c.language != "" {
		t.Errorf("form: model %q language %q", c.model, c.language)
	}
	f := recs[0].GetFields()
	if f["language"].GetText() != "de" || f["model"].GetText() != "whisper-large-v3" || recs[0].GetUsage().GetModel() != "whisper-large-v3" {
		t.Errorf("fields %v usage %v", f, recs[0].GetUsage())
	}
	if _, ok := f["confidence"]; ok {
		t.Errorf("no segment reported no_speech_prob, yet the record has a confidence: %v", f["confidence"])
	}
}

// A model that offers only plain json is asked again in it, once for the run: the record has
// the requested language and no confidence.
func TestOpenAIFallsBackToPlainJSON(t *testing.T) {
	p := newFakeProvider(t, func(_ int, c transcriptionCall) (int, string) {
		if c.format == "verbose_json" {
			return http.StatusBadRequest, `{"error":{"message":"response_format 'verbose_json' is not compatible with model 'gpt-4o-transcribe'. Use 'json' or 'text' instead.","type":"invalid_request_error"}}`
		}
		return http.StatusOK, `{"text":"net control, go ahead"}`
	})
	recs, stderr := runOpenAI(t, []string{"--model", "gpt-4o-transcribe"}, p.URL, 4800, 4800)
	if len(recs) != 2 {
		t.Fatalf("got %d records, want 2; stderr: %s", len(recs), stderr)
	}
	var formats []string
	for _, c := range p.seen() {
		formats = append(formats, c.format)
	}
	if strings.Join(formats, ",") != "verbose_json,json,json" {
		t.Errorf("formats asked for: %v, want verbose_json once, then json", formats)
	}
	f := recs[0].GetFields()
	if f["text"].GetText() != "net control, go ahead" || f["language"].GetText() != "en" {
		t.Errorf("fields %v", f)
	}
	if _, ok := f["confidence"]; ok {
		t.Errorf("plain json has no confidence, yet the record has one")
	}
}

// A 400 about this audio costs that segment its record and a line on stderr; the next over is
// sent as usual.
func TestOpenAIRefusedAudioSkipsTheSegment(t *testing.T) {
	p := newFakeProvider(t, func(n int, _ transcriptionCall) (int, string) {
		if n == 1 {
			return http.StatusBadRequest, `{"error":{"message":"Audio file is too short. Minimum audio length is 0.1 seconds."}}`
		}
		return http.StatusOK, verboseBody
	})
	recs, stderr := runOpenAI(t, nil, p.URL, 480, testAudioRate)
	if len(recs) != 1 || recs[0].GetTime().GetSampleIndex() == 1_000_000 {
		t.Fatalf("want the second segment's record only, got %d", len(recs))
	}
	if !strings.Contains(stderr, "segment 1") || !strings.Contains(stderr, "Audio file is too short") {
		t.Errorf("stderr does not say which segment was refused and why: %s", stderr)
	}
}

func TestOpenAIEndpoint(t *testing.T) {
	for _, tc := range []struct {
		endpoint, base, host, err string
	}{
		{"", "https://api.openai.com", "openai", ""},
		{"https://gateway.example/v1/", "https://gateway.example", "gateway.example", ""},
		{"https://gateway.example/openai", "https://gateway.example/openai", "gateway.example", ""},
		{"http://localhost:8080/v1", "http://localhost:8080", "localhost", ""},
		{"http://127.0.0.1:9000", "http://127.0.0.1:9000", "127.0.0.1", ""},
		{"http://gateway.example", "", "", "the endpoint must be https: http://gateway.example would send the key in the clear"},
		{"gateway.example", "", "", `the endpoint "gateway.example" is not a URL`},
	} {
		base, host, err := openaiBase(tc.endpoint)
		if base != tc.base || host != tc.host || (err == nil) != (tc.err == "") || (err != nil && err.Error() != tc.err) {
			t.Errorf("openaiBase(%q) = %q, %q, %v; want %q, %q, %q", tc.endpoint, base, host, err, tc.base, tc.host, tc.err)
		}
	}
}

// pluginRun is one run of the plugin as a process.
type pluginRun struct {
	code           int
	stdout, stderr string
	records        []*leylinev1.DecodeRecord
}

// lastLine is the plugin's last line on stderr, which the daemon reports as the reason it exited.
func (r pluginRun) lastLine() string {
	lines := strings.Split(strings.TrimRight(r.stderr, "\n"), "\n")
	return lines[len(lines)-1]
}

// runProcess runs the plugin as the daemon does: a process with args, the key and the segments on
// stdin, and LEYLINE_KEY_ON_STDIN=1 in its environment.
func runProcess(t *testing.T, args []string, endpoint string, lengths ...int) pluginRun {
	t.Helper()
	cmd := exec.Command(os.Args[0], args...)
	cmd.Env = append(os.Environ(), runMainEnv+"=1", plugin.KeyOnStdinEnv+"=1")
	cred := &leylinev1.SetCredentialRequest{Provider: "openai", Secret: testKey, Endpoint: endpoint}
	cmd.Stdin = bytes.NewReader(segmentStream(t, cred, lengths...))
	var out, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &stderr
	err := cmd.Run()
	run := pluginRun{stdout: out.String(), stderr: stderr.String(), records: readRecords(out.Bytes())}
	var exit *exec.ExitError
	switch {
	case errors.As(err, &exit):
		run.code = exit.ExitCode()
	case err != nil:
		t.Fatal(err)
	}
	for _, s := range append([]string{run.stdout, run.stderr}, cmd.Args...) {
		if strings.Contains(s, testKey) {
			t.Errorf("the key is in the plugin's stdout, stderr or argv: %q", s)
		}
	}
	return run
}

// How each refusal ends the plugin: a rejected key or a wrong endpoint exits 1, a provider's limit
// or outage exits 75 (EX_TEMPFAIL) with the provider's words as the last line on stderr, and the
// key, which a gateway may echo back, is cut out of every line.
func TestOpenAIRefusalsEndThePlugin(t *testing.T) {
	echo := func(msg string) string { return `{"error":{"message":"` + msg + ` (sent: Bearer ` + testKey + `)"}}` }
	for _, tc := range []struct {
		name   string
		status int
		body   string
		code   int
		last   []string
	}{
		{
			"a rejected key", http.StatusUnauthorized, echo("Incorrect API key provided"), 1,
			[]string{"127.0.0.1 rejected the key (401 Unauthorized: Incorrect API key provided", "ley ai check openai"},
		},
		{"a forbidden key", http.StatusForbidden, echo("Project does not have access"), 1, []string{"rejected the key"}},
		{
			"a rate limit", http.StatusTooManyRequests, echo("Rate limit reached for whisper-1"), exitTempFail,
			[]string{"127.0.0.1: 429 Too Many Requests: Rate limit reached for whisper-1 (sent: Bearer …)"},
		},
		{
			"an outage", http.StatusInternalServerError, "upstream is down", exitTempFail,
			[]string{"127.0.0.1: 500 Internal Server Error: upstream is down"},
		},
		{
			"no credit", http.StatusBadRequest, echo("Your credit balance is too low"), exitTempFail,
			[]string{"400 Bad Request: Your credit balance is too low"},
		},
		{"no such API", http.StatusNotFound, "not found", 1, []string{"has no transcription API at"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := newFakeProvider(t, func(int, transcriptionCall) (int, string) { return tc.status, tc.body })
			run := runProcess(t, []string{"--engine", "openai"}, p.URL, 4800, 4800)
			if run.code != tc.code {
				t.Errorf("exit %d, want %d; stderr:\n%s", run.code, tc.code, run.stderr)
			}
			for _, want := range tc.last {
				if !strings.Contains(run.lastLine(), want) {
					t.Errorf("the last stderr line %q lacks %q", run.lastLine(), want)
				}
			}
			if len(p.seen()) != 1 || len(run.records) != 0 {
				t.Errorf("after the refusal: %d calls and %d records, want 1 and none", len(p.seen()), len(run.records))
			}
		})
	}
}

// A provider that cannot be reached is an outage too: exit 75, naming the host.
func TestOpenAIUnreachableIsTemporary(t *testing.T) {
	p := newFakeProvider(t, func(int, transcriptionCall) (int, string) { return http.StatusOK, verboseBody })
	url := p.URL
	p.Close()
	run := runProcess(t, []string{"--engine", "openai"}, url, 4800)
	if run.code != exitTempFail || !strings.HasPrefix(run.lastLine(), "127.0.0.1 did not answer") {
		t.Errorf("exit %d, last line %q; want 75 and the host", run.code, run.lastLine())
	}
}

// A redirect is not followed, so the key reaches no host but the endpoint's.
func TestOpenAIRedirectIsNotFollowed(t *testing.T) {
	var elsewhere int
	other := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { elsewhere++ }))
	defer other.Close()
	redirector := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, other.URL+r.URL.Path, http.StatusTemporaryRedirect)
	}))
	defer redirector.Close()
	run := runProcess(t, []string{"--engine", "openai"}, redirector.URL, 4800)
	if run.code != 1 || !strings.Contains(run.lastLine(), "redirected the call to") || elsewhere != 0 {
		t.Errorf("exit %d, last line %q, %d calls elsewhere; want 1, the redirect named, none", run.code, run.lastLine(), elsewhere)
	}
}

// The plugin as a process: records on stdout for every over, exit 0 when stdin closes.
func TestOpenAIProcessTranscribes(t *testing.T) {
	p := newFakeProvider(t, func(int, transcriptionCall) (int, string) { return http.StatusOK, verboseBody })
	run := runProcess(t, []string{"--engine", "openai", "--model", "whisper-1"}, p.URL, 4800, 9600)
	if run.code != 0 || len(run.records) != 2 {
		t.Fatalf("exit %d with %d records; stderr:\n%s", run.code, len(run.records), run.stderr)
	}
	if run.records[1].GetUsage().GetAudioSeconds() != 0.2 {
		t.Errorf("audio_seconds %v, want 0.2", run.records[1].GetUsage().GetAudioSeconds())
	}
}

// An endpoint that would send the key in the clear is refused before anything is sent.
func TestOpenAIRefusesAPlainHTTPEndpoint(t *testing.T) {
	run := runProcess(t, []string{"--engine", "openai"}, "http://gateway.example/v1", 4800)
	if run.code != 1 || !strings.Contains(run.stderr, "the endpoint must be https") {
		t.Errorf("exit %d; stderr:\n%s", run.code, run.stderr)
	}
}

// The WAV the provider gets holds the segment's samples to 16-bit precision, at its rate, and
// clips what is beyond full scale.
func TestWAVRoundTripsASine(t *testing.T) {
	const rate = 16000
	in := make([]float32, rate)
	for i := range in {
		in[i] = float32(0.8 * math.Sin(2*math.Pi*440*float64(i)/rate))
	}
	in = append(in, 1.5, -1.5, float32(math.NaN()))
	got, samples := decodeTestWAV(t, encodeWAV(in, rate))
	if got != rate || len(samples) != len(in) {
		t.Fatalf("%d samples at %d Hz, want %d at %d", len(samples), got, len(in), rate)
	}
	for i := range rate {
		if d := math.Abs(float64(samples[i] - in[i])); d > 1.0/math.MaxInt16 {
			t.Fatalf("sample %d: %v, want %v", i, samples[i], in[i])
		}
	}
	if tail := samples[rate:]; tail[0] != 1 || tail[1] != -1 || tail[2] != 0 {
		t.Errorf("1.5, -1.5 and NaN became %v, want clipped to 1, -1 and silence", tail)
	}
}

// decodeTestWAV reads a 16-bit mono PCM WAV back into floats, checking the header on the way.
func decodeTestWAV(t *testing.T, wav []byte) (uint32, []float32) {
	t.Helper()
	le := binary.LittleEndian
	if len(wav) < 44 || string(wav[0:4]) != "RIFF" || string(wav[8:16]) != "WAVEfmt " || string(wav[36:40]) != "data" {
		t.Fatalf("not a canonical WAV header: % x", wav[:min(len(wav), 44)])
	}
	if le.Uint16(wav[20:]) != 1 || le.Uint16(wav[22:]) != 1 || le.Uint16(wav[34:]) != 16 {
		t.Fatalf("format %d, channels %d, bits %d; want PCM, mono, 16", le.Uint16(wav[20:]), le.Uint16(wav[22:]), le.Uint16(wav[34:]))
	}
	rate, dataLen := le.Uint32(wav[24:]), le.Uint32(wav[40:])
	if le.Uint32(wav[4:]) != 36+dataLen || int(dataLen) != len(wav)-44 || le.Uint32(wav[28:]) != 2*rate {
		t.Fatalf("lengths disagree: riff %d data %d file %d byte rate %d", le.Uint32(wav[4:]), dataLen, len(wav), le.Uint32(wav[28:]))
	}
	out := make([]float32, dataLen/2)
	for i := range out {
		out[i] = float32(int16(le.Uint16(wav[44+2*i:]))) / math.MaxInt16
	}
	return rate, out
}
