// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/pkg/bookmarks"
)

// The tools AI-8 added, each held against its mirror verb's --json.

// set changes the agent's channel, picks it over another client's the way ley set picks ley's,
// and refuses to move the radio under somebody else's channel until take_over.
func TestMCPSetMirrorsLeySet(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	listening(t, h.client) // another client's channel on 146.52
	var mine leylinev1.Channel
	structuredField(t, h.must(t, "tune", map[string]any{"frequency": "146.55"}), "channel", &mine)

	res := h.must(t, "set", map[string]any{"param": "squelch", "value": "-50"})
	var ev leylinev1.Event
	structured(t, res, &ev)
	if ev.GetChannel().GetChannelId() != mine.GetChannelId() || ev.GetChannel().GetSquelchDb() != -50 {
		t.Fatalf("set did not confirm the agent's channel at -50: %v", &ev)
	}
	text := resultText(res)
	for _, want := range []string{"the only active channel an agent made", "squelch", "-50 dBFS"} {
		if !strings.Contains(text, want) {
			t.Errorf("set's text lacks %q:\n%s", want, text)
		}
	}
	// The JSON is what `ley set --json` prints: the confirming Event.
	var cli leylinev1.Event
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "set", "squelch", "-45", "--channel", mine.GetChannelId(), "--json")), &cli); err != nil {
		t.Fatal(err)
	}
	if _, ok := cli.Body.(*leylinev1.Event_Channel); !ok {
		t.Fatalf("ley set --json is not a channel event: %v", &cli)
	}

	before, _ := h.client.State(t.Context())
	refused := h.call(t, "set", map[string]any{"param": "freq", "value": "150", "channel": mine.GetChannelId()})
	if !refused.IsError {
		t.Fatalf("set freq moved a radio another channel listens on:\n%s", resultText(refused))
	}
	for _, want := range []string{"1 channel listening", "take_over: true"} {
		if !strings.Contains(resultText(refused), want) {
			t.Errorf("the refusal lacks %q:\n%s", want, resultText(refused))
		}
	}
	if strings.Contains(resultText(refused), mine.GetChannelId()) {
		t.Errorf("the channel being moved is not one that falls silent:\n%s", resultText(refused))
	}
	if after, _ := h.client.State(t.Context()); after.EventSeq != before.EventSeq {
		t.Errorf("a refusal changed the daemon: seq %d -> %d", before.EventSeq, after.EventSeq)
	}
	h.must(t, "set", map[string]any{"param": "freq", "value": "150", "channel": mine.GetChannelId(), "take_over": true})

	if r := h.call(t, "set", map[string]any{"param": "loudness", "value": "3"}); !r.IsError || !strings.Contains(resultText(r), "squelch") {
		t.Errorf("an unknown setting must be refused with the list: %s", resultText(r))
	}
}

// stop with no arguments stops the agent's own channels and leaves another client's; naming
// another client's channel is refused until take_over.
func TestMCPStop(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	listening(t, h.client)
	var mine leylinev1.Channel
	structuredField(t, h.must(t, "tune", map[string]any{"frequency": "146.55"}), "channel", &mine)
	st, _ := h.client.State(t.Context())
	var theirs string
	for _, ch := range st.GetChannels() {
		if ch.GetChannelId() != mine.GetChannelId() {
			theirs = ch.GetChannelId()
		}
	}

	res := h.must(t, "stop", nil)
	structured(t, res, &leylinev1.Empty{})
	if !strings.Contains(resultText(res), "stopped 146.550 MHz") {
		t.Errorf("stop's text:\n%s", resultText(res))
	}
	st, _ = h.client.State(t.Context())
	if channelByID(st, mine.GetChannelId()) != nil || channelByID(st, theirs) == nil {
		t.Fatalf("stop must take the agent's channel and leave the other: %v", st.GetChannels())
	}
	if r := h.call(t, "stop", nil); !r.IsError || !strings.Contains(resultText(r), "no channels") {
		t.Errorf("with none of its own, stop says so: %s", resultText(r))
	}

	refused := h.call(t, "stop", map[string]any{"channel": theirs})
	if !refused.IsError || !strings.Contains(resultText(refused), theirs) || !strings.Contains(resultText(refused), "take_over: true") {
		t.Fatalf("another client's channel must be refused by name:\n%s", resultText(refused))
	}
	h.must(t, "stop", map[string]any{"channel": theirs, "take_over": true})
	if st, _ = h.client.State(t.Context()); channelByID(st, theirs) != nil {
		t.Error("take_over did not stop the channel")
	}
	// ley stop --json prints the daemon's Empty, which is the tool's JSON too.
	if out := strings.TrimSpace(mustRun(t, h.sock, "stop", "all", "--json")); out != "{}" {
		t.Errorf("ley stop all --json = %q", out)
	}
}

// list_bands, list_presets and help are the verbs' own tables and topics.
func TestMCPReferenceTools(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	sameJSON := func(name string, args map[string]any, verb ...string) *bytes.Buffer {
		t.Helper()
		res := h.must(t, name, args)
		want := mustRun(t, h.sock, append(verb, "--json")...)
		if !jsonEqual(t, resultJSON(res), []byte(want)) {
			t.Errorf("%s != ley %s --json:\n%s\n%s", name, strings.Join(verb, " "), resultJSON(res), want)
		}
		return bytes.NewBufferString(resultText(res))
	}
	if text := sameJSON("list_bands", nil, "bands"); !strings.Contains(text.String(), "2 m amateur") {
		t.Errorf("list_bands text:\n%s", text)
	}
	if text := sameJSON("list_bands", map[string]any{"query": "146.52"}, "bands", "146.52"); !strings.Contains(text.String(), "2 m amateur") {
		t.Errorf("list_bands 146.52 text:\n%s", text)
	}
	if text := sameJSON("list_presets", nil, "presets"); !strings.Contains(text.String(), "wx3") {
		t.Errorf("list_presets text:\n%s", text)
	}
	if r := h.call(t, "list_bands", map[string]any{"query": "nowhere"}); !r.IsError {
		t.Errorf("an unknown band must be an error: %s", resultText(r))
	}

	list := h.must(t, "help", nil)
	var topicsJSON struct {
		Topics []helpTopic `json:"topics"`
	}
	if err := json.Unmarshal(resultJSON(list), &topicsJSON); err != nil || len(topicsJSON.Topics) != len(topics) {
		t.Fatalf("help with no topic lists them all (%v): %s", err, resultJSON(list))
	}
	one := h.must(t, "help", map[string]any{"topic": "Squelch"})
	var topic helpTopic
	if err := json.Unmarshal(resultJSON(one), &topic); err != nil || topic.Name != "squelch" || topic.Text != topicSquelch() {
		t.Errorf("help squelch is not the topic's text (%v): %+v", err, topic)
	}
	if !strings.Contains(resultText(one), "floor + 10 dB") {
		t.Errorf("help squelch text:\n%s", resultText(one))
	}
	if r := h.call(t, "help", map[string]any{"topic": "antennas"}); !r.IsError || !strings.Contains(resultText(r), "glossary") {
		t.Errorf("an unknown topic must name the topics: %s", resultText(r))
	}
}

// The bookmark tools edit the file $LEYLINE_BOOKMARKS names, as the verbs do, and return the rows
// their --json prints.
func TestMCPBookmarkTools(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	path := filepath.Join(t.TempDir(), "bookmarks.json")
	h.srv.app.LookupEnv = func(k string) (string, bool) {
		if k == bookmarks.BookmarksEnv {
			return path, true
		}
		return "", false
	}
	if raw := strings.TrimSpace(string(resultJSON(h.must(t, "list_bookmarks", nil)))); raw != "[]" {
		t.Fatalf("an empty file lists as []: %s", raw)
	}
	added := h.must(t, "add_bookmark", map[string]any{"frequency": "146.94", "name": "Local repeater", "tone": "100.0", "note": "600 kHz down", "tags": []string{"home"}})
	var row bookmarkJSON
	if err := json.Unmarshal(resultJSON(added), &row); err != nil || row.Hz != 146_940_000 || row.Mode != "NFM" || row.Tone != "100.0" || row.ID == "" {
		t.Fatalf("add_bookmark row (%v): %s", err, resultJSON(added))
	}
	if !strings.Contains(resultText(added), "2 m amateur band default") {
		t.Errorf("add_bookmark text says where the mode came from:\n%s", resultText(added))
	}
	if r := h.call(t, "add_bookmark", map[string]any{"frequency": "146.94", "name": "x", "tone": "99"}); !r.IsError {
		t.Errorf("a bad tone must be refused: %s", resultText(r))
	}

	want, _, err := runBookmarks(t, path, "--json", "bookmarks", "--tag", "home")
	if err != nil {
		t.Fatal(err)
	}
	listed := h.must(t, "list_bookmarks", map[string]any{"tag": "home"})
	if !jsonEqual(t, resultJSON(listed), []byte(want)) {
		t.Errorf("list_bookmarks != ley bookmarks --json:\n%s\n%s", resultJSON(listed), want)
	}
	if !strings.Contains(resultText(listed), "PL 100.0") {
		t.Errorf("list_bookmarks text:\n%s", resultText(listed))
	}

	sample, _ := filepath.Abs("../../../fixtures/chirp/sample.csv")
	dry := h.must(t, "import_chirp", map[string]any{"path": sample, "dry_run": true})
	if !strings.Contains(resultText(dry), "8 added, 1 updated, 1 skipped") || !strings.Contains(resultText(dry), "nothing written") {
		t.Errorf("dry run text:\n%s", resultText(dry))
	}
	var imp importJSON
	if err := json.Unmarshal(resultJSON(h.must(t, "import_chirp", map[string]any{"path": sample})), &imp); err != nil || len(imp.Added) != 8 || len(imp.Skipped) != 1 {
		t.Fatalf("import_chirp (%v): %+v", err, imp)
	}
	if r := h.call(t, "import_chirp", map[string]any{"path": filepath.Join(t.TempDir(), "none.csv")}); !r.IsError {
		t.Error("a missing file must be an error")
	}

	removed := h.must(t, "remove_bookmark", map[string]any{"bookmark": "local REPEATER"})
	if err := json.Unmarshal(resultJSON(removed), &row); err != nil || row.Name != "Local repeater" {
		t.Errorf("remove_bookmark row (%v): %s", err, resultJSON(removed))
	}
	if r := h.call(t, "remove_bookmark", map[string]any{"bookmark": "Local repeater"}); !r.IsError {
		t.Errorf("a bookmark already gone must be an error: %s", resultText(r))
	}
}

// watch starts the job ley watch --detach would, with the same predicate and notifier, and
// refuses the shell notifier before anything starts.
func TestMCPWatchMirrorsLeyWatch(t *testing.T) {
	t.Parallel()
	h := newMCPHarness(t)
	if r := h.call(t, "watch", map[string]any{"decoder": "aprs", "notify": "shell:say hi"}); !r.IsError || !strings.Contains(resultText(r), "not available") {
		t.Fatalf("the shell notifier must be refused: %s", resultText(r))
	}
	if jobs, _ := h.client.ListJobs(t.Context()); len(jobs) != 0 {
		t.Fatalf("a refused watch started a job: %v", jobs)
	}
	res := h.must(t, "watch", map[string]any{"decoder": "packets", "where": []string{"device_id=LEYTST-1"}, "notify": "macos", "keep": true})
	var job leylinev1.Job
	structured(t, res, &job)
	if job.GetDecode().GetDecoder() != "aprs" || !job.GetDecode().GetKeep() || job.GetState() != leylinev1.JobState_RUNNING {
		t.Fatalf("watch job: %v", &job)
	}
	for _, want := range []string{"watching aprs", "device_id = LEYTST-1", "notify: macOS notification", "kept", "cancel_job"} {
		if !strings.Contains(resultText(res), want) {
			t.Errorf("watch text lacks %q:\n%s", want, resultText(res))
		}
	}
	h.must(t, "cancel_job", map[string]any{"job": job.GetJobId()})

	mustSay(t, h.sock, "watch", "aprs", "--where", "device_id=LEYTST-1", "--notify", "--detach")
	jobs, _ := h.client.ListJobs(t.Context())
	var cli *leylinev1.Job
	for _, j := range jobs {
		if j.GetJobId() != job.GetJobId() {
			cli = j
		}
	}
	if cli == nil {
		t.Fatalf("ley watch --detach started no job: %v", jobs)
	}
	if !proto.Equal(cli.GetDecode().GetPredicate(), job.GetDecode().GetPredicate()) || !proto.Equal(cli.GetDecode().GetNotify(), job.GetDecode().GetNotify()) {
		t.Errorf("watch and ley watch built different jobs:\n%v\n%v", job.GetDecode(), cli.GetDecode())
	}
	_, _ = h.client.Jobs.CancelJob(t.Context(), &leylinev1.JobRef{JobId: cli.GetJobId()})
	if r := h.call(t, "watch", map[string]any{"decoder": "aprs", "near": "37.76,-122.42"}); !r.IsError || !strings.Contains(resultText(r), "radius") {
		t.Errorf("near without radius must be refused: %s", resultText(r))
	}
}

// attach_device adds an rtl_tcp radio as ley devices attach does, and a recording as a file
// device as ley play does before it tunes.
func TestMCPAttachDevice(t *testing.T) {
	t.Parallel()
	h := newMCPHarnessWith(t, fakedaemon.Options{NoDevice: true})
	res := h.must(t, "attach_device", map[string]any{"kind": "rtltcp", "endpoint": "pi.local:1234"})
	var dev leylinev1.DeviceDescriptor
	structured(t, res, &dev)
	if dev.GetDriver() != "rtltcp" || !strings.Contains(resultText(res), "the daemon remembers it") {
		t.Fatalf("attach rtltcp: %v\n%s", &dev, resultText(res))
	}
	var cli leylinev1.DeviceDescriptor
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "devices", "attach", "rtltcp", "pi.local:1234", "--json")), &cli); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&dev, &cli) {
		t.Errorf("attach_device != ley devices attach --json:\n%v\n%v", &dev, &cli)
	}
	if r := h.call(t, "attach_device", map[string]any{"kind": "rtltcp", "endpoint": "roof.invalid:1234"}); !r.IsError || !strings.Contains(resultText(r), "DEVICE_IO") {
		t.Errorf("an unreachable host must be the daemon's error: %s", resultText(r))
	}

	dir := t.TempDir()
	iq := filepath.Join(dir, "radio-a.cf32")
	if err := os.WriteFile(iq, make([]byte, 8*1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "radio-a.json"), []byte(`{"format":"cf32","sample_rate":2400000,"center_hz":146520000}`), 0o644); err != nil {
		t.Fatal(err)
	}
	file := h.must(t, "attach_device", map[string]any{"kind": "file", "path": iq, "loop": true})
	structured(t, file, &dev)
	if dev.GetDriver() != "file" || !strings.Contains(resultText(file), "146.520 MHz") || !strings.Contains(resultText(file), "until the daemon restarts") {
		t.Errorf("attach file: %v\n%s", &dev, resultText(file))
	}
	if r := h.call(t, "attach_device", map[string]any{"kind": "file", "path": filepath.Join(dir, "gone.cf32")}); !r.IsError {
		t.Error("a missing file must be an error")
	}
	if r := h.call(t, "attach_device", map[string]any{"kind": "airspy"}); !r.IsError || !strings.Contains(resultText(r), "rtltcp") {
		t.Errorf("an unknown kind names the kinds: %s", resultText(r))
	}
}

// jsonEqual compares two JSON documents as values, so whitespace and key order do not count.
func jsonEqual(t *testing.T, a, b []byte) bool {
	t.Helper()
	var x, y any
	if err := json.Unmarshal(a, &x); err != nil {
		t.Fatalf("%v: %s", err, a)
	}
	if err := json.Unmarshal(b, &y); err != nil {
		t.Fatalf("%v: %s", err, b)
	}
	xa, _ := json.Marshal(x)
	ya, _ := json.Marshal(y)
	return bytes.Equal(xa, ya)
}
