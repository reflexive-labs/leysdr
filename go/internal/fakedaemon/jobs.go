package fakedaemon

import (
	"context"

	leylinev1 "github.com/dpup/leysdr/go/gen/leyline/v1"
	"github.com/dpup/leysdr/go/pkg/leyline"
)

func unimplemented(ctx context.Context, what string) error {
	return fail(ctx, errorf(leyline.CodeUnimplemented, "", what+" is not implemented in v0"))
}

// Jobs service: UNIMPLEMENTED in v0.

// StartJob implements Jobs.
func (d *Daemon) StartJob(ctx context.Context, _ *leylinev1.StartJobRequest) (*leylinev1.Job, error) {
	return nil, unimplemented(ctx, "Jobs.StartJob")
}

// ListJobs implements Jobs.
func (d *Daemon) ListJobs(ctx context.Context, _ *leylinev1.ListJobsRequest) (*leylinev1.ListJobsResponse, error) {
	return nil, unimplemented(ctx, "Jobs.ListJobs")
}

// GetJob implements Jobs.
func (d *Daemon) GetJob(ctx context.Context, _ *leylinev1.JobRef) (*leylinev1.Job, error) {
	return nil, unimplemented(ctx, "Jobs.GetJob")
}

// CancelJob implements Jobs.
func (d *Daemon) CancelJob(ctx context.Context, _ *leylinev1.JobRef) (*leylinev1.Job, error) {
	return nil, unimplemented(ctx, "Jobs.CancelJob")
}

// GetTranscript implements Jobs.
func (d *Daemon) GetTranscript(ctx context.Context, _ *leylinev1.TranscriptRequest) (*leylinev1.Transcript, error) {
	return nil, unimplemented(ctx, "Jobs.GetTranscript")
}

// GetScan implements Jobs.
func (d *Daemon) GetScan(ctx context.Context, _ *leylinev1.ScanRef) (*leylinev1.Scan, error) {
	return nil, unimplemented(ctx, "Jobs.GetScan")
}

// Resources service: UNIMPLEMENTED in v0.

// ListResources implements Resources.
func (d *Daemon) ListResources(ctx context.Context, _ *leylinev1.ListResourcesRequest) (*leylinev1.ListResourcesResponse, error) {
	return nil, unimplemented(ctx, "Resources.ListResources")
}

// GetResource implements Resources.
func (d *Daemon) GetResource(ctx context.Context, _ *leylinev1.ResourceRef) (*leylinev1.Resource, error) {
	return nil, unimplemented(ctx, "Resources.GetResource")
}

// ResolveLocalPath implements Resources.
func (d *Daemon) ResolveLocalPath(ctx context.Context, _ *leylinev1.ResourceRef) (*leylinev1.LocalPath, error) {
	return nil, unimplemented(ctx, "Resources.ResolveLocalPath")
}
