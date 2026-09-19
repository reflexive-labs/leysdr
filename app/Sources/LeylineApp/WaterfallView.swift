// SPDX-License-Identifier: Apache-2.0

// Region 4: the waterfall. The Metal view draws rows from the feed's ring, newest at the top,
// one row per display pixel at 30 rows a second; SwiftUI draws what sits over it: the tuned
// channel, the pointer's hairline and badge, the time axis in seconds. Every gesture is handled
// by the Metal view (it owns the mouse, through `ChartMouse` like the spectrum) and lands in
// `AppSession.tune(to:)`.

import Foundation
import LeylineClient
import MetalKit
import SwiftUI

struct WaterfallView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    @State private var pointer: CGPoint?
    @State private var problem: String?

    var body: some View {
        GeometryReader { geo in
            let columns = columns(width: geo.size.width)
            ZStack(alignment: .topLeading) {
                WaterfallMetalView(
                    feed: session.spectrum,
                    floorDB: session.rampFloorDB,
                    viewLo: fraction(of: session.visibleRange?.lowerBound),
                    viewHi: fraction(of: session.visibleRange?.upperBound),
                    onPointer: { p in
                        pointer = p
                        session.pointerHz = p.flatMap { columns?.hz(atX: $0.x) }
                    },
                    onClick: { p in if let c = columns { session.tune(to: c.hz(atX: p.x)) } },
                    onDrag: { p, ended in if let c = columns { session.chartDrag(to: c.hz(atX: p.x), ended: ended) } },
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

    @ViewBuilder
    private func overlays(columns: Columns, size: CGSize) -> some View {
        // The tuned channel, continuous with the spectrum's band above.
        if let hz = session.tunedHz, let ch = session.channel {
            TunedBand(x0: columns.x(of: hz - UInt64(ch.bandwidthHz) / 2), x1: columns.x(of: hz + UInt64(ch.bandwidthHz) / 2), height: size.height)
        }
        TimeAxis(rowsPerPoint: Double(displayScale), height: size.height)
            .allowsHitTesting(false)
        PointerOverlay(columns: columns, size: size, point: pointer)
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
        view.mouse.onPointer = onPointer
        view.mouse.onClick = onClick
        view.mouse.onDrag = onDrag
        view.mouse.onScroll = onScroll
        if let problem = r.problem, !r.problemReported {
            r.problemReported = true
            let report = onProblem
            Task { @MainActor in report(problem) }
        }
    }
}

/// An MTKView that owns the mouse through `ChartMouse`, every event handed up as a point in
/// the view's coordinates (origin top-left, points).
final class InteractiveMetalView: MTKView {
    let mouse = ChartMouse()
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: ChartMouse.trackingOptions, owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) { mouse.cursorUpdate() }
    override func mouseMoved(with event: NSEvent) { mouse.moved(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { mouse.exited() }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        mouse.down(convert(event.locationInWindow, from: nil))
    }
    override func mouseDragged(with event: NSEvent) { mouse.dragged(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) { mouse.up(convert(event.locationInWindow, from: nil)) }
    override func scrollWheel(with event: NSEvent) { mouse.scroll(event) }
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
    private var lastTextureFailure: CFAbsoluteTime = 0
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
            fail("The waterfall shader did not load: there is no Metal device.")
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
            fail("The waterfall shader did not load: \(error)")
        }
    }

    /// The first failure is the one that explains the dark panel, so it is the one kept, and it
    /// goes to the log as well as to the window.
    private func fail(_ what: String) {
        guard problem == nil else { return }
        problem = what
        log("waterfall", what)
    }

    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let device, let queue, let pipeline, let buffer, buffer.bins > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor else { return }
        if texture == nil || texture?.width != buffer.bins {
            guard let made = makeRingTexture(device: device, bins: buffer.bins) else { return }
            texture = made
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

    /// The ring texture, or nil while Metal is refusing one. A refusal says so in the window
    /// once and is retried at most once a second: `draw(in:)` runs at the row rate, so an
    /// ungated retry would ask thirty times a second and the panel would stay dark without a word.
    private func makeRingTexture(device: MTLDevice, bins: Int) -> MTLTexture? {
        guard CFAbsoluteTimeGetCurrent() - lastTextureFailure >= 1 else { return nil }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Uint, width: bins, height: WaterfallBuffer.capacity, mipmapped: false)
        d.usage = [.shaderRead]
        d.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: d) else {
            lastTextureFailure = CFAbsoluteTimeGetCurrent()
            fail("The waterfall has no texture: Metal refused \(bins)×\(WaterfallBuffer.capacity) bytes on \(device.name).")
            return nil
        }
        return texture
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
