// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// FromStatus keeps the error it converted reachable through Unwrap so callers
// can errors.Is through a *Error to context.Canceled or the original status.
func TestErrorUnwrap(t *testing.T) {
	le := FromStatus(context.Canceled)
	if le.Code != "CANCELED" || !errors.Is(le, context.Canceled) {
		t.Errorf("FromStatus(context.Canceled) = %+v, Is(Canceled)=%v", le, errors.Is(le, context.Canceled))
	}
	st := status.Error(codes.Canceled, "context canceled")
	le = FromStatus(st)
	if le.Code != "CANCELED" || !errors.Is(le, st) {
		t.Errorf("FromStatus(status Canceled) = %+v, Is(status)=%v", le, errors.Is(le, st))
	}
	if errors.Is(le, context.Canceled) {
		t.Errorf("a Canceled status is not context.Canceled")
	}
	hand := &Error{Code: CodeDeviceBusy, Message: "busy"}
	if hand.Unwrap() != nil || FromStatus(hand) != hand {
		t.Errorf("hand-built Error: Unwrap=%v, FromStatus identity=%v", hand.Unwrap(), FromStatus(hand) == hand)
	}
}

// Every code the client mints from a transport status must map back to the gRPC
// code it came from: the fake daemon re-serves parsed Errors with ToStatus, and a
// client that retries on UNAVAILABLE must still see UNAVAILABLE on the far side.
func TestGRPCCodeRoundTripsTransportCodes(t *testing.T) {
	for _, c := range []codes.Code{
		codes.Unimplemented, codes.InvalidArgument, codes.NotFound,
		codes.Unavailable, codes.Canceled, codes.DeadlineExceeded, codes.Unknown,
	} {
		if got := GRPCCode(codeForGRPC(c)); got != c {
			t.Errorf("GRPCCode(codeForGRPC(%v)) = %v", c, got)
		}
	}
	e := &Error{Code: CodeUnavailable, Message: "no daemon"}
	if got := e.ToStatus().Code(); got != codes.Unavailable {
		t.Errorf("ToStatus of UNAVAILABLE = %v", got)
	}
}

// docs/engine-internals.md carries the one error table: every stable code and the
// gRPC status it is served with. Both daemons follow it, so a code added on one
// side alone, or a status changed in one switch, fails here and in the engine's
// twin of this test.
func TestErrorTableMatchesDocumentation(t *testing.T) {
	table := documentedErrorTable(t)

	inDoc := map[string]bool{}
	for code := range table {
		inDoc[code] = true
	}
	for _, code := range DaemonCodes {
		if !inDoc[code] {
			t.Errorf("%s is in DaemonCodes and not in the table", code)
		}
		delete(inDoc, code)
	}
	for code := range inDoc {
		t.Errorf("%s is in the table and not in DaemonCodes", code)
	}

	for code, want := range table {
		if got := GRPCCode(code); got != want {
			t.Errorf("GRPCCode(%s) = %v, table says %v", code, got, want)
		}
	}
}

// documentedErrorTable reads the "### Error codes" table as code -> gRPC status.
func documentedErrorTable(t *testing.T) map[string]codes.Code {
	t.Helper()
	doc, err := os.ReadFile(filepath.Join("..", "..", "..", "docs", "engine-internals.md"))
	if err != nil {
		t.Fatalf("reading engine-internals.md: %v", err)
	}
	row := regexp.MustCompile("^\\| `([A-Z_]+)` \\| `([A-Z_]+)` \\|")
	table := map[string]codes.Code{}
	inSection := false
	for _, line := range strings.Split(string(doc), "\n") {
		if strings.HasPrefix(line, "### ") {
			inSection = line == "### Error codes"
			continue
		}
		if !inSection {
			continue
		}
		m := row.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		st, ok := grpcCodeNamed(m[2])
		if !ok {
			t.Fatalf("the table gives %s a status gRPC does not have: %s", m[1], m[2])
		}
		table[m[1]] = st
	}
	if len(table) == 0 {
		t.Fatal("no error-code rows found in engine-internals.md")
	}
	return table
}

// grpcCodeNamed resolves a SHOUTING_CASE gRPC status name, as the table spells it.
func grpcCodeNamed(name string) (codes.Code, bool) {
	want := strings.ReplaceAll(name, "_", "")
	for c := codes.Code(0); c <= codes.Unauthenticated; c++ {
		if strings.EqualFold(c.String(), want) {
			return c, true
		}
	}
	return codes.OK, false
}
