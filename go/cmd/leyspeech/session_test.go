// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"io"
	"testing"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/fakedaemon"
	"github.com/reflexive-labs/leysdr/go/internal/testutil"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// fakeSession is a session on the contract's fake daemon.
func fakeSession(t *testing.T) *session {
	t.Helper()
	sock := testutil.SocketPath(t, "d.sock")
	ctx, cancel := context.WithCancel(context.Background())
	served := make(chan error, 1)
	go func() { served <- fakedaemon.New(fakedaemon.Options{}).Serve(ctx, sock) }()
	c, err := leyline.Dial(ctx, sock, leyline.WithKind("cli"), leyline.WithLabel("leyspeech-test"))
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := c.State(ctx); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the fake daemon never came up")
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Cleanup(func() {
		_ = c.Close()
		cancel()
		<-served
	})
	return &session{client: c, stderr: io.Discard, keyed: map[string]bool{}}
}

func speechModel(t *testing.T, s *session) *leylinev1.FeatureModel {
	t.Helper()
	st, err := s.client.Credentials.GetAIState(t.Context(), &leylinev1.GetAIStateRequest{})
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range st.GetFeatures() {
		if f.GetFeature() == "speech" {
			return f
		}
	}
	return nil
}

// A model chosen for a run (as ley transcribe --model does) is put back afterwards: the previous
// choice when there was one, and no choice when there was none.
func TestKeepSpeechModelRestores(t *testing.T) {
	for _, tc := range []struct {
		name     string
		previous *leylinev1.FeatureModel
	}{
		{"none before", nil},
		{"a model before", &leylinev1.FeatureModel{Feature: "speech", Provider: "openai", Model: "gpt-4o-transcribe"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s := fakeSession(t)
			ctx := t.Context()
			if tc.previous != nil {
				if _, err := s.client.Credentials.SetFeatureModel(ctx, tc.previous); err != nil {
					t.Fatal(err)
				}
			}
			restore, err := s.keepSpeechModel(ctx, "whisper-1")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := s.client.Credentials.SetFeatureModel(ctx, &leylinev1.FeatureModel{Feature: "speech", Provider: "openai", Model: "whisper-1"}); err != nil {
				t.Fatal(err)
			}
			if got := speechModel(t, s); got.GetModel() != "whisper-1" {
				t.Fatalf("the run's model was not set: %v", got)
			}
			restore()
			got := speechModel(t, s)
			switch {
			case tc.previous == nil && got != nil && (got.GetProvider() != "" || got.GetModel() != ""):
				t.Errorf("with no model before, the speech feature is %v after, want none", got)
			case tc.previous != nil && (got.GetProvider() != tc.previous.GetProvider() || got.GetModel() != tc.previous.GetModel()):
				t.Errorf("the speech feature is %v after, want %v back", got, tc.previous)
			}
		})
	}
	// Without a model nothing is read or changed.
	s := fakeSession(t)
	restore, err := s.keepSpeechModel(t.Context(), "")
	if err != nil {
		t.Fatal(err)
	}
	restore()
	if got := speechModel(t, s); got != nil {
		t.Errorf("no --model set the speech feature to %v", got)
	}
}
