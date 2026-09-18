// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"io"
	"math"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/dpup/leysdr/go/pkg/iqfile"
)

// checkResult is the outcome of verifying one expect entry.
type checkResult struct {
	file   string
	index  int
	pass   bool
	detail string
}

func runCheck(args []string, w io.Writer) error {
	if len(args) == 0 {
		return errors.New("check: DIR or FILE arguments required")
	}
	var files []string
	for _, a := range args {
		st, err := os.Stat(a)
		if err != nil {
			return err
		}
		if st.IsDir() {
			m, _ := filepath.Glob(filepath.Join(a, "*.json"))
			sort.Strings(m)
			files = append(files, m...)
		} else {
			files = append(files, iqfile.SidecarPath(a))
		}
	}
	if len(files) == 0 {
		return errors.New("check: no sidecars found")
	}
	failed := 0
	for _, f := range files {
		results, err := checkFile(f)
		if err != nil {
			fmt.Fprintf(w, "FAIL %s: %v\n", f, err)
			failed++
			continue
		}
		for _, r := range results {
			status := "PASS"
			if !r.pass {
				status = "FAIL"
				failed++
			}
			fmt.Fprintf(w, "%s %s[%d] %s\n", status, filepath.Base(r.file), r.index, r.detail)
		}
	}
	if failed > 0 {
		return fmt.Errorf("check: %d failure(s)", failed)
	}
	return nil
}

// checkFile verifies every expect entry of the fixture whose sidecar is at path.
func checkFile(path string) ([]checkResult, error) {
	sc, err := iqfile.ReadSidecar(path)
	if err != nil {
		return nil, err
	}
	raw, err := iqfile.ReadAll(path, sc.Format)
	if err != nil {
		return nil, err
	}
	x := make([]complex128, len(raw))
	for i, v := range raw {
		x[i] = complex(float64(real(v)), float64(imag(v)))
	}
	var out []checkResult
	for i, e := range sc.Expect {
		r := checkResult{file: path, index: i}
		r.pass, r.detail = checkExpect(x, sc.SampleRate, e)
		out = append(out, r)
	}
	return out, nil
}

// checkExpect runs the reference chain for one expect entry and evaluates
// its audio and meter assertions, returning pass and a numeric summary.
func checkExpect(x []complex128, rate float64, e iqfile.Expect) (bool, string) {
	res, err := referenceChain(x, rate, e.Mode, e.OffsetHz, e.BandwidthHz)
	if err != nil {
		return false, fmt.Sprintf("%s @%+.0f bw %.0f: %v", e.Mode, e.OffsetHz, e.BandwidthHz, err)
	}
	// Drop the filter/IIR settling transient (50 ms) when the file is long enough.
	// `trimmedS` is what that costs the time base: the record check reports edges
	// in seconds from the start of the file, and a silent 50 ms shift would move
	// every one of them.
	trimmedS := 0.0
	if skip := int(0.05 * res.audioRate); len(res.audio) > 4*skip {
		res.audio = res.audio[skip:]
	}
	if skip := int(0.05 * res.iqRate); len(res.iq) > 4*skip {
		res.iq = res.iq[skip:]
		trimmedS = float64(skip) / res.iqRate
	}
	pass := true
	var parts []string
	parts = append(parts, fmt.Sprintf("%s @%+.0f bw %.0f:", e.Mode, e.OffsetHz, e.BandwidthHz))
	if e.Audio != nil {
		if res.audio == nil {
			pass = false
			parts = append(parts, "no audio for mode")
		} else {
			m := measureTone(res.audio, res.audioRate)
			tol := 0.01 * e.Audio.ToneHz
			toneOK := math.Abs(m.peakHz-e.Audio.ToneHz) <= tol
			snrOK := m.snrDB >= e.Audio.MinSNRDB
			pass = pass && toneOK && snrOK
			parts = append(parts, fmt.Sprintf("tone %.1f Hz (want %.0f ±%.0f%s) snr %.1f dB (min %.0f%s) frames %d/%d",
				m.peakHz, e.Audio.ToneHz, tol, okMark(toneOK), m.snrDB, e.Audio.MinSNRDB, okMark(snrOK), m.frames, m.frames+m.gatedOut))
		}
	}
	if e.Meter != nil {
		p := meanPowerDBFS(res.iq)
		parts = append(parts, fmt.Sprintf("power %.1f dBFS", p))
		if e.Meter.PowerDBFSMin != nil {
			ok := p >= *e.Meter.PowerDBFSMin
			pass = pass && ok
			parts = append(parts, fmt.Sprintf("(min %.1f%s)", *e.Meter.PowerDBFSMin, okMark(ok)))
		}
		if e.Meter.PowerDBFSMax != nil {
			ok := p <= *e.Meter.PowerDBFSMax
			pass = pass && ok
			parts = append(parts, fmt.Sprintf("(max %.1f%s)", *e.Meter.PowerDBFSMax, okMark(ok)))
		}
		if e.Meter.SquelchOpen != nil {
			open := p > squelchRefDBFS
			ok := open == *e.Meter.SquelchOpen
			pass = pass && ok
			parts = append(parts, fmt.Sprintf("squelch open=%v @%.0f dBFS (want %v%s)", open, squelchRefDBFS, *e.Meter.SquelchOpen, okMark(ok)))
		}
	}
	if e.Record != nil {
		ok, detail := checkRecord(res, e.Record, trimmedS)
		pass = pass && ok
		parts = append(parts, detail)
	}
	return pass, strings.Join(parts, " ")
}

// checkRecord verifies a keyed fixture's own answer key: the channel's power
// crosses the stated squelch threshold exactly where the sidecar says it was
// keyed, and nowhere else. The fixture claims the segments, so this is what
// keeps that claim honest -- a recording test graded against a fixture whose
// keying had drifted would fail the daemon for the generator's mistake.
func checkRecord(res *channelResult, e *iqfile.RecordExpect, offsetS float64) (bool, string) {
	if len(res.iq) == 0 {
		return false, "record: no channel samples"
	}
	// One decision per 20 ms, which is finer than any hang or pre-roll the
	// recorder uses and coarse enough to be a stable power estimate.
	const windowS = 0.020
	window := max(1, int(windowS*res.iqRate))
	var found []iqfile.RecordSegment
	open := false
	var openedAt float64
	for start := 0; start+window <= len(res.iq); start += window {
		p := meanPowerDBFS(res.iq[start : start+window])
		at := offsetS + float64(start)/res.iqRate
		if p > e.SquelchDBFS && !open {
			open, openedAt = true, at
		} else if p <= e.SquelchDBFS && open {
			open = false
			found = append(found, iqfile.RecordSegment{StartS: openedAt, EndS: at})
		}
	}
	if open {
		found = append(found, iqfile.RecordSegment{StartS: openedAt, EndS: offsetS + float64(len(res.iq))/res.iqRate})
	}
	// The filter's group delay and the window itself move an edge by a few tens
	// of milliseconds; 100 ms is generous against that and still far tighter
	// than the shortest gap the fixture states.
	const tolS = 0.100
	ok := len(found) == len(e.Segments)
	var parts []string
	parts = append(parts, fmt.Sprintf("record: %d/%d segments", len(found), len(e.Segments)))
	for i, want := range e.Segments {
		if i >= len(found) {
			break
		}
		startOK := math.Abs(found[i].StartS-want.StartS) <= tolS
		endOK := math.Abs(found[i].EndS-want.EndS) <= tolS
		ok = ok && startOK && endOK
		parts = append(parts, fmt.Sprintf("[%.2f,%.2f] want [%.2f,%.2f]%s",
			found[i].StartS, found[i].EndS, want.StartS, want.EndS, okMark(startOK && endOK)))
	}
	return ok, strings.Join(parts, " ")
}

func okMark(ok bool) string {
	if ok {
		return ""
	}
	return " FAIL"
}
