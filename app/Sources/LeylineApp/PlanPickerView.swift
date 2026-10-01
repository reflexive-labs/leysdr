// SPDX-License-Identifier: Apache-2.0

// The plan picker: a popover from a band row's `Channels…` line listing the plan in its own
// order, about twelve rows tall and scrolling past that (docs/design/channels.md, "The plan
// picker"). It exists so a channel is reached by name without the mouse: the filter field
// at its top narrows the rows for the long plans (marine, CB), Up and Down move a highlight
// that starts on the tuned channel when the plan has it, Return picks it and Escape closes. A
// pick tunes through the part that holds the channel and closes. The rows, the query and the
// highlight are the session's (`pickerRows`, `pickerQuery`, `pickerHighlight`), so the key
// monitor the field shares with the sidebar's filter (`TuningKeyGuard`) moves the highlight
// without a callback into this view.

import LeylineClient
import SwiftUI

struct PlanPickerView: View {
    @Environment(AppSession.self) private var session
    let band: Band
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var session = session
        let rows = session.pickerRows
        let highlight = session.pickerHighlight
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
                TextField("Filter \(band.name) channels", text: $session.pickerQuery)
                    .textFieldStyle(.plain).font(Theme.Font.label).foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { session.pickHighlighted() }
                    .onExitCommand { session.pickerBand = nil }
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Theme.ground, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .modifier(TuningKeyGuard(focused: focused, pickerKeys: true))
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if rows.isEmpty {
                            Text("No channel matches “\(session.pickerQuery)”.")
                                .font(Theme.Font.footnote).foregroundStyle(Theme.inkFaintest)
                                .padding(.horizontal, 8).padding(.vertical, 6)
                        }
                        ForEach(rows.indices, id: \.self) { i in
                            let channel = rows[i]
                            PlanChannelRow(channel: channel, highlighted: i == highlight)
                                .id(channel.id)
                                .contentShape(Rectangle())
                                .onTapGesture { session.pick(channel: channel, in: band) }
                        }
                    }
                }
                .frame(height: Theme.Layout.pickerRowHeight * CGFloat(Theme.Layout.pickerRows))
                // The highlight stays in view as the arrows move it, and the opening scroll
                // puts the tuned channel in view.
                .onChange(of: highlight, initial: true) { _, i in
                    if rows.indices.contains(i) { proxy.scrollTo(rows[i].id) }
                }
            }
        }
        .padding(14)
        .frame(width: Theme.Layout.pickerWidth)
        .background(Theme.chrome)
        .onAppear { focused = true }
    }
}

/// One channel of the plan: its name in `label`, its frequency in `valueSmall` `inkTertiary`,
/// and its note after them in `inkFaint`, truncated; `selected` ground on the highlighted row.
struct PlanChannelRow: View {
    let channel: PlanChannel
    let highlighted: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(channel.name).font(Theme.Font.label)
                .foregroundStyle(highlighted ? Theme.ink : Theme.inkSecondary)
                .lineLimit(1).fixedSize()
            Text(Frequency.fieldParts(channel.hz).major).font(Theme.Font.valueSmall)
                .foregroundStyle(Theme.inkTertiary).fixedSize()
            if !channel.note.isEmpty {
                Text(channel.note).font(Theme.Font.footnote).foregroundStyle(Theme.inkFaint)
                    .lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: Theme.Layout.pickerRowHeight)
        .background(
            highlighted ? Theme.selected : Color.clear,
            in: RoundedRectangle(cornerRadius: 4)
        )
        .help(help)
    }

    /// `157.100 MHz · Ship-to-coast`: the frequency in full, and the note a narrow row cut.
    private var help: String {
        let hz = Frequency.format(channel.hz)
        return channel.note.isEmpty ? hz : "\(hz) · \(channel.note)"
    }
}
