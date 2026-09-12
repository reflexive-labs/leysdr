// SPDX-License-Identifier: Apache-2.0

package leyline

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
)

// The pidfile and log are named after the socket, so two sockets in one
// directory (/tmp/leyline-<uid>.sock for every user) never share them.
func TestPidAndLogPathsFollowSocketName(t *testing.T) {
	env := func(m map[string]string) func(string) string { return func(k string) string { return m[k] } }
	uid := strconv.Itoa(os.Getuid())
	tmp := os.TempDir()
	home := homeDir()

	// Non-darwin, nothing set: /tmp/leyline-<uid>.{sock,pid,log}.
	sock := defaultSocketPath("linux", env(nil))
	if want := filepath.Join(tmp, "leyline-"+uid+".sock"); sock != want {
		t.Fatalf("linux socket %q, want %q", sock, want)
	}
	if got, want := PidPathFor(sock), filepath.Join(tmp, "leyline-"+uid+".pid"); got != want {
		t.Errorf("linux pid %q, want %q", got, want)
	}
	if got, want := defaultLogPath("linux", sock), filepath.Join(tmp, "leyline-"+uid+".log"); got != want {
		t.Errorf("linux log %q, want %q", got, want)
	}
	// XDG_RUNTIME_DIR: leyline.{sock,pid,log} inside it.
	sock = defaultSocketPath("linux", env(map[string]string{"XDG_RUNTIME_DIR": "/run/user/7"}))
	if sock != "/run/user/7/leyline.sock" || PidPathFor(sock) != "/run/user/7/leyline.pid" || defaultLogPath("linux", sock) != "/run/user/7/leyline.log" {
		t.Errorf("xdg: %q %q %q", sock, PidPathFor(sock), defaultLogPath("linux", sock))
	}
	// darwin: the socket dir under Application Support, the log under ~/Library/Logs.
	sock = defaultSocketPath("darwin", env(nil))
	dir := filepath.Join(home, "Library", "Application Support", "Leyline")
	if sock != filepath.Join(dir, "leyline.sock") || PidPathFor(sock) != filepath.Join(dir, "leyline.pid") {
		t.Errorf("darwin: %q %q", sock, PidPathFor(sock))
	}
	if got, want := defaultLogPath("darwin", sock), filepath.Join(home, "Library", "Logs", "Leyline", "leylined.log"); got != want {
		t.Errorf("darwin log %q, want %q", got, want)
	}
	// LEYLINE_SOCKET overrides everywhere; an odd name still gets siblings.
	sock = defaultSocketPath("darwin", env(map[string]string{SocketEnv: "/srv/radio/main"}))
	if sock != "/srv/radio/main" || PidPathFor(sock) != "/srv/radio/main.pid" || LogPathFor(sock) != "/srv/radio/main.log" {
		t.Errorf("override: %q %q %q", sock, PidPathFor(sock), LogPathFor(sock))
	}
}
