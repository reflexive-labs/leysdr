// SPDX-License-Identifier: Apache-2.0

// Region 4: the waterfall. The Metal view draws rows from the feed's ring, newest at the top,
// one row per display pixel at 30 rows a second; SwiftUI draws what sits over it: the tuned
// channel, the pointer's hairline and badge, the time axis in seconds. Every gesture is handled
// by the Metal view (it owns the mouse) and lands in `AppSession.tune(to:)`.

import LeylineClient
import MetalKit
import SwiftUI

struct WaterfallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var pointer: CGPoint?
    @State private var dragStartHz: UInt64?
    @State private var dragHz: UInt64?
    @State private var problem: String?

    var body: some View {
        GeometryReader { geo in
            let columns = columns(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                WaterfallMetalView(
                    feed: session.spectrum,
                    floorDB: session.spectrum.floorDB,
                    viewLo: fraction(of: session.visibleRange?.lowerBound),
                    viewHi: fraction(of: session.visibleRange?.upperBound),
                    onPointer: { pointer = $0 },
                    onClick: { p in if let c = columns { session.tune(to: c.hz(atX: p.x)) } },
                    onDrag: { p, ended in drag(p, ended: ended, columns: columns) },
                    onScroll: { dy in session.step(dy > 0 ? 1 : -1, fine: true) },
                    onProblem: { problem = $0 }
                )
                if let c = columns { overlays(columns: c, size: geo.size) }
                if let problem {
                    EmptyWords(headline: "No waterfall", detail: problem)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.ground)
        .clipped()
    }

    private func columns(width: CGFloat) -> Columns? {
        guard let cap = session.capture, let r = session.visibleRange, cap.sampleRate > 0 else { return nil }
        return Columns(range: r, captureCenterHz: cap.centerHz, captureSpanHz: cap.sampleRate, bins: Int(SpectrumFeed.bins), width: width)
    }

    /// Where a frequency sits across the capture's span, 0 at its low edge and 1 at its high.
    private func fraction(of hz: UInt64?) -> Float {
        guard let hz, let cap = session.capture, cap.sampleRate > 0 else { return hz == nil ? 0 : 1 }
        let lo = Double(cap.centerHz) - Double(cap.sampleRate) / 2
        return Float(((Double(hz) - lo) / Double(cap.sampleRate)).clamped(to: 0...1))
    }

    private func drag(_ p: CGPoint, ended: Bool, columns: Columns?) {
        guard let columns else { return }
        let hz = columns.hz(atX: p.x)
        if dragStartHz == nil {
            dragStartHz = hz
            log("tune", "drag from \(hz) Hz")
        }
        dragHz = hz
        session.tune(to: hz, dragging: !ended)
        if ended {
            log("tune", "drag ended at \(hz) Hz")
            dragStartHz = nil
            dragHz = nil
        }
    }

    @ViewBuilder
    private func overlays(columns: Columns, size: CGSize) -> some View {
        // The tuned channel, continuous with the spectrum's band above.
        if let hz = session.tunedHz, let ch = session.channel {
            let x0 = columns.x(of: hz - UInt64(ch.bandwidthHz) / 2)
            let x1 = columns.x(of: hz + UInt64(ch.bandwidthHz) / 2)
            // The edges are overlaid before the offset: an overlay added after it is placed on
            // the un-shifted frame, at the left of the panel.
            Rectangle().fill(Theme.accent.opacity(0.11))
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: 1.5) }
                .overlay(alignment: .trailing) { Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: 1.5) }
                .frame(width: max(2, x1 - x0), height: size.height)
                .offset(x: x0)
                .allowsHitTesting(false)
        }
        TimeAxis(rowsPerPoint: Double(displayScale), height: size.height)
            .allowsHitTesting(false)
        // The pointer: a hairline at its frequency and a badge with the value, not the verb.
        if let p = pointer {
            let hz = dragHz ?? columns.hz(atX: p.x)
            Rectangle().fill(Theme.ink.opacity(0.35)).frame(width: 1, height: size.height)
                .offset(x: columns.x(of: hz))
                .allowsHitTesting(false)
            PointerBadge(text: badgeText(hz: hz))
                .offset(x: min(max(p.x + 12, 0), size.width - 130), y: min(max(p.y + 14, 0), size.height - 28))
                .allowsHitTesting(false)
        }
    }

    private func badgeText(hz: UInt64) -> String {
        let f = Frequency.fieldParts(hz)
        if let start = dragStartHz, start != hz {
            let sweep = start > hz ? start - hz : hz - start
            return "\(f.major) MHz · \(Frequency.format(sweep)) swept"
        }
        return "\(f.major) MHz"
    }
}

struct PointerBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(Theme.Font.value)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Theme.ground.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.border))
    }
}

/// `now` at the top, a tick every 5 s down the right edge, relative only.
struct TimeAxis: View {
    let rowsPerPoint: Double
    let height: CGFloat

    var body: some View {
        let secondsPerPoint = rowsPerPoint / SpectrumFeed.rowsPerSecond
        let tickEvery: CGFloat = CGFloat(5 / secondsPerPoint)
        let ticks = tickEvery > 0 ? Int(height / tickEvery) : 0
        ZStack(alignment: .topTrailing) {
            Text("now").font(Theme.Font.valueSmall).foregroundStyle(Theme.inkTertiary).padding(.trailing, 8).padding(.top, 4)
            ForEach(1...max(ticks, 1), id: \.self) { i in
                if i <= ticks {
                    Text("−\(i * 5) s").font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
                        .padding(.trailing, 8)
                        .offset(y: CGFloat(i) * tickEvery - 6)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topTrailing)
    }
}

// MARK: - Metal

struct WaterfallMetalView: NSViewRepresentable {
    let feed: SpectrumFeed
    let floorDB: Float
    let viewLo: Float
    let viewHi: Float
    let onPointer: (CGPoint?) -> Void
    let onClick: (CGPoint) -> Void
    let onDrag: (CGPoint, Bool) -> Void
    let onScroll: (CGFloat) -> Void
    /// Called once, off the update pass, if the renderer could not come up.
    let onProblem: (String) -> Void

    func makeCoordinator() -> WaterfallRenderer { WaterfallRenderer() }

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView(frame: .zero, device: context.coordinator.device)
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0x0B / 255.0, green: 0x0D / 255.0, blue: 0x0F / 255.0, alpha: 1)
        view.preferredFramesPerSecond = Int(SpectrumFeed.rowsPerSecond)
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.framebufferOnly = true
        apply(to: view, context: context)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        apply(to: view, context: context)
    }

    private func apply(to view: InteractiveMetalView, context: Context) {
        let r = context.coordinator
        r.buffer = feed.waterfall
        r.viewLo = viewLo
        r.viewHi = viewHi
        r.floorDB = floorDB
        view.onPointer = onPointer
        view.onClick = onClick
        view.onDrag = onDrag
        view.onScroll = onScroll
        if let problem = r.problem, !r.problemReported {
            r.problemReported = true
            let report = onProblem
            Task { @MainActor in report(problem) }
        }
    }
}

/// An MTKView that owns the mouse: the cursor teaches the gesture, and every event is handed
/// up as a point in the view's coordinates (origin top-left, points).
final class InteractiveMetalView: MTKView {
    var onPointer: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onDrag: ((CGPoint, Bool) -> Void)?
    var onScroll: ((CGFloat) -> Void)?
    private var tracking: NSTrackingArea?
    private var downAt: CGPoint?
    private var dragged = false

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        (downAt == nil ? NSCursor.crosshair : NSCursor.resizeLeftRight).set()
    }

    override func mouseMoved(with event: NSEvent) {
        onPointer?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        onPointer?(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        downAt = convert(event.locationInWindow, from: nil)
        dragged = false
        NSCursor.resizeLeftRight.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let start = downAt else { return }
        if !dragged, abs(p.x - start.x) < 3 { return }
        dragged = true
        onPointer?(p)
        onDrag?(p, false)
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if dragged { onDrag?(p, true) } else { onClick?(p) }
        downAt = nil
        dragged = false
        NSCursor.crosshair.set()
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        guard abs(dy) >= 1 else { return }
        onScroll?(dy)
    }
}

/// Uniforms the shader reads; scalars only, so the two layouts cannot disagree.
struct WaterfallUniforms {
    var head: UInt32 = 0
    var rowsWritten: UInt32 = 0
    var capacity: UInt32 = 0
    var bins: UInt32 = 0
    var viewLo: Float = 0
    var viewHi: Float = 1
    var floorU8: Float = 0
    var rangeU8: Float = 1
    var width: Float = 1
    var height: Float = 1
    var rowsPerPixel: Float = 1
    var pad: Float = 0
}

/// Fills a byte texture from the feed's ring and draws it through the ramp. S1's client half:
/// a signpost interval around each draw, matched by seq with the row's arrival.
@MainActor
final class WaterfallRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice?
    private let queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var texture: MTLTexture?
    private var uploaded = 0
    private var stops: [SIMD4<Float>] = Theme.levelStopsRGB.map { SIMD4($0, 1) }

    var buffer: WaterfallBuffer?
    var viewLo: Float = 0
    var viewHi: Float = 1
    var floorDB: Float = .nan
    /// Why there is no pipeline, in the compiler's or Metal's words; nil when it came up.
    private(set) var problem: String?
    var problemReported = false
    private(set) var frames = 0

    override init() {
        device = MTLCreateSystemDefaultDevice()
        queue = device?.makeCommandQueue()
        super.init()
        guard let device else {
            fail("no Metal device")
            return
        }
        do {
            let library = try device.makeLibrary(source: WaterfallShader.source, options: nil)
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: "waterfall_vertex")
            desc.fragmentFunction = library.makeFunction(name: "waterfall_fragment")
            desc.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: desc)
            log("waterfall", "shader compiled on \(device.name)")
        } catch {
            fail("\(error)")
        }
    }

    private func fail(_ why: String) {
        problem = "The waterfall shader did not load: \(why)"
        log("waterfall", problem!)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let device, let queue, let pipeline, let buffer, buffer.bins > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        if texture == nil || texture?.width != buffer.bins {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: buffer.bins, height: WaterfallBuffer.capacity, mipmapped: false)
            d.usage = [.shaderRead]
            d.storageMode = .managed
            texture = device.makeTexture(descriptor: d)
            uploaded = 0
            log("waterfall", "texture \(buffer.bins)×\(WaterfallBuffer.capacity), drawable \(Int(view.drawableSize.width))×\(Int(view.drawableSize.height))")
        }
        guard let texture else { return }
        upload(from: buffer, into: texture)

        let state = signposter.beginInterval("draw", "seq=\(buffer.newestSeq)")
        var u = WaterfallUniforms()
        u.capacity = UInt32(WaterfallBuffer.capacity)
        u.bins = UInt32(buffer.bins)
        u.rowsWritten = UInt32(min(buffer.count, WaterfallBuffer.capacity))
        u.head = buffer.count > 0 ? UInt32((buffer.count - 1) % WaterfallBuffer.capacity) : 0
        u.viewLo = viewLo
        u.viewHi = viewHi
        let floor = floorDB.isNaN ? -100 : floorDB
        u.floorU8 = (floor + DBU8.offset) * DBU8.scale
        u.rangeU8 = SpectrumFeed.rangeDB * DBU8.scale
        u.width = Float(view.drawableSize.width)
        u.height = Float(view.drawableSize.height)
        u.rowsPerPixel = 1

        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(texture, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<WaterfallUniforms>.stride, index: 0)
        stops.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 1) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        frames += 1
        signposter.endInterval("draw", state)
    }

    /// Copies the rows appended since the last draw; after a long stall the whole ring.
    private func upload(from buffer: WaterfallBuffer, into texture: MTLTexture) {
        let count = buffer.count
        guard count > uploaded else { return }
        let capacity = WaterfallBuffer.capacity
        let from = max(uploaded, count - capacity)
        for row in from..<count {
            let slot = row % capacity
            buffer.withRow(slot: slot) { ptr in
                texture.replace(region: MTLRegionMake2D(0, slot, buffer.bins, 1), mipmapLevel: 0, withBytes: ptr, bytesPerRow: buffer.bins)
            }
        }
        uploaded = count
    }
}
