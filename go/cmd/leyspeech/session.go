// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
	"github.com/reflexive-labs/leysdr/go/internal/daemonrun"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// daemonOptions say whether to start a hermetic daemon for the run, and with what.
type daemonOptions struct {
	hermetic   bool
	leylined   string
	decoders   string
	recordings string
}

// session is one daemon leyspeech measures against: the user's own, or a hermetic one it started
// on a copy of the recording.
type session struct {
	ley    *leyRunner
	client *leyline.Client
	daemon *daemonrun.Daemon
	tmp    string
	stderr io.Writer
	// keyed is the providers whose key this session added to its hermetic daemon.
	keyed map[string]bool
}

// openSession connects to the daemon, or starts a hermetic one holding a copy of the recording,
// and returns the recording's directory as that daemon sees it.
func openSession(ctx context.Context, g *globals, o daemonOptions, recordingRef string, stderr io.Writer) (*session, string, error) {
	s := &session{ley: g.runner(), stderr: stderr, keyed: map[string]bool{}}
	if !o.hermetic {
		c, err := leyline.Dial(ctx, g.socket, leyline.WithKind("cli"), leyline.WithLabel("leyspeech"))
		if err != nil {
			return nil, "", err
		}
		s.client = c
		dir, err := s.ley.locateRecording(ctx, recordingRef)
		if err != nil {
			s.close()
			return nil, "", err
		}
		return s, dir, nil
	}
	src, err := hermeticSource(recordingRef, o.recordings)
	if err != nil {
		return nil, "", err
	}
	m, err := leyline.ReadRecordingManifest(src)
	if err != nil {
		return nil, "", fmt.Errorf("the recording's manifest could not be read (%s): %w", src, err)
	}
	if s.tmp, err = os.MkdirTemp("", "leyspeech"); err != nil {
		return nil, "", err
	}
	// The daemon reads recordings from <Dir>/recordings, and a listing there is a scan of the
	// manifests, so a copy is all it needs; the original is never written to.
	dir := filepath.Join(s.tmp, "recordings", m.JobID)
	if err := copyDir(src, dir); err != nil {
		s.close()
		return nil, "", err
	}
	d, err := daemonrun.Start(ctx, daemonrun.Options{
		Bin: o.leylined, Dir: s.tmp, Decoders: o.decoders, Label: "leyspeech", Unset: []string{keyEnv},
	})
	if err != nil {
		s.close()
		return nil, "", err
	}
	s.daemon, s.client, s.ley.socket = d, d.Client, d.Socket
	fmt.Fprintf(stderr, "leyspeech: a hermetic daemon on %s, its log %s\n", d.Socket, d.Log)
	return s, dir, nil
}

// openLiveSession connects to the running daemon: a live run needs its radios.
func openLiveSession(ctx context.Context, g *globals, stderr io.Writer) (*session, error) {
	c, err := leyline.Dial(ctx, g.socket, leyline.WithKind("cli"), leyline.WithLabel("leyspeech"))
	if err != nil {
		return nil, err
	}
	return &session{ley: g.runner(), client: c, stderr: stderr, keyed: map[string]bool{}}, nil
}

// hermeticSource is the directory of the recording to copy into a hermetic daemon: ref itself
// when it is a recording's directory, else the one under recordings whose id ref names or starts.
func hermeticSource(ref, recordings string) (string, error) {
	if isRecordingDir(ref) {
		return ref, nil
	}
	if recordings == "" {
		return "", fmt.Errorf("--daemon starts a daemon with no recordings of its own: give the recording as a directory, or say where it is with --recordings")
	}
	id := ref
	if parsed, _, ok := leyline.ParseRecordingURI(ref); ok {
		id = parsed
	}
	entries, err := os.ReadDir(recordings)
	if err != nil {
		return "", err
	}
	var matches []string
	for _, e := range entries {
		if e.IsDir() && strings.HasPrefix(e.Name(), id) && isRecordingDir(filepath.Join(recordings, e.Name())) {
			matches = append(matches, e.Name())
		}
	}
	switch len(matches) {
	case 0:
		return "", fmt.Errorf("no recording called %s in %s", ref, recordings)
	case 1:
		return filepath.Join(recordings, matches[0]), nil
	}
	return "", fmt.Errorf("%s names %d recordings in %s (%s); give the whole id", ref, len(matches), recordings, strings.Join(matches, ", "))
}

// copyDir copies the files under src to dst.
func copyDir(src, dst string) error {
	return filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		b, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, b, 0o644)
	})
}

// close stops a hermetic daemon and removes its directory, or disconnects from the user's.
func (s *session) close() {
	if s.daemon != nil {
		s.daemon.Stop()
	} else if s.client != nil {
		_ = s.client.Close()
	}
	if s.tmp != "" {
		_ = os.RemoveAll(s.tmp)
	}
}

// decoder is the installed decoder called name, by name or alias, which must read overs.
func (s *session) decoder(ctx context.Context, name string) (*leylinev1.DecoderManifest, error) {
	resp, err := s.client.ListDecoders(ctx)
	if err != nil {
		return nil, err
	}
	var found *leylinev1.DecoderManifest
	for _, m := range resp.GetDecoders() {
		if m.GetName() == name {
			found = m
			break
		}
		for _, a := range m.GetAliases() {
			if a == name && found == nil {
				found = m
			}
		}
	}
	switch {
	case found == nil:
		return nil, fmt.Errorf("the daemon has no decoder called %q; 'ley decoders' lists the ones installed", name)
	case found.GetInput().GetMode() != leylinev1.InputMode_SEGMENTED:
		return nil, fmt.Errorf("%s decodes a continuous stream, not overs, so it is not a speech engine", name)
	}
	return found, nil
}

// ensureKey adds the provider's key to a hermetic daemon from $LEYSPEECH_KEY, once. The user's
// own daemon has its keys already, and ley names the missing one if it has not.
func (s *session) ensureKey(ctx context.Context, provider string) error {
	if s.daemon == nil || provider == "" || s.keyed[provider] {
		return nil
	}
	key := strings.TrimSpace(os.Getenv(keyEnv))
	if key == "" {
		return fmt.Errorf("the hermetic daemon has no %s key: set $%s to it, which leyspeech passes to 'ley ai add %s' on stdin", provider, keyEnv, provider)
	}
	cmd := s.ley.command(ctx, "ai", "add", provider)
	cmd.Stdin = strings.NewReader(key + "\n")
	cmd.Stdout, cmd.Stderr = io.Discard, s.stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("ley ai add %s: %w", provider, err)
	}
	s.keyed[provider] = true
	return nil
}

// keepSpeechModel notes the speech feature's model before a run that changes it and returns the
// function that puts it back, so that measuring a model does not leave it chosen for the owner's
// later jobs. With no model it changes nothing.
func (s *session) keepSpeechModel(ctx context.Context, model string) (func(), error) {
	if model == "" {
		return func() {}, nil
	}
	st, err := s.client.Credentials.GetAIState(ctx, &leylinev1.GetAIStateRequest{})
	if err != nil {
		return nil, err
	}
	previous := &leylinev1.FeatureModel{Feature: "speech"} // an empty provider and model clear it
	for _, f := range st.GetFeatures() {
		if f.GetFeature() == "speech" {
			previous = f
		}
	}
	return func() {
		cctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, err := s.client.Credentials.SetFeatureModel(cctx, previous); err != nil {
			fmt.Fprintf(s.stderr, "leyspeech: the speech model is still %s; 'ley ai use speech %s %s' puts it back: %v\n",
				model, previous.GetProvider(), previous.GetModel(), err)
		}
	}, nil
}

// usage sums the ledger's lines for one job: what the provider counted, in its own units.
func (s *session) usage(ctx context.Context, jobID string) (usage, error) {
	var u usage
	if jobID == "" {
		return u, nil
	}
	resp, err := s.client.Usage.GetUsage(ctx, &leylinev1.GetUsageRequest{ScopeId: jobID})
	if err != nil {
		return u, err
	}
	for _, l := range resp.GetLines() {
		u.Provider, u.Model = l.GetProvider(), l.GetModel()
		u.Requests += float64(l.GetRequests())
		u.InputTokens += float64(l.GetInputTokens())
		u.OutputTokens += float64(l.GetOutputTokens())
		u.CacheReadTokens += float64(l.GetCacheReadTokens())
		u.CacheWriteTokens += float64(l.GetCacheWriteTokens())
		u.AudioSeconds += l.GetAudioSeconds()
	}
	return u, nil
}
