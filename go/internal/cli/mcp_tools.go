// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
	"github.com/dpup/leysdr/go/pkg/records"
)

// The tool table of docs/plans/mcp.md, in the order an agent reads it: orient,
// control, observe, decode, jobs. Each tool names the RPC it maps onto and the
// `ley` verb that mirrors it, and returns that verb's `--json` shape. The
// blocked tools of the plan (find_recordings, get_transcript, identify_signal,
// lookup_identity, whats_out_there) are not registered: a tool that only
// refuses spends an agent's context on nothing, and the server's instructions
// say what is not here yet.
func (srv *mcpServer) registerTools() {
	s := srv.server
	readOnly := &mcp.ToolAnnotations{ReadOnlyHint: true, OpenWorldHint: boolPtr(false)}
	mutates := &mcp.ToolAnnotations{DestructiveHint: boolPtr(false), OpenWorldHint: boolPtr(false)}

	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_devices",
		Description: "List the radios the daemon can see, with their state, tuning ranges and gain elements (Control.ListDevices; ley devices). Returns a ListDevicesResponse.",
		Annotations: readOnly,
	}, srv.listDevices)
	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_state",
		Description: "Everything the daemon holds right now: devices, captures (a radio tuned to a band), channels (a station picked out of a capture), sinks and jobs (Control.GetState; ley state). Read this to orient before tuning or scanning. Returns a GetStateResponse.",
		Annotations: readOnly,
	}, srv.getState)
	mcp.AddTool(s, &mcp.Tool{
		Name: "tune",
		Description: "Tune a radio to a frequency or preset and open a channel there, the way 'ley tune' does: the mode is chosen from the band unless given, and the squelch is measured from the noise floor for voice modes. " +
			"Refuses to move a radio other channels are listening on and says who, unless take_over is true. The channel ends when this server exits unless keep is true. " +
			"Returns {capture: Capture, channel: Channel, sink: Sink|null}; the text lists the decisions made.",
		Annotations: mutates,
	}, srv.tune)
	mcp.AddTool(s, &mcp.Tool{
		Name: "scan",
		Description: "Sweep a frequency range and report the carriers that stood above the measured noise floor: centre, width, SNR and how many looks saw each (Jobs.StartJob(ScanConfig{once}) then Jobs.GetScan; ley scan). " +
			"A detection is a carrier, not a protocol or a station. Takes seconds and owns the radio meanwhile; refuses a radio somebody is using unless take_over is true. Returns a Scan.",
		Annotations: mutates,
	}, srv.scan)
	mcp.AddTool(s, &mcp.Tool{
		Name: "listen_summary",
		Description: "Listen on a frequency, preset or existing channel for duration_s seconds and summarise what the daemon's squelch and meter saw: the transmissions (squelch-open intervals with their length and peak), the signal level range, and any CTCSS tone (Telemetry.Subscribe, bounded; ley tune / ley listen). " +
			"No audio is returned or played. Returns {channel: Channel, transcript: Transcript, meter: {...}, tone: SubAudible|null}.",
		Annotations: mutates,
	}, srv.listenSummary)
	mcp.AddTool(s, &mcp.Tool{
		Name: "snapshot",
		Description: "One spectrum row of the band around a frequency (or a named band, or whatever the radio is already tuned to) as a PNG chart and as numbers: bins in dBFS, the noise floor, and the loudest local maxima (Bulk.Subscribe(FFT), one row; ley spectrum --json). " +
			"Peaks are presentation, never called signals; scan is the honest detector. Returns {seq, sample_index, center_hz, span_hz, bins, floor_db, peaks}.",
		Annotations: mutates,
	}, srv.snapshot)
	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_decoders",
		Description: "The decoder plugins the daemon has installed: name, aliases, what each tunes (recipe) and what it produces (Decoders.ListDecoders; ley decoders). Returns a ListDecodersResponse.",
		Annotations: readOnly,
	}, srv.listDecoders)
	mcp.AddTool(s, &mcp.Tool{
		Name: "query_records",
		Description: "Search the records kept decode jobs have written, newest first: who transmitted, what kind of record, what it said, with the anchors that date them (Decoders.QueryRecords; ley records). " +
			"Only jobs started with keep write to the store. Returns a RecordPage; the text renders one line per record.",
		Annotations: readOnly,
	}, srv.queryRecords)
	mcp.AddTool(s, &mcp.Tool{
		Name: "list_entities",
		Description: "One row per transmitter a protocol is hearing: last heard, how many records, last position and what it last said (Decoders.SubscribeRecords folded client-side; ley track). " +
			"Uses a decode job already running for the protocol, else starts one for the call and stops it after; listens for duration_s seconds. Returns {entities: [...]}, the shape 'ley track --json' prints.",
		Annotations: mutates,
	}, srv.listEntities)
	mcp.AddTool(s, &mcp.Tool{
		Name: "start_decode_job",
		Description: "Start a decoder on its recipe's frequency (Jobs.StartJob(DecodeConfig); ley decode). The daemon finds or makes the capture and refuses a radio somebody is using unless take_over is true. " +
			"Without keep the job ends when this server exits and its records reach list_entities only; with keep it runs on and its records are stored for query_records. Returns a Job.",
		Annotations: mutates,
	}, srv.startDecodeJob)
	mcp.AddTool(s, &mcp.Tool{
		Name:        "list_jobs",
		Description: "The daemon's background work -- sweeps, decode jobs, watches -- with state and progress (Jobs.ListJobs; ley jobs). Returns a ListJobsResponse.",
		Annotations: readOnly,
	}, srv.listJobs)
	mcp.AddTool(s, &mcp.Tool{
		Name:        "get_job",
		Description: "One job by id, id prefix or row number in list_jobs (Jobs.GetJob; ley jobs). Returns a Job.",
		Annotations: readOnly,
	}, srv.getJob)
	mcp.AddTool(s, &mcp.Tool{
		Name:        "cancel_job",
		Description: "Stop a job and hand the radio back (Jobs.CancelJob; ley jobs cancel). A job that has already finished is left as it is. Returns the Job in the state the daemon left it.",
		Annotations: &mcp.ToolAnnotations{DestructiveHint: boolPtr(true), OpenWorldHint: boolPtr(false)},
	}, srv.cancelJob)
}

// registerResources exposes the one ley:// resource with a store behind it
// today: a kept decode job's records. Recordings, scans and snapshots become
// resources with the Resources service (docs/plans/mcp.md, MCP-7).
func (srv *mcpServer) registerResources() {
	srv.server.AddResourceTemplate(&mcp.ResourceTemplate{
		URITemplate: "ley://records/{job_id}",
		Name:        "records",
		Title:       "A kept decode job's records",
		Description: "The records a decode job started with keep has written, newest first, as a RecordPage (proto3 JSON): the same page query_records returns for job_id.",
		MIMEType:    "application/json",
	}, srv.readRecordsResource)
}

// ---------- orient ----------

func (srv *mcpServer) listDevices(ctx context.Context, _ *mcp.CallToolRequest, _ mcpNoArgs) (*mcp.CallToolResult, any, error) {
	resp, err := srv.client.Control.ListDevices(ctx, &leylinev1.ListDevicesRequest{})
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	var b strings.Builder
	for _, d := range resp.GetDevices() {
		b.WriteString(deviceSummary(ui.Style{}, d) + "\n")
	}
	if len(resp.GetDevices()) == 0 {
		b.WriteString(noDeviceChecklist + "\n")
	}
	return protoResult(resp, b.String())
}

func (srv *mcpServer) getState(ctx context.Context, _ *mcp.CallToolRequest, _ mcpNoArgs) (*mcp.CallToolResult, any, error) {
	st, err := srv.client.State(ctx)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	app, out, _ := srv.toolApp()
	printState(app, st, false)
	return protoResult(st, out.String())
}

// ---------- control ----------

type tuneArgs struct {
	Frequency string `json:"frequency" jsonschema:"where to listen: a frequency (a bare number is MHz: 146.52; units are exact: 1010k, 146520000) or a preset name such as noaa, calling or ch1"`
	Mode      string `json:"mode,omitempty" jsonschema:"how to decode: nfm, wfm, am, usb, lsb, cw, raw; fm or ssb pick by frequency (default: chosen from the band)"`
	Bandwidth string `json:"bandwidth,omitempty" jsonschema:"channel width: a bare number is kHz (12.5), or 200k, 12500 (default: the mode's usual width)"`
	Squelch   string `json:"squelch,omitempty" jsonschema:"mute below this level: auto (measured from the noise floor; the default for nfm and am), off, or dBFS such as -40"`
	Gain      string `json:"gain,omitempty" jsonschema:"receiver gain: auto, or dB such as 30 (default: leave the radio's setting)"`
	Device    string `json:"device,omitempty" jsonschema:"which radio: an id (dev_...), id prefix or row number from list_devices (default: the first real radio)"`
	Audio     bool   `json:"audio,omitempty" jsonschema:"also play the channel through the speakers of the machine the daemon runs on (default: false)"`
	Keep      bool   `json:"keep,omitempty" jsonschema:"leave the channel running after this server exits (default: false; the channel ends with the agent's session)"`
	TakeOver  bool   `json:"take_over,omitempty" jsonschema:"move the radio even when other channels are listening on it; they fall silent (default: false, refuse and say who is listening)"`
}

func (srv *mcpServer) tune(ctx context.Context, _ *mcp.CallToolRequest, in tuneArgs) (*mcp.CallToolResult, any, error) {
	hz, def, err := resolveTuneTarget(in.Frequency)
	if err != nil {
		return nil, nil, toolError(err)
	}
	f := tuneFlags{
		mode: in.Mode, bw: in.Bandwidth, squelch: in.Squelch, gain: in.Gain, device: in.Device,
		volume: "1", noAudio: !in.Audio, persistent: in.Keep, retune: in.TakeOver,
	}
	o, err := f.parse(in.Frequency, hz, def)
	if err != nil {
		return nil, nil, toolError(err)
	}
	app, out, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	// The session is closed, not torn down: the channel it made stays up on
	// the presence this server holds (keepPresence), and a kept one is
	// persistent on the daemon and needs nobody.
	defer s.close()
	s.proseToStderr = true
	s.takeOverHint = takeOverHint
	if s.device, err = pickDevice(s.state, o.device); err != nil {
		return nil, nil, toolError(err)
	}
	if err := refuseRetune(s, o.freq, o.bw, o.retune); err != nil {
		return nil, nil, err
	}
	if err := s.bringUp(ctx, o); err != nil {
		return nil, nil, toolError(err)
	}
	if s.squelchNote != "" {
		fmt.Fprintln(app.Stderr, s.squelchNote)
	}
	fmt.Fprintf(app.Stdout, "listening to %s (%s) on %s: channel %s on capture %s.\n",
		leyline.FormatFrequency(o.freq), strings.ToUpper(leyline.ModeName(o.mode)), deviceName(s.device),
		s.channel.GetChannelId(), s.capture.GetCaptureId())
	switch {
	case in.Keep:
		fmt.Fprintln(app.Stdout, "kept: it runs on after this server exits; cancel it with 'ley stop'.")
	default:
		fmt.Fprintln(app.Stdout, "it ends when this server exits; keep: true would leave it running.")
	}
	raw, err := composite(map[string]any{"capture": s.capture, "channel": s.channel, "sink": sinkOrNil(s.sink)})
	if err != nil {
		return nil, nil, err
	}
	return textResult(errb.String() + out.String()), raw, nil
}

// sinkOrNil is a sink for composite, or JSON null when there is none: a typed
// nil pointer is still a proto.Message and would marshal as an empty object.
func sinkOrNil(sink *leylinev1.Sink) any {
	if sink == nil {
		return nil
	}
	return sink
}

// takeOverHint is the remedy the tools' retune refusal ends with, in place of
// the `--retune` flag `ley tune` names: an agent has arguments, not flags.
const takeOverHint = "Call again with take_over: true to move it anyway, or stop what is listening first"

// refuseRetune is the don't-disturb refusal made adapter-side, as
// docs/design/semantic-tier.md asks ("belt and suspenders"): when the radio
// is tuned somewhere the frequency does not fit and channels are listening
// on it, refuse and name them before anything is written. ensureCapture
// refuses again with the daemon's picture if this one is stale.
func refuseRetune(s *session, freq uint64, bw uint32, takeOver bool) error {
	if takeOver || s.device == nil {
		return nil
	}
	cap := leyline.FindCapture(s.state, s.device.DeviceId)
	if cap == nil || covers(cap, freq, bw) {
		return nil
	}
	var who []string
	for _, ch := range s.state.GetChannels() {
		if ch.GetCaptureId() != cap.GetCaptureId() || ch.GetState() != leylinev1.ChannelState_CHANNEL_ACTIVE {
			continue
		}
		hz := uint64(int64(cap.GetCenterHz()) + ch.GetOffsetHz())
		who = append(who, fmt.Sprintf("%s (%s, %s)", ch.GetChannelId(), leyline.FormatFrequency(hz), clientLabel(ch.GetOwner())))
	}
	if len(who) == 0 {
		return nil
	}
	return fmt.Errorf("the radio is on %s with %s listening: %s. Retuning to %s would silence %s. %s",
		leyline.FormatFrequency(cap.GetCenterHz()), plural(len(who), "channel"), strings.Join(who, ", "),
		leyline.FormatFrequency(freq), themOrIt(len(who)), takeOverHint)
}

// ---------- observe ----------

type scanArgs struct {
	Range    string  `json:"range" jsonschema:"a frequency range such as 144M..148M or 462.5M..462.75M, or a band name such as 2m, gmrs, airband, noaa"`
	DwellMs  uint32  `json:"dwell_ms,omitempty" jsonschema:"milliseconds to listen at each stop; longer finds weaker signals (default: the daemon's 250)"`
	MinSNR   float64 `json:"min_snr,omitempty" jsonschema:"leave out detections weaker than this many dB over the noise floor (default: 0, report everything found)"`
	Device   string  `json:"device,omitempty" jsonschema:"which radio: an id, id prefix or row number from list_devices (default: the daemon picks an idle one)"`
	TakeOver bool    `json:"take_over,omitempty" jsonschema:"sweep even when somebody is using the radio; it is theirs again afterwards (default: false)"`
}

func (srv *mcpServer) scan(ctx context.Context, _ *mcp.CallToolRequest, in scanArgs) (*mcp.CallToolResult, any, error) {
	o := scanOptions{dwellMs: in.DwellMs, minSNR: in.MinSNR, takeOver: in.TakeOver, device: in.Device}
	if lo, hi, rerr := leyline.ParseUserRange(in.Range); rerr == nil {
		o.minHz, o.maxHz, o.rangeInput = lo, hi, in.Range
	} else if b, berr := leyline.ResolveBand(in.Range); berr == nil {
		o.minHz, o.maxHz, o.rangeInput, o.bandName = b.MinHz, b.MaxHz, b.Name, b.Name
	} else {
		return nil, nil, fmt.Errorf("%v, and no band called %q; list_devices says what the radio tunes and ley bands the band names", rerr, in.Range)
	}
	app, out, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.close()
	s.proseToStderr = true
	if o.device != "" {
		d, derr := pickDevice(s.state, o.device)
		if derr != nil {
			return nil, nil, toolError(derr)
		}
		o.deviceID = d.DeviceId
	}
	scan, _, err := s.sweep(ctx, o)
	if err != nil {
		return nil, nil, toolError(scanToolFailure(err))
	}
	if scan == nil {
		return nil, nil, errors.New(strings.TrimSpace(errb.String()))
	}
	errb.Reset()
	printScan(app, scan, o)
	return protoResult(scan, out.String()+errb.String())
}

// scanToolFailure rewrites the one remedy scanFailure phrases as a flag.
func scanToolFailure(err error) error {
	var ee *ExitError
	if errors.As(err, &ee) && strings.Contains(ee.Message, "ley scan --take-over") {
		return errors.New(strings.Replace(ee.Message, "ley scan --take-over sweeps anyway", "take_over: true sweeps anyway", 1))
	}
	return err
}

type listenSummaryArgs struct {
	Target    string  `json:"target" jsonschema:"what to listen to: a frequency (a bare number is MHz), a preset name, or the id of a channel already running (chan_...)"`
	DurationS float64 `json:"duration_s,omitempty" jsonschema:"how long to listen, in seconds (default 10, at most 300)"`
	Mode      string  `json:"mode,omitempty" jsonschema:"how to decode: nfm, wfm, am, usb, lsb, cw (default: chosen from the band); not with a channel id"`
	Bandwidth string  `json:"bandwidth,omitempty" jsonschema:"channel width: a bare number is kHz, or 200k, 12500 (default: the mode's usual width); not with a channel id"`
	Squelch   string  `json:"squelch,omitempty" jsonschema:"auto (the default for nfm and am: a transmission is a squelch-open interval, so a squelch is what makes one countable), off, or dBFS such as -40; not with a channel id"`
	Gain      string  `json:"gain,omitempty" jsonschema:"receiver gain: auto, or dB such as 30 (default: leave it); not with a channel id"`
	Device    string  `json:"device,omitempty" jsonschema:"which radio: an id, id prefix or row number from list_devices (default: the first real radio)"`
	TakeOver  bool    `json:"take_over,omitempty" jsonschema:"move the radio even when other channels are listening on it (default: false, refuse and say who)"`
}

// listenMaxSeconds bounds a listen_summary, because a tool call that runs for
// an hour is a hung agent, not a watch; a watch is a job (Milestone D.15).
const listenMaxSeconds = 300

// meterStats is the listen_summary's reading of the meter: a client-side
// statistic over the daemon's Meter telemetry (presentation, as `ley scope
// --json`'s numbers are), so it has no proto message and is snake_case. A
// level that was never measured, and a squelch that is off, are null: JSON
// has no NaN, and 0 dBFS is a real, very loud level.
type meterStats struct {
	Samples             int     `json:"samples"`
	MinPowerDbfs        float64 `json:"min_power_dbfs"`
	MaxPowerDbfs        float64 `json:"max_power_dbfs"`
	MeanPowerDbfs       float64 `json:"mean_power_dbfs"`
	SquelchOpenFraction float64 `json:"squelch_open_fraction"`
	SquelchDb           float64 `json:"squelch_db"`
	OpenAtEnd           bool    `json:"open_at_end"`
}

// MarshalJSON writes NaN and infinities as null, which encoding/json refuses to
// do on its own.
func (m meterStats) MarshalJSON() ([]byte, error) {
	num := func(f float64) any {
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return nil
		}
		return f
	}
	return json.Marshal(map[string]any{
		"samples":               m.Samples,
		"min_power_dbfs":        num(m.MinPowerDbfs),
		"max_power_dbfs":        num(m.MaxPowerDbfs),
		"mean_power_dbfs":       num(m.MeanPowerDbfs),
		"squelch_open_fraction": m.SquelchOpenFraction,
		"squelch_db":            num(m.SquelchDb),
		"open_at_end":           m.OpenAtEnd,
	})
}

func (srv *mcpServer) listenSummary(ctx context.Context, _ *mcp.CallToolRequest, in listenSummaryArgs) (*mcp.CallToolResult, any, error) {
	dur := time.Duration(in.DurationS * float64(time.Second))
	if in.DurationS <= 0 {
		dur = 10 * time.Second
	}
	if dur > listenMaxSeconds*time.Second {
		return nil, nil, fmt.Errorf("duration_s is at most %d: a longer watch is a job, not a tool call", listenMaxSeconds)
	}
	var (
		channelID string
		o         *tuneOptions
	)
	if strings.HasPrefix(in.Target, tapChannelPrefix) {
		if in.Mode != "" || in.Bandwidth != "" || in.Squelch != "" || in.Gain != "" || in.Device != "" {
			return nil, nil, fmt.Errorf("mode, bandwidth, squelch, gain and device cannot be given with a channel id: %s already has its settings", in.Target)
		}
		channelID = in.Target
	} else {
		hz, def, err := resolveTuneTarget(in.Target)
		if err != nil {
			return nil, nil, toolError(err)
		}
		f := tuneFlags{mode: in.Mode, bw: in.Bandwidth, squelch: in.Squelch, gain: in.Gain, device: in.Device, volume: "1", noAudio: true, retune: in.TakeOver}
		if o, err = f.parse(in.Target, hz, def); err != nil {
			return nil, nil, toolError(err)
		}
	}
	app, _, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.close()
	s.proseToStderr = true
	s.takeOverHint = takeOverHint
	if o != nil {
		if s.device, err = pickDevice(s.state, o.device); err != nil {
			return nil, nil, toolError(err)
		}
		if err := refuseRetune(s, o.freq, o.bw, o.retune); err != nil {
			return nil, nil, err
		}
	}
	stop, err := s.openChannel(ctx, o, channelID)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer stop()
	sum, err := s.summarise(ctx, dur)
	if err != nil {
		return nil, nil, toolError(err)
	}
	raw, err := composite(map[string]any{
		"channel": s.channel, "transcript": sum.transcript, "meter": sum.meter, "tone": subAudibleOrNil(sum.tone),
	})
	if err != nil {
		return nil, nil, err
	}
	return textResult(errb.String() + sum.text(s, dur)), raw, nil
}

func subAudibleOrNil(sa *leylinev1.SubAudible) any {
	if sa == nil {
		return nil
	}
	return sa
}

// listenSummary is what a bounded telemetry subscription folded into: the
// transmissions as ActivitySegments (the transcript's own building block),
// the meter's range, and the last tone reported.
type listenSummary struct {
	transcript *leylinev1.Transcript
	meter      meterStats
	tone       *leylinev1.SubAudible
	rate       uint64
}

// summarise subscribes to the channel's meter, squelch and sub-audible
// telemetry for dur and folds it. A squelch close edge carries the
// transmission's length and peaks, so the segments come from the daemon's
// own edges rather than from timing anything here; the mean is the meter's,
// averaged over the blocks the squelch was open for.
func (s *session) summarise(ctx context.Context, dur time.Duration) (*listenSummary, error) {
	tctx, cancel := context.WithTimeout(ctx, dur)
	defer cancel()
	msgs, terrs, err := s.client.WatchTelemetry(tctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: s.channel.GetChannelId()},
		Types: []leylinev1.TelemetryType{
			leylinev1.TelemetryType_METER,
			leylinev1.TelemetryType_SQUELCH_TRANSITION,
			leylinev1.TelemetryType_SUB_AUDIBLE,
		},
	})
	if err != nil {
		return nil, err
	}
	stopDrain := s.drainEvents()
	defer stopDrain()
	sum := &listenSummary{
		transcript: &leylinev1.Transcript{Segments: []*leylinev1.ActivitySegment{}},
		meter:      meterStats{MinPowerDbfs: math.NaN(), MaxPowerDbfs: math.NaN(), MeanPowerDbfs: math.NaN(), SquelchDb: s.channel.GetSquelchDb()},
		rate:       leyline.ChannelCaptureRate(s.state, s.channel),
	}
	var (
		sumPower, openSum float64
		openN             int
		open              bool
	)
	for {
		select {
		case <-tctx.Done():
			sum.finish(sumPower, open)
			return sum, nil
		case m, ok := <-msgs:
			if !ok {
				if err := <-terrs; err != nil && tctx.Err() == nil {
					return nil, err
				}
				sum.finish(sumPower, open)
				return sum, nil
			}
			switch b := m.Body.(type) {
			case *leylinev1.TelemetryMsg_Meter:
				p := b.Meter.GetPowerDbfs()
				if math.IsNaN(p) || math.IsInf(p, 0) {
					continue
				}
				sum.meter.Samples++
				sumPower += p
				if math.IsNaN(sum.meter.MinPowerDbfs) || p < sum.meter.MinPowerDbfs {
					sum.meter.MinPowerDbfs = p
				}
				if math.IsNaN(sum.meter.MaxPowerDbfs) || p > sum.meter.MaxPowerDbfs {
					sum.meter.MaxPowerDbfs = p
				}
				if b.Meter.GetSquelchOpen() {
					sum.meter.SquelchOpenFraction++
					openSum += p
					openN++
				}
			case *leylinev1.TelemetryMsg_Squelch:
				if b.Squelch.GetOpen() {
					open, openSum, openN = true, 0, 0
					continue
				}
				open = false
				t, ok := closedTransmission(b.Squelch, sum.rate)
				if !ok {
					continue
				}
				seg := &leylinev1.ActivitySegment{
					End:      proto.Clone(m.GetTime()).(*leylinev1.SampleTime),
					PeakDbfs: t.peakDbfs,
					MeanDbfs: math.NaN(),
				}
				if st := m.GetTime(); st != nil {
					seg.Start = &leylinev1.SampleTime{CaptureId: st.GetCaptureId(), SampleIndex: st.GetSampleIndex() - min(st.GetSampleIndex(), b.Squelch.GetDurationSamples())}
				}
				if openN > 0 {
					seg.MeanDbfs = openSum / float64(openN)
				}
				sum.transcript.Segments = append(sum.transcript.Segments, seg)
			case *leylinev1.TelemetryMsg_SubAudible:
				if b.SubAudible.GetKind() == leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS || sum.tone == nil {
					sum.tone = b.SubAudible
				}
			}
		}
	}
}

// finish turns the running sums into the stats: fractions need the count.
func (sum *listenSummary) finish(sumPower float64, open bool) {
	if n := sum.meter.Samples; n > 0 {
		sum.meter.MeanPowerDbfs = sumPower / float64(n)
		sum.meter.SquelchOpenFraction /= float64(n)
	}
	sum.meter.OpenAtEnd = open
}

// text is the summary in words: how many transmissions, the longest and
// loudest, the level range, the tone. Numbers an agent reads off the
// structured result too; the sentence is for reasoning, not parsing.
func (sum *listenSummary) text(s *session, dur time.Duration) string {
	var b strings.Builder
	what := audioWhat(s)
	segs := sum.transcript.GetSegments()
	fmt.Fprintf(&b, "%s for %s: %s", what, fmtDuration(dur.Seconds()), plural(len(segs), "transmission"))
	if len(segs) > 0 {
		longest, loudest := math.NaN(), math.NaN()
		for _, seg := range segs {
			if sum.rate > 0 {
				secs := float64(seg.GetEnd().GetSampleIndex()-seg.GetStart().GetSampleIndex()) / float64(sum.rate)
				if math.IsNaN(longest) || secs > longest {
					longest = secs
				}
			}
			if p := seg.GetPeakDbfs(); !math.IsNaN(p) && (math.IsNaN(loudest) || p > loudest) {
				loudest = p
			}
		}
		fmt.Fprintf(&b, " (longest %s", fmtDuration(longest))
		if !math.IsNaN(loudest) {
			fmt.Fprintf(&b, ", loudest peak %.0f dBFS", loudest)
		}
		b.WriteString(")")
	}
	b.WriteString(".")
	if sum.meter.OpenAtEnd {
		b.WriteString(" A transmission was still in progress when the window ended.")
	}
	m := sum.meter
	if m.Samples > 0 {
		fmt.Fprintf(&b, "\nsignal %.0f to %.0f dBFS (mean %.0f), squelch %s, open %.0f%% of the time.",
			m.MinPowerDbfs, m.MaxPowerDbfs, m.MeanPowerDbfs, squelchString(m.SquelchDb), 100*m.SquelchOpenFraction)
	} else {
		b.WriteString("\nno meter readings arrived.")
	}
	if sum.tone != nil {
		var tr subAudibleTracker
		if line, ok := tr.line(sum.tone, ui.Style{}); ok {
			b.WriteString("\n" + line)
		}
	}
	return b.String() + "\n"
}

type snapshotArgs struct {
	Frequency string `json:"frequency,omitempty" jsonschema:"the frequency to centre on (a bare number is MHz) or a preset name; default: whatever the radio is already tuned to"`
	Band      string `json:"band,omitempty" jsonschema:"show a whole named band instead of a frequency: 2m, fm, airband, noaa (not with frequency)"`
	Span      string `json:"span,omitempty" jsonschema:"width of the band to show, e.g. 2.4M or 250k; this is the capture's sample rate, snapped to one the radio supports (default: the radio's default, or the width it is already capturing)"`
	Bins      uint32 `json:"bins,omitempty" jsonschema:"number of bins across the band (default 1024; the daemon may round it)"`
	Device    string `json:"device,omitempty" jsonschema:"which radio: an id, id prefix or row number from list_devices (default: the first real radio)"`
	TakeOver  bool   `json:"take_over,omitempty" jsonschema:"move the radio even when other channels are listening on it (default: false, refuse and say who)"`
	NoImage   bool   `json:"no_image,omitempty" jsonschema:"return the numbers only, no PNG (default: false)"`
}

// snapshotFirstRow bounds the wait for the one row a snapshot needs.
const snapshotFirstRow = 5 * time.Second

func (srv *mcpServer) snapshot(ctx context.Context, _ *mcp.CallToolRequest, in snapshotArgs) (*mcp.CallToolResult, any, error) {
	bo := bandOptions{freqInput: in.Frequency, retune: in.TakeOver, device: in.Device, verb: "snapshot"}
	if in.Frequency != "" {
		t, err := resolveDialTarget(in.Frequency, "snapshot", "frequency: 101.1, frequency: noaa", "101.1 (MHz) or 1010k")
		if err != nil {
			return nil, nil, toolError(err)
		}
		bo.freq = t.Hz
	}
	if in.Band != "" {
		if in.Frequency != "" {
			return nil, nil, errors.New("give frequency or band, not both: a band is a range and a frequency is a point")
		}
		b, err := leyline.ResolveBand(in.Band)
		if err != nil {
			return nil, nil, toolError(err)
		}
		bo.band = &b
	}
	if in.Span != "" {
		v, err := leyline.ParseUserFrequency(in.Span)
		if err != nil {
			return nil, nil, fmt.Errorf("span %v; for example 2.4M or 200k", err)
		}
		bo.span = v
	}
	bins := in.Bins
	if bins == 0 {
		bins = 1024
	}
	app, _, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.close()
	s.proseToStderr = true
	s.takeOverHint = takeOverHint
	if s.device, err = pickDevice(s.state, bo.device); err != nil {
		return nil, nil, toolError(err)
	}
	if bo.freq != 0 {
		if err := refuseRetune(s, bo.freq, 0, bo.retune); err != nil {
			return nil, nil, err
		}
	}
	if err := s.openBand(ctx, app, bo); err != nil {
		return nil, nil, toolError(err)
	}
	if s.createdCapture {
		defer s.teardown()
	}
	row, err := s.oneRow(ctx, bins)
	if err != nil {
		return nil, nil, toolError(err)
	}
	raw, err := json.Marshal(row)
	if err != nil {
		return nil, nil, err
	}
	res := &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: strings.TrimRight(errb.String()+snapshotText(row, s), "\n")}}}
	if !in.NoImage {
		png, err := renderSpectrumPNG(row.Bins, row.FloorDb, row.CenterHz, row.SpanHz, row.Peaks, bo.freq)
		if err != nil {
			return nil, nil, err
		}
		res.Content = append(res.Content, &mcp.ImageContent{Data: png, MIMEType: "image/png"})
	}
	return res, json.RawMessage(raw), nil
}

// oneRow subscribes to the capture's FFT and returns the first row as the
// `ley spectrum --json` shape, with the same floor and the same peaks.
func (s *session) oneRow(ctx context.Context, bins uint32) (*SpectrumRow, error) {
	sctx, cancel := context.WithTimeout(ctx, snapshotFirstRow)
	defer cancel()
	sub, err := s.client.SubscribeFFT(sctx, s.capture.GetCaptureId(), bins, 2, leylinev1.FftBinFormat_DB_F32)
	if err != nil {
		return nil, err
	}
	defer sub.Close()
	stopDrain := s.drainEvents()
	defer stopDrain()
	desc := sub.Descriptor
	for {
		select {
		case <-sctx.Done():
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			return nil, fmt.Errorf("no spectrum row arrived in %.0f s, so there is nothing to draw; get_state says whether the radio is still capturing", snapshotFirstRow.Seconds())
		case fr, ok := <-sub.Frames:
			if !ok {
				if err := sub.Err(); err != nil {
					return nil, err
				}
				return nil, errors.New("the spectrum stream ended before it sent a row; get_state says whether the radio is still capturing")
			}
			if len(fr.Payload) == 0 {
				continue
			}
			vals := leyline.DecodeFFTBins(fr.Payload, desc.GetFft().GetBinFormat())
			floor := medianDb(vals)
			return &SpectrumRow{FFTRow: FFTRow{
				Seq: fr.Seq, SampleIndex: fr.Time.GetSampleIndex(),
				CenterHz: desc.CenterHz, SpanHz: desc.SpanHz,
				Bins: vals, FloorDb: floorOf(vals),
			}, Peaks: loudestBins(vals, desc.CenterHz, desc.SpanHz, spectrumPeaks, floor+peakAboveFloorDb)}, nil
		}
	}
}

// snapshotText names what the picture shows: the span, the floor, and the
// loudest bins with the caveat the terminal view carries.
func snapshotText(row *SpectrumRow, s *session) string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s wide around %s on %s, %d bins, noise floor %.0f dBFS (the row's median bin).\n",
		leyline.FormatFrequency(row.SpanHz), leyline.FormatFrequency(row.CenterHz), deviceName(s.device), len(row.Bins), row.FloorDb)
	if len(row.Peaks) == 0 {
		fmt.Fprintf(&b, "nothing above the floor by %d dB: no bin stands out.\n", peakAboveFloorDb)
		return b.String()
	}
	b.WriteString("loudest bins (local maxima, presentation only, never called signals):\n")
	for _, p := range row.Peaks {
		var band string
		if bd := leyline.BandFor(p.CenterHz); bd != nil {
			band = "  " + bd.Name
		}
		fmt.Fprintf(&b, "  %s  %.0f dBFS  (%.0f dB over the floor)%s\n", leyline.FormatFrequency(p.CenterHz), p.Db, p.Db-row.FloorDb, band)
	}
	return b.String()
}

// ---------- decoders ----------

func (srv *mcpServer) listDecoders(ctx context.Context, _ *mcp.CallToolRequest, _ mcpNoArgs) (*mcp.CallToolResult, any, error) {
	resp, err := srv.client.ListDecoders(ctx)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	app, out, _ := srv.toolApp()
	printDecoderTable(app, resp)
	return protoResult(resp, out.String())
}

type queryRecordsArgs struct {
	Protocol string  `json:"protocol,omitempty" jsonschema:"only this protocol, e.g. aprs (list_decoders names them)"`
	JobID    string  `json:"job_id,omitempty" jsonschema:"only this kept job's records"`
	DeviceID string  `json:"device_id,omitempty" jsonschema:"only this transmitter, e.g. N0CALL-9 (the id the protocol gives it, not a radio)"`
	Kind     string  `json:"kind,omitempty" jsonschema:"only this kind of record, e.g. position, weather, status"`
	SinceS   float64 `json:"since_s,omitempty" jsonschema:"only records newer than this many seconds ago"`
	Near     string  `json:"near,omitempty" jsonschema:"only records from around here: LAT,LON such as 37.76,-122.42 (needs radius)"`
	Radius   string  `json:"radius,omitempty" jsonschema:"how far around near to look, with its unit: 10km, 500m, 5nm, 3mi"`
	InEffect bool    `json:"in_effect,omitempty" jsonschema:"only records whose validity window covers now (alerts, warnings)"`
	Limit    uint32  `json:"limit,omitempty" jsonschema:"at most this many records (default: the daemon's 1000; the page says if it was cut)"`
}

func (srv *mcpServer) queryRecords(ctx context.Context, _ *mcp.CallToolRequest, in queryRecordsArgs) (*mcp.CallToolResult, any, error) {
	q := &leylinev1.RecordQuery{Protocol: in.Protocol, JobId: in.JobID, DeviceId: in.DeviceID, Kind: in.Kind, InEffect: in.InEffect, Limit: in.Limit}
	if in.SinceS > 0 {
		q.SinceNs = time.Now().Add(-time.Duration(in.SinceS * float64(time.Second))).UnixNano()
	}
	if in.Near != "" {
		near, err := parseLatLon(in.Near)
		if err != nil {
			return nil, nil, fmt.Errorf("near %v", err)
		}
		q.Near = near
	}
	if in.Radius != "" {
		r, err := parseDistance(in.Radius)
		if err != nil {
			return nil, nil, fmt.Errorf("radius %v", err)
		}
		q.RadiusM = r
	}
	switch {
	case q.Near != nil && q.RadiusM == 0:
		return nil, nil, errors.New("near needs radius: a point without a distance says nothing about which records to keep (try radius: 10km)")
	case q.Near == nil && q.RadiusM > 0:
		return nil, nil, errors.New("radius needs near: a distance without a point has nothing to measure from (try near: 37.76,-122.42)")
	}
	page, err := srv.client.QueryRecords(ctx, q)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	app, out, errb := srv.toolApp()
	printRecordTable(app, page)
	return protoResult(page, out.String()+errb.String())
}

type listEntitiesArgs struct {
	Protocol  string  `json:"protocol" jsonschema:"the protocol to fold, e.g. aprs, or an alias a decoder lists such as vessels (list_decoders names them)"`
	DurationS float64 `json:"duration_s,omitempty" jsonschema:"how long to listen for records before answering, in seconds (default 5, at most 300); a decode job already running replays what it retained first"`
	SinceS    float64 `json:"since_s,omitempty" jsonschema:"seed the table from kept records this many seconds old, before listening"`
	Device    string  `json:"device,omitempty" jsonschema:"which radio to start the decoder on, when one has to be started (default: the daemon picks)"`
	TakeOver  bool    `json:"take_over,omitempty" jsonschema:"start the decoder even when somebody is using the radio (default: false)"`
}

func (srv *mcpServer) listEntities(ctx context.Context, _ *mcp.CallToolRequest, in listEntitiesArgs) (*mcp.CallToolResult, any, error) {
	dur := time.Duration(in.DurationS * float64(time.Second))
	if in.DurationS <= 0 {
		dur = 5 * time.Second
	}
	if dur > listenMaxSeconds*time.Second {
		return nil, nil, fmt.Errorf("duration_s is at most %d: a longer watch is a job, not a tool call", listenMaxSeconds)
	}
	c := srv.client
	protocol := in.Protocol
	if name, _, err := c.ResolveDecoder(ctx, protocol); err == nil {
		protocol = name
	}
	silence := trackSilence(ctx, c, protocol)
	window := trackWindow(silence)
	job := runningDecodeJob(ctx, c, protocol)
	started := false
	if job == nil {
		var deviceID string
		if in.Device != "" {
			st, err := c.State(ctx)
			if err != nil {
				return nil, nil, toolError(srv.app.notRunning(err))
			}
			d, err := pickDevice(st, in.Device)
			if err != nil {
				return nil, nil, toolError(err)
			}
			deviceID = d.GetDeviceId()
		}
		var err error
		job, err = c.StartDecode(ctx, &leylinev1.DecodeConfig{Decoder: protocol, DeviceId: deviceID, TakeOver: in.TakeOver})
		if err != nil {
			return nil, nil, toolError(decodeToolFailure(protocol, err))
		}
		started = true
		defer func() {
			cctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
			defer cancel()
			_, _ = c.Jobs.CancelJob(cctx, &leylinev1.JobRef{JobId: job.GetJobId()})
		}()
	}
	table := records.NewTable()
	if in.SinceS > 0 {
		if err := seedTrack(ctx, c, table, trackOptions{protocol: protocol, since: time.Duration(in.SinceS * float64(time.Second))}); err != nil {
			return nil, nil, toolError(err)
		}
	}
	// The job's own scope replays what it retained (up to 256 records) before
	// going live, so a decoder that has been running for a while answers at
	// once and the wait only adds what arrives during it.
	from := uint64(0)
	sctx, stop := context.WithTimeout(ctx, dur)
	defer stop()
	recs, errs, err := c.SubscribeRecords(sctx, leyline.RecordScopeJob(job.GetJobId(), &from))
	if err != nil {
		return nil, nil, toolError(err)
	}
fold:
	for {
		select {
		case <-sctx.Done():
			break fold
		case err := <-errs:
			if err != nil && sctx.Err() == nil {
				return nil, nil, toolError(err)
			}
			break fold
		case rec, ok := <-recs:
			if !ok {
				break fold
			}
			table.Apply(rec)
		}
	}
	table.Expire(time.Now(), silence)
	app, out, _ := srv.toolApp()
	how := fmt.Sprintf("%s, %s", protocol, plural(table.Len(), "transmitter"))
	if started {
		how += fmt.Sprintf(" heard in %s (a decoder was started for this call and stopped after it)", fmtDuration(dur.Seconds()))
	} else {
		how += fmt.Sprintf(" from the decode job %s already running", job.GetJobId())
	}
	fmt.Fprintln(app.Stdout, how)
	fmt.Fprint(app.Stdout, renderTrack(app, table, window))
	raw, err := json.Marshal(entitySnapshot(table, window))
	if err != nil {
		return nil, nil, err
	}
	return textResult(out.String()), json.RawMessage(raw), nil
}

type startDecodeJobArgs struct {
	Decoder   string `json:"decoder" jsonschema:"a decoder name or alias from list_decoders, e.g. aprs"`
	Frequency string `json:"frequency,omitempty" jsonschema:"decode somewhere other than the recipe's first frequency, e.g. 144.8 (a bare number is MHz)"`
	Device    string `json:"device,omitempty" jsonschema:"which radio: an id, id prefix or row number from list_devices (default: the daemon picks)"`
	TakeOver  bool   `json:"take_over,omitempty" jsonschema:"decode even when somebody is using the radio; it is theirs again afterwards (default: false)"`
	Keep      bool   `json:"keep,omitempty" jsonschema:"keep the job and its records after this server exits; kept records are what query_records reads (default: false)"`
}

func (srv *mcpServer) startDecodeJob(ctx context.Context, _ *mcp.CallToolRequest, in startDecodeJobArgs) (*mcp.CallToolResult, any, error) {
	c := srv.client
	cfg := &leylinev1.DecodeConfig{Decoder: in.Decoder, TakeOver: in.TakeOver, Keep: in.Keep}
	if name, _, err := c.ResolveDecoder(ctx, in.Decoder); err == nil {
		cfg.Decoder = name
	}
	if in.Frequency != "" {
		hz, err := leyline.ParseUserFrequency(in.Frequency)
		if err != nil {
			return nil, nil, fmt.Errorf("frequency %v", err)
		}
		cfg.FrequencyHz = hz
	}
	if in.Device != "" {
		st, err := c.State(ctx)
		if err != nil {
			return nil, nil, toolError(srv.app.notRunning(err))
		}
		d, err := pickDevice(st, in.Device)
		if err != nil {
			return nil, nil, toolError(err)
		}
		cfg.DeviceId = d.GetDeviceId()
	}
	job, err := c.StartDecode(ctx, cfg)
	if err != nil {
		return nil, nil, toolError(decodeToolFailure(cfg.Decoder, err))
	}
	var b strings.Builder
	fmt.Fprintf(&b, "%s: job %s", job.GetStatusDetail(), job.GetJobId())
	if in.Keep {
		fmt.Fprintf(&b, ", kept: it runs on after this server exits and its records are ley://records/%s, which query_records reads.", job.GetJobId())
	} else {
		b.WriteString(", running until this server exits; list_entities folds its records, and keep: true would store them for query_records.")
	}
	b.WriteString("\ncancel_job stops it.")
	return protoResult(job, b.String())
}

// decodeToolFailure is decodeFailure's sentence with the tool's remedies in
// place of the verb's flags.
func decodeToolFailure(decoder string, err error) error {
	switch leyline.Code(err) {
	case leyline.CodeDecoderNotFound:
		return fmt.Errorf("there is no decoder called %q; list_decoders lists the ones installed", decoder)
	case leyline.CodeDeviceBusy:
		return fmt.Errorf("%s. take_over: true decodes anyway, and hands the radio back afterwards", leylineMessage(err, "the radio is busy"))
	case leyline.CodeDecoderFailed:
		return fmt.Errorf("%s. 'ley daemon logs' carries what the plugin wrote", leylineMessage(err, "the decoder would not start"))
	}
	return err
}

// ---------- jobs ----------

func (srv *mcpServer) listJobs(ctx context.Context, _ *mcp.CallToolRequest, _ mcpNoArgs) (*mcp.CallToolResult, any, error) {
	jobs, err := srv.client.ListJobs(ctx)
	if err != nil {
		return nil, nil, toolError(srv.app.notRunning(err))
	}
	app, out, _ := srv.toolApp()
	printJobTable(app, jobs, true)
	return protoResult(&leylinev1.ListJobsResponse{Jobs: jobs}, out.String())
}

type jobArgs struct {
	Job string `json:"job" jsonschema:"the job: its id (job_...), an unambiguous id prefix, or its row number in list_jobs"`
}

// resolveJob names a job the way `ley jobs cancel` does: id, prefix or row.
func (srv *mcpServer) resolveJob(ctx context.Context, sel string) (*leylinev1.Job, error) {
	jobs, err := srv.client.ListJobs(ctx)
	if err != nil {
		return nil, toolError(srv.app.notRunning(err))
	}
	j, err := leyline.ResolveJob(jobs, sel)
	if err != nil {
		if len(jobs) == 0 {
			return nil, errors.New("the daemon has no jobs; scan or start_decode_job starts one")
		}
		return nil, fmt.Errorf("%w; list_jobs names them", err)
	}
	return j, nil
}

func (srv *mcpServer) getJob(ctx context.Context, _ *mcp.CallToolRequest, in jobArgs) (*mcp.CallToolResult, any, error) {
	j, err := srv.resolveJob(ctx, in.Job)
	if err != nil {
		return nil, nil, err
	}
	job, err := srv.client.Jobs.GetJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
	if err != nil {
		return nil, nil, toolError(err)
	}
	return protoResult(job, jobLine(job))
}

func (srv *mcpServer) cancelJob(ctx context.Context, _ *mcp.CallToolRequest, in jobArgs) (*mcp.CallToolResult, any, error) {
	j, err := srv.resolveJob(ctx, in.Job)
	if err != nil {
		return nil, nil, err
	}
	final, err := srv.client.Jobs.CancelJob(ctx, &leylinev1.JobRef{JobId: j.GetJobId()})
	if err != nil {
		return nil, nil, toolError(err)
	}
	return protoResult(final, jobLine(final))
}

// jobLine is one job in words: what, where, state, detail.
func jobLine(j *leylinev1.Job) string {
	line := fmt.Sprintf("%s %s %s", j.GetJobId(), jobKind(j), jobStateWord(j))
	if r := jobRange(j); r != "" {
		line += " " + r
	}
	if d := j.GetStatusDetail(); d != "" {
		line += ": " + d
	}
	return line + "\n"
}

// ---------- resources ----------

// readRecordsResource serves ley://records/<job_id>: the kept job's page.
func (srv *mcpServer) readRecordsResource(ctx context.Context, req *mcp.ReadResourceRequest) (*mcp.ReadResourceResult, error) {
	uri := req.Params.URI
	jobID, ok := strings.CutPrefix(uri, "ley://records/")
	if !ok || jobID == "" {
		return nil, mcp.ResourceNotFoundError(uri)
	}
	page, err := srv.client.QueryRecords(ctx, &leylinev1.RecordQuery{JobId: jobID})
	if err != nil {
		return nil, toolError(srv.app.notRunning(err))
	}
	if len(page.GetRecords()) == 0 {
		// An empty page is either a kept job that has heard nothing yet or a
		// job the store never had; the job list tells them apart.
		jobs, jerr := srv.client.ListJobs(ctx)
		if jerr != nil {
			return nil, toolError(jerr)
		}
		known := false
		for _, j := range jobs {
			if j.GetJobId() == jobID && j.GetDecode().GetKeep() {
				known = true
			}
		}
		if !known {
			return nil, mcp.ResourceNotFoundError(uri)
		}
	}
	raw, err := protoJSON(page)
	if err != nil {
		return nil, err
	}
	return &mcp.ReadResourceResult{Contents: []*mcp.ResourceContents{{URI: uri, MIMEType: "application/json", Text: string(raw)}}}, nil
}
