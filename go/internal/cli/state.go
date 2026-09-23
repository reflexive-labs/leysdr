// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/internal/ui"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func newStateCommand(app *App) *cobra.Command {
	var wide bool
	cmd := &cobra.Command{
		Use:   "state",
		Short: "Show everything the daemon knows right now",
		Long: `state prints the daemon's whole picture: the daemon itself, every radio,
every capture (a radio tuned to a band), every channel (one station picked
out of a capture: frequency, mode, squelch) and every sink (where the audio
goes). It is the place to look when something is not doing what you expect,
and 'ley state --json' is the snapshot scripts and agents should read.`,
		Example: `  ley state                # the whole picture, as a tree
  ley state --wide         # the same, as flat tables with every column
  ley state --json         # the same as proto3 JSON (GetStateResponse)`,
		GroupID: GroupLooking,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			st, err := stateSnapshot(cmd.Context(), app)
			if err != nil {
				return err
			}
			if app.JSON {
				return app.printJSON(st)
			}
			printState(app, st, wide)
			return nil
		},
	}
	cmd.Flags().BoolVar(&wide, "wide", false, "flat tables (every id, owner and column) instead of the tree")
	return cmd
}

// stateSnapshot dials, reads the daemon's whole picture and hangs up. The bare
// `ley` under --json answers with the same snapshot `ley state --json` prints,
// so a script has one shape to read whichever it types.
func stateSnapshot(ctx context.Context, app *App) (*leylinev1.GetStateResponse, error) {
	c, err := app.dial(ctx)
	if err != nil {
		return nil, app.notRunning(err)
	}
	defer c.Close()
	st, err := c.State(ctx)
	if err != nil {
		return nil, app.notRunning(err)
	}
	return st, nil
}

func daemonLine(d *leylinev1.DaemonInfo) string {
	if d == nil {
		return "daemon: (no info)"
	}
	up := time.Since(time.Unix(0, d.StartedAtNs)).Truncate(time.Second)
	return fmt.Sprintf("daemon %s pid %d up %s socket %s", d.Version, d.Pid, up, d.SocketPath)
}

// printState renders the whole daemon picture: a header, then either the tree
// (device to capture to channel to sink, hierarchy carried by indentation) or,
// behind --wide, the flat tables with every id and owner in a column.
func printState(app *App, st *leylinev1.GetStateResponse, wide bool) {
	fmt.Fprint(app.Stdout, stateHeader(app.Style, st, time.Now()))
	if wide {
		printStateTables(app, st)
		return
	}
	fmt.Fprint(app.Stdout, renderStateTree(app.Style, st))
}

// stateHeader is the two-line preamble: what the daemon is on the first line,
// where it is on a muted second one. The event sequence stays in the header
// for reconnect debugging, but not on the first line.
func stateHeader(s ui.Style, st *leylinev1.GetStateResponse, now time.Time) string {
	d := st.GetDaemon()
	if d == nil {
		return fmt.Sprintf("%s (no info)\n%s\n\n", s.Label("daemon"), s.Muted(fmt.Sprintf("event seq %d", st.GetEventSeq())))
	}
	up := now.Sub(time.Unix(0, d.StartedAtNs)).Truncate(time.Second)
	return fmt.Sprintf("%s %s  up %s\n%s\n\n", s.Label("daemon"), d.Version, up,
		s.Muted(fmt.Sprintf("pid %d  socket %s  event seq %d", d.Pid, d.SocketPath, st.GetEventSeq())))
}

// treeNode is one thing the daemon holds: a headline that answers "what is
// this", a muted detail line carrying the id and the facts nobody reads
// first, and the things that hang off it.
type treeNode struct {
	head   []string
	detail []string
	kids   []treeNode
}

// renderStateTree lays the state out by indentation instead of by repeated
// ids: each level names only what is new, so the DEVICE, CAPTURE and CHANNEL
// columns disappear. Ids stay whole and copy-pasteable on their own line.
func renderStateTree(s ui.Style, st *leylinev1.GetStateResponse) string {
	var b strings.Builder
	roots, orphans := stateNodes(s, st)
	if len(roots) == 0 && len(orphans) == 0 {
		b.WriteString("nothing running (no devices, captures or channels)\n\n")
		fmt.Fprintf(&b, "%s\n  %s %s\n", s.Label("Next:"), s.Pad(s.Cmd("ley devices"), 28), s.Muted("look for a radio the daemon can see"))
		return b.String()
	}
	for i, n := range roots {
		if i > 0 {
			b.WriteString("\n")
		}
		writeNode(&b, s, n, "", "", "  ")
	}
	if len(orphans) > 0 {
		fmt.Fprintf(&b, "\n%s\n", s.Muted("not attached to a listed device"))
		writeNodes(&b, s, orphans, "  ")
	}
	// A playback hangs off no device: it is a recording playing through the daemon's speakers,
	// with no radio in it, so it gets its own short block rather than a place in the tree.
	writePlaybacks(&b, s, st)
	return b.String()
}

// writePlaybacks lists the recordings the daemon is playing. Nothing is written when there are
// none, which is the usual case.
func writePlaybacks(b *strings.Builder, s ui.Style, st *leylinev1.GetStateResponse) {
	if len(st.GetPlaybacks()) == 0 {
		return
	}
	fmt.Fprintf(b, "\n%s\n", s.Muted("playing through the daemon's audio"))
	for _, p := range st.GetPlaybacks() {
		fmt.Fprintf(b, "  %s  %s  %s\n", playbackPosition(p), p.GetResourceUri(),
			s.Muted(clientString(p.GetCreatedBy())))
	}
}

// playbackPosition is how far a playback has got, as a player shows it.
func playbackPosition(p *leylinev1.Playback) string {
	rate := float64(max(p.GetSampleRate(), 1))
	return fmt.Sprintf("%s / %s",
		clockPhrase(float64(p.GetPosition())/rate), clockPhrase(float64(p.GetSamples())/rate))
}

// stateNodes turns the flat lists into the tree, and returns anything whose
// parent is missing from the snapshot separately: a row is never dropped
// because its device or capture is not there.
func stateNodes(s ui.Style, st *leylinev1.GetStateResponse) (roots, orphans []treeNode) {
	sinks := map[string][]*leylinev1.Sink{}
	for _, sk := range st.GetSinks() {
		sinks[sk.ChannelId] = append(sinks[sk.ChannelId], sk)
	}
	channels := map[string][]*leylinev1.Channel{}
	for _, ch := range st.GetChannels() {
		channels[ch.CaptureId] = append(channels[ch.CaptureId], ch)
	}
	captures := map[string][]*leylinev1.Capture{}
	for _, c := range st.GetCaptures() {
		captures[c.DeviceId] = append(captures[c.DeviceId], c)
	}
	buildChannel := func(ch *leylinev1.Channel) treeNode {
		n := channelNode(s, st, ch)
		for _, sk := range sinks[ch.ChannelId] {
			n.kids = append(n.kids, sinkNode(s, sk))
		}
		delete(sinks, ch.ChannelId)
		return n
	}
	buildCapture := func(c *leylinev1.Capture) treeNode {
		n := captureNode(s, c)
		for _, ch := range channels[c.CaptureId] {
			n.kids = append(n.kids, buildChannel(ch))
		}
		delete(channels, c.CaptureId)
		return n
	}
	for _, d := range st.GetDevices() {
		n := deviceNode(s, d)
		for _, c := range captures[d.DeviceId] {
			n.kids = append(n.kids, buildCapture(c))
		}
		delete(captures, d.DeviceId)
		roots = append(roots, n)
	}
	// What is left in the maps is orphaned, but the maps are walked in wire
	// order rather than iterated: two runs against an unchanged daemon must
	// print the same screen. A parent that was drawn took its whole entry with
	// it, so a key still present means every row under it is an orphan.
	for _, c := range st.GetCaptures() {
		if _, ok := captures[c.DeviceId]; ok {
			orphans = append(orphans, buildCapture(c))
		}
	}
	for _, ch := range st.GetChannels() {
		if _, ok := channels[ch.CaptureId]; ok {
			orphans = append(orphans, buildChannel(ch))
		}
	}
	for _, sk := range st.GetSinks() {
		if _, ok := sinks[sk.ChannelId]; ok {
			orphans = append(orphans, sinkNode(s, sk))
		}
	}
	return roots, orphans
}

// deviceNode is a radio: what it is, what it is doing, and its id below.
func deviceNode(s ui.Style, d *leylinev1.DeviceDescriptor) treeNode {
	name := d.Model
	if name == "" {
		name = d.DeviceId
	}
	n := treeNode{head: []string{name, s.Muted(d.Driver), inkState(s, deviceStateWords(d))}}
	n.detail = []string{s.Muted("device " + d.DeviceId)}
	if d.Serial != "" {
		n.detail = append(n.detail, s.Muted("serial "+d.Serial))
	}
	n.detail = append(n.detail, s.Muted("tunes "+absentIfEmpty(s, rangesPhrase(d.TuningRanges))))
	return n
}

// captureNode is a radio tuned to a band.
func captureNode(s ui.Style, c *leylinev1.Capture) treeNode {
	head := []string{leyline.FormatFrequency(c.CenterHz), ratesString([]uint64{c.SampleRate}), inkState(s, stateWord(c.State.String()))}
	if g := captureGains(c.Gains); g != "" {
		head = append(head, g)
	}
	detail := []string{s.Muted("capture " + c.CaptureId)}
	if c.CreatedBy != nil {
		detail = append(detail, s.Muted("by "+clientLabel(c.CreatedBy)))
	}
	return treeNode{head: head, detail: detail}
}

// channelNode is one station picked out of a capture.
func channelNode(s ui.Style, st *leylinev1.GetStateResponse, ch *leylinev1.Channel) treeNode {
	freq := "-"
	if _, ok := leyline.ChannelFrequency(st, ch); ok {
		freq = channelFreqLabel(st, ch)
	}
	head := []string{
		freq + " " + strings.ToUpper(leyline.ModeName(ch.Mode)),
		"bw " + formatBandwidth(ch.BandwidthHz),
		"squelch " + squelchString(ch.SquelchDb),
		inkState(s, stateWord(ch.State.String())),
	}
	// The absolute frequency is the answer; the offset it sits at inside the
	// capture is a diagnostic, so it goes on the muted line with the id.
	detail := []string{s.Muted("channel " + ch.ChannelId), s.Muted("offset " + formatOffset(ch.OffsetHz))}
	if ch.Persistent {
		detail = append(detail, s.Muted("persistent"))
	}
	if ch.Owner != nil {
		detail = append(detail, s.Muted("by "+clientLabel(ch.Owner)))
	}
	return treeNode{head: head, detail: detail}
}

// sinkNode is where a channel's audio goes.
func sinkNode(s ui.Style, sk *leylinev1.Sink) treeNode {
	kind, detail := sinkStrings(sk)
	head := []string{kind}
	if detail != "" {
		head = append(head, detail)
	}
	return treeNode{head: head, detail: []string{s.Muted("sink " + sk.SinkId)}}
}

// writeNodes writes a list of siblings under prefix, each with the branch
// glyph its position calls for.
func writeNodes(b *strings.Builder, s ui.Style, nodes []treeNode, prefix string) {
	g := s.Glyphs()
	for i, n := range nodes {
		branch, cont := g.TreeBranch+" ", g.TreeTrunk+"  "
		if i == len(nodes)-1 {
			branch, cont = g.TreeLast+" ", strings.Repeat(" ", ui.Visible(g.TreeLast)+1)
		}
		writeNode(b, s, n, prefix, branch, cont)
	}
}

// writeNode writes one node and everything under it. The headline sits on the
// branch line; the detail line and the node's children line up under the
// headline's first character, so the indentation alone carries the hierarchy.
func writeNode(b *strings.Builder, s ui.Style, n treeNode, prefix, branch, cont string) {
	head := prefix + mutedGlyphs(s, branch)
	body := prefix + mutedGlyphs(s, cont)
	writeSegments(b, head, body, n.head, s.Width)
	if len(n.detail) > 0 {
		writeSegments(b, body, body, n.detail, s.Width)
	}
	writeNodes(b, s, n.kids, body)
}

// mutedGlyphs dims the tree drawing, and leaves pure indentation alone so a
// line never carries ink it does not need.
func mutedGlyphs(s ui.Style, prefix string) string {
	if strings.TrimSpace(prefix) == "" {
		return prefix
	}
	return s.Muted(prefix)
}

// writeSegments packs segments onto lines two spaces apart, wrapping at width
// (0 means unknown, so no wrapping) and indenting the wrap under cont. A
// segment wider than the room left goes on a line of its own rather than
// being cut: ids are copy-pasteable, so they are never truncated.
func writeSegments(b *strings.Builder, first, cont string, segs []string, width int) {
	used, started := 0, false
	for _, seg := range segs {
		if seg == "" {
			continue
		}
		w := ui.Visible(seg)
		switch {
		case !started:
			b.WriteString(first + seg)
			used, started = ui.Visible(first)+w, true
		case width > 0 && used+2+w > width:
			b.WriteString("\n" + cont + seg)
			used = ui.Visible(cont) + w
		default:
			b.WriteString("  " + seg)
			used += 2 + w
		}
	}
	if started {
		b.WriteString("\n")
	}
}

// deviceStateWords is the device's state as a phrase: "in use (other program)"
// when another program holds the dongle, so the row is not mistaken for one of
// our own captures.
func deviceStateWords(d *leylinev1.DeviceDescriptor) string {
	s := stateWord(d.State.String())
	if heldExternally(d) {
		s += " (other program)"
	}
	return s
}

// captureGains renders the gains a capture is running with ("gain tuner auto",
// "gain tuner 20.0 dB"); empty when the daemon reports none.
func captureGains(gs []*leylinev1.GainState) string {
	if len(gs) == 0 {
		return ""
	}
	parts := make([]string, 0, len(gs))
	for _, g := range gs {
		if g.Auto {
			parts = append(parts, strings.ToLower(g.Element)+" auto")
			continue
		}
		parts = append(parts, fmt.Sprintf("%s %.1f dB", strings.ToLower(g.Element), g.Db))
	}
	return "gain " + strings.Join(parts, ", ")
}

// sinkStrings splits a sink into its kind and the one fact that identifies it.
func sinkStrings(s *leylinev1.Sink) (kind, detail string) {
	kind = "?"
	switch k := s.Kind.(type) {
	case *leylinev1.Sink_SystemAudio:
		// An absent volume means full, not silent (SystemAudioSink.volume).
		vol := 1.0
		if k.SystemAudio.Volume != nil {
			vol = k.SystemAudio.GetVolume()
		}
		kind, detail = "system_audio", fmt.Sprintf("volume %.2f %s", vol, k.SystemAudio.AudioDeviceUid)
	case *leylinev1.Sink_Stream:
		kind, detail = "stream", k.Stream.StreamId
	case *leylinev1.Sink_File:
		kind, detail = "file", fmt.Sprintf("%s %s", k.File.Kind, k.File.ResourceUri)
	}
	return kind, strings.TrimSpace(detail)
}

// printStateTables is the --wide fallback: the flat, one-row-per-object tables
// with every id, owner and column, for a state too large to read as a tree.
func printStateTables(app *App, st *leylinev1.GetStateResponse) {
	fmt.Fprintln(app.Stdout, "Devices")
	// Wide: the Captures table below joins to a device by its id, so this
	// screen keeps the id column `ley devices` moves behind --wide.
	printDeviceTable(app, st.Devices, true)
	fmt.Fprintln(app.Stdout, "\nCaptures")
	w := app.table()
	fmt.Fprintln(w, "ID\tDEVICE\tCENTER\tRATE\tSTATE\tGAINS\tAUDIO SINKS\tCREATED BY")
	for _, c := range st.Captures {
		gains := "-"
		if len(c.Gains) > 0 {
			gains = ""
			for i, g := range c.Gains {
				if i > 0 {
					gains += ","
				}
				if g.Auto {
					gains += g.Element + "=auto"
				} else {
					gains += fmt.Sprintf("%s=%gdB", g.Element, g.Db)
				}
			}
		}
		sinks := uint32(0)
		if c.Activity != nil {
			sinks = c.Activity.LiveAudioSinks
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n", c.CaptureId, c.DeviceId, leyline.FormatFrequency(c.CenterHz),
			ratesString([]uint64{c.SampleRate}), enumName(c.State.String()), gains, sinks, clientString(c.CreatedBy))
	}
	w.Flush()
	fmt.Fprintln(app.Stdout, "\nChannels")
	w = app.table()
	fmt.Fprintln(w, "ID\tCAPTURE\tFREQ\tOFFSET\tMODE\tBW\tSQUELCH\tSTATE\tPERSISTENT\tOWNER")
	for _, ch := range st.Channels {
		freq := "-"
		if _, ok := leyline.ChannelFrequency(st, ch); ok {
			freq = channelFreqLabel(st, ch)
		}
		fmt.Fprintf(w, "%s\t%s\t%s\t%+d\t%s\t%d\t%s\t%s\t%v\t%s\n", ch.ChannelId, ch.CaptureId, freq, ch.OffsetHz,
			leyline.ModeName(ch.Mode), ch.BandwidthHz, squelchString(ch.SquelchDb), enumName(ch.State.String()), ch.Persistent, clientString(ch.Owner))
	}
	w.Flush()
	fmt.Fprintln(app.Stdout, "\nSinks")
	w = app.table()
	fmt.Fprintln(w, "ID\tCHANNEL\tKIND\tDETAIL")
	for _, s := range st.Sinks {
		kind, detail := sinkStrings(s)
		fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", s.SinkId, s.ChannelId, kind, detail)
	}
	w.Flush()
	if len(st.GetPlaybacks()) > 0 {
		fmt.Fprintln(app.Stdout, "\nPlaybacks")
		w = app.table()
		fmt.Fprintln(w, "ID\tRESOURCE\tPOSITION\tCREATED BY")
		for _, p := range st.GetPlaybacks() {
			fmt.Fprintf(w, "%s\t%s\t%s\t%s\n", p.GetPlaybackId(), p.GetResourceUri(),
				playbackPosition(p), clientString(p.GetCreatedBy()))
		}
		w.Flush()
	}
}
