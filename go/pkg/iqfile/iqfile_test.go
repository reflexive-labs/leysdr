// SPDX-License-Identifier: Apache-2.0

package iqfile

import (
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPaths(t *testing.T) {
	if got := SidecarPath("a/b.cf32"); got != "a/b.json" {
		t.Fatal(got)
	}
	if got := SidecarPath("a/b.cu8"); got != "a/b.json" {
		t.Fatal(got)
	}
	if got := SamplesPath("a/b.json", FormatCU8); got != "a/b.cu8" {
		t.Fatal(got)
	}
	if got := SamplesPath("a/b.json", ""); got != "a/b.cf32" {
		t.Fatal(got)
	}
	if got := SamplesPath("a/b.cu8", FormatCF32); got != "a/b.cu8" {
		t.Fatal(got)
	}
}

func TestRoundTripCF32(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "x.cf32")
	w, err := NewWriter(p)
	if err != nil {
		t.Fatal(err)
	}
	src := make([]complex64, 10000)
	for i := range src {
		src[i] = complex(float32(i)/10000, -float32(i)/20000)
	}
	if err := w.Write(src[:3000]); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(src[3000:]); err != nil {
		t.Fatal(err)
	}
	if w.Samples() != 10000 {
		t.Fatal(w.Samples())
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	sc := &Sidecar{
		Format: FormatCF32, SampleRate: 48000, CenterHz: 1e6, Samples: 10000,
		Expect: []Expect{{
			Mode: "NFM", OffsetHz: 100, BandwidthHz: 12500,
			Audio: &AudioExpect{ToneHz: 1000, MinSNRDB: 30},
		}},
		Metadata: map[string]string{"mode": "NFM"},
	}
	if err := WriteSidecar(p, sc); err != nil {
		t.Fatal(err)
	}
	got, err := ReadSidecar(filepath.Join(dir, "x.json"))
	if err != nil {
		t.Fatal(err)
	}
	if got.SampleRate != 48000 || len(got.Expect) != 1 || got.Expect[0].Audio.ToneHz != 1000 || got.Metadata["mode"] != "NFM" {
		t.Fatalf("sidecar mismatch: %+v", got)
	}
	r, err := Open(filepath.Join(dir, "x.json"), got.Format)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	if r.Samples != 10000 {
		t.Fatal(r.Samples)
	}
	buf := make([]complex64, 4096)
	var all []complex64
	for {
		n, err := r.Read(buf)
		all = append(all, buf[:n]...)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	if len(all) != len(src) {
		t.Fatalf("len %d", len(all))
	}
	for i := range src {
		if all[i] != src[i] {
			t.Fatalf("sample %d: %v != %v", i, all[i], src[i])
		}
	}
}

func TestReadCU8(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "y.cu8")
	if err := os.WriteFile(p, []byte{0, 255, 128, 127, 255, 0}, 0o644); err != nil {
		t.Fatal(err)
	}
	all, err := ReadAll(p, FormatCU8)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 3 {
		t.Fatal(len(all))
	}
	if real(all[0]) != -1 || imag(all[0]) != 1 || real(all[2]) != 1 || imag(all[2]) != -1 {
		t.Fatalf("%v", all)
	}
	if d := real(all[1]) - 0.5/127.5; d > 1e-6 || d < -1e-6 {
		t.Fatalf("%v", all[1])
	}
}

// A zero-length buffer is a caller mistake — a size computed from a config value
// or a sidecar field — and the documented drain loop breaks only on io.EOF, so
// answering "no samples, no error" would spin instead of failing.
func TestReadRefusesAnEmptyBuffer(t *testing.T) {
	p := filepath.Join(t.TempDir(), "x.cf32")
	w, err := NewWriter(p)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Write(make([]complex64, 16)); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	r, err := Open(p, FormatCF32)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Close()
	n, err := r.Read(nil)
	if n != 0 || err == nil || errors.Is(err, io.EOF) {
		t.Fatalf("Read(nil) = %d, %v; want an error that is not io.EOF", n, err)
	}
	if n, err := r.Read(make([]complex64, 16)); n != 16 || err != nil {
		t.Fatalf("the reader must still be usable: %d, %v", n, err)
	}
}

// The cu8 writer is the reader's inverse to within half a step, and clips outside ±1.
func TestWriteCU8(t *testing.T) {
	p := filepath.Join(t.TempDir(), "z.cu8")
	w, err := NewFormatWriter(p, FormatCU8)
	if err != nil {
		t.Fatal(err)
	}
	src := []complex64{complex(-1, 1), complex(0.25, -0.5), complex(2, -2), 0}
	if err := w.Write(src); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(p)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) != 2*len(src) || raw[0] != 0 || raw[1] != 255 || raw[4] != 255 || raw[5] != 0 {
		t.Fatalf("bytes %v", raw)
	}
	got, err := ReadAll(p, FormatCU8)
	if err != nil {
		t.Fatal(err)
	}
	const halfStep = 0.5/127.5 + 1e-6
	for i, want := range []complex64{complex(-1, 1), complex(0.25, -0.5), complex(1, -1), 0} {
		if d := got[i] - want; real(d) > halfStep || real(d) < -halfStep || imag(d) > halfStep || imag(d) < -halfStep {
			t.Errorf("sample %d: %v, want %v", i, got[i], want)
		}
	}
	if _, err := NewFormatWriter(filepath.Join(t.TempDir(), "x.cs16"), "cs16"); err == nil {
		t.Error("an unknown format should be refused")
	}
}

// Label is optional and left out of the file when empty, so a sidecar written before it
// existed reads back unchanged.
func TestSidecarLabel(t *testing.T) {
	dir := t.TempDir()
	for _, label := range []string{"", "NESDR SMArt v5"} {
		p := filepath.Join(dir, "l.cu8")
		if err := WriteSidecar(p, &Sidecar{Format: FormatCU8, SampleRate: 2.4e6, Label: label}); err != nil {
			t.Fatal(err)
		}
		b, err := os.ReadFile(SidecarPath(p))
		if err != nil {
			t.Fatal(err)
		}
		if has := strings.Contains(string(b), `"label"`); has != (label != "") {
			t.Errorf("label %q: the file %s the key", label, map[bool]string{true: "has", false: "lacks"}[has])
		}
		got, err := ReadSidecar(p)
		if err != nil {
			t.Fatal(err)
		}
		if got.Label != label {
			t.Errorf("label read back as %q, want %q", got.Label, label)
		}
	}
}
