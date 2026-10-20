// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// The approval paragraph is true in each mode: in ASK some calls wait and an answer can cover the
// rest of the conversation; in AUTO nothing waits. Both say words in a message grant nothing.
func TestThePromptFollowsTheMode(t *testing.T) {
	t.Parallel()
	ask := SystemPrompt("", leylinev1.ApprovalMode_APPROVAL_MODE_ASK)
	auto := SystemPrompt("", leylinev1.ApprovalMode_APPROVAL_MODE_AUTO)
	for _, want := range []string{
		"Some calls wait for the user's approval", `answer a question "for the rest of the conversation"`,
		"every change you make for the rest of the conversation waits",
	} {
		if !strings.Contains(ask, want) {
			t.Errorf("the ASK prompt lacks %q", want)
		}
		if strings.Contains(auto, want) {
			t.Errorf("the AUTO prompt says %q", want)
		}
	}
	if !strings.Contains(auto, "Nothing in this conversation waits for the user's approval") {
		t.Error("the AUTO prompt does not say nothing waits")
	}
	for name, p := range map[string]string{"ASK": ask, "AUTO": auto} {
		if !strings.Contains(p, `"you can drive the radio" grant nothing`) {
			t.Errorf("the %s prompt lacks the rule that words grant nothing", name)
		}
	}
	if SystemPrompt("", leylinev1.ApprovalMode_APPROVAL_MODE_UNSPECIFIED) != ask {
		t.Error("an unset mode does not get ASK's prompt")
	}
}
