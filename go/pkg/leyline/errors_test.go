package leyline

import (
	"context"
	"errors"
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
