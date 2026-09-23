// SPDX-License-Identifier: Apache-2.0

package e2e

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// rtlTCPServer impersonates rtl_tcp well enough for the daemon to open a radio on it: the 12-byte
// header (magic "RTL0", tuner type, tuner gain count), then cu8 forever. Commands are read and
// dropped, as a real server never acknowledges them either.
type rtlTCPServer struct {
	listener net.Listener
	mu       sync.Mutex
	conns    []net.Conn
	closed   bool
}

// rtlTCPRate is the byte rate of 2.4 MSPS of cu8, the capture the daemon opens. A server that
// falls far behind it starves the pipeline; one that ignores the clock entirely floods the ring
// with hours of air per second of test.
const rtlTCPRate = 4_800_000

// startRTLTCP binds an ephemeral port on the loopback and serves every client that arrives.
func startRTLTCP(t *testing.T) *rtlTCPServer {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	s := &rtlTCPServer{listener: l}
	t.Cleanup(s.stop)
	go s.accept()
	return s
}

func (s *rtlTCPServer) port() int { return s.listener.Addr().(*net.TCPAddr).Port }

func (s *rtlTCPServer) endpoint() string { return fmt.Sprintf("127.0.0.1:%d", s.port()) }

func (s *rtlTCPServer) accept() {
	for {
		conn, err := s.listener.Accept()
		if err != nil {
			return
		}
		s.mu.Lock()
		if s.closed {
			s.mu.Unlock()
			_ = conn.Close()
			return
		}
		s.conns = append(s.conns, conn)
		s.mu.Unlock()
		go s.serve(conn)
	}
}

func (s *rtlTCPServer) serve(conn net.Conn) {
	defer func() { _ = conn.Close() }()
	// Tuner 5 is the R820T, and 29 is the length of its gain table.
	header := make([]byte, 12)
	copy(header, "RTL0")
	binary.BigEndian.PutUint32(header[4:], 5)
	binary.BigEndian.PutUint32(header[8:], 29)
	if _, err := conn.Write(header); err != nil {
		return
	}
	// Commands are 5 bytes each, but nothing here depends on which: read until the daemon hangs up.
	go func() { _, _ = io.Copy(io.Discard, conn) }()
	// Quiet cu8 noise around the zero level (127.5), which is what a dongle on an antenna receives
	// with nothing on frequency. Digital silence would be simpler but has no noise floor, and the
	// squelch cannot be measured without one.
	chunk := make([]byte, 16384)
	noise := uint32(1)
	start := time.Now()
	var sent int64
	for {
		for i := range chunk {
			noise = noise*1664525 + 1013904223
			chunk[i] = byte(120 + noise>>28)
		}
		n, err := conn.Write(chunk)
		if err != nil {
			return
		}
		sent += int64(n)
		if ahead := time.Duration(float64(sent)/rtlTCPRate*float64(time.Second)) - time.Since(start); ahead > 0 {
			time.Sleep(ahead)
		}
	}
}

func (s *rtlTCPServer) stop() {
	s.mu.Lock()
	s.closed = true
	conns := s.conns
	s.conns = nil
	s.mu.Unlock()
	_ = s.listener.Close()
	for _, c := range conns {
		_ = c.Close()
	}
}

// rememberedEndpoints reads devices.json beside the daemon's socket: the list it re-attaches at
// startup, and the only way to check that an attach outlives the client that asked for it.
func (e *env) rememberedEndpoints() []map[string]any {
	e.t.Helper()
	raw, err := os.ReadFile(filepath.Join(filepath.Dir(e.socket), "devices.json"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		e.t.Fatalf("read devices.json: %v", err)
	}
	var file struct {
		RtlTCP []map[string]any `json:"rtl_tcp"`
	}
	if err := json.Unmarshal(raw, &file); err != nil {
		e.t.Fatalf("devices.json is not a device list (%v): %s", err, raw)
	}
	return file.RtlTCP
}

// TestRemoteRadioAgainstRealDaemon attaches a radio served over the network and uses it. Only the
// real daemon has the rtl_tcp client, the remembered-device file and the device registry, so this
// is the one place the Go side of `ley devices attach` meets them.
func TestRemoteRadioAgainstRealDaemon(t *testing.T) {
	e, _ := setup(t)
	server := startRTLTCP(t)

	// Attach: the id on stdout, the sentence about it on stderr.
	attach := e.mustRun("devices", "attach", "rtltcp", server.endpoint())
	fields := strings.Fields(strings.TrimSpace(attach))
	if len(fields) != 2 || fields[0] != "device" || !strings.HasPrefix(fields[1], "dev_") {
		t.Fatalf("attach stdout: %q", attach)
	}
	devID := fields[1]

	// The daemon lists it as a radio like any other, with the endpoint as its serial.
	devs := testDevices(list(parseJSON(t, e.mustRun("devices", "--json")), "devices"))
	if len(devs) != 1 {
		t.Fatalf("devices: want the attached radio only, got %v", devs)
	}
	dev := devs[0]
	if dev["deviceId"] != devID || dev["driver"] != "rtltcp" || dev["serial"] != server.endpoint() {
		t.Fatalf("unexpected device %v", dev)
	}
	if dev["state"] != "AVAILABLE" {
		t.Fatalf("an attached radio nobody is using is available: %v", dev)
	}

	// It is also written to devices.json, which survives a restart.
	remembered := e.rememberedEndpoints()
	if len(remembered) != 1 || remembered[0]["host"] != "127.0.0.1" || remembered[0]["port"] != float64(server.port()) {
		t.Fatalf("devices.json after attach: %v", remembered)
	}

	// Tune it: samples cross the network, through the daemon's channelizer and demodulator, and
	// come back as telemetry on this capture's timebase.
	stopTune, tuneOut := e.startLive("tune", "146.62M", "--no-audio", "--device", devID, "--json")
	st := e.waitChannels(1)
	caps := list(st, "captures")
	if len(caps) != 1 {
		t.Fatalf("captures: %v", caps)
	}
	capture := caps[0].(map[string]any)
	capID := capture["captureId"].(string)
	if capture["deviceId"] != devID || capture["state"] != "CAPTURE_ACTIVE" {
		t.Fatalf("unexpected capture %v", capture)
	}
	// Wait for the first telemetry line on this capture's timebase rather than a fixed pause: a
	// loaded machine can take longer than any fixed pause, and an idle one need not wait at all.
	for deadline := time.Now().Add(10 * time.Second); !strings.Contains(tuneOut.out.String(), `"captureId":"`+capID+`"`); {
		if time.Now().After(deadline) {
			_ = stopTune()
			t.Fatalf("no telemetry from the remote radio within 10 s:\n%s\n%s", tuneOut.out.String(), tuneOut.errOut.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err := stopTune(); err != nil {
		t.Fatalf("tune exit: %v\n%s\n%s", err, tuneOut.out.String(), tuneOut.errOut.String())
	}
	var meters int
	for _, line := range strings.Split(strings.TrimSpace(tuneOut.out.String()), "\n") {
		if line == "" {
			continue
		}
		msg := parseJSON(t, line)
		if _, ok := msg["causedBy"].(map[string]any); ok {
			continue
		}
		if tm, _ := msg["time"].(map[string]any); tm["captureId"] != capID {
			t.Fatalf("telemetry off the capture timebase: %v", msg)
		}
		meters++
	}
	if meters == 0 {
		t.Fatalf("no telemetry from the remote radio:\n%s\n%s", tuneOut.out.String(), tuneOut.errOut.String())
	}

	// Detach: the radio goes, and so does the line in devices.json.
	if out := e.mustRun("devices", "detach", devID); !strings.Contains(out, "detached "+devID) {
		t.Fatalf("detach stdout: %q", out)
	}
	if devs := testDevices(list(parseJSON(t, e.mustRun("devices", "--json")), "devices")); len(devs) != 0 {
		t.Fatalf("the radio outlived its detach: %v", devs)
	}
	if remembered := e.rememberedEndpoints(); len(remembered) != 0 {
		t.Fatalf("devices.json after detach: %v", remembered)
	}
}
