package fakedaemon

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
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

// sidecar is the <name>.json sidecar of a .cf32 recording.
type sidecar struct {
	SampleRate uint64 `json:"sample_rate"`
	CenterHz   uint64 `json:"center_hz"`
	Format     string `json:"format"`
}

// fileDevice builds a descriptor for a playback device from path (+ optional
// sidecar). Missing sidecar values fall back to 2.4 MSPS at 100 MHz.
func fileDevice(path string, loop bool) *leylinev1.DeviceDescriptor {
	sc := sidecar{SampleRate: RTLSDRDefaultRate, CenterHz: 100_000_000}
	base := strings.TrimSuffix(path, filepath.Ext(path))
	for _, p := range []string{base + ".json", path + ".json"} {
		if b, err := os.ReadFile(p); err == nil {
			var got sidecar
			if json.Unmarshal(b, &got) == nil {
				if got.SampleRate > 0 {
					sc.SampleRate = got.SampleRate
				}
				if got.CenterHz > 0 {
					sc.CenterHz = got.CenterHz
				}
			}
			break
		}
	}
	return &leylinev1.DeviceDescriptor{
		DeviceId:     newID("dev_"),
		Driver:       "file",
		Model:        "FilePlaybackDevice",
		Serial:       filepath.Base(path),
		State:        leylinev1.DeviceState_AVAILABLE,
		TuningRanges: []*leylinev1.FrequencyRange{{MinHz: sc.CenterHz, MaxHz: sc.CenterHz}},
		SampleRates:  []uint64{sc.SampleRate},
		NativeFormat: leylinev1.SampleFormat_CF32,
		Features: map[string]*leylinev1.FeatureValue{
			"path": {Value: &leylinev1.FeatureValue_Text{Text: path}},
			"loop": {Value: &leylinev1.FeatureValue_Flag{Flag: loop}},
		},
	}
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
