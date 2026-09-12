// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"errors"
	"testing"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"

	"github.com/dpup/leysdr/go/internal/cli"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func TestExitStatus(t *testing.T) {
	live := context.Background()
	cancelled, cancel := context.WithCancel(context.Background())
	cancel()
	cases := []struct {
		name string
		ctx  context.Context
		err  error
		want int
	}{
		{"ok", live, nil, 0},
		{"generic", live, errors.New("boom"), 1},
		{"interrupted", cancelled, context.Canceled, cli.ExitInterrupted},
		{"wrapped interrupt", cancelled, errors.Join(errors.New("rpc"), context.Canceled), cli.ExitInterrupted},
		{"cancelled without signal", live, context.Canceled, 1},
		{"exit error", live, &cli.ExitError{Code: cli.ExitNotRunning}, cli.ExitNotRunning},
		// gRPC reports a cancelled call context as a Canceled status rather
		// than context.Canceled; under the signal that is still an interrupt.
		{"canceled status", cancelled, status.Error(codes.Canceled, "context canceled"), cli.ExitInterrupted},
		{"canceled daemon error", cancelled, leyline.FromStatus(status.Error(codes.Canceled, "context canceled")), cli.ExitInterrupted},
		{"canceled via exit error", cancelled, &cli.ExitError{Code: 1, Message: "x [CANCELED]", Err: leyline.FromStatus(context.Canceled)}, cli.ExitInterrupted},
		{"canceled status without signal", live, status.Error(codes.Canceled, "context canceled"), 1},
		{"other daemon error under signal", cancelled, &cli.ExitError{Code: 1, Err: &leyline.Error{Code: leyline.CodeDeviceBusy}}, 1},
	}
	for _, tc := range cases {
		if got := exitStatus(tc.ctx, &cli.App{}, tc.err); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.name, got, tc.want)
		}
	}
}
