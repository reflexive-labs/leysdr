// Package leyline is the Go client library for the Leyline daemon. It wraps the
// generated leyline.v1 gRPC stubs with connection setup, client identity
// metadata, error mapping, and small helpers shared by the ley CLI/TUI and the
// MCP adapter.
package leyline

import (
	"os"
	"path/filepath"
	"runtime"
	"strconv"
)

// SocketEnv is the environment variable that overrides DefaultSocketPath.
const SocketEnv = "LEYLINE_SOCKET"

// LaunchAgentLabel is the launchd label of the daemon's LaunchAgent.
const LaunchAgentLabel = "com.leyline.daemon"

// DefaultSocketPath returns the daemon's UDS path for this user. LEYLINE_SOCKET
// overrides; otherwise macOS uses ~/Library/Application Support/Leyline/leyline.sock,
// and other platforms use $XDG_RUNTIME_DIR/leyline.sock or /tmp/leyline-<uid>.sock.
func DefaultSocketPath() string {
	if p := os.Getenv(SocketEnv); p != "" {
		return p
	}
	if runtime.GOOS == "darwin" {
		return filepath.Join(homeDir(), "Library", "Application Support", "Leyline", "leyline.sock")
	}
	if dir := os.Getenv("XDG_RUNTIME_DIR"); dir != "" {
		return filepath.Join(dir, "leyline.sock")
	}
	return filepath.Join(os.TempDir(), "leyline-"+strconv.Itoa(os.Getuid())+".sock")
}

// DefaultPidPath returns the daemon pidfile path: leylined.pid beside the socket.
func DefaultPidPath() string {
	return filepath.Join(filepath.Dir(DefaultSocketPath()), "leylined.pid")
}

// DefaultLogPath returns the daemon log path: ~/Library/Logs/Leyline/leylined.log
// on macOS, otherwise leylined.log beside the socket.
func DefaultLogPath() string {
	if runtime.GOOS == "darwin" {
		return filepath.Join(homeDir(), "Library", "Logs", "Leyline", "leylined.log")
	}
	return filepath.Join(filepath.Dir(DefaultSocketPath()), "leylined.log")
}

// DefaultLaunchAgentPath returns the path of the daemon's launchd plist
// (~/Library/LaunchAgents/com.leyline.daemon.plist). It is a macOS concept but
// the path is computed on every platform so tooling can print it.
func DefaultLaunchAgentPath() string {
	return filepath.Join(homeDir(), "Library", "LaunchAgents", LaunchAgentLabel+".plist")
}

func homeDir() string {
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		return h
	}
	return os.TempDir()
}
