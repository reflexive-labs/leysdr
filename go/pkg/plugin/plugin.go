// SPDX-License-Identifier: Apache-2.0

// Package plugin is the SDK a Go decoder plugin is written against. The wire it
// speaks is the one docs/design/decoders.md ("Transport: stdio") settled on: the
// daemon writes one varint-delimited StreamDescriptor to the plugin's stdin
// followed by varint-delimited Frames, and reads varint-delimited DecodeRecords
// from its stdout. Both ends use protobuf's own delimited convention
// (protodelim here, BinaryDelimited in swift-protobuf), so no framing of ours
// has to be reimplemented by a plugin author.
//
// A plugin's main is two lines: build the manifest, call Main. Everything the
// daemon fills in later -- record_id, rssi_dbfs, snr_db, job_id, seq,
// channel_id -- is left alone here, per the plugin wire in
// docs/plans/decoders.md (DEC-1).
package plugin

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math"
	"os"

	"google.golang.org/protobuf/encoding/protodelim"
	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Decoder is the one thing a plugin implements. Feed is called once per frame,
// in order, on a single goroutine; emit may be called any number of times
// during the call and not after it returns.
//
// at is the frame's SampleTime on the capture timeline; gap is non-nil only
// when the delivery policy dropped samples before this frame (GAP_MARKED), and
// a decoder holding partial state across frames should reset it when one
// arrives.
type Decoder interface {
	Feed(samples []float32, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord))
}

// Starter is the optional half of Decoder: a decoder that stamps records with
// SampleTimeAt needs the capture rate, which only the descriptor carries
// (span_hz, per DEC-1 in docs/plans/decoders.md).
type Starter interface {
	Start(desc *leylinev1.StreamDescriptor)
}

// Factory builds the decoder once the descriptor has named the audio rate.
// A demodulator's filters and bit clock depend on that rate, so it cannot be
// built before the daemon has said what it is.
type Factory func(audioRateHz uint32) Decoder

// Run reads the descriptor and frames from stdin and writes records to stdout.
func Run(ctx context.Context, newDecoder Factory) error {
	return RunStreams(ctx, os.Stdin, os.Stdout, newDecoder)
}

// RunStreams is Run against explicit streams, which is what the tests use.
// It returns nil at end of input: the daemon closing stdin is how a decode job
// stops, not a failure.
func RunStreams(ctx context.Context, r io.Reader, w io.Writer, newDecoder Factory) error {
	in := bufio.NewReaderSize(r, 1<<16)
	out := bufio.NewWriterSize(w, 1<<16)

	var desc leylinev1.StreamDescriptor
	if err := protodelim.UnmarshalFrom(in, &desc); err != nil {
		if errors.Is(err, io.EOF) {
			return nil
		}
		return fmt.Errorf("plugin: read descriptor: %w", err)
	}
	audio := desc.GetAudio()
	if audio == nil || audio.GetSampleRate() == 0 {
		return errors.New("plugin: descriptor carries no audio params")
	}
	// The descriptor's span_hz is the capture's rate, which is what SampleTime
	// counts in (DEC-1: "the descriptor's center_hz and span_hz name the
	// capture rate as span_hz").

	dec := newDecoder(audio.GetSampleRate())
	if st, ok := dec.(Starter); ok {
		st.Start(&desc)
	}
	emit := func(rec *leylinev1.DecodeRecord) {
		if rec == nil {
			return
		}
		if _, err := protodelim.MarshalTo(out, rec); err != nil {
			// stdout is the only way out; a broken pipe means the daemon is gone.
			fmt.Fprintf(os.Stderr, "write record: %v\n", err)
		}
	}

	var samples []float32
	for {
		if err := ctx.Err(); err != nil {
			return out.Flush()
		}
		var frame leylinev1.Frame
		if err := protodelim.UnmarshalFrom(in, &frame); err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return out.Flush()
			}
			_ = out.Flush()
			return fmt.Errorf("plugin: read frame: %w", err)
		}
		var err error
		samples, err = decodePayload(samples[:0], frame.GetPayload(), audio.GetFormat())
		if err != nil {
			return err
		}
		dec.Feed(samples, frame.GetTime(), frame.GetGap(), emit)
		// Flush per frame: a record is a thing that was said, and a client
		// waiting on the live stream should not wait on the next packet too.
		if err := out.Flush(); err != nil {
			return fmt.Errorf("plugin: flush: %w", err)
		}
	}
}

// decodePayload turns a frame's bytes into float32 audio. The daemon sends F32
// little-endian (docs/design/decoders.md, "Transport: stdio"); S16 is handled
// because AudioParams can name it and a plugin that refused would be lying
// about the contract it implements.
func decodePayload(dst []float32, payload []byte, format leylinev1.AudioSampleFormat) ([]float32, error) {
	switch format {
	case leylinev1.AudioSampleFormat_S16:
		if len(payload)%2 != 0 {
			return nil, fmt.Errorf("plugin: S16 payload of %d bytes is not a whole number of samples", len(payload))
		}
		for i := 0; i+1 < len(payload); i += 2 {
			dst = append(dst, float32(int16(binary.LittleEndian.Uint16(payload[i:])))/32768)
		}
		return dst, nil
	case leylinev1.AudioSampleFormat_F32, leylinev1.AudioSampleFormat_AUDIO_SAMPLE_FORMAT_UNSPECIFIED:
		if len(payload)%4 != 0 {
			return nil, fmt.Errorf("plugin: F32 payload of %d bytes is not a whole number of samples", len(payload))
		}
		for i := 0; i+3 < len(payload); i += 4 {
			dst = append(dst, math.Float32frombits(binary.LittleEndian.Uint32(payload[i:])))
		}
		return dst, nil
	default:
		return nil, fmt.Errorf("plugin: unsupported audio format %v", format)
	}
}

// SampleTimeAt places an audio-sample offset inside a frame on the capture's
// timeline. The formula is DEC-1's: sample_index + offset·capture_rate/audio_rate,
// because SampleTime counts capture samples everywhere (invariant 5) and the
// plugin only ever sees decimated audio.
func SampleTimeAt(frameTime *leylinev1.SampleTime, offsetSamples int, audioRate, captureRate float64) *leylinev1.SampleTime {
	if frameTime == nil {
		return nil
	}
	idx := frameTime.GetSampleIndex()
	if audioRate > 0 && captureRate > 0 && offsetSamples > 0 {
		idx += uint64(float64(offsetSamples) * captureRate / audioRate)
	}
	return &leylinev1.SampleTime{CaptureId: frameTime.GetCaptureId(), SampleIndex: idx}
}

// Main is a plugin's whole main function. With --manifest it prints the
// manifest as proto3 JSON and exits 0, which is what `ley decoders --check`
// and the registry's own tests read; with anything else it runs the decoder
// against stdin and stdout.
func Main(manifest *leylinev1.DecoderManifest, newDecoder Factory) {
	for _, arg := range os.Args[1:] {
		if arg == "--manifest" || arg == "-manifest" {
			out, err := protojson.MarshalOptions{Multiline: true, Indent: "  "}.Marshal(manifest)
			if err != nil {
				fmt.Fprintf(os.Stderr, "manifest: %v\n", err)
				os.Exit(1)
			}
			fmt.Printf("%s\n", out)
			os.Exit(0)
		}
	}
	if err := Run(context.Background(), newDecoder); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
