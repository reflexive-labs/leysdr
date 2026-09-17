// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

// mcpConfig is the file the agent is pointed at: one server, `ley mcp` on the eval daemon's
// socket. The agent's client starts it as a subprocess, the way a person's would.
func mcpConfig(dir, ley, socket string) (string, error) {
	cfg := map[string]any{
		"mcpServers": map[string]any{
			"leyline": map[string]any{"command": ley, "args": []string{"--socket", socket, "mcp"}},
		},
	}
	raw, _ := json.MarshalIndent(cfg, "", "  ")
	path := filepath.Join(dir, "mcp.json")
	return path, os.WriteFile(path, raw, 0o644)
}

// runAgent runs the agent on the prompt and returns its stream. The arguments are Claude Code's
// headless ones and the prompt goes on stdin, which is what --print reads: the tool lists are
// variadic flags and would swallow a prompt placed after them. A fake agent (tests) sees the
// same argument list and reads the same stdin.
func runAgent(ctx context.Context, env Env, dir, prompt, mode string, maxTurns int, mcpPath string) (*Log, []byte, error) {
	args := []string{
		"-p", "--output-format", "stream-json", "--verbose",
		"--mcp-config", mcpPath, "--strict-mcp-config",
		"--max-turns", strconv.Itoa(maxTurns),
	}
	if env.Model != "" {
		args = append(args, "--model", env.Model)
	}
	// The variadic flags last, so nothing can follow them.
	if mode == "mcp" {
		args = append(args, "--allowedTools", "mcp__leyline__*",
			"--disallowedTools", "Bash", "Read", "Write", "Edit", "Glob", "Grep", "WebFetch", "WebSearch", "Agent")
	} else {
		args = append(args, "--allowedTools", "mcp__leyline__*", "Bash")
	}
	cmd := exec.CommandContext(ctx, env.Claude, args...)
	cmd.Stdin = strings.NewReader(prompt)
	// The agent runs in the run directory, which holds nothing but this run: an agent given a
	// shell should not find the repository's answer keys beside it.
	cmd.Dir = dir
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err := cmd.Run()
	log, perr := ParseStream(bytes.NewReader(stdout.Bytes()))
	if perr != nil {
		return log, stdout.Bytes(), perr
	}
	if err != nil && len(log.Events) == 0 {
		return log, stdout.Bytes(), fmt.Errorf("%s: %v\n%s", env.Claude, err, stderr.String())
	}
	if stderr.Len() > 0 {
		_ = os.WriteFile(filepath.Join(dir, "agent-stderr.txt"), stderr.Bytes(), 0o644)
	}
	return log, stdout.Bytes(), nil
}
