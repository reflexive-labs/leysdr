// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"fmt"
	"math"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/units"
)

// --gain: writing each stage and waiting for the daemon's confirmation, and the words every verb
// prints a capture's gain with.

// applyGain writes --gain to the capture, one stage at a time in the order
// given (the first stage for a bare level), and waits for each confirming
// capture event so the banner shows the values the daemon settled on (the
// daemon snaps to the element's table, as set.go mirrors).
func (s *verbSession) applyGain(ctx context.Context, o *tuneOptions) error {
	if o.gain == "" {
		return nil
	}
	settings, err := units.ParseGains(o.gain)
	if err != nil {
		return fmt.Errorf("--gain %w", err)
	}
	if len(s.device.GainElements) == 0 {
		return fmt.Errorf("%s reports no gain stages, so --gain has nothing to set; leave it off", deviceName(s.device))
	}
	for _, g := range settings {
		if err := s.writeGain(ctx, g); err != nil {
			return err
		}
	}
	return nil
}

// writeGain writes one stage's gain and waits for the daemon to confirm or
// refuse it. A named stage is matched against the device ignoring case; one
// the device does not list is sent as typed, so the refusal is the daemon's,
// with the stages the radio has.
func (s *verbSession) writeGain(ctx context.Context, g units.GainSetting) error {
	el := s.device.GainElements[0]
	name := el.GetName()
	if g.Element != "" {
		el, name = nil, g.Element
		for _, e := range s.device.GainElements {
			if strings.EqualFold(e.GetName(), g.Element) {
				el, name = e, e.GetName()
			}
		}
	}
	db, auto, tol := g.DB, g.Auto, 1.0
	if el != nil && !auto {
		if err := units.CheckGain(db, el); err != nil {
			return fmt.Errorf("--gain %w", err)
		}
		db, tol = units.SnapGain(el, db), units.GainTolerance(el)
	}
	gw := &leylinev1.GainWrite{Element: name}
	if auto {
		gw.Value = &leylinev1.GainWrite_Auto{Auto: true}
	} else {
		gw.Value = &leylinev1.GainWrite_Db{Db: db}
	}
	w := &leylinev1.ParamWrite{Tag: 3, TargetId: s.Capture.CaptureId, Param: &leylinev1.ParamWrite_Gain{Gain: gw}}
	if _, err := s.Client.WriteParams(ctx, w); err != nil {
		return fmt.Errorf("--gain was not applied: %w", err)
	}
	ev, err := s.AwaitEvent(ctx, func(ev *leylinev1.Event) bool {
		switch b := ev.Body.(type) {
		case *leylinev1.Event_Capture:
			if b.Capture.CaptureId != s.Capture.CaptureId {
				return false
			}
			for _, gs := range b.Capture.Gains {
				if gs.Element == name && (auto && gs.Auto || !auto && !gs.Auto && math.Abs(gs.Db-db) <= tol) {
					return true
				}
			}
		case *leylinev1.Event_WriteRejected:
			return s.Mine(ev) && b.WriteRejected.Tag == 3
		}
		return false
	})
	if err != nil {
		return fmt.Errorf("--gain was not applied: %w", err)
	}
	if r, ok := ev.Body.(*leylinev1.Event_WriteRejected); ok {
		return fmt.Errorf("--gain was not applied: %w", rejectedError(r.WriteRejected))
	}
	return nil
}

// stageGainWords is the one way a capture's gain prints, wherever it prints: "gain 28 dB" or
// "gain auto" on a radio with one stage, every stage by name on a radio with several ("gain LNA
// 0 dB, VGA 20 dB, AMP off"), because "gain 8.0 dB" on a HackRF reads as the radio's whole gain
// when it is the LNA alone. Names are the daemon's
// spelling. els is the device's gain elements, which is how a two-value stage is known to be a
// switch; without them (the device is gone) such a stage prints its level ("AMP 11 dB").
func stageGainWords(gains []*leylinev1.GainState, els []*leylinev1.GainElement) string {
	switch len(gains) {
	case 0:
		return "no gain control"
	case 1:
		return "gain " + stageLevel(gains[0], gainElement(els, gains[0].GetElement()))
	}
	stages := make([]string, len(gains))
	for i, g := range gains {
		stages[i] = g.GetElement() + " " + stageLevel(g, gainElement(els, g.GetElement()))
	}
	return "gain " + strings.Join(stages, ", ")
}

// stageLevel is one stage's setting as stageGainWords prints it: "auto", "on" or "off" for a
// switch, else the level ("20 dB", "49.6 dB").
func stageLevel(g *leylinev1.GainState, el *leylinev1.GainElement) string {
	switch {
	case g.GetAuto():
		return "auto"
	case isGainSwitch(el):
		if g.GetDb() > min(el.ValidDb[0], el.ValidDb[1]) {
			return "on"
		}
		return "off"
	}
	return gainDB(g.GetDb()) + " dB"
}

// gainDB renders a gain level with a decimal only when it has one: "49.6", "8", "0". Gains are
// set in steps of a tenth of a dB at the finest (the RTL-SDR tables), so the level is rounded to
// one decimal first and a stored 29.700000001 still reads 29.7.
func gainDB(db float64) string {
	return strconv.FormatFloat(math.Round(db*10)/10, 'f', -1, 64)
}

// isGainSwitch reports whether a gain element is a switch rather than a level: two valid settings
// and no step, as the HackRF's AMP (0 or 11 dB).
func isGainSwitch(el *leylinev1.GainElement) bool {
	return el != nil && len(el.ValidDb) == 2 && el.StepDb == 0
}

// gainElement is the element of els a stage names, matched ignoring case as the daemon matches
// it; nil when els does not list it.
func gainElement(els []*leylinev1.GainElement, name string) *leylinev1.GainElement {
	for _, el := range els {
		if strings.EqualFold(el.GetName(), name) {
			return el
		}
	}
	return nil
}

// deviceGainElements is the gain elements of the device a capture runs on, from the state; nil
// when the state no longer lists it.
func deviceGainElements(st *leylinev1.GetStateResponse, deviceID string) []*leylinev1.GainElement {
	for _, d := range st.GetDevices() {
		if d.GetDeviceId() == deviceID {
			return d.GetGainElements()
		}
	}
	return nil
}
