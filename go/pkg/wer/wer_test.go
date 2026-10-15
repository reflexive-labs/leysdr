// SPDX-License-Identifier: Apache-2.0

package wer

import (
	"math"
	"strings"
	"testing"
)

func TestNormalise(t *testing.T) {
	for _, tc := range []struct{ text, want string }{
		{"This is Whiskey Six Alpha Bravo Charlie, over.", "this is w6abc over"},
		{"this is W6ABC over", "this is w6abc over"},
		{"W 6 A B C checking in", "w6abc checking in"},
		{"whiskey six alpha bravo charlie slash papa", "w6abc"},
		// A letter-digit run that is no callsign stays as it was said.
		{"see you at six alpha", "see you at six alpha"},
		{"the net is on 146.94, PL 100.", "the net is on 146.94 pl 100"},
		{"Don't   key up—yet!", "dont key up yet"},
		{"kilo delta two x-ray yankee zulu, go ahead", "kd2xyz go ahead"},
		{"W6ABC, W7XYZ", "w6abc w7xyz"},
		{"", ""},
	} {
		if got := Normalise(tc.text); got != tc.want {
			t.Errorf("Normalise(%q) = %q, want %q", tc.text, got, tc.want)
		}
	}
}

func TestWER(t *testing.T) {
	for _, tc := range []struct {
		name            string
		ref, hyp        string
		subs, dels, ins int
		rate            float64
	}{
		{"identical", "a b c d", "a b c d", 0, 0, 0, 0},
		{"one substitution", "a b c d", "a x c d", 1, 0, 0, 0.25},
		{"one deletion", "a b c d", "a b d", 0, 1, 0, 0.25},
		{"one insertion", "a b c d", "a b x c d", 0, 0, 1, 0.25},
		{"all missing", "a b c d", "", 0, 4, 0, 1},
		{"words over silence", "", "a b", 0, 0, 2, 2},
		{"both empty", "", "", 0, 0, 0, 0},
		{"mixed", "the quick brown fox jumps", "a quick fox jumps high", 1, 1, 1, 0.6},
		{"more errors than words", "a", "x y z", 1, 0, 2, 3},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s, d, i, rate := WER(strings.Fields(tc.ref), strings.Fields(tc.hyp))
			if s != tc.subs || d != tc.dels || i != tc.ins || math.Abs(rate-tc.rate) > 1e-9 {
				t.Errorf("WER(%q, %q) = S%d D%d I%d %.3f, want S%d D%d I%d %.3f",
					tc.ref, tc.hyp, s, d, i, rate, tc.subs, tc.dels, tc.ins, tc.rate)
			}
		})
	}
}

// A callsign spoken on one side and written on the other is one word, so it costs nothing.
func TestWERAfterNormalising(t *testing.T) {
	ref := Words("this is whiskey six alpha bravo charlie checking in")
	hyp := Words("This is W6ABC, checking in.")
	if s, d, i, _ := WER(ref, hyp); s+d+i != 0 {
		t.Errorf("ref %v against hyp %v: S%d D%d I%d, want none", ref, hyp, s, d, i)
	}
}

func TestCallsignRecall(t *testing.T) {
	for _, tc := range []struct {
		ref, hyp    []string
		hits, total int
		recall      float64
	}{
		{[]string{"W6ABC", "KD2XYZ"}, []string{"W6ABC"}, 1, 2, 0.5},
		{[]string{"W6ABC", "W6ABC"}, []string{"w6abc"}, 1, 1, 1},
		{[]string{"W6ABC"}, nil, 0, 1, 0},
		{nil, []string{"W6ABC"}, 0, 0, 1},
	} {
		h, n, r := CallsignRecall(tc.ref, tc.hyp)
		if h != tc.hits || n != tc.total || r != tc.recall {
			t.Errorf("CallsignRecall(%v, %v) = %d/%d %.2f, want %d/%d %.2f", tc.ref, tc.hyp, h, n, r, tc.hits, tc.total, tc.recall)
		}
	}
}

func over(part, n int, text string) Over { return Over{Key: Key{part, n}, Text: text} }

func TestScore(t *testing.T) {
	ref := &Transcript{
		Overs: []Over{
			over(1, 1, "this is whiskey six alpha bravo charlie checking in"), // "this is w6abc checking in": 5 words
			over(1, 3, "kilo delta two x-ray yankee zulu go ahead"),           // "kd2xyz go ahead": 3
			over(2, 1, "roger see you at six alpha"),                          // 6
			over(2, 2, "seventy three"),                                       // 2, no record
		},
		Skipped: []Key{{3, 1}},
	}
	hyp := []Over{
		over(1, 1, "This is W6ABC checking in."),           // exact
		over(1, 3, "kilo delta two x-ray yankee go ahead"), // the callsign misheard as KD2XY: one substitution
		over(2, 1, "roger see you at six"),                 // one deletion
		over(2, 4, "hello"),                                // a record the transcript does not list
		over(3, 1, "not yet transcribed"),                  // dropped with its "?" line
	}
	r := Score(ref, hyp)
	if len(r.Overs) != 5 {
		t.Fatalf("got %d stretches, want 5: %+v", len(r.Overs), r.Overs)
	}
	if r.Overs[0].Counts.Errors() != 0 || r.Overs[0].CallsignHits != 1 {
		t.Errorf("1/1: %+v, want no errors and its callsign found", r.Overs[0])
	}
	if got := r.Overs[1].Counts; got.Subs != 1 || got.Errors() != 1 || got.RefWords != 3 || r.Overs[1].CallsignHits != 0 || r.Overs[1].CallsignTotal != 1 {
		t.Errorf("1/3: %+v", r.Overs[1])
	}
	if got := r.Overs[2].Counts; got.Dels != 1 || got.Errors() != 1 {
		t.Errorf("2/1: %+v, want one deletion", got)
	}
	if !r.Overs[3].Missing || r.Overs[3].Counts.Dels != 2 {
		t.Errorf("2/2: %+v, want missing with two deletions", r.Overs[3])
	}
	if !r.Overs[4].Extra || r.Overs[4].Counts.Ins != 1 {
		t.Errorf("2/4: %+v, want extra with one insertion", r.Overs[4])
	}
	if want := (Counts{RefWords: 5 + 3 + 6 + 2, Subs: 1, Dels: 1 + 2, Ins: 1}); r.Counts != want {
		t.Errorf("total %+v, want %+v", r.Counts, want)
	}
	if math.Abs(r.Rate-5.0/16) > 1e-9 {
		t.Errorf("rate %.4f, want %.4f", r.Rate, 5.0/16)
	}
	if r.CallsignHits != 1 || r.CallsignTotal != 2 || r.Recall != 0.5 {
		t.Errorf("callsigns %d/%d %.2f, want 1/2 0.5", r.CallsignHits, r.CallsignTotal, r.Recall)
	}
	if r.RefOvers != 4 || r.HypOvers != 4 || r.Missing != 1 || r.Extra != 1 || r.Skipped != 1 {
		t.Errorf("tallies %+v", r)
	}
}

// An engine whose segment holds two openings the transcript lists apart is scored against both
// lines joined, not charged a deletion for the second.
func TestScoreJoinsDifferentCuts(t *testing.T) {
	ref := &Transcript{Overs: []Over{over(1, 1, "net control"), over(1, 2, "go ahead"), over(1, 3, "thanks")}}
	joined := over(1, 1, "net control go ahead")
	joined.Last = 2
	hyp := []Over{joined, over(1, 3, "thanks")}
	r := Score(ref, hyp)
	if len(r.Overs) != 2 || r.Overs[0].Name != "1/1+2" || r.Counts.Errors() != 0 {
		t.Errorf("got %+v, want 1/1+2 and 1/3 with no errors", r.Overs)
	}
	// And the other way: the transcript joins what the engine split.
	r = Score(&Transcript{Overs: []Over{joined}}, []Over{over(1, 1, "net control"), over(1, 2, "go ahead")})
	if len(r.Overs) != 1 || r.Counts.Errors() != 0 || r.Extra != 0 {
		t.Errorf("got %+v, want one stretch with no errors", r.Overs)
	}
}
