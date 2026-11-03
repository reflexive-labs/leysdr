// SPDX-License-Identifier: Apache-2.0

// Notify Me… (docs/plans/decoders-app.md, DA-10): a sheet on a decoder's page that builds a watch,
// a kept decode job whose predicate the daemon judges on every record and whose notifier is a
// macOS notification, so a match reaches the person with the app closed. The fields come from the
// manifest's hints (`Watches.fields`), and a place and a radius are offered once the decoder's
// records on the page carry positions; the predicate is the one `ley watch` sends for the same
// choice (`Watches.predicate`). The watch starts on the frequency Start would use and never takes a
// radio somebody is using. Watches are listed under their decoder in the sidebar with Stop.

import LeylineClient
import LeylineProto
import SwiftUI

struct DecoderWatchSheet: View {
    let manifest: Leyline_V1_DecoderManifest
    @Environment(AppSession.self) private var session
    /// The sheet's choices, transient to it.
    @State private var field = "device_id"
    @State private var test = Watches.Test.equals
    @State private var value = ""
    @State private var nearOn = false
    @State private var near = ""
    @State private var radius = ""
    @State private var starting = false

    var body: some View {
        let d = session.decoders
        let fields = Watches.fields(manifest)
        let chosen = fields.first { $0.name == field } ?? fields[0]
        let built = Result {
            try Watches.predicate(
                field: chosen.name, test: test, value: value, near: nearOn ? near : "",
                radius: nearOn ? radius : "")
        }
        let placement = session.decoderPlacement(manifest)
        let hz = session.decoderFrequency(manifest)
        // A watch never sends `take_over`, so a radio somebody is using is a reason not to start.
        let placeable = placement.canStart && !placement.needsTakeOver && hz != nil
        VStack(alignment: .leading, spacing: 12) {
            Text("Notify me").font(Theme.Font.title).foregroundStyle(Theme.ink)
            Text(
                "A notification on this Mac for each \(DecoderPages.title(manifest)) record that matches, with the app closed too. It runs until you stop it in the sidebar."
            )
            .font(Theme.Font.label).foregroundStyle(Theme.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Picker("When", selection: $field) {
                    ForEach(fields) { Text($0.name).tag($0.name) }
                }
                .accessibilityIdentifier("decoders.watch.field")
                Picker("Test", selection: $test) {
                    ForEach(Watches.tests(for: chosen.type)) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("decoders.watch.test")
            }
            TextField(chosen.type == .integer ? "A number" : "A value", text: $value)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("decoders.watch.value")
            if !chosen.description.isEmpty {
                Text(chosen.description).font(Theme.Font.footnote)
                    .foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if d.records.anyPosition {
                Toggle("Near a place", isOn: $nearOn)
                    .accessibilityIdentifier("decoders.watch.near")
                if nearOn {
                    HStack(spacing: 8) {
                        TextField("37.76,-122.42", text: $near)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("decoders.watch.place")
                        TextField("10km", text: $radius)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: Theme.Layout.watchRadiusWidth)
                            .accessibilityIdentifier("decoders.watch.radius")
                    }
                }
            }
            Text(conditionWords(built))
                .font(Theme.Font.footnote)
                .foregroundStyle(built.isSuccess ? Theme.inkMuted : Theme.inkFaint)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("decoders.watch.condition")
            if !placeable {
                Text(
                    placement.needsTakeOver
                        ? "\(placement.words) A watch does not take it." : placement.words
                )
                .font(Theme.Font.footnote).foregroundStyle(Theme.caution)
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { d.watchFor = nil }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("decoders.watch.cancel")
                Button("Start Watching") {
                    guard case .success(let p) = built, let hz else { return }
                    starting = true
                    Task {
                        let ok = await d.startWatch(manifest, frequencyHz: hz, predicate: p)
                        starting = false
                        if ok { d.watchFor = nil }
                    }
                }
                // The default action: Return starts it, and it is the filled button, as the
                // assistant's Allow is, since a system default button draws grey in a window
                // that is not key.
                .keyboardShortcut(.defaultAction)
                .buttonStyle(ActionButtonStyle(filled: true))
                .disabled(!session.isLive || !placeable || !built.isSuccess || starting)
                .accessibilityIdentifier("decoders.watch.start")
            }
        }
        .padding(20)
        .frame(width: Theme.Layout.watchSheetWidth)
        .background(Theme.panel)
        .onChange(of: field) {
            let tests = Watches.tests(for: chosen.type)
            if !tests.contains(test) { test = tests[0] }
        }
    }

    /// `Notifies when fips contains 06009.`, or why the choice is not a watch yet.
    private func conditionWords(_ built: Result<Leyline_V1_Predicate, any Error>) -> String {
        switch built {
        case .success(let p): "Notifies when \(Watches.words(p))."
        case .failure(let e): (e as? Watches.Refusal)?.message ?? "\(e)"
        }
    }
}

extension Result {
    fileprivate var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

/// A watch under its decoder in the sidebar: a bell, its condition in words (`fips contains
/// 06009`) and Stop, which ends that job alone.
struct DecoderWatchLine: View {
    let job: Leyline_V1_Job
    /// The row's identifier; its Stop is `<identifier>.stop`.
    let identifier: String
    let stop: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "bell").font(Theme.Font.rowGlyph)
                .foregroundStyle(job.state == .degraded ? Theme.caution : Theme.inkTertiary)
            Text(Watches.words(job)).font(Theme.Font.footnote)
                .foregroundStyle(job.state == .degraded ? Theme.caution : Theme.inkSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: stop) {
                Text("Stop").font(Theme.Font.footnote).foregroundStyle(Theme.accent)
            }
            .buttonStyle(.plain)
            .help("Stop this watch; what it matched stays")
            .accessibilityIdentifier("\(identifier).stop")
        }
        .padding(.leading, 14 + Theme.Layout.decoderJobIndent).padding(.trailing, 14)
        .padding(.bottom, 6)
        .help("\(job.jobID): notifies when \(Watches.words(job))")
        .identifiedGroup(identifier)
        // The row's words are not read out of the group beside its button, so it carries them.
        .accessibilityLabel("Notifies when \(Watches.words(job))")
    }
}
