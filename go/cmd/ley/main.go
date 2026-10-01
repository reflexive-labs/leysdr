// SPDX-License-Identifier: Apache-2.0

// Command ley is the Leyline terminal client: CLI verbs over the leyline.v1
// gRPC contract.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/reflexive-labs/leysdr/go/internal/cli"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	exe, _ := os.Executable()
	app := &cli.App{Stdout: os.Stdout, Stderr: os.Stderr, Executable: exe}
	os.Exit(exitStatus(ctx, app, cli.Execute(ctx, app, os.Args[1:])))
}

// exitStatus maps Execute's error to a process status, per the taxonomy in
// docs/reference/cli.md and `ley help scripting`: 0 ok, 1 daemon/runtime error,
// 2 usage error (bad flag, unknown verb or parameter), 3 daemon not running,
// 130 interrupted by Ctrl-C before the live phase (a verb whose live phase
// was interrupted returns nil and so exits 0). Verbs carry 2 and 3 as
// cli.ExitError; everything else is 1. The line takes stderr's resolved ink
// (plain when the style never resolved, as for a flag error). An interrupt
// shows up either as
// context.Canceled in the chain or as a CANCELED daemon error (gRPC turns a
// cancelled call context into a Canceled status); both count only while the
// signal context is actually cancelled, so a stray CANCELED stays exit 1.
func exitStatus(ctx context.Context, app *cli.App, err error) int {
	if err == nil {
		return 0
	}
	if ctx.Err() != nil && (errors.Is(err, context.Canceled) || leyline.Code(err) == "CANCELED") {
		fmt.Fprintln(os.Stderr, app.ErrorLine("interrupted"))
		return cli.ExitInterrupted
	}
	var ee *cli.ExitError
	if errors.As(err, &ee) {
		if ee.Message != "" {
			fmt.Fprintln(os.Stderr, app.ErrorLine(ee.Message))
		}
		return ee.Code
	}
	fmt.Fprintln(os.Stderr, app.ErrorLine(err.Error()))
	return 1
}
