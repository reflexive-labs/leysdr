// SPDX-License-Identifier: Apache-2.0

// Settings, AI: the keys the daemon holds, the provider and model each feature calls, and what
// the calls used (`docs/design/ai.md`). The pane renders the mirror's `ai` and `usage` through the façade's rows (`AISettings.swift`) and
// writes through `AppSession`'s unary calls, as `ley ai` does; a key it adds appears when the
// daemon's `ai` event carries it, and a key `ley ai add` stored appears the same way. With no key
// and no on-device engine the pane shows what each feature would do and send, and the Add
// form, and nothing else.

import AppKit
import LeylineClient
import LeylineProto
import SwiftUI

struct AISettingsView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        // Everything observed is read here and handed to the timeline's closure as values
        // (`docs/dev/swift-style.md`, "SwiftUI and layout"); the closure only adds the minute, so
        // the relative words ("2 min ago") move on while nothing else changes.
        let ai = session.state.ai
        let usage = session.state.usage
        let notice = session.settingsNotice
        let daemonDown: Bool = {
            if case .unavailable = session.connection { return true }
            return false
        }()
        TimelineView(.everyMinute) { context in
            AIPaneContent(
                ai: ai, usage: usage, notice: notice, daemonDown: daemonDown, now: context.date)
        }
        .background(Theme.ground)
    }
}

private struct AIPaneContent: View {
    @Environment(AppSession.self) private var session
    let ai: Leyline_V1_AIState
    let usage: [Leyline_V1_UsageLine]
    let notice: String?
    let daemonDown: Bool
    let now: Date

    var body: some View {
        let hasAI = AISettings.hasAnyAI(ai)
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Layout.settingsGroupGap) {
                if daemonDown {
                    Text(
                        "The daemon is not running. Keys and usage live in the daemon, so this pane is empty until it starts."
                    )
                    .font(Theme.Font.label).foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
                }
                if let notice {
                    SettingsNoticeLine(text: notice) { session.clearSettingsNotice() }
                }
                if !hasAI { WhatAIDoes(rows: AISettings.featureRows(ai)) }
                KeysGroup(rows: AISettings.keyRows(ai, now: now))
                if hasAI {
                    Divider().overlay(Theme.hairline)
                    FeaturesGroup(rows: AISettings.featureRows(ai))
                    Divider().overlay(Theme.hairline)
                    UsageGroup(lines: usage, now: now)
                }
            }
            .padding(Theme.Layout.pageInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // What the system still colours in a control of the pane (a pop-up's arrows) takes a
        // neutral ink, as the transport's volume slider does, rather than the system's blue. The
        // tab above the pane is the system's own and stays as macOS draws it.
        .tint(Theme.inkTertiary)
        .accessibilityIdentifier("settings.ai")
    }
}

/// The last write's line, with a close button, as the window's notice strip draws one.
private struct SettingsNoticeLine: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark").font(Theme.Font.closeGlyph) }
                .buttonStyle(.plain).foregroundStyle(Theme.inkFaint)
                .accessibilityIdentifier("settings.ai.notice.close")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.chrome)
    }
}

/// With nothing set up: what each feature does, what each provider it can use would be sent and where, and which
/// key enables it. Shown only while no key or on-device engine is set.
private struct WhatAIDoes: View {
    let rows: [FeatureRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.settingsRowGap) {
            Text(
                "Leyline can call a model on your own provider account. Nothing here runs until you add a key, and until then no other screen shows an AI control. The daemon keeps the key and never shows or returns it."
            )
            .font(Theme.Font.body).foregroundStyle(Theme.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    Text(row.does).font(Theme.Font.aside).foregroundStyle(Theme.inkTertiary)
                    if row.choices.isEmpty {
                        Text("No provider is offered for it yet.")
                            .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                    }
                    ForEach(row.choices) { choice in
                        Text(choiceWords(choice))
                            .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    private func choiceWords(_ c: FeatureRow.Choice) -> String {
        let key = c.provider.needsKey ? " Needs a key for \(c.provider.name)." : ""
        return "\(c.provider.name): \(c.privacy)\(key)"
    }
}

// MARK: Keys

private struct KeysGroup: View {
    let rows: [KeyRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.settingsRowGap) {
            SectionHeader(text: "Keys")
            ForEach(rows) { row in
                KeyRowView(row: row)
                Divider().overlay(Theme.hairline)
            }
            AddKeyForm()
        }
    }
}

/// One stored key: who it is for, its last four characters, when it was added, used and checked,
/// what the provider said, and Check and Remove.
private struct KeyRowView: View {
    @Environment(AppSession.self) private var session
    let row: KeyRow
    @State private var confirmingRemove = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.providerName).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    if !row.label.isEmpty {
                        Text(row.label).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                    }
                    Text(row.maskedKey).font(Theme.Font.value).foregroundStyle(Theme.inkSecondary)
                }
                if !row.endpoint.isEmpty {
                    Text(row.endpoint).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkMuted)
                }
                Text("added \(row.added) · last used \(row.lastUsed)")
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(row.outcome.word).font(Theme.Font.footnote)
                        .foregroundStyle(outcomeColour)
                    Text(row.outcome == .unchecked ? "" : row.lastChecked)
                        .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                }
                if !row.message.isEmpty {
                    Text(row.message).font(Theme.Font.footnote).foregroundStyle(Theme.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("Check") { Task { await session.checkKey(provider: row.provider) } }
                .accessibilityIdentifier(
                    "settings.ai.key.\(ViewIdentifier.slug(row.provider)).check")
            Button("Remove") { confirmingRemove = true }
                .accessibilityIdentifier(
                    "settings.ai.key.\(ViewIdentifier.slug(row.provider)).remove")
        }
        .identifiedGroup("settings.ai.key.\(ViewIdentifier.slug(row.provider))")
        .confirmationDialog(
            "Remove the \(row.providerName) key?", isPresented: $confirmingRemove
        ) {
            Button("Remove", role: .destructive) {
                Task { await session.removeKey(provider: row.provider) }
            }
        } message: {
            Text("Every job and conversation using it stops.")
        }
    }

    private var outcomeColour: Color {
        switch row.outcome {
        case .accepted: Theme.good
        case .rejected: Theme.recording
        case .unavailable: Theme.caution
        case .unchecked: Theme.inkFaint
        }
    }
}

/// Add a key: the provider, a label, the key in a secure field and, for a provider that takes
/// one, the endpoint. The field clears the moment Add is pressed, and the key comes back only if
/// the daemon did not store it, so a mistyped key can be corrected. It also clears when any window
/// closes: `onDisappear` is not reliably sent to a `Settings` scene's content when its window
/// closes, and `willCloseNotification` is.
private struct AddKeyForm: View {
    @Environment(AppSession.self) private var session
    @State private var providerID = ProviderCatalog.anthropic.id
    @State private var label = ""
    @State private var secret = ""
    @State private var endpoint = ""
    @State private var adding = false

    /// The key field's content type: the app's own, which no AutoFill source answers.
    private static let apiKeyContent = NSTextContentType(rawValue: "com.leysdr.api-key")

    private var providers: [AIProvider] { ProviderCatalog.all.filter(\.needsKey) }
    private var provider: AIProvider? { ProviderCatalog.provider(providerID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add a key").font(Theme.Font.label).foregroundStyle(Theme.inkSecondary)
            field("Provider") {
                Picker("", selection: $providerID) {
                    ForEach(providers) { p in Text(p.name).tag(p.id) }
                }
                .labelsHidden()
                .frame(width: Theme.Layout.settingsPickerWidth, alignment: .leading)
                .accessibilityIdentifier("settings.ai.add.provider")
            }
            field("Label") {
                TextField("optional, such as home", text: $label).modifier(SettingsField())
                    .accessibilityIdentifier("settings.ai.add.label")
            }
            field("Key") {
                SecureField("paste the key", text: $secret).modifier(SettingsField())
                    // An API key is no password AutoFill holds. Without a content type a secure
                    // field reads as a password one; a type of the app's own, which AutoFill has
                    // nothing for, opts the field out of its suggestions. The window closing
                    // ends the edit first (below), or the list brought a closed Settings back.
                    .textContentType(Self.apiKeyContent)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("settings.ai.add.key")
            }
            if provider?.takesEndpoint == true {
                field("Endpoint") {
                    TextField("empty for the provider's own API", text: $endpoint)
                        .modifier(SettingsField())
                        .accessibilityIdentifier("settings.ai.add.endpoint")
                }
            }
            HStack {
                Spacer().frame(width: Theme.Layout.settingsLabelWidth)
                Button(adding ? "Checking…" : "Add") { add() }
                    .disabled(adding || secret.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("settings.ai.add")
                Text("Adding a key replaces any key for that provider, then checks it once.")
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            }
        }
        .onDisappear { secret = "" }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) {
            note in
            // The secure field gives up the focus first. Closed while it was editing, the
            // window came back 0.3 s later with the system's password list (`SPRoundedWindow`)
            // opening over the field, whatever its content type.
            (note.object as? NSWindow)?.makeFirstResponder(nil)
            secret = ""
        }
    }

    private func field<Control: View>(_ title: String, @ViewBuilder _ control: () -> Control)
        -> some View
    {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(Theme.Font.label).foregroundStyle(Theme.inkTertiary)
                .frame(width: Theme.Layout.settingsLabelWidth, alignment: .trailing)
            control()
        }
    }

    private func add() {
        adding = true
        let typed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        secret = ""
        let showsEndpoint = provider?.takesEndpoint == true
        Task {
            let stored = await session.addKey(
                provider: providerID, secret: typed, label: label,
                endpoint: showsEndpoint ? endpoint : "")
            if stored {
                label = ""
                endpoint = ""
            } else {
                secret = typed
            }
            adding = false
        }
    }
}

// MARK: Features

private struct FeaturesGroup: View {
    let rows: [FeatureRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.settingsRowGap) {
            SectionHeader(text: "Features")
            ForEach(rows) { row in FeatureRowView(row: row) }
        }
    }
}

/// One feature: what it does, its provider and model pickers, and what the chosen provider is
/// sent. A provider whose models are typed (OpenAI-compatible) shows a field instead of the model
/// picker, and is written only once a model is entered.
private struct FeatureRowView: View {
    @Environment(AppSession.self) private var session
    let row: FeatureRow
    /// A provider picked whose model is typed, until the model is entered.
    @State private var typedProvider: String?
    @State private var typedModel = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.title).font(Theme.Font.label).foregroundStyle(Theme.ink)
            Text(row.does).font(Theme.Font.aside).foregroundStyle(Theme.inkTertiary)
            if row.choices.isEmpty && row.provider.isEmpty {
                Text("No provider is offered for it yet.")
                    .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
            } else {
                HStack(spacing: 8) {
                    providerPicker
                    modelControl
                }
                .padding(.vertical, 2)
            }
            Text(privacy).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .fixedSize(horizontal: false, vertical: true)
            if let missing = row.missingKey {
                Text(missing).font(Theme.Font.footnote).foregroundStyle(Theme.caution)
            }
        }
        .identifiedGroup(identifier)
    }

    private var shownProvider: String { typedProvider ?? row.provider }

    /// The sentence for the provider shown in the picker, so a choice is read before it is made.
    private var privacy: String {
        row.choices.first { $0.provider.id == shownProvider }?.privacy ?? row.privacy
    }

    /// The catalog's providers for the feature, plus one `ley ai use` set that the catalog does
    /// not list, so the picker always shows what the daemon holds.
    private var providerIDs: [String] {
        var ids = row.choices.map(\.provider.id)
        if !row.provider.isEmpty, !ids.contains(row.provider) { ids.append(row.provider) }
        return ids
    }

    private var providerPicker: some View {
        Picker(
            "",
            selection: Binding(
                get: { shownProvider },
                set: { pick(provider: $0) })
        ) {
            if shownProvider.isEmpty { Text("Not chosen").tag("") }
            ForEach(providerIDs, id: \.self) { id in
                Text(ProviderCatalog.name(id)).tag(id)
            }
        }
        .labelsHidden()
        .frame(width: Theme.Layout.settingsPickerWidth, alignment: .leading)
        .accessibilityIdentifier("\(identifier).provider")
    }

    /// `settings.ai.feature.speech`: the feature's row, which its pickers' identifiers extend.
    private var identifier: String { "settings.ai.feature.\(ViewIdentifier.slug(row.feature))" }

    @ViewBuilder
    private var modelControl: some View {
        let models = ProviderCatalog.provider(shownProvider)?.models ?? []
        if typedProvider != nil || (models.isEmpty && !shownProvider.isEmpty) {
            TextField("model", text: $typedModel)
                .modifier(SettingsField())
                .frame(width: Theme.Layout.settingsPickerWidth)
                .onSubmit { writeTyped() }
                .onAppear { if typedProvider == nil { typedModel = row.model } }
                .accessibilityIdentifier("\(identifier).model")
        } else if !models.isEmpty {
            Picker(
                "",
                selection: Binding(
                    get: { row.model },
                    set: { write(provider: row.provider, model: $0) })
            ) {
                ForEach(modelChoices(models), id: \.self) { m in Text(m).tag(m) }
            }
            .labelsHidden()
            .frame(width: Theme.Layout.settingsPickerWidth, alignment: .leading)
            .accessibilityIdentifier("\(identifier).model")
        }
    }

    /// The provider's models, plus the one the daemon holds if it is not among them.
    private func modelChoices(_ models: [String]) -> [String] {
        row.model.isEmpty || models.contains(row.model) ? models : models + [row.model]
    }

    private func pick(provider id: String) {
        guard !id.isEmpty else { return }
        // Back to the provider the daemon holds: drop the half-made choice, keep its model.
        if id == row.provider {
            typedProvider = nil
            return
        }
        guard id != shownProvider else { return }
        let models = ProviderCatalog.provider(id)?.models ?? []
        if let first = models.first {
            typedProvider = nil
            write(provider: id, model: first)
        } else {
            typedProvider = id
            typedModel = ""
        }
    }

    private func writeTyped() {
        let model = typedModel.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, !shownProvider.isEmpty else { return }
        write(provider: shownProvider, model: model)
        typedProvider = nil
    }

    private func write(provider: String, model: String) {
        Task {
            await session.setFeatureModel(feature: row.feature, provider: provider, model: model)
        }
    }
}

// MARK: Usage

/// Requests, tokens and audio minutes per provider, model and feature, by UTC day over the
/// last 30 days or by month over the whole ledger, with the total and the note that the numbers
/// are the workers' and the cost is the provider's. A column empty in every row is left out, as
/// `ley ai usage` leaves it out.
private struct UsageGroup: View {
    let lines: [Leyline_V1_UsageLine]
    let now: Date
    @State private var period = UsageFold.Period.day

    var body: some View {
        let fold = UsageFold(
            lines: lines, by: period,
            sinceDay: period == .day ? UsageFold.sinceDay(now: now) : nil)
        VStack(alignment: .leading, spacing: Theme.Layout.settingsRowGap) {
            HStack {
                SectionHeader(text: "Usage")
                Spacer()
                PeriodSwitch(period: $period)
            }
            if fold.rows.isEmpty {
                Text("No usage reported yet; calls made with these keys are counted here.")
                    .font(Theme.Font.aside).foregroundStyle(Theme.inkTertiary)
            } else {
                UsageTable(fold: fold, period: period)
            }
            Text(UsageFold.note).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `By day | By month`, drawn as the toolbar's `Radio | Library` switch (`PlaceSwitch`): the
/// period showing raised on `border` in `ink`, the other in `inkTertiary`, inside a `border`
/// stroke on `chrome`. Two plain buttons rather than a segmented `Picker`, whose selected segment
/// the system draws in its own accent colour, which `Theme` cannot set.
private struct PeriodSwitch: View {
    @Binding var period: UsageFold.Period

    var body: some View {
        let outer = Theme.Layout.placeSwitchRadius
        let inset = Theme.Layout.placeSwitchInset
        HStack(spacing: 0) {
            ForEach(UsageFold.Period.allCases, id: \.self) { p in
                let shown = period == p
                Button {
                    period = p
                } label: {
                    Text(p == .day ? "By day" : "By month").font(Theme.Font.label)
                        .foregroundStyle(shown ? Theme.ink : Theme.inkTertiary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background(
                            shown ? Theme.border : Color.clear,
                            in: RoundedRectangle(cornerRadius: outer - inset)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(shown ? .isSelected : [])
                .accessibilityIdentifier("settings.ai.usage.period.\(p.rawValue)")
            }
        }
        .padding(inset)
        .background(Theme.chrome, in: RoundedRectangle(cornerRadius: outer))
        .overlay(
            RoundedRectangle(cornerRadius: outer).strokeBorder(Theme.border, lineWidth: 1)
        )
        .fixedSize()
        .identifiedGroup("settings.ai.usage.period")
    }
}

/// A text field of the pane in the palette's roles: `raised` ground, a `border` edge that is
/// `borderFocus` while it has the focus, `ink` text, and no system focus ring, which would draw
/// in the system's accent colour.
private struct SettingsField: ViewModifier {
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(Theme.Font.label).foregroundStyle(Theme.ink)
            // The line's height, set: left to the field, an empty one and one with text
            // differ by a point, and the rows under the Key field moved between runs.
            .frame(height: Theme.Layout.labelFieldHeight)
            .focused($focused)
            .focusEffectDisabled()
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(focused ? Theme.borderFocus : Theme.border, lineWidth: 1))
    }
}

private struct UsageTable: View {
    let fold: UsageFold
    let period: UsageFold.Period

    var body: some View {
        let numbers: [UsageFold.Column] = fold.columns
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                head(period == .day ? "DAY" : "MONTH")
                head("MODEL")
                head("FEATURE")
                ForEach(numbers, id: \.self) { column in
                    head(column.head).gridColumnAlignment(.trailing)
                }
            }
            ForEach(fold.rows) { r in
                GridRow {
                    Text(r.period).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.model).font(Theme.Font.value).foregroundStyle(Theme.inkSecondary)
                        Text(ProviderCatalog.name(r.provider)).font(Theme.Font.valueSmall)
                            .foregroundStyle(Theme.inkMuted)
                    }
                    Text(r.feature).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
                    ForEach(numbers, id: \.self) { column in
                        Text(column.value(r)).font(Theme.Font.value)
                            .foregroundStyle(Theme.inkSecondary)
                    }
                }
            }
            Divider().overlay(Theme.hairline).gridCellUnsizedAxes(.horizontal)
            GridRow {
                Text("total").font(Theme.Font.value).foregroundStyle(Theme.ink)
                Text("")
                Text("")
                ForEach(numbers, id: \.self) { column in
                    Text(column.value(fold.total)).font(Theme.Font.value)
                        .foregroundStyle(Theme.ink)
                }
            }
        }
    }

    private func head(_ text: String) -> some View {
        Text(text).font(Theme.Font.columnHead).foregroundStyle(Theme.inkFaint)
    }
}
