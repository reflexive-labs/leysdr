// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
)

const notAnsweringDetail = "NESDR SMArt v5 is not answering: unplug it and plug it back in, ideally into a port on the back of the Mac"

func notAnsweringRadio() *leylinev1.DeviceDescriptor {
	return &leylinev1.DeviceDescriptor{
		DeviceId: "dev_01M224S5ZRDDEGKRWJSCTABBRZ", Driver: "rtlsdr", Model: "NESDR SMArt v5", Serial: "00000001",
		State: leylinev1.DeviceState_NOT_ANSWERING, StateDetail: notAnsweringDetail,
		TuningRanges: []*leylinev1.FrequencyRange{{MinHz: 24_000_000, MaxHz: 1_766_000_000}},
	}
}

// A radio the daemon has stopped opening says so in ley devices and ley state,
// with the daemon's sentence: what happened and what to do.
func TestDevicesSayARadioIsNotAnswering(t *testing.T) {
	t.Parallel()
	sock, _ := harness(t, fakedaemon.Options{ExtraDevices: []*leylinev1.DeviceDescriptor{notAnsweringRadio()}})
	out := mustRun(t, sock, "devices")
	var row string
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "NESDR SMArt v5") && row == "" {
			row = l
		}
	}
	if !strings.Contains(row, "NOT_ANSWERING") {
		t.Fatalf("the radio's row must read NOT_ANSWERING:\n%s", out)
	}
	if !strings.Contains(out, "\n"+notAnsweringDetail+"\n") {
		t.Fatalf("ley devices must print the sentence on a line of its own:\n%s", out)
	}
	if out = mustRun(t, sock, "state"); !strings.Contains(out, "not answering") || !strings.Contains(out, notAnsweringDetail) {
		t.Fatalf("ley state must say the radio is not answering and what to do:\n%s", out)
	}
	if out = mustRun(t, sock, "--json", "devices"); !strings.Contains(out, `"stateDetail":"`+notAnsweringDetail+`"`) ||
		!strings.Contains(out, `"NOT_ANSWERING"`) {
		t.Fatalf("--json carries the proto fields as they are: %s", out)
	}
}

// A stalled capture reads "stalled" with its detail in the tree, and STALLED in
// the --wide table.
func TestStateSaysACaptureIsStalled(t *testing.T) {
	st := busyState()
	st.Captures[0].State = leylinev1.CaptureState_CAPTURE_STALLED
	st.Captures[0].StateDetail = "no samples from Generic RTL2832U (R820T) for 5 s"
	out := renderStateTree(ui.Style{Unicode: true, Width: 100}, st)
	if !strings.Contains(out, "stalled") || !strings.Contains(out, "no samples from Generic RTL2832U (R820T) for 5 s") {
		t.Fatalf("the tree must say the capture is stalled and for how long:\n%s", out)
	}
	if got := inkState(ui.Style{Color: true}, "stalled"); got == "stalled" {
		t.Error("stalled must be inked as a degraded state")
	}
	if got := inkState(ui.Style{Color: true}, "not answering"); got == "not answering" {
		t.Error("not answering must be inked as a fault")
	}
}

// The default device is never one the daemon will not open.
func TestPickDeviceSkipsARadioNotAnswering(t *testing.T) {
	remote := &leylinev1.DeviceDescriptor{DeviceId: "dev_remote", Driver: "rtltcp", Model: "rtl_tcp", State: leylinev1.DeviceState_AVAILABLE}
	got, err := pickDevice(&leylinev1.GetStateResponse{Devices: []*leylinev1.DeviceDescriptor{notAnsweringRadio(), remote}}, "")
	if err != nil || got.DeviceId != "dev_remote" {
		t.Fatalf("expected the radio that answers, got %v (err %v)", got.GetDeviceId(), err)
	}
}
