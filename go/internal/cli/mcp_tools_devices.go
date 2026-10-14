// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/reflexive-labs/leysdr/go/internal/ui"
	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// The device tool: a radio the daemon cannot find by itself. rtltcp is `ley devices attach
// rtltcp` as it stands (runDevicesAttach); a file is the attach `ley play` makes before it tunes,
// without the tune, so an agent can hand the daemon a recording to treat as a radio.

func (srv *mcpServer) registerDeviceTools() {
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "attach_device",
		Description: "Add a radio the daemon cannot find by itself (Control.AttachDevice; ley devices attach). kind rtltcp is a dongle another machine serves with rtl_tcp, named by endpoint host:port; the daemon remembers it across restarts. " +
			"kind file is an IQ recording (.cf32 or .cu8 with its .json sidecar) played as a radio, named by path, as ley play attaches one; it lasts until the daemon restarts. " +
			"Once attached, list_devices lists it and tune, scan and record use it. 'ley devices detach' removes it. Returns the DeviceDescriptor.",
		Annotations: &mcp.ToolAnnotations{DestructiveHint: boolPtr(false), OpenWorldHint: boolPtr(true)},
	}, srv.attachDevice)
}

type attachDeviceArgs struct {
	Kind     string `json:"kind" jsonschema:"rtltcp (a dongle another machine serves with rtl_tcp) or file (an IQ recording played as a radio)"`
	Endpoint string `json:"endpoint,omitempty" jsonschema:"with rtltcp: host:port, e.g. pi.local:1234 (rtl_tcp listens on 1234 unless told otherwise)"`
	Path     string `json:"path,omitempty" jsonschema:"with file: the recording, with its .json sidecar beside it; a relative path is read from the directory ley mcp was started in"`
	Loop     bool   `json:"loop,omitempty" jsonschema:"with file: start over when the file ends (default: false, the radio goes quiet at the end)"`
}

func (srv *mcpServer) attachDevice(ctx context.Context, _ *mcp.CallToolRequest, in attachDeviceArgs) (*mcp.CallToolResult, any, error) {
	switch strings.ToLower(in.Kind) {
	case "rtltcp":
		if in.Path != "" || in.Loop {
			return nil, nil, errors.New("path and loop go with kind file; rtltcp takes endpoint host:port")
		}
		app, out, errb := srv.toolApp()
		dev, err := runDevicesAttach(ctx, app, "rtltcp", in.Endpoint)
		if err != nil {
			return nil, nil, toolError(err)
		}
		return protoResult(dev, out.String()+errb.String())
	case "file":
		if in.Endpoint != "" {
			return nil, nil, errors.New("endpoint goes with kind rtltcp; file takes path")
		}
		return srv.attachFile(ctx, in.Path, in.Loop)
	}
	return nil, nil, fmt.Errorf("%q is not a kind of radio this server can attach; the kinds are rtltcp (endpoint host:port) and file (path)", in.Kind)
}

// attachFile attaches a recording as a radio, with ley play's checks on the path first.
func (srv *mcpServer) attachFile(ctx context.Context, path string, loop bool) (*mcp.CallToolResult, any, error) {
	if strings.TrimSpace(path) == "" {
		return nil, nil, errors.New("path is required with kind file: the recording to play as a radio")
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return nil, nil, err
	}
	if _, err := os.Stat(abs); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil, fileMissing(abs, "check the path; a file device plays a .cf32 or .cu8 IQ recording with its .json sidecar beside it")
		}
		return nil, nil, err
	}
	dev, err := srv.client.AttachDevice(ctx, leyline.FileSource(abs, loop))
	if err != nil {
		return nil, nil, toolError(err)
	}
	text := fmt.Sprintf("attached %s\nas device %s; it lasts until the daemon restarts, and 'ley devices detach %s' removes it sooner.\n",
		deviceSummary(ui.Style{}, dev), dev.GetDeviceId(), dev.GetDeviceId())
	return protoResult(dev, text)
}
