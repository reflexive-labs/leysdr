// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"math"
	"sort"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// The decoders service, faked the way the scan job is: the shape of the contract with synthetic
// traffic behind it. One decoder is installed (`aprs`, the shape of decoders/aprs/manifest.json),
// a decode job emits records from three invented stations, and every rule the Swift daemon keeps
// is kept here -- a kept job outlives its client, a decoder name nobody installed is
// DECODER_NOT_FOUND, and a job's records replay from since_seq.

// RecordInterval is how often a fake decode job emits a record. Short enough that a test waits
// milliseconds, long enough that a person watching `ley decode` reads the lines.
const RecordInterval = 200 * time.Millisecond

// retainedRecords is the per-job replay window, as RecordHub keeps it.
const retainedRecords = 256

// FakeStoreCapBytes and FakeStoreAgeDays are the retention `ley decoders` prints.
const (
	FakeStoreCapBytes = uint64(2) << 30
	FakeStoreAgeDays  = uint32(90)
)

// AprsManifest is the one decoder the fake has installed: the shape of the real
// decoders/aprs/manifest.json, so a client rendering it here renders the real one.
func AprsManifest() *leylinev1.DecoderManifest {
	return &leylinev1.DecoderManifest{
		Name:        "aprs",
		Aliases:     []string{"packets"},
		Version:     "0.1.0",
		Description: "APRS over AX.25, AFSK 1200 baud",
		Attribution: "APRS is a trademark of Bob Bruninga, WB4APR",
		License:     "Apache-2.0",
		Recipe: &leylinev1.DecoderRecipe{
			FrequenciesHz: []uint64{144_390_000, 144_800_000},
			BandwidthHz:   15_000,
			Mode:          leylinev1.DemodMode_NFM,
			Gain:          leylinev1.GainPolicy_GAIN_LEAVE,
		},
		Input:          &leylinev1.DecoderInput{Mode: leylinev1.InputMode_CONTINUOUS, Tap: leylinev1.AudioTap_TAP_DEMOD},
		Outputs:        []leylinev1.OutputShape{leylinev1.OutputShape_SHAPE_RECORDS, leylinev1.OutputShape_SHAPE_ENTITIES},
		EntitySilenceS: 1800,
		Fields: []*leylinev1.FieldHint{
			{Name: "symbol", Type: leylinev1.FieldType_TEXT, Description: "the APRS symbol table and code"},
			{Name: "comment", Type: leylinev1.FieldType_TEXT, Description: "free text the station sent with its position"},
			{Name: "path", Type: leylinev1.FieldType_TEXT, Description: "the digipeater path the frame took"},
			{Name: "speed_kmh", Type: leylinev1.FieldType_NUMBER, Unit: "km/h"},
			{Name: "course_deg", Type: leylinev1.FieldType_NUMBER, Unit: "deg"},
			{Name: "temp_c", Type: leylinev1.FieldType_NUMBER, Unit: "degC"},
			{Name: "wind_kmh", Type: leylinev1.FieldType_NUMBER, Unit: "km/h"},
			{Name: "wind_dir_deg", Type: leylinev1.FieldType_NUMBER, Unit: "deg"},
		},
		Executable: "leydec-aprs",
	}
}

// FakeDecoderPath and FakeStorePath are the directories ListDecoders reports it looked in and
// keeps kept records under.
const (
	FakeDecoderPath = "/fake/decoders"
	FakeStorePath   = "/fake/store"
)

// ListDecoders implements Decoders.
func (d *Daemon) ListDecoders(ctx context.Context, _ *leylinev1.ListDecodersRequest) (*leylinev1.ListDecodersResponse, error) {
	d.touchUnary(clientFrom(ctx))
	return &leylinev1.ListDecodersResponse{
		Decoders:      []*leylinev1.DecoderManifest{AprsManifest()},
		SearchPath:    []string{FakeDecoderPath},
		StorePath:     FakeStorePath,
		StoreCapBytes: FakeStoreCapBytes,
		StoreAgeDays:  FakeStoreAgeDays,
	}, nil
}

// decoderByName is the registry lookup StartJob makes. Caller need not hold the lock: the fake's
// registry is a constant.
func decoderByName(name string) *leylinev1.DecoderManifest {
	if m := AprsManifest(); name == m.Name {
		return m
	}
	return nil
}

// recordSub is one open SubscribeRecords stream.
type recordSub struct {
	scope *leylinev1.RecordSubscription
	ch    chan *leylinev1.DecodeRecord
}

// admits reports whether a record is in this subscription's scope.
func (s *recordSub) admits(rec *leylinev1.DecodeRecord) bool {
	switch sc := s.scope.GetScope().(type) {
	case *leylinev1.RecordSubscription_JobId:
		return sc.JobId == rec.GetJobId()
	case *leylinev1.RecordSubscription_Protocol:
		return sc.Protocol == rec.GetProtocol()
	default:
		return true
	}
}

// offer queues a record drop-oldest, the delivery the design doc's "Decisions" states: a client
// that cannot keep up loses the oldest record and sees the hole as a seq gap.
func (s *recordSub) offer(rec *leylinev1.DecodeRecord) {
	select {
	case s.ch <- rec:
	default:
		select {
		case <-s.ch:
		default:
		}
		select {
		case s.ch <- rec:
		default:
		}
	}
}

// publishRecord fans a record out to the subscribers it is in scope for and keeps it in the
// job's replay window. Caller holds the lock.
func (d *Daemon) publishRecord(j *fakeJob, rec *leylinev1.DecodeRecord) {
	j.records = append(j.records, proto.Clone(rec).(*leylinev1.DecodeRecord))
	if n := len(j.records) - retainedRecords; n > 0 {
		j.records = j.records[n:]
	}
	if j.keep {
		if s := d.storeFor(j); s != nil {
			s.records = append(s.records, proto.Clone(rec).(*leylinev1.DecodeRecord))
		}
	}
	for sub := range d.recordSubs {
		if sub.admits(rec) {
			sub.offer(proto.Clone(rec).(*leylinev1.DecodeRecord))
		}
	}
}

// storedJob is one kept job's file in the fake store: its records and every anchor that was in
// force while it ran, which is what a wall-clock query is answered through.
type storedJob struct {
	jobID    string
	protocol string
	anchors  []*leylinev1.RecordAnchor
	records  []*leylinev1.DecodeRecord
}

// storeFor returns the kept job's store entry, opening one the first time. Caller holds the lock.
func (d *Daemon) storeFor(j *fakeJob) *storedJob {
	for _, s := range d.store {
		if s.jobID == j.proto.GetJobId() {
			return s
		}
	}
	s := &storedJob{jobID: j.proto.GetJobId(), protocol: j.protocol}
	if c := d.captures[j.captureID]; c != nil && c.Anchor != nil {
		s.anchors = append(s.anchors, &leylinev1.RecordAnchor{Anchor: proto.Clone(c.Anchor).(*leylinev1.CaptureAnchor)})
	}
	d.store = append(d.store, s)
	return s
}

// SubscribeRecords implements Decoders: the retained window first when the request asks for it,
// then live, until the client goes away or the daemon shuts down.
func (d *Daemon) SubscribeRecords(sub *leylinev1.RecordSubscription, srv grpc.ServerStreamingServer[leylinev1.DecodeRecord]) error {
	ctx, cancel := d.streamContext(srv.Context())
	defer cancel()
	defer d.streamOpened(ctx)()

	s := &recordSub{scope: sub, ch: make(chan *leylinev1.DecodeRecord, 64)}
	d.mu.Lock()
	// Replay and registration happen under one lock, so a record published between them can
	// neither be missed nor sent twice.
	replay := d.replayLocked(sub)
	d.recordSubs[s] = struct{}{}
	d.mu.Unlock()
	defer func() {
		d.mu.Lock()
		delete(d.recordSubs, s)
		d.mu.Unlock()
	}()

	for _, rec := range replay {
		if err := srv.Send(rec); err != nil {
			return err
		}
	}
	for {
		select {
		case <-ctx.Done():
			return nil
		case rec := <-s.ch:
			if err := srv.Send(rec); err != nil {
				return err
			}
		}
	}
}

// replayLocked is the retained window a job-scoped subscription asked for: every retained record
// after since_seq. Only the job scope replays, as decode.proto states.
func (d *Daemon) replayLocked(sub *leylinev1.RecordSubscription) []*leylinev1.DecodeRecord {
	scope, ok := sub.GetScope().(*leylinev1.RecordSubscription_JobId)
	if !ok || sub.SinceSeq == nil {
		return nil
	}
	j := d.jobs[scope.JobId]
	if j == nil {
		return nil
	}
	var out []*leylinev1.DecodeRecord
	for _, rec := range j.records {
		if rec.GetSeq() > sub.GetSinceSeq() {
			out = append(out, proto.Clone(rec).(*leylinev1.DecodeRecord))
		}
	}
	return out
}

// QueryRecords implements Decoders: the kept jobs' records, filtered and newest first.
func (d *Daemon) QueryRecords(ctx context.Context, q *leylinev1.RecordQuery) (*leylinev1.RecordPage, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	limit := int(q.GetLimit())
	if limit <= 0 {
		limit = 1000
	}
	page := &leylinev1.RecordPage{}
	anchors := map[string]*leylinev1.RecordAnchor{}
	var matched []*leylinev1.DecodeRecord
	for _, s := range d.store {
		if q.GetProtocol() != "" && q.GetProtocol() != s.protocol {
			continue
		}
		if q.GetJobId() != "" && q.GetJobId() != s.jobID {
			continue
		}
		// A job with no record from the requested transmitter is skipped whole, the way the store
		// skips a file whose protocol or span cannot match.
		if q.GetDeviceId() != "" && !s.hasDevice(q.GetDeviceId()) {
			continue
		}
		for _, rec := range s.records {
			if !matchesQuery(rec, q, s.anchors) {
				continue
			}
			matched = append(matched, proto.Clone(rec).(*leylinev1.DecodeRecord))
			for _, a := range s.anchors {
				anchors[a.GetAnchor().GetCaptureId()] = a
			}
		}
	}
	// Newest first, which for records on one timeline is the seq the daemon stamped them with.
	sortRecordsNewestFirst(matched)
	if len(matched) > limit {
		matched, page.Truncated = matched[:limit], true
	}
	page.Records = matched
	for _, a := range anchors {
		page.Anchors = append(page.Anchors, proto.Clone(a).(*leylinev1.RecordAnchor))
	}
	sortByID(page.Anchors, func(a *leylinev1.RecordAnchor) string { return a.GetAnchor().GetCaptureId() })
	return page, nil
}

// hasDevice reports whether a kept job has a record from the named transmitter. The query's
// device_id names the transmitter, not the radio, so a job is only skipped when none of its
// records match.
func (s *storedJob) hasDevice(id string) bool {
	for _, rec := range s.records {
		if rec.GetDeviceId() == id {
			return true
		}
	}
	return false
}

func sortRecordsNewestFirst(recs []*leylinev1.DecodeRecord) {
	sort.SliceStable(recs, func(i, j int) bool {
		a, b := recs[i], recs[j]
		if a.GetJobId() == b.GetJobId() {
			return a.GetSeq() > b.GetSeq()
		}
		// Job ids are ULIDs, so the later job sorts last and its records come first.
		return a.GetJobId() > b.GetJobId()
	})
}

// matchesQuery applies every filter a RecordQuery carries. Wall-clock bounds are answered
// through the job's anchors, as the store does: no record carries a clock of its own.
func matchesQuery(rec *leylinev1.DecodeRecord, q *leylinev1.RecordQuery, anchors []*leylinev1.RecordAnchor) bool {
	if q.GetDeviceId() != "" && rec.GetDeviceId() != q.GetDeviceId() {
		return false
	}
	if q.GetKind() != "" && rec.GetKind() != q.GetKind() {
		return false
	}
	if q.GetSinceNs() > 0 || q.GetUntilNs() > 0 {
		at, ok := leyline.RecordWallTime(rec, anchors)
		if !ok {
			return false
		}
		if q.GetSinceNs() > 0 && at.UnixNano() < q.GetSinceNs() {
			return false
		}
		if q.GetUntilNs() > 0 && at.UnixNano() > q.GetUntilNs() {
			return false
		}
	}
	if q.GetInEffect() {
		now := time.Now().UnixNano()
		v := rec.GetValidity()
		if v == nil || (v.GetStartNs() > 0 && now < v.GetStartNs()) || (v.GetEndNs() > 0 && now > v.GetEndNs()) {
			return false
		}
	}
	if near := q.GetNear(); near != nil && q.GetRadiusM() > 0 {
		p := rec.GetPosition()
		if p == nil || HaversineMetres(near, p) > q.GetRadiusM() {
			return false
		}
	}
	for _, f := range q.GetFields() {
		if !proto.Equal(rec.GetFields()[f.GetName()], f.GetEquals()) {
			return false
		}
	}
	return true
}

// HaversineMetres is the great-circle distance between two positions, which is what a spatial
// filter means by "within 10 km of here".
func HaversineMetres(a, b *leylinev1.Position) float64 {
	const earthM = 6_371_000.0
	rad := math.Pi / 180
	lat1, lat2 := a.GetLatitude()*rad, b.GetLatitude()*rad
	dLat, dLon := lat2-lat1, (b.GetLongitude()-a.GetLongitude())*rad
	h := math.Sin(dLat/2)*math.Sin(dLat/2) + math.Cos(lat1)*math.Cos(lat2)*math.Sin(dLon/2)*math.Sin(dLon/2)
	return 2 * earthM * math.Asin(math.Min(1, math.Sqrt(h)))
}
