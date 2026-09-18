// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The recording tools (docs/design/recording.md, "MCP"): start one, find the
// ones that exist, and get one with its parts' local paths so an agent hands a
// file to another tool by path. Samples are never returned through MCP; a path
// is (docs/design/data-planes.md, "no lossless network stream").

// recordMaxSeconds bounds a recording an agent starts. What an agent begins
// must end without it: a tool call that leaves a radio recording for ever is a
// radio nobody else can use and a disk nobody is watching.
const recordMaxSeconds = 3600

type recordArgs struct {
	Target    string  `json:"target" jsonschema:"what to record: a frequency (a bare number is MHz: 146.52; units are exact: 1010k, 146520000), a preset name such as noaa, or the id of a channel already running (chan_...)"`
	DurationS float64 `json:"duration_s" jsonschema:"how long to record, in seconds (1 to 3600). Required: what an agent starts must end without it"`
	IQ        bool    `json:"iq,omitempty" jsonschema:"record the radio's raw samples (.cf32) instead of demodulated audio; about 19 MB a second at 2.4 MSPS (default: false)"`
	Gate      string  `json:"gate,omitempty" jsonschema:"record only while something is on the air: squelch. Files are one per exchange -- the pauses between overs stay in one file (default: record continuously)"`
	PreRollMs uint32  `json:"pre_roll_ms,omitempty" jsonschema:"audio kept from before each key-up, in milliseconds (default 500; needs gate)"`
	HangMs    uint32  `json:"hang_ms,omitempty" jsonschema:"how long a file stays open after a key-down, in milliseconds, so the pauses between overs stay in one file (default 5000; needs gate)"`
	Mode      string  `json:"mode,omitempty" jsonschema:"how to decode: nfm, wfm, am, usb, lsb, cw (default: chosen from the band); not with a channel id or with iq"`
	Bandwidth string  `json:"bandwidth,omitempty" jsonschema:"channel width: a bare number is kHz (12.5), or 200k, 12500 (default: the mode's usual width)"`
	Squelch   string  `json:"squelch,omitempty" jsonschema:"mute below this level: auto (the default with a gate, measured from the channel's own noise floor), off, or dBFS such as -40"`
	Gain      string  `json:"gain,omitempty" jsonschema:"receiver gain: auto, or dB such as 30 (default: leave the radio's setting)"`
	Device    string  `json:"device,omitempty" jsonschema:"which radio: an id (dev_...), id prefix or row number from list_devices (default: the first real radio)"`
	TakeOver  bool    `json:"take_over,omitempty" jsonschema:"record even when somebody is using the radio (default: false, refuse and say who is using it). Send it only after a refusal named who"`
}

// record starts a recording and waits for it, so the tool returns a recording
// that exists rather than a job an agent has to poll.
func (srv *mcpServer) record(ctx context.Context, _ *mcp.CallToolRequest, in recordArgs) (*mcp.CallToolResult, any, error) {
	if in.DurationS < 1 || in.DurationS > recordMaxSeconds {
		return nil, nil, fmt.Errorf("duration_s is required and must be 1 to %d seconds: a recording an agent starts has to end without it", recordMaxSeconds)
	}
	o := recordOptions{
		iq: in.IQ, forDur: time.Duration(in.DurationS * float64(time.Second)),
		pre: time.Duration(in.PreRollMs) * time.Millisecond, hang: time.Duration(in.HangMs) * time.Millisecond,
		gain: in.Gain, device: in.Device, takeOver: in.TakeOver,
	}
	if err := o.parse(in.Target, in.Gate, "", in.Mode, in.Bandwidth, in.Squelch, "", "", "", ""); err != nil {
		return nil, nil, toolError(err)
	}
	// parse reads the gate flags off strings; the tool takes them as numbers, so they are put
	// back after it and checked the same way.
	if !o.gated && (in.PreRollMs != 0 || in.HangMs != 0) {
		return nil, nil, fmt.Errorf("pre_roll_ms and hang_ms need gate: squelch; without a gate nothing is watching the squelch")
	}
	o.pre = time.Duration(in.PreRollMs) * time.Millisecond
	o.hang = time.Duration(in.HangMs) * time.Millisecond
	o.forDur = time.Duration(in.DurationS * float64(time.Second))

	c := srv.client
	st, err := c.State(ctx)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	if in.Device != "" {
		d, derr := pickDevice(st, in.Device)
		if derr != nil {
			return nil, nil, toolError(derr)
		}
		o.deviceID = d.GetDeviceId()
	}
	cfg := o.config()
	var b strings.Builder
	if !cfg.TakeOver && srv.ownGrace(st, cfg.DeviceId) {
		cfg.TakeOver = true
		b.WriteString(ownGraceNote)
	}
	job, err := c.StartRecord(ctx, cfg)
	if err != nil {
		return nil, nil, toolError(recordToolFailure(err))
	}
	uri := recordURI(job)
	// Wait it out: an agent that had to poll a job would spend two calls learning what one can
	// say. The duration is the bound, with a little slack for the daemon's own teardown.
	final := srv.awaitJob(ctx, job, o.forDur+10*time.Second)
	if final.GetState() == leylinev1.JobState_FAILED {
		return nil, nil, toolError(fmt.Errorf("%s", recordFailureDetail(final)))
	}
	fmt.Fprintf(&b, "%s: %s", final.GetStatusDetail(), uri)
	if m, merr := srv.manifestFor(ctx, job.GetJobId()); merr == nil {
		fmt.Fprintf(&b, "\n%s", recordingSummary(m))
		fmt.Fprintf(&b, "\nget_recording %s gives every part's path on this machine.", job.GetJobId())
	}
	return protoResult(final, b.String())
}

// awaitJob polls the job until it ends or the bound elapses. The event stream
// would do, but a tool call has no session to fold events into and a poll at
// this cadence costs the daemon nothing.
func (srv *mcpServer) awaitJob(ctx context.Context, job *leylinev1.Job, bound time.Duration) *leylinev1.Job {
	deadline := time.Now().Add(bound)
	last := job
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return last
		case <-time.After(250 * time.Millisecond):
		}
		j, err := srv.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: job.GetJobId()})
		if err != nil {
			return last
		}
		last = j
		if !isLiveJob(j) {
			return j
		}
	}
	return last
}

// recordToolFailure keeps the daemon's sentence and names the argument an agent
// has instead of a flag.
func recordToolFailure(err error) error {
	if leyline.Code(err) == leyline.CodeDeviceBusy {
		return fmt.Errorf("%s. take_over: true records anyway, and hands the radio back afterwards", leylineMessage(err, "the radio is busy"))
	}
	return err
}

type findRecordingsArgs struct {
	Kind      string `json:"kind,omitempty" jsonschema:"only audio or iq recordings"`
	Frequency string `json:"frequency,omitempty" jsonschema:"only recordings of this frequency or preset, e.g. 146.52"`
	Mode      string `json:"mode,omitempty" jsonschema:"only recordings in this mode, e.g. NFM"`
	SinceS    int64  `json:"since_s,omitempty" jsonschema:"only recordings started less than this many seconds ago"`
	Limit     int    `json:"limit,omitempty" jsonschema:"at most this many, newest first (default: all of them)"`
}

// findRecordings is Resources.ListResources(RECORDING) with the frozen metadata
// keys as its filters.
func (srv *mcpServer) findRecordings(ctx context.Context, _ *mcp.CallToolRequest, in findRecordingsArgs) (*mcp.CallToolResult, any, error) {
	filter := map[string]string{}
	switch in.Kind {
	case "":
	case "audio", "iq":
		filter["kind"] = in.Kind
	default:
		return nil, nil, fmt.Errorf("kind %q is not a kind of recording; audio and iq are the ones there are", in.Kind)
	}
	if in.Frequency != "" {
		t, err := resolveDial(in.Frequency, "146.52 (MHz)")
		if err != nil {
			return nil, nil, fmt.Errorf("frequency %v", err)
		}
		filter["frequency_hz"] = strconv.FormatUint(t.Hz, 10)
	}
	if in.Mode != "" {
		filter["mode"] = strings.ToUpper(in.Mode)
	}
	found, err := srv.client.ListRecordings(ctx, filter)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	if in.SinceS > 0 {
		cutoff := time.Now().Add(-time.Duration(in.SinceS) * time.Second).UnixNano()
		kept := found[:0]
		for _, r := range found {
			if r.GetCreatedAtNs() >= cutoff {
				kept = append(kept, r)
			}
		}
		found = kept
	}
	if in.Limit > 0 && len(found) > in.Limit {
		found = found[:in.Limit]
	}
	var b strings.Builder
	if len(found) == 0 {
		b.WriteString("no recordings match; record makes one.")
	}
	for _, r := range found {
		m := r.GetMetadata()
		hz, _ := strconv.ParseUint(m["frequency_hz"], 10, 64)
		fmt.Fprintf(&b, "%s  %s %s  %s in %s parts  %s\n", r.GetOriginatingJobId(),
			leyline.FormatFrequency(hz), strings.TrimSpace(m["mode"]+" "+m["kind"]),
			recordingLength(m["duration_ms"]), m["parts"], recordingSize(r.GetSizeBytes()))
	}
	return protoResult(&leylinev1.ListResourcesResponse{Resources: found}, b.String())
}

type getRecordingArgs struct {
	ID string `json:"id" jsonschema:"the recording: a job id from find_recordings or record, or a ley://recordings/ uri"`
}

// getRecording is GetResource plus ResolveLocalPath: the manifest with every
// part's local path, so an agent hands a file to another tool by path.
func (srv *mcpServer) getRecording(ctx context.Context, _ *mcp.CallToolRequest, in getRecordingArgs) (*mcp.CallToolResult, any, error) {
	jobID, _, ok := leyline.ParseRecordingURI(in.ID)
	if !ok {
		jobID = in.ID
	}
	if jobID == "" {
		return nil, nil, fmt.Errorf("id is required: a job id from find_recordings, or a ley://recordings/ uri")
	}
	m, err := srv.manifestFor(ctx, jobID)
	if err != nil {
		return nil, nil, toolError(err)
	}
	dir, err := srv.client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		return nil, nil, toolError(err)
	}
	// The manifest as the daemon wrote it, with each part's path added: the
	// samples stay on disk and the agent is handed where they are.
	doc := map[string]any{"manifest": m, "directory": dir}
	paths := make([]map[string]any, 0, len(m.Parts))
	for _, p := range m.Parts {
		paths = append(paths, map[string]any{"part": p.Part, "path": filepath.Join(dir, p.File), "samples": p.Samples})
	}
	doc["parts"] = paths
	raw, err := json.Marshal(doc)
	if err != nil {
		return nil, nil, err
	}
	var b strings.Builder
	b.WriteString(recordingSummary(m))
	fmt.Fprintf(&b, "\n%s\nThe samples are files on the daemon's machine; this returns their paths, never their bytes.", dir)
	return jsonResult(b.String(), raw), nil, nil
}

// manifestFor reads a recording's manifest through the daemon's own path, so a
// recording the daemon does not have is a refusal rather than a missing file.
func (srv *mcpServer) manifestFor(ctx context.Context, jobID string) (*leyline.RecordingManifest, error) {
	dir, err := srv.client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		if leyline.Code(err) == leyline.CodeJobNotFound {
			return nil, fmt.Errorf("no recording called %s; find_recordings lists the ones the daemon has", jobID)
		}
		return nil, err
	}
	return leyline.ReadRecordingManifest(dir)
}

// recordingSummary is the sentence a person would read off `ley recordings show`.
func recordingSummary(m *leyline.RecordingManifest) string {
	var b strings.Builder
	what := m.Kind
	if m.Kind == "audio" && m.Mode != "" {
		what = m.Mode + " audio"
	}
	fmt.Fprintf(&b, "%s %s, %s of signal in %s, %s",
		what, leyline.FormatFrequency(m.FrequencyHz),
		forPhrase(time.Duration(m.DurationMs())*time.Millisecond),
		plural(len(m.Parts), "part"), recordingSize(m.Bytes))
	if m.Gate != nil {
		fmt.Fprintf(&b, "; the squelch opened %s", plural(m.SquelchOpens(), "time"))
	}
	if len(m.Gaps) > 0 {
		fmt.Fprintf(&b, "; %s where nothing was recorded", plural(len(m.Gaps), "gap"))
	}
	if m.EndedBy != "" {
		fmt.Fprintf(&b, "; ended by %s", m.EndedBy)
	}
	return b.String()
}

// readRecordingResource serves ley://recordings/<job_id> as the manifest JSON.
func (srv *mcpServer) readRecordingResource(ctx context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
	uri := req.Params.URI
	jobID, _, ok := leyline.ParseRecordingURI(uri)
	if !ok {
		return nil, mcp.ResourceNotFoundError(uri)
	}
	dir, err := srv.client.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		if leyline.Code(err) == leyline.CodeJobNotFound {
			return nil, mcp.ResourceNotFoundError(uri)
		}
		return nil, toolError(err)
	}
	raw, err := os.ReadFile(filepath.Join(dir, "recording.json"))
	if err != nil {
		return nil, mcp.ResourceNotFoundError(uri)
	}
	return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{
		{URI: uri, MIMEType: "application/json", Text: string(raw)},
	}}, nil
}
