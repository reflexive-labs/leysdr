// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"math"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// startDecode is Jobs.StartJob(decode) in the fake: look the decoder up, take a capture and a
// channel the way SessionCaptureAllocator does, and run a goroutine that emits records. The
// allocation failures the daemon answers synchronously (an unknown decoder, a radio somebody
// else is using) are answered synchronously here too, so a client exercises the same paths.
func (d *Daemon) startDecode(ctx context.Context, cfg *leylinev1.DecodeConfig) (*leylinev1.Job, error) {
	man := decoderByName(cfg.GetDecoder())
	if man == nil {
		return nil, fail(ctx, errorf(leyline.CodeDecoderNotFound, cfg.GetDecoder(),
			"no decoder called "+quoted(cfg.GetDecoder())+" is installed"))
	}
	hz := cfg.GetFrequencyHz()
	if hz == 0 && len(man.GetRecipe().GetFrequenciesHz()) > 0 {
		hz = man.GetRecipe().GetFrequenciesHz()[0]
	}
	bw := man.GetRecipe().GetBandwidthHz()
	ci := clientFrom(ctx)
	d.touchUnary(ci)

	d.mu.Lock()
	lease, err := d.leaseChannelLocked(ci, cfg, hz, bw, man.GetRecipe().GetMode())
	if err != nil {
		d.mu.Unlock()
		return nil, fail(ctx, err)
	}
	job := &leylinev1.Job{
		JobId:        newID("job_"),
		State:        leylinev1.JobState_RUNNING,
		CreatedAtNs:  time.Now().UnixNano(),
		CreatedBy:    ci,
		Config:       &leylinev1.Job_Decode{Decode: proto.Clone(cfg).(*leylinev1.DecodeConfig)},
		StatusDetail: fmt.Sprintf("decoding %s on %s", man.GetName(), leyline.FormatFrequency(hz)),
	}
	if cfg.GetKeep() {
		job.ResultUris = []string{"ley://records/" + job.JobId}
	}
	fj := &fakeJob{
		proto: job, owner: ci.GetClientId(), protocol: man.GetName(), keep: cfg.GetKeep(),
		channelID: lease.channelID, captureID: lease.captureID, createdCapture: lease.created,
	}
	d.jobs[job.JobId] = fj
	d.jobOrder = append(d.jobOrder, job.JobId)
	d.trimJobsLocked()
	if cfg.GetKeep() {
		d.storeFor(fj)
	}
	d.emit(byDaemon(), job)
	reply := proto.Clone(job).(*leylinev1.Job)
	d.mu.Unlock()

	go d.runDecode(job.JobId, man)
	return reply, nil
}

func quoted(s string) string { return "\"" + s + "\"" }

// channelLease is what the allocator hands a decode job: the channel it owns, the capture under
// it, and whether the capture is the job's to destroy when it ends.
type channelLease struct {
	channelID, captureID, deviceID string
	created                        bool
}

// leaseChannelLocked is the allocator's order from docs/design/decoders.md, "Decisions": a
// capture that already covers the frequency, else a radio with no capture, else a capture
// nobody is using, else declined naming who has it. Caller holds the lock.
func (d *Daemon) leaseChannelLocked(ci *leylinev1.ClientInfo, cfg *leylinev1.DecodeConfig,
	hz uint64, bw uint32, mode leylinev1.DemodMode,
) (channelLease, *leyline.Error) {
	var lease channelLease
	for _, c := range d.captures {
		if cfg.GetDeviceId() != "" && c.DeviceId != cfg.GetDeviceId() {
			continue
		}
		if !captureCovers(c, hz, bw) {
			continue
		}
		if !cfg.GetTakeOver() {
			if why := d.busyReason(c.DeviceId); why != "" {
				return lease, errorf(leyline.CodeDeviceBusy, c.DeviceId, why)
			}
		}
		lease.captureID, lease.deviceID = c.CaptureId, c.DeviceId
		break
	}
	if lease.captureID == "" {
		dev := d.scanDevice(cfg.GetDeviceId(), &leylinev1.FrequencyRange{MinHz: hz, MaxHz: hz + 1})
		if dev == nil {
			return lease, errorf(leyline.CodeNoDevice, cfg.GetDeviceId(),
				"no radio here can tune "+leyline.FormatFrequency(hz))
		}
		if !cfg.GetTakeOver() {
			if why := d.busyReason(dev.DeviceId); why != "" {
				return lease, errorf(leyline.CodeDeviceBusy, dev.DeviceId, why)
			}
		}
		c, err := d.createJobCaptureLocked(dev, hz)
		if err != nil {
			return lease, err
		}
		lease.captureID, lease.deviceID, lease.created = c.CaptureId, dev.DeviceId, true
	}
	c := d.captures[lease.captureID]
	owner := &leylinev1.ClientInfo{ClientId: ci.GetClientId(), Kind: "job", Label: "decode"}
	ch := &leylinev1.Channel{
		ChannelId:        newID("chan_"),
		CaptureId:        c.CaptureId,
		OffsetHz:         int64(hz) - int64(c.CenterHz),
		BandwidthHz:      bw,
		Mode:             mode,
		SquelchDb:        noSquelch,
		Agc:              leylinev1.GainMode_AUTO,
		State:            leylinev1.ChannelState_CHANNEL_ACTIVE,
		SubaudibleDetect: false,
		Persistent:       true,
		RequiredHz:       hz,
		Owner:            owner,
	}
	d.channels[ch.ChannelId] = ch
	d.emit(owner, ch)
	lease.channelID = ch.ChannelId
	return lease, nil
}

// createJobCaptureLocked makes the capture a decode job needs, centred so the channel sits clear
// of the tuner's own DC spike and inside the flat part of the passband (the allocator's
// frequency - Fs/8).
func (d *Daemon) createJobCaptureLocked(dev *leylinev1.DeviceDescriptor, hz uint64) (*capture, *leyline.Error) {
	rate := RTLSDRDefaultRate
	if dev.Driver == "file" && len(dev.SampleRates) > 0 {
		rate = dev.SampleRates[0]
	}
	centre := hz - rate/8
	if !inRange(dev, centre) {
		centre = hz
	}
	if !inRange(dev, centre) {
		return nil, errorf(leyline.CodeFreqOutOfRange, dev.DeviceId,
			leyline.FormatFrequency(hz)+" is outside this radio's tuning range")
	}
	now := time.Now()
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "job", Label: "decode"}
	c := &capture{startedAt: now, manualGain: map[string]float64{}, Capture: &leylinev1.Capture{
		CaptureId:  newID("cap_"),
		DeviceId:   dev.DeviceId,
		CenterHz:   centre,
		SampleRate: rate,
		State:      leylinev1.CaptureState_CAPTURE_ACTIVE,
		Activity:   &leylinev1.CaptureActivity{},
		CreatedBy:  by,
	}}
	c.Anchor = &leylinev1.CaptureAnchor{CaptureId: c.CaptureId, HostTimeNs: now.UnixNano(), SampleRate: rate}
	c.file = d.files[dev.DeviceId]
	for _, el := range dev.GainElements {
		c.Gains = append(c.Gains, &leylinev1.GainState{Element: el.Name, Auto: el.SupportsAuto, Db: leyline.SnapGain(el, el.MaxDb/2)})
	}
	d.captures[c.CaptureId] = c
	dev.State = leylinev1.DeviceState_IN_USE
	d.emit(by, dev)
	d.emit(by, c.Capture)
	d.emit(by, c.Anchor)
	return c, nil
}

// captureCovers reports whether a channel of this width fits inside the capture at hz, the
// allocator's test: |offset| + bw/2 <= Fs/2, and not a capture a sweep is walking.
func captureCovers(c *capture, hz uint64, bw uint32) bool {
	offset := float64(int64(hz) - int64(c.CenterHz))
	if offset < 0 {
		offset = -offset
	}
	return offset+float64(bw)/2 <= float64(c.SampleRate)/2
}

// noSquelch is the channel's squelch: a decoder wants every sample, so nothing is muted.
var noSquelch = math.NaN()

// fakeStations is the traffic a fake decode job hears: three invented stations, one of each of
// the record forms a client has to render. The callsigns are in the LEYTST- block, which no real
// amateur licence issues, so a record from the fake can never be mistaken for one off the air.
var fakeStations = []func(now uint64) *leylinev1.DecodeRecord{
	func(uint64) *leylinev1.DecodeRecord {
		return &leylinev1.DecodeRecord{
			DeviceId: "LEYTST-1", Kind: "position",
			Position: &leylinev1.Position{Latitude: 37.76, Longitude: -122.42},
			Fields: map[string]*leylinev1.FieldValue{
				"symbol":  textField("/>"),
				"comment": textField("fake station, no radio involved"),
				"path":    textField("WIDE1-1"),
			},
			Raw: []byte("LEYTST-1>APRS,WIDE1-1:!3745.60N/12225.20W>fake"),
		}
	},
	func(n uint64) *leylinev1.DecodeRecord {
		return &leylinev1.DecodeRecord{
			DeviceId: "LEYTST-2", Kind: "weather",
			Fields: map[string]*leylinev1.FieldValue{
				"temp_c":       numberField(21 + float64(n%3)),
				"wind_kmh":     numberField(12),
				"wind_dir_deg": numberField(270),
				"humidity_pct": numberField(64),
			},
			Raw: []byte("LEYTST-2>APRS:_c270s007g011t070h64"),
		}
	},
	func(uint64) *leylinev1.DecodeRecord {
		return &leylinev1.DecodeRecord{
			DeviceId: "LEYTST-3", Kind: "status",
			Fields: map[string]*leylinev1.FieldValue{"text": textField("fake daemon, monitoring nothing")},
			Raw:    []byte("LEYTST-3>APRS:>fake daemon, monitoring nothing"),
		}
	},
}

func textField(s string) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Text{Text: s}}
}

func numberField(v float64) *leylinev1.FieldValue {
	return &leylinev1.FieldValue{Value: &leylinev1.FieldValue_Number{Number: v}}
}

// runDecode emits a record every RecordInterval until the job is cancelled, stamping each one the
// way the daemon does: record id, job, seq, channel, and the levels the channel's meter read.
func (d *Daemon) runDecode(jobID string, man *leylinev1.DecoderManifest) {
	for n := uint64(0); ; n++ {
		time.Sleep(RecordInterval)
		if d.jobCancelled(jobID) {
			d.finishDecode(jobID)
			return
		}
		d.mu.Lock()
		j := d.jobs[jobID]
		if j == nil || j.proto.State != leylinev1.JobState_RUNNING {
			d.mu.Unlock()
			continue
		}
		rec := fakeStations[n%uint64(len(fakeStations))](n)
		rec.Protocol = man.GetName()
		rec.RecordId = newID("rec_")
		rec.JobId = jobID
		rec.ChannelId = j.channelID
		j.seq++
		rec.Seq = j.seq
		rec.RssiDbfs, rec.SnrDb = fakeRecordRssiDbfs, fakeRecordSnrDb
		rec.Time = &leylinev1.SampleTime{CaptureId: j.captureID}
		if c := d.captures[j.captureID]; c != nil {
			rec.Time.SampleIndex = c.sampleIndex(time.Now())
		}
		d.publishRecord(j, rec)
		d.mu.Unlock()
	}
}

// The levels the fake channel's meter reads. A plugin never measures these: the daemon stamps
// them from the channel it decoded on (docs/design/decoders.md, "Decisions").
const (
	fakeRecordRssiDbfs = -25.0
	fakeRecordSnrDb    = 20.0
)

// finishDecode ends a decode job: the channel goes, the capture goes with it when the job made
// it, and the terminal Job event goes out last, so a client that sees the job end finds the
// radio already handed back.
func (d *Daemon) finishDecode(jobID string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	j := d.jobs[jobID]
	if j == nil {
		return
	}
	by := &leylinev1.ClientInfo{ClientId: "daemon", Kind: "job", Label: "decode"}
	if j.channelID != "" {
		d.destroyChannelLocked(j.channelID, by)
		j.channelID = ""
	}
	if j.createdCapture && j.captureID != "" {
		d.destroyCaptureLocked(j.captureID, by)
		j.createdCapture = false
	}
	if j.proto.State != leylinev1.JobState_RUNNING {
		return
	}
	j.proto.State = leylinev1.JobState_CANCELLED
	j.proto.StatusDetail = fmt.Sprintf("stopped after %d records", j.seq)
	d.emit(byDaemon(), j.proto)
	d.trimJobsLocked()
}
