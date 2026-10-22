// SPDX-License-Identifier: Apache-2.0

// The window's own picture in a staged run (docs/dev/app.md, "Staged runs"): the whole frame,
// toolbar and title bar included, drawn by AppKit into a bitmap at the backing scale. It needs
// no Screen Recording permission and does not depend on focus, Stage Manager or Mission
// Control, which `screencapture -l` does.
//
// The frame is the content view's superview (the theme frame), drawn with `cacheDisplay`. A
// `CAMetalLayer` draws nothing into that bitmap, so the waterfall would come out as its ground:
// each Metal view is drawn once more, offscreen (`WaterfallRenderer.picture(of:)`), and that
// image is laid in a plain layer over it for the length of the draw, under whatever SwiftUI
// draws over the Metal view (the seam, the tuned band, the pointer's hairline).

import AppKit
import MetalKit

@MainActor
enum WindowPicture {
    /// The window as PNG bytes at its backing scale, or nil when there is nothing to draw.
    static func png(of window: NSWindow) -> Data? {
        guard let frame = window.contentView?.superview else { return nil }
        let bounds = frame.bounds
        guard let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        let covers = coverMetalViews(in: frame)
        defer { for cover in covers { cover.removeFromSuperview() } }
        frame.cacheDisplay(in: bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }

    /// One layer-backed view over each Metal view under `root`, showing what it would draw now.
    private static func coverMetalViews(in root: NSView) -> [NSView] {
        var covers: [NSView] = []
        for view in metalViews(under: root) {
            guard let renderer = view.delegate as? WaterfallRenderer,
                let image = renderer.picture(of: view)
            else { continue }
            let cover = NSView(frame: view.bounds)
            cover.wantsLayer = true
            cover.layer?.contents = image
            cover.layer?.contentsGravity = .resize
            cover.autoresizingMask = [.width, .height]
            view.addSubview(cover)
            covers.append(cover)
        }
        return covers
    }

    private static func metalViews(under view: NSView) -> [MTKView] {
        if let mtk = view as? MTKView { return mtk.isHiddenOrHasHiddenAncestor ? [] : [mtk] }
        return view.subviews.flatMap { metalViews(under: $0) }
    }
}
