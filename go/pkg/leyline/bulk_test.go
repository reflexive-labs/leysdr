package leyline

import (
	"encoding/binary"
	"math"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// encodeU8 is the daemon's DB_U8 quantisation (StreamSources.swift), written out
// here so the decoder is checked against the encoder rather than against itself.
func encodeU8(db []float64) []byte {
	out := make([]byte, len(db))
	for i, v := range db {
		out[i] = byte(math.Max(0, math.Min(255, math.Round((v+120)*2))))
	}
	return out
}

func TestDecodeFFTBinsRoundTripsTheDaemonsQuantisation(t *testing.T) {
	levels := []float64{-119.5, -100, -73.25, -40.1, 0, 7.5}
	got := DecodeFFTBins(encodeU8(levels), leylinev1.FftBinFormat_DB_U8)
	if len(got) != len(levels) {
		t.Fatalf("DB_U8: %d bins, want %d", len(got), len(levels))
	}
	for i, want := range levels {
		if math.Abs(got[i]-want) > DBU8Step/2 {
			t.Errorf("DB_U8 bin %d: %v, want %v within %v", i, got[i], want, DBU8Step/2)
		}
	}
	// Everything outside the encodable window clamps to an end of it.
	ends := DecodeFFTBins(encodeU8([]float64{-200, 40}), leylinev1.FftBinFormat_DB_U8)
	if ends[0] != -120 || ends[1] != 7.5 {
		t.Errorf("DB_U8 clamps to -120..7.5, got %v", ends)
	}

	f32 := make([]byte, 4*len(levels))
	for i, v := range levels {
		binary.LittleEndian.PutUint32(f32[i*4:], math.Float32bits(float32(v)))
	}
	for _, format := range []leylinev1.FftBinFormat{
		leylinev1.FftBinFormat_DB_F32,
		leylinev1.FftBinFormat_FFT_BIN_FORMAT_UNSPECIFIED, // the daemon's default
	} {
		got := DecodeFFTBins(f32, format)
		for i, want := range levels {
			if math.Abs(got[i]-float64(float32(want))) > 1e-6 {
				t.Errorf("%v bin %d: %v, want %v", format, i, got[i], want)
			}
		}
	}
}

func TestDecodePersistence(t *testing.T) {
	const bins, levels = 4, 3
	payload := make([]byte, bins*levels*2)
	for b := range bins {
		for l := range levels {
			binary.LittleEndian.PutUint16(payload[2*(b*levels+l):], uint16(10*b+l))
		}
	}
	h, ok := DecodePersistence(payload, bins, levels)
	if !ok {
		t.Fatal("an exact payload must decode")
	}
	if h.At(3, 2) != 32 || h.At(0, 0) != 0 || h.Peak() != 32 {
		t.Errorf("counts read wrong: at(3,2)=%d peak=%d", h.At(3, 2), h.Peak())
	}
	for _, c := range []struct {
		name         string
		payload      []byte
		bins, levels int
	}{
		{"empty", nil, bins, levels},
		{"one byte short", payload[:len(payload)-1], bins, levels},
		{"zero bins", payload, 0, levels},
		{"zero levels", payload, bins, 0},
	} {
		if _, ok := DecodePersistence(c.payload, c.bins, c.levels); ok {
			t.Errorf("%s: should have been refused", c.name)
		}
	}
}

func TestDecodeAudio(t *testing.T) {
	s16 := []int16{0, 1000, -1000, 32767, -32768}
	payload := make([]byte, 2*len(s16))
	for i, v := range s16 {
		binary.LittleEndian.PutUint16(payload[2*i:], uint16(v))
	}
	for _, format := range []leylinev1.AudioSampleFormat{
		leylinev1.AudioSampleFormat_S16,
		leylinev1.AudioSampleFormat_AUDIO_SAMPLE_FORMAT_UNSPECIFIED, // the daemon's default
	} {
		got := DecodeAudio(payload, format)
		if len(got) != len(s16) {
			t.Fatalf("%v: %d samples, want %d", format, len(got), len(s16))
		}
		for i, v := range s16 {
			if want := float32(v) / 32768; got[i] != want {
				t.Errorf("%v sample %d: %v, want %v", format, i, got[i], want)
			}
		}
		if got[len(got)-1] != -1 {
			t.Errorf("%v: full-scale negative is %v, want -1", format, got[len(got)-1])
		}
	}

	f32 := []float32{0, 0.5, -0.25, 1}
	raw := make([]byte, 4*len(f32))
	for i, v := range f32 {
		binary.LittleEndian.PutUint32(raw[i*4:], math.Float32bits(v))
	}
	got := DecodeAudio(raw, leylinev1.AudioSampleFormat_F32)
	for i, want := range f32 {
		if got[i] != want {
			t.Errorf("F32 sample %d: %v, want %v", i, got[i], want)
		}
	}
}
