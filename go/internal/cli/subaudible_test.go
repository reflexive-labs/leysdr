package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
)

func ctcss(std, measured, dev, snr float64) *leylinev1.SubAudible {
	return &leylinev1.SubAudible{
		Kind:           leylinev1.SubAudibleKind_SUB_AUDIBLE_CTCSS,
		StandardToneHz: std, ToneHz: measured, DeviationHz: dev, ToneSnrDb: snr,
	}
}

// The daemon repeats itself on a heartbeat, because the telemetry plane has no
// GetState and a client subscribing mid-transmission has to be told what is
// already there. A person watching does not need to be told twice.
func TestSubAudibleReportsOnlyChanges(t *testing.T) {
	var tr subAudibleTracker
	st := ui.Style{}
	if _, ok := tr.line(ctcss(100, 100.1, 700, 20), st); !ok {
		t.Fatal("the first tone must be reported")
	}
	if _, ok := tr.line(ctcss(100, 100.2, 690, 21), st); ok {
		t.Error("the same tone repeated must not print again")
	}
	if _, ok := tr.line(ctcss(123, 123.1, 700, 22), st); !ok {
		t.Error("a different tone is news")
	}
}

// A channel that never had a tone does not narrate its absence: the daemon says
// SUB_AUDIBLE_NONE every heartbeat on every NFM channel in the world.
func TestSubAudibleSilenceIsNotNarrated(t *testing.T) {
	var tr subAudibleTracker
	for i := 0; i < 5; i++ {
		if line, ok := tr.line(&leylinev1.SubAudible{Kind: leylinev1.SubAudibleKind_SUB_AUDIBLE_NONE}, ui.Style{}); ok {
			t.Fatalf("no tone must print nothing, got %q", line)
		}
	}
	if _, ok := tr.line(nil, ui.Style{}); ok {
		t.Error("a nil report prints nothing")
	}
}

// A measurement two standard tones could both explain is reported as a
// measurement and said to be unclassifiable. Naming one of them would be a
// guess wearing a reading's clothes.
func TestSubAudibleUnclassifiedSaysSo(t *testing.T) {
	var tr subAudibleTracker
	line, ok := tr.line(ctcss(0, 68.15, 700, 20), ui.Style{})
	if !ok {
		t.Fatal("an unclassifiable tone is still worth reporting")
	}
	if !strings.Contains(line, "68.2") { // 68.15 rounds to one decimal
		t.Errorf("the measurement is reported: %q", line)
	}
	if !strings.Contains(line, "between two standard tones") {
		t.Errorf("and it is said to be unclassifiable: %q", line)
	}
}

// The style guide's first principle.
func TestSubAudibleStripsToPlain(t *testing.T) {
	for _, sa := range []*leylinev1.SubAudible{
		ctcss(100, 100.1, 700, 20),
		ctcss(0, 68.15, 700, 12),
	} {
		var a, b subAudibleTracker
		plain, _ := a.line(sa, ui.Style{})
		styled, _ := b.line(sa, ui.Style{Color: true, Unicode: true, Profile: ui.ProfileTrueColor})
		if ui.Strip(styled) != plain {
			t.Errorf("styled != plain:\n plain  %q\n styled %q", plain, ui.Strip(styled))
		}
	}
}
