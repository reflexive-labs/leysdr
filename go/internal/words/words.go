// SPDX-License-Identifier: Apache-2.0

// Package words holds the number agreement ley's sentences share, so that every verb, the MCP
// adapter and the fake daemon pluralise the same way.
package words

import "fmt"

// Count is n followed by the noun, plural when n is not 1: "1 channel", "2 channels". The plural
// is the noun with an s appended.
func Count(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return fmt.Sprintf("%d %ss", n, noun)
}

// Noun is the noun alone, with an s appended when n is not 1: "job", "jobs".
func Noun(n int, noun string) string {
	return Pick(n, noun, noun+"s")
}

// Pick returns one when n is 1 and many otherwise: Pick(n, "it", "them"), Pick(n, "was", "were").
func Pick(n int, one, many string) string {
	if n == 1 {
		return one
	}
	return many
}
