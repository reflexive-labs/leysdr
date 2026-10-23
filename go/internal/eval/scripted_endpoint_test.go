// SPDX-License-Identifier: Apache-2.0

package eval

import (
	"io"
	"net/http"
	"strings"
	"testing"
)

// The scripted provider's endpoint answers the key check's models call, on this machine, and
// nothing else: any other method or path is 404.
func TestScriptedEndpointAnswersOnlyTheModelsCall(t *testing.T) {
	url, stop, err := scriptedEndpoint()
	if err != nil {
		t.Fatal(err)
	}
	defer stop()
	if !strings.HasPrefix(url, "http://127.0.0.1:") || !strings.HasSuffix(url, "/v1") {
		t.Fatalf("the endpoint is %s, want http://127.0.0.1:<port>/v1", url)
	}
	for _, tc := range []struct {
		method, path string
		status       int
	}{
		{http.MethodGet, "/models", http.StatusOK},
		{http.MethodPost, "/models", http.StatusNotFound},
		{http.MethodPost, "/chat/completions", http.StatusNotFound},
		{http.MethodGet, "/", http.StatusNotFound},
	} {
		req, err := http.NewRequestWithContext(t.Context(), tc.method, url+tc.path, nil)
		if err != nil {
			t.Fatal(err)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		body, _ := io.ReadAll(resp.Body)
		_ = resp.Body.Close()
		if resp.StatusCode != tc.status {
			t.Errorf("%s %s: %d, want %d", tc.method, tc.path, resp.StatusCode, tc.status)
		}
		if tc.status == http.StatusOK && string(body) != `{"data":[]}` {
			t.Errorf("%s %s: body %q", tc.method, tc.path, body)
		}
	}
}
