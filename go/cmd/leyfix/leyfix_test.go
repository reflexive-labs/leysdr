package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func sha(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	s := sha256.Sum256(b)
	return hex.EncodeToString(s[:])
}

func TestGenerateDeterministic(t *testing.T) {
	a, b := t.TempDir(), t.TempDir()
	o := genOptions{rate: 240_000, duration: 0.05, seed: 7, only: []string{"nfm_tone", "cw", "noise_floor"}}
	for _, d := range []string{a, b} {
		o.out = d
		if err := generate(o, &bytes.Buffer{}); err != nil {
			t.Fatal(err)
		}
	}
	for _, n := range o.only {
		ha, hb := sha(t, filepath.Join(a, n+".cf32")), sha(t, filepath.Join(b, n+".cf32"))
		if ha != hb {
			t.Fatalf("%s: samples differ between runs", n)
		}
		if sha(t, filepath.Join(a, n+".json")) != sha(t, filepath.Join(b, n+".json")) {
			t.Fatalf("%s: sidecars differ between runs", n)
		}
	}
	// Different seed changes the noise, so samples must differ.
	o.out, o.seed = t.TempDir(), 8
	if err := generate(o, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	if sha(t, filepath.Join(a, "noise_floor.cf32")) == sha(t, filepath.Join(o.out, "noise_floor.cf32")) {
		t.Fatal("seed did not change noise")
	}
}

func TestGenerateRejectsMisfit(t *testing.T) {
	o := genOptions{out: t.TempDir(), rate: 240_000, duration: 0.01, seed: 1, only: []string{"wfm_tone"}}
	if err := generate(o, &bytes.Buffer{}); err == nil {
		t.Fatal("expected error for wfm_tone at 240 kHz")
	}
	o.only = []string{"nope"}
	if err := generate(o, &bytes.Buffer{}); err == nil {
		t.Fatal("expected error for unknown fixture")
	}
}

func TestCheckReducedGeneration(t *testing.T) {
	dir := t.TempDir()
	var out bytes.Buffer
	if err := runGenerate([]string{"--out", dir, "--rate", "240000", "--duration", "0.25"}, &out); err != nil {
		t.Fatal(err)
	}
	// scan_band declares no expectations, so only its carriers can refuse it:
	// ±800 kHz has no room in a 240 kHz span.
	if !strings.Contains(out.String(), "skip scan_band") {
		t.Fatalf("scan_band should be skipped at 240 kHz:\n%s", out.String())
	}
	if _, err := os.Stat(filepath.Join(dir, "scan_band.cf32")); !os.IsNotExist(err) {
		t.Fatalf("scan_band.cf32 written at 240 kHz: %v", err)
	}
	out.Reset()
	if err := runCheck([]string{dir}, &out); err != nil {
		t.Fatalf("check failed: %v\n%s", err, out.String())
	}
	got := out.String()
	for _, n := range []string{"nfm_tone", "usb_tone", "cw", "noise_floor"} {
		if !strings.Contains(got, "PASS "+n+".json[0]") {
			t.Fatalf("missing PASS for %s:\n%s", n, got)
		}
	}
	if strings.Contains(got, "FAIL") {
		t.Fatalf("unexpected FAIL:\n%s", got)
	}
	out.Reset()
	if err := runInfo([]string{filepath.Join(dir, "cw.cf32")}, &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "duration:     0.250000 s") {
		t.Fatalf("info output:\n%s", out.String())
	}
}

func TestCheckDetectsWrongExpectation(t *testing.T) {
	dir := t.TempDir()
	if err := runGenerate([]string{"--out", dir, "--rate", "240000", "--duration", "0.25", "--only", "usb_tone"}, &bytes.Buffer{}); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, "usb_tone.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	// The generator block also carries tone_hz; the expect entry is the last one.
	i := bytes.LastIndex(b, []byte(`"tone_hz": 1000`))
	if i < 0 {
		t.Fatal("tone_hz not found in sidecar")
	}
	b = append(b[:i:i], append([]byte(`"tone_hz": 1200`), b[i+len(`"tone_hz": 1000`):]...)...)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	if err := runCheck([]string{p}, &out); err == nil {
		t.Fatalf("expected failure:\n%s", out.String())
	}
	if !strings.Contains(out.String(), "FAIL usb_tone.json[0]") {
		t.Fatalf("output:\n%s", out.String())
	}
}

func TestMorseTiming(t *testing.T) {
	spans, period := morseTiming("CQ", 10)
	if len(spans) != 8 {
		t.Fatalf("spans %d", len(spans))
	}
	dit := 0.12
	if d := period - 34*dit; d > 1e-9 || d < -1e-9 {
		t.Fatalf("period %v", period)
	}
	if d := spans[0].end - spans[0].start - 3*dit; d > 1e-9 || d < -1e-9 {
		t.Fatalf("first element should be a dah: %v", spans[0])
	}
}

// The fixtures with expectations that do not fit at 240 kHz (see
// TestCheckReducedGeneration) each round-trip generate+check on their own at a
// rate that holds them.
func TestCheckEachWideFixture(t *testing.T) {
	cases := []struct {
		name string
		rate string
	}{
		{"am_tone", "1024000"},
		{"wfm_tone", "1536000"},
		{"two_nfm", "1024000"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			dir := t.TempDir()
			var out bytes.Buffer
			if err := runGenerate([]string{"--out", dir, "--rate", c.rate, "--duration", "0.25", "--only", c.name}, &out); err != nil {
				t.Fatal(err)
			}
			out.Reset()
			if err := runCheck([]string{dir}, &out); err != nil {
				t.Fatalf("check failed: %v\n%s", err, out.String())
			}
			got := out.String()
			if !strings.Contains(got, "PASS "+c.name+".json[0]") || strings.Contains(got, "FAIL") {
				t.Fatalf("expected PASS for %s:\n%s", c.name, got)
			}
			if c.name == "two_nfm" && !strings.Contains(got, "PASS two_nfm.json[1]") {
				t.Fatalf("two_nfm should check both channels:\n%s", got)
			}
		})
	}
}

// scan_band is the fixture whose placement is the whole point, and it has no
// expectations to be judged by, so the rate check has to read its carriers.
func TestScanBandRateBound(t *testing.T) {
	f := findFixture("scan_band")
	if f == nil {
		t.Fatal("scan_band missing from the catalog")
	}
	for _, rate := range []float64{240_000, 1_024_000, 1_800_000} {
		if f.fits(rate) {
			t.Fatalf("scan_band should not fit at %.0f Hz", rate)
		}
	}
	if !f.fits(2_400_000) {
		t.Fatal("scan_band should fit at 2.4 MSPS")
	}
	dir := t.TempDir()
	var out bytes.Buffer
	if err := runGenerate([]string{"--out", dir, "--rate", "2400000", "--duration", "0.02", "--only", "scan_band"}, &out); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(dir, "scan_band.cf32")); err != nil {
		t.Fatalf("scan_band.cf32 not written at 2.4 MSPS: %v", err)
	}
}
