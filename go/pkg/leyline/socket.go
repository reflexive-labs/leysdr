// SPDX-License-Identifier: Apache-2.0

// Package leyline is the Go client library for the Leyline daemon. It wraps the
// generated leyline.v1 gRPC stubs with the transport (Dial, with the flow-control
// windows the daemon needs, and client identity metadata), the error-code
// registry and its mapping from gRPC status, selectors that resolve what a
// person types to a device, capture, channel or job, event and telemetry
// streams and bulk subscriptions with their payload decoders, recordings and
// decode records, the daemon's socket paths, and the demodulator mode names.
// The input parsers live in pkg/units and the band table in pkg/bandplan.
package leyline

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// SocketEnv is the environment variable that overrides DefaultSocketPath.
const SocketEnv = "LEYLINE_SOCKET"

// DefaultSocketPath returns the daemon's UDS path for this user. LEYLINE_SOCKET
// overrides; otherwise macOS uses ~/Library/Application Support/Leyline/leyline.sock,
// and other platforms use $XDG_RUNTIME_DIR/leyline.sock or /tmp/leyline-<uid>.sock.
func DefaultSocketPath() string {
	return defaultSocketPath(runtime.GOOS, os.Getenv)
}

func defaultSocketPath(goos string, getenv func(string) string) string {
	if p := getenv(SocketEnv); p != "" {
		return p
	}
	if goos == "darwin" {
		return filepath.Join(homeDir(), "Library", "Application Support", "Leyline", "leyline.sock")
	}
	if dir := getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "leyline.sock")
	}
	return filepath.Join(os.TempDir(), "leyline-"+strconv.Itoa(os.Getuid())+".sock")
}

// DefaultPidPath returns the daemon pidfile path: PidPathFor(DefaultSocketPath()).
func DefaultPidPath() string {
	return PidPathFor(DefaultSocketPath())
}

// PidPathFor returns the pidfile beside socket, named after it with .pid in
// place of .sock (leyline.sock -> leyline.pid, /tmp/leyline-501.sock ->
// /tmp/leyline-501.pid), so two sockets sharing a directory never share a pidfile.
func PidPathFor(socket string) string {
	return sibling(socket, ".pid")
}

// DefaultLogPath returns the daemon log path: ~/Library/Logs/Leyline/leylined.log
// on macOS, otherwise LogPathFor(DefaultSocketPath()).
func DefaultLogPath() string {
	return defaultLogPath(runtime.GOOS, DefaultSocketPath())
}

func defaultLogPath(goos, socket string) string {
	if goos == "darwin" {
		return filepath.Join(homeDir(), "Library", "Logs", "Leyline", "leylined.log")
	}
	return LogPathFor(socket)
}

// LogPathFor returns the log file beside socket, named after it with .log in
// place of .sock (see PidPathFor).
func LogPathFor(socket string) string {
	return sibling(socket, ".log")
}

// sibling is socket's directory joined with its base name, extension replaced by ext.
func sibling(socket, ext string) string {
	return filepath.Join(filepath.Dir(socket), strings.TrimSuffix(filepath.Base(socket), filepath.Ext(socket))+ext)
}

func homeDir() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	return os.TempDir()
}
