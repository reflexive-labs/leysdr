package ui

import (
	"math"
	"testing"
)

func TestBar(t *testing.T) {
	ascii := Style{}
	uni := Style{Unicode: true}
	tests := []struct {
		name  string
		s     Style
		frac  float64
		width int
		want  string
	}{
		{"empty", ascii, 0, 4, "...."},
		{"full", ascii, 1, 4, "####"},
		{"half", ascii, 0.5, 4, "##.."},
		{"below zero clamps", ascii, -3, 4, "...."},
		{"above one clamps", ascii, 7, 4, "####"},
		{"nan reads empty", ascii, math.NaN(), 4, "...."},
		{"zero width", ascii, 0.5, 0, ""},
		{"negative width", ascii, 0.5, -2, ""},
		{"unicode", uni, 0.5, 2, "█░"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := tc.s.Bar(tc.frac, tc.width)
			if got != tc.want {
				t.Fatalf("Bar(%v, %d) = %q, want %q", tc.frac, tc.width, got, tc.want)
			}
			if w := Visible(got); tc.width > 0 && w != tc.width {
				t.Fatalf("Bar(%v, %d) is %d columns wide", tc.frac, tc.width, w)
			}
		})
	}
}

func TestRamp(t *testing.T) {
	ascii := Style{}
	uni := Style{Unicode: true}
	tests := []struct {
		name string
		s    Style
		frac float64
		want string
	}{
		{"zero is blank", ascii, 0, " "},
		{"below zero is blank", ascii, -1, " "},
		{"nan is blank", ascii, math.NaN(), " "},
		{"one is full", ascii, 1, "%"},
		{"above one is full", ascii, 9, "%"},
		{"middle", ascii, 0.5, "="},
		{"unicode zero", uni, 0, " "},
		{"unicode one", uni, 1, "█"},
		{"unicode middle", uni, 0.5, "▄"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.s.Ramp(tc.frac); got != tc.want {
				t.Fatalf("Ramp(%v) = %q, want %q", tc.frac, got, tc.want)
			}
		})
	}
	// The ramp is monotone: a louder bin is never a shorter column.
	prev := -1
	for i := 0; i <= 100; i++ {
		got := uni.Ramp(float64(i) / 100)
		idx := indexOf(uni.Glyphs().Ramp, []rune(got)[0])
		if idx < prev {
			t.Fatalf("ramp went backwards at %d%%: %q", i, got)
		}
		prev = idx
	}
}

func TestRule(t *testing.T) {
	if got := (Style{}).Rule(3); got != "---" {
		t.Errorf("ascii Rule(3) = %q", got)
	}
	if got := (Style{Unicode: true}).Rule(3); got != "───" {
		t.Errorf("unicode Rule(3) = %q", got)
	}
	if got := (Style{}).Rule(0); got != "" {
		t.Errorf("Rule(0) = %q, want empty", got)
	}
	if got := (Style{}).Rule(-4); got != "" {
		t.Errorf("Rule(-4) = %q, want empty", got)
	}
	if w := Visible((Style{Unicode: true}).Rule(80)); w != 80 {
		t.Errorf("Rule(80) is %d columns wide", w)
	}
}

func indexOf(rs []rune, r rune) int {
	for i, x := range rs {
		if x == r {
			return i
		}
	}
	return -1
}
