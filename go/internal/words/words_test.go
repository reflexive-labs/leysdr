// SPDX-License-Identifier: Apache-2.0

package words

import "testing"

func TestAgreement(t *testing.T) {
	cases := []struct{ got, want string }{
		{Count(0, "channel"), "0 channels"},
		{Count(1, "channel"), "1 channel"},
		{Count(2, "other channel"), "2 other channels"},
		{Noun(1, "job"), "job"},
		{Noun(3, "decode job"), "decode jobs"},
		{Pick(1, "it", "them"), "it"},
		{Pick(2, "was", "were"), "were"},
		{Pick(1, "", "s"), ""},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("got %q, want %q", c.got, c.want)
		}
	}
}
