package leyline

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
)

// ErrorTrailerKey is the trailing-metadata key under which the daemon serialises
// a leyline.v1.ErrorDetail. gRPC transports "-bin" keys as base64 automatically.
const ErrorTrailerKey = "leyline-error-bin"

// Stable machine error codes carried in ErrorDetail.code. The list mirrors the
// engine's EngineError constructors.
const (
	CodeDeviceNotFound      = "DEVICE_NOT_FOUND"
	CodeDeviceBusy          = "DEVICE_BUSY"
	CodeDeviceSweeping      = "DEVICE_SWEEPING"
	CodeDeviceDetached      = "DEVICE_DETACHED"
	CodeDeviceIO            = "DEVICE_IO"
	CodeFreqOutOfRange      = "FREQ_OUT_OF_RANGE"
	CodeRateUnsupported     = "RATE_UNSUPPORTED"
	CodeOffsetOutOfCapture  = "OFFSET_OUT_OF_CAPTURE"
	CodeGainElementUnknown  = "GAIN_ELEMENT_UNKNOWN"
	CodeCaptureNotFound     = "CAPTURE_NOT_FOUND"
	CodeChannelNotFound     = "CHANNEL_NOT_FOUND"
	CodeSinkNotFound        = "SINK_NOT_FOUND"
	CodeJobNotFound         = "JOB_NOT_FOUND"
	CodeScanNotFound        = "SCAN_NOT_FOUND"
	CodeStreamNotFound      = "STREAM_NOT_FOUND"
	CodeModeUnsupported     = "MODE_UNSUPPORTED"
	CodeUnimplemented       = "UNIMPLEMENTED"
	CodeInvalidArgument     = "INVALID_ARGUMENT"
	CodePlatformUnsupported = "PLATFORM_UNSUPPORTED"
	CodeUnavailable         = "UNAVAILABLE"
	CodeUnknown             = "UNKNOWN"

	// Transport-level codes: no daemon mints these, but a call that never reached
	// the daemon still has to name what happened.
	CodeNotFound         = "NOT_FOUND"
	CodeCanceled         = "CANCELED"
	CodeDeadlineExceeded = "DEADLINE_EXCEEDED"
)

// Error is a daemon error with a stable machine code. It is what every client
// method returns when the daemon rejects a call; errors.As works on it.
type Error struct {
	Code    string // stable machine code, e.g. "FREQ_OUT_OF_RANGE"
	Message string // human prose
	Target  string // id of the object the error concerns, may be empty
	Status  *status.Status
	// cause is the error FromStatus converted, kept so errors.Is can see
	// through to context.Canceled and friends.
	cause error
}

// Error implements error as "CODE: message (target)".
func (e *Error) Error() string {
	if e.Target != "" {
		return fmt.Sprintf("%s: %s (%s)", e.Code, e.Message, e.Target)
	}
	return fmt.Sprintf("%s: %s", e.Code, e.Message)
}

// Unwrap returns the error this one was converted from (nil when built by
// hand), so errors.Is(err, context.Canceled) works on a client-side cancel.
func (e *Error) Unwrap() error { return e.cause }

// GRPCStatus lets status.FromError recover the original gRPC status.
func (e *Error) GRPCStatus() *status.Status { return e.Status }

// Code returns the stable machine code of err, or "" if err is nil. Non-daemon
// errors yield CodeUnknown (or CodeUnavailable for transport failures).
func Code(err error) string {
	if err == nil {
		return ""
	}
	var le *Error
	if errors.As(err, &le) {
		return le.Code
	}
	return FromStatus(err).Code
}

// FromStatus converts any error returned by a leyline RPC into *Error. It reads
// the ErrorDetail from the "leyline-error-bin" trailer when the call's trailer
// metadata is supplied (see FromStatusWithTrailer), otherwise falls back to the
// "CODE: message" convention in the status message, then to the gRPC code.
func FromStatus(err error) *Error {
	return FromStatusWithTrailer(err, nil)
}

// FromStatusWithTrailer is FromStatus with the call's trailing metadata, which
// gRPC hands back via grpc.Trailer(&md) for unary calls or stream.Trailer().
func FromStatusWithTrailer(err error, trailer metadata.MD) *Error {
	if err == nil {
		return nil
	}
	var le *Error
	if errors.As(err, &le) {
		return le
	}
	st, ok := status.FromError(err)
	if !ok {
		if errors.Is(err, context.Canceled) {
			return &Error{Code: "CANCELED", Message: err.Error(), Status: status.New(codes.Canceled, err.Error()), cause: err}
		}
		return &Error{Code: CodeUnknown, Message: err.Error(), Status: status.New(codes.Unknown, err.Error()), cause: err}
	}
	if d := detailFromTrailer(trailer); d != nil {
		return &Error{Code: d.Code, Message: d.Message, Target: d.Target, Status: st, cause: err}
	}
	for _, d := range st.Details() {
		if ed, ok := d.(*leylinev1.ErrorDetail); ok {
			return &Error{Code: ed.Code, Message: ed.Message, Target: ed.Target, Status: st, cause: err}
		}
	}
	code, msg := splitCodeMessage(st.Message())
	if code == "" {
		code = codeForGRPC(st.Code())
	}
	return &Error{Code: code, Message: msg, Status: st, cause: err}
}

func detailFromTrailer(md metadata.MD) *leylinev1.ErrorDetail {
	if md == nil {
		return nil
	}
	vals := md.Get(ErrorTrailerKey)
	if len(vals) == 0 {
		return nil
	}
	var d leylinev1.ErrorDetail
	if err := proto.Unmarshal([]byte(vals[0]), &d); err != nil || d.Code == "" {
		return nil
	}
	return &d
}

// splitCodeMessage splits "CODE: message" when CODE looks like a stable code
// (upper-case letters, digits, underscores).
func splitCodeMessage(s string) (code, msg string) {
	i := strings.Index(s, ":")
	if i <= 0 {
		return "", s
	}
	c := s[:i]
	for _, r := range c {
		if (r < 'A' || r > 'Z') && (r < '0' || r > '9') && r != '_' {
			return "", s
		}
	}
	return c, strings.TrimSpace(s[i+1:])
}

func codeForGRPC(c codes.Code) string {
	switch c {
	case codes.Unimplemented:
		return CodeUnimplemented
	case codes.InvalidArgument:
		return CodeInvalidArgument
	case codes.NotFound:
		return CodeNotFound
	case codes.Unavailable:
		return CodeUnavailable
	case codes.Canceled:
		return CodeCanceled
	case codes.DeadlineExceeded:
		return CodeDeadlineExceeded
	default:
		return strings.ToUpper(strings.ReplaceAll(c.String(), " ", "_"))
	}
}

// GRPCCode maps a stable machine code to the gRPC status code daemons use for it.
// Every code codeForGRPC can produce round-trips back to the code it came from,
// so an Error parsed off the wire and re-served — as the fake daemon does — keeps
// the status code any retry logic keys on.
func GRPCCode(code string) codes.Code {
	switch code {
	case CodeDeviceNotFound, CodeCaptureNotFound, CodeChannelNotFound, CodeSinkNotFound, CodeStreamNotFound, CodeGainElementUnknown,
		CodeJobNotFound, CodeScanNotFound, CodeNotFound:
		return codes.NotFound
	case CodeUnavailable:
		return codes.Unavailable
	case CodeCanceled:
		return codes.Canceled
	case CodeDeadlineExceeded:
		return codes.DeadlineExceeded
	case CodeDeviceBusy, CodeDeviceSweeping:
		return codes.FailedPrecondition
	case CodeDeviceDetached, CodeDeviceIO:
		return codes.Unavailable
	case CodeUnimplemented, CodePlatformUnsupported, CodeModeUnsupported:
		return codes.Unimplemented
	case CodeFreqOutOfRange, CodeRateUnsupported, CodeOffsetOutOfCapture, CodeInvalidArgument:
		return codes.InvalidArgument
	default:
		return codes.Unknown
	}
}

// ToStatus builds the daemon-side representation of an Error: a gRPC status
// whose message is "CODE: message". Servers should additionally set the
// ErrorTrailerKey trailer with the serialised ErrorDetail (see Trailer).
func (e *Error) ToStatus() *status.Status {
	return status.New(GRPCCode(e.Code), e.Code+": "+e.Message)
}

// Trailer returns the trailing metadata carrying this error's ErrorDetail.
func (e *Error) Trailer() metadata.MD {
	b, _ := proto.Marshal(&leylinev1.ErrorDetail{Code: e.Code, Message: e.Message, Target: e.Target})
	return metadata.Pairs(ErrorTrailerKey, string(b))
}
