// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"errors"
	"strings"
	"testing"

	"google.golang.org/protobuf/encoding/protojson"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
)

// --dry-run says where a job would go in a sentence and starts nothing; a decline exits 1 with
// the reason, and --json is the CapturePlan.
func TestDryRunSaysThePlan(t *testing.T) {
	t.Parallel()
	sock, c := harness(t, fakedaemon.Options{})

	out := mustRun(t, sock, "scan", "145M..147M", "--dry-run")
	if !strings.HasPrefix(out, "would sweep with ") || !strings.Contains(out, "which nothing is using") {
		t.Errorf("an idle radio: %q", out)
	}
	out = mustRun(t, sock, "decode", "aprs", "--dry-run")
	if !strings.HasPrefix(out, "would open ") || !strings.Contains(out, "2.4 MSPS") {
		t.Errorf("a decode on an idle radio: %q", out)
	}

	listening(t, c)
	_, _, err := run(t, t.Context(), sock, "scan", "145M..147M", "--dry-run")
	var ee *ExitError
	if !asExit(err, &ee) || ee.Code != 1 {
		t.Fatalf("a busy radio declines with exit 1, got %v", err)
	}
	if !strings.HasPrefix(ee.Message, "would not start: ") || !strings.Contains(ee.Message, "--take-over") {
		t.Errorf("the decline names the reason and the way through: %q", ee.Message)
	}
	out = mustRun(t, sock, "scan", "145M..147M", "--dry-run", "--take-over")
	if !strings.Contains(out, "for the sweep and put it back afterwards, pausing: ") ||
		!strings.Contains(out, "channel on 146.520 MHz") {
		t.Errorf("a take-over names what it pauses: %q", out)
	}
	out = mustRun(t, sock, "record", "146.52", "--dry-run", "--take-over")
	if !strings.HasPrefix(out, "would share the capture at 146.520 MHz on ") {
		t.Errorf("a recording inside the span shares it: %q", out)
	}

	out, _, err = run(t, t.Context(), sock, "--json", "scan", "145M..147M", "--dry-run")
	if !asExit(err, &ee) || ee.Code != 1 {
		t.Fatalf("--json declines with exit 1 too, got %v", err)
	}
	var p leylinev1.CapturePlan
	if uerr := protojson.Unmarshal([]byte(out), &p); uerr != nil {
		t.Fatalf("--json is the CapturePlan: %v\n%s", uerr, out)
	}
	if p.GetDecline().GetCode() != "DEVICE_BUSY" || len(p.GetDecline().GetBlocking()) == 0 {
		t.Errorf("the decline carries its code and blocking claims: %v", &p)
	}

	if _, _, err := run(t, t.Context(), sock, "decode", "aprs", "--dry-run", "--recording", "job_x"); !asExit(err, &ee) || ee.Code != ExitUsage {
		t.Errorf("--recording needs no radio, so --dry-run is a usage error: %v", err)
	}

	st, err := c.State(t.Context())
	if err != nil {
		t.Fatal(err)
	}
	if len(st.GetJobs()) != 0 {
		t.Errorf("a dry run starts nothing: %v", st.GetJobs())
	}
}

func asExit(err error, target **ExitError) bool { return errors.As(err, target) }
