// SPDX-License-Identifier: Apache-2.0

package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// stagedBundleID is the bundle identifier of the copy of the app that leyshots runs. A staged
// run under the app's own identifier shares the person's defaults domain, saved state and window
// frames (AppKit and SwiftUI write a window's frame under "NSWindow Frame …" whatever the app
// asks), so it would change the app they use and depend on it.
const stagedBundleID = "com.leysdr.app.staged"

// stagedRequirement is the copy's designated requirement: its identifier alone.
const stagedRequirement = `designated => identifier "` + stagedBundleID + `"`

// stagedStamp, inside the copy, records the source it was made from; a copy whose stamp matches
// the source is reused.
const stagedStamp = "Contents/Resources/leyshots-staged-from"

// stagedApp returns a copy of the bundle at src in dir whose CFBundleIdentifier is
// stagedBundleID, ad-hoc signed again, so nothing a staged run writes lands in the person's own
// app's domain. The copy is made again only when the source's executable or Info.plist changes.
func stagedApp(ctx context.Context, src, dir string) (string, error) {
	stamp, err := bundleStamp(src)
	if err != nil {
		return "", fmt.Errorf("%s: %w; build it with: make app-bundle", src, err)
	}
	// The identifier and the requirement are in the stamp, so a change to either remakes the copy.
	stamp = stagedBundleID + " " + stagedRequirement + " " + stamp
	dst := filepath.Join(dir, filepath.Base(src))
	if b, err := os.ReadFile(filepath.Join(dst, stagedStamp)); err == nil && string(b) == stamp {
		return dst, nil
	}
	if err := os.RemoveAll(dst); err != nil {
		return "", err
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	run := func(name string, args ...string) error {
		if b, err := exec.CommandContext(ctx, name, args...).CombinedOutput(); err != nil {
			return fmt.Errorf("%s %s: %w: %s", name, strings.Join(args, " "), err, strings.TrimSpace(string(b)))
		}
		return nil
	}
	if err := run("ditto", src, dst); err != nil {
		return "", err
	}
	plist := filepath.Join(dst, "Contents", "Info.plist")
	if err := run("/usr/libexec/PlistBuddy", "-c", "Set :CFBundleIdentifier "+stagedBundleID, plist); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(dst, stagedStamp), []byte(stamp), 0o644); err != nil {
		return "", err
	}
	// The nested code (Sparkle) keeps its signature; only the bundle's own seal changed. The
	// designated requirement names the identifier rather than the build's hash, so the
	// Accessibility permission the ax command needs, granted to the copy once, holds for every
	// later copy.
	if err := run("codesign", "--force", "--sign", "-", "--timestamp=none",
		"-r="+stagedRequirement, dst); err != nil {
		return "", err
	}
	return dst, nil
}

// bundleStamp is a hash of the bundle's executable and Info.plist.
func bundleStamp(app string) (string, error) {
	h := sha256.New()
	for _, p := range []string{appExe, "Contents/Info.plist"} {
		f, err := os.Open(filepath.Join(app, p))
		if err != nil {
			return "", err
		}
		_, err = io.Copy(h, f)
		_ = f.Close() // read-only
		if err != nil {
			return "", err
		}
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// stagedAppIn is stagedApp with its copies kept in tmp/staged-app in the checkout.
func stagedAppIn(root string) func(context.Context, string) (string, error) {
	return func(ctx context.Context, src string) (string, error) {
		return stagedApp(ctx, src, filepath.Join(root, "tmp", "staged-app"))
	}
}
