// SPDX-License-Identifier: Apache-2.0

package plugin

import (
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
// carries. samples is reused for the next segment, so a decoder that keeps
// audio past the call copies it. emit follows Decoder's rules: any number of
// calls during Segment and none after it returns.
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

// RunSegmented reads a SEGMENTED stream from stdin and writes records to
// stdout. provider is the manifest's credential_provider: when it is set, the
// daemon writes one SetCredentialRequest before the descriptor, and it is read
// first.
func RunSegmented(ctx context.Context, provider string, newDecoder SegmentFactory) error {
	return RunSegmentedStreams(ctx, os.Stdin, os.Stdout, provider, newDecoder)
}

// RunSegmentedStreams is RunSegmented against explicit streams, which is what
// the tests use. It assembles each segment's frames into one buffer and hands
// it to the decoder at the END frame. A gap inside a segment is filled with
// silence, so the buffer keeps the segment's length on the timeline. A frame
// outside a segment, an END with no START, a START inside a segment and a
// segment over MaxSegment are each logged on stderr and dropped: the daemon
// sends none of them, and a plugin that decoded a half segment would emit a
// record for words it did not hear whole.
func RunSegmentedStreams(ctx context.Context, r io.Reader, w io.Writer, provider string, newDecoder SegmentFactory) error {
	in := asByteReader(r)
	var cred *leylinev1.SetCredentialRequest
	if provider != "" {
		var err error
		if cred, err = ReadCredential(in); err != nil {
			return err
		}
	}
	return runFramed(ctx, in, w, func(desc *leylinev1.StreamDescriptor, emit func(*leylinev1.DecodeRecord)) (func(*leylinev1.Frame) error, error) {
		audio := desc.GetAudio()
		if audio == nil || audio.GetSampleRate() == 0 {
			return nil, errors.New("plugin: descriptor carries no audio params")
		}
		dec := newDecoder(audio.GetSampleRate(), cred)
		if st, ok := dec.(Starter); ok {
			st.Start(desc)
		}
		a := &segmentAssembler{
			format:      audio.GetFormat(),
			audioRate:   float64(audio.GetSampleRate()),
			captureRate: float64(desc.GetSpanHz()),
			maxSamples:  int(MaxSegment.Seconds() * float64(audio.GetSampleRate())),
			deliver: func(samples []float32, at *leylinev1.SampleTime) {
				dec.Segment(samples, at, emit)
			},
		}
		return a.frame, nil
	})
}

// MainSegmented is Main for a plugin with SEGMENTED input: --manifest prints
// the manifest, and otherwise it reads the key the manifest's
// credential_provider asks for, then the segments.
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
	deliver     func(samples []float32, at *leylinev1.SampleTime)

	open     bool
	dropping bool
	at       *leylinev1.SampleTime
	buf      []float32
	scratch  []float32
	// strays counts frames outside a segment, so the log says so once per run
	// of them rather than once per frame.
	strays int
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
		return a.add(f)
	case leylinev1.SegmentMark_SEGMENT_END:
		if !a.open {
			a.logf("a segment end at sample %d with no start; ignored", f.GetTime().GetSampleIndex())
			return nil
		}
		if !a.dropping {
			a.deliver(a.buf, a.at)
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
	if g := f.GetGap(); g != nil && a.captureRate > 0 && g.GetToSample() > g.GetFromSample() {
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

func (a *segmentAssembler) logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "plugin: "+format+"\n", args...)
}
