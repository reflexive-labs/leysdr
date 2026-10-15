// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"strings"

	"github.com/spf13/cobra"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The features a model can be chosen for, in the order `ley ai` lists them.
var aiFeatures = leyline.AIFeatures

// providerName is how a provider is spelled: the lower-case name of a kind of endpoint
// (proto/leyline/v1/ai.proto, "Keys"), so "Anthropic" is refused rather than filed as a second
// provider.
var providerName = regexp.MustCompile(`^[a-z0-9][a-z0-9._-]*$`)

func checkProvider(p string) error {
	if !providerName.MatchString(p) {
		return usageErrorf("%q is not a provider name; providers are spelled in lower case, such as anthropic, openai or deepgram", p)
	}
	return nil
}

// newAICommand builds `ley ai`: the keys the daemon holds for model providers, the model each
// feature calls, and what the calls used. The daemon keeps the keys and never returns one, so
// every verb here reads or writes daemon state over the contract (proto/leyline/v1/ai.proto).
func newAICommand(app *App) *cobra.Command {
	cmd := &cobra.Command{
		Use:   "ai",
		Short: "Show the provider keys and the model each feature uses",
		Long: `ai lists the keys the daemon holds for model providers, and the provider
and model each feature calls. A key is stored by the daemon and never
printed or returned: the KEY column shows its last four characters, so two
keys can be told apart. LAST USED is when a worker last took the key for a
call; CHECKED is what the provider said when the key was last tried
(accepted, rejected, or unavailable when the check could not run).

'ley ai add <provider>' stores a key, reading it from stdin; 'ley ai check'
tries it again, 'ley ai remove' deletes it, 'ley ai use' chooses the model a
feature calls, and 'ley ai usage' prints what the calls used.

--json prints the AIState: every key's description (never its text) and
every feature's model.`,
		Example: `  ley ai add openai                    # paste a key; the assistant and speech use it
  ley ai                               # which keys are set, and do they work?
  ley ai use assistant anthropic       # switch a feature, with the default model
  ley ai usage                         # requests and tokens, last 30 days
  ley ai --json | jq -r '.credentials[].provider'`,
		GroupID: GroupDaemon,
		Args:    cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			return runAI(cmd.Context(), app)
		},
	}
	cmd.AddCommand(newAIAddCommand(app), newAICheckCommand(app), newAIRemoveCommand(app),
		newAIUseCommand(app), newAIUsageCommand(app))
	return cmd
}

func runAI(ctx context.Context, app *App) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	st, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		return app.printJSON(st)
	}
	_, err = io.WriteString(app.Stdout, renderAI(tableStyle(app), st))
	return err
}

// renderAI is `ley ai`: a table of keys, then a table of features. Every feature is listed
// whether or not a model was chosen for it, so the reader sees what can be set.
func renderAI(s ui.Style, st *leylinev1.AIState) string {
	var b strings.Builder
	keys := []column{
		{head: "PROVIDER"},
		{head: "LABEL", drop: 2, hideEmpty: true},
		{head: "KEY"},
		{head: "ENDPOINT", min: 12, drop: 3, hideEmpty: true},
		{head: "LAST USED", drop: 1},
		{head: "CHECKED", min: 12},
	}
	for _, cr := range st.GetCredentials() {
		used := s.Glyphs().Absent
		if cr.GetLastUsedAtNs() > 0 {
			used = recordingClock(cr.GetLastUsedAtNs())
		}
		add(keys, cr.GetProvider(), absentIfEmpty(s, cr.GetLabel()), keyHint(s, cr),
			absentIfEmpty(s, cr.GetEndpoint()), used, checkedCell(s, cr.GetLastCheck()))
	}
	_, _ = printColumns(&b, s, keys, nil)
	if len(st.GetCredentials()) == 0 {
		writeWrapped(&b, s, "(no keys; add one with: "+unbracketed(leyline.AddCommand("assistant"))+")")
	}
	b.WriteByte('\n')
	features := []column{{head: "FEATURE"}, {head: "PROVIDER"}, {head: "MODEL", min: 10}}
	var unset []string
	for _, f := range aiFeatures {
		provider, model := s.Glyphs().Absent, s.Glyphs().Absent
		for _, fm := range st.GetFeatures() {
			if fm.GetFeature() == f {
				provider, model = fm.GetProvider(), fm.GetModel()
			}
		}
		if provider == s.Glyphs().Absent {
			unset = append(unset, f)
		}
		add(features, f, provider, model)
	}
	_, _ = printColumns(&b, s, features, nil)
	// With no key the line above already says what to do first.
	if len(st.GetCredentials()) > 0 {
		for _, f := range unset {
			writeWrapped(&b, s, unsetHint(f, st.GetCredentials()))
		}
	}
	return b.String()
}

// unsetHint is the next step for a feature with no model, from the keys there are: the use
// that sets it, or the add of a key that can serve it.
func unsetHint(feature string, keys []*leylinev1.Credential) string {
	cmd := leyline.ChooseCommand(feature, keys)
	if strings.HasPrefix(cmd, "ley ai use ") {
		return fmt.Sprintf("(%s has no model; choose one with: %s)", feature, cmd)
	}
	return fmt.Sprintf("(%s has no model, and no key serves it; add one with: %s)", feature, unbracketed(cmd))
}

// unbracketed turns AddCommand's "ley ai add openai (or anthropic)" into "ley ai add openai, or
// anthropic", so a hint that is itself in brackets holds none.
func unbracketed(cmd string) string {
	head, others, ok := strings.Cut(cmd, " (or ")
	if !ok {
		return cmd
	}
	return head + ", or " + strings.TrimSuffix(others, ")")
}

// keyHint is the KEY cell: the key's last four characters behind an ellipsis, so it reads as the
// end of something longer. A key too short to show any of itself is the absent glyph.
func keyHint(s ui.Style, cr *leylinev1.Credential) string {
	if cr.GetLastFour() == "" {
		return s.Glyphs().Absent
	}
	return s.Glyphs().Ellipsis + cr.GetLastFour()
}

// keyWords names a key in a sentence: "anthropic key …1234".
func keyWords(s ui.Style, cr *leylinev1.Credential) string {
	if cr.GetLastFour() == "" {
		return cr.GetProvider() + " key"
	}
	return cr.GetProvider() + " key " + keyHint(s, cr)
}

// outcomeWord is a check's outcome as a person says it, inked by what it means.
func outcomeWord(s ui.Style, c *leylinev1.CredentialCheck) string {
	switch c.GetOutcome() {
	case leylinev1.CredentialCheck_ACCEPTED:
		return s.Ok("accepted")
	case leylinev1.CredentialCheck_REJECTED:
		return s.Err("rejected")
	case leylinev1.CredentialCheck_UNAVAILABLE:
		return s.Warn("unavailable")
	}
	return s.Glyphs().Absent
}

func checkedCell(s ui.Style, c *leylinev1.CredentialCheck) string {
	if c.GetAtNs() == 0 {
		return s.Glyphs().Absent
	}
	return outcomeWord(s, c) + " " + recordingClock(c.GetAtNs())
}

// writeWrapped writes a muted hint, wrapped to the style's width when it is known.
func writeWrapped(b *strings.Builder, s ui.Style, text string) {
	for _, line := range wrapWords(text, s.Width) {
		b.WriteString(s.Muted(line))
		b.WriteByte('\n')
	}
}

// wrapWords breaks text at spaces so no line is wider than width; a width of zero or less keeps
// it on one line, and a word longer than width gets a line of its own.
func wrapWords(text string, width int) []string {
	if width <= 0 {
		return []string{text}
	}
	var lines []string
	line := ""
	for _, w := range strings.Fields(text) {
		switch {
		case line == "":
			line = w
		case ui.Visible(line)+1+ui.Visible(w) <= width:
			line += " " + w
		default:
			lines = append(lines, line)
			line = w
		}
	}
	return append(lines, line)
}

func newAIAddCommand(app *App) *cobra.Command {
	var label, endpoint string
	cmd := &cobra.Command{
		Use:   "add <provider> [--label L] [--endpoint URL]",
		Short: "Store a provider key, read from stdin, and check it",
		Long: `add gives the daemon a key for a model provider and has it checked once
against the provider. The key is read from stdin, never from an argument or
the environment, because an argument is visible to every user in ps and the
environment is inherited by everything ley starts. On a terminal ley asks
for it and turns echo off while you paste it; otherwise it reads one line.
Spaces and the newline around the key are dropped.

The key replaces any key already stored for the provider. A key the
provider refuses is still stored, so the line printed afterwards says what
the provider answered and what to do next; the exit status is 0 either way.

Unless the provider refuses the key, every feature the provider serves and
that has no model yet gets the provider's default (openai: the assistant
gpt-5 and speech whisper-1; anthropic: the assistant claude-sonnet-5-5),
and the line says so. A model already chosen is kept; 'ley ai use'
changes one.

--label is a name for the key in 'ley ai' (which account it is), and
--endpoint points the provider at a gateway or an OpenAI-compatible server
in place of the provider's own API.

--json prints the stored Credential: its description and the check's
outcome, never the key.`,
		Example: `  ley ai add openai                            # paste at the prompt
  ley ai add anthropic --label work < ~/.config/anthropic.key
  pbpaste | ley ai add openai
  ley ai add openai --endpoint http://localhost:11434 --label ollama`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runAIAdd(cmd.Context(), app, args[0], label, endpoint)
		},
	}
	cmd.Flags().StringVar(&label, "label", "", "a name for the key in ley ai, e.g. --label work")
	cmd.Flags().StringVar(&endpoint, "endpoint", "", "a gateway or OpenAI-compatible server to call in place of the provider's own API")
	return cmd
}

func runAIAdd(ctx context.Context, app *App, provider, label, endpoint string) error {
	if err := checkProvider(provider); err != nil {
		return err
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	// Ask the daemon first, so nobody pastes a key into a verb that cannot store it. The state
	// is kept to tell afterwards which features the daemon gave this provider.
	before, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil {
		return app.notRunning(err)
	}
	secret, err := readKey(ctx, app, provider)
	if err != nil {
		return err
	}
	cred, err := c.Credentials.SetCredential(ctx, &leylinev1.SetCredentialRequest{
		Provider: provider, Secret: secret, Label: label, Endpoint: endpoint,
	})
	if err != nil {
		return app.notRunning(err)
	}
	line := addedLine(app.ErrStyle, cred)
	if after, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{}); err == nil {
		if set := newlySet(before, after, provider); len(set) > 0 {
			sep := ". "
			if cred.GetLastCheck().GetOutcome() != leylinev1.CredentialCheck_ACCEPTED {
				sep = "\n" // the line already ends with its own next command
			}
			line += sep + defaultsSentence(app.ErrStyle, set)
		}
	}
	fmt.Fprintln(app.Stderr, line)
	if app.JSON {
		return app.printJSON(cred)
	}
	return nil
}

// newlySet are the features that call provider in after and did not before: the ones the
// daemon gave the provider's default models when its key was added.
func newlySet(before, after *leylinev1.AIState, provider string) []*leylinev1.FeatureModel {
	was := map[string]string{}
	for _, f := range before.GetFeatures() {
		was[f.GetFeature()] = f.GetProvider() + "\x00" + f.GetModel()
	}
	var set []*leylinev1.FeatureModel
	for _, f := range after.GetFeatures() {
		if f.GetProvider() == provider && was[f.GetFeature()] != f.GetProvider()+"\x00"+f.GetModel() {
			set = append(set, f)
		}
	}
	return set
}

// defaultsSentence says which features now call the provider, with which models, and how to
// change them: "The assistant and speech now use openai (gpt-5, whisper-1); change one with ley
// ai use <feature> <provider> [<model>]".
func defaultsSentence(s ui.Style, set []*leylinev1.FeatureModel) string {
	var names, models []string
	for _, f := range set {
		names = append(names, leyline.FeatureWords(f.GetFeature()))
		models = append(models, f.GetModel())
	}
	subject := strings.Join(names, " and ")
	subject = strings.ToUpper(subject[:1]) + subject[1:]
	if len(set) == 1 {
		return fmt.Sprintf("%s now uses %s (%s); change it with %s", subject, set[0].GetProvider(), models[0],
			s.Cmd("ley ai use "+set[0].GetFeature()+" <provider> [<model>]"))
	}
	return fmt.Sprintf("%s now use %s (%s); change one with %s", subject, set[0].GetProvider(),
		strings.Join(models, ", "), s.Cmd("ley ai use <feature> <provider> [<model>]"))
}

// addedLine reports a stored key and what the provider said about it, ending with the next
// command when the key does not work yet.
func addedLine(s ui.Style, cred *leylinev1.Credential) string {
	key, p := keyWords(s, cred), cred.GetProvider()
	chk := cred.GetLastCheck()
	switch chk.GetOutcome() {
	case leylinev1.CredentialCheck_ACCEPTED:
		return fmt.Sprintf("%s added; the provider %s it", key, s.Ok("accepted"))
	case leylinev1.CredentialCheck_REJECTED:
		return fmt.Sprintf("%s added; the provider %s it: %s. Paste a working key with: %s",
			key, s.Err("rejected"), oneLine(chk.GetMessage()), s.Cmd("ley ai add "+p))
	}
	return fmt.Sprintf("%s added; the check %s: %s. Try it again with: %s",
		key, s.Warn("could not run"), oneLine(chk.GetMessage()), s.Cmd("ley ai check "+p))
}

// oneLine keeps a provider's message to one line, and gives an empty one a word.
func oneLine(msg string) string {
	msg = strings.Join(strings.Fields(msg), " ")
	if msg == "" {
		return "no reason given"
	}
	return msg
}

// readKey reads one line from stdin. On a terminal it prompts on stderr and turns echo off for
// the line, so the key is never on the screen; Ctrl-C while it waits ends the verb.
func readKey(ctx context.Context, app *App, provider string) (string, error) {
	tty := app.IsInTTY()
	if tty {
		quiet := app.echoOff
		if quiet == nil {
			quiet = echoOff
		}
		// A key typed with echo on would sit on the screen and in the scrollback, so a terminal
		// that will not turn echo off is refused rather than read.
		restore, err := quiet(app.Stdin)
		if err != nil {
			return "", usageErrorf("cannot turn echo off on this terminal (%v), so the key would show as you paste it; pipe it in instead: pbpaste | ley ai add %s", err, provider)
		}
		defer restore()
		fmt.Fprintf(app.Stderr, "Paste the %s key and press Enter: ", provider)
		// With echo off the Enter is not shown either, so the next line would start mid-prompt.
		defer fmt.Fprintln(app.Stderr)
	}
	type read struct {
		line string
		err  error
	}
	got := make(chan read, 1)
	go func() {
		line, err := bufio.NewReader(app.Stdin).ReadString('\n')
		got <- read{line, err}
	}()
	var r read
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case r = <-got:
	}
	if r.err != nil && !errors.Is(r.err, io.EOF) {
		return "", fmt.Errorf("cannot read the key from stdin: %w", r.err)
	}
	key := strings.TrimSpace(r.line)
	if key != "" {
		return key, nil
	}
	if tty {
		return "", usageErrorf("no key was entered; run ley ai add %s again and paste the key at the prompt", provider)
	}
	return "", usageErrorf("stdin held no key; pipe one in: ley ai add %s < %s.key", provider, provider)
}

// echoOff turns echo off on stdin when it is a terminal file.
func echoOff(r io.Reader) (restore func(), err error) {
	f, ok := r.(*os.File)
	if !ok {
		return nil, errors.New("stdin is not a file")
	}
	return noEcho(int(f.Fd()))
}

func newAICheckCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "check <provider>",
		Short: "Try a stored key against its provider again",
		Long: `check has the daemon try the provider's stored key again, the same check
'ley ai add' runs, and records the answer in the CHECKED column of 'ley ai'.

It exits 0 when the provider accepts the key and 1 otherwise: for a refused
key it prints the provider's words and the command that replaces the key,
and for a check that could not run (the provider unreachable, no worker to
run it) it says why. A check that could not run says nothing about the key
itself.

--json prints the Credential with the new outcome in lastCheck; the exit
status follows the same rule.`,
		Example: `  ley ai check anthropic
  ley ai check openai --json | jq -r .lastCheck.outcome`,
		Args: cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runAICheck(cmd.Context(), app, args[0])
		},
	}
}

func runAICheck(ctx context.Context, app *App, provider string) error {
	if err := checkProvider(provider); err != nil {
		return err
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	cred, err := c.Credentials.CheckCredential(ctx, &leylinev1.CredentialRef{Provider: provider})
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		if err := app.printJSON(cred); err != nil {
			return err
		}
	}
	s := app.ErrStyle
	key, said := keyWords(ui.Style{Unicode: s.Unicode}, cred), oneLine(cred.GetLastCheck().GetMessage())
	switch cred.GetLastCheck().GetOutcome() {
	case leylinev1.CredentialCheck_ACCEPTED:
		fmt.Fprintf(app.Stderr, "%s: the provider %s it\n", keyWords(s, cred), s.Ok("accepted"))
		return nil
	case leylinev1.CredentialCheck_REJECTED:
		// The exit status comes from the outcome: the daemon answers a refused key with the
		// credential, not an error, because the check itself worked.
		return &ExitError{Code: 1, Message: fmt.Sprintf("the provider rejected the %s: %s. Paste a working key with: ley ai add %s",
			key, said, provider)}
	}
	return &ExitError{Code: 1, Message: fmt.Sprintf("could not check the %s: %s. Run: ley ai check %s", key, said, provider)}
}

func newAIRemoveCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "remove <provider>",
		Short: "Delete a provider's key from the daemon",
		Long: `remove deletes the provider's key from the daemon. Every job that calls
the provider ends with CREDENTIAL_MISSING, because it can make no further
call. The model a feature uses stays chosen, so 'ley ai add' with a new key
puts the feature back to work.

--json prints {} once the key is gone.`,
		Example: `  ley ai remove anthropic`,
		Args:    cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runAIRemove(cmd.Context(), app, args[0])
		},
	}
}

func runAIRemove(ctx context.Context, app *App, provider string) error {
	if err := checkProvider(provider); err != nil {
		return err
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	done, err := c.Credentials.DeleteCredential(ctx, &leylinev1.CredentialRef{Provider: provider})
	if err != nil {
		return app.notRunning(err)
	}
	fmt.Fprintf(app.Stderr, "%s the %s key; any job that used it has ended\n", app.ErrStyle.Ok("Removed"), provider)
	if app.JSON {
		return app.printJSON(done)
	}
	return nil
}

func newAIUseCommand(app *App) *cobra.Command {
	return &cobra.Command{
		Use:   "use [<feature>] <provider> [<model>]",
		Short: "Choose the provider and model a feature calls",
		Long: `use sets the provider and model a feature calls: assistant is the
assistant that runs the radio for you, speech is speech-to-text on received
audio.

With a provider alone, every feature the provider serves calls it, with the
provider's default model (openai: the assistant gpt-5 and speech
whisper-1; anthropic: the assistant claude-sonnet-5-5). With a feature and a
provider, that feature calls it with the default model. A provider and a
model with no feature is taken when the provider serves one feature, and
refused when it serves two, since the model could be either's.

The model is the provider's own name for it, passed on as typed, so a model
the provider has not heard of fails on the first call rather than here. A
provider that cannot serve the feature is refused here, naming those that
can: speech is served by openai and by the provider of any speech decoder
installed, and a provider ley does not know serves the assistant as an
OpenAI-compatible server, at the endpoint its key was added with.

A model can be chosen before the provider's key is added; ley says so and
prints the command that adds it.

--json prints the FeatureModel the daemon stored, one line per feature.`,
		Example: `  ley ai use openai                                # the assistant and speech
  ley ai use assistant anthropic                   # its default model
  ley ai use assistant anthropic claude-opus-5-5
  ley ai use assistant ollama llama3               # added with --endpoint`,
		Args: cobra.RangeArgs(1, 3),
		RunE: func(cmd *cobra.Command, args []string) error {
			return runAIUse(cmd.Context(), app, args)
		},
	}
}

// useChoices turns use's arguments into the feature models to set, filling in the default
// models (leyline.ProviderDefaults). Whether the provider can serve each feature is the daemon's
// to say: it knows which speech decoders are installed.
func useChoices(args []string) ([]*leylinev1.FeatureModel, error) {
	if leyline.IsAIFeature(args[0]) && len(args) == 1 {
		return nil, usageErrorf("name the provider %s should call: %s", leyline.FeatureWords(args[0]),
			leyline.ChooseCommand(args[0], nil))
	}
	// Three words start with a feature, and so do two whose second is a provider: a typo in the
	// feature must not become a provider called "assistnat".
	if !leyline.IsAIFeature(args[0]) && (len(args) == 3 || len(args) == 2 && leyline.IsKnownProvider(args[1])) {
		return nil, usageErrorf("no feature named %q; the features are %s", args[0], strings.Join(aiFeatures, " and "))
	}
	for _, p := range args[:min(len(args), 2)] {
		if !leyline.IsAIFeature(p) {
			if err := checkProvider(p); err != nil {
				return nil, err
			}
		}
	}
	choice := func(feature, provider, model string) ([]*leylinev1.FeatureModel, error) {
		if model == "" {
			model = leyline.DefaultModel(provider, feature)
		}
		if model == "" {
			return nil, usageErrorf("%s has no default model for %s; name one: ley ai use %s %s <model>",
				provider, leyline.FeatureWords(feature), feature, provider)
		}
		return []*leylinev1.FeatureModel{{Feature: feature, Provider: provider, Model: model}}, nil
	}
	switch {
	case len(args) == 3:
		return choice(args[0], args[1], args[2])
	case leyline.IsAIFeature(args[0]):
		return choice(args[0], args[1], "")
	}
	provider := args[0]
	served := leyline.TableFeatures(provider)
	if !leyline.IsKnownProvider(provider) {
		served = []string{"assistant"} // an OpenAI-compatible server
	}
	if len(args) == 2 {
		if len(served) > 1 {
			return nil, usageErrorf("%s could be a model for %s, since %s serves both; say which: ley ai use %s %s %s",
				args[1], strings.Join(served, " or "), provider, served[0], provider, args[1])
		}
		return choice(served[0], provider, args[1])
	}
	var out []*leylinev1.FeatureModel
	for _, f := range served {
		fm, err := choice(f, provider, "")
		if err != nil {
			return nil, err
		}
		out = append(out, fm...)
	}
	return out, nil
}

func runAIUse(ctx context.Context, app *App, args []string) error {
	choices, err := useChoices(args)
	if err != nil {
		return err
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	var set []*leylinev1.FeatureModel
	for _, want := range choices {
		fm, err := c.Credentials.SetFeatureModel(ctx, want)
		if err != nil {
			return app.notRunning(err)
		}
		set = append(set, fm)
		fmt.Fprintf(app.Stderr, "%s now calls %s %s\n", fm.GetFeature(), fm.GetProvider(), fm.GetModel())
	}
	s, provider := app.ErrStyle, choices[0].GetProvider()
	if st, err := c.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{}); err == nil && !hasKey(st, provider) {
		fmt.Fprintf(app.Stderr, "  %s %s\n", s.Muted("no "+provider+" key is set yet; add one with:"), s.Cmd("ley ai add "+provider))
	}
	if !app.JSON {
		return nil
	}
	for _, fm := range set {
		if err := app.printJSON(fm); err != nil {
			return err
		}
	}
	return nil
}

func hasKey(st *leylinev1.AIState, provider string) bool {
	for _, cr := range st.GetCredentials() {
		if cr.GetProvider() == provider {
			return true
		}
	}
	return false
}
