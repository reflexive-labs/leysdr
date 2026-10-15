// SPDX-License-Identifier: Apache-2.0

package plugin_test

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"os"
	"slices"
	"strings"
	"testing"
	"time"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/plugin"
)

// segmentEcho emits one record per segment carrying its length in samples (as device_id) and its
// time, and keeps a copy of every segment it was handed.
type segmentEcho struct {
	cred     *leylinev1.SetCredentialRequest
	segments [][]float32
}

func (d *segmentEcho) Segment(samples []float32, at *leylinev1.SampleTime, emit func(*leylinev1.DecodeRecord)) {
	d.segments = append(d.segments, append([]float32{}, samples...))
	emit(&leylinev1.DecodeRecord{Protocol: "speech", Time: at, Raw: []byte{byte(len(samples))}})
}

func f32(vals ...float32) []byte {
	out := make([]byte, 0, 4*len(vals))
	for _, v := range vals {
		out = binary.LittleEndian.AppendUint32(out, math.Float32bits(v))
	}
	return out
}

func segFrame(seq, sample uint64, mark leylinev1.SegmentMark, payload []byte) *leylinev1.Frame {
	return &leylinev1.Frame{
		StreamId: "str_1", Seq: seq, Segment: mark, Payload: payload,
		Time: &leylinev1.SampleTime{CaptureId: "cap_1", SampleIndex: sample},
	}
}

func runSegmented(t *testing.T, in *bytes.Buffer, provider string) (*segmentEcho, []*leylinev1.DecodeRecord) {
	t.Helper()
	dec := &segmentEcho{}
	var out bytes.Buffer
	err := plugin.RunSegmentedStreams(t.Context(), in, &out, provider, func(_ uint32, cred *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
		dec.cred = cred
		return dec
	})
	if err != nil {
		t.Fatal(err)
	}
	return dec, readRecords(t, out.Bytes())
}

// Two segments back to back, the first spread over three frames with a gap inside it: one
// Segment call each, the first holding every sample with silence where the gap was, and each
// record stamped with its START frame's time.
func TestRunSegmentedAssemblesSegments(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	start := leylinev1.SegmentMark_SEGMENT_START
	end := leylinev1.SegmentMark_SEGMENT_END
	none := leylinev1.SegmentMark_SEGMENT_MARK_UNSPECIFIED
	mustMarshal(t, &in, segFrame(1, 1000, start, f32(0.1, 0.2)))
	mustMarshal(t, &in, segFrame(2, 1010, none, f32(0.3)))
	// The descriptor's capture runs at five times the audio rate, so 10 capture samples lost
	// are two audio samples of silence.
	gapped := segFrame(3, 1025, none, f32(0.4))
	gapped.Gap = &leylinev1.Gap{FromSample: 1015, ToSample: 1025}
	mustMarshal(t, &in, gapped)
	mustMarshal(t, &in, segFrame(4, 1030, end, nil))
	mustMarshal(t, &in, segFrame(5, 1030, start, f32(0.5)))
	mustMarshal(t, &in, segFrame(6, 1035, end, nil))

	dec, recs := runSegmented(t, &in, "")
	want := [][]float32{{0.1, 0.2, 0.3, 0, 0, 0.4}, {0.5}}
	if len(dec.segments) != len(want) {
		t.Fatalf("got %d segments, want %d: %v", len(dec.segments), len(want), dec.segments)
	}
	for i := range want {
		if len(dec.segments[i]) != len(want[i]) {
			t.Fatalf("segment %d = %v, want %v", i+1, dec.segments[i], want[i])
		}
		for j := range want[i] {
			if dec.segments[i][j] != want[i][j] {
				t.Errorf("segment %d sample %d = %v, want %v", i+1, j, dec.segments[i][j], want[i][j])
			}
		}
	}
	if len(recs) != 2 || recs[0].GetTime().GetSampleIndex() != 1000 || recs[1].GetTime().GetSampleIndex() != 1030 {
		t.Errorf("records are not stamped with their START frames' times: %v", recs)
	}
	if dec.cred != nil {
		t.Errorf("a manifest with no credential_provider got a key: %v", dec.cred)
	}
}

// Audio outside a segment, an END with no START, and a segment that never ends are dropped
// rather than decoded as a fragment.
func TestRunSegmentedDropsWhatIsNotAWholeSegment(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	mustMarshal(t, &in, segFrame(1, 100, leylinev1.SegmentMark_SEGMENT_MARK_UNSPECIFIED, f32(1)))
	mustMarshal(t, &in, segFrame(2, 105, leylinev1.SegmentMark_SEGMENT_END, nil))
	mustMarshal(t, &in, segFrame(3, 200, leylinev1.SegmentMark_SEGMENT_START, f32(1, 1)))
	// A second START before the first ended: the first is dropped, the second decoded.
	mustMarshal(t, &in, segFrame(4, 300, leylinev1.SegmentMark_SEGMENT_START, f32(0.5)))
	mustMarshal(t, &in, segFrame(5, 305, leylinev1.SegmentMark_SEGMENT_END, nil))
	// Input ends inside a segment: the job stopped mid-over.
	mustMarshal(t, &in, segFrame(6, 400, leylinev1.SegmentMark_SEGMENT_START, f32(1)))

	var log bytes.Buffer
	defer plugin.SetSegmentLog(&log)()
	dec, recs := runSegmented(t, &in, "")
	if !strings.Contains(log.String(), "plugin: segment 3 cut off by end of input, dropped") {
		t.Errorf("the segment cut off by the end of input was not logged:\n%s", log.String())
	}
	if len(dec.segments) != 1 || len(dec.segments[0]) != 1 || dec.segments[0][0] != 0.5 {
		t.Errorf("want only the one whole segment [0.5], got %v", dec.segments)
	}
	if len(recs) != 1 || recs[0].GetTime().GetSampleIndex() != 300 {
		t.Errorf("records = %v", recs)
	}
}

// A segment longer than MaxSegment is dropped whole, and the next one still decodes.
func TestRunSegmentedDropsASegmentOverTheLimit(t *testing.T) {
	var in bytes.Buffer
	// At 10 Hz, ten minutes is 6000 samples: small enough to send, so the limit is the real one.
	desc := descriptor(leylinev1.AudioSampleFormat_F32)
	desc.GetAudio().SampleRate = 10
	desc.SpanHz = 10
	mustMarshal(t, &in, desc)
	limit := int(plugin.MaxSegment.Seconds() * 10)
	block := make([]float32, 1000)
	mustMarshal(t, &in, segFrame(1, 0, leylinev1.SegmentMark_SEGMENT_START, f32(block...)))
	for i := 1; i <= limit/len(block); i++ {
		mustMarshal(t, &in, segFrame(uint64(i+1), uint64(i*len(block)), leylinev1.SegmentMark_SEGMENT_MARK_UNSPECIFIED, f32(block...)))
	}
	mustMarshal(t, &in, segFrame(100, 7000, leylinev1.SegmentMark_SEGMENT_END, nil))
	mustMarshal(t, &in, segFrame(101, 8000, leylinev1.SegmentMark_SEGMENT_START, f32(0.25)))
	mustMarshal(t, &in, segFrame(102, 8001, leylinev1.SegmentMark_SEGMENT_END, nil))

	dec, _ := runSegmented(t, &in, "")
	if len(dec.segments) != 1 || len(dec.segments[0]) != 1 {
		t.Errorf("want the over-long segment dropped and the short one decoded, got %d segments", len(dec.segments))
	}
}

// A manifest that names a provider reads the key before the descriptor, and the decoder is built
// with it.
func TestRunSegmentedReadsTheKeyFirst(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.SetCredentialRequest{Provider: "deepgram", Secret: "dg-secret", Endpoint: "https://example.test"})
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	mustMarshal(t, &in, segFrame(1, 10, leylinev1.SegmentMark_SEGMENT_START, f32(0.5)))
	mustMarshal(t, &in, segFrame(2, 15, leylinev1.SegmentMark_SEGMENT_END, nil))

	dec, recs := runSegmented(t, &in, "deepgram")
	if dec.cred.GetSecret() != "dg-secret" || dec.cred.GetProvider() != "deepgram" || dec.cred.GetEndpoint() != "https://example.test" {
		t.Errorf("the decoder got %v", dec.cred)
	}
	if len(recs) != 1 {
		t.Errorf("want 1 record after the key, got %d", len(recs))
	}
}

// The daemon goes by the installed manifest, which may name a provider the binary's own does not:
// with KeyOnStdinEnv set, RunSegmented reads the key first although its built-in provider is
// empty, and the decoder is built with it.
func TestRunSegmentedReadsTheKeyTheEnvironmentAnnounces(t *testing.T) {
	t.Setenv(plugin.KeyOnStdinEnv, "1")
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: "sk-ant-env"})
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	mustMarshal(t, &in, segFrame(1, 10, leylinev1.SegmentMark_SEGMENT_START, f32(0.5)))
	mustMarshal(t, &in, segFrame(2, 15, leylinev1.SegmentMark_SEGMENT_END, nil))
	stdout := swapStdio(t, in.Bytes())

	dec := &segmentEcho{}
	err := plugin.RunSegmented(t.Context(), "", func(_ uint32, cred *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
		dec.cred = cred
		return dec
	})
	if err != nil {
		t.Fatal(err)
	}
	if dec.cred.GetSecret() != "sk-ant-env" || dec.cred.GetProvider() != "anthropic" {
		t.Errorf("the decoder got %v", dec.cred)
	}
	if recs := readRecords(t, stdout()); len(recs) != 1 {
		t.Errorf("want 1 record after the key, got %d", len(recs))
	}
}

// RunStreams reads the key the environment announces and drops it, so the descriptor after it is
// read as the descriptor.
func TestRunStreamsSkipsTheKeyTheEnvironmentAnnounces(t *testing.T) {
	t.Setenv(plugin.KeyOnStdinEnv, "1")
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.SetCredentialRequest{Provider: "anthropic", Secret: "sk-ant-env"})
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	dec := &echoDecoder{}
	if err := plugin.RunStreams(t.Context(), &in, &bytes.Buffer{}, func(uint32) plugin.Decoder { return dec }); err != nil {
		t.Fatal(err)
	}
	if dec.capID != "str_1" {
		t.Errorf("the decoder started on %q, want the descriptor after the key", dec.capID)
	}
}

// swapStdio points os.Stdin at a pipe holding input and os.Stdout at a file, for the length of the
// test, and returns what was written to stdout as a function to call once the run has returned.
func swapStdio(t *testing.T, input []byte) func() []byte {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		_, _ = w.Write(input)
		_ = w.Close()
	}()
	out, err := os.CreateTemp(t.TempDir(), "stdout")
	if err != nil {
		t.Fatal(err)
	}
	oldIn, oldOut := os.Stdin, os.Stdout
	os.Stdin, os.Stdout = r, out
	t.Cleanup(func() {
		os.Stdin, os.Stdout = oldIn, oldOut
		_ = r.Close()
		_ = out.Close()
	})
	return func() []byte {
		b, err := os.ReadFile(out.Name())
		if err != nil {
			t.Fatal(err)
		}
		return b
	}
}

// A plugin that needs a key and gets none stops with an error naming what was missing.
func TestRunSegmentedRefusesToRunWithoutTheKey(t *testing.T) {
	var out bytes.Buffer
	err := plugin.RunSegmentedStreams(t.Context(), &bytes.Buffer{}, &out, "deepgram", func(uint32, *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
		return &segmentEcho{}
	})
	if err == nil || !strings.Contains(err.Error(), "key") {
		t.Errorf("want an error about the key, got %v", err)
	}
}

// ReadCredential consumes the key and nothing after it, even from a reader that cannot read one
// byte at a time, so the descriptor that follows is still there.
func TestReadCredentialLeavesTheDescriptor(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, &leylinev1.SetCredentialRequest{Provider: "openai", Secret: "sk-1"})
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	r := io.MultiReader(&in) // not an io.ByteReader
	cred, err := plugin.ReadCredential(r)
	if err != nil || cred.GetSecret() != "sk-1" {
		t.Fatalf("ReadCredential = %v, %v", cred, err)
	}
	var desc leylinev1.StreamDescriptor
	if err := protodelim.UnmarshalFrom(&in, &desc); err != nil || desc.GetStreamId() != "str_1" {
		t.Errorf("the descriptor after the key did not survive: %v, %v", &desc, err)
	}
	if _, err := plugin.ReadCredential(strings.NewReader("")); err == nil {
		t.Error("an empty stdin gave a key")
	}
	var empty bytes.Buffer
	mustMarshal(t, &empty, &leylinev1.SetCredentialRequest{Provider: "openai"})
	if _, err := plugin.ReadCredential(&empty); err == nil {
		t.Error("a request with no secret was accepted as a key")
	}
}

// blockingDecoder holds its first Segment call until release is closed, as a provider call that
// takes seconds does, and records the START time of every segment it is handed.
type blockingDecoder struct {
	release chan struct{}
	started chan struct{}
	seen    []uint64
}

func (d *blockingDecoder) Segment(_ []float32, at *leylinev1.SampleTime, emit func(*leylinev1.DecodeRecord)) {
	if len(d.seen) == 0 {
		close(d.started)
		<-d.release
	}
	d.seen = append(d.seen, at.GetSampleIndex())
	emit(&leylinev1.DecodeRecord{Protocol: "speech", Time: at})
}

// A decoder busy with one segment does not stop stdin being read: ten more segments arrive while
// it is blocked, the oldest waiting ones past the queue's eight are dropped with a line each, and
// the rest are decoded in order, with every record written before the run returns.
func TestRunSegmentedKeepsReadingWhileTheDecoderWorks(t *testing.T) {
	var log bytes.Buffer
	defer plugin.SetSegmentLog(&log)()
	pr, pw := io.Pipe()
	dec := &blockingDecoder{release: make(chan struct{}), started: make(chan struct{})}
	var out bytes.Buffer
	ran := make(chan error, 1)
	go func() {
		ran <- plugin.RunSegmentedStreams(t.Context(), pr, &out, "", func(uint32, *leylinev1.SetCredentialRequest) plugin.SegmentDecoder { return dec })
	}()

	write := func(m proto.Message) {
		if _, err := protodelim.MarshalTo(pw, m); err != nil {
			t.Error(err)
		}
	}
	segment := func(n uint64) {
		write(segFrame(2*n, n*100, leylinev1.SegmentMark_SEGMENT_START, f32(0.5)))
		write(segFrame(2*n+1, n*100+5, leylinev1.SegmentMark_SEGMENT_END, nil))
	}
	write(descriptor(leylinev1.AudioSampleFormat_F32))
	segment(1)
	<-dec.started
	// Every write below goes through an unbuffered pipe, so it returns only once the reader took
	// it: if the reader stalled behind the decoder, this would never finish.
	wrote := make(chan struct{})
	go func() {
		for n := uint64(2); n <= 11; n++ {
			segment(n)
		}
		// The reader takes the next bytes only once it has handled the last END, so this stray
		// frame returns only when segment 11 is queued, before the decoder is released.
		write(segFrame(24, 1200, leylinev1.SegmentMark_SEGMENT_MARK_UNSPECIFIED, f32(0.5)))
		_ = pw.Close()
		close(wrote)
	}()
	select {
	case <-wrote:
	case <-time.After(5 * time.Second):
		t.Fatal("the reader stalled while the decoder was busy")
	}
	close(dec.release)
	if err := <-ran; err != nil {
		t.Fatal(err)
	}
	want := []uint64{100, 400, 500, 600, 700, 800, 900, 1000, 1100}
	if !slices.Equal(dec.seen, want) {
		t.Errorf("decoded segments at %v, want %v", dec.seen, want)
	}
	for _, n := range []string{"2", "3"} {
		if !strings.Contains(log.String(), "plugin: dropped segment "+n+": the engine is behind") {
			t.Errorf("no line for dropped segment %s:\n%s", n, log.String())
		}
	}
	if recs := readRecords(t, out.Bytes()); len(recs) != len(want) {
		t.Errorf("wrote %d records, want %d", len(recs), len(want))
	}
}

// A gap on a START frame is audio the daemon could not deliver before the segment, so it adds no
// silence to the segment.
func TestRunSegmentedIgnoresAGapBeforeTheStart(t *testing.T) {
	var in bytes.Buffer
	mustMarshal(t, &in, descriptor(leylinev1.AudioSampleFormat_F32))
	start := segFrame(1, 5000, leylinev1.SegmentMark_SEGMENT_START, f32(0.5))
	start.Gap = &leylinev1.Gap{FromSample: 1000, ToSample: 5000}
	mustMarshal(t, &in, start)
	mustMarshal(t, &in, segFrame(2, 5005, leylinev1.SegmentMark_SEGMENT_END, nil))
	dec, _ := runSegmented(t, &in, "")
	if len(dec.segments) != 1 || len(dec.segments[0]) != 1 {
		t.Errorf("segments %v, want one of one sample", dec.segments)
	}
}
