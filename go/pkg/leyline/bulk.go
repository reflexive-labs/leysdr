// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"encoding/binary"
	"math"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// Bulk frames are the one part of leyline.v1 with no proto message: a frame
// carries a descriptor-shaped byte payload (docs/reference/cli.md). The decoders
// below are the Go half of that contract, and they live here rather than in a
// client so that every client — CLI, TUI, MCP adapter — reads a spectrum on the
// same scale as the daemon wrote it.

// dbU8Offset and dbU8Scale are the DB_U8 quantisation: the daemon sends
// round((dB + 120) * 2) clamped to a byte, so a bin covers 0.5 dB from -120 dBFS
// up to +7.5.
const (
	dbU8Offset = 120.0
	dbU8Scale  = 2.0
)

// DBU8Step is the width of one DB_U8 level in dB. A client comparing a DB_U8 row
// against a DB_F32 row of the same signal should allow at least half of it.
const DBU8Step = 1 / dbU8Scale

// DecodeFFTBins turns an FFT frame's payload into dBFS levels, one per bin.
// Pass the format from the descriptor the daemon answered with — what the
// subscriber asked for is a desire, and DB_U8 read as DB_F32 is not obviously
// wrong to look at. An unrecognised format is read as DB_F32, the wire default.
func DecodeFFTBins(payload []byte, format leylinev1.FftBinFormat) []float64 {
	if format == leylinev1.FftBinFormat_DB_U8 {
		out := make([]float64, len(payload))
		for i, b := range payload {
			out[i] = float64(b)/dbU8Scale - dbU8Offset
		}
		return out
	}
	out := make([]float64, len(payload)/4)
	for i := range out {
		out[i] = float64(math.Float32frombits(binary.LittleEndian.Uint32(payload[i*4:])))
	}
	return out
}

// PersistenceHistogram is one decoded persistence frame: how often each level
// has been seen lately, per frequency bin.
type PersistenceHistogram struct {
	Bins, Levels int
	Counts       []uint16 // bin-major
}

// At is the count for one cell.
func (h PersistenceHistogram) At(bin, level int) uint16 { return h.Counts[bin*h.Levels+level] }

// Peak is the largest count anywhere in the frame, which is what a renderer
// normalises against.
func (h PersistenceHistogram) Peak() uint16 {
	var m uint16
	for _, v := range h.Counts {
		if v > m {
			m = v
		}
	}
	return m
}

// DecodePersistence reads a persistence payload: bins*levels little-endian
// uint16 counts, bin-major. Take bins and levels from the descriptor; a payload
// too short for them is refused rather than read as a smaller frame, because a
// half-read histogram draws a picture instead of an error.
func DecodePersistence(payload []byte, bins, levels int) (PersistenceHistogram, bool) {
	if bins <= 0 || levels <= 0 || len(payload) < bins*levels*2 {
		return PersistenceHistogram{}, false
	}
	h := PersistenceHistogram{Bins: bins, Levels: levels, Counts: make([]uint16, bins*levels)}
	for i := range h.Counts {
		h.Counts[i] = binary.LittleEndian.Uint16(payload[2*i:])
	}
	return h, true
}

// DecodeAudio turns an audio frame's payload into mono samples in [-1, 1].
// Pass the format from the descriptor. Anything but F32 is read as little-endian
// S16, which is what the daemon serves when the subscriber names no format; the
// divisor is 32768 so a full-scale negative sample lands on exactly -1.
func DecodeAudio(payload []byte, format leylinev1.AudioSampleFormat) []float32 {
	if format == leylinev1.AudioSampleFormat_F32 {
		out := make([]float32, len(payload)/4)
		for i := range out {
			out[i] = math.Float32frombits(binary.LittleEndian.Uint32(payload[i*4:]))
		}
		return out
	}
	out := make([]float32, len(payload)/2)
	for i := range out {
		out[i] = float32(int16(binary.LittleEndian.Uint16(payload[i*2:]))) / 32768
	}
	return out
}
