// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// dcsWindow is how long the daemon has to name the code once the channel exists. The decoder locks
// on three consecutive words, 0.51 s of the bit stream, so 3 s
// covers the detector's hop, the lock and a heartbeat.
const dcsWindow = 3 * time.Second

// TestDCSAgainstRealDaemon plays the nfm_dcs fixture (DCS 023 normal under a voice tone) and waits
// for the daemon's sub-audible telemetry to name the code. The fixture comes from go/pkg/dcs, the
// same encoder the Go side reads the handheld's words with, so this is the check that the engine's
// decoder and the Go encoder agree on the frame.
func TestDCSAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	fixture, err := filepath.Abs("../../../fixtures/nfm_dcs.cf32")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixture); err != nil {
		t.Skipf("fixture missing (%v); run `go run ./cmd/leyfix generate --out ../../../fixtures`", err)
	}
	stopPlay, _ := e.startLive("play", fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	st := e.waitChannels(1)
	chanID := list(st, "channels")[0].(map[string]any)["channelId"].(string)

	ctx, cancel := context.WithTimeout(t.Context(), dcsWindow)
	defer cancel()
	c, err := leyline.Dial(ctx, e.socket, leyline.WithLabel("e2e"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	msgs, _, err := c.WatchTelemetry(ctx, &leylinev1.TelemetrySubscription{
		Scope: &leylinev1.TelemetrySubscription_ChannelId{ChannelId: chanID},
		Types: []leylinev1.TelemetryType{leylinev1.TelemetryType_SUB_AUDIBLE},
	})
	if err != nil {
		t.Fatal(err)
	}
	var last *leylinev1.SubAudible
	for m := range msgs {
		sa := m.GetSubAudible()
		if sa == nil {
			continue
		}
		last = sa
		if sa.GetKind() != leylinev1.SubAudibleKind_SUB_AUDIBLE_DCS {
			continue
		}
		if sa.GetDcsCode() != 23 || sa.GetDcsInverted() {
			t.Fatalf("the daemon named DCS %03d inverted=%v, want 023 normal: %v", sa.GetDcsCode(), sa.GetDcsInverted(), sa)
		}
		return
	}
	t.Fatalf("no SUB_AUDIBLE_DCS within %s (last report %v)", dcsWindow, last)
}
