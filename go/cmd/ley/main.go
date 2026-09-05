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

	"github.com/dpup/leysdr/go/internal/cli"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	exe, _ := os.Executable()
	app := &cli.App{Stdout: os.Stdout, Stderr: os.Stderr, Executable: exe}
	os.Exit(exitStatus(ctx, cli.Execute(ctx, app, os.Args[1:])))
}

// exitStatus maps Execute's error to a process status: Ctrl-C is 130 whether
// it landed during setup or the live phase, verbs may carry their own code
// via cli.ExitError, everything else is 1.
func exitStatus(ctx context.Context, err error) int {
	if err == nil {
		return 0
	}
	if errors.Is(err, context.Canceled) && ctx.Err() != nil {
		fmt.Fprintln(os.Stderr, "ley: interrupted")
		return cli.ExitInterrupted
	}
	var ee *cli.ExitError
	if errors.As(err, &ee) {
		if ee.Message != "" {
			fmt.Fprintln(os.Stderr, "ley:", ee.Message)
		}
		return ee.Code
	}
	fmt.Fprintln(os.Stderr, "ley:", err)
	return 1
}
