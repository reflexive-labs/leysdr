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

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
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
	cmd.AddCommand(newWorkerCheckCommand(app))
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
	res, called := checkKey(ctx, &http.Client{Timeout: workerHTTPTimeout}, provider, endpoint, secret)
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
			Provider: provider, Model: checkModelsPath, Feature: "check", Requests: 1, AtNs: time.Now().UnixNano(),
		})
	}
	if err != nil {
		fmt.Fprintf(app.Stderr, "ley worker: the check's usage was not reported: %v\n", err)
	}
}
