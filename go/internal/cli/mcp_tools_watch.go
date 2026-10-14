// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// The watch tool: `ley watch` seen from an agent. It builds the filter and the notifier with the
// verb's own parsers (buildPredicate, parseNotify), starts the job the verb would
// (watchOptions.config) and reports it with the verb's banner; it does not stream, because a
// tool call returns. The shell notifier is not offered: a command run on the user's Mac with
// a record's text on stdin turns words from the air into an action, and the assistant's policy
// keeps it among the things only a person sets up (docs/plans/ai-features.md, "What the
// assistant may do").

func (srv *mcpServer) registerWatchTool() {
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "watch",
		Description: "Start a decoder with a filter and, optionally, a notifier that fires on each match (Jobs.StartJob(DecodeConfig) with a predicate; ley watch). " +
			"where is ley watch's --where: field=value, field!=value, field~value (contains), field>value, >=, <, <=, on any field the decoder emits; near with radius keeps records with a position within that distance; county keeps SAME alerts naming a county. All tests must pass. " +
			"notify is macos (a notification on the Mac) or webhook:URL; the shell notifier is not available here. " +
			"Without keep the job ends when this server exits; with keep it runs on and keeps firing. A kept watch or a webhook notifier is the user's to confirm first: show them the filter and the notifier. " +
			"Refuses a radio somebody is using unless take_over is true. Returns the Job; the text is ley watch's banner.",
		Annotations: &mcp.ToolAnnotations{DestructiveHint: boolPtr(false), OpenWorldHint: boolPtr(true)},
	}, srv.watch)
}

type watchArgs struct {
	Decoder   string   `json:"decoder" jsonschema:"a decoder name or alias from list_decoders, e.g. aprs or same"`
	Where     []string `json:"where,omitempty" jsonschema:"field tests, each field=value, field!=value, field~value, field>value, field>=value, field<value or field<=value, e.g. device_id=LEYTST-1 or temp_c>25"`
	County    []string `json:"county,omitempty" jsonschema:"county codes a SAME alert must name: the five-digit FIPS code (06009) or the six-digit SAME code (006009); a record matches if it names any"`
	Near      string   `json:"near,omitempty" jsonschema:"records from around a point: LAT,LON, e.g. 37.76,-122.42 (needs radius)"`
	Radius    string   `json:"radius,omitempty" jsonschema:"how far around near: 10km, 500m, 5nm, 3mi"`
	Notify    string   `json:"notify,omitempty" jsonschema:"hand each match to a notifier: macos (a notification on the Mac the daemon runs on) or webhook:URL (POSTs the record). Default: none, the job only filters"`
	Frequency string   `json:"frequency,omitempty" jsonschema:"watch somewhere other than the recipe's first frequency, e.g. 144.8 (a bare number is MHz)"`
	Device    string   `json:"device,omitempty" jsonschema:"which radio: an id, id prefix or row number from list_devices (default: the daemon picks)"`
	TakeOver  bool     `json:"take_over,omitempty" jsonschema:"watch even when somebody is using the radio; it is theirs again afterwards (default: false)"`
	Keep      bool     `json:"keep,omitempty" jsonschema:"keep the job running after this server exits, so the notifier fires with nothing connected (default: false). The user's to confirm first"`
}

// shellNotifyRefusal is the sentence a shell notifier is refused with.
const shellNotifyRefusal = "the shell notifier is not available through this server: it runs a command on the Mac with each record's text, and that text comes from anyone with a transmitter. A person sets one up with ley watch --notify=shell:CMD; here notify takes macos or webhook:URL"

func (srv *mcpServer) watch(ctx context.Context, _ *mcp.CallToolRequest, in watchArgs) (*mcp.CallToolResult, any, error) {
	if strings.TrimSpace(in.Decoder) == "" {
		return nil, nil, errors.New("decoder is required: a name from list_decoders, e.g. aprs")
	}
	o := watchOptions{decoder: in.Decoder, device: in.Device, takeOver: in.TakeOver, detach: in.Keep}
	if in.Frequency != "" {
		hz, err := units.ParseFrequency(in.Frequency)
		if err != nil {
			return nil, nil, fmt.Errorf("frequency %w", err)
		}
		o.freqHz = hz
	}
	pred, predWords, err := buildPredicate(in.Where, in.County, in.Near, in.Radius)
	if err != nil {
		return nil, nil, toolError(err)
	}
	o.predicate, o.predWords = pred, predWords
	if n := strings.TrimSpace(in.Notify); n != "" {
		if scheme, _, _ := strings.Cut(n, ":"); strings.EqualFold(scheme, "shell") {
			return nil, nil, errors.New(shellNotifyRefusal)
		}
		if o.notify, err = parseNotify(n); err != nil {
			return nil, nil, toolError(err)
		}
	}
	app, out, errb := srv.toolApp()
	s, err := openSession(ctx, app)
	if err != nil {
		return nil, nil, toolError(err)
	}
	defer s.Close()
	s.proseToStderr = true
	if o.device != "" {
		d, derr := pickDevice(s.State, o.device)
		if derr != nil {
			return nil, nil, toolError(derr)
		}
		o.deviceID = d.DeviceId
	}
	if !o.takeOver && srv.ownGrace(s.State, o.deviceID) {
		o.takeOver = true
		fmt.Fprint(out, ownGraceNote)
	}
	if name, _, rerr := s.Client.ResolveDecoder(ctx, o.decoder); rerr == nil {
		o.decoder = name
	}
	job, err := s.Client.StartDecode(ctx, o.config())
	if err != nil {
		return nil, nil, toolError(decodeToolFailure(o.decoder, err))
	}
	fmt.Fprintf(out, "%s\njob %s", watchWhat(ctx, s, job, o), job.GetJobId())
	if in.Keep {
		fmt.Fprint(out, ", kept: it runs on after this server exits and keeps firing; cancel_job stops it.\n")
	} else {
		fmt.Fprint(out, ", running until this server exits; cancel_job stops it sooner, and keep: true would leave it running.\n")
	}
	return protoResult(job, errb.String()+out.String())
}
