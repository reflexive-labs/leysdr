// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"context"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// ListDecoders returns the decoders the daemon has installed, with the directories it looked in
// and the retention it applies to kept records. A decoder that failed to parse is not here: the
// daemon logs it and carries on, so an empty list means nothing is installed.
func (c *Client) ListDecoders(ctx context.Context) (*leylinev1.ListDecodersResponse, error) {
	return c.Decoders.ListDecoders(ctx, &leylinev1.ListDecodersRequest{})
}

// ResolveDecoder maps a name the user typed to a decoder's canonical name: the name itself, or a
// decoder that lists it in `aliases` ("vessels" -> "ais", "aircraft" -> "adsb"), so a friendly
// name reads well on the command line while records still carry the canonical `protocol`. An
// unknown name is returned unchanged, so the caller's StartDecode reports DECODER_NOT_FOUND
// naming what the user actually typed. `matched` says whether an install claimed it.
func (c *Client) ResolveDecoder(ctx context.Context, name string) (canonical string, matched bool, err error) {
	resp, err := c.ListDecoders(ctx)
	if err != nil {
		return name, false, err
	}
	for _, m := range resp.GetDecoders() {
		if m.GetName() == name {
			return name, true, nil
		}
	}
	for _, m := range resp.GetDecoders() {
		for _, a := range m.GetAliases() {
			if a == name {
				return m.GetName(), true, nil
			}
		}
	}
	return name, false, nil
}

// StartDecode starts a decode job: the daemon finds or makes a capture for the recipe's
// frequency, adds the channel the job owns and spawns the plugin. The records arrive on
// SubscribeRecords, not here.
func (c *Client) StartDecode(ctx context.Context, cfg *leylinev1.DecodeConfig) (*leylinev1.Job, error) {
	return c.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{Config: &leylinev1.StartJobRequest_Decode{Decode: cfg}})
}

// SubscribeRecords opens Decoders.SubscribeRecords and pumps it into a channel with the same
// contract as Events: the record channel closes when the stream ends and the error channel then
// carries exactly one value (nil on a clean end, ctx.Err() on cancellation, else the error).
func (c *Client) SubscribeRecords(ctx context.Context, sub *leylinev1.RecordSubscription) (<-chan *leylinev1.DecodeRecord, <-chan error, error) {
	stream, err := c.Decoders.SubscribeRecords(ctx, sub)
	if err != nil {
		return nil, nil, err
	}
	records, errs := pump(ctx, stream.Recv, 64)
	return records, errs, nil
}

// RecordScopeAll subscribes to every record the daemon produces.
func RecordScopeAll() *leylinev1.RecordSubscription {
	return &leylinev1.RecordSubscription{Scope: &leylinev1.RecordSubscription_All{All: true}}
}

// RecordScopeJob subscribes to one job's records. sinceSeq replays the retained window from that
// seq on (0 = everything still retained) before going live, so "StartJob then Subscribe" misses
// nothing; pass nil for live only.
func RecordScopeJob(jobID string, sinceSeq *uint64) *leylinev1.RecordSubscription {
	return &leylinev1.RecordSubscription{
		Scope:    &leylinev1.RecordSubscription_JobId{JobId: jobID},
		SinceSeq: sinceSeq,
	}
}

// RecordScopeProtocol subscribes to every job decoding one protocol.
func RecordScopeProtocol(protocol string) *leylinev1.RecordSubscription {
	return &leylinev1.RecordSubscription{Scope: &leylinev1.RecordSubscription_Protocol{Protocol: protocol}}
}

// QueryRecords reads the store: kept jobs only, newest first. The page carries the anchors its
// records need, so wall clock comes from RecordWallTime rather than from a field on a record.
func (c *Client) QueryRecords(ctx context.Context, q *leylinev1.RecordQuery) (*leylinev1.RecordPage, error) {
	return c.Decoders.QueryRecords(ctx, q)
}

// RecordWallTime turns a record's sample time into wall clock through the page's anchors: the
// newest anchor on the record's capture whose from_sample is not past the record's sample index.
// It reports false when no anchor covers the record, because a time without an anchor would not
// come from any clock the daemon recorded (AGENTS.md invariant 5).
func RecordWallTime(rec *leylinev1.DecodeRecord, anchors []*leylinev1.RecordAnchor) (time.Time, bool) {
	t := rec.GetTime()
	if t == nil || t.GetCaptureId() == "" {
		return time.Time{}, false
	}
	var best *leylinev1.RecordAnchor
	for _, a := range anchors {
		if a.GetAnchor().GetCaptureId() != t.GetCaptureId() || a.GetFromSample() > t.GetSampleIndex() {
			continue
		}
		if best == nil || a.GetFromSample() >= best.GetFromSample() {
			best = a
		}
	}
	if best == nil {
		return time.Time{}, false
	}
	return AnchorWallTime(best.GetAnchor(), t.GetSampleIndex())
}

// AnchorWallTime is RecordWallTime for a live capture, whose anchor is the one the daemon last
// published. Drift is applied as the anchor states it: a dongle's crystal is the reason the
// field exists.
func AnchorWallTime(anchor *leylinev1.CaptureAnchor, sampleIndex uint64) (time.Time, bool) {
	rate := float64(anchor.GetSampleRate())
	if rate <= 0 {
		return time.Time{}, false
	}
	seconds := float64(sampleIndex) / rate
	if ppm := anchor.GetDriftPpm(); ppm != 0 {
		seconds *= 1 + ppm/1e6
	}
	return time.Unix(0, anchor.GetHostTimeNs()).Add(time.Duration(seconds * float64(time.Second))), true
}
