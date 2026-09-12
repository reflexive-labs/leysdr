// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"encoding/json"
	"fmt"
	"runtime"

	"github.com/spf13/cobra"
)

// versionInfo is the `ley version --json` document: a client-local value with
// no proto message, so it is the second named exception to the proto3 JSON
// mapping (docs/interfaces.md). Key order is part of the contract.
type versionInfo struct {
	Version string `json:"version"`
	Go      string `json:"go"`
	OS      string `json:"os"`
	Arch    string `json:"arch"`
}

func newVersionCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print the ley version",
		Long: `version prints the version of this ley binary and the Go toolchain it was
built with. The daemon's own version is in 'ley daemon status'.

A version with a '+' carries the git description of the tree it was built
from; only a build of the tagged commit prints the bare number.

--json prints {"version","go","os","arch"}: a client-local document, not a
proto message.`,
		Example: `  ley version              # ley 0.1.0+3-gd34db33 (go1.25 darwin/arm64)
  ley version --json       # {"version": ..., "go": ..., "os": ..., "arch": ...}`,
		GroupID: GroupDaemon,
		Args:    cobra.NoArgs,
		RunE: func(_ *cobra.Command, _ []string) error {
			if app.JSON {
				b, err := json.Marshal(versionInfo{Version: Version, Go: runtime.Version(), OS: runtime.GOOS, Arch: runtime.GOARCH})
				if err != nil {
					return err
				}
				_, err = fmt.Fprintf(app.Stdout, "%s\n", b)
				return err
			}
			// One line, one fact: the version leads plain and the build
			// details behind it are diagnostics, so they dim. Same bytes:
			// this is what bug reports paste and scripts head -1.
			build := app.Style.Muted(fmt.Sprintf("(%s %s/%s)", runtime.Version(), runtime.GOOS, runtime.GOARCH))
			_, err := fmt.Fprintf(app.Stdout, "%s %s %s\n", app.Style.Label("ley"), Version, build)
			return err
		},
	}
}
