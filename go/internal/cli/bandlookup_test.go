package cli

import (
	"encoding/json"
	"strings"
	"testing"
)

func bandsOut(t *testing.T, args ...string) (string, string) {
	t.Helper()
	out, errOut, err := runApp(t, &App{}, append([]string{"bands"}, args...)...)
	if err != nil {
		t.Fatalf("ley bands %v: %v\n%s\n%s", args, err, out, errOut)
	}
	return out, errOut
}

// The question the table could only answer by making the reader scan fifteen
// rows: what is this frequency, and what will tune do with it?
func TestBandsLookupByFrequency(t *testing.T) {
	out, _ := bandsOut(t, "146.52")
	for _, want := range []string{"146.520 MHz", "2 m amateur", "144.000 MHz to 148.000 MHz", "nfm", "12.5 kHz", "2m"} {
		if !strings.Contains(out, want) {
			t.Errorf("want %q in:\n%s", want, out)
		}
	}
	// A screen ends with what to do next.
	if !strings.Contains(out, "ley spectrum --band 2m") {
		t.Errorf("want the next step:\n%s", out)
	}
}

// The mode is resolved for the frequency, so an HF band answers a concrete
// sideband rather than the table's usb/lsb.
func TestBandsLookupResolvesTheSideband(t *testing.T) {
	low, _ := bandsOut(t, "3.7") // 80 m, below 10 MHz
	if !strings.Contains(low, "lsb") || strings.Contains(low, "usb/lsb") {
		t.Errorf("3.7 MHz should answer lsb, not usb/lsb:\n%s", low)
	}
	high, _ := bandsOut(t, "14.2") // 20 m, above 10 MHz
	if !strings.Contains(high, "usb") || strings.Contains(high, "usb/lsb") {
		t.Errorf("14.2 MHz should answer usb:\n%s", high)
	}
}

// This is the one verb where a band name beats a frequency, because it is the
// verb about band names. Answering "160 m amateur" for `ley bands 2m` -- the
// alias this very screen tells you to type -- would be a worse papercut than
// the one being fixed.
func TestBandsLookupPrefersTheBandName(t *testing.T) {
	out, errOut := bandsOut(t, "2m")
	if !strings.Contains(out, "2 m amateur") {
		t.Errorf("2m must mean the 2 m band here:\n%s", out)
	}
	if strings.Contains(out, "160 m amateur") {
		t.Errorf("2m must not be read as 2 MHz:\n%s", out)
	}
	// And it says which reading it took, so the other is a keystroke away.
	if !strings.Contains(errOut, "reading \"2m\" as the band") || !strings.Contains(errOut, "2.000 MHz") {
		t.Errorf("an argument that reads both ways must say which was taken:\n%s", errOut)
	}
	// An alias that is not also a frequency says nothing.
	if _, quiet := bandsOut(t, "fm"); strings.Contains(quiet, "reading") {
		t.Errorf("fm is unambiguous and needs no note:\n%s", quiet)
	}
}

func TestBandsLookupAcceptsAPreset(t *testing.T) {
	out, _ := bandsOut(t, "noaa2")
	if !strings.Contains(out, "162.400 MHz") || !strings.Contains(out, "NOAA weather") {
		t.Errorf("a preset resolves to its frequency:\n%s", out)
	}
	// The reason names the preset, not the band default, so `bands` and `tune`
	// cannot disagree about why a mode was chosen.
	if !strings.Contains(out, "preset noaa2") {
		t.Errorf("want the preset rationale:\n%s", out)
	}
}

// Outside every band, in the same words `ley tune` uses.
func TestBandsLookupNoMatch(t *testing.T) {
	out, _ := bandsOut(t, "500")
	for _, want := range []string{"500.000 MHz is in no band ley knows", "nfm", "no band recognised, using NFM"} {
		if !strings.Contains(out, want) {
			t.Errorf("want %q in:\n%s", want, out)
		}
	}
	if !strings.Contains(out, "ley bands") {
		t.Errorf("want a next step even with no band:\n%s", out)
	}
}

// A script asking what to tune with still gets the answer when no band matches:
// null there would throw away the mode and bandwidth it came for.
func TestBandsLookupJSON(t *testing.T) {
	out, _ := bandsOut(t, "146.52", "--json")
	var hit struct {
		Hz   uint64 `json:"hz"`
		Band *struct {
			Name    string   `json:"name"`
			Aliases []string `json:"aliases"`
		} `json:"band"`
		Mode        string `json:"mode"`
		BandwidthHz uint32 `json:"bandwidth_hz"`
		Reason      string `json:"reason"`
	}
	if err := json.Unmarshal([]byte(out), &hit); err != nil {
		t.Fatalf("%v: %s", err, out)
	}
	if hit.Hz != 146_520_000 || hit.Band == nil || hit.Band.Name != "2 m amateur" || hit.Mode != "nfm" || hit.BandwidthHz != 12500 {
		t.Errorf("unexpected object: %s", out)
	}
	if len(hit.Band.Aliases) == 0 || hit.Band.Aliases[0] != "2m" {
		t.Errorf("aliases should be carried: %s", out)
	}

	miss, _ := bandsOut(t, "500", "--json")
	if err := json.Unmarshal([]byte(miss), &hit); err != nil {
		t.Fatalf("%v: %s", err, miss)
	}
	if hit.Band != nil {
		t.Errorf("no band should be null: %s", miss)
	}
	if hit.Mode != "nfm" || hit.BandwidthHz == 0 || hit.Reason == "" {
		t.Errorf("the answer survives a null band: %s", miss)
	}
}

// No argument keeps the table byte for byte.
func TestBandsWithNoArgumentStillPrintsTheTable(t *testing.T) {
	out, _ := bandsOut(t)
	for _, want := range []string{"NAME", "ALIAS", "RANGE", "2 m amateur", "NOAA weather"} {
		if !strings.Contains(out, want) {
			t.Errorf("want %q in the table:\n%s", want, out)
		}
	}
}

func TestBandsLookupRejectsNonsense(t *testing.T) {
	_, _, err := runApp(t, &App{}, "bands", "nonsense")
	if err == nil {
		t.Fatal("nonsense is neither a frequency nor a preset nor a band")
	}
	if exitCode(err) != ExitUsage {
		t.Errorf("want exit %d, got %d: %v", ExitUsage, exitCode(err), err)
	}
}
