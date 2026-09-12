// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"fmt"

	"github.com/spf13/cobra"
)

// stub describes a verb on the roadmap that does not exist yet. Stubs are
// hidden from --help (they are listed by `ley help roadmap`), exit 2 with the
// milestone and today's workaround, and never talk to the daemon.
type stub struct {
	use, short, milestone, today string
}

// Stubs is the roadmap table: verbs that are planned but not implemented.
var Stubs = []stub{
	{
		use:       "record",
		short:     "Record a channel or the raw capture to a file",
		milestone: "Milestone C.12",
		today:     "ley play <file> plays back an IQ recording; recording is a daemon job and is not in this build",
	},
}

// stubMessage is the exit-2 line a stub prints.
func stubMessage(s stub) string {
	return fmt.Sprintf("%s is not implemented yet (%s). Today: %s", s.use, s.milestone, s.today)
}

// newStubCommands builds the hidden roadmap verbs.
func newStubCommands(_ *App) []*cobra.Command {
	var cmds []*cobra.Command
	for _, s := range Stubs {
		s := s
		cmds = append(cmds, &cobra.Command{
			Use:     s.use,
			Short:   s.short + " (not yet: " + s.milestone + ")",
			Long:    stubMessage(s) + ".",
			Example: "  ley help roadmap        # what is planned and when",
			Hidden:  true,
			GroupID: GroupLooking,
			Args:    cobra.ArbitraryArgs,
			// Whatever flags the newcomer typed (ley record --audio) must reach the message,
			// not Cobra's "unknown flag".
			DisableFlagParsing: true,
			RunE: func(_ *cobra.Command, _ []string) error {
				return &ExitError{Code: ExitUsage, Message: stubMessage(s)}
			},
		})
	}
	return cmds
}
