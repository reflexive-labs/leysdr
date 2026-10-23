// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"sort"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/internal/words"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// `ley ask --list` and `ley ask --delete`: the conversations the daemon keeps on disk, which
// outlive the ask that started them and the daemon that ran them.

// listConversations is every conversation the daemon keeps, the one used last first.
func listConversations(ctx context.Context, c *leyline.Client) ([]*leylinev1.Conversation, error) {
	resp, err := c.Assistant.ListConversations(ctx, &leylinev1.ListConversationsRequest{})
	if err != nil {
		return nil, err
	}
	list := resp.GetConversations()
	sort.SliceStable(list, func(i, j int) bool { return lastUsedNs(list[i]) > lastUsedNs(list[j]) })
	return list, nil
}

// lastUsedNs is when the conversation last changed hands: its last turn, or its start.
func lastUsedNs(cv *leylinev1.Conversation) int64 {
	if ns := cv.GetLastTurnAtNs(); ns != 0 {
		return ns
	}
	return cv.GetStartedAtNs()
}

func runAskList(ctx context.Context, app *App) error {
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	list, err := listConversations(ctx, c)
	if err != nil {
		return app.notRunning(err)
	}
	if app.JSON {
		return app.printJSON(&leylinev1.ListConversationsResponse{Conversations: list})
	}
	_, err = io.WriteString(app.Stdout, renderConversations(tableStyle(app), list))
	return err
}

// renderConversations is the --list table. The id and the first words tell conversations apart,
// so they stay at any width; the times go first when the terminal is narrow.
func renderConversations(s ui.Style, list []*leylinev1.Conversation) string {
	cols := []column{
		// A ULID starts with its millisecond, so the id cut to that is still one --delete takes.
		{head: "ID", min: len("conv_") + 10 + 1},
		{head: "STARTED", drop: 2},
		{head: "LAST TURN", drop: 1},
		{head: "STATE"},
		{head: "FIRST WORDS", min: len("FIRST WORDS")},
	}
	for _, cv := range list {
		last := s.Glyphs().Absent
		if cv.GetLastTurnAtNs() != 0 {
			last = recordingClock(cv.GetLastTurnAtNs())
		}
		add(cols, s.Muted(cv.GetConversationId()), recordingClock(cv.GetStartedAtNs()), last,
			inkState(s, conversationStateWord(cv.GetState())), absentIfEmpty(s, firstWords(cv)))
	}
	var b strings.Builder
	_, _ = printColumns(&b, s, cols, nil)
	if len(list) == 0 {
		writeWrapped(&b, s, `(no conversations; start one with: ley ask "what is on 2m?")`)
	}
	return b.String()
}

// conversationStateWord is a conversation's state as the table shows it.
func conversationStateWord(st leylinev1.ConversationState) string {
	switch st {
	case leylinev1.ConversationState_CONVERSATION_IDLE:
		return "idle"
	case leylinev1.ConversationState_CONVERSATION_THINKING:
		return "thinking"
	case leylinev1.ConversationState_CONVERSATION_WAITING:
		return "waiting"
	case leylinev1.ConversationState_CONVERSATION_ENDED:
		return "ended"
	case leylinev1.ConversationState_CONVERSATION_FAILED:
		return "failed"
	}
	return "-"
}

// firstWords is the first thing the user asked, on one line.
func firstWords(cv *leylinev1.Conversation) string {
	for _, t := range cv.GetTurns() {
		if t.GetRole() == leylinev1.Role_ROLE_USER {
			return strings.Join(strings.Fields(t.GetText()), " ")
		}
	}
	return ""
}

// runAskDelete deletes one conversation, asking first on a terminal.
func runAskDelete(ctx context.Context, app *App, ref string, yes bool) error {
	if strings.TrimSpace(ref) == "" {
		return usageErrorf("--delete needs a conversation id; ley ask --list lists them")
	}
	if !yes && !app.IsInTTY() {
		return usageErrorf("stdin is not a terminal, so nobody can confirm the delete. Run: ley ask --delete %s --yes", ref)
	}
	c, err := app.dial(ctx)
	if err != nil {
		return app.notRunning(err)
	}
	defer c.Close()
	list, err := listConversations(ctx, c)
	if err != nil {
		return app.notRunning(err)
	}
	cv, err := findConversation(list, strings.TrimSpace(ref))
	if err != nil {
		return err
	}
	id := cv.GetConversationId()
	if !yes {
		fmt.Fprintf(app.Stderr, "Delete %s? [y/N] ", conversationSummary(app.ErrStyle, cv))
		answer, _ := bufio.NewReader(app.Stdin).ReadString('\n')
		if a := strings.ToLower(strings.TrimSpace(answer)); a != "y" && a != "yes" {
			fmt.Fprintln(app.Stderr, "Kept "+id+"; nothing was deleted.")
			return nil
		}
	}
	done, err := c.Assistant.DeleteConversation(ctx, &leylinev1.ConversationRef{ConversationId: id})
	if err != nil {
		return app.notRunning(err)
	}
	fmt.Fprintf(app.Stderr, "%s %s\n", app.ErrStyle.Ok("Deleted"), id)
	if app.JSON {
		return app.printJSON(done)
	}
	return nil
}

// findConversation is the one conversation whose id is ref or starts with it.
func findConversation(list []*leylinev1.Conversation, ref string) (*leylinev1.Conversation, error) {
	var matches []*leylinev1.Conversation
	for _, cv := range list {
		if cv.GetConversationId() == ref {
			return cv, nil
		}
		if strings.HasPrefix(cv.GetConversationId(), ref) {
			matches = append(matches, cv)
		}
	}
	switch len(matches) {
	case 1:
		return matches[0], nil
	case 0:
		return nil, usageErrorf("no conversation called %s; ley ask --list lists them", ref)
	}
	ids := make([]string, len(matches))
	for i, cv := range matches {
		ids[i] = cv.GetConversationId()
	}
	return nil, usageErrorf("%s names %d conversations (%s); give the whole id", ref, len(matches), strings.Join(ids, ", "))
}

// conversationSummary is the conversation as the confirmation names it: when it started, how
// long it is and what was asked first, enough to tell it from the one beside it.
func conversationSummary(s ui.Style, cv *leylinev1.Conversation) string {
	line := fmt.Sprintf("the conversation started %s (%s)", recordingClock(cv.GetStartedAtNs()),
		words.Count(len(cv.GetTurns()), "turn"))
	if first := firstWords(cv); first != "" {
		line += ", \"" + s.Truncate(first, 40) + "\""
	}
	return line
}
