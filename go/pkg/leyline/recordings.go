// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	leylinev1 "github.com/reflexive-labs/leysdr/go/gen/leyline/v1"
)

// RecordingURI is the resource a record job produces: ley://recordings/<job_id>.
func RecordingURI(jobID string) string { return "ley://recordings/" + jobID }

// RecordingPartURI names one part of a recording: ley://recordings/<job_id>/<part>.
func RecordingPartURI(jobID string, part int) string {
	return fmt.Sprintf("ley://recordings/%s/%d", jobID, part)
}

// ParseRecordingURI splits a ley://recordings/... uri into its job id and part
// number; part is 0 when the uri names the whole recording. The second return
// is false for anything that is not a recording uri.
func ParseRecordingURI(uri string) (jobID string, part int, ok bool) {
	rest, found := strings.CutPrefix(uri, "ley://recordings/")
	if !found || rest == "" {
		return "", 0, false
	}
	id, tail, split := strings.Cut(rest, "/")
	if id == "" {
		return "", 0, false
	}
	if !split {
		return id, 0, true
	}
	n, err := strconv.Atoi(tail)
	if err != nil || n < 1 {
		return "", 0, false
	}
	return id, n, true
}

// StartRecord starts a record job. The daemon finds or makes the capture, or
// refuses with the reason; the recording is a resource from the moment the job
// exists, and its uri is the job's own id.
func (c *Client) StartRecord(ctx context.Context, cfg *leylinev1.RecordConfig) (*leylinev1.Job, error) {
	return c.Jobs.StartJob(ctx, &leylinev1.StartJobRequest{
		Config: &leylinev1.StartJobRequest_Record{Record: cfg},
	})
}

// ListRecordings returns the recordings the daemon's store holds, newest first,
// narrowed by the frozen metadata keys (kind, frequency_hz, mode, bandwidth_hz,
// sample_rate, format, duration_ms, parts, started_at_ns, ended_at_ns, ended_by,
// device).
func (c *Client) ListRecordings(ctx context.Context, filter map[string]string) ([]*leylinev1.Resource, error) {
	resp, err := c.Resources.ListResources(ctx, &leylinev1.ListResourcesRequest{
		Kind: leylinev1.ResourceKind_RECORDING, MetadataFilter: filter,
	})
	if err != nil {
		return nil, err
	}
	return resp.GetResources(), nil
}

// GetResource reads one resource by uri.
func (c *Client) GetResource(ctx context.Context, uri string) (*leylinev1.Resource, error) {
	return c.Resources.GetResource(ctx, &leylinev1.ResourceRef{Uri: uri})
}

// ResolveLocalPath asks the daemon where a resource is on this machine: a
// recording's directory, or one part's samples file. Samples are never streamed
// (docs/design/data-planes.md, "no lossless network stream"), so this is how a
// client on the same machine reads one.
func (c *Client) ResolveLocalPath(ctx context.Context, uri string) (string, error) {
	resp, err := c.Resources.ResolveLocalPath(ctx, &leylinev1.ResourceRef{Uri: uri})
	if err != nil {
		return "", err
	}
	return resp.GetPath(), nil
}

// DeleteRecording asks the daemon to remove a recording whole: every part, its
// sidecars and the manifest. The daemon refuses a part's uri and refuses while
// the recording's job runs (FAILED_PRECONDITION; cancel the job first). The
// reply carries the bytes the directory held.
func (c *Client) DeleteRecording(ctx context.Context, uri string) (*leylinev1.DeletedResource, error) {
	return c.Resources.DeleteResource(ctx, &leylinev1.ResourceRef{Uri: uri})
}

// StartPlayback asks the daemon to play a recording through its own audio
// device. The daemon owns the speakers, as it does for a channel's audio, so
// the sound comes out where the radio is and no samples cross the socket.
// The playback belongs to this client and stops when it goes.
func (c *Client) StartPlayback(ctx context.Context, uri string, volume float64) (*leylinev1.Playback, error) {
	req := &leylinev1.StartPlaybackRequest{ResourceUri: uri}
	if volume >= 0 {
		req.Volume = &volume
	}
	return c.Control.StartPlayback(ctx, req)
}

// SetPlaybackPaused pauses or resumes a playback. Paused, the daemon holds the
// position and stops feeding the audio device; resumed, it continues from
// there. The reply is the playback's full state.
func (c *Client) SetPlaybackPaused(ctx context.Context, playbackID string, paused bool) (*leylinev1.Playback, error) {
	return c.Control.SetPlaybackPaused(ctx, &leylinev1.SetPlaybackPausedRequest{PlaybackId: playbackID, Paused: paused})
}

// NothingHeard is the status_detail of a record job that ended with no part
// written. The daemon discards such a recording, so its URI resolves to
// JOB_NOT_FOUND; a client says so rather than reading a manifest that is gone
// (docs/design/recording.md, "Nothing heard").
const NothingHeard = "nothing was heard"

// StopPlayback stops one the daemon is playing.
func (c *Client) StopPlayback(ctx context.Context, playbackID string) error {
	_, err := c.Control.StopPlayback(ctx, &leylinev1.StopPlaybackRequest{PlaybackId: playbackID})
	return err
}
