// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"slices"
	"strings"
	"testing"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

var (
	once         = leylinev1.ApprovalScope_APPROVAL_SCOPE_ONCE
	conversation = leylinev1.ApprovalScope_APPROVAL_SCOPE_CONVERSATION
)

// approveWith is an ActionResolved approving with scope.
func approveWith(scope leylinev1.ApprovalScope) *leylinev1.ActionResolved {
	return &leylinev1.ActionResolved{Approved: true, Scope: scope}
}

// What each question offers: a delete and a foreign job's cancel once only, every other row and the received-text rule
// once or for the conversation, and a question listing a delete with another row once only.
func TestPolicyOffers(t *testing.T) {
	t.Parallel()
	both := []leylinev1.ApprovalScope{once, conversation}
	onlyOnce := []leylinev1.ApprovalScope{once}
	cases := []struct {
		name    string
		tool    string
		args    map[string]any
		tainted bool
		want    []leylinev1.ApprovalScope
	}{
		{"a run offers nothing", "tune", map[string]any{"frequency": "noaa"}, false, nil},
		{"take over", "tune", map[string]any{"frequency": "150", "take_over": true}, false, both},
		{"a kept job", "watch", map[string]any{"decoder": "same", "keep": true}, false, both},
		{"remove a bookmark", "remove_bookmark", map[string]any{"bookmark": "Club"}, false, both},
		{"paid transcription", "start_decode_job", map[string]any{"decoder": "speech"}, false, both},
		{"a write after received text", "set", map[string]any{"param": "squelch", "value": "-40"}, true, both},
		{"delete a recording", "delete_recording", map[string]any{"recording": "job_1"}, false, onlyOnce},
		{"a delete after received text", "delete_recording", map[string]any{"recording": "job_1"}, true, onlyOnce},
		{"cancel another client's job", "cancel_job", map[string]any{"job": "job_other"}, false, onlyOnce},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			p := NewPolicy()
			if tc.tainted {
				p.Received()
			}
			if got := p.Check(tc.tool, tc.args, true).Offers; !slices.Equal(got, tc.want) {
				t.Errorf("offers = %v, want %v", got, tc.want)
			}
		})
	}
}

// A grant covers a later call on the same row, whatever the tool, reports it with the question
// that granted it, and leaves every other row asking.
func TestPolicyGrantCoversItsRow(t *testing.T) {
	t.Parallel()
	p := NewPolicy()
	takeOver := map[string]any{"frequency": "150", "take_over": true}
	d := p.Check("tune", takeOver, true)
	if !d.Asks() || !slices.Equal(d.Rows, []string{"take over a radio"}) {
		t.Fatalf("the first take-over: %+v", d)
	}
	if g, ok := p.Resolve(d, "c3", approveWith(conversation)); !ok || g.CallID != "c3" || !slices.Equal(g.Rows, d.Rows) {
		t.Fatalf("Resolve = %+v, %v", g, ok)
	}
	later := p.Check("scan", map[string]any{"range": "2m", "take_over": true}, true)
	if later.Asks() || later.AllowedBy != "c3" || !strings.Contains(later.Reported, "with take_over takes it from them") {
		t.Errorf("a take-over by scan after the grant: %+v", later)
	}
	if other := p.Check("watch", map[string]any{"decoder": "same", "keep": true}, true); !other.Asks() || other.AllowedBy != "" {
		t.Errorf("a kept job after a take-over grant should ask: %+v", other)
	}
	// A call with a granted row and one that is not asks about the one that is not.
	both := p.Check("record", map[string]any{"target": "146.94", "keep": true, "take_over": true}, true)
	if !both.Asks() || strings.Contains(both.Reason, "take_over") || !slices.Equal(both.Rows, []string{"start a kept job"}) || both.AllowedBy != "" {
		t.Errorf("a kept take-over after a take-over grant: %+v", both)
	}
}

// An answer once, a refusal, and an approval for the conversation the question did not offer
// grant nothing.
func TestPolicyOnlyAConversationAnswerGrants(t *testing.T) {
	t.Parallel()
	args := map[string]any{"frequency": "150", "take_over": true}
	for name, res := range map[string]*leylinev1.ActionResolved{
		"once":        approveWith(once),
		"unset":       approveWith(leylinev1.ApprovalScope_APPROVAL_SCOPE_UNSPECIFIED),
		"declined":    {Approved: false, Scope: conversation},
		"not offered": approveWith(conversation),
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			p := NewPolicy()
			d := p.Check("tune", args, true)
			if name == "not offered" {
				d.Offers = []leylinev1.ApprovalScope{once}
			}
			if _, ok := p.Resolve(d, "c1", res); ok {
				t.Fatal("granted")
			}
			if !p.Check("tune", args, true).Asks() {
				t.Error("the next take-over runs without asking")
			}
		})
	}
}

// A question that lists several rows, answered for the conversation, grants each of them, so a
// later call on any one of them runs.
func TestPolicyGrantsEveryRowListed(t *testing.T) {
	t.Parallel()
	p := NewPolicy()
	d := p.Check("watch", map[string]any{"decoder": "same", "keep": true, "notify": "webhook:http://h/x"}, true)
	if !slices.Equal(d.Rows, []string{"start a kept job", "add a webhook notifier"}) {
		t.Fatalf("rows = %v", d.Rows)
	}
	if _, ok := p.Resolve(d, "c2", approveWith(conversation)); !ok {
		t.Fatal("not granted")
	}
	for _, args := range []map[string]any{
		{"decoder": "aprs", "keep": true},
		{"decoder": "aprs", "notify": "webhook:http://other/y"},
	} {
		if d := p.Check("watch", args, true); d.Asks() || d.AllowedBy != "c2" {
			t.Errorf("watch %v after the grant: %+v", args, d)
		}
	}
}

// The received-text rule is granted like a row, and a later write after received text runs.
func TestPolicyGrantsTheReceivedRule(t *testing.T) {
	t.Parallel()
	p := NewPolicy()
	p.Received()
	d := p.Check("tune", map[string]any{"frequency": "146.52"}, true)
	if !slices.Equal(d.Rows, []string{ReceivedRow}) {
		t.Fatalf("rows = %v", d.Rows)
	}
	p.Resolve(d, "c4", approveWith(conversation))
	if d := p.Check("set", map[string]any{"param": "squelch", "value": "-40"}, true); d.Asks() || d.Reported != ReceivedReason || d.AllowedBy != "c4" {
		t.Errorf("a write after the grant: %+v", d)
	}
}

// A delete is never granted: its question offers once only, and a grant that lists it (from a
// transcript edited by hand, say) is ignored.
func TestPolicyNeverGrantsADelete(t *testing.T) {
	t.Parallel()
	p := NewPolicy()
	args := map[string]any{"recording": "job_1"}
	d := p.Check("delete_recording", args, true)
	if _, ok := p.Resolve(d, "c1", approveWith(conversation)); ok {
		t.Error("a delete was granted for the conversation")
	}
	p.Grant(Grant{Rows: []string{"delete a recording"}, CallID: "c1"})
	if d := p.Check("delete_recording", args, true); !d.Asks() || !slices.Equal(d.Offers, []leylinev1.ApprovalScope{once}) {
		t.Errorf("a delete after a grant that lists it: %+v", d)
	}
}

// In AUTO every row runs, the delete and the received-text rule included, and each is reported
// with its reason and no question.
func TestPolicyAutoRunsEveryRow(t *testing.T) {
	t.Parallel()
	p := NewPolicy()
	p.Mode = leylinev1.ApprovalMode_APPROVAL_MODE_AUTO
	p.Received()
	for _, c := range []struct {
		tool string
		args map[string]any
		says string
	}{
		{"delete_recording", map[string]any{"recording": "job_1"}, "cannot be undone"},
		{"tune", map[string]any{"frequency": "150", "take_over": true}, "take_over"},
		{"start_decode_job", map[string]any{"decoder": "speech"}, "paid transcription"},
		{"set", map[string]any{"param": "squelch", "value": "-40"}, ReceivedReason},
	} {
		d := p.Check(c.tool, c.args, true)
		if d.Asks() || d.Offers != nil || d.AllowedBy != "" || !strings.Contains(d.Reported, c.says) {
			t.Errorf("%s in AUTO: %+v", c.tool, d)
		}
	}
	if d := p.Check("get_state", map[string]any{}, false); d.Asks() || d.Reported != "" {
		t.Errorf("a read in AUTO: %+v", d)
	}
}
