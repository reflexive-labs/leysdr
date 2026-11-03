// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// Dry runs (docs/design/claims.md, "One decision: plan"): `ley decode`, `ley record` and `ley
// scan` with --dry-run, and the MCP tools with dry_run, ask Control.Plan where the job would go
// and say it in a sentence. The daemon makes the decision; this file only words it.

// planWords is a plan in one or two sentences. sweep words a scan's plan (a sweep takes the whole
// radio); takeOver is the remedy a decline names, "--take-over" or "take_over: true", and empty
// when the request already took over. declined reports a DECLINE.
func planWords(st *leylinev1.GetStateResponse, p *leylinev1.CapturePlan, sweep bool, takeOver string) (text string, declined bool) {
	switch o := p.GetOutcome().(type) {
	case *leylinev1.CapturePlan_Share:
		return fmt.Sprintf("would share the capture at %s on %s; nothing is retuned",
			units.FormatFrequency(o.Share.GetCenterHz()), planDevice(st, o.Share.GetDeviceId())), false
	case *leylinev1.CapturePlan_Create:
		if sweep {
			return fmt.Sprintf("would sweep with %s, which nothing is using", planDevice(st, o.Create.GetDeviceId())), false
		}
		return fmt.Sprintf("would open %s at %s, %s; nothing else is using it", planDevice(st, o.Create.GetDeviceId()),
			units.FormatFrequency(o.Create.GetCenterHz()), formatMSPS(o.Create.GetSampleRateHz())), false
	case *leylinev1.CapturePlan_Retune:
		r := o.Retune
		dev := planDevice(st, r.GetDeviceId())
		var head string
		if sweep {
			head = fmt.Sprintf("would take %s for the sweep and put it back afterwards", dev)
		} else {
			head = fmt.Sprintf("would retune %s to %s", dev, units.FormatFrequency(r.GetCenterHz()))
			if c := planCapture(st, r.GetCaptureId()); c != nil && c.GetSampleRate() != r.GetSampleRateHz() {
				head += " at " + formatMSPS(r.GetSampleRateHz())
			}
		}
		if len(r.GetDisplaced()) == 0 {
			return head + "; nothing on it has to move", false
		}
		names := make([]string, 0, len(r.GetDisplaced()))
		for _, c := range r.GetDisplaced() {
			names = append(names, claimName(st, c))
		}
		return head + ", pausing: " + joinAnd(names), false
	case *leylinev1.CapturePlan_Decline:
		text := "would not start: " + o.Decline.GetReason()
		if takeOver != "" && o.Decline.GetCode() == "DEVICE_BUSY" && len(o.Decline.GetBlocking()) > 0 {
			text += "; " + takeOver + " insists"
		}
		return text, true
	}
	return "the daemon gave no plan", true
}

// claimName names a claim the way a person would: whose it is, what it is and where.
// "the app's channel on 146.520 MHz", "the aprs decoder on 144.390 MHz", "the recording on
// 162.550 MHz".
func claimName(st *leylinev1.GetStateResponse, c *leylinev1.Claim) string {
	at := ""
	switch n := c.GetNeed().(type) {
	case *leylinev1.Claim_Covers:
		at = " on " + units.FormatFrequency(n.Covers.GetFrequencyHz())
	case *leylinev1.Claim_Centred:
		at = " at " + units.FormatFrequency(n.Centred.GetFrequencyHz())
	}
	h := c.GetHolder()
	if h.GetKind() == "job" {
		return jobName(st, h.GetClientId()) + at
	}
	var whose string
	switch h.GetKind() {
	case "app":
		whose = "the app's"
	case "cli":
		whose = "a terminal's"
	case "mcp":
		whose = "an agent's"
	default:
		if h.GetLabel() != "" {
			whose = h.GetLabel() + "'s"
		} else {
			whose = "another client's"
		}
	}
	what := map[leylinev1.ClaimKind]string{
		leylinev1.ClaimKind_CLAIM_CHANNEL:  "channel",
		leylinev1.ClaimKind_CLAIM_IQ:       "IQ reader",
		leylinev1.ClaimKind_CLAIM_LISTEN:   "listening",
		leylinev1.ClaimKind_CLAIM_SPECTRUM: "spectrum view",
		leylinev1.ClaimKind_CLAIM_SWEEP:    "sweep",
	}[c.GetKind()]
	if what == "" {
		what = "claim"
	}
	return whose + " " + what + at
}

// jobName is a job as a person names it: the decoder it runs or what it does.
func jobName(st *leylinev1.GetStateResponse, id string) string {
	for _, j := range st.GetJobs() {
		if j.GetJobId() != id {
			continue
		}
		switch cfg := j.GetConfig().(type) {
		case *leylinev1.Job_Decode:
			return "the " + cfg.Decode.GetDecoder() + " decoder"
		case *leylinev1.Job_Record:
			return "the recording"
		case *leylinev1.Job_Scan:
			return "the scan"
		case *leylinev1.Job_Monitor:
			return "the monitor"
		}
	}
	return "a job"
}

func planDevice(st *leylinev1.GetStateResponse, id string) string {
	for _, d := range st.GetDevices() {
		if d.GetDeviceId() == id {
			return deviceName(d)
		}
	}
	if id == "" {
		return "the radio"
	}
	return id
}

func planCapture(st *leylinev1.GetStateResponse, id string) *leylinev1.Capture {
	for _, c := range st.GetCaptures() {
		if c.GetCaptureId() == id {
			return c
		}
	}
	return nil
}

// formatMSPS is a sample rate as people say it: 2.4 MSPS.
func formatMSPS(hz uint64) string {
	return strconv.FormatFloat(float64(hz)/1e6, 'f', -1, 64) + " MSPS"
}

// joinAnd is "a", "a and b", "a, b and c".
func joinAnd(items []string) string {
	switch len(items) {
	case 0:
		return ""
	case 1:
		return items[0]
	}
	return strings.Join(items[:len(items)-1], ", ") + " and " + items[len(items)-1]
}

// dryRun asks for the plan and prints it: the sentence on stdout, or the CapturePlan under
// --json. A decline exits 1 with the sentence; a plan that would go ahead exits 0.
func (s *verbSession) dryRun(ctx context.Context, req *leylinev1.PlanRequest, sweep, tookOver bool) error {
	p, err := s.Client.Control.Plan(ctx, req)
	if err != nil {
		return err
	}
	st, err := s.Client.State(ctx)
	if err != nil {
		st = s.State
	}
	hint := s.app.ErrStyle.Cmd("--take-over")
	if tookOver {
		hint = ""
	}
	text, declined := planWords(st, p, sweep, hint)
	if s.app.JSON {
		if err := s.app.printJSON(p); err != nil {
			return err
		}
		if declined {
			return &ExitError{Code: 1, Message: text}
		}
		return nil
	}
	if declined {
		return &ExitError{Code: 1, Message: text}
	}
	fmt.Fprintln(s.app.Stdout, text)
	return nil
}

// dryRunFailure passes a decline through as it is and gives an RPC error (a decoder that is not
// installed, a frequency no radio tunes) the verb's own sentence for it.
func dryRunFailure(err error, verb func(error) error) error {
	var ee *ExitError
	if errors.As(err, &ee) {
		return err
	}
	return verb(err)
}
