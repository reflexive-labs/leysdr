// SPDX-License-Identifier: Apache-2.0

// The Decoders inspector: a transmitter, or one record of it. The transmitter's name as the page
// shows it, its id and a field that names it in `labels.json` (`LabelStore`, the file `ley track`
// and `ley records` read too), how often and when it was heard and where it was last; then the
// record: its time, the signal the daemon measured, its line, every field with the manifest's
// unit and description, and the raw payload as hex. With nothing selected, the decoder itself:
// what it is, where it listens and what it sends. Nothing here decodes (AGENTS.md, invariant 2):
// every value is the record's, printed by the template rules.

import LeylineClient
import LeylineProto
import SwiftUI

struct DecoderInspector: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let m = d.selected {
                    let entity = d.inspectedEntity
                    let record = d.inspectedRecord
                    if entity != nil || record != nil {
                        if let deviceID = entity?.deviceID ?? record?.record.deviceID,
                            !deviceID.isEmpty
                        {
                            TransmitterSection(deviceID: deviceID, entity: entity, manifest: m)
                            Rectangle().fill(Theme.hairline).frame(height: 1)
                        }
                        if let record {
                            RecordSection(entry: record, manifest: m)
                        }
                    } else {
                        DecoderAbout(manifest: m)
                    }
                }
            }
        }
        // A scroll view whose top meets the toolbar's comes out white over the whole column in
        // the window's picture (macOS 26's scroll edge under the toolbar); one point of the
        // panel above it keeps the two apart.
        .padding(.top, 1)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
    }
}

/// `TRANSMITTER`, its name in `name`, its id and protocol, the name field, and its counts.
struct TransmitterSection: View {
    let deviceID: String
    let entity: DecoderEntity?
    let manifest: Leyline_V1_DecoderManifest
    @Environment(AppSession.self) private var session
    /// The name being typed, until Return writes it.
    @State private var draft = ""

    var body: some View {
        let d = session.decoders
        VStack(alignment: .leading, spacing: 8) {
            ColumnHeadText(text: "Transmitter")
            Text(d.name(of: deviceID)).font(Theme.Font.name).tracking(Theme.nameTracking)
                .foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.tail)
            Text("\(deviceID) · \(manifest.name)").font(Theme.Font.value)
                .foregroundStyle(Theme.inkMuted).lineLimit(1)
            HStack(spacing: 0) {
                Text("Name").font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
                    .frame(width: Theme.Layout.partTableLabelWidth, alignment: .leading)
                // The placeholder in `inkFaint`, as the sidebar filter's is: the field's own
                // takes the ink and reads as a name already given.
                TextField("", text: $draft)
                    .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .frame(height: Theme.Layout.labelFieldHeight)
                    .accessibilityLabel("Name it")
                    .fieldPlaceholder("Name it", font: Theme.Font.label, shown: draft.isEmpty)
                    .onSubmit { d.setLabel(deviceID, name: draft) }
                    .accessibilityIdentifier("decoders.inspector.name")
                    .help(
                        "Your name for \(deviceID), kept in labels.json beside your bookmarks; ley track shows it too. Return saves it, and an empty name removes it."
                    )
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            if let e = entity {
                PartTable(rows: rows(e), ink: { _ in Theme.inkSecondary })
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .onAppear { draft = d.labels.name(of: deviceID) ?? "" }
        .onChange(of: deviceID) { draft = d.labels.name(of: deviceID) ?? "" }
        .onChange(of: d.labels.name(of: deviceID)) { _, new in draft = new ?? "" }
    }

    private func rows(_ e: DecoderEntity) -> [PartTableRow] {
        var out = [
            PartTableRow(label: "Heard", value: e.count == 1 ? "once" : "\(e.count) times"),
            PartTableRow(label: "First", value: DecoderPages.clock(e.firstHeard)),
            PartTableRow(label: "Last", value: DecoderPages.clock(e.lastHeard)),
        ]
        if let p = e.position, p.latitude.isFinite, p.longitude.isFinite {
            out.append(PartTableRow(label: "Position", value: DisplayTemplate.formatPosition(p)))
            if p.hasAltitudeM, let alt = DisplayTemplate.formatNumber(p.altitudeM, decimals: 0) {
                out.append(PartTableRow(label: "Altitude", value: "\(alt) m"))
            }
        }
        if let h = e.heading, let deg = DisplayTemplate.formatNumber(h, decimals: 0) {
            out.append(PartTableRow(label: "Heading", value: "\(deg)°"))
        }
        return out
    }
}

/// `RECORD · POSITION`, the record's time, signal and line, its fields and its raw bytes.
struct RecordSection: View {
    let entry: RecordEntry
    let manifest: Leyline_V1_DecoderManifest
    @Environment(AppSession.self) private var session

    var body: some View {
        let d = session.decoders
        let r = entry.record
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                ColumnHeadText(text: r.kind.isEmpty ? "Record" : "Record · \(r.kind)")
                Text(d.summary(r)).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                PartTable(rows: header(r), ink: { _ in Theme.inkSecondary })
                    .padding(.top, 4)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            let fields = DecoderPages.fieldRows(r.fields, manifest: manifest)
            if !fields.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    ColumnHeadText(text: "Fields")
                    ForEach(fields) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(f.name).font(Theme.Font.label)
                                    .foregroundStyle(Theme.inkMuted).lineLimit(1)
                                    .frame(
                                        width: Theme.Layout.decoderFieldLabelWidth,
                                        alignment: .leading)
                                Text(f.value).font(Theme.Font.value)
                                    .foregroundStyle(Theme.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            if !f.description.isEmpty {
                                Text(f.description).font(Theme.Font.footnote)
                                    .foregroundStyle(Theme.inkFaint)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.leading, Theme.Layout.decoderFieldLabelWidth)
                            }
                        }
                        .identifiedGroup("decoders.inspector.field.\(ViewIdentifier.slug(f.name))")
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
            let hex = DecoderPages.hexLines(r.raw)
            if !hex.isEmpty {
                Rectangle().fill(Theme.hairline).frame(height: 1)
                VStack(alignment: .leading, spacing: 8) {
                    ColumnHeadText(text: "Raw · \(r.raw.count) bytes")
                    Text(hex.joined(separator: "\n")).font(Theme.Font.valueSmall)
                        .foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("decoders.inspector.raw")
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
            }
        }
    }

    private func header(_ r: Leyline_V1_DecodeRecord) -> [PartTableRow] {
        var out = [
            PartTableRow(
                label: "Time",
                value: DecoderPages.clock(entry.at) + (entry.dated ? "" : " (arrived)"))
        ]
        if let s = DecoderPages.signalWords(r) {
            out.append(PartTableRow(label: "Signal", value: s))
        }
        if r.hasPosition, r.position.latitude.isFinite, r.position.longitude.isFinite {
            out.append(
                PartTableRow(label: "Position", value: DisplayTemplate.formatPosition(r.position)))
        }
        if !r.jobID.isEmpty { out.append(PartTableRow(label: "Job", value: r.jobID)) }
        return out
    }
}

/// With nothing selected: the decoder's description, where it listens, what it reads and what
/// it sends, and whose it is.
struct DecoderAbout: View {
    let manifest: Leyline_V1_DecoderManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ColumnHeadText(text: "Decoder")
            Text(DecoderPages.title(manifest)).font(Theme.Font.name)
                .tracking(Theme.nameTracking).foregroundStyle(Theme.ink).lineLimit(1)
            if !manifest.description_p.isEmpty {
                Text(manifest.description_p).font(Theme.Font.label)
                    .foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            PartTable(rows: rows, ink: { _ in Theme.inkSecondary }).padding(.top, 4)
            Text("Pick a record or a transmitter to see what it sent.")
                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var rows: [PartTableRow] {
        var out = [PartTableRow(label: "Name", value: "\(manifest.name) \(manifest.version)")]
        let hz = manifest.recipe.frequenciesHz
        if !hz.isEmpty {
            out.append(
                PartTableRow(
                    label: "Listens", value: hz.map(Frequency.format).joined(separator: ", ")))
        }
        out.append(
            PartTableRow(
                label: "Reads", value: manifest.input.signal == .signalIq ? "IQ" : "audio"))
        if !manifest.license.isEmpty {
            out.append(PartTableRow(label: "Licence", value: manifest.license))
        }
        return out
    }
}
