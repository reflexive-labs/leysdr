// SPDX-License-Identifier: Apache-2.0

// Command leyeval runs the agent evals under evals/: each scenario stands up a daemon playing
// fixtures, points an agent at `ley mcp` on it, and grades the agent's answer and its tool calls
// (docs/dev/evals.md).
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"

	"github.com/reflexive-labs/leysdr/go/internal/eval"
)

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := newRoot().ExecuteContext(ctx); err != nil {
		fmt.Fprintln(os.Stderr, "leyeval:", err)
		os.Exit(1)
	}
}

func newRoot() *cobra.Command {
	root := &cobra.Command{
		Use:           "leyeval",
		Short:         "Run and read the agent evals against ley mcp",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.AddCommand(newRunCommand(), newShowCommand(), newCheckCommand())
	return root
}

func newRunCommand() *cobra.Command {
	var (
		env       eval.Env
		scenarios string
		out       string
		timeout   time.Duration
	)
	cmd := &cobra.Command{
		Use:   "run [scenario ...]",
		Short: "Run every scenario, or the ones named",
		Long: `run stands up a daemon per scenario, plays its fixtures as radios, starts the agent
with the leyline MCP server on that daemon, and grades what it did. Each run leaves a
directory under --out with messages.jsonl (the agent's stream), transcript.md (the
conversation, readable), prompt.md and result.json; the summary table is printed at the
end. Nothing here needs a radio or a person on the air.`,
		Example: `  leyeval run                         # every scenario in evals/scenarios
  leyeval run survey-2m --mode shell  # one scenario, with a shell available to the agent
  leyeval run --model claude-sonnet-5 # a different model`,
		RunE: func(cmd *cobra.Command, args []string) error {
			env.Timeout = timeout
			env.Log = func(format string, a ...any) { fmt.Fprintf(os.Stderr, format+"\n", a...) }
			if env.Daemon == "" {
				return fmt.Errorf("no daemon: set --daemon or LEYLINED_BIN to a built leylined")
			}
			all, err := eval.LoadDir(scenarios)
			if err != nil {
				return err
			}
			var chosen []*eval.Scenario
			if len(args) == 0 {
				chosen = all
			} else {
				for _, name := range args {
					found := false
					for _, s := range all {
						if s.Name == name {
							chosen = append(chosen, s)
							found = true
						}
					}
					if !found {
						return fmt.Errorf("no scenario named %q in %s", name, scenarios)
					}
				}
			}
			runDir := filepath.Join(out, time.Now().Format("2006-01-02T15-04-05"))
			if err := os.MkdirAll(runDir, 0o755); err != nil {
				return err
			}
			var results []*eval.Result
			for _, s := range chosen {
				if cmd.Context().Err() != nil {
					break
				}
				r := eval.Run(cmd.Context(), env, s, runDir)
				results = append(results, r)
				switch {
				case r.Skipped != "":
					env.Log("%s: skipped (%s)", s.Name, r.Skipped)
				case r.Error != "":
					env.Log("%s: error: %s", s.Name, r.Error)
				default:
					env.Log("%s: %d passed, %d failed; %s", s.Name, r.Passed, r.Failed, filepath.Join(r.Dir, "transcript.md"))
				}
			}
			fmt.Print(eval.Summary(results))
			fmt.Printf("\nrun directory: %s\n", runDir)
			for _, r := range results {
				if r.Failed > 0 || r.Error != "" {
					return fmt.Errorf("%d scenario(s) did not pass", countBad(results))
				}
			}
			return nil
		},
	}
	f := cmd.Flags()
	f.StringVar(&env.Daemon, "daemon", os.Getenv("LEYLINED_BIN"), "the leylined binary (default: $LEYLINED_BIN)")
	f.StringVar(&env.Ley, "ley", envOr("LEY_BIN", "ley"), "the ley binary the agent's MCP server and the setup steps run (default: $LEY_BIN, else ley on PATH)")
	f.StringVar(&env.Fixtures, "fixtures", envOr("LEYLINE_FIXTURES", "fixtures"), "where scenario fixtures are relative to")
	f.StringVar(&env.Decoders, "decoders", envOr("LEYLINE_DECODERS", "decoders"), "the decoder plugin directory the daemon searches; the plugin binaries must be on PATH")
	f.StringVar(&env.Claude, "claude", envOr("LEYEVAL_AGENT", "claude"), "the agent command; it gets Claude Code's headless flags and the prompt on stdin")
	f.StringVar(&env.Model, "model", "", "passed to the agent as --model (default: the agent's own)")
	f.StringVar(&env.Mode, "mode", "mcp", "mcp: the leyline tools alone; shell: a shell as well, to measure how often the agent leaves the tools")
	f.IntVar(&env.MaxTurns, "max-turns", 25, "the agent's turn budget unless the scenario sets one")
	f.DurationVar(&timeout, "timeout", 10*time.Minute, "how long one agent run may take")
	f.StringVar(&scenarios, "scenarios", "evals/scenarios", "the scenario directory")
	f.StringVar(&out, "out", "evals/runs", "where run directories go")
	return cmd
}

func countBad(results []*eval.Result) int {
	n := 0
	for _, r := range results {
		if r.Failed > 0 || r.Error != "" {
			n++
		}
	}
	return n
}

func newShowCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "show <run directory | messages.jsonl>",
		Short: "Render a saved message log as a transcript",
		Long: `show prints the transcript of a run: the checks, then the conversation with every
tool call and result. Given a run directory it uses the result.json beside the log; given
a bare messages.jsonl (an agent's stream-json saved by any means) it renders the
conversation alone.`,
		Example: `  leyeval show evals/runs/2026-09-17T18-00-00/survey-2m
  leyeval show some/messages.jsonl | less`,
		Args: cobra.ExactArgs(1),
		RunE: func(_ *cobra.Command, args []string) error {
			path := args[0]
			var res *eval.Result
			logPath := path
			if st, err := os.Stat(path); err == nil && st.IsDir() {
				logPath = filepath.Join(path, "messages.jsonl")
				if b, err := os.ReadFile(filepath.Join(path, "result.json")); err == nil {
					var r eval.Result
					if err := json.Unmarshal(b, &r); err == nil {
						res = &r
					}
				}
			}
			f, err := os.Open(logPath)
			if err != nil {
				return err
			}
			defer f.Close()
			log, err := eval.ParseStream(f)
			if err != nil {
				return err
			}
			fmt.Print(eval.Transcript(nil, res, log))
			return nil
		},
	}
}

func newCheckCommand() *cobra.Command {
	var scenarios string
	cmd := &cobra.Command{
		Use:   "check",
		Short: "Parse every scenario and say what each grades, without running anything",
		Example: `  leyeval check
  leyeval check --scenarios evals/scenarios`,
		RunE: func(_ *cobra.Command, _ []string) error {
			all, err := eval.LoadDir(scenarios)
			if err != nil {
				return err
			}
			for _, s := range all {
				fmt.Printf("%s: %d fixture(s), %d setup step(s), %d check(s)", s.Name, len(s.Fixtures), len(s.Setup), len(s.Checks))
				if s.Skip != "" {
					fmt.Printf(" (skipped: %s)", s.Skip)
				}
				fmt.Println()
				var kinds []string
				for _, c := range s.Checks {
					kinds = append(kinds, c.Type)
				}
				fmt.Printf("  %s\n", strings.Join(kinds, ", "))
			}
			return nil
		},
	}
	cmd.Flags().StringVar(&scenarios, "scenarios", "evals/scenarios", "the scenario directory")
	return cmd
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}
