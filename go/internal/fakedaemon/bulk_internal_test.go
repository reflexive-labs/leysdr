package fakedaemon

import "testing"

// audioRate must follow the engine's channelizer plan (engine-internals.md):
// r2 = (fs / max(1, floor(fs/240k))) / max(1, round(r1/48k)).
func TestAudioRateFollowsChannelizerPlan(t *testing.T) {
	for _, tc := range []struct {
		fs   uint64
		want uint32
	}{
		{2_400_000, 48_000},  // D1=10, r1=240k, D2=5
		{250_000, 50_000},    // D1=1, r1=250k, D2=5
		{1_024_000, 51_200},  // D1=4, r1=256k, D2=5
		{2_048_000, 51_200},  // D1=8, r1=256k, D2=5
		{3_200_000, 49_231},  // D1=13, r1=246154, D2=5
		{10_000_000, 48_780}, // D1=41, r1=243902, D2=5
		{48_000, 48_000},     // D1=1, r1=48k, D2=1
		{0, 48_000},          // unknown capture rate: engine default at 2.4 MSPS
	} {
		if got := audioRate(tc.fs); got != tc.want {
			t.Errorf("audioRate(%d) = %d, want %d", tc.fs, got, tc.want)
		}
	}
}

func TestNearestLadderRoundsUp(t *testing.T) {
	for _, tc := range []struct{ req, want uint32 }{{0, 1024}, {1, 256}, {300, 512}, {1500, 2048}, {8193, 16384}, {16384, 16384}, {100000, 16384}} {
		if got := nearestLadder(tc.req); got != tc.want {
			t.Errorf("nearestLadder(%d) = %d, want %d", tc.req, got, tc.want)
		}
	}
}
