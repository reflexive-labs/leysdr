// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// fileSidecar is the subset of the .json sidecar that play consults
// (docs/reference/iq-files.md): centre frequency and the first expected channel.
type fileSidecar struct {
	CenterHz uint64 `json:"center_hz"`
	Expect   []struct {
		Mode        string `json:"mode"`
		OffsetHz    int64  `json:"offset_hz"`
		BandwidthHz uint32 `json:"bandwidth_hz"`
	} `json:"expect"`
	// A recording's part carries its mode here rather than in an expect entry:
	// it is a recording of something, not a fixture asserting anything
	// (docs/design/recording.md, "The part sidecar").
	Metadata map[string]string `json:"metadata"`
}

// mode is the demod mode the sidecar suggests, and why. A fixture says it in
// its first expect entry; a recording's part says it in its metadata.
func (sc *fileSidecar) mode() (string, string) {
	if len(sc.Expect) > 0 && sc.Expect[0].Mode != "" {
		return sc.Expect[0].Mode, "the recording's sidecar says "
	}
	if m := sc.Metadata["mode"]; m != "" {
		return m, "the recording was made in "
	}
	return "", ""
}

// readSidecar loads <base>.json or <path>.json; a missing sidecar is not an error.
func readSidecar(path string) (*fileSidecar, error) {
	base := strings.TrimSuffix(path, filepath.Ext(path))
	for _, p := range []string{base + ".json", path + ".json"} {
		b, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var sc fileSidecar
		if err := json.Unmarshal(b, &sc); err != nil {
			return nil, fmt.Errorf("cannot read the sidecar %s: %w", p, err)
		}
		return &sc, nil
	}
	return &fileSidecar{}, nil
}

func newPlayCommand(app *App) *cobra.Command {
	var (
		f        tuneFlags
		loop     bool
		freq     string
		playPart int
	)
	cmd := &cobra.Command{
		Use:   "play <file.cf32>",
		Short: "Listen to a recording as if it were a radio",
		Long: `play attaches an IQ recording (a .cf32 file: the raw samples a radio
produced, the kind the daemon writes and the fixtures directory contains) as
a pretend radio, then tunes on it exactly as 'tune' would, so every other
command works the same: ley set adjusts it, ley spectrum shows it.

The frequency defaults to the file's centre (from the .json sidecar beside
the file: center_hz plus the first 'expect' offset when present) and the
mode to the first 'expect' entry's mode; --mode and --freq override. The
pretend radio is removed on exit unless --persistent is given, in which
case the channel and the device outlive the command; 'ley stop' removes the
channel and 'ley devices detach <id>' the pretend radio. No hardware is
needed.`,
		Example: `  ley play fixtures/nfm_tone.cf32              # decode a fixture and listen
  ley play recording.cf32 --loop               # keep playing until Ctrl-C
  ley play recording.cf32 --freq 146.52 --mode nfm
  ley play recording.cf32 --persistent --json  # leave it running, print ids`,
		GroupID: GroupListening,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			arg := args[0]
			// A recording the daemon kept, named by its uri or by the job id `ley recordings`
			// prints. The daemon says where it is on this machine and the rest of play is
			// unchanged -- playing a part is playing a file.
			if namesARecording(arg) {
				resolved, rerr := resolveRecordingPlayPath(cmd.Context(), app, arg, playPart)
				if rerr != nil {
					return rerr
				}
				arg = resolved
			}
			path, err := filepath.Abs(arg)
			if err != nil {
				return err
			}
			if _, err := os.Stat(path); err != nil {
				if errors.Is(err, os.ErrNotExist) {
					// A wrong path is a usage error (exit 2). A bare word with no directory in
					// it may have been meant as a recording, so the hint also points to where
					// recordings are listed.
					hint := "check the path; ley play takes a .cf32 IQ recording (the fixtures/ directory has some)"
					if !strings.ContainsAny(args[0], "/.") {
						hint = "check the path. If you meant a recording, " + app.ErrStyle.Cmd("ley recordings") + " lists them by id"
					}
					return usageError(fileMissing(path, hint))
				}
				return err
			}
			sc, err := readSidecar(path)
			if err != nil {
				return err
			}
			// Precedence for play: explicit --mode > the sidecar's first expect
			// entry > the band table (inside parse). Bandwidth likewise.
			var def modeDefault
			if name, why := sc.mode(); name != "" {
				if m, err := leyline.ParseMode(name); err == nil {
					def = modeDefault{mode: m, reason: why + strings.ToUpper(leyline.ModeName(m))}
				}
			}
			if len(sc.Expect) > 0 && f.bw == "" && sc.Expect[0].BandwidthHz > 0 {
				f.bw = fmt.Sprintf("%d", sc.Expect[0].BandwidthHz)
			}
			// --freq is a usage error before anything reaches the daemon.
			var freqHz uint64
			if freq != "" {
				t, terr := resolveDial(freq, "146.52 (MHz)")
				if terr != nil {
					return usageErrorf("--freq %v", terr)
				}
				freqHz = t.Hz
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			// A live session's prose goes to stderr, not to stdout where a script
			// reads: the meter is already on stderr, and a banner on stdout split
			// one screen across two streams. Set here rather than in runTune,
			// because play prints its first line before runTune is reached. Ids
			// stay on stdout in printCreated.
			s.proseToStderr = true
			defer s.close()
			dev, err := s.client.Control.AttachFileDevice(cmd.Context(), &leylinev1.AttachFileDeviceRequest{Path: path, Loop: loop})
			if err != nil {
				return err
			}
			// keep is set only once a persistent tune succeeded: a failed tune
			// must not leave an orphan file device behind.
			keep := false
			defer func() {
				if keep {
					// The persistent channel rides on this device's capture; detaching would destroy both.
					return
				}
				ctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
				defer cancel()
				if _, err := s.client.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: dev.DeviceId}); err != nil && leyline.Code(err) != leyline.CodeDeviceNotFound {
					fmt.Fprintf(app.Stderr, "warning: could not detach file device %s: %v; detach it with: ley devices detach %s\n", dev.DeviceId, err, dev.DeviceId)
				}
			}()
			s.device = dev
			center := sc.CenterHz
			if center == 0 && len(dev.TuningRanges) > 0 {
				center = dev.TuningRanges[0].MinHz
			}
			hz := center
			if len(sc.Expect) > 0 {
				hz = uint64(int64(hz) + sc.Expect[0].OffsetHz)
			}
			if freq != "" {
				hz = freqHz
			}
			o, err := f.parse(freq, hz, def)
			if err != nil {
				return err
			}
			o.captureCenter = center
			if f.squelch == "" {
				// A recording is played as it is: squelch stays off unless asked for.
				o.squelchAuto = false
			}
			// What is being played belongs in the banner's second line, where
			// tune names the radio: one fact per line, and the line it replaces
			// would have read "Radio FilePlaybackDevice, no gain control".
			s.sourceLine = playedSource(path, dev)
			if err := runTune(cmd.Context(), s, o); err != nil {
				return err
			}
			if f.persistent {
				keep = true
				// The id is machine output and goes to stdout beside the
				// capture and channel printCreated already printed; the
				// sentence about it is prose and goes to stderr. Without
				// the first line a --persistent scrape would lose the device
				// entirely, since printCreated does not name it.
				fmt.Fprintf(app.Stdout, "device %s\n", dev.DeviceId)
				s.say("the file device stays attached; detach with: ley devices detach %s\n", dev.DeviceId)
			}
			return nil
		},
	}
	addTuneFlags(cmd, &f, false)
	cmd.Flags().BoolVar(&loop, "loop", false, "start over when the file ends, until Ctrl-C (default: stop at the end)")
	cmd.Flags().IntVar(&playPart, "part", 0, "which part of a ley://recordings/ recording to play, e.g. 2 (default: the first)")
	cmd.Flags().StringVar(&freq, "freq", "", "frequency to listen to within the recording; a bare number is MHz, e.g. 146.52 (default: the file's centre plus its first expect offset)")
	return cmd
}

// namesARecording reports whether the positional is a recording rather than a
// path: the uri `ley record` prints, or the job id `ley recordings` lists.
func namesARecording(arg string) bool {
	if _, _, ok := leyline.ParseRecordingURI(arg); ok {
		return true
	}
	return strings.HasPrefix(arg, "job_")
}

// resolveRecordingPlayPath turns a ley://recordings/ uri into the part file on
// this machine. A recording can hold more than one part, so it says which one
// it picked and how to name another.
//
// An audio recording is a WAV, which is not a radio: it holds what the
// demodulator already produced, and there is no signal left in it for a
// channel to decode. play says so and names the tools that do play one, rather
// than attaching it as a pretend radio and demodulating audio into noise.
func resolveRecordingPlayPath(ctx context.Context, app *App, uri string, part int) (string, error) {
	jobID, inURI, ok := leyline.ParseRecordingURI(uri)
	if !ok {
		// A bare job id, as `ley recordings` prints it.
		jobID, inURI = uri, 0
	}
	if inURI != 0 && part != 0 && inURI != part {
		return "", usageErrorf("the uri names part %d and --part says %d; give one of them", inURI, part)
	}
	if part == 0 {
		part = inURI
	}
	c, err := app.dial(ctx)
	if err != nil {
		return "", app.notRunning(err)
	}
	defer c.Close()
	dir, err := c.ResolveLocalPath(ctx, leyline.RecordingURI(jobID))
	if err != nil {
		return "", recordingNotFound(app, jobID, err)
	}
	manifest, err := leyline.ReadRecordingManifest(dir)
	if err != nil {
		return "", fmt.Errorf("the recording's manifest could not be read (%s): %w", dir, err)
	}
	if len(manifest.Parts) == 0 {
		return "", &friendlyError{msg: fmt.Sprintf("%s has no parts yet; %s says how it is getting on",
			jobID, app.ErrStyle.Cmd("ley recordings show "+jobID))}
	}
	chose := part == 0
	if part == 0 {
		part = manifest.Parts[0].Part
	}
	var chosen *leyline.RecordingPart
	for i := range manifest.Parts {
		if manifest.Parts[i].Part == part {
			chosen = &manifest.Parts[i]
		}
	}
	if chosen == nil {
		return "", usageErrorf("%s has no part %d; it has %s (ley recordings show %s lists them)",
			jobID, part, plural(len(manifest.Parts), "part"), jobID)
	}
	path := filepath.Join(dir, chosen.File)
	if manifest.Kind != "iq" {
		return "", playAudioPart(ctx, app, jobID, path, manifest, part)
	}
	// Printed only once the part is one play will actually tune: a recording that turns out to be
	// audio should not first announce which of its parts it picked.
	if chose && len(manifest.Parts) > 1 {
		fmt.Fprintln(app.Stderr, app.ErrStyle.Muted(fmt.Sprintf(
			"playing part %d of %d; --part 2 plays the next", part, len(manifest.Parts))))
	}
	return path, nil
}

// playAudioPart plays an audio recording. The file holds demodulator output, so there is no
// signal left in it for a channel to tune, and attaching it as a file device would put a fake
// capture and mode into `ley state`. Instead the file goes to the daemon's audio output, or to
// this machine's player.
//
// It always returns an error, because the caller's next step is to tune a file device and there
// is none here. `errDone` means playback worked.
func playAudioPart(ctx context.Context, app *App, jobID, path string, manifest *leyline.RecordingManifest, part int) error {
	where := jobID
	if len(manifest.Parts) > 1 {
		where = fmt.Sprintf("%s, part %d of %d", jobID, part, len(manifest.Parts))
	}
	// A script wants the path, not a sound: --json answers with the shape `ley recordings path`
	// uses and starts nothing.
	if app.JSON {
		if err := app.printJSON(&leylinev1.LocalPath{Path: path}); err != nil {
			return err
		}
		return errDone
	}
	// The daemon owns the speakers, as it does for a channel's audio, so the sound comes out on
	// the radio's host and this terminal shows progress and can stop it.
	err := playThroughDaemon(ctx, app, jobID, where, part)
	if err == nil || !errors.Is(err, errNoDaemonAudio) {
		return err
	}
	// A daemon with no audio device (a headless Linux one, which is usually the one on this
	// machine) leaves the file to the machine's own player.
	return playThroughLocalPlayer(app, where, path)
}

// errNoDaemonAudio means the daemon has no audio device. It is the only refusal that falls back
// to a local player rather than being reported.
var errNoDaemonAudio = errors.New("the daemon has no audio device")

// playThroughDaemon starts a daemon-side playback and holds the terminal until it finishes or
// Ctrl-C stops it, the way every other listening verb does.
func playThroughDaemon(ctx context.Context, app *App, jobID, where string, part int) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	pb, err := c.StartPlayback(ctx, leyline.RecordingPartURI(jobID, part), -1)
	if err != nil {
		if leyline.Code(err) == leyline.CodePlatformUnsupported {
			return errNoDaemonAudio
		}
		return err
	}
	st := app.ErrStyle
	fmt.Fprintln(app.Stderr, leadLabel(st, "Playing", where+" through the daemon's audio"))
	fmt.Fprintln(app.Stderr, st.Muted(playbackLength(pb)+". Ctrl-C stops."))
	defer func() {
		cctx, cancel := context.WithTimeout(context.Background(), confirmTimeout)
		defer cancel()
		_ = c.StopPlayback(cctx, pb.GetPlaybackId())
	}()
	followPlayback(ctx, app, c, pb)
	return errDone
}

// playbackLength renders the playback's duration, from the frames the daemon counted.
func playbackLength(pb *leylinev1.Playback) string {
	if pb.GetSampleRate() == 0 || pb.GetSamples() == 0 {
		return "playing"
	}
	secs := float64(pb.GetSamples()) / float64(pb.GetSampleRate())
	return forPhrase(time.Duration(secs * float64(time.Second)))
}

// followPlayback draws the position until the playback leaves the daemon's state or Ctrl-C
// stops it. The position is the daemon's own count of frames it has pushed, not a clock here.
func followPlayback(ctx context.Context, app *App, c *leyline.Client, pb *leylinev1.Playback) {
	progress := newScanProgress(app)
	defer progress.clear()
	total := float64(pb.GetSamples()) / float64(max(pb.GetSampleRate(), 1))
	tick := time.NewTicker(250 * time.Millisecond)
	defer tick.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-tick.C:
			st, err := c.State(ctx)
			if err != nil {
				return
			}
			var live *leylinev1.Playback
			for _, p := range st.GetPlaybacks() {
				if p.GetPlaybackId() == pb.GetPlaybackId() {
					live = p
				}
			}
			if live == nil {
				// Gone from the daemon's state: it reached the end of the file.
				return
			}
			at := float64(live.GetPosition()) / float64(max(live.GetSampleRate(), 1))
			progress.show(fmt.Sprintf("%s / %s", clockPhrase(at), clockPhrase(total)))
		}
	}
}

// clockPhrase renders a position as m:ss, the way a player does.
func clockPhrase(seconds float64) string {
	total := int(seconds)
	return fmt.Sprintf("%d:%02d", total/60, total%60)
}

// playThroughLocalPlayer is the fallback when the daemon has no audio device: hand the file to
// this machine's own player. It returns as soon as the player is launched, because `open` does.
func playThroughLocalPlayer(app *App, where, path string) error {
	st := app.ErrStyle
	// The path is the daemon's. On the same machine that is this machine; pointed at a daemon
	// somewhere else the file is not here, so report that rather than launch a player that fails.
	if _, err := os.Stat(path); err != nil {
		return &friendlyError{msg: fmt.Sprintf(
			"%s is an audio recording, the daemon has no audio device, and the file is on the daemon's machine rather than this one: %s",
			where, path)}
	}
	player := playerCommand(app)
	if err := exec.Command(player, path).Start(); err != nil {
		return &friendlyError{msg: fmt.Sprintf("%s is an audio recording, the daemon has no audio device, and %s could not open it (%v). Play it with your own player: %s",
			where, player, err, st.Cmd(player+" "+path))}
	}
	fmt.Fprintln(app.Stderr, leadLabel(st, "Playing", where+" through "+player))
	fmt.Fprintln(app.Stderr, st.Muted("the daemon has no audio device, so this machine's player has it: "+path))
	return errDone
}

// errDone ends a verb that has already done its work and has nothing left to run. It is not a
// failure and prints nothing: `Execute` maps it to exit 0.
var errDone = errors.New("done")

// playerCommand is what hands a file to the machine's own player: `$LEYLINE_PLAYER` when the
// reader has a preference (`afplay`, `mpv`, `vlc`), else the platform's own opener.
func playerCommand(app *App) string {
	if v, ok := app.LookupEnv("LEYLINE_PLAYER"); ok && strings.TrimSpace(v) != "" {
		return strings.TrimSpace(v)
	}
	return openCommand()
}

// openCommand is the platform's own opener. `open` on macOS, where the daemon runs; `xdg-open` is
// the Linux equivalent, for the container the Go clients are developed in.
func openCommand() string {
	if runtime.GOOS == "darwin" {
		return "open"
	}
	return "xdg-open"
}

// playedSource describes a recording for the banner, from the daemon's own
// descriptor rather than from the file we handed it -- the daemon is what
// actually opened it, and its numbers are the ones in force.
func playedSource(path string, dev *leylinev1.DeviceDescriptor) string {
	out := filepath.Base(path)
	if d := dev.GetFeatures()["duration_s"].GetNumber(); d > 0 {
		out += fmt.Sprintf(", %s", fmtDuration(d))
	}
	// A descriptor with no rates is not something the banner should crash on.
	// The unit is MSPS, not MHz: this is how fast the file is read, not where
	// on the dial it sits, and the line already carries a frequency above it.
	if rates := dev.GetSampleRates(); len(rates) > 0 {
		out += fmt.Sprintf(" at %.3g MSPS", float64(rates[0])/1e6)
	}
	if dev.GetFeatures()["loop"].GetFlag() {
		out += ", looping"
	}
	return out
}
