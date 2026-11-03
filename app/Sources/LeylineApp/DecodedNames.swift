// SPDX-License-Identifier: Apache-2.0

// Decoding, seen from the radio (docs/plans/decoders-app.md, DA-9): the Radio sidebar's row per
// running decoder, and the waterfall's tags, each transmitter's name at its decoder's frequency
// on the row its record arrived in. The rules are `LeylineClient`'s (`WaterfallTags.swift`); here
// are the record subscription, the session's half and the views. The tags are SwiftUI over the
// Metal view, as the tuned band and the pointer's badge are, not a pass of the shader: they are
// text, few, and change only when a record arrives.

import LeylineClient
import LeylineProto
import SwiftUI

/// The records every decoder sends, while the Radio shows, the names are on and a decode job
/// runs on a radio, folded into `WaterfallTags`. One `SubscribeRecords` for all of them, live
/// only, opened again after a failure; each time it opens, the last minute is read back
/// (`onOpen`, `AppSession.backfillDecodedNames`), so what was decoded before it still has a tag.
@MainActor
@Observable
final class DecodedNamesFeed {
    private(set) var tags = WaterfallTags()
    /// Each record as it arrives; the session decides whether it tags and where.
    @ObservationIgnored var onRecord: ((Leyline_V1_DecodeRecord) -> Void)?
    /// The subscription has just opened; the session reads the last minute back.
    @ObservationIgnored var onOpen: (() -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var captureID: String?
    @ObservationIgnored private var connection: DaemonConnection?

    /// After the stream fails, this long before it is opened again.
    static let retrySeconds: Double = 2

    /// Opens the subscription while `wanted`, and closes it, forgetting the tags, otherwise. A
    /// change of capture forgets them too: their rows were the old capture's.
    func follow(_ wanted: Bool, captureID: String?, connection: DaemonConnection?) {
        if captureID != self.captureID {
            self.captureID = captureID
            if !tags.isEmpty { tags.removeAll() }
        }
        guard wanted, let connection else {
            if task != nil {
                task?.cancel()
                task = nil
                log("waterfall", "decoded names: not following")
            }
            if !tags.isEmpty { tags.removeAll() }
            return
        }
        if task != nil, connection === self.connection { return }
        self.connection = connection
        open(connection)
    }

    private func open(_ connection: DaemonConnection) {
        task?.cancel()
        let stream = connection.records(scope: .all)
        log("waterfall", "decoded names: following every decoder's records")
        // After the stream is asked for, so a record lands live, read back, or both, and the
        // fold keeps it once.
        onOpen?()
        task = Task { [weak self] in
            do {
                for try await r in stream {
                    if Task.isCancelled { return }
                    self?.onRecord?(r)
                }
            } catch {
                if Task.isCancelled { return }
                log("waterfall", "decoded names: records ended: \(LeylineError(error))")
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(Self.retrySeconds))
            guard let self, !Task.isCancelled, self.task != nil else { return }
            self.open(connection)
        }
    }

    /// Tags `record` at `frequencyHz` on the newest of `rows`, after dropping the tags whose rows
    /// have gone.
    func add(
        _ record: Leyline_V1_DecodeRecord, display: Leyline_V1_DecoderDisplay?,
        frequencyHz: UInt64, captureID: String, rows: Int, horizon: Int
    ) {
        var t = tags
        t.expire(rows: rows, horizon: horizon, captureID: captureID)
        let added = t.add(
            record, display: display, frequencyHz: frequencyHz, captureID: captureID, rows: rows,
            at: Date())
        if t != tags { tags = t }
        if added, let name = tags.tags.first?.name {
            log("waterfall", "tag \(name) at \(frequencyHz) Hz on row \(rows)")
        }
    }

    /// Whether the subscription is open, so the tags and counts are the window's own.
    var isFollowing: Bool { task != nil }

    /// Notes a record that may tag nothing, for its job's count.
    func hold(_ record: Leyline_V1_DecodeRecord) {
        var t = tags
        t.hold(record)
        if t != tags { tags = t }
    }

    /// The records read back, after dropping the tags whose rows have gone: `held` for the
    /// counts, `items` for the tags. Logs how many of them tagged.
    func backfill(
        _ items: [WaterfallTags.Backfill], held: [Leyline_V1_DecodeRecord], captureID: String,
        rows: Int, horizon: Int
    ) {
        var t = tags
        t.expire(rows: rows, horizon: horizon, captureID: captureID)
        for r in held { t.hold(r) }
        let added = t.backfill(items, captureID: captureID)
        if t != tags { tags = t }
        log(
            "waterfall",
            "decoded names: \(held.count) records from the last minute, \(added) tagged")
        let read = Set(items.map(\.record.recordID))
        for tag in tags.tags.reversed() where read.contains(tag.id) {
            log(
                "waterfall", "tag \(tag.name) at \(tag.frequencyHz) Hz on row \(tag.row), read back"
            )
        }
    }
}

extension AppSession {
    /// Whether the waterfall follows the decoders' records: the names are on, the Radio shows,
    /// and a decode job runs on a radio. Called on every mirror change and when the place or
    /// the View item changes.
    func followDecodedNames() {
        let decoding = state.jobs.contains { j in
            guard case .decode(let d)? = j.config, d.sourceUri.isEmpty else { return false }
            return DecoderPages.isLive(j)
        }
        let wanted = showsDecodedNames && place == .radio && isLive && capture != nil && decoding
        if decodedNames.onRecord == nil {
            decodedNames.onRecord = { [weak self] r in self?.landDecodedName(r) }
            decodedNames.onOpen = { [weak self] in self?.backfillDecodedNames() }
        }
        decodedNames.follow(wanted, captureID: capture?.captureID, connection: daemonConnection)
    }

    /// One record from any decoder: a tag when it is an audio decoder's inside the window's
    /// capture (`WaterfallTags.frequency`), on the waterfall's newest row.
    private func landDecodedName(_ r: Leyline_V1_DecodeRecord) {
        decodedNames.hold(r)
        guard
            let cap = capture,
            let hz = WaterfallTags.frequency(
                of: r, jobs: state.jobs, manifests: decoders.manifests ?? [],
                channels: state.channels, capture: cap)
        else { return }
        let m = decoders.manifest(named: r.protocol)
        decodedNames.add(
            r, display: m.flatMap { $0.hasDisplay ? $0.display : nil }, frequencyHz: hz,
            captureID: cap.captureID, rows: spectrum.waterfall.count,
            horizon: waterfallTagHorizon)
    }

    /// The last minute of every running decoder's records, read with `QueryRecords` when the
    /// tags start (DA-21): an audio decoder's are tagged on the rows their times fell in, while
    /// those rows show, under the live rules (`WaterfallTags.backfill`), and every decoder's
    /// give its sidebar row's count. A failed read leaves the live tags alone.
    func backfillDecodedNames() {
        guard let daemon = daemonConnection else { return }
        let protocols = WaterfallTags.backfillProtocols(
            decoders.manifests ?? [], jobs: state.jobs)
        guard !protocols.isEmpty else { return }
        let since = Int64((Date().timeIntervalSince1970 - WaterfallTags.backfillSeconds) * 1e9)
        Task { [weak self] in
            var pages: [Leyline_V1_RecordPage] = []
            for p in protocols {
                var q = Leyline_V1_RecordQuery()
                q.protocol = p
                q.sinceNs = since
                q.limit = UInt32(DecoderPages.logLimit)
                do {
                    pages.append(try await daemon.decoders.queryRecords(q))
                } catch {
                    log(
                        "waterfall",
                        "decoded names: \(p)'s last minute not read: \(LeylineError(error))")
                }
            }
            self?.landBackfill(pages)
        }
    }

    private func landBackfill(_ pages: [Leyline_V1_RecordPage]) {
        guard let cap = capture, decodedNames.isFollowing else { return }
        let rows = spectrum.waterfall.count
        let horizon = waterfallTagHorizon
        let held = spectrum.waterfall.clipped
        let now = Date()
        var items: [WaterfallTags.Backfill] = []
        var all: [Leyline_V1_DecodeRecord] = []
        for page in pages {
            for r in page.records {
                all.append(r)
                guard
                    let hz = WaterfallTags.frequency(
                        of: r, jobs: state.jobs, manifests: decoders.manifests ?? [],
                        channels: state.channels, capture: cap),
                    r.hasTime, r.time.captureID == cap.captureID,
                    let row = held.row(atSample: r.time.sampleIndex, captureID: cap.captureID),
                    rows - (row + 1) < horizon
                else { continue }
                let m = decoders.manifest(named: r.protocol)
                items.append(
                    WaterfallTags.Backfill(
                        record: r, display: m.flatMap { $0.hasDisplay ? $0.display : nil },
                        frequencyHz: hz, row: row + 1,
                        at: RecordEntry.dated(r, anchors: page.anchors, fallback: now).at))
            }
        }
        decodedNames.backfill(
            items, held: all, captureID: cap.captureID, rows: rows, horizon: horizon)
    }

    /// How many rows the waterfall shows, the tags' horizon: its height in device pixels, a row
    /// each, and never more than the ring holds.
    var waterfallTagHorizon: Int {
        let shown = waterfallRowsShown > 0 ? waterfallRowsShown : WaterfallBuffer.capacity
        return min(shown, WaterfallBuffer.capacity)
    }

    /// The tags the waterfall draws now, newest first: on the window's capture, their rows still
    /// shown, and their frequency inside the view. Empty while the names are off.
    var shownWaterfallTags: [WaterfallTag] {
        guard showsDecodedNames, let range = visibleRange else { return [] }
        return decodedNames.tags.shown(
            rows: spectrum.waterfall.count, horizon: waterfallTagHorizon,
            captureID: capture?.captureID
        ).filter { range.contains($0.frequencyHz) }
    }

    /// The Radio sidebar's rows, one per running decoder.
    var decodingRows: [DecodingRow] {
        DecodingRow.rows(
            decoders.manifests ?? [], jobs: state.jobs,
            held: decodedNames.isFollowing ? decodedNames.tags.lastSeq : [:])
    }

    /// A decoding row's click: the Decoders place with that decoder's page.
    func openDecoder(_ name: String) {
        decoders.select(name)
        place = .decoders
        log("sidebar", "opened \(name) in Decoders")
    }
}

/// The Radio sidebar's top: a row per running decoder, its symbol in `good` (`caution` while
/// degraded), its title and the count: the records the window holds of its job while the tags
/// follow them, else out of its job's detail, which is the row's tooltip whole. A
/// click opens its page in Decoders. Nothing while no decoder runs.
struct DecodingRowsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let rows = session.decodingRows
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    DecodingRowView(row: row)
                        .contentShape(Rectangle())
                        .onTapGesture { session.openDecoder(row.decoder) }
                        .pressableGroup("sidebar.decoder.\(ViewIdentifier.slug(row.decoder))") {
                            session.openDecoder(row.decoder)
                        }
                        .help(row.detail)
                }
            }
            .padding(.top, 8)
        }
    }
}

struct DecodingRowView: View {
    let row: DecodingRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: row.symbol)
                .font(Theme.Font.rowGlyph)
                .foregroundStyle(row.degraded ? Theme.caution : Theme.good)
                .frame(width: Theme.Layout.decoderSymbolWidth)
            Text(row.title).font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(row.count).font(Theme.Font.footnote)
                .foregroundStyle(row.degraded ? Theme.caution : Theme.inkFaint)
                .lineLimit(1)
        }
        .padding(.horizontal, 14).padding(.vertical, 4)
    }
}

/// The waterfall's tags: each a dot on its frequency and the transmitter's name beside it, on the
/// row its record arrived in, moving down with the rows. Laid out once per change of the tags
/// (`WaterfallTagLayer`, which is equatable) and moved by one offset per row, so a row costs an
/// offset and no layout or allocation. A tag below the bottom is clipped with the waterfall and
/// dropped when the next record arrives. Hidden from accessibility, as the rows are: the sidebar's
/// row says what is decoding.
struct WaterfallTagsOverlay: View {
    @Environment(AppSession.self) private var session
    @Environment(\.displayScale) private var displayScale
    let columns: Columns
    let size: CGSize

    var body: some View {
        let feed = session.spectrum
        let tags = session.decodedNames.tags.tags
        // Reading `rows` subscribes the overlay to each row, as `KeptBars` is.
        let count = feed.rows > 0 ? feed.waterfall.count : 0
        let anchor = tags.first?.row ?? count
        let scale = max(displayScale, 1)
        if !tags.isEmpty, count >= anchor {
            WaterfallTagLayer(
                tags: tags, anchor: anchor, range: columns.range, width: size.width,
                captureID: session.capture?.captureID ?? "", scale: scale, columns: columns
            )
            .equatable()
            .offset(y: CGFloat(count - anchor) / scale)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The tags placed against the newest tag's row, `anchor`, each with its top on its row; the
/// overlay moves the whole layer.
struct WaterfallTagLayer: View, Equatable {
    let tags: [WaterfallTag]
    let anchor: Int
    let range: ClosedRange<UInt64>
    let width: CGFloat
    let captureID: String
    let scale: CGFloat
    let columns: Columns

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.tags == b.tags && a.anchor == b.anchor && a.range == b.range && a.width == b.width
            && a.captureID == b.captureID && a.scale == b.scale
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(tags) { t in
                if t.captureID == captureID, range.contains(t.frequencyHz) {
                    WaterfallTagView(name: t.name)
                        .offset(
                            x: columns.x(of: t.frequencyHz) - Theme.Layout.waterfallTagDot / 2,
                            y: CGFloat(anchor - t.row) / scale)
                }
            }
        }
        .frame(width: width, alignment: .topLeading)
    }
}

/// One tag: a dot in `ink` on the frequency and the name in `valueSmall` on `ground`, as the
/// pointer's badge is but smaller.
struct WaterfallTagView: View {
    let name: String

    var body: some View {
        HStack(spacing: 3) {
            Circle().fill(Theme.ink)
                .frame(width: Theme.Layout.waterfallTagDot, height: Theme.Layout.waterfallTagDot)
            Text(name)
                .font(Theme.Font.valueSmall)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
                .frame(height: Theme.Layout.waterfallTagHeight)
                .background(Theme.ground.opacity(0.85), in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.border))
        }
    }
}
