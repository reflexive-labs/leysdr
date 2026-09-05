package leyline

import (
	"errors"
	"strings"
	"testing"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

func selectorState() *leylinev1.GetStateResponse {
	return &leylinev1.GetStateResponse{
		Devices: []*leylinev1.DeviceDescriptor{
			{DeviceId: "dev_01AAA", TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}}},
			{DeviceId: "dev_01ABB", TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 1_000_000, MaxHz: 6_000_000_000}}},
		},
		Captures: []*leylinev1.Capture{
			{CaptureId: "cap_01XYZ", DeviceId: "dev_01AAA", CenterHz: 146_000_000, SampleRate: 2_400_000},
			{CaptureId: "cap_01XQQ", DeviceId: "dev_01ABB", CenterHz: 101_000_000, SampleRate: 2_400_000},
		},
		Channels: []*leylinev1.Channel{
			{ChannelId: "chan_01AAAA", CaptureId: "cap_01XYZ", OffsetHz: 520_000, BandwidthHz: 12_500},
			{ChannelId: "chan_01AABB", CaptureId: "cap_01XYZ", OffsetHz: 620_000, BandwidthHz: 12_500},
			{ChannelId: "chan_01BBBB", CaptureId: "cap_01XQQ", OffsetHz: 100_000, BandwidthHz: 200_000},
		},
	}
}

func TestResolveChannel(t *testing.T) {
	st := selectorState()
	cases := []struct {
		sel  string
		want string
		err  string
		ambi bool
	}{
		{"chan_01AAAA", "chan_01AAAA", "", false},
		{"chan_01AAB", "chan_01AABB", "", false},
		{"chan_01B", "chan_01BBBB", "", false},
		{"1", "chan_01AAAA", "", false},
		{"3", "chan_01BBBB", "", false},
		{"146.52", "chan_01AAAA", "", false},
		{"146.62", "chan_01AABB", "", false},
		{"146.625M", "chan_01AABB", "", false},
		{"101.1", "chan_01BBBB", "", false},
		{"chan_01AA", "", "more than one", true},
		{"chan_01AA", "", "chan_01AABB", true},
		{"4", "", "no channel matches", false},
		{"0", "", "no channel matches", false},
		{"146.7", "", "no channel matches", false},
		{"chan_zzz", "", "chan_01AAAA", false},
		{"", "", "no channel matches", false},
	}
	for _, c := range cases {
		got, err := ResolveChannel(st, c.sel)
		if c.err != "" {
			var se *SelectorError
			if err == nil || !strings.Contains(err.Error(), c.err) || !errors.As(err, &se) || se.Ambiguous != c.ambi {
				t.Errorf("ResolveChannel(%q) err = %v, want containing %q ambiguous=%v", c.sel, err, c.err, c.ambi)
			}
			continue
		}
		if err != nil || got.GetChannelId() != c.want {
			t.Errorf("ResolveChannel(%q) = %v, %v; want %s", c.sel, got.GetChannelId(), err, c.want)
		}
	}
	// A miss and an ambiguity list the candidates as rows a person can pick from.
	if _, err := ResolveChannel(st, "146.7"); err == nil || !strings.Contains(err.Error(), "pick one:\n  1  chan_01AAAA  146.520 MHz ") {
		t.Errorf("ResolveChannel(146.7) rows: %v", err)
	}
	if _, err := ResolveChannel(&leylinev1.GetStateResponse{}, "1"); err == nil || !strings.Contains(err.Error(), "no channels") {
		t.Errorf("ResolveChannel(empty, 1) = %v", err)
	}
}

func TestResolveCapture(t *testing.T) {
	st := selectorState()
	cases := []struct {
		sel  string
		want string
		err  string
	}{
		{"cap_01XYZ", "cap_01XYZ", ""},
		{"cap_01XQ", "cap_01XQQ", ""},
		{"2", "cap_01XQQ", ""},
		{"146.52", "cap_01XYZ", ""},
		{"147.1", "cap_01XYZ", ""},
		{"101.9", "cap_01XQQ", ""},
		{"cap_01X", "", "more than one"},
		{"120", "", "no capture matches"},
		{"3", "", "no capture matches"},
	}
	for _, c := range cases {
		got, err := ResolveCapture(st, c.sel)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ResolveCapture(%q) err = %v, want containing %q", c.sel, err, c.err)
			}
			continue
		}
		if err != nil || got.GetCaptureId() != c.want {
			t.Errorf("ResolveCapture(%q) = %v, %v; want %s", c.sel, got.GetCaptureId(), err, c.want)
		}
	}
}

func TestResolveDevice(t *testing.T) {
	st := selectorState()
	cases := []struct {
		sel  string
		want string
		err  string
	}{
		{"dev_01AAA", "dev_01AAA", ""},
		{"dev_01AB", "dev_01ABB", ""},
		{"1", "dev_01AAA", ""},
		{"2", "dev_01ABB", ""},
		{"7.1", "dev_01ABB", ""},
		{"146.52", "", "more than one"},
		{"dev_01A", "", "more than one"},
		{"dev_zz", "", "no device matches"},
	}
	for _, c := range cases {
		got, err := ResolveDevice(st, c.sel)
		if c.err != "" {
			if err == nil || !strings.Contains(err.Error(), c.err) {
				t.Errorf("ResolveDevice(%q) err = %v, want containing %q", c.sel, err, c.err)
			}
			continue
		}
		if err != nil || got.GetDeviceId() != c.want {
			t.Errorf("ResolveDevice(%q) = %v, %v; want %s", c.sel, got.GetDeviceId(), err, c.want)
		}
	}
}
