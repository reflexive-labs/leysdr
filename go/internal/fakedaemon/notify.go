// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"bytes"
	"os"
	"os/exec"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// fireNotify delivers a record that passed the predicate to the job's notifier, the way the
// design doc's notification sink does (docs/design/decoders.md, "Predicates and delivery"): a
// shell hook is actually run -- with the record's proto3 JSON on stdin and its promoted fields
// in the environment -- so a test can assert a notifier fired against the fake without the Swift
// daemon; a webhook or a macOS notification is counted here and logged by the real daemon.
// External delivery is the daemon reaching out, so it runs off the record path, not under mu.
func (d *Daemon) fireNotify(t *leylinev1.NotifyTarget, rec *leylinev1.DecodeRecord) {
	switch tt := t.GetTarget().(type) {
	case *leylinev1.NotifyTarget_Shell:
		js, _ := protojson.Marshal(rec)
		cmd := exec.Command("/bin/sh", "-c", tt.Shell)
		cmd.Stdin = bytes.NewReader(js)
		cmd.Env = append(os.Environ(),
			"LEYLINE_PROTOCOL="+rec.GetProtocol(),
			"LEYLINE_DEVICE_ID="+rec.GetDeviceId(),
			"LEYLINE_KIND="+rec.GetKind(),
			"LEYLINE_RECORD_ID="+rec.GetRecordId(),
		)
		_ = cmd.Run()
		d.countNotify("shell")
	case *leylinev1.NotifyTarget_Webhook:
		d.countNotify("webhook")
	case *leylinev1.NotifyTarget_MacosNotification:
		d.countNotify("macos")
	}
}

func (d *Daemon) countNotify(kind string) {
	d.notifyMu.Lock()
	d.notifyCounts[kind]++
	d.notifyMu.Unlock()
}

// NotifyCount reports how many times a notifier of the given kind (shell, webhook, macos) has
// fired. A test hook: a shell notifier also leaves its own evidence, but a webhook or macOS one
// is a no-op in the fake and this is how a test sees it happened.
func (d *Daemon) NotifyCount(kind string) int {
	d.notifyMu.Lock()
	defer d.notifyMu.Unlock()
	return d.notifyCounts[kind]
}
