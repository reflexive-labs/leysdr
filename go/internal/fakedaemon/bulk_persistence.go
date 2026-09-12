// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"encoding/binary"
	"math"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// persistence is the phosphor histogram behind a PERSISTENCE stream: for each frequency bin, how
// often each level has been seen lately. It mirrors the engine's PersistenceAccumulator -- counts
// saturate rather than wrap, and every count halves once the half-life's worth of rows has been
// folded in, which is what makes "usual" mean "usual lately".
type persistence struct {
	bins, levels     int
	floorDB, rangeDB float64
	rowsPerHalfLife  int
	// Rows folded into one delivered frame. The histogram wants every row the ladder can give it
	// and a person reads a couple of frames a second, so the two rates are not the same.
	rowsPerFrame int
	counts       []uint16
	sinceHalving int
}

func newPersistence(p *leylinev1.PersistenceParams) *persistence {
	bins, levels := int(p.GetBins()), int(p.GetLevels())
	rows := int(math.Round(ladderRowsPerSecond / p.GetRowsPerSecond()))
	return &persistence{
		bins: bins, levels: levels,
		floorDB: p.GetFloorDb(), rangeDB: p.GetRangeDb(),
		rowsPerHalfLife: max(1, int(p.GetHalfLifeSeconds()*ladderRowsPerSecond)),
		rowsPerFrame:    max(1, rows),
		counts:          make([]uint16, bins*levels),
	}
}

// add folds one FFT row in, one count per bin at the level bucket it lands in.
func (h *persistence) add(row []float32) {
	scale := float64(h.levels) / h.rangeDB
	for b := 0; b < h.bins; b++ {
		// Nearest source bin, so the ladder's size and the histogram's need not match.
		s := b
		if len(row) != h.bins {
			s = min(len(row)-1, (b*len(row)+h.bins/2)/h.bins)
		}
		db := float64(row[s])
		if math.IsNaN(db) || math.IsInf(db, 0) {
			continue
		}
		l := int((db - h.floorDB) * scale)
		if l < 0 {
			l = 0
		}
		if l >= h.levels {
			l = h.levels - 1
		}
		if i := b*h.levels + l; h.counts[i] < math.MaxUint16 {
			h.counts[i]++
		}
	}
	h.sinceHalving++
	if h.sinceHalving >= h.rowsPerHalfLife {
		h.sinceHalving = 0
		for i := range h.counts {
			h.counts[i] >>= 1
		}
	}
}

// snapshot copies the histogram out as little-endian uint16, bin-major.
func (h *persistence) snapshot() []byte {
	out := make([]byte, h.bins*h.levels*2)
	for i, c := range h.counts {
		binary.LittleEndian.PutUint16(out[i*2:], c)
	}
	return out
}

// renderPersistenceLocked folds this frame's worth of rows in and answers with the histogram.
// The rows are taken across the frame's interval rather than all at one instant: the fake's noise
// jitters with the clock, and a histogram built from one row repeated would show a floor one
// count wide instead of a band.
func (d *Daemon) renderPersistenceLocked(s *stream, c *capture, p *leylinev1.PersistenceParams, now time.Time) []byte {
	if s.phosphor == nil {
		s.phosphor = newPersistence(p)
	}
	h := s.phosphor
	rowRate := float64(ladderRowsPerSecond)
	step := time.Duration(float64(time.Second) / rowRate)
	for i := 0; i < h.rowsPerFrame; i++ {
		h.add(d.spectrumRowLocked(c, h.bins, now.Add(time.Duration(i)*step)))
	}
	return h.snapshot()
}
