// SPDX-License-Identifier: Apache-2.0

// Package testutil holds helpers shared by the Go test suites.
package testutil

import (
	"os"
	"path/filepath"
	"testing"
)

// maxSocketPath is the shortest sun_path limit among supported platforms
// (macOS: 104 bytes including the terminator; Linux: 108).
const maxSocketPath = 100

// SocketPath returns a path for a Unix-domain socket named base in a fresh
// temporary directory that is removed when the test ends. t.TempDir() is
// not used: it embeds the test name, and on macOS the result can
// exceed the sun_path limit, which surfaces as "connect: invalid argument".
func SocketPath(t testing.TB, base string) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "ley")
	if err != nil {
		t.Fatal(err)
	}
	if len(filepath.Join(dir, base)) > maxSocketPath {
		os.RemoveAll(dir)
		if dir, err = os.MkdirTemp("/tmp", "ley"); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	return filepath.Join(dir, base)
}
