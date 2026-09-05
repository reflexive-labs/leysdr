package cli

import (
	"fmt"
	"runtime"

	"github.com/spf13/cobra"
)

func newVersionCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the ley version",
		Long: `version prints the version of this ley binary and the Go toolchain it was
built with. The daemon's own version is in 'ley daemon status'.`,
		Example: `  ley version              # ley 0.1.0 (go1.25 darwin/arm64)
  ley version --json       # {"version": ..., "go": ..., "os": ..., "arch": ...}`,
		GroupID: GroupDaemon,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			if app.JSON {
				_, err := fmt.Fprintf(app.Stdout, "{\"version\":%q,\"go\":%q,\"os\":%q,\"arch\":%q}\n", Version, runtime.Version(), runtime.GOOS, runtime.GOARCH)
				return err
			}
			_, err := fmt.Fprintf(app.Stdout, "ley %s (%s %s/%s)\n", Version, runtime.Version(), runtime.GOOS, runtime.GOARCH)
			return err
		},
	}
}
