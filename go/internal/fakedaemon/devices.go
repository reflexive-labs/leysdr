package fakedaemon

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// RTLSDRRates is the RTL-SDR sample-rate list the fake device advertises.
var RTLSDRRates = []uint64{250_000, 1_024_000, 1_536_000, 1_792_000, 1_920_000, 2_048_000, 2_160_000, 2_400_000, 2_560_000, 2_880_000, 3_200_000}

// RTLSDRDefaultRate is the rate used when CreateCapture asks for 0.
const RTLSDRDefaultRate uint64 = 2_400_000

// R820TGains is the R820T tuner gain table (dB).
var R820TGains = []float64{0, 0.9, 1.4, 2.7, 3.7, 7.7, 8.7, 12.5, 14.4, 15.7, 16.6, 19.7, 20.7, 22.9, 25.4, 28.0, 29.7, 32.8, 33.8, 36.4, 37.2, 38.6, 40.2, 42.1, 43.4, 43.9, 44.5, 48.0, 49.6}

// fakeRTLSDR builds the descriptor of the built-in RTL-SDR (R820T) device.
func fakeRTLSDR() *leylinev1.DeviceDescriptor {
	return &leylinev1.DeviceDescriptor{
		DeviceId:     newID("dev_"),
		Driver:       "rtlsdr",
		Model:        "Generic RTL2832U (R820T)",
		Serial:       "00000001",
		UsbLocation:  "fake-usb-0",
		State:        leylinev1.DeviceState_AVAILABLE,
		TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}},
		SampleRates:  RTLSDRRates,
		NativeFormat: leylinev1.SampleFormat_CS8,
		GainElements: []*leylinev1.GainElement{{
			Name: "TUNER", MinDb: 0, MaxDb: 49.6, StepDb: 0, SupportsAuto: true, ValidDb: R820TGains,
		}},
		Features: map[string]*leylinev1.FeatureValue{
			"bias_tee":        {Value: &leylinev1.FeatureValue_Flag{Flag: true}},
			"direct_sampling": {Value: &leylinev1.FeatureValue_Flag{Flag: true}},
			"tx_capable":      {Value: &leylinev1.FeatureValue_Flag{Flag: false}},
		},
	}
}

// HeldRTLSDR builds the descriptor of an RTL-SDR another program holds, the
// way the real daemon reports one it never managed to open: IN_USE with the
// held_externally flag and a TUNER gain element whose table could not be read
// (empty valid_db, 0..0 dB).
func HeldRTLSDR() *leylinev1.DeviceDescriptor {
	return &leylinev1.DeviceDescriptor{
		DeviceId:     newID("dev_"),
		Driver:       "rtlsdr",
		Model:        "NESDR SMArt v5",
		Serial:       "00000002",
		UsbLocation:  "fake-usb-1",
		State:        leylinev1.DeviceState_IN_USE,
		TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}},
		SampleRates:  RTLSDRRates,
		NativeFormat: leylinev1.SampleFormat_CS8,
		GainElements: []*leylinev1.GainElement{{Name: "TUNER", SupportsAuto: true}},
		Features: map[string]*leylinev1.FeatureValue{
			"held_externally": {Value: &leylinev1.FeatureValue_Flag{Flag: true}},
		},
	}
}

// sidecar is the <name>.json sidecar of a .cf32|.cu8 recording (docs/fixtures.md).
type sidecar struct {
	SampleRate uint64 `json:"sample_rate"`
	CenterHz   uint64 `json:"center_hz"`
	Format     string `json:"format"`
}

// Sidecar sample rates the daemon accepts (IQSidecar.validSampleRates).
const (
	minFileRate uint64 = 1_000
	maxFileRate uint64 = 100_000_000
	// maxSidecarBytes bounds the sidecar the loader reads (IQSidecar.maxSidecarBytes).
	maxSidecarBytes int64 = 1 << 20
)

// fileInfo is what the fake keeps about an attached playback file: how many
// samples it holds (the EOF position) and whether playback wraps.
type fileInfo struct {
	samples uint64
	loop    bool
}

// iqStem strips a trailing .cf32, .cu8 or .json (IQFilePaths.stem).
func iqStem(path string) string {
	for _, ext := range []string{".cf32", ".cu8", ".json"} {
		if strings.HasSuffix(path, ext) {
			return strings.TrimSuffix(path, ext)
		}
	}
	return path
}

// regularFileSize stats path the way IQFilePaths.requireRegularFile does:
// DEVICE_IO when it cannot be stat'ed, INVALID_ARGUMENT when it is not a
// regular file.
func regularFileSize(path, what string) (int64, *leyline.Error) {
	st, err := os.Stat(path)
	if err != nil {
		return 0, errorf(leyline.CodeDeviceIO, path, fmt.Sprintf("cannot stat %s: %v", what, err))
	}
	if !st.Mode().IsRegular() {
		return 0, errorf(leyline.CodeInvalidArgument, path, what+" is not a regular file")
	}
	return st.Size(), nil
}

// openFileDevice validates the <name>.cf32|.cu8 + <name>.json pair the way the
// daemon's FilePlaybackDevice does (path may name either member) and builds
// the playback descriptor. Errors carry the daemon's codes: INVALID_ARGUMENT
// for a non-regular file, a malformed or oversized sidecar, an out-of-range
// sample_rate or an unknown format; DEVICE_IO when a member cannot be read.
func openFileDevice(path string, loop bool) (*leylinev1.DeviceDescriptor, fileInfo, *leyline.Error) {
	if st, err := os.Stat(path); err == nil && !st.Mode().IsRegular() {
		return nil, fileInfo{}, errorf(leyline.CodeInvalidArgument, path, "IQ file is not a regular file")
	}
	stem := iqStem(path)
	samples := path
	if !strings.HasSuffix(path, ".cf32") && !strings.HasSuffix(path, ".cu8") {
		samples = stem + ".cf32"
		if _, err := os.Stat(samples); err != nil {
			if _, err := os.Stat(stem + ".cu8"); err == nil {
				samples = stem + ".cu8"
			}
		}
	}
	sidecarPath := stem + ".json"
	size, e := regularFileSize(sidecarPath, "sidecar")
	if e != nil {
		return nil, fileInfo{}, e
	}
	if size > maxSidecarBytes {
		return nil, fileInfo{}, errorf(leyline.CodeInvalidArgument, sidecarPath, fmt.Sprintf("sidecar is %d bytes; limit is %d", size, maxSidecarBytes))
	}
	b, err := os.ReadFile(sidecarPath)
	if err != nil {
		return nil, fileInfo{}, errorf(leyline.CodeDeviceIO, sidecarPath, fmt.Sprintf("cannot read sidecar: %v", err))
	}
	var sc sidecar
	if err := json.Unmarshal(b, &sc); err != nil {
		return nil, fileInfo{}, errorf(leyline.CodeInvalidArgument, sidecarPath, fmt.Sprintf("malformed sidecar: %v", err))
	}
	if sc.SampleRate < minFileRate || sc.SampleRate > maxFileRate {
		return nil, fileInfo{}, errorf(leyline.CodeInvalidArgument, sidecarPath, fmt.Sprintf("sample_rate %d is outside %d...%d", sc.SampleRate, minFileRate, maxFileRate))
	}
	var bytesPerSample uint64
	switch {
	case strings.HasSuffix(samples, ".cf32"), strings.HasSuffix(samples, ".cu8"):
		bytesPerSample = 8
		if strings.HasSuffix(samples, ".cu8") {
			bytesPerSample = 2
		}
	default:
		return nil, fileInfo{}, errorf(leyline.CodeInvalidArgument, path, fmt.Sprintf("unsupported IQ format %q", sc.Format))
	}
	bytes, e := regularFileSize(samples, "IQ file")
	if e != nil {
		return nil, fileInfo{}, e
	}
	info := fileInfo{samples: uint64(bytes) / bytesPerSample, loop: loop}
	center := sc.CenterHz
	if center == 0 {
		center = 100_000_000
	}
	dev := &leylinev1.DeviceDescriptor{
		DeviceId:     newID("dev_"),
		Driver:       "file",
		Model:        "FilePlaybackDevice",
		Serial:       filepath.Base(samples),
		State:        leylinev1.DeviceState_AVAILABLE,
		TuningRanges: []*leylinev1.FrequencyRange{{MinHz: center, MaxHz: center}},
		SampleRates:  []uint64{sc.SampleRate},
		NativeFormat: leylinev1.SampleFormat_CF32,
		Features: map[string]*leylinev1.FeatureValue{
			"path":       {Value: &leylinev1.FeatureValue_Text{Text: path}},
			"loop":       {Value: &leylinev1.FeatureValue_Flag{Flag: loop}},
			"duration_s": {Value: &leylinev1.FeatureValue_Number{Number: float64(info.samples) / float64(sc.SampleRate)}},
		},
	}
	return dev, info, nil
}

func inRange(dev *leylinev1.DeviceDescriptor, hz uint64) bool {
	for _, r := range dev.TuningRanges {
		if hz >= r.MinHz && hz <= r.MaxHz {
			return true
		}
	}
	return false
}

func rateOK(dev *leylinev1.DeviceDescriptor, rate uint64) bool {
	for _, r := range dev.SampleRates {
		if r == rate {
			return true
		}
	}
	return false
}

// snapGain snaps db to the nearest valid_db entry (or clamps to min/max).
func snapGain(el *leylinev1.GainElement, db float64) float64 {
	if len(el.ValidDb) == 0 {
		if db < el.MinDb {
			return el.MinDb
		}
		if db > el.MaxDb {
			return el.MaxDb
		}
		return db
	}
	best := el.ValidDb[0]
	for _, v := range el.ValidDb {
		if abs(v-db) < abs(best-db) {
			best = v
		}
	}
	return best
}

func abs(x float64) float64 {
	if x < 0 {
		return -x
	}
	return x
}
