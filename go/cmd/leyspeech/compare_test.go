// SPDX-License-Identifier: Apache-2.0

package main

import "testing"

func TestParseEngineSpec(t *testing.T) {
	for _, tc := range []struct {
		in   string
		want engineSpec
	}{
		{"speech", engineSpec{name: "speech"}},
		{"cloud=nova-3", engineSpec{name: "cloud", model: "nova-3"}},
		{"cloud=anthropic.model:1=x", engineSpec{name: "cloud", model: "anthropic.model:1=x"}},
	} {
		got, err := parseEngineSpec(tc.in)
		if err != nil || got != tc.want {
			t.Errorf("parseEngineSpec(%q) = %+v, %v; want %+v", tc.in, got, err, tc.want)
		}
	}
	if _, err := parseEngineSpec("=nova-3"); err == nil {
		t.Error("parseEngineSpec(\"=nova-3\") named no decoder and was accepted")
	}
}
