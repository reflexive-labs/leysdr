#!/usr/bin/env swift
// SPDX-License-Identifier: Apache-2.0
//
// Draws an HTML page to a PNG at 2× for the site's terminal shots and the CHIRP table
// (docs/plans/site-shots.md, "Terminal shots"): `leyshots` writes the page in the site's terminal
// theme and this script turns it into the image. WebKit, AppKit and ImageIO only, so it runs on
// any Mac with the Swift toolchain.
//
//   swift scripts/render-html.swift <in.html> <out.png> --width <points>
//
// The page is laid out <points> wide in an off-screen WKWebView, which is then sized to the
// page's height once the page has loaded and `document.fonts.ready` has resolved, so the snapshot
// is taken in the final font. The PNG is twice the page's size in pixels on any screen: WebKit's
// snapshot is asked for at the width that gives 2× on the main screen's backing scale, then
// drawn into a bitmap of exactly 2× the page, so a 1× display still gives the site 2× images.
// Any failure exits 1 with one line on stderr.

import AppKit
import ImageIO
import WebKit

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-html: \(message)\n".utf8))
    exit(1)
}

let usage = "usage: swift scripts/render-html.swift <in.html> <out.png> --width <points>"
var positional: [String] = []
var width: CGFloat = 0
var argv = CommandLine.arguments.dropFirst()
while let a = argv.popFirst() {
    if a == "--width" {
        guard let v = argv.popFirst(), let w = Double(v), w.isFinite, w > 0 else { fail(usage) }
        width = CGFloat(w)
    } else {
        positional.append(a)
    }
}
guard positional.count == 2, width > 0 else { fail(usage) }
let input = URL(fileURLWithPath: positional[0]).standardizedFileURL
let output = URL(fileURLWithPath: positional[1])
guard FileManager.default.isReadableFile(atPath: input.path) else {
    fail("cannot read \(input.path)")
}

/// The pixel scale of the PNG: the site's images are all 2×.
let scale: CGFloat = 2
/// A page that has not drawn by now is not going to.
let timeoutSeconds: Double = 30

final class Renderer: NSObject, WKNavigationDelegate {
    let window: NSWindow
    let webView: WKWebView

    override init() {
        let frame = NSRect(x: 0, y: 0, width: width, height: 100)
        webView = WKWebView(frame: frame, configuration: WKWebViewConfiguration())
        // Borderless and far off every screen, so nothing shows; a web view in a window lays out
        // and paints as it would on screen, which a snapshot after screen updates waits for.
        window = NSWindow(
            contentRect: frame.offsetBy(dx: -20000, dy: -20000), styleMask: [.borderless],
            backing: .buffered, defer: false)
        super.init()
        window.contentView = webView
        webView.navigationDelegate = self
        window.orderFront(nil)
    }

    func start() {
        webView.loadFileURL(input, allowingReadAccessTo: input.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.callAsyncJavaScript(
            """
            await document.fonts.ready;
            const e = document.documentElement;
            return [e.scrollWidth, e.scrollHeight];
            """,
            arguments: [:], in: nil, in: .page
        ) { result in
            switch result {
            case .success(let value):
                let size = (value as? [NSNumber])?.map(\.doubleValue) ?? []
                guard size.count == 2, size.allSatisfy({ $0.isFinite && $0 > 0 }) else {
                    fail("the page reported no size")
                }
                // --width is the least the page is drawn at: a page laid out in `ch` follows the
                // font WebKit really uses, whose advance can be wider than the caller assumed,
                // and a fixed width would clip the last column.
                width = max(width, CGFloat(size[0]).rounded(.up))
                self.snapshot(height: CGFloat(size[1]).rounded(.up))
            case .failure(let error):
                fail("the page's height could not be read: \(error.localizedDescription)")
            }
        }
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error
    ) {
        fail("\(input.path) did not load: \(error.localizedDescription)")
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        fail("\(input.path) did not load: \(error.localizedDescription)")
    }

    func snapshot(height: CGFloat) {
        let size = NSSize(width: width, height: height)
        window.setContentSize(size)
        webView.setFrameSize(size)
        let config = WKSnapshotConfiguration()
        config.rect = NSRect(origin: .zero, size: size)
        config.afterScreenUpdates = true
        // `snapshotWidth` is in points of the snapshot image, whose pixels follow the screen's
        // backing scale; this width makes it 2× the page in pixels.
        let backing = NSScreen.main?.backingScaleFactor ?? 1
        config.snapshotWidth = NSNumber(value: Double(width * scale / backing))
        webView.takeSnapshot(with: config) { image, error in
            guard let image else {
                fail("no snapshot: \(error?.localizedDescription ?? "WebKit gave no reason")")
            }
            self.write(image, size: size)
        }
    }

    /// Draws the snapshot into an sRGB bitmap of exactly 2× the page, the colour space the
    /// site's theme colours are written in, and writes it as PNG.
    func write(_ image: NSImage, size: NSSize) {
        let pixelsWide = Int((size.width * scale).rounded())
        let pixelsHigh = Int((size.height * scale).rounded())
        var proposed = NSRect(origin: .zero, size: image.size)
        guard let snapshot = image.cgImage(forProposedRect: &proposed, context: nil, hints: nil)
        else { fail("the snapshot has no bitmap") }
        if snapshot.width < pixelsWide {
            let warning = "the snapshot is \(snapshot.width) px wide, scaled up to \(pixelsWide)"
            FileHandle.standardError.write(Data("render-html: \(warning)\n".utf8))
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let ctx = CGContext(
                data: nil, width: pixelsWide, height: pixelsHigh, bitsPerComponent: 8,
                bytesPerRow: 0, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { fail("no \(pixelsWide)×\(pixelsHigh) bitmap") }
        ctx.interpolationQuality = .high
        ctx.draw(snapshot, in: CGRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh))
        guard let drawn = ctx.makeImage(),
            let dest = CGImageDestinationCreateWithURL(
                output as CFURL, "public.png" as CFString, 1, nil)
        else { fail("cannot write \(output.path)") }
        CGImageDestinationAddImage(dest, drawn, nil)
        guard CGImageDestinationFinalize(dest) else { fail("cannot write \(output.path)") }
        print(output.path)
        exit(0)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
    fail("\(input.path) did not draw within \(Int(timeoutSeconds)) s")
}
app.run()
