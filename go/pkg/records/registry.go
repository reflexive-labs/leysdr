// SPDX-License-Identifier: Apache-2.0

package records

import (
	"sort"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// Device is one discovered transmitter in the registry: a stable id, when it was first and last
// heard, how many records it has been in, and its newest record's kind and summary. It is the
// client-side shape of the design doc's SHAPE_REGISTRY (docs/design/decoders.md, section 5, "Registry devices"):
// discovered transmitters with stable ids, first seen, last seen and an observation count,
// derived from the record log. The user-given name is not here -- a label is user data held in the
// labels store, joined in by the verb, not derived by the fold (the state boundary).
type Device struct {
	DeviceID string
	Protocol string
	// Kind and Summary come from the newest record.
	Kind    string
	Summary string
	// FirstSeen and LastSeen are on the capture timeline, the timebase every record carries; the
	// wall-clock forms are derived through the page's anchors, and are zero when no anchor covers
	// the record (AGENTS.md invariant 5: no record carries a clock).
	FirstSeen, LastSeen *leylinev1.SampleTime
	FirstWall, LastWall time.Time
	Count               int
}

// Registry is the registry fold: records in, one row per device_id out, ordered by when each was
// last heard. Unlike Table (a live table aged on arrival), the registry is a fold over the kept
// record log, which QueryRecords returns newest first, so first and last are decided by the
// records' own wall time rather than the order they are applied in. Not safe for concurrent use.
type Registry struct {
	devices map[string]*Device
	anchors []*leylinev1.RecordAnchor
}

// NewRegistry returns an empty fold.
func NewRegistry() *Registry {
	return &Registry{devices: map[string]*Device{}}
}

// Anchor adds an anchor the fold dates records by. A page carries the anchors its records need, so
// the verb hands them all over before applying the records (docs/design/decoders.md, "Decisions").
func (r *Registry) Anchor(a *leylinev1.RecordAnchor) {
	if a == nil {
		return
	}
	r.anchors = append(r.anchors, a)
}

// Apply folds one record in and returns the device it landed on. A record with no device_id is
// ignored: the protocol has no identity concept, so there is no transmitter to register.
func (r *Registry) Apply(rec *leylinev1.DecodeRecord) *Device {
	id := rec.GetDeviceId()
	if id == "" {
		return nil
	}
	wall, hasWall := leyline.RecordWallTime(rec, r.anchors)
	d := r.devices[id]
	if d == nil {
		d = &Device{
			DeviceID: id, Protocol: rec.GetProtocol(),
			Kind: rec.GetKind(), Summary: Summary(rec),
			FirstSeen: cloneTime(rec.GetTime()), LastSeen: cloneTime(rec.GetTime()),
		}
		if hasWall {
			d.FirstWall, d.LastWall = wall, wall
		}
		r.devices[id] = d
		d.Count = 1
		return d
	}
	d.Count++
	if d.Protocol == "" {
		d.Protocol = rec.GetProtocol()
	}
	// Newest wins the summary and the last-seen mark; oldest wins first-seen. A record with no
	// wall time can move neither bound: an undated record cannot be placed on the timeline.
	if hasWall {
		if d.LastWall.IsZero() || wall.After(d.LastWall) {
			d.LastWall, d.LastSeen = wall, cloneTime(rec.GetTime())
			d.Kind, d.Summary = rec.GetKind(), Summary(rec)
		}
		if d.FirstWall.IsZero() || wall.Before(d.FirstWall) {
			d.FirstWall, d.FirstSeen = wall, cloneTime(rec.GetTime())
		}
	}
	return d
}

// Rows returns the devices last-heard first, ties broken by device id so a redraw does not
// reorder rows. A device with no wall time sorts to the end, because a row that cannot be dated
// cannot count as the most recent.
func (r *Registry) Rows() []*Device {
	out := make([]*Device, 0, len(r.devices))
	for _, d := range r.devices {
		out = append(out, d)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LastWall.Equal(out[j].LastWall) {
			return out[i].LastWall.After(out[j].LastWall)
		}
		return out[i].DeviceID < out[j].DeviceID
	})
	return out
}

// Len is how many devices the fold holds.
func (r *Registry) Len() int { return len(r.devices) }
