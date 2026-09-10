package cli

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// fileSidecar is the subset of the .json sidecar that play consults
// (docs/fixtures.md): centre frequency and the first expected channel.
type fileSidecar struct {
	CenterHz uint64 `json:"center_hz"`
	Expect   []struct {
		Mode        string `json:"mode"`
		OffsetHz    int64  `json:"offset_hz"`
		BandwidthHz uint32 `json:"bandwidth_hz"`
	} `json:"expect"`
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
			return nil, fmt.Errorf("%s: %w", p, err)
		}
		return &sc, nil
	}
	return &fileSidecar{}, nil
}

func newPlayCommand(app *App) *cobra.Command {
	var (
		f    tuneFlags
		loop bool
		freq string
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
			path, err := filepath.Abs(args[0])
			if err != nil {
				return err
			}
			if _, err := os.Stat(path); err != nil {
				if errors.Is(err, os.ErrNotExist) {
					// A wrong path is the user's mistake (exit 2), said in plain words.
					return usageError(fileMissing(path, "check the path; ley play takes a .cf32 IQ recording (the fixtures/ directory has some)"))
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
			if len(sc.Expect) > 0 {
				if m, err := leyline.ParseMode(sc.Expect[0].Mode); err == nil {
					def = modeDefault{mode: m, reason: "the recording's sidecar says " + strings.ToUpper(leyline.ModeName(m))}
				}
				if f.bw == "" && sc.Expect[0].BandwidthHz > 0 {
					f.bw = fmt.Sprintf("%d", sc.Expect[0].BandwidthHz)
				}
			}
			// --freq is a usage error before anything reaches the daemon.
			var freqHz uint64
			if freq != "" {
				t, terr := resolveDial(freq, "146.52 (MHz)")
				if terr != nil {
					return usageErrorf("--freq: %v", terr)
				}
				freqHz = t.Hz
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
			// A live session's prose belongs to the person, not to a script
			// reading stdout: the meter is already on stderr, and leaving the
			// banner on stdout split one screen across two streams. Set here
			// rather than in runTune, because play says its first line before
			// runTune is reached. Ids stay on stdout in printCreated.
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
			o, err := f.parse(app, freq, hz, def)
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
				// sentence about it is prose and goes to the person. Without
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
	cmd.Flags().StringVar(&freq, "freq", "", "frequency to listen to within the recording; a bare number is MHz, e.g. 146.52 (default: the file's centre plus its first expect offset)")
	return cmd
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
