// SPDX-License-Identifier: Apache-2.0

package cli

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// The bookmark tools: the user's own file of kept frequencies, which `ley bookmarks` edits and
// the Mac app's sidebar reads ($LEYLINE_BOOKMARKS names it). Nothing here reaches the daemon.
// Each tool runs its verb's code (runBookmarkAdd, runBookmarkRemove, runBookmarkImport) and
// returns the rows its --json prints.

func (srv *mcpServer) registerBookmarkTools() {
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "list_bookmarks",
		Description: "The frequencies the user has kept, lowest first, with the mode, bandwidth, tone, note and tags of each (ley bookmarks). The file is the user's, shared with the Mac app's sidebar. " +
			"Returns the array 'ley bookmarks --json' prints: {id, name, hz, mode, bandwidth_hz, updated_ns, tone, note, tags, offset_hz, duplex}; client-local data, not a proto message.",
		Annotations: toolReadOnly,
	}, srv.listBookmarks)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "add_bookmark",
		Description: "Keep a frequency under a name in the user's bookmarks (ley bookmarks add). The frequency is read as tune reads one, and the mode comes from the band unless given. " +
			"The same name at the same frequency updates that bookmark and keeps its tone, note and tags. Adding several at once is the user's to confirm first. " +
			"Returns the row 'ley bookmarks add --json' prints.",
		Annotations: toolMutates,
	}, srv.addBookmark)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "remove_bookmark",
		Description: "Forget one bookmark, by id or by name in any case (ley bookmarks remove). This cannot be undone; two bookmarks answering to one name are named and neither is removed. " +
			"Returns the row that was removed, as 'ley bookmarks remove --json' prints.",
		Annotations: toolDestructive,
	}, srv.removeBookmark)
	mcp.AddTool(srv.server, &mcp.Tool{
		Name: "import_chirp",
		Description: "Read a CHIRP CSV export into the user's bookmarks, one per memory, tagged with the file's name (ley bookmarks import). Rows already kept under their name and frequency are updated. " +
			"This writes many bookmarks at once: run it with dry_run first and show the user what it would add before importing. " +
			"Returns {added, updated, skipped, warnings}, as 'ley bookmarks import --json' prints.",
		Annotations: toolMutates,
	}, srv.importChirp)
}

type listBookmarksArgs struct {
	Tag string `json:"tag,omitempty" jsonschema:"only the bookmarks filed under this tag (default: all of them)"`
}

func (srv *mcpServer) listBookmarks(ctx context.Context, _ *mcp.CallToolRequest, in listBookmarksArgs) (*mcp.CallToolResult, any, error) {
	var args []string
	if in.Tag != "" {
		args = []string{"--tag", in.Tag}
	}
	text, raw, err := srv.localVerb(ctx, newBookmarksCommand, args...)
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(text, raw), nil, nil
}

type addBookmarkArgs struct {
	Frequency string   `json:"frequency" jsonschema:"what to keep: a frequency (a bare number is MHz: 146.94; units are exact: 162550k), a preset such as noaa or marine16, or with band a channel of that band's plan (5 with band gmrs)"`
	Name      string   `json:"name" jsonschema:"what to call it in the list, e.g. Local repeater"`
	Band      string   `json:"band,omitempty" jsonschema:"read frequency as a channel of this band's plan, as its radios print it: gmrs, marine, noaa (list_bands names them)"`
	Mode      string   `json:"mode,omitempty" jsonschema:"how to decode it: nfm, wfm, am, usb, lsb, cw (default: by band, as tune does)"`
	Bandwidth string   `json:"bandwidth,omitempty" jsonschema:"how wide a slice to listen to: a bare number is kHz (12.5), or 200k (default: the mode's usual width, which the bookmark keeps following)"`
	Tone      string   `json:"tone,omitempty" jsonschema:"the tone the repeater requires on its input, as CHIRP spells it: a CTCSS tone with one decimal (100.0) or a DCS code (D023N, D023I). Kept as a record; nothing gates audio on it"`
	Note      string   `json:"note,omitempty" jsonschema:"free text kept beside it, e.g. 600 kHz down, club net Tuesdays"`
	Tags      []string `json:"tags,omitempty" jsonschema:"words to file it under; they join any it has"`
}

func (srv *mcpServer) addBookmark(_ context.Context, _ *mcp.CallToolRequest, in addBookmarkArgs) (*mcp.CallToolResult, any, error) {
	if strings.TrimSpace(in.Frequency) == "" {
		return nil, nil, errors.New("frequency is required: a frequency, a preset, or a plan channel with band")
	}
	app, out, _ := srv.toolApp()
	b, err := runBookmarkAdd(app, in.Frequency, in.Name, in.Mode, in.Bandwidth, in.Band,
		bookmarkFields{tone: in.Tone, note: in.Note, tags: in.Tags})
	if err != nil {
		return nil, nil, toolError(err)
	}
	raw, err := json.Marshal(bookmarkRow(b))
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(out.String(), raw), nil, nil
}

type removeBookmarkArgs struct {
	Bookmark string `json:"bookmark" jsonschema:"the bookmark: its id (bm_...) or its name, in any case"`
}

func (srv *mcpServer) removeBookmark(_ context.Context, _ *mcp.CallToolRequest, in removeBookmarkArgs) (*mcp.CallToolResult, any, error) {
	if strings.TrimSpace(in.Bookmark) == "" {
		return nil, nil, errors.New("bookmark is required: an id or a name from list_bookmarks")
	}
	app, out, _ := srv.toolApp()
	b, err := runBookmarkRemove(app, in.Bookmark)
	if err != nil {
		return nil, nil, toolError(err)
	}
	raw, err := json.Marshal(bookmarkRow(b))
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(out.String(), raw), nil, nil
}

type importChirpArgs struct {
	Path   string `json:"path" jsonschema:"the CHIRP CSV export (File > Export in CHIRP) on the machine ley mcp runs on; a relative path is read from the directory ley mcp was started in"`
	DryRun bool   `json:"dry_run,omitempty" jsonschema:"say what the import would add, update and skip, and write nothing (default: false)"`
}

func (srv *mcpServer) importChirp(_ context.Context, _ *mcp.CallToolRequest, in importChirpArgs) (*mcp.CallToolResult, any, error) {
	if strings.TrimSpace(in.Path) == "" {
		return nil, nil, errors.New("path is required: the CHIRP CSV export to read")
	}
	app, _, errb := srv.toolApp()
	res, err := runBookmarkImport(app, in.Path, in.DryRun)
	if err != nil {
		return nil, nil, toolError(err)
	}
	raw, err := json.Marshal(res)
	if err != nil {
		return nil, nil, err
	}
	return jsonResult(errb.String(), raw), nil, nil
}
