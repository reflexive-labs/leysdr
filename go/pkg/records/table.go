// SPDX-License-Identifier: Apache-2.0

package records

import (
	"sort"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// Entity is one transmitter as the fold has built it: the newest value of every field it has
// sent, its last reported position, when it was first and last heard, and how many records it has
// been in. It is the client-side shape of the design doc's SHAPE_ENTITIES
// (docs/design/decoders.md, "Decisions"), so a decoder that declares entities needs no
// daemon-side state for a table to be drawn.
type Entity struct {
	DeviceID string
	Protocol string
	// Kind and Summary come from the last record.
	Kind    string
	Summary string
	// Fields is the newest value of every field the station has sent, merged across records: a
	// weather station that reports wind in one packet and temperature in the next has both.
	Fields   map[string]*leylinev1.FieldValue
	Position *leylinev1.Position
	// FirstSeen and LastSeen are on the capture's timeline, the timebase every record carries.
	FirstSeen, LastSeen *leylinev1.SampleTime
	// FirstWall and LastWall are those two turned into wall clock through an anchor, and are
	// zero when no anchor covers the record (AGENTS.md invariant 5: no record carries a clock).
	FirstWall, LastWall time.Time
	// FirstHeard and LastHeard are the table's own clock: when the record reached this client.
	// Ages and Expire run on these, because a record whose capture has no anchor still has to
	// age out of a live table.
	FirstHeard, LastHeard time.Time
	Count                 int
	// Heard is when each record reached this client, oldest first, on the same clock: the
	// series behind a row's activity sparkline. Expire trims it to the silence window, and a
	// table that never expires keeps the newest heardCap, so an all-night watch stays bounded.
	Heard []time.Time
}

// heardCap bounds Entity.Heard when no silence window trims it.
const heardCap = 1024

// Table is the entity fold: records in, one row per device_id out. It is not safe for concurrent
// use; the verb that owns it applies records and reads rows on one goroutine.
type Table struct {
	// Now is the clock Apply and Expire read, so a test can hold time still. nil means time.Now.
	Now      func() time.Time
	entities map[string]*Entity
	anchors  map[string]*leylinev1.CaptureAnchor
}

// NewTable returns an empty fold.
func NewTable() *Table {
	return &Table{entities: map[string]*Entity{}, anchors: map[string]*leylinev1.CaptureAnchor{}}
}

func (t *Table) now() time.Time {
	if t.Now != nil {
		return t.Now()
	}
	return time.Now()
}

// Anchor tells the fold how one capture's sample times map to wall clock. Records applied after
// it carry a wall time; records applied before it keep the sample time they always had, because
// a row is not rewritten by a later anchor.
func (t *Table) Anchor(a *leylinev1.CaptureAnchor) {
	if a.GetCaptureId() == "" {
		return
	}
	t.anchors[a.GetCaptureId()] = a
}

// Apply folds one record in and returns the entity it landed on. A record with no device_id is
// ignored: the protocol has no identity concept, so there is no row to keep it in.
func (t *Table) Apply(rec *leylinev1.DecodeRecord) *Entity {
	id := rec.GetDeviceId()
	if id == "" {
		return nil
	}
	now := t.now()
	e := t.entities[id]
	if e == nil {
		e = &Entity{
			DeviceID: id, Protocol: rec.GetProtocol(),
			Fields: map[string]*leylinev1.FieldValue{}, FirstHeard: now,
		}
		e.FirstSeen = cloneTime(rec.GetTime())
		e.FirstWall, _ = t.wall(rec)
		t.entities[id] = e
	}
	if e.Protocol == "" {
		e.Protocol = rec.GetProtocol()
	}
	for name, v := range rec.GetFields() {
		e.Fields[name] = proto.Clone(v).(*leylinev1.FieldValue)
	}
	if p := rec.GetPosition(); p != nil {
		e.Position = proto.Clone(p).(*leylinev1.Position)
	}
	e.Kind, e.Summary = rec.GetKind(), Summary(rec)
	e.LastSeen = cloneTime(rec.GetTime())
	if w, ok := t.wall(rec); ok {
		e.LastWall = w
	}
	e.LastHeard = now
	e.Count++
	e.Heard = append(e.Heard, now)
	if len(e.Heard) > heardCap {
		e.Heard = e.Heard[len(e.Heard)-heardCap:]
	}
	return e
}

// HeardSince returns the entity's arrival times at or after cutoff, oldest first.
func (e *Entity) HeardSince(cutoff time.Time) []time.Time {
	i := 0
	for i < len(e.Heard) && e.Heard[i].Before(cutoff) {
		i++
	}
	return e.Heard[i:]
}

// wall derives a record's wall clock from the anchor of the capture it was decoded on.
func (t *Table) wall(rec *leylinev1.DecodeRecord) (time.Time, bool) {
	a := t.anchors[rec.GetTime().GetCaptureId()]
	if a == nil {
		return time.Time{}, false
	}
	return leyline.AnchorWallTime(a, rec.GetTime().GetSampleIndex())
}

// Expire drops every entity silent for longer than the decoder's silence timeout and returns how
// many went. A timeout of zero means never, which is what a manifest's entity_silence_s of 0
// declares.
func (t *Table) Expire(now time.Time, silence time.Duration) int {
	if silence <= 0 {
		return 0
	}
	gone := 0
	cutoff := now.Add(-silence)
	for id, e := range t.entities {
		if now.Sub(e.LastHeard) > silence {
			delete(t.entities, id)
			gone++
			continue
		}
		e.Heard = e.HeardSince(cutoff)
	}
	return gone
}

// Rows returns the entities newest first, ties broken by device id so a redraw of an unchanged
// table does not reorder rows.
func (t *Table) Rows() []*Entity {
	out := make([]*Entity, 0, len(t.entities))
	for _, e := range t.entities {
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].LastHeard.Equal(out[j].LastHeard) {
			return out[i].LastHeard.After(out[j].LastHeard)
		}
		return out[i].DeviceID < out[j].DeviceID
	})
	return out
}

// Len is how many entities the fold holds.
func (t *Table) Len() int { return len(t.entities) }

func cloneTime(st *leylinev1.SampleTime) *leylinev1.SampleTime {
	if st == nil {
		return nil
	}
	return proto.Clone(st).(*leylinev1.SampleTime)
}
