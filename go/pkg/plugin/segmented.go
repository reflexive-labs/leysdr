// SPDX-License-Identifier: Apache-2.0

package plugin

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"time"

	"google.golang.org/protobuf/encoding/protodelim"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// SegmentDecoder is the interface a plugin with SEGMENTED input implements
// (decode.proto, InputMode). Segment is called once per segment, with the
// whole segment's audio in one buffer: the frames from the one marked
// SEGMENT_START to the one marked SEGMENT_END. at is the START frame's time,
// which is pre-roll before the squelch opened, and is what a record's `time`
// carries. samples is the decoder's to keep. Segment runs on a goroutine of
// its own while stdin is still read, so a call that takes seconds (a provider's
// API) does not hold up the daemon's writes; calls are in order, one at a time,
// and emit follows Decoder's rules: any number of calls during Segment and none
// after it returns.
//
// A decoder that needs the capture rate also implements Starter, as an audio
// Decoder does.
type SegmentDecoder interface {
	Segment(samples []float32, at *leylinev1.SampleTime, emit func(*leylinev1.DecodeRecord))
}

// SegmentFactory builds the decoder once the descriptor has named the audio
// rate. cred is the key the daemon handed over before the descriptor when the
// manifest names a credential_provider, and nil when it names none.
type SegmentFactory func(audioRateHz uint32, cred *leylinev1.SetCredentialRequest) SegmentDecoder

// MaxSegment bounds one segment. A squelch held open for longer is a stuck
// carrier or an open squelch on noise rather than an over, and buffering it
// would hold minutes of audio in memory for a call no speech engine accepts.
const MaxSegment = 10 * time.Minute

// segmentQueue is how many complete segments may wait for the decoder. When a
// slow engine lets more pile up, the oldest waiting one is dropped, because the
// daemon replaces a plugin that stops reading its stdin and the newest overs
// are the ones a person is waiting for.
const segmentQueue = 8

// RunSegmented reads a SEGMENTED stream from stdin and writes records to
// stdout. provider is the built-in manifest's credential_provider. The daemon
// writes one SetCredentialRequest before the descriptor when the installed
// manifest names a provider, and says so in KeyOnStdinEnv; the key is read
// first when that variable is 1 or provider is set.
func RunSegmented(ctx context.Context, provider string, newDecoder SegmentFactory) error {
	return RunSegmentedStreams(ctx, os.Stdin, os.Stdout, provider, newDecoder)
}

// RunSegmentedStreams is RunSegmented against explicit streams, which is what
// the tests use. It assembles each segment's frames into one buffer on the
// reading goroutine and, at the END frame, queues it for the decoder, which
// runs on a second goroutine; at the end of input it waits for every queued
// segment and writes the records before it returns. A gap inside a segment is
// filled with silence, so the buffer keeps the segment's length on the
// timeline; a gap on a START frame is audio before the segment (a segment the
// daemon could not deliver) and is not. A frame outside a segment, an END with
// no START, a START inside a segment, a segment over MaxSegment, a segment cut
// off by the end of input and a queued segment the decoder fell behind on are
// each logged on stderr and dropped: a plugin that decoded a half segment would
// emit a record for words it did not hear whole.
func RunSegmentedStreams(ctx context.Context, r io.Reader, w io.Writer, provider string, newDecoder SegmentFactory) error {
	in := asByteReader(r)
	cred, err := readKeyIfSent(in, provider)
	if err != nil {
		return err
	}
	var a *segmentAssembler
	var work *segmentWorker
	err = runFramed(ctx, in, w, func(desc *leylinev1.StreamDescriptor, _ func(*leylinev1.DecodeRecord)) (func(*leylinev1.Frame) error, error) {
		audio := desc.GetAudio()
		if audio == nil || audio.GetSampleRate() == 0 {
			return nil, errors.New("plugin: descriptor carries no audio params")
		}
		dec := newDecoder(audio.GetSampleRate(), cred)
		if st, ok := dec.(Starter); ok {
			st.Start(desc)
		}
		a = &segmentAssembler{
			format:      audio.GetFormat(),
			audioRate:   float64(audio.GetSampleRate()),
			captureRate: float64(desc.GetSpanHz()),
			maxSamples:  int(MaxSegment.Seconds() * float64(audio.GetSampleRate())),
		}
		work = startSegmentWorker(dec, w)
		a.deliver = work.enqueue
		return a.frame, nil
	})
	if a != nil {
		a.end()
	}
	if work != nil {
		if werr := work.finish(); err == nil {
			err = werr
		}
	}
	return err
}

// queuedSegment is one complete segment waiting for the decoder.
type queuedSegment struct {
	n       int
	samples []float32
	at      *leylinev1.SampleTime
}

// segmentWorker runs the decoder on its own goroutine and is the only writer of
// records, so emit needs no lock and each record is flushed as it is made.
type segmentWorker struct {
	queue chan queuedSegment
	done  chan error
}

func startSegmentWorker(dec SegmentDecoder, w io.Writer) *segmentWorker {
	sw := &segmentWorker{queue: make(chan queuedSegment, segmentQueue), done: make(chan error, 1)}
	go func() {
		out := bufio.NewWriter(w)
		var werr error
		emit := func(rec *leylinev1.DecodeRecord) {
			if rec == nil || werr != nil {
				return
			}
			if _, werr = protodelim.MarshalTo(out, rec); werr == nil {
				werr = out.Flush()
			}
		}
		for seg := range sw.queue {
			dec.Segment(seg.samples, seg.at, emit)
		}
		if werr != nil {
			werr = fmt.Errorf("plugin: write record: %w", werr)
		}
		sw.done <- werr
	}()
	return sw
}

// enqueue hands a segment to the decoder without blocking the reader: when the
// queue is full the oldest waiting segment makes room. The reader is the only
// sender, so after one receive the send cannot block.
func (sw *segmentWorker) enqueue(seg queuedSegment) {
	select {
	case sw.queue <- seg:
		return
	default:
	}
	select {
	case old := <-sw.queue:
		fmt.Fprintf(segmentLog, "plugin: dropped segment %d: the engine is behind\n", old.n)
	default:
	}
	sw.queue <- seg
}

// finish waits for the decoder to work through every queued segment.
func (sw *segmentWorker) finish() error {
	close(sw.queue)
	return <-sw.done
}

// MainSegmented is Main for a plugin with SEGMENTED input: --manifest prints
// the manifest, and otherwise it reads the key when the daemon says one comes
// (KeyOnStdinEnv) or the manifest names a credential_provider, then the
// segments.
func MainSegmented(manifest *leylinev1.DecoderManifest, newDecoder SegmentFactory) {
	handleManifestFlag(manifest)
	if err := RunSegmented(context.Background(), manifest.GetCredentialProvider(), newDecoder); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// ReadCredential reads the one varint-delimited SetCredentialRequest the
// daemon writes before the StreamDescriptor when a manifest names a
// credential_provider. It reads no byte past the message, so the descriptor
// that follows is still on r. The secret is the caller's to pass to its
// provider and nowhere else: not to stderr, a record or a file.
func ReadCredential(r io.Reader) (*leylinev1.SetCredentialRequest, error) {
	var req leylinev1.SetCredentialRequest
	if err := protodelim.UnmarshalFrom(asByteReader(r), &req); err != nil {
		if errors.Is(err, io.EOF) {
			return nil, errors.New("plugin: stdin closed before the key the manifest's credential_provider asks for")
		}
		return nil, fmt.Errorf("plugin: read the key: %w", err)
	}
	if req.GetSecret() == "" {
		return nil, fmt.Errorf("plugin: the daemon sent no key for %q", req.GetProvider())
	}
	return &req, nil
}

// byteReader is protodelim's reader for an io.Reader that cannot read one byte
// at a time. It reads one byte per call, so nothing past a message is consumed.
type byteReader struct{ io.Reader }

func (b byteReader) ReadByte() (byte, error) {
	var one [1]byte
	if _, err := io.ReadFull(b.Reader, one[:]); err != nil {
		return 0, err
	}
	return one[0], nil
}

// asByteReader returns r unchanged when it already reads bytes (a
// *bufio.Reader, which runFramed then reuses rather than wrapping again).
func asByteReader(r io.Reader) protodelim.Reader {
	if br, ok := r.(protodelim.Reader); ok {
		return br
	}
	return byteReader{r}
}

// segmentAssembler collects one segment's frames into a buffer.
type segmentAssembler struct {
	format      leylinev1.AudioSampleFormat
	audioRate   float64
	captureRate float64
	maxSamples  int
	deliver     func(queuedSegment)

	open     bool
	dropping bool
	at       *leylinev1.SampleTime
	buf      []float32
	scratch  []float32
	// strays counts frames outside a segment, so the log says so once per run
	// of them rather than once per frame.
	strays int
	// started counts the segments begun, so a log line can say which one.
	started int
}

func (a *segmentAssembler) frame(f *leylinev1.Frame) error {
	switch f.GetSegment() {
	case leylinev1.SegmentMark_SEGMENT_START:
		if a.open {
			a.logf("a segment started at sample %d inside the one from sample %d, which had no end; dropped the earlier one",
				f.GetTime().GetSampleIndex(), a.at.GetSampleIndex())
		}
		a.reset()
		a.open, a.at = true, f.GetTime()
		a.strays = 0
		a.started++
		return a.add(f)
	case leylinev1.SegmentMark_SEGMENT_END:
		if !a.open {
			a.logf("a segment end at sample %d with no start; ignored", f.GetTime().GetSampleIndex())
			return nil
		}
		if !a.dropping {
			a.deliver(queuedSegment{n: a.started, samples: a.buf, at: a.at})
			a.buf = nil // the decoder owns it now
		}
		a.reset()
		return nil
	}
	if !a.open {
		if a.strays == 0 {
			a.logf("audio at sample %d arrived outside a segment; ignored until the next segment starts", f.GetTime().GetSampleIndex())
		}
		a.strays++
		return nil
	}
	return a.add(f)
}

// add appends a frame's samples, after silence for any gap before it.
func (a *segmentAssembler) add(f *leylinev1.Frame) error {
	var err error
	a.scratch, err = decodePayload(a.scratch[:0], f.GetPayload(), a.format)
	if err != nil {
		return err
	}
	if a.dropping {
		return nil
	}
	gapSamples := 0
	// A gap on a START frame lies before the segment, not inside it.
	if g := f.GetGap(); g != nil && f.GetSegment() != leylinev1.SegmentMark_SEGMENT_START &&
		a.captureRate > 0 && g.GetToSample() > g.GetFromSample() {
		gapSamples = int(float64(g.GetToSample()-g.GetFromSample()) * a.audioRate / a.captureRate)
	}
	if len(a.buf)+gapSamples+len(a.scratch) > a.maxSamples {
		a.logf("the segment from sample %d is longer than %s; dropped", a.at.GetSampleIndex(), MaxSegment)
		a.dropping, a.buf = true, nil
		return nil
	}
	for range gapSamples {
		a.buf = append(a.buf, 0)
	}
	a.buf = append(a.buf, a.scratch...)
	return nil
}

func (a *segmentAssembler) reset() {
	a.open, a.dropping, a.at = false, false, nil
	a.buf = a.buf[:0]
}

// end is called when the input ends: a segment still open never got its END
// frame, so it is dropped, and the log says so.
func (a *segmentAssembler) end() {
	if a.open {
		a.logf("segment %d cut off by end of input, dropped", a.started)
		a.reset()
	}
}

// segmentLog is where the assembler's lines go; a test swaps it to read them.
var segmentLog io.Writer = os.Stderr

func (a *segmentAssembler) logf(format string, args ...any) {
	fmt.Fprintf(segmentLog, "plugin: "+format+"\n", args...)
}
