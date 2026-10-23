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

#if LEYLINE_STAGING
    @MainActor
    enum WindowPicture {
        /// The window as PNG bytes at its backing scale, or nil when there is nothing to draw. The
        /// windows over it (an open popover, a sheet) are drawn in at their places, so the picture
        /// shows what the person sees; a menu that is open is not, because its window is not the
        /// app's to draw.
        static func png(of window: NSWindow) -> Data? {
            guard let rep = bitmap(of: window) else { return nil }
            let over = overlying(window)
            if !over.isEmpty, let context = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                for child in over {
                    guard let drawn = image(of: child) else { continue }
                    let image = child === window.attachedSheet ? grounded(drawn, child) : drawn
                    // Both frames are in screen points from the bottom left, as the bitmap's
                    // context draws.
                    let at = NSRect(
                        x: child.frame.minX - window.frame.minX,
                        y: child.frame.minY - window.frame.minY,
                        width: child.frame.width, height: child.frame.height)
                    image.draw(
                        in: at, from: .zero, operation: .sourceOver, fraction: 1,
                        respectFlipped: false, hints: nil)
                }
                context.flushGraphics()
                NSGraphicsContext.restoreGraphicsState()
            }
            // In sRGB whatever screen the window is on, so two runs on two displays give one picture.
            let srgb = rep.converting(to: .sRGB, renderingIntent: .default) ?? rep
            return srgb.representation(using: .png, properties: [:])
        }

        /// The windows drawn over `window`, bottom first: its visible child windows (a popover's)
        /// and the sheet attached to it.
        static func overlying(_ window: NSWindow) -> [NSWindow] {
            var out = (window.childWindows ?? []).filter(\.isVisible)
            if let sheet = window.attachedSheet, sheet.isVisible, !out.contains(sheet) {
                out.append(sheet)
            }
            return out
        }

        /// One window's frame view drawn into a bitmap at its backing scale.
        private static func bitmap(of window: NSWindow) -> NSBitmapImageRep? {
            guard let frame = window.contentView?.superview else { return nil }
            let bounds = frame.bounds
            guard let rep = frame.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
            let covers = coverMetalViews(in: frame)
            defer { for cover in covers { cover.removeFromSuperview() } }
            // Glass and vibrancy are drawn by the window server, not into the bitmap, where they
            // come out white under a sheet's white text; they are left out of the picture, and
            // `grounded` lays the sheet on its appearance's ground instead.
            let glass = window.isSheet ? materials(under: frame).filter { !$0.isHidden } : []
            for v in glass { v.isHidden = true }
            defer { for v in glass { v.isHidden = false } }
            frame.cacheDisplay(in: bounds, to: rep)
            return rep
        }

        /// The corners of macOS 26's alert sheet, as its glass draws them.
        static let sheetCornerRadius: CGFloat = 24

        /// A sheet's picture laid on the window background of its appearance, in the sheet's
        /// rounded shape: its glass is left out of the bitmap (`bitmap(of:)`), since cacheDisplay
        /// draws it white under the dark appearance's white text.
        private static func grounded(_ image: NSImage, _ sheet: NSWindow) -> NSImage {
            let rect = NSRect(origin: .zero, size: image.size)
            return NSImage(size: image.size, flipped: false) { _ in
                sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
                    NSColor.windowBackgroundColor.setFill()
                    NSBezierPath(
                        roundedRect: rect, xRadius: sheetCornerRadius, yRadius: sheetCornerRadius
                    ).fill()
                }
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
        }

        /// `bitmap(of:)` as an image a context can draw, sized in points.
        private static func image(of window: NSWindow) -> NSImage? {
            guard let rep = bitmap(of: window) else { return nil }
            let image = NSImage(size: window.frame.size)
            image.addRepresentation(rep)
            return image
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

        private static func materials(under view: NSView) -> [NSView] {
            if view is NSVisualEffectView || NSStringFromClass(type(of: view)).contains("Glass") {
                return [view]
            }
            return view.subviews.flatMap { materials(under: $0) }
        }

        private static func metalViews(under view: NSView) -> [MTKView] {
            if let mtk = view as? MTKView { return mtk.isHiddenOrHasHiddenAncestor ? [] : [mtk] }
            return view.subviews.flatMap { metalViews(under: $0) }
        }
    }
#endif
