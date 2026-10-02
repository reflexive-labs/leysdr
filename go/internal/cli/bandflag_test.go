// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"
	"time"

	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// A band is a range and a positional is a point, so the two conflict about
// where to put the radio. Passing both is a usage error rather than a silent
// precedence rule.
func TestBandFlagRefusesAPositionalToo(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	for _, verb := range []string{"spectrum", "waterfall", "phosphor"} {
		_, _, err := runApp(t, &App{Socket: sock}, verb, "101.1", "--band", "2m")
		if err == nil {
			t.Errorf("%s: a frequency and --band together should be refused", verb)
			continue
		}
		if got := err.Error(); !strings.Contains(got, "not both") {
			t.Errorf("%s: %q", verb, got)
		}
		if exitCode(err) != ExitUsage {
			t.Errorf("%s: want exit %d, got %d", verb, ExitUsage, exitCode(err))
		}
	}
}

// A band group the radio cannot capture whole is refused with its parts named: centring a
// picture between two halves 5 MHz apart would show neither.
func TestBandFlagRefusesAGroupThatDoesNotFit(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	for _, verb := range []string{"spectrum", "waterfall", "phosphor"} {
		_, _, err := runApp(t, &App{Socket: sock}, verb, "--band", "gmrs")
		if exitCode(err) != ExitUsage {
			t.Errorf("%s --band gmrs: want exit %d, got %v", verb, ExitUsage, err)
			continue
		}
		for _, want := range []string{"GMRS is 5.200 MHz wide", "captures at most", "gmrs-462 or gmrs-467"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%s: refusal lacks %q: %v", verb, want, err)
			}
		}
	}
	// A half fits, and is shown whole.
	out, _, err := runApp(t, &App{Socket: sock}, "spectrum", "--band", "gmrs-462")
	if err != nil || !strings.Contains(out, "462") {
		t.Errorf("spectrum --band gmrs-462: %v\n%s", err, out)
	}
}

func TestBandFlagUnknownName(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	_, _, err := runApp(t, &App{Socket: sock}, "spectrum", "--band", "2mm")
	if err == nil {
		t.Fatal("2mm is not a band")
	}
	if got := err.Error(); !strings.Contains(got, "did you mean") || !strings.Contains(got, "2m") {
		t.Errorf("want a suggestion: %q", got)
	}
	if exitCode(err) != ExitUsage {
		t.Errorf("want exit %d, got %d", ExitUsage, exitCode(err))
	}
}

// A band narrower than the radio's rates is shown whole: the capture centres on
// the band and takes the smallest rate that covers it.
func TestBandFlagFittingBandSetsTheCapture(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	out, errOut, err := runApp(t, &App{Socket: sock}, "spectrum", "--band", "noaa", "--width", "80")
	if err != nil {
		t.Fatalf("spectrum --band noaa: %v\n%s\n%s", err, out, errOut)
	}
	// NOAA is 162.400-162.550, so the capture centres on 162.475 and covers it.
	if !strings.Contains(out, "162.475 MHz") {
		t.Errorf("want the band's centre in the header:\n%s", out)
	}
	// A band that fits should not be reported as truncated.
	if strings.Contains(errOut, "captures at most") {
		t.Errorf("NOAA fits; nothing should be said about truncation:\n%s", errOut)
	}
	_ = c
}

// A band wider than any rate the radio has is centred, and the output states
// how much of the band is shown. Without that note the chart would cover a
// quarter of the band with no warning.
func TestBandFlagWideBandSaysWhatItShows(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	out, errOut, err := runApp(t, &App{Socket: sock}, "spectrum", "--band", "2m", "--width", "80")
	if err != nil {
		t.Fatalf("spectrum --band 2m: %v\n%s\n%s", err, out, errOut)
	}
	for _, want := range []string{"2 m amateur", "4.000 MHz", "captures at most", "146.000 MHz"} {
		if !strings.Contains(errOut, want) {
			t.Errorf("the truncation note should mention %q:\n%s", want, errOut)
		}
	}
	if !strings.Contains(out, "146.000 MHz") {
		t.Errorf("the chart should be centred on the band:\n%s", out)
	}
}

// An explicit --span wins over the band's width. The output notes when the
// span shows less than the whole band.
func TestBandFlagExplicitSpanWins(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{MeterInterval: 20 * time.Millisecond})
	out, errOut, err := runApp(t, &App{Socket: sock}, "spectrum", "--band", "2m", "--span", "250k", "--width", "80")
	if err != nil {
		t.Fatalf("spectrum --band 2m --span 250k: %v\n%s\n%s", err, out, errOut)
	}
	if !strings.Contains(errOut, "--span shows") {
		t.Errorf("a narrower --span should say so:\n%s", errOut)
	}
	if strings.Contains(errOut, "captures at most") {
		t.Errorf("--span was explicit, so the radio's limit is not the story:\n%s", errOut)
	}
	_ = out
}

// The four band views share one --rate rule, so a nonsense rate is a usage
// error before the daemon is asked for a stream that would never tick.
func TestBandFlagRefusesANonPositiveRate(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{})
	for _, verb := range []string{"spectrum", "waterfall", "phosphor", "fft"} {
		_, _, err := runApp(t, &App{Socket: sock}, verb, "--rate", "0")
		if err == nil {
			t.Errorf("%s --rate 0 should be refused", verb)
			continue
		}
		if got := err.Error(); !strings.Contains(got, "--rate must be greater than 0") {
			t.Errorf("%s: %q", verb, got)
		}
		if exitCode(err) != ExitUsage {
			t.Errorf("%s: want exit %d, got %d", verb, ExitUsage, exitCode(err))
		}
	}
}
