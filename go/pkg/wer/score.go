// SPDX-License-Identifier: Apache-2.0

package wer

import (
	"fmt"
	"slices"
	"strconv"
	"strings"

	"github.com/reflexive-labs/leysdr/go/pkg/callsign"
)

// Key names one over of a recording: its part, and its 1-based index in that part's
// squelch_opens, which is what a speech record's clip_uri and over give.
type Key struct {
	Part int `json:"part"`
	Over int `json:"over"`
}

func (k Key) String() string { return fmt.Sprintf("%d/%d", k.Part, k.Over) }

// Over is one over's words: a line of the hand transcript, or a speech record's text.
type Over struct {
	Key  Key
	Text string
	// Last is the last squelch opening the over's audio holds, when a segment holds more than
	// one (two openings closer together than the decoder's hang are one segment, numbered by
	// the first). 0 means Key.Over alone.
	Last int
}

// last is the over's final opening.
func (o Over) last() int { return max(o.Last, o.Key.Over) }

// Transcript is the reference for one recording: the words of each over as a person heard them.
type Transcript struct {
	Overs []Over
	// Skipped is the overs not transcribed yet, which the score leaves out.
	Skipped []Key
}

// OverScore is one scored stretch of the recording. It is usually one over. When the engine
// heard two openings as one segment and the transcript lists them apart, or the other way round,
// the overs on both sides are joined into one stretch, named by its part and the overs it holds
// ("1/1+2").
type OverScore struct {
	Name          string   `json:"over"`
	Ref           string   `json:"ref"`
	Hyp           string   `json:"hyp"`
	Counts        Counts   `json:"counts"`
	Rate          float64  `json:"wer"`
	RefCallsigns  []string `json:"ref_callsigns,omitempty"`
	HypCallsigns  []string `json:"hyp_callsigns,omitempty"`
	CallsignHits  int      `json:"callsign_hits"`
	CallsignTotal int      `json:"callsign_total"`
	// Missing is a transcribed stretch with no record: every reference word is a deletion.
	Missing bool `json:"missing,omitempty"`
	// Extra is a record over a stretch the transcript does not list: every word is an insertion.
	Extra bool `json:"extra,omitempty"`
}

// Report is a whole recording's score: every stretch, and the totals over them.
type Report struct {
	Overs         []OverScore `json:"overs"`
	Counts        Counts      `json:"counts"`
	Rate          float64     `json:"wer"`
	CallsignHits  int         `json:"callsign_hits"`
	CallsignTotal int         `json:"callsign_total"`
	Recall        float64     `json:"callsign_recall"`
	RefOvers      int         `json:"ref_overs"`
	HypOvers      int         `json:"hyp_overs"`
	Missing       int         `json:"missing"`
	Extra         int         `json:"extra"`
	// Skipped is the transcript lines marked "?", left out with the record that starts there.
	Skipped int `json:"skipped"`
}

// Score matches the engine's overs to the transcript's by (part, over) and scores each pair. An
// over the transcript lists and the engine has no record for counts its words as deletions; a
// record the transcript does not list counts its words as insertions. When the two sides cut a
// part differently, which Over.Last says, the overs whose openings overlap are joined into one
// stretch and scored together, so an engine whose segments hang on longer is not charged a
// deletion for the opening it heard inside the one before. A record whose over the transcript
// marks "?" is dropped with it.
func Score(ref *Transcript, hyp []Over) Report {
	skipped := map[Key]bool{}
	for _, k := range ref.Skipped {
		skipped[k] = true
	}
	refBy, hypBy := group(ref.Overs, nil), group(hyp, skipped)
	r := Report{RefOvers: len(refBy), HypOvers: len(hypBy), Skipped: len(ref.Skipped)}
	for _, st := range stretches(refBy, hypBy) {
		s := scoreStretch(st)
		r.Overs = append(r.Overs, s)
		r.Counts = r.Counts.Add(s.Counts)
		r.CallsignHits += s.CallsignHits
		r.CallsignTotal += s.CallsignTotal
		if s.Missing {
			r.Missing++
		}
		if s.Extra {
			r.Extra++
		}
	}
	r.Rate = r.Counts.Rate()
	r.Recall = 1
	if r.CallsignTotal > 0 {
		r.Recall = float64(r.CallsignHits) / float64(r.CallsignTotal)
	}
	return r
}

// group joins the overs that share a key, texts in the order given and the widest Last, leaving
// out the skipped keys.
func group(overs []Over, skip map[Key]bool) map[Key]Over {
	out := map[Key]Over{}
	for _, o := range overs {
		if skip[o.Key] {
			continue
		}
		if prev, ok := out[o.Key]; ok {
			prev.Text = strings.TrimSpace(prev.Text + " " + o.Text)
			prev.Last = max(prev.last(), o.last())
			out[o.Key] = prev
			continue
		}
		out[o.Key] = o
	}
	return out
}

// side says which list an over came from.
type side struct {
	Over
	isRef bool
}

// stretch is a run of overlapping overs in one part, scored as one.
type stretch struct {
	part     int
	last     int
	overs    []int
	ref, hyp []string
	hasRef   bool
	hasHyp   bool
}

// stretches sorts both sides by part and first opening and joins every over whose first opening
// falls inside the stretch so far.
func stretches(refBy, hypBy map[Key]Over) []stretch {
	all := make([]side, 0, len(refBy)+len(hypBy))
	for _, o := range refBy {
		all = append(all, side{o, true})
	}
	for _, o := range hypBy {
		all = append(all, side{o, false})
	}
	slices.SortFunc(all, func(a, b side) int {
		switch {
		case a.Key.Part != b.Key.Part:
			return a.Key.Part - b.Key.Part
		case a.Key.Over != b.Key.Over:
			return a.Key.Over - b.Key.Over
		case a.isRef != b.isRef:
			if a.isRef {
				return -1
			}
			return 1
		}
		return 0
	})
	var out []stretch
	for _, o := range all {
		n := len(out)
		if n == 0 || out[n-1].part != o.Key.Part || o.Key.Over > out[n-1].last {
			out = append(out, stretch{part: o.Key.Part})
			n++
		}
		st := &out[n-1]
		st.last = max(st.last, o.last())
		if !slices.Contains(st.overs, o.Key.Over) {
			st.overs = append(st.overs, o.Key.Over)
		}
		if o.isRef {
			st.ref, st.hasRef = append(st.ref, o.Text), true
		} else {
			st.hyp, st.hasHyp = append(st.hyp, o.Text), true
		}
	}
	return out
}

func scoreStretch(st stretch) OverScore {
	refText, hypText := strings.Join(st.ref, " "), strings.Join(st.hyp, " ")
	overs := make([]string, len(st.overs))
	for i, o := range st.overs {
		overs[i] = strconv.Itoa(o)
	}
	s := OverScore{
		Name: fmt.Sprintf("%d/%s", st.part, strings.Join(overs, "+")),
		Ref:  refText, Hyp: hypText,
		Counts:       Align(Words(refText), Words(hypText)),
		RefCallsigns: callsign.Find(refText), HypCallsigns: callsign.Find(hypText),
		Missing: !st.hasHyp, Extra: !st.hasRef,
	}
	s.Rate = s.Counts.Rate()
	s.CallsignHits, s.CallsignTotal, _ = CallsignRecall(s.RefCallsigns, s.HypCallsigns)
	return s
}
