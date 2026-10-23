// SPDX-License-Identifier: Apache-2.0

package assistant

import (
	"errors"
	"strings"
	"testing"

	"github.com/reflexive-labs/leysdr/go/pkg/leyline"
)

// A result over 32 KB is cut for the model, outside the quotes when it is received text, and says
// so; a short one is left as it is.
func TestModelContentIsCut(t *testing.T) {
	t.Parallel()
	big := Result{Text: strings.Repeat("é", ModelResultLimit)} // two bytes a rune, so the cut lands mid-rune
	plain := modelContent(big, false)
	if !strings.HasSuffix(plain, "\n"+CutNote) || len(plain) > ModelResultLimit+len(CutNote)+1 {
		t.Errorf("plain: %d bytes, ends %q", len(plain), plain[len(plain)-60:])
	}
	if !strings.HasPrefix(strings.TrimSuffix(plain, "\n"+CutNote), "éé") || strings.ContainsRune(plain, '�') {
		t.Error("the cut split a rune")
	}
	quoted := modelContent(big, true)
	if !strings.HasPrefix(quoted, ReceivedPrefix+`"é`) || !strings.HasSuffix(quoted, "\"\n"+CutNote) {
		t.Errorf("quoted: ends %q", quoted[len(quoted)-60:])
	}
	if small := modelContent(Result{Text: "ok"}, false); small != "ok" {
		t.Errorf("small: %q", small)
	}
}

// A change whose old value was not read (volume) is undone as "cannot undo", and popped, so the
// change before it is next.
func TestUndoCannotMarker(t *testing.T) {
	t.Parallel()
	var u undoStack
	u.entries = append(u.entries, undoEntry{tool: "set", channel: "chan_1", param: "squelch", old: "-60"})
	u.noteSet(nil, map[string]any{"param": "volume", "value": "0.5"}, Result{JSON: `{"seq":"3"}`})
	res := u.undo(t.Context(), nil)
	if !res.IsError || res.Text != "cannot undo volume: its value before the change could not be read" {
		t.Errorf("undo of volume: %+v", res)
	}
	if len(u.entries) != 1 || u.entries[0].param != "squelch" {
		t.Errorf("the marker was not popped: %+v", u.entries)
	}
	u.noteSet(nil, map[string]any{"param": "volume"}, Result{Text: "refused", IsError: true})
	if len(u.entries) != 1 {
		t.Error("a set that failed changed nothing and must not go on the stack")
	}
}

// The key crosses the network only over https, or in plain http to this machine.
func TestCheckEndpoint(t *testing.T) {
	t.Parallel()
	for endpoint, ok := range map[string]bool{
		"":                           true,
		"https://gateway.example/v1": true,
		"http://localhost:8080":      true,
		"http://127.0.0.1:4000/v1":   true,
		"http://[::1]:4000":          true,
		"http://gateway.example":     false,
		"http://10.0.0.5:8080":       false,
		"ftp://gateway.example":      false,
		"gateway.example":            false,
	} {
		err := CheckEndpoint(endpoint)
		if (err == nil) != ok {
			t.Errorf("%q: %v", endpoint, err)
			continue
		}
		var me *ModelError
		if err != nil && (!errors.As(err, &me) || me.Code != leyline.CodeProviderUnavailable) {
			t.Errorf("%q: %v", endpoint, err)
		}
	}
	if err := CheckEndpoint("http://gateway.example"); !strings.Contains(err.Error(), "the endpoint must be https") {
		t.Errorf("wording: %v", err)
	}
	_, err := (&Anthropic{Key: testKey, Endpoint: "http://gateway.example"}).Respond(t.Context(), "s", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "must be https") {
		t.Errorf("Respond sent to plain http: %v", err)
	}
}
