// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"image/png"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"google.golang.org/protobuf/encoding/protojson"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/fakedaemon"
	"github.com/dpup/leysdr/go/internal/testutil"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// mcpToolNames is the tool table of docs/plans/mcp.md as `ley mcp` serves it,
// in the order it is registered. The reference page (docs/reference/mcp.md)
// lists the same names; a tool added here is added there.
var mcpToolNames = []string{
	"list_devices", "get_state", "daemon_logs", "tune", "scan", "listen_summary", "snapshot",
	"list_decoders", "query_records", "list_entities", "start_decode_job",
	"list_jobs", "get_job", "cancel_job",
}

// mcpHarness starts a fake daemon, an MCP server dialled to it the way `ley
// mcp` dials, and an in-memory MCP client session on the server. The
// server's stderr is captured so a test can read what it logged.
type mcpHarness struct {
	sock   string
	client *leyline.Client
	srv    *mcpServer
	cs     *mcp.ClientSession
	stderr *bytes.Buffer
}

func newMCPHarness(t *testing.T) *mcpHarness {
	t.Helper()
	sock, c := harness(t, fakedaemon.Options{})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	var errb bytes.Buffer
	app := &App{
		Socket: sock, Stderr: &errb, Stdout: &bytes.Buffer{},
		LookupEnv: func(string) (string, bool) { return "", false },
		IsTTY:     func() bool { return false }, IsErrTTY: func() bool { return false },
		TermWidth: func() int { return 80 }, TermHeight: func() int { return 24 }, ErrTermWidth: func() int { return 80 },
	}
	app.clientKind, app.clientLabel = "mcp", "ley mcp"
	srv, err := newMCPServer(ctx, app)
	if err != nil {
		t.Fatalf("newMCPServer: %v", err)
	}
	st, ct := mcp.NewInMemoryTransports()
	if _, err := srv.server.Connect(ctx, st, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "0"}, nil)
	cs, err := client.Connect(ctx, ct, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	h := &mcpHarness{sock: sock, client: c, srv: srv, cs: cs, stderr: &errb}
	t.Cleanup(func() {
		_ = cs.Close()
		srv.close()
	})
	return h
}

// call runs one tool and returns its result; a protocol-level error fails the
// test, a tool error (IsError) is the caller's to inspect.
func (h *mcpHarness) call(t *testing.T, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res, err := h.cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	return res
}

// must runs a tool that has to succeed and returns its result.
func (h *mcpHarness) must(t *testing.T, name string, args map[string]any) *mcp.CallToolResult {
	t.Helper()
	res := h.call(t, name, args)
	if res.IsError {
		t.Fatalf("%s %v: %s", name, args, resultText(res))
	}
	return res
}

// resultText joins the text content blocks of a result.
func resultText(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}

// structured unmarshals a result's structured content into m through
// protojson, which is what proves the shape is the contract's.
func structured(t *testing.T, res *mcp.CallToolResult, m proto.Message) {
	t.Helper()
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	if err := protojson.Unmarshal(raw, m); err != nil {
		t.Fatalf("structured content is not a %T: %v\n%s", m, err, raw)
	}
}

// structuredField pulls one top-level key out of a composite result as proto3 JSON.
func structuredField(t *testing.T, res *mcp.CallToolResult, key string, m proto.Message) {
	t.Helper()
	raw, err := json.Marshal(res.StructuredContent)
	if err != nil {
		t.Fatal(err)
	}
	var parts map[string]json.RawMessage
	if err := json.Unmarshal(raw, &parts); err != nil {
		t.Fatalf("%v\n%s", err, raw)
	}
	part, ok := parts[key]
	if !ok {
		t.Fatalf("no %q in %s", key, raw)
	}
	if err := protojson.Unmarshal(part, m); err != nil {
		t.Fatalf("%q is not a %T: %v\n%s", key, m, err, part)
	}
}

// MCP-1: an MCP client lists the server's tools, and the list is the table.
func TestMCPListsTheToolTable(t *testing.T) {
	h := newMCPHarness(t)
	res, err := h.cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var names []string
	for _, tool := range res.Tools {
		names = append(names, tool.Name)
		if tool.Description == "" || tool.InputSchema == nil {
			t.Errorf("%s: no description or input schema", tool.Name)
		}
	}
	// The SDK lists tools by name; the table's order is the help text's.
	want := append([]string{}, mcpToolNames...)
	sort.Strings(want)
	if strings.Join(names, " ") != strings.Join(want, " ") {
		t.Errorf("tools:\n got %v\nwant %v", names, want)
	}
	tmpl, err := h.cs.ListResourceTemplates(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	var uris []string
	for _, r := range tmpl.ResourceTemplates {
		uris = append(uris, r.URITemplate)
	}
	sort.Strings(uris)
	if strings.Join(uris, " ") != "ley://records/{job_id} ley://scans/{scan_id}" {
		t.Errorf("resource templates: %v", uris)
	}
	if init := h.cs.InitializeResult(); init == nil || init.ServerInfo.Name != "leyline" || !strings.Contains(init.Instructions, "proto3 JSON") {
		t.Errorf("initialize result: %+v", init)
	}
}

// MCP-1: the server's daemon connection is the shared client library's, with
// the adapter's identity: what it creates is attributed to kind "mcp".
func TestMCPIsTheSharedClientWithItsOwnIdentity(t *testing.T) {
	h := newMCPHarness(t)
	res := h.must(t, "tune", map[string]any{"frequency": "146.52"})
	var ch leylinev1.Channel
	structuredField(t, res, "channel", &ch)
	if ch.GetOwner().GetKind() != "mcp" || ch.GetOwner().GetLabel() != "ley mcp" {
		t.Errorf("channel owner %v, want kind mcp label \"ley mcp\"", ch.GetOwner())
	}
	if ch.GetOwner().GetClientId() != leyline.ProcessClientID() {
		t.Errorf("owner client id %q is not this process's %q: presence would not cover it", ch.GetOwner().GetClientId(), leyline.ProcessClientID())
	}
	if !strings.Contains(resultText(res), "using NFM: 2 m amateur band default") {
		t.Errorf("the tune's decisions are missing from the text:\n%s", resultText(res))
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(raw), `"sink":null`) {
		t.Errorf("no audio was asked for, so sink must be null: %s", raw)
	}
}

// MCP-2: list_devices and get_state return exactly what the verbs print.
func TestMCPOrientToolsMirrorTheVerbs(t *testing.T) {
	h := newMCPHarness(t)
	var got, want leylinev1.ListDevicesResponse
	structured(t, h.must(t, "list_devices", nil), &got)
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "devices", "--json")), &want); err != nil {
		t.Fatal(err)
	}
	if !proto.Equal(&got, &want) {
		t.Errorf("list_devices != ley devices --json:\n%v\n%v", &got, &want)
	}
	if text := resultText(h.must(t, "list_devices", nil)); !strings.Contains(text, want.Devices[0].Model) {
		t.Errorf("text names no device:\n%s", text)
	}
	var st, stWant leylinev1.GetStateResponse
	structured(t, h.must(t, "get_state", nil), &st)
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "state", "--json")), &stWant); err != nil {
		t.Fatal(err)
	}
	st.EventSeq, stWant.EventSeq = 0, 0
	if !proto.Equal(&st, &stWant) {
		t.Errorf("get_state != ley state --json:\n%v\n%v", &st, &stWant)
	}
}

// MCP-2: tune refuses to move a radio somebody is listening on, names who,
// and says how to insist; take_over moves it. The refusal is made before
// anything is written, so the daemon's state is untouched by it.
func TestMCPTuneRefusesAnActiveCaptureAndNamesWhy(t *testing.T) {
	h := newMCPHarness(t)
	listening(t, h.client)
	before, _ := h.client.State(context.Background())
	res := h.call(t, "tune", map[string]any{"frequency": "150"})
	if !res.IsError {
		t.Fatalf("tune moved a radio somebody was listening on:\n%s", resultText(res))
	}
	text := resultText(res)
	for _, want := range []string{"the radio is on 146.520 MHz with 1 channel listening", before.Channels[0].ChannelId, "take_over: true"} {
		if !strings.Contains(text, want) {
			t.Errorf("refusal lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "--retune") {
		t.Errorf("an agent has no flags; the refusal names one:\n%s", text)
	}
	after, _ := h.client.State(context.Background())
	if after.EventSeq != before.EventSeq {
		t.Errorf("a refusal changed the daemon: seq %d -> %d", before.EventSeq, after.EventSeq)
	}
	moved := h.must(t, "tune", map[string]any{"frequency": "150", "take_over": true})
	var cap leylinev1.Capture
	structuredField(t, moved, "capture", &cap)
	if cap.GetCenterHz() != 150_000_000 {
		t.Errorf("take_over did not move the radio: %v", &cap)
	}
}

// MCP-2: a channel tune makes ends when the server does; keep leaves it.
func TestMCPTunedChannelsFollowTheServersPresence(t *testing.T) {
	h := newMCPHarness(t)
	var ephemeral, kept leylinev1.Channel
	structuredField(t, h.must(t, "tune", map[string]any{"frequency": "146.52"}), "channel", &ephemeral)
	structuredField(t, h.must(t, "tune", map[string]any{"frequency": "146.55", "keep": true}), "channel", &kept)
	if ephemeral.GetPersistent() || !kept.GetPersistent() {
		t.Fatalf("keep did not decide persistence: %v %v", &ephemeral, &kept)
	}
	// The tool's own session has closed by now; the channel is still there
	// because the server's presence stream holds it.
	st, _ := h.client.State(context.Background())
	if channelByID(st, ephemeral.GetChannelId()) == nil {
		t.Fatal("the channel died with the tool's session; the server's presence should hold it")
	}
	_ = h.cs.Close()
	h.srv.close()
	deadline := time.Now().Add(3 * time.Second)
	for {
		st, _ = h.client.State(context.Background())
		if channelByID(st, ephemeral.GetChannelId()) == nil || time.Now().After(deadline) {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if channelByID(st, ephemeral.GetChannelId()) != nil {
		t.Error("the ephemeral channel outlived the server")
	}
	if channelByID(st, kept.GetChannelId()) == nil {
		t.Error("the kept channel died with the server")
	}
}

// MCP-3: scan returns the Scan the verb prints, with the fake's detections.
func TestMCPScanReturnsTheDetections(t *testing.T) {
	h := newMCPHarness(t)
	res := h.must(t, "scan", map[string]any{"range": "145M..147M"})
	var scan leylinev1.Scan
	structured(t, res, &scan)
	if len(scan.Detections) == 0 {
		t.Fatalf("no detections: %s", resultText(res))
	}
	var want leylinev1.Scan
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "--json", "scan", "145M..147M")), &want); err != nil {
		t.Fatal(err)
	}
	centres := func(s *leylinev1.Scan) map[uint64]bool {
		out := map[uint64]bool{}
		for _, d := range s.Detections {
			out[d.CenterHz] = true
		}
		return out
	}
	if got, exp := centres(&scan), centres(&want); len(got) != len(exp) {
		t.Errorf("the tool and the verb found different carriers: %v vs %v", got, exp)
	}
	text := resultText(res)
	for _, want := range []string{"FREQUENCY", "SNR (dB)", "SEEN", leyline.FormatFrequency(scan.Detections[0].CenterHz)} {
		if !strings.Contains(text, want) {
			t.Errorf("summary lacks %q:\n%s", want, text)
		}
	}
	// A band name works where a range does, as it does for the verb.
	if r := h.call(t, "scan", map[string]any{"range": "2m"}); r.IsError {
		t.Errorf("scan by band name: %s", resultText(r))
	}
	if r := h.call(t, "scan", map[string]any{"range": "nonsense"}); !r.IsError || !strings.Contains(resultText(r), "no band called") {
		t.Errorf("a bad range must be refused with the band hint: %s", resultText(r))
	}
}

// MCP-3: listen_summary folds the squelch edges and the meter for its window
// and leaves no channel behind.
func TestMCPListenSummary(t *testing.T) {
	h := newMCPHarness(t)
	// The fake's signal swings 20 dB either side of -50 dBFS every 4 s, so a
	// squelch at -50 crosses at least twice in 4.5 s: one of them is a close.
	res := h.must(t, "listen_summary", map[string]any{"target": "146.52", "duration_s": 4.5, "squelch": "-50"})
	var tr leylinev1.Transcript
	structuredField(t, res, "transcript", &tr)
	if len(tr.Segments) == 0 {
		t.Errorf("no transmission folded in 4.5 s:\n%s", resultText(res))
	}
	for _, seg := range tr.Segments {
		if seg.GetEnd().GetSampleIndex() <= seg.GetStart().GetSampleIndex() {
			t.Errorf("segment has no length: %v", seg)
		}
	}
	raw, _ := json.Marshal(res.StructuredContent)
	var parts struct {
		Meter meterStats `json:"meter"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil || parts.Meter.Samples == 0 {
		t.Errorf("meter stats missing (%v): %s", err, raw)
	}
	text := resultText(res)
	for _, want := range []string{"146.520 MHz NFM for 4.5 s", "transmission", "squelch -50.0 dB"} {
		if !strings.Contains(text, want) {
			t.Errorf("summary lacks %q:\n%s", want, text)
		}
	}
	st, _ := h.client.State(context.Background())
	if len(st.Channels) != 0 {
		t.Errorf("listen_summary left a channel behind: %v", st.Channels)
	}
	if r := h.call(t, "listen_summary", map[string]any{"target": "146.52", "duration_s": 1000}); !r.IsError {
		t.Error("a 1000 s listen must be refused: a watch is a job")
	}
}

// MCP-3 and MCP-6: snapshot returns the `ley spectrum --json` row and a PNG
// whose plot is one pixel per negotiated bin.
func TestMCPSnapshot(t *testing.T) {
	h := newMCPHarness(t)
	res := h.must(t, "snapshot", map[string]any{"frequency": "146.52", "bins": 256})
	raw, _ := json.Marshal(res.StructuredContent)
	var row SpectrumRow
	if err := json.Unmarshal(raw, &row); err != nil {
		t.Fatalf("%v\n%s", err, raw)
	}
	if len(row.Bins) != 256 || row.CenterHz != 146_520_000 || row.SpanHz == 0 {
		t.Errorf("row: %d bins, centre %d, span %d", len(row.Bins), row.CenterHz, row.SpanHz)
	}
	var img *mcp.ImageContent
	for _, c := range res.Content {
		if ic, ok := c.(*mcp.ImageContent); ok {
			img = ic
		}
	}
	if img == nil || img.MIMEType != "image/png" {
		t.Fatalf("no PNG in the result: %v", res.Content)
	}
	decoded, err := png.Decode(bytes.NewReader(img.Data))
	if err != nil {
		t.Fatalf("the image is not a PNG: %v", err)
	}
	if w := decoded.Bounds().Dx(); w != 256+pngGutter {
		t.Errorf("plot width %d, want one pixel per bin plus the gutter (%d)", w, 256+pngGutter)
	}
	if !strings.Contains(resultText(res), "noise floor") {
		t.Errorf("text:\n%s", resultText(res))
	}
	st, _ := h.client.State(context.Background())
	if len(st.Captures) != 0 {
		t.Errorf("snapshot left its capture behind: %v", st.Captures)
	}
	bare := h.must(t, "snapshot", map[string]any{"frequency": "146.52", "no_image": true})
	for _, c := range bare.Content {
		if _, ok := c.(*mcp.ImageContent); ok {
			t.Error("no_image still drew a picture")
		}
	}
	// Without a frequency and with an idle radio there is nothing to draw.
	if r := h.call(t, "snapshot", nil); !r.IsError || !strings.Contains(resultText(r), "not tuned to anything yet") {
		t.Errorf("an idle radio and no frequency must be refused with a hint: %s", resultText(r))
	}
}

// MCP-4 and MCP-5: the decoder and job tools over the DEC-6 fake.
func TestMCPDecoderAndJobTools(t *testing.T) {
	h := newMCPHarness(t)
	var decs leylinev1.ListDecodersResponse
	structured(t, h.must(t, "list_decoders", nil), &decs)
	if len(decs.Decoders) != 1 || decs.Decoders[0].Name != "aprs" {
		t.Fatalf("decoders: %v", decs.Decoders)
	}
	// An alias resolves to the canonical decoder, as `ley decode packets` does.
	var job leylinev1.Job
	structured(t, h.must(t, "start_decode_job", map[string]any{"decoder": "packets"}), &job)
	if job.GetDecode().GetDecoder() != "aprs" || job.GetState() != leylinev1.JobState_RUNNING {
		t.Fatalf("job: %v", &job)
	}
	if r := h.call(t, "start_decode_job", map[string]any{"decoder": "morse"}); !r.IsError || !strings.Contains(resultText(r), "list_decoders") {
		t.Errorf("an unknown decoder must be refused and point at list_decoders: %s", resultText(r))
	}
	// list_entities folds the running job's records rather than starting a second decoder.
	time.Sleep(3 * fakedaemon.RecordInterval)
	ent := h.must(t, "list_entities", map[string]any{"protocol": "aprs", "duration_s": 0.5})
	raw, _ := json.Marshal(ent.StructuredContent)
	var snap EntitySnapshot
	if err := json.Unmarshal(raw, &snap); err != nil || len(snap.Entities) == 0 {
		t.Fatalf("entities (%v): %s\n%s", err, raw, resultText(ent))
	}
	if !strings.Contains(resultText(ent), "already running") || !strings.Contains(resultText(ent), snap.Entities[0].DeviceID) {
		t.Errorf("entities text:\n%s", resultText(ent))
	}
	// A kept job writes to the store, which query_records and the resource read. The first
	// job is stopped first: the fake, like the allocator, declines a radio a job is listening on.
	structured(t, h.must(t, "cancel_job", map[string]any{"job": job.JobId}), &job)
	var kept leylinev1.Job
	structured(t, h.must(t, "start_decode_job", map[string]any{"decoder": "aprs", "keep": true}), &kept)
	if len(kept.ResultUris) != 1 || kept.ResultUris[0] != "ley://records/"+kept.JobId {
		t.Fatalf("kept job names no records resource: %v", &kept)
	}
	time.Sleep(3 * fakedaemon.RecordInterval)
	var page leylinev1.RecordPage
	structured(t, h.must(t, "query_records", map[string]any{"job_id": kept.JobId}), &page)
	if len(page.Records) == 0 {
		t.Fatal("the kept job's records are not in the store")
	}
	rr, err := h.cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: kept.ResultUris[0]})
	if err != nil {
		t.Fatalf("read resource: %v", err)
	}
	var viaResource leylinev1.RecordPage
	if err := protojson.Unmarshal([]byte(rr.Contents[0].Text), &viaResource); err != nil || len(viaResource.Records) == 0 {
		t.Errorf("the resource is not the RecordPage (%v): %s", err, rr.Contents[0].Text)
	}
	if _, err := h.cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "ley://records/job_nothing"}); err == nil {
		t.Error("an unknown job's records resource must not be found")
	}
	if r := h.call(t, "query_records", map[string]any{"near": "37.76,-122.42"}); !r.IsError || !strings.Contains(resultText(r), "radius") {
		t.Errorf("near without radius must be refused: %s", resultText(r))
	}
	// Jobs: the list is the verb's, a row number names one, cancel ends it.
	var jobs leylinev1.ListJobsResponse
	structured(t, h.must(t, "list_jobs", nil), &jobs)
	var want leylinev1.ListJobsResponse
	if err := protojson.Unmarshal([]byte(mustRun(t, h.sock, "jobs", "--json")), &want); err != nil {
		t.Fatal(err)
	}
	if len(jobs.Jobs) != 2 || len(want.Jobs) != 2 || jobs.Jobs[0].JobId != want.Jobs[0].JobId {
		t.Errorf("list_jobs != ley jobs --json: %v vs %v", jobs.Jobs, want.Jobs)
	}
	var got leylinev1.Job
	structured(t, h.must(t, "get_job", map[string]any{"job": "1"}), &got)
	if got.JobId != job.JobId {
		t.Errorf("get_job 1 = %s, want %s", got.JobId, job.JobId)
	}
	var final leylinev1.Job
	structured(t, h.must(t, "cancel_job", map[string]any{"job": kept.JobId}), &final)
	if final.State != leylinev1.JobState_CANCELLED {
		t.Errorf("cancel_job left the job %v", final.State)
	}
	if r := h.call(t, "get_job", map[string]any{"job": "job_nope"}); !r.IsError || !strings.Contains(resultText(r), "list_jobs") {
		t.Errorf("an unknown job must point at list_jobs: %s", resultText(r))
	}
}

// daemon_logs is `ley daemon logs` with the daemon's pid and start time in
// front, which is how an agent learns that the daemon it is talking to is
// not the one it started with.
func TestMCPDaemonLogs(t *testing.T) {
	h := newMCPHarness(t)
	log := filepath.Join(t.TempDir(), "leylined.log")
	line := func(n int, msg string) string {
		return fmt.Sprintf("2026-09-17T10:00:0%d+0000 info leyline.daemon: [LeylineDaemon] %s\n", n, msg)
	}
	if err := os.WriteFile(log, []byte(line(1, "one")+line(2, "two")+line(3, "three")), 0o644); err != nil {
		t.Fatal(err)
	}
	h.srv.app.logFile = log
	res := h.must(t, "daemon_logs", map[string]any{"lines": 2})
	text := resultText(res)
	for _, want := range []string{"pid", "up since", "last 2 of 3 daemon lines", "] two\n", "] three"} {
		if !strings.Contains(text, want) {
			t.Errorf("daemon_logs lacks %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "] one\n") {
		t.Errorf("the first line was not asked for:\n%s", text)
	}
	var info leylinev1.DaemonInfo
	structuredField(t, res, "daemon", &info)
	if info.GetPid() == 0 || info.GetStartedAtNs() == 0 {
		t.Errorf("no pid or start time in the structured result: %v", &info)
	}
	raw, _ := json.Marshal(res.StructuredContent)
	if !strings.Contains(string(raw), `"lines":["2026-09-17T10:00:02+0000 info leyline.daemon: [LeylineDaemon] two","2026-09-17T10:00:03+0000 info leyline.daemon: [LeylineDaemon] three"]`) {
		t.Errorf("structured lines: %s", raw)
	}
	h.srv.app.logFile = filepath.Join(t.TempDir(), "missing.log")
	if r := h.call(t, "daemon_logs", nil); !r.IsError || !strings.Contains(resultText(r), "there is no file at") {
		t.Errorf("a missing log must be refused with its path: %s", resultText(r))
	}
	if r := h.call(t, "daemon_logs", map[string]any{"lines": 9999}); !r.IsError {
		t.Error("a whole-file read must be refused")
	}
}

// An empty page cannot tell a quiet band from a decoder that never stored, so
// the text says which it was from the job list.
func TestMCPQueryRecordsExplainsAnEmptyPage(t *testing.T) {
	h := newMCPHarness(t)
	text := resultText(h.must(t, "query_records", map[string]any{"protocol": "aprs"}))
	if !strings.Contains(text, "no kept decode job for aprs has run") {
		t.Errorf("with no jobs:\n%s", text)
	}
	var job leylinev1.Job
	structured(t, h.must(t, "start_decode_job", map[string]any{"decoder": "aprs"}), &job)
	text = resultText(h.must(t, "query_records", map[string]any{"protocol": "aprs"}))
	if !strings.Contains(text, "started without keep") || !strings.Contains(text, job.JobId) {
		t.Errorf("with an unkept job:\n%s", text)
	}
	text = resultText(h.must(t, "query_records", map[string]any{"job_id": job.JobId}))
	if !strings.Contains(text, "job "+job.JobId+" was started without keep") {
		t.Errorf("by job id:\n%s", text)
	}
	text = resultText(h.must(t, "query_records", map[string]any{"job_id": "job_nothing"}))
	if !strings.Contains(text, "lists no job job_nothing") {
		t.Errorf("unknown job:\n%s", text)
	}
	structured(t, h.must(t, "cancel_job", map[string]any{"job": job.JobId}), &job)
	var kept leylinev1.Job
	structured(t, h.must(t, "start_decode_job", map[string]any{"decoder": "aprs", "keep": true}), &kept)
	// Before the fake's first record lands, the kept job is the quiet-band case.
	text = resultText(h.must(t, "query_records", map[string]any{"job_id": kept.JobId, "device_id": "NOBODY"}))
	if !strings.Contains(text, "the kept job "+kept.JobId) || !strings.Contains(text, "filters excluded") || !strings.Contains(text, "listen_summary") {
		t.Errorf("kept job, filtered to nothing:\n%s", text)
	}
}

// The listen fold alone: a close edge with no open before it is the squelch
// having been open when listening began, not a transmission, and a real
// open-then-close is one segment with the meter's mean while open.
func TestListenSummaryFold(t *testing.T) {
	at := func(idx uint64) *leylinev1.SampleTime {
		return &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: idx}
	}
	meter := func(idx uint64, db float64, open bool) *leylinev1.TelemetryMsg {
		return &leylinev1.TelemetryMsg{Time: at(idx), Body: &leylinev1.TelemetryMsg_Meter{Meter: &leylinev1.Meter{PowerDbfs: db, SquelchOpen: open}}}
	}
	edge := func(idx uint64, open bool, dur uint64, peak float64) *leylinev1.TelemetryMsg {
		return &leylinev1.TelemetryMsg{Time: at(idx), Body: &leylinev1.TelemetryMsg_Squelch{Squelch: &leylinev1.SquelchTransition{
			Open: open, DurationSamples: dur, PeakAudioDbfs: peak, PeakSnrDb: 10,
		}}}
	}
	sum := newListenSummary(-40, 2_400_000)
	// The phantom: a close at the noise level, from channel start, before any open.
	sum.apply(meter(1_000, -48, false))
	sum.apply(edge(2_400_000, false, 2_400_000, -48))
	// A real transmission: open, three loud meters, close.
	sum.apply(edge(4_800_000, true, 0, math.NaN()))
	sum.apply(meter(5_000_000, -20, true))
	sum.apply(meter(5_200_000, -22, true))
	sum.apply(meter(5_400_000, -24, true))
	sum.apply(edge(7_200_000, false, 2_400_000, -20))
	sum.finish()
	if !sum.meter.OpenAtStart {
		t.Error("a close with no open before it must be reported as open_at_start")
	}
	segs := sum.transcript.GetSegments()
	if len(segs) != 1 {
		t.Fatalf("want one segment for the real transmission, got %d: %v", len(segs), segs)
	}
	if segs[0].GetStart().GetSampleIndex() != 4_800_000 || segs[0].GetEnd().GetSampleIndex() != 7_200_000 {
		t.Errorf("segment spans %d to %d, want 4800000 to 7200000", segs[0].GetStart().GetSampleIndex(), segs[0].GetEnd().GetSampleIndex())
	}
	if math.Abs(segs[0].GetMeanDbfs()+22) > 0.01 || segs[0].GetPeakDbfs() != -20 {
		t.Errorf("segment mean %.1f peak %.1f, want -22 and -20", segs[0].GetMeanDbfs(), segs[0].GetPeakDbfs())
	}
	if sum.meter.Samples != 4 || math.Abs(sum.meter.SquelchOpenFraction-0.75) > 0.001 || sum.meter.OpenAtEnd {
		t.Errorf("meter stats: %+v", sum.meter)
	}
	text := sum.text(&session{channel: &leylinev1.Channel{}, state: &leylinev1.GetStateResponse{}}, 3*time.Second)
	if !strings.Contains(text, "1 transmission") || !strings.Contains(text, "already open when listening began") {
		t.Errorf("text:\n%s", text)
	}
}

// daemon_logs keeps the daemon's own lines and counts the driver's.
func TestMCPDaemonLogsLeavesTheDriverOut(t *testing.T) {
	h := newMCPHarness(t)
	log := filepath.Join(t.TempDir(), "leylined.log")
	body := "2026-09-17T10:00:00+0000 info leyline.daemon: [LeylineDaemon] listening\n" +
		"Found Rafael Micro R820T tuner\n[R82XX] PLL not locked!\n" +
		"2026-09-17T10:00:02+0000 warning leyline.daemon: [LeylineDaemon] something\n" +
		"Found Rafael Micro R820T tuner\n"
	if err := os.WriteFile(log, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	h.srv.app.logFile = log
	text := resultText(h.must(t, "daemon_logs", nil))
	if strings.Contains(text, "R820T") || !strings.Contains(text, "something") || !strings.Contains(text, "3 lines from the radio driver left out") {
		t.Errorf("driver lines should be left out and counted:\n%s", text)
	}
	text = resultText(h.must(t, "daemon_logs", map[string]any{"include_driver": true}))
	if strings.Count(text, "R820T") != 2 || strings.Contains(text, "left out") {
		t.Errorf("include_driver should show them all:\n%s", text)
	}
}

// scan's min_snr trims the returned Scan as `ley scan --min-snr` trims its
// rows, and the whole sweep stays readable as its ley://scans resource.
func TestMCPScanMinSNRAndTheScansResource(t *testing.T) {
	h := newMCPHarness(t)
	var whole leylinev1.Scan
	structured(t, h.must(t, "scan", map[string]any{"range": "145M..147M"}), &whole)
	res := h.must(t, "scan", map[string]any{"range": "145M..147M", "min_snr": 20})
	var trimmed leylinev1.Scan
	structured(t, res, &trimmed)
	if len(whole.Detections) < 3 || len(trimmed.Detections) >= len(whole.Detections) {
		t.Fatalf("min_snr 20 should drop the 18.7 dB carrier: %d of %d kept", len(trimmed.Detections), len(whole.Detections))
	}
	for _, d := range trimmed.Detections {
		if d.SnrDb < 20 {
			t.Errorf("a %.1f dB detection survived min_snr 20", d.SnrDb)
		}
	}
	if !strings.Contains(resultText(res), "ley://scans/"+trimmed.ScanId) {
		t.Errorf("the text should name the whole scan's resource:\n%s", resultText(res))
	}
	rr, err := h.cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "ley://scans/" + trimmed.ScanId})
	if err != nil {
		t.Fatalf("read the scan resource: %v", err)
	}
	var viaResource leylinev1.Scan
	if err := protojson.Unmarshal([]byte(rr.Contents[0].Text), &viaResource); err != nil || len(viaResource.Detections) != len(whole.Detections) {
		t.Errorf("the resource is not the whole scan (%v): %d detections", err, len(viaResource.Detections))
	}
	if _, err := h.cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "ley://scans/scan_nothing"}); err == nil {
		t.Error("an unknown scan must not be found")
	}
	tmpl, _ := h.cs.ListResourceTemplates(context.Background(), nil)
	if len(tmpl.ResourceTemplates) != 2 {
		t.Errorf("resource templates: %+v", tmpl.ResourceTemplates)
	}
}

// A band wider than the radio captures is shown in part, and the text says
// how much. The fake's radio captures 2.4 MHz at most; the FM band is 20.
func TestMCPSnapshotSaysHowMuchOfABandItCovers(t *testing.T) {
	h := newMCPHarness(t)
	res := h.must(t, "snapshot", map[string]any{"band": "fm", "no_image": true})
	text := resultText(res)
	for _, want := range []string{"this radio captures at most", "of the FM broadcast band's 87.500 MHz to 108.000 MHz", "scan sweeps the rest"} {
		if !strings.Contains(text, want) {
			t.Errorf("text lacks %q:\n%s", want, text)
		}
	}
}

// A daemon that is not running is the ordinary exit-3 line, before any tool.
func TestMCPNeedsADaemon(t *testing.T) {
	sock := testutil.SocketPath(t, "gone.sock")
	app := &App{Socket: sock, Stdout: &bytes.Buffer{}, Stderr: &bytes.Buffer{}, LookupEnv: func(string) (string, bool) { return "", false }}
	_, err := newMCPServer(context.Background(), app)
	if exitCode(err) != ExitNotRunning || !strings.Contains(err.Error(), "not running") {
		t.Errorf("want the exit-3 not-running error, got %v", err)
	}
}

// The tool table in the help text stays the served one.
func TestMCPHelpNamesEveryTool(t *testing.T) {
	out, _, err := runApp(t, helpApp(), "mcp", "--help")
	if err != nil {
		t.Fatal(err)
	}
	for _, name := range mcpToolNames {
		if !strings.Contains(out, name) {
			t.Errorf("ley mcp --help does not name %s", name)
		}
	}
}

// MCP-6: the PNG is the row, one column per bin, with the level ramp on the
// columns above the floor and nothing drawn where the floor is.
func TestRenderSpectrumPNG(t *testing.T) {
	bins := make([]float64, 512)
	for i := range bins {
		bins[i] = -80
	}
	bins[100] = -30 // a carrier 50 dB over the floor
	peaks := loudestBins(bins, 146_520_000, 2_400_000, spectrumPeaks, -80+peakAboveFloorDb)
	data, err := renderSpectrumPNG(bins, -80, 146_520_000, 2_400_000, peaks, 146_520_000)
	if err != nil {
		t.Fatal(err)
	}
	img, err := png.Decode(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if img.Bounds().Dx() != 512+pngGutter || img.Bounds().Dy() != pngTop+pngPlotH+pngAxisH {
		t.Errorf("size %v", img.Bounds())
	}
	// The carrier's column carries the ramp's hot end somewhere; a floor
	// column (one the grid's dashes and the floor line's dots skip) is the
	// bin's own pixel, its shadow, and ground everywhere else.
	hot := false
	for y := 0; y < pngTop+pngPlotH; y++ {
		r, g, b, _ := img.At(pngGutter+100, y).RGBA()
		if r>>8 > 150 && g>>8 < 120 && b>>8 < 120 {
			hot = true
		}
	}
	if !hot {
		t.Error("the carrier's column has no hot ramp pixel")
	}
	lit := 0
	for y := 0; y < pngTop+pngPlotH; y++ {
		r, g, b, _ := img.At(pngGutter+301, y).RGBA()
		if r>>8 != 30 || g>>8 != 30 || b>>8 != 30 {
			lit++
		}
	}
	if lit > 2 {
		t.Errorf("a floor column has %d lit pixels; the floor is drawn as a line, not an area", lit)
	}
	if _, err := renderSpectrumPNG(nil, 0, 0, 0, nil, 0); err != nil {
		t.Errorf("an empty row must still render: %v", err)
	}
}
