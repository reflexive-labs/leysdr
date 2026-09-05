package cli

import (
	"context"
	"encoding/json"
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
	SampleRate uint64 `json:"sample_rate"`
	CenterHz   uint64 `json:"center_hz"`
	Expect     []struct {
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
		Short: "Play an IQ recording through the full pipeline",
		Long: `play attaches the file as a playback device, then tunes on it exactly as
'tune' would. The frequency defaults to the file's centre (sidecar center_hz plus
the first 'expect' offset when present); the mode defaults to the first 'expect'
entry's mode. The device is detached on exit unless --persistent is given, in which
case the channel and the file device outlive the command (detach with "ley devices detach <id>").`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			path, err := filepath.Abs(args[0])
			if err != nil {
				return err
			}
			if _, err := os.Stat(path); err != nil {
				return err
			}
			sc, err := readSidecar(path)
			if err != nil {
				return err
			}
			defMode := leylinev1.DemodMode_NFM
			if len(sc.Expect) > 0 {
				if m, err := leyline.ParseMode(sc.Expect[0].Mode); err == nil {
					defMode = m
				}
				if f.bw == 0 && sc.Expect[0].BandwidthHz > 0 {
					f.bw = sc.Expect[0].BandwidthHz
				}
			}
			s, err := openSession(cmd.Context(), app)
			if err != nil {
				return err
			}
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
				_, _ = s.client.Control.DetachFileDevice(ctx, &leylinev1.DetachFileDeviceRequest{DeviceId: dev.DeviceId})
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
				if hz, err = leyline.ParseFrequency(freq); err != nil {
					return err
				}
			}
			o, err := f.parse(hz, defMode)
			if err != nil {
				return err
			}
			o.captureCenter = center
			if !app.JSON {
				fmt.Fprintf(app.Stdout, "playing %s as device %s\n", filepath.Base(path), dev.DeviceId)
			}
			if err := runTune(cmd.Context(), s, o); err != nil {
				return err
			}
			if f.persistent {
				keep = true
				if !app.JSON {
					fmt.Fprintf(app.Stdout, "file device %s stays attached; detach with: ley devices detach %s\n", dev.DeviceId, dev.DeviceId)
				}
			}
			return nil
		},
	}
	addTuneFlags(cmd, &f, false)
	cmd.Flags().BoolVar(&loop, "loop", false, "loop the file")
	cmd.Flags().StringVar(&freq, "freq", "", "frequency to tune (default: file centre + first expect offset)")
	return cmd
}
