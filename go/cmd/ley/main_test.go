package main

import (
	"context"
	"errors"
	"testing"

	"github.com/dpup/leysdr/go/internal/cli"
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
	}
	for _, tc := range cases {
		if got := exitStatus(tc.ctx, tc.err); got != tc.want {
			t.Errorf("%s: got %d, want %d", tc.name, got, tc.want)
		}
	}
}
