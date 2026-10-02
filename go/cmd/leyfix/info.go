// SPDX-License-Identifier: Apache-2.0

package main

import (
	"errors"
	"fmt"
	"io"
	"math"

	"github.com/reflexive-labs/leysdr/go/pkg/iqfile"
)

func runInfo(args []string, w io.Writer) error {
	if len(args) != 1 {
		return errors.New("info: exactly one FILE argument required")
	}
	sc, err := iqfile.ReadSidecar(args[0])
	if err != nil {
		return err
	}
	r, err := iqfile.Open(args[0], sc.Format)
	if err != nil {
		return err
	}
	defer r.Close()
	buf := make([]complex64, 1<<16)
	var (
		peak  float64
		power float64
		count int64
	)
	for {
		n, err := r.Read(buf)
		for _, v := range buf[:n] {
			re, im := float64(real(v)), float64(imag(v))
			p := re*re + im*im
			power += p
			peak = math.Max(peak, p)
		}
		count += int64(n)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return err
		}
	}
	fmt.Fprintf(w, "file:         %s\n", iqfile.SamplesPath(args[0], sc.Format))
	fmt.Fprintf(w, "format:       %s\n", sc.Format)
	fmt.Fprintf(w, "sample_rate:  %.0f Hz\n", sc.SampleRate)
	fmt.Fprintf(w, "center_hz:    %.0f Hz\n", sc.CenterHz)
	fmt.Fprintf(w, "samples:      %d (sidecar %d)\n", count, sc.Samples)
	fmt.Fprintf(w, "duration:     %.6f s\n", float64(count)/sc.SampleRate)
	if count > 0 {
		fmt.Fprintf(w, "peak:         %.4f (%.1f dBFS)\n", math.Sqrt(peak), 10*math.Log10(peak))
		fmt.Fprintf(w, "mean power:   %.1f dBFS\n", 10*math.Log10(power/float64(count)))
	}
	if sc.Description != "" {
		fmt.Fprintf(w, "description:  %s\n", sc.Description)
	}
	for i, e := range sc.Expect {
		fmt.Fprintf(w, "expect[%d]:    %s @%+.0f Hz bw %.0f Hz", i, e.Mode, e.OffsetHz, e.BandwidthHz)
		if e.Audio != nil {
			fmt.Fprintf(w, " tone %.0f Hz snr>=%.0f dB", e.Audio.ToneHz, e.Audio.MinSNRDB)
		}
		fmt.Fprintln(w)
	}
	for k, v := range sc.Metadata {
		fmt.Fprintf(w, "metadata.%s: %s\n", k, v)
	}
	return nil
}
