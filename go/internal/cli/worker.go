// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/assistant"
)

// The workers are the processes the daemon spawns to make a call on the user's key. Each one reads the key from stdin -- an argument is
// visible in ps, and the environment is inherited by whatever the worker runs -- and reports
// what the call used with Usage.ReportUsage, over the socket like any client.

// workerHTTPTimeout bounds one call to a provider, so a check never holds the daemon's RPC for
// longer than a person would wait at `ley ai add`.
const workerHTTPTimeout = 15 * time.Second

// checkModelsPath is what a check calls, and the model its usage report names, so the ledger
// shows which endpoint was called.
const checkModelsPath = "/v1/models"

// Default API bases for the providers the check knows without an endpoint.
const (
	anthropicAPI = "https://api.anthropic.com"
	openaiAPI    = "https://api.openai.com"
)

// checkResult is the check worker's one line on stdout.
type checkResult struct {
	Outcome string `json:"outcome"` // accepted, rejected or unavailable
	Message string `json:"message"`
}

func newWorkerCommand(app *App) *cobra.Command {
	cmd := &cobra.Command{
		Use:    "worker",
		Short:  "Processes the daemon runs to call a model provider",
		Long:   `worker holds the processes the daemon starts to make a call on a provider key. They are not meant to be run by hand.`,
		Hidden: true,
		Args:   cobra.NoArgs,
	}
	cmd.AddCommand(newWorkerCheckCommand(app), newWorkerAssistantCommand(app))
	return cmd
}

func newWorkerAssistantCommand(app *App) *cobra.Command {
	var conversation string
	cmd := &cobra.Command{
		Use:   "assistant --conversation ID",
		Short: "Run the assistant for one conversation the daemon holds",
		Long: `assistant is the worker the daemon starts for each assistant conversation. With
LEYLINE_KEY_ON_STDIN=1 it reads the provider's key from stdin as one
SetCredentialRequest, then a WorkerStart and the conversation's events, each
varint-delimited; it writes the assistant's turns on stdout the same way, and
logs on stderr. It drives the radio through the ley mcp tools over the
daemon's socket, as client kind mcp with the label assistant.
It appends the model transcript to WorkerStart's transcript path, one message
a line, and with resume loads it before the first call.
LEY_ASSISTANT_SCRIPT names a file of scripted model responses, one JSON object
a line, which tests play in place of a provider; LEY_ASSISTANT_RECORD names a
file the scripted model appends the messages of each call to. It exits 0 when
stdin closes.`,
		Example: `  ley worker assistant --conversation conv_01K...   # the daemon runs this`,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if app.JSON {
				return noJSONErrorf("worker assistant", "it speaks the worker protocol on stdin and stdout, which is protobuf already")
			}
			return assistant.Run(cmd.Context(), assistant.Options{
				Stdin: app.Stdin, Stdout: app.Stdout, Stderr: app.Stderr, LookupEnv: app.LookupEnv,
				Conversation: conversation,
				NewToolServer: func(ctx context.Context, socket string) (*mcp.Server, func(), error) {
					return NewAssistantToolServer(ctx, socket, app.LookupEnv, app.Stderr)
				},
			})
		},
	}
	cmd.Flags().StringVar(&conversation, "conversation", "", "the conversation this worker runs, so it shows in ps and in the log")
	return cmd
}

func newWorkerCheckCommand(app *App) *cobra.Command {
	var provider, endpoint string
	cmd := &cobra.Command{
		Use:   "check --provider P [--endpoint URL]",
		Short: "Try the key on stdin against its provider",
		Long: `check reads a key from stdin, asks the provider to list its models with it,
and prints one JSON line: {"outcome": "accepted" | "rejected" |
"unavailable", "message": "..."}. It exits 0 whenever it printed the line,
and 2 for a usage error before it.`,
		Example: `  printf %s "$KEY" | ley worker check --provider anthropic`,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runWorkerCheck(cmd.Context(), app, provider, endpoint)
		},
	}
	cmd.Flags().StringVar(&provider, "provider", "", "the provider the key is for: anthropic, openai, or any OpenAI-compatible server with --endpoint")
	cmd.Flags().StringVar(&endpoint, "endpoint", "", "the server to call in place of the provider's own API")
	return cmd
}

func runWorkerCheck(ctx context.Context, app *App, provider, endpoint string) error {
	if provider == "" {
		return usageErrorf("worker check needs --provider")
	}
	line, err := bufio.NewReader(app.Stdin).ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return usageErrorf("cannot read the key from stdin: %v", err)
	}
	secret := strings.TrimSpace(line)
	if secret == "" {
		return usageErrorf("worker check reads the key from stdin, and stdin held none")
	}
	res, called := checkKey(ctx, newCheckClient(), provider, endpoint, secret)
	// A gateway may echo the request back in its refusal, header and all; the message travels on
	// into last_check, every listing and the event plane, so the key is cut out of it here.
	res.Message = strings.ReplaceAll(res.Message, secret, "…")
	b, err := json.Marshal(res)
	if err != nil {
		return err
	}
	if _, err := fmt.Fprintf(app.Stdout, "%s\n", b); err != nil {
		return err
	}
	if called {
		reportCheckUsage(ctx, app, provider)
	}
	return nil
}

// newCheckClient is the check's HTTP client. It never follows a redirect, because Go re-sends
// x-api-key and Authorization to a redirect's host when they were set by hand, and the key must
// reach no host but the one the check names.
func newCheckClient() *http.Client {
	return &http.Client{
		Timeout:       workerHTTPTimeout,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
}

// checkKey asks the provider to list its models with the key. called reports whether a provider
// answered, so a request that never left this machine is not counted against the account.
func checkKey(ctx context.Context, hc *http.Client, provider, endpoint, secret string) (res checkResult, called bool) {
	req, err := checkRequest(ctx, provider, endpoint, secret)
	if err != nil {
		return checkResult{Outcome: "unavailable", Message: err.Error()}, false
	}
	resp, err := hc.Do(req)
	if err != nil {
		return checkResult{Outcome: "unavailable", Message: oneLineCapped(err.Error())}, false
	}
	defer func() { _ = resp.Body.Close() }()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	switch resp.StatusCode {
	case http.StatusOK:
		return checkResult{Outcome: "accepted"}, true
	case http.StatusUnauthorized, http.StatusForbidden:
		return checkResult{Outcome: "rejected", Message: providerMessage(resp, body)}, true
	}
	if resp.StatusCode >= 300 && resp.StatusCode < 400 {
		to := "another address"
		if loc, err := resp.Location(); err == nil {
			to = loc.Host
		}
		return checkResult{Outcome: "unavailable", Message: "redirected to " + to}, true
	}
	msg := resp.Status
	if said := providerMessage(resp, body); said != resp.Status {
		msg += ": " + said
	}
	return checkResult{Outcome: "unavailable", Message: oneLineCapped(msg)}, true
}

// checkRequest builds the models call: Anthropic's own headers for anthropic, a bearer token
// for OpenAI and every OpenAI-compatible server.
func checkRequest(ctx context.Context, provider, endpoint, secret string) (*http.Request, error) {
	base := strings.TrimRight(endpoint, "/")
	switch {
	case base != "":
	case provider == "anthropic":
		base = anthropicAPI
	case provider == "openai":
		base = openaiAPI
	default:
		return nil, fmt.Errorf("no check for provider %s", provider)
	}
	// An OpenAI-compatible base URL is often written with its /v1 already on it.
	url := strings.TrimSuffix(base, "/v1") + checkModelsPath
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, fmt.Errorf("the endpoint %q is not a URL: %w", endpoint, err)
	}
	if provider == "anthropic" {
		req.Header.Set("x-api-key", secret)
		req.Header.Set("anthropic-version", "2023-06-01")
	} else {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	return req, nil
}

// providerMessage is the provider's own words for a refusal: the message in its error body
// (Anthropic and OpenAI both send {"error": {"message": ...}}), else the body as text, else the
// status line.
func providerMessage(resp *http.Response, body []byte) string {
	var shaped struct {
		Error struct {
			Message string `json:"message"`
		} `json:"error"`
	}
	msg := ""
	if json.Unmarshal(body, &shaped) == nil {
		msg = shaped.Error.Message
	} else {
		msg = string(body)
	}
	if strings.TrimSpace(msg) == "" {
		msg = resp.Status
	}
	return oneLineCapped(msg)
}

// oneLineCapped folds a message onto one line of at most 200 characters, the length `ley ai`
// prints a provider's words in.
func oneLineCapped(msg string) string {
	msg = strings.Join(strings.Fields(msg), " ")
	if r := []rune(msg); len(r) > 200 {
		msg = string(r[:199]) + "…"
	}
	return msg
}

// reportCheckUsage adds the check to the ledger: one request, under the endpoint it called. A
// daemon that cannot be reached is noted on stderr and changes nothing about the outcome.
func reportCheckUsage(ctx context.Context, app *App, provider string) {
	rctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	c, err := app.dial(rctx)
	if err == nil {
		defer c.Close()
		_, err = c.Usage.ReportUsage(rctx, &leylinev1.UsageReport{
			Provider: provider, Model: checkModelsPath, Feature: "check", Requests: 1,
		})
	}
	if err != nil {
		fmt.Fprintf(app.Stderr, "ley worker: the check's usage was not reported: %v\n", err)
	}
}
