// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// mcpSession spawns `ley mcp` the way an agent's client does -- as a
// subprocess speaking MCP on stdin and stdout -- against the test daemon.
func (e *env) mcpSession(t *testing.T) *mcp.ClientSession {
	t.Helper()
	client := mcp.NewClient(&mcp.Implementation{Name: "e2e", Version: "0"}, nil)
	cmd := exec.Command(e.ley, "--socket", e.socket, "mcp")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cs, err := client.Connect(context.Background(), &mcp.CommandTransport{Command: cmd}, nil)
	if err != nil {
		t.Fatalf("connect to ley mcp: %v\n%s", err, stderr.String())
	}
	t.Cleanup(func() {
		_ = cs.Close()
		if t.Failed() {
			t.Logf("ley mcp stderr:\n%s", stderr.String())
		}
	})
	return cs
}

// callTool runs one tool and returns its structured content as a generic
// JSON value plus its text, failing the test on a tool error.
func callTool(t *testing.T, cs *mcp.ClientSession, name string, args map[string]any) (any, string) {
	t.Helper()
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("%s: %v", name, err)
	}
	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	if res.IsError {
		t.Fatalf("%s %v: %s", name, args, text.String())
	}
	return res.StructuredContent, text.String()
}

// TestMCPAgainstRealDaemon is docs/plans/mcp.md's end-to-end check: the adapter
// spawned as an MCP client would spawn it, driving the real daemon over the
// same socket `ley` uses, on the scan_band fixture. The tools' answers are
// held against the verbs' `--json`, which is the compatibility test the plan
// names: an agent and a shell script read identical shapes.
func TestMCPAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	band, err := filepath.Abs("../../../fixtures/scan_band.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(band); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	// The recording is attached as a radio and left idle, as the scan e2e does.
	e.mustRun("play", band, "--no-audio", "--loop", "--persistent", "--json")
	e.mustRun("stop", "--all")
	devs := testDevices(list(parseJSON(t, e.mustRun("devices", "--json")), "devices"))
	if len(devs) != 1 {
		t.Fatalf("devices: want the file device alone, got %v", devs)
	}
	devID := devs[0]["deviceId"].(string)

	cs := e.mcpSession(t)
	tools, err := cs.ListTools(context.Background(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(tools.Tools) < 13 {
		t.Errorf("only %d tools listed", len(tools.Tools))
	}

	// list_devices is `ley devices --json`, byte for byte once both are canonical JSON.
	got, _ := callTool(t, cs, "list_devices", nil)
	if want := parseJSON(t, e.mustRun("devices", "--json")); !jsonEqual(got, want) {
		t.Errorf("list_devices != ley devices --json:\n%v\n%v", got, want)
	}

	// scan finds the fixture's carriers, the same four the scan e2e checks.
	scan, scanText := callTool(t, cs, "scan", map[string]any{"range": "145.0M..147.0M", "dwell_ms": 500, "device": devID})
	sm := scan.(map[string]any)
	var found []uint64
	for _, d := range list(sm, "detections") {
		hz, _ := strconv.ParseUint(d.(map[string]any)["centerHz"].(string), 10, 64)
		found = append(found, hz)
	}
	for _, want := range []uint64{145_200_000, 145_600_000, 146_400_000, 146_800_000} {
		if !near(found, want, 30_000) {
			t.Errorf("scan missed the carrier at %d Hz: found %v\n%s", want, found, scanText)
		}
	}
	if !strings.Contains(scanText, "FREQUENCY") || !strings.Contains(scanText, "floor") {
		t.Errorf("scan text is not the verb's summary:\n%s", scanText)
	}

	// snapshot: the row shape of `ley spectrum --json`, and a PNG one pixel per bin. A recording
	// tunes only its own centre, so the capture is made there and the carriers sit inside it.
	res, err := cs.CallTool(context.Background(), &mcp.CallToolParams{Name: "snapshot", Arguments: map[string]any{"frequency": "146.0", "device": devID, "bins": 512}})
	if err != nil || res.IsError {
		var text string
		if res != nil {
			for _, c := range res.Content {
				if tc, ok := c.(*mcp.TextContent); ok {
					text += tc.Text
				}
			}
		}
		t.Fatalf("snapshot: %v %s", err, text)
	}
	row := res.StructuredContent.(map[string]any)
	if bins := list(row, "bins"); len(bins) != 512 || row["floor_db"] == nil || row["peaks"] == nil {
		t.Errorf("snapshot row: %d bins, floor %v, peaks %v", len(bins), row["floor_db"], row["peaks"])
	}
	var img *mcp.ImageContent
	for _, c := range res.Content {
		if ic, ok := c.(*mcp.ImageContent); ok {
			img = ic
		}
	}
	if img == nil {
		t.Fatal("snapshot returned no image")
	}
	if decoded, err := png.Decode(bytes.NewReader(img.Data)); err != nil || decoded.Bounds().Dx() != 512+48 {
		t.Errorf("snapshot PNG: %v, bounds %v", err, decoded.Bounds())
	}
	peakHz := []uint64{}
	for _, p := range list(row, "peaks") {
		peakHz = append(peakHz, uint64(p.(map[string]any)["center_hz"].(float64)))
	}
	if !near(peakHz, 146_400_000, 30_000) {
		t.Errorf("the strong carrier at 146.4 MHz is not among the peaks: %v", peakHz)
	}

	// tune: the channel is attributed to the adapter and lives while the server does.
	tuned, tuneText := callTool(t, cs, "tune", map[string]any{"frequency": "146.0", "device": devID, "mode": "nfm"})
	ch := tuned.(map[string]any)["channel"].(map[string]any)
	if owner, _ := ch["owner"].(map[string]any); owner["kind"] != "mcp" {
		t.Errorf("channel owner %v, want kind mcp", ch["owner"])
	}
	if !strings.Contains(tuneText, "channel "+ch["channelId"].(string)) {
		t.Errorf("tune text does not name the channel:\n%s", tuneText)
	}
	if chans := list(e.state(), "channels"); len(chans) != 1 {
		t.Fatalf("after tune: %v", chans)
	}

	// listen_summary on the strong carrier, inside the capture tune made: the meter runs on a
	// real channel, and that channel is gone afterwards while tune's stays.
	sum, sumText := callTool(t, cs, "listen_summary", map[string]any{"target": "146.4", "device": devID, "duration_s": 2, "mode": "nfm", "squelch": "off"})
	meter := sum.(map[string]any)["meter"].(map[string]any)
	if meter["samples"].(float64) == 0 {
		t.Errorf("no meter samples in 2 s:\n%s", sumText)
	}
	if chans := list(e.state(), "channels"); len(chans) != 1 {
		t.Errorf("listen_summary left a channel, or took tune's: %v", chans)
	}
	jobs, _ := callTool(t, cs, "list_jobs", nil)
	if js := list(jobs.(map[string]any), "jobs"); len(js) != 1 || js[0].(map[string]any)["state"] != "COMPLETED" {
		t.Errorf("list_jobs: %v", js)
	}
	// The conversation ends: the daemon tears the adapter's channel down after its presence grace.
	_ = cs.Close()
	deadline := time.Now().Add(10 * time.Second)
	for len(list(e.state(), "channels")) != 0 && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if chans := list(e.state(), "channels"); len(chans) != 0 {
		t.Errorf("the adapter's channel outlived it: %v", chans)
	}
}

// TestMCPDecodeAgainstRealDaemon is MCP-4's end-to-end: the real daemon plays
// the AFSK fixture and runs the real APRS plugin; the decoder tools see its
// records. LEYLINE_DECODERS and leydec-aprs on PATH, as `make e2e` sets them.
func TestMCPDecodeAgainstRealDaemon(t *testing.T) {
	decoders := os.Getenv("LEYLINE_DECODERS")
	if decoders == "" {
		t.Skip("set LEYLINE_DECODERS to the repository's decoders/ directory (make e2e does)")
	}
	fixture, err := filepath.Abs("../../../fixtures/aprs_afsk.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	store := filepath.Join(t.TempDir(), "store")
	e, _ := setup(t, "--store", store, "--decoders", decoders)
	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	e.waitChannels(1)

	cs := e.mcpSession(t)
	decs, _ := callTool(t, cs, "list_decoders", nil)
	if want := parseJSON(t, e.mustRun("decoders", "--json")); !jsonEqual(decs, want) {
		t.Errorf("list_decoders != ley decoders --json")
	}
	job, jobText := callTool(t, cs, "start_decode_job", map[string]any{"decoder": "aprs", "keep": true})
	jobID := job.(map[string]any)["jobId"].(string)
	if !strings.Contains(jobText, "ley://records/"+jobID) {
		t.Errorf("a kept job's text should name its records resource:\n%s", jobText)
	}
	// The fixture carries three packets a second or so apart; the entity fold sees all three
	// stations once they have been decoded, and the store has their records.
	ents, entText := callTool(t, cs, "list_entities", map[string]any{"protocol": "aprs", "duration_s": 6})
	stations := map[string]bool{}
	for _, en := range list(ents.(map[string]any), "entities") {
		stations[en.(map[string]any)["device_id"].(string)] = true
	}
	for _, id := range []string{"LEYTST-1", "LEYTST-2", "LEYTST-3"} {
		if !stations[id] {
			t.Errorf("list_entities did not hear %s: %v\n%s", id, stations, entText)
		}
	}
	page, pageText := callTool(t, cs, "query_records", map[string]any{"job_id": jobID})
	if recs := list(page.(map[string]any), "records"); len(recs) == 0 {
		t.Errorf("query_records returned nothing for the kept job:\n%s", pageText)
	} else if recs[0].(map[string]any)["protocol"] != "aprs" {
		t.Errorf("record: %v", recs[0])
	}
	if want := parseJSON(t, e.mustRun("records", "--json", "--job-id", jobID)); len(list(want, "records")) != len(list(page.(map[string]any), "records")) {
		t.Errorf("query_records and ley records disagree on the count")
	}
	rr, err := cs.ReadResource(context.Background(), &mcp.ReadResourceParams{URI: "ley://records/" + jobID})
	if err != nil || len(rr.Contents) != 1 || !strings.Contains(rr.Contents[0].Text, `"records"`) {
		t.Errorf("records resource: %v %v", err, rr)
	}
	final, _ := callTool(t, cs, "cancel_job", map[string]any{"job": jobID})
	if final.(map[string]any)["state"] != "CANCELLED" {
		t.Errorf("cancel_job: %v", final)
	}
}

// jsonEqual compares two JSON values after a round trip through encoding/json,
// so a map from one source and a decoded message from another compare alike.
func jsonEqual(a, b any) bool {
	ab, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return bytes.Equal(ab, bb)
}

// near reports whether some value in vals is within tol of want.
func near(vals []uint64, want, tol uint64) bool {
	for _, v := range vals {
		if v+tol >= want && v <= want+tol {
			return true
		}
	}
	return false
}
