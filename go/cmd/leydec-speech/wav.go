// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/binary"
	"math"
)

// encodeWAV is a segment as a 16-bit PCM mono WAV file at the descriptor's rate, the format every
// speech API takes. A sample beyond full scale is clipped rather than wrapped, and a NaN is
// silence.
func encodeWAV(samples []float32, rate uint32) []byte {
	const bytesPerSample = 2
	dataLen := uint32(len(samples) * bytesPerSample)
	out := make([]byte, 0, 44+int(dataLen))
	out = append(out, "RIFF"...)
	out = binary.LittleEndian.AppendUint32(out, 36+dataLen)
	out = append(out, "WAVEfmt "...)
	out = binary.LittleEndian.AppendUint32(out, 16) // fmt chunk length
	out = binary.LittleEndian.AppendUint16(out, 1)  // PCM
	out = binary.LittleEndian.AppendUint16(out, 1)  // mono
	out = binary.LittleEndian.AppendUint32(out, rate)
	out = binary.LittleEndian.AppendUint32(out, rate*bytesPerSample) // byte rate
	out = binary.LittleEndian.AppendUint16(out, bytesPerSample)      // block align
	out = binary.LittleEndian.AppendUint16(out, 8*bytesPerSample)    // bits per sample
	out = append(out, "data"...)
	out = binary.LittleEndian.AppendUint32(out, dataLen)
	for _, s := range samples {
		v := math.Round(float64(s) * math.MaxInt16)
		if math.IsNaN(v) {
			v = 0
		}
		v = max(-math.MaxInt16, min(math.MaxInt16, v)) // symmetric, so -1 and 1 clip alike
		out = binary.LittleEndian.AppendUint16(out, uint16(int16(v)))
	}
	return out
}
