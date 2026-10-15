// SPDX-License-Identifier: Apache-2.0

package main

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"text/tabwriter"

	"github.com/reflexive-labs/leysdr/go/pkg/wer"
)

// result is one engine measured on one recording, or live on one frequency.
type result struct {
	Engine    string `json:"engine"`
	Model     string `json:"model,omitempty"`
	Recording string `json:"recording"`
	JobID     string `json:"job_id,omitempty"`
	Records   int    `json:"records"`
	// Ref is the hand transcript scored against, and Score the score; both empty without one.
	Ref   string      `json:"ref,omitempty"`
	Score *wer.Report `json:"score,omitempty"`
	// OpenSeconds is how long the squelch was open across the recording: the audio the plan's
	// cost per hour is counted against.
	OpenSeconds float64 `json:"open_seconds"`
	// Usage is the ledger's lines for the job, summed, in the provider's units; PerOpenHour is the
	// same scaled to one hour of squelch-open audio.
	Usage       usage   `json:"usage"`
	PerOpenHour usage   `json:"per_open_hour"`
	WallSeconds float64 `json:"wall_seconds"`
	// Speed is seconds of squelch-open audio transcribed per second of wall clock, for a stored
	// recording. A live run has Latency instead.
	Speed   float64  `json:"speed,omitempty"`
	Latency *latency `json:"latency,omitempty"`
}

// usage is what a provider counted, as the ledger holds it. Counts are float64 so that the same
// type holds the per-hour rate.
type usage struct {
	Provider         string  `json:"provider,omitempty"`
	Model            string  `json:"model,omitempty"`
	Requests         float64 `json:"requests"`
	InputTokens      float64 `json:"input_tokens"`
	OutputTokens     float64 `json:"output_tokens"`
	CacheReadTokens  float64 `json:"cache_read_tokens"`
	CacheWriteTokens float64 `json:"cache_write_tokens"`
	AudioSeconds     float64 `json:"audio_seconds"`
}

func (u usage) scaled(f float64) usage {
	return usage{
		Provider: u.Provider, Model: u.Model, Requests: u.Requests * f,
		InputTokens: u.InputTokens * f, OutputTokens: u.OutputTokens * f,
		CacheReadTokens: u.CacheReadTokens * f, CacheWriteTokens: u.CacheWriteTokens * f,
		AudioSeconds: u.AudioSeconds * f,
	}
}

func (u usage) tokens() float64 {
	return u.InputTokens + u.OutputTokens + u.CacheReadTokens + u.CacheWriteTokens
}

// billed is the unit the provider counts in: audio seconds for a speech API that bills by
// duration, tokens for one that bills by tokens, requests when it reports neither.
func (u usage) billed() string {
	switch {
	case u.AudioSeconds > 0:
		return fmt.Sprintf("%.0f s audio", u.AudioSeconds)
	case u.tokens() > 0:
		return fmt.Sprintf("%.0f tokens", u.tokens())
	case u.Requests > 0:
		return fmt.Sprintf("%.0f requests", u.Requests)
	}
	return "-"
}

// printJSON prints the results as one JSON array.
func printJSON(w io.Writer, results []*result) error {
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(results)
}

// writeTable prints one row per result: the shape of the table the decision record holds.
func writeTable(w io.Writer, results []*result) error {
	tw := tabwriter.NewWriter(w, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ENGINE\tMODEL\tOVERS\tWER\tS/D/I\tCALLSIGNS\tOPEN\tREQUESTS\tBILLED\tPER OPEN HOUR\tSPEED")
	for _, r := range results {
		overs, rate, sdi, calls := fmt.Sprint(r.Records), "-", "-", "-"
		if sc := r.Score; sc != nil {
			overs = fmt.Sprintf("%d/%d", sc.HypOvers, sc.RefOvers)
			rate = fmt.Sprintf("%.1f%%", sc.Rate*100)
			sdi = fmt.Sprintf("%d/%d/%d", sc.Counts.Subs, sc.Counts.Dels, sc.Counts.Ins)
			if sc.CallsignTotal > 0 {
				calls = fmt.Sprintf("%d/%d", sc.CallsignHits, sc.CallsignTotal)
			}
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\t%s\t%.1f min\t%.0f\t%s\t%s\t%s\n",
			r.Engine, orDash(r.Model), overs, rate, sdi, calls, r.OpenSeconds/60, r.Usage.Requests,
			r.Usage.billed(), r.PerOpenHour.billed(), r.speedCell())
	}
	return tw.Flush()
}

func (r *result) speedCell() string {
	if l := r.Latency; l != nil {
		if len(l.Overs) == 0 {
			return "no overs"
		}
		return fmt.Sprintf("%.1f s median, %.1f s p90", l.MedianSeconds, l.P90Seconds)
	}
	if r.Speed > 0 {
		return fmt.Sprintf("%.1fx real time", r.Speed)
	}
	return "-"
}

// writeNotes prints what the table cannot: that nothing was scored without a transcript, and
// every stretch that was not word-perfect, so a high WER can be read rather than guessed at.
func writeNotes(w io.Writer, results []*result) {
	for _, r := range results {
		if r.Score == nil && r.Latency == nil {
			fmt.Fprintf(w, "\n%s: no hand transcript, so nothing was scored. Start one with: leyspeech ref %s\n", r.Engine, r.Recording)
			continue
		}
		if r.Score == nil {
			continue
		}
		if r.Score.Skipped > 0 {
			fmt.Fprintf(w, "\n%s: %d over(s) of %s are marked ? and were left out.\n", r.Engine, r.Score.Skipped, r.Ref)
		}
		var bad []wer.OverScore
		for _, o := range r.Score.Overs {
			if o.Counts.Errors() > 0 || o.CallsignHits < o.CallsignTotal {
				bad = append(bad, o)
			}
		}
		if len(bad) == 0 {
			continue
		}
		fmt.Fprintf(w, "\n%s %s, the overs with errors:\n", r.Engine, orDash(r.Model))
		for _, o := range bad {
			why := fmt.Sprintf("S%d D%d I%d", o.Counts.Subs, o.Counts.Dels, o.Counts.Ins)
			switch {
			case o.Missing:
				why += ", no record"
			case o.Extra:
				why += ", not in the transcript"
			}
			fmt.Fprintf(w, "  %s  %s\n    ref: %s\n    hyp: %s\n", o.Name, why, orDash(o.Ref), orDash(o.Hyp))
		}
	}
}

func orDash(s string) string {
	if strings.TrimSpace(s) == "" {
		return "-"
	}
	return s
}
