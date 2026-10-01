// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"errors"
	"fmt"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// Selectors let a person name a device, capture or channel the way it
// appears in ley's own output: a full id, an unambiguous id prefix, the
// 1-based row number of the printed list (the order the daemon's state lists
// them), or a frequency ("146.52" via ParseUserFrequency) that the object
// covers. Resolution is presentation-only: the result is always an id the
// daemon already reported.

// SelectorError is returned when a selector matches nothing or more than
// one object. Candidates lists the ids in question so the caller can print
// them; Ambiguous distinguishes the two cases.
type SelectorError struct {
	Kind       string // "device", "capture", "channel"
	Selector   string
	Ambiguous  bool
	Candidates []string
	// Rows, when set, describes each candidate for a person ("1  chan_…
	// 146.620 MHz NFM": row number, id, frequency, mode) and is printed as a
	// list instead of the bare ids.
	Rows []string
}

func (e *SelectorError) Error() string {
	list := strings.Join(e.Candidates, ", ")
	if len(e.Rows) > 0 {
		list = "\n  " + strings.Join(e.Rows, "\n  ")
	}
	if e.Ambiguous {
		if len(e.Rows) > 0 {
			return fmt.Sprintf("%s %q matches more than one; pick one by row number or a longer id prefix:%s", e.Kind, e.Selector, list)
		}
		return fmt.Sprintf("%s %q matches more than one: %s; use a longer prefix or the row number", e.Kind, e.Selector, list)
	}
	if len(e.Candidates) == 0 {
		return fmt.Sprintf("no %ss; %s %q matches nothing", e.Kind, e.Kind, e.Selector)
	}
	if len(e.Rows) > 0 {
		return fmt.Sprintf("no %s matches %q (%s); pick one:%s", e.Kind, e.Selector, e.forms(), list)
	}
	return fmt.Sprintf("no %s matches %q; known: %s (%s)", e.Kind, e.Selector, list, e.forms())
}

// forms lists the selector forms this kind accepts. A job covers a range rather than sitting at
// a frequency, so the frequency form is not offered for jobs.
func (e *SelectorError) forms() string {
	if e.Kind == "job" {
		return "a full id, id prefix or row number"
	}
	return "a full id, id prefix, row number or frequency"
}

// resolveIndex applies the selector rules to ids. covers reports whether the
// object at index i covers frequency hz.
func resolveIndex(kind, sel string, ids []string, covers func(i int, hz uint64) bool) (int, error) {
	s := strings.TrimSpace(sel)
	if s == "" {
		return -1, &SelectorError{Kind: kind, Selector: sel, Candidates: ids}
	}
	for i, id := range ids {
		if id == s {
			return i, nil
		}
	}
	var prefix []int
	for i, id := range ids {
		if strings.HasPrefix(id, s) {
			prefix = append(prefix, i)
		}
	}
	if len(prefix) == 1 {
		return prefix[0], nil
	}
	if len(prefix) > 1 {
		return -1, &SelectorError{Kind: kind, Selector: sel, Ambiguous: true, Candidates: pick(ids, prefix)}
	}
	if n, err := strconv.Atoi(s); err == nil && n >= 1 && n <= len(ids) {
		return n - 1, nil
	}
	if hz, err := ParseUserFrequency(s); err == nil && covers != nil {
		var hits []int
		for i := range ids {
			if covers(i, hz) {
				hits = append(hits, i)
			}
		}
		if len(hits) == 1 {
			return hits[0], nil
		}
		if len(hits) > 1 {
			return -1, &SelectorError{Kind: kind, Selector: sel, Ambiguous: true, Candidates: pick(ids, hits)}
		}
	}
	return -1, &SelectorError{Kind: kind, Selector: sel, Candidates: ids}
}

func pick(ids []string, idx []int) []string {
	out := make([]string, 0, len(idx))
	for _, i := range idx {
		out = append(out, ids[i])
	}
	return out
}

// ResolveDevice finds a device by id, id prefix, row number, or a frequency
// inside one of its tuning ranges.
func ResolveDevice(state *leylinev1.GetStateResponse, sel string) (*leylinev1.DeviceDescriptor, error) {
	devs := state.GetDevices()
	ids := make([]string, len(devs))
	for i, d := range devs {
		ids[i] = d.GetDeviceId()
	}
	i, err := resolveIndex("device", sel, ids, func(i int, hz uint64) bool {
		return InRanges(hz, devs[i].GetTuningRanges())
	})
	if err != nil {
		return nil, err
	}
	return devs[i], nil
}

// CaptureCovers reports whether hz lies inside the capture's sampled span
// (center ± sample_rate/2).
func CaptureCovers(c *leylinev1.Capture, hz uint64) bool {
	half := c.GetSampleRate() / 2
	lo := c.GetCenterHz() - min(c.GetCenterHz(), half)
	return hz >= lo && hz <= c.GetCenterHz()+half
}

// ResolveCapture finds a capture by id, id prefix, row number, or a
// frequency inside its span.
func ResolveCapture(state *leylinev1.GetStateResponse, sel string) (*leylinev1.Capture, error) {
	caps := state.GetCaptures()
	ids := make([]string, len(caps))
	for i, c := range caps {
		ids[i] = c.GetCaptureId()
	}
	i, err := resolveIndex("capture", sel, ids, func(i int, hz uint64) bool {
		return CaptureCovers(caps[i], hz)
	})
	if err != nil {
		return nil, err
	}
	return caps[i], nil
}

// ChannelCaptureRate is the sample rate of the capture a channel is on. It is
// the rate SampleTime counts in, so it converts anything the daemon reports in
// samples -- a transmission's duration, a gap -- into seconds. Zero means the
// capture is not in this state snapshot.
func ChannelCaptureRate(state *leylinev1.GetStateResponse, ch *leylinev1.Channel) uint64 {
	for _, c := range state.GetCaptures() {
		if c.GetCaptureId() == ch.GetCaptureId() {
			return c.GetSampleRate()
		}
	}
	return 0
}

// ChannelFrequency returns the channel's absolute frequency (capture center
// plus offset) using the captures in state; ok is false when the capture is
// not in state.
func ChannelFrequency(state *leylinev1.GetStateResponse, ch *leylinev1.Channel) (hz uint64, ok bool) {
	for _, c := range state.GetCaptures() {
		if c.GetCaptureId() == ch.GetCaptureId() {
			f := int64(c.GetCenterHz()) + ch.GetOffsetHz()
			if f < 0 {
				return 0, false
			}
			return uint64(f), true
		}
	}
	return 0, false
}

// ChannelCovers reports whether hz lies within bandwidth/2 of the channel's
// absolute frequency.
func ChannelCovers(state *leylinev1.GetStateResponse, ch *leylinev1.Channel, hz uint64) bool {
	f, ok := ChannelFrequency(state, ch)
	if !ok {
		return false
	}
	half := uint64(ch.GetBandwidthHz() / 2)
	return hz+half >= f && hz <= f+half
}

// ResolveChannel finds a channel by id, id prefix, row number, or a
// frequency within bandwidth/2 of the channel's absolute frequency.
func ResolveChannel(state *leylinev1.GetStateResponse, sel string) (*leylinev1.Channel, error) {
	chans := state.GetChannels()
	ids := make([]string, len(chans))
	for i, c := range chans {
		ids[i] = c.GetChannelId()
	}
	i, err := resolveIndex("channel", sel, ids, func(i int, hz uint64) bool {
		return ChannelCovers(state, chans[i], hz)
	})
	if err != nil {
		var se *SelectorError
		if errors.As(err, &se) {
			for _, id := range se.Candidates {
				for row, c := range chans {
					if c.GetChannelId() == id {
						se.Rows = append(se.Rows, ChannelRow(state, row+1, c))
					}
				}
			}
		}
		return nil, err
	}
	return chans[i], nil
}

// ChannelRow renders one channel the way selector lists show it:
// "1  chan_01J…  146.620 MHz NFM" (row number, id, frequency, mode).
func ChannelRow(state *leylinev1.GetStateResponse, row int, ch *leylinev1.Channel) string {
	freq := "frequency unknown"
	if hz, ok := ChannelFrequency(state, ch); ok {
		freq = FormatFrequency(hz)
	}
	return fmt.Sprintf("%d  %s  %s %s", row, ch.GetChannelId(), freq, strings.ToUpper(ModeName(ch.GetMode())))
}

// ResolveJob finds a job by id, id prefix, or its row number in the list it was given, which is
// the list ListJobs returned and `ley jobs` printed. A job has no frequency of its own -- a scan
// covers a range, and matching one edge of it could select a job the user did not mean -- so a
// frequency selector is not accepted here.
func ResolveJob(jobs []*leylinev1.Job, sel string) (*leylinev1.Job, error) {
	ids := make([]string, len(jobs))
	for i, j := range jobs {
		ids[i] = j.GetJobId()
	}
	i, err := resolveIndex("job", sel, ids, nil)
	if err != nil {
		return nil, err
	}
	return jobs[i], nil
}
