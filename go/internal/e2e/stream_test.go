// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"context"
	"testing"
	"time"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

// TestSustainedAudioStream streams a channel's audio for several seconds through the client
// library. Regression: with grpc-go's default dynamic windows the client sends an HTTP/2 PING per
// data frame for bandwidth estimation, and swift-nio-http2 caps inbound control frames at 200 per
// 30 s, so every busy stream died with GOAWAY ENHANCE_YOUR_CALM after ~1.3 s. The library dials
// with fixed 1 MiB windows, which disables those pings (docs/reference/cli.md, "Client requirements").
func TestSustainedAudioStream(t *testing.T) {
	e, _ := setup(t)
	stopPlay, _ := e.startLive("play", e.fixture, "--no-audio", "--loop", "--json")
	defer func() { _ = stopPlay() }()
	st := e.waitChannels(1)
	chanID := list(st, "channels")[0].(map[string]any)["channelId"].(string)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	c, err := leyline.Dial(ctx, e.socket, leyline.WithLabel("e2e"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	bulk := c.Bulk
	desc, err := bulk.Subscribe(ctx, &leylinev1.SubscribeRequest{
		Source: &leylinev1.SubscribeRequest_ChannelId{ChannelId: chanID},
		Kind:   leylinev1.StreamKind_AUDIO,
		Start:  &leylinev1.StreamPosition{Position: &leylinev1.StreamPosition_Live{Live: true}},
		Params: &leylinev1.SubscribeRequest_Audio{Audio: &leylinev1.AudioParams{SampleRate: 48000, Format: leylinev1.AudioSampleFormat_S16}},
	})
	if err != nil {
		t.Fatal(err)
	}
	rate := desc.GetAudio().GetSampleRate()
	stream, err := bulk.Stream(ctx, &leylinev1.StreamRef{StreamId: desc.StreamId})
	if err != nil {
		t.Fatal(err)
	}
	const want = 4.0 // seconds of audio
	var samples uint64
	frames := 0
	start := time.Now()
	for float64(samples)/float64(rate) < want {
		f, err := stream.Recv()
		if err != nil {
			t.Fatalf("audio stream ended after %d frames / %.2f s of audio (%.2f s wall): %v", frames, float64(samples)/float64(rate), time.Since(start).Seconds(), err)
		}
		frames++
		samples += uint64(len(f.Payload) / 2)
		if time.Since(start) > 12*time.Second {
			t.Fatalf("only %.2f s of audio after 12 s wall", float64(samples)/float64(rate))
		}
	}
	t.Logf("%d frames, %.2f s of audio in %.2f s wall at %d Hz", frames, float64(samples)/float64(rate), time.Since(start).Seconds(), rate)
	if _, err := bulk.Unsubscribe(ctx, &leylinev1.StreamRef{StreamId: desc.StreamId}); err != nil {
		t.Fatal(err)
	}
}
