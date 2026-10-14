// SPDX-License-Identifier: Apache-2.0

package fakedaemon

import (
	"context"
	"fmt"
	"sort"
	"strings"
	"time"

	"google.golang.org/protobuf/proto"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The keys and the ledger, faked the way the daemon keeps them (proto/leyline/v1/ai.proto): one
// key per provider, written and never read back, a check run once when a key is set, and usage
// summed per provider, model, feature, scope and UTC day. The fake has no worker: its check is
// Options.CheckCredential, which a test replaces to script the provider's answer.

// CheckFunc is the provider's verdict on a key: the outcome and the provider's words, or why the
// check could not run.
type CheckFunc func(provider, secret, endpoint string) (leylinev1.CredentialCheck_Outcome, string)

// RejectedSecret is the key the default check refuses, so a test can exercise a rejection without
// a hook of its own.
const RejectedSecret = "bad"

// defaultCheck accepts every key but RejectedSecret, which it refuses in the words Anthropic's API
// uses for an unknown key.
func defaultCheck(_, secret, _ string) (leylinev1.CredentialCheck_Outcome, string) {
	if secret == RejectedSecret {
		return leylinev1.CredentialCheck_REJECTED, "invalid x-api-key"
	}
	return leylinev1.CredentialCheck_ACCEPTED, ""
}

// The features a model can be chosen for, and the ones a usage report may name: a key check is a
// call on the account too, so it is counted.
var (
	modelFeatures = map[string]bool{"assistant": true, "speech": true}
	usageFeatures = map[string]bool{"assistant": true, "speech": true, "check": true}
)

// aiState is the daemon's keys, feature models and ledger. Guarded by Daemon.mu.
type aiState struct {
	credentials map[string]*leylinev1.Credential // by provider, never with a secret in it
	secrets     map[string]string                // by provider: the only place a secret is kept
	features    map[string]*leylinev1.FeatureModel
	ledger      map[usageKey]*leylinev1.UsageLine
}

// usageKey is the ledger's grain (UsageLine).
type usageKey struct{ provider, model, feature, scope, day string }

func newAIState() aiState {
	return aiState{
		credentials: map[string]*leylinev1.Credential{},
		secrets:     map[string]string{},
		features:    map[string]*leylinev1.FeatureModel{},
		ledger:      map[usageKey]*leylinev1.UsageLine{},
	}
}

// aiSnapshot is the whole AIState, sorted by provider and feature. Call with d.mu held.
func (d *Daemon) aiSnapshot() *leylinev1.AIState {
	st := &leylinev1.AIState{}
	for _, c := range d.ai.credentials {
		st.Credentials = append(st.Credentials, proto.Clone(c).(*leylinev1.Credential))
	}
	for _, f := range d.ai.features {
		st.Features = append(st.Features, proto.Clone(f).(*leylinev1.FeatureModel))
	}
	sort.Slice(st.Credentials, func(i, j int) bool { return st.Credentials[i].Provider < st.Credentials[j].Provider })
	sort.Slice(st.Features, func(i, j int) bool { return st.Features[i].Feature < st.Features[j].Feature })
	return st
}

// usageLines is the ledger in day, provider, model, feature and scope order, filtered by req.
// Call with d.mu held.
func (d *Daemon) usageLines(req *leylinev1.GetUsageRequest) []*leylinev1.UsageLine {
	sinceDay := ""
	if req.GetSinceNs() > 0 {
		sinceDay = utcDay(req.GetSinceNs())
	}
	var out []*leylinev1.UsageLine
	for _, l := range d.ai.ledger {
		// A line is a whole UTC day and cannot be cut, so since_ns keeps the day it falls in.
		if sinceDay != "" && l.Day < sinceDay {
			continue
		}
		if (req.GetProvider() != "" && l.Provider != req.GetProvider()) ||
			(req.GetFeature() != "" && l.Feature != req.GetFeature()) ||
			(req.GetScopeId() != "" && l.ScopeId != req.GetScopeId()) {
			continue
		}
		out = append(out, proto.Clone(l).(*leylinev1.UsageLine))
	}
	sort.Slice(out, func(i, j int) bool { return lineOrder(out[i]) < lineOrder(out[j]) })
	return out
}

func lineOrder(l *leylinev1.UsageLine) string {
	return strings.Join([]string{l.Day, l.Provider, l.Model, l.Feature, l.ScopeId}, "\x00")
}

func utcDay(ns int64) string { return time.Unix(0, ns).UTC().Format(time.DateOnly) }

// lastFour is what a person tells keys apart by. A key of four characters or fewer shows none of
// itself, so a short key is never printed whole.
func lastFour(secret string) string {
	if len(secret) <= 4 {
		return ""
	}
	return secret[len(secret)-4:]
}

// SetCredential implements Credentials: the key replaces any for the provider and is checked once.
// A rejected key is still stored, and the reply says so in last_check. A replacement is added now,
// but keeps last_used_at_ns: that is when the provider's account was last called, which a new key
// for the same account does not reset.
func (d *Daemon) SetCredential(ctx context.Context, req *leylinev1.SetCredentialRequest) (*leylinev1.Credential, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	provider := strings.TrimSpace(req.GetProvider())
	if provider == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, "", "a key needs a provider; add one with ley ai add anthropic"))
	}
	if req.GetSecret() == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, provider, "the key is empty; paste it on stdin to ley ai add "+provider))
	}
	d.mu.Lock()
	d.ai.secrets[provider] = req.GetSecret()
	d.ai.credentials[provider] = &leylinev1.Credential{
		Provider: provider, Label: req.GetLabel(), LastFour: lastFour(req.GetSecret()),
		Endpoint: req.GetEndpoint(), AddedAtNs: time.Now().UnixNano(),
		LastUsedAtNs: d.ai.credentials[provider].GetLastUsedAtNs(),
	}
	d.mu.Unlock()
	cred, err := d.checkStored(ci, provider)
	if err != nil {
		return nil, fail(ctx, err)
	}
	return cred, nil
}

// CheckCredential implements Credentials: the stored key is tried again and the reply carries the
// outcome in last_check, rejected or not, as SetCredential's does. The only error is
// CREDENTIAL_MISSING, for a provider with no key; CREDENTIAL_REJECTED belongs to a job that
// starts on a key whose last check was refused.
func (d *Daemon) CheckCredential(ctx context.Context, req *leylinev1.CredentialRef) (*leylinev1.Credential, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	provider := strings.TrimSpace(req.GetProvider())
	d.mu.Lock()
	_, ok := d.ai.credentials[provider]
	d.mu.Unlock()
	if !ok {
		return nil, fail(ctx, credentialMissing(provider))
	}
	cred, err := d.checkStored(ci, provider)
	if err != nil {
		return nil, fail(ctx, err)
	}
	return cred, nil
}

// checkStored runs the check outside the lock, since a hook may block as a worker does, then
// records the outcome and publishes the new state.
func (d *Daemon) checkStored(by *leylinev1.ClientInfo, provider string) (*leylinev1.Credential, *leyline.Error) {
	d.mu.Lock()
	secret := d.ai.secrets[provider]
	endpoint := d.ai.credentials[provider].GetEndpoint()
	d.mu.Unlock()
	check := d.opts.CheckCredential
	if check == nil {
		check = defaultCheck
	}
	outcome, msg := check(provider, secret, endpoint)
	d.mu.Lock()
	defer d.mu.Unlock()
	cred := d.ai.credentials[provider]
	if cred == nil {
		// Deleted while the check ran.
		return nil, credentialMissing(provider)
	}
	cred.LastCheck = &leylinev1.CredentialCheck{Outcome: outcome, Message: msg, AtNs: time.Now().UnixNano()}
	d.emit(by, d.aiSnapshot())
	return proto.Clone(cred).(*leylinev1.Credential), nil
}

// credentialMissing is the daemon's sentence for a provider with no key (EngineError's factory).
func credentialMissing(provider string) *leyline.Error {
	return errorf(leyline.CodeCredentialMissing, provider,
		fmt.Sprintf("no %s key is set; add one with ley ai add %s", provider, provider))
}

// DeleteCredential implements Credentials. Every running decode job whose decoder names the
// provider ends FAILED with CREDENTIAL_MISSING, as the daemon ends them.
func (d *Daemon) DeleteCredential(ctx context.Context, req *leylinev1.CredentialRef) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	provider := strings.TrimSpace(req.GetProvider())
	d.mu.Lock()
	defer d.mu.Unlock()
	if _, ok := d.ai.credentials[provider]; !ok {
		return nil, fail(ctx, credentialMissing(provider))
	}
	delete(d.ai.credentials, provider)
	delete(d.ai.secrets, provider)
	d.emit(ci, d.aiSnapshot())
	gone := credentialMissing(provider)
	for _, id := range d.jobOrder {
		j := d.jobs[id]
		if j == nil || j.proto.GetState() != leylinev1.JobState_RUNNING || j.proto.GetDecode() == nil {
			continue
		}
		if man := d.decoderByName(j.protocol); man.GetCredentialProvider() == provider {
			d.failDecodeLocked(j, &leylinev1.ErrorDetail{Code: gone.Code, Message: gone.Message, Target: provider})
		}
	}
	return &leylinev1.Empty{}, nil
}

// GetAIState implements Credentials.
func (d *Daemon) GetAIState(ctx context.Context, _ *leylinev1.GetAIStateRequest) (*leylinev1.AIState, error) {
	d.touchUnary(clientFrom(ctx))
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.aiSnapshot(), nil
}

// SetFeatureModel implements Credentials. A model can be chosen before its provider's key is
// added: the feature reports CREDENTIAL_MISSING when it runs, not here.
func (d *Daemon) SetFeatureModel(ctx context.Context, req *leylinev1.FeatureModel) (*leylinev1.FeatureModel, error) {
	ci := clientFrom(ctx)
	d.touchUnary(ci)
	if !modelFeatures[req.GetFeature()] {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetFeature(),
			fmt.Sprintf("no feature named %q; the features are assistant and speech", req.GetFeature())))
	}
	if req.GetProvider() == "" || req.GetModel() == "" {
		return nil, fail(ctx, errorf(leyline.CodeInvalidArgument, req.GetFeature(),
			"a feature needs a provider and a model: ley ai use "+req.GetFeature()+" anthropic <model>"))
	}
	fm := &leylinev1.FeatureModel{Feature: req.GetFeature(), Provider: req.GetProvider(), Model: req.GetModel()}
	d.mu.Lock()
	defer d.mu.Unlock()
	d.ai.features[fm.Feature] = fm
	d.emit(ci, d.aiSnapshot())
	return proto.Clone(fm).(*leylinev1.FeatureModel), nil
}

// usageSvc gives the Usage RPCs a receiver of their own, as telemetrySvc does for Subscribe.
type usageSvc struct {
	leylinev1.UnimplementedUsageServer
	d *Daemon
}

// GetUsage implements Usage.
func (u usageSvc) GetUsage(ctx context.Context, req *leylinev1.GetUsageRequest) (*leylinev1.GetUsageResponse, error) {
	u.d.touchUnary(clientFrom(ctx))
	u.d.mu.Lock()
	defer u.d.mu.Unlock()
	return &leylinev1.GetUsageResponse{Lines: u.d.usageLines(req)}, nil
}

// ReportUsage implements Usage: the report is folded into its line, the line goes out on the
// event plane, and the provider's key, if one is set, is marked used.
func (u usageSvc) ReportUsage(ctx context.Context, r *leylinev1.UsageReport) (*leylinev1.Empty, error) {
	ci := clientFrom(ctx)
	u.d.touchUnary(ci)
	if err := validReport(r); err != nil {
		return nil, fail(ctx, err)
	}
	d := u.d
	d.mu.Lock()
	defer d.mu.Unlock()
	line := d.foldUsage(r)
	d.emit(ci, line)
	if cred := d.ai.credentials[r.GetProvider()]; cred != nil {
		cred.LastUsedAtNs = max(cred.LastUsedAtNs, line.LastAtNs)
		d.emit(ci, d.aiSnapshot())
	}
	return &leylinev1.Empty{}, nil
}

func validReport(r *leylinev1.UsageReport) *leyline.Error {
	switch {
	case r.GetProvider() == "" || r.GetModel() == "":
		return errorf(leyline.CodeInvalidArgument, "", "a usage report needs a provider and a model")
	case !usageFeatures[r.GetFeature()]:
		return errorf(leyline.CodeInvalidArgument, r.GetFeature(),
			fmt.Sprintf("no feature named %q; a report is for assistant, speech or check", r.GetFeature()))
	case r.GetJobId() != "" && r.GetConversationId() != "":
		return errorf(leyline.CodeInvalidArgument, r.GetJobId(), "a usage report names a job or a conversation, not both")
	}
	return nil
}

// foldUsage adds r to its line and returns the line. Call with d.mu held.
func (d *Daemon) foldUsage(r *leylinev1.UsageReport) *leylinev1.UsageLine {
	at := r.GetAtNs()
	if at == 0 {
		at = time.Now().UnixNano()
	}
	scope := r.GetJobId()
	if scope == "" {
		scope = r.GetConversationId()
	}
	k := usageKey{r.GetProvider(), r.GetModel(), r.GetFeature(), scope, utcDay(at)}
	l := d.ai.ledger[k]
	if l == nil {
		l = &leylinev1.UsageLine{Provider: k.provider, Model: k.model, Feature: k.feature, ScopeId: k.scope, Day: k.day}
		d.ai.ledger[k] = l
	}
	l.Requests += r.GetRequests()
	l.InputTokens += r.GetInputTokens()
	l.OutputTokens += r.GetOutputTokens()
	l.CacheReadTokens += r.GetCacheReadTokens()
	l.CacheWriteTokens += r.GetCacheWriteTokens()
	l.AudioSeconds += r.GetAudioSeconds()
	l.LastAtNs = max(l.LastAtNs, at)
	return l
}
