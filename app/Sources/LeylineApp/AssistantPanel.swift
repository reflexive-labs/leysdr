// SPDX-License-Identifier: Apache-2.0

// The assistant's panel: a column on the window's right, beside the inspector, holding one
// conversation with the assistant (`docs/design/ai.md`, "The assistant"). It renders the session's
// copy of the conversation through the façade's rows (`ConversationView`) and moves it only through
// the session's calls, which are the `Assistant` RPCs `ley ask` makes too: each step opens to the
// call's arguments and result, a question is a card with Allow and Decline, Stop ends
// a running turn, and the usage line counts the tokens so far in the provider's units. The column
// sits outside both places' bodies, so `show_place` and ⌘1/⌘2 switch the body beside it without
// remaking the transcript or the field. It is drawn only while an AI feature can run
// (`AppSession.assistantPanelShown`, `docs/design/ai.md`, "Context").

import LeylineClient
import LeylineProto
import SwiftUI

/// The toolbar's assistant toggle, beside the inspector's, drawn as that one is; absent while no
/// AI feature can run.
struct AssistantToggle: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.hasAnyAI {
            Button {
                session.toggleAssistant()
            } label: {
                Image(systemName: "bubble.left.and.text.bubble.right")
                    .font(Theme.Font.toolbarGlyph)
                    .foregroundStyle(session.assistantShown ? Theme.inkSecondary : Theme.inkMuted)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Theme.border, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(session.assistantShown ? "Hide Assistant (⇧⌘A)" : "Show Assistant (⇧⌘A)")
            // The symbol's own name would be read otherwise.
            .accessibilityLabel("Assistant")
            .accessibilityIdentifier("toolbar.assistant")
        }
    }
}

/// The column: a hairline, then the panel at its fixed width, while it is shown.
struct AssistantColumn: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        if session.assistantPanelShown {
            Rectangle().fill(Theme.border).frame(width: 1)
            AssistantPanel()
                .frame(width: Theme.Layout.assistantPanel)
        }
    }
}

/// The header, the transcript, the question, the notice and the field, top to bottom.
struct AssistantPanel: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        let view = session.conversationView
        VStack(alignment: .leading, spacing: 0) {
            AssistantHeader(view: view)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let view, !view.turns.isEmpty {
                AssistantTranscript(view: view)
            } else {
                AssistantEmpty()
            }
            if let q = view?.pending, !q.isViewTool {
                PendingCard(question: q)
            }
            if let error = view?.errorText {
                AssistantNoticeLine(text: error, colour: Theme.recording, settings: false)
            }
            if let n = session.assistantNotice {
                AssistantNoticeLine(
                    text: n.text, colour: Theme.caution, settings: n.pointsToSettings)
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            AssistantField(view: view)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.panel)
        .identifiedGroup("assistant.panel")
    }
}

/// `Assistant`, the conversation's state word, and New Conversation.
struct AssistantHeader: View {
    @Environment(AppSession.self) private var session
    let view: ConversationView?

    var body: some View {
        HStack(spacing: 8) {
            Text("Assistant").font(Theme.Font.menuTitle).foregroundStyle(Theme.inkSecondary)
            if let view {
                Text(session.assistantLost ? "gone" : view.stateWord)
                    .font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
            }
            Spacer()
            if view != nil {
                Button {
                    Task { await session.newConversation() }
                } label: {
                    Image(systemName: "square.and.pencil").font(Theme.Font.panelGlyph)
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
                .help("New Conversation: ends this one and starts empty")
                .accessibilityLabel("New Conversation")
                .accessibilityIdentifier("assistant.new")
            }
        }
        .padding(.horizontal, Theme.Layout.assistantInset)
        .frame(height: Theme.Layout.inspectorHeaderHeight)
        .background(Theme.panelHeader)
    }
}

/// What the assistant can do, and where to set it up when it cannot start yet.
struct AssistantEmpty: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AssistantWords.whatItDoes).font(Theme.Font.label)
                .foregroundStyle(Theme.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if !session.hasAssistantModel {
                Text(AssistantWords.noModel).font(Theme.Font.aside)
                    .foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
                SettingsLink { Text("Open Settings") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("assistant.settings")
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Layout.assistantInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The turns, oldest first, kept scrolled to the newest. Your message and the assistant's turn
/// that answers it are one exchange, `assistantInTurnGap` apart; exchanges are
/// `assistantTurnGap` apart.
struct AssistantTranscript: View {
    let view: ConversationView

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(view.turns.enumerated()), id: \.element.id) { i, turn in
                    TurnView(turn: turn)
                        .padding(.top, gap(before: i))
                }
                if view.isWaitingOnModel {
                    WaitingRow(since: view.waitingSince(now: Date()))
                        .padding(.top, Theme.Layout.assistantInTurnGap)
                }
            }
            .padding(Theme.Layout.assistantInset)
        }
        .defaultScrollAnchor(.bottom)
    }

    /// Nothing over the first turn; the small gap over the assistant's turn, which answers what
    /// is over it; the large one over your message, which starts an exchange.
    private func gap(before i: Int) -> CGFloat {
        guard i > 0 else { return 0 }
        return view.turns[i].role == .assistant
            ? Theme.Layout.assistantInTurnGap : Theme.Layout.assistantTurnGap
    }
}

/// The sign that the assistant is thinking: a spinner and `thinking…`, with the seconds once a
/// wait has gone on for three. It sits under the newest turn only while
/// `ConversationView.isWaitingOnModel`, is drawn only once the wait has gone on for 300 ms, so an
/// answer that comes straight back does not flicker it, and nothing of it stays when the turn
/// moves on. The 300 ms and the count from three seconds are the style guide's
/// (`docs/dev/cli-style.md`, "A wait says so, and leaves nothing behind").
struct WaitingRow: View {
    let since: Date

    /// The wait before the row shows (`docs/dev/cli-style.md`, "A wait says so, and leaves nothing
    /// behind").
    private static let delay: TimeInterval = 0.3

    var body: some View {
        TimelineView(.periodic(from: since + Self.delay, by: 1)) { context in
            if context.date >= since + Self.delay {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(words(at: context.date)).font(Theme.Font.valueSmall)
                        .foregroundStyle(Theme.inkFaint)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("The assistant is thinking")
    }

    private func words(at now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(since).rounded(.down))
        return seconds >= 3 ? "thinking\u{2026} \(seconds)s" : "thinking\u{2026}"
    }
}

/// Your message on a `raised` bubble at the right, at most about 80 % of the column wide; an
/// assistant turn's steps, then its reply across the column with no bubble. Both are
/// `inkSecondary` in `Font.reply` with `Theme.replyLeading` between lines; `ink`, the
/// brightest, is kept for the field's typing. A stopped turn (`stop_reason` STOPPED, an empty
/// one included) ends with a faint `Stopped.` after its steps.
struct TurnView: View {
    let turn: TurnRow

    var body: some View {
        switch turn.role {
        case .user:
            VStack(alignment: .trailing, spacing: Theme.Layout.assistantInTurnGap) {
                Text(turn.text).font(Theme.Font.reply).lineSpacing(Theme.replyLeading)
                    .foregroundStyle(Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Theme.Layout.assistantBubblePaddingH)
                    .padding(.vertical, Theme.Layout.assistantBubblePaddingV)
                    .background(
                        Theme.raised,
                        in: RoundedRectangle(cornerRadius: Theme.Layout.assistantRadius)
                    )
                    .frame(maxWidth: Theme.Layout.assistantBubbleMaxWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: Theme.Layout.assistantInTurnGap) {
                ForEach(turn.steps) { step in
                    StepView(step: step)
                }
                if !turn.text.isEmpty {
                    Text(turn.text).font(Theme.Font.reply).lineSpacing(Theme.replyLeading)
                        .foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if turn.stopped { StoppedLine() }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// `Stopped.`: the turn ended on Stop, here or from a terminal's Ctrl-C.
struct StoppedLine: View {
    var body: some View {
        Text("Stopped.").font(Theme.Font.aside).foregroundStyle(Theme.inkFaint)
    }
}

/// One tool call: the chevron, the tool and its arguments, and its state word at the right;
/// opened, the call read through `StepDetail` on the column's left edge.
struct StepView: View {
    let step: StepRow
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Layout.assistantInTurnGap) {
            Button {
                open.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right").font(Theme.Font.glyph)
                        .foregroundStyle(Theme.inkFaintest)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    let arguments = Text(step.summary.isEmpty ? "" : " \(step.summary)")
                        .foregroundStyle(Theme.inkFaint)
                    Text("\(Text(step.tool).foregroundStyle(Theme.inkTertiary))\(arguments)")
                        .font(Theme.Font.value)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(step.stateWord).font(Theme.Font.valueSmall)
                        .foregroundStyle(stateColour)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(step.line), \(step.stateWord)")
            .accessibilityIdentifier("assistant.step.\(ViewIdentifier.slug(step.callID))")
            if open {
                StepBody(step: step)
            }
        }
    }

    private var stateColour: Color {
        switch step.state {
        case .toolCallAwaitingApproval, .toolCallRefused: Theme.caution
        case .toolCallDone where step.isError: Theme.recording
        default: Theme.inkFaint
        }
    }
}

/// An opened step: the gate's reason when it asked, the arguments as `key value` lines and the
/// result as a table or compact text, or with `JSON` on, the JSON behind them. The box is at
/// most `assistantStepBodyMaxHeight` tall and scrolls inside past that.
struct StepBody: View {
    let step: StepRow
    @State private var showJSON = false
    /// The content's own height, measured, so a short body's box hugs it.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        let detail = step.detail
        VStack(alignment: .trailing, spacing: 4) {
            ScrollView {
                Group {
                    if showJSON { json(detail) } else { readable(detail) }
                }
                .padding(Theme.Layout.assistantBoxPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.height
                } action: {
                    contentHeight = $0
                }
            }
            .frame(height: min(contentHeight, Theme.Layout.assistantStepBodyMaxHeight))
            .background(
                Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Layout.assistantBoxRadius))
            if detail.hasJSON {
                Button(showJSON ? "Readable" : "JSON") { showJSON.toggle() }
                    .buttonStyle(.plain)
                    .font(Theme.Font.valueSmall)
                    .foregroundStyle(Theme.inkFaint)
                    .help(showJSON ? "Show the call as lines" : "Show the call's JSON")
                    .accessibilityIdentifier(
                        "assistant.step.\(ViewIdentifier.slug(step.callID)).json")
            }
        }
    }

    private func readable(_ d: StepDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.assistantInTurnGap) {
            if !step.reason.isEmpty {
                Text(step.reason).font(Theme.Font.aside).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.arguments.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 2)
                {
                    ForEach(Array(d.arguments.enumerated()), id: \.offset) { _, a in
                        GridRow {
                            Text(a.key).foregroundStyle(Theme.inkFaint)
                            Text(a.value).foregroundStyle(Theme.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .font(Theme.Font.valueSmall)
                .textSelection(.enabled)
            }
            switch d.result {
            case .none:
                EmptyView()
            case .text(let text):
                Text(text).font(Theme.Font.valueSmall)
                    .foregroundStyle(step.isError ? Theme.recording : Theme.inkSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .table(let t):
                StepTable(table: t)
            }
        }
    }

    private func json(_ d: StepDetail) -> some View {
        VStack(alignment: .leading, spacing: Theme.Layout.assistantInTurnGap) {
            if !d.argumentsJSON.isEmpty {
                SectionHeader(text: "Arguments")
                jsonText(d.argumentsJSON)
            }
            if !d.resultJSON.isEmpty {
                SectionHeader(text: "Result")
                jsonText(d.resultJSON)
            }
        }
    }

    private func jsonText(_ s: String) -> some View {
        Text(s).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkSecondary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A result that is rows: the column heads, the rows shown, and `… N more`.
struct StepTable: View {
    let table: StepDetail.Table

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 2) {
                GridRow {
                    ForEach(table.columns, id: \.self) { c in
                        Text(c.uppercased()).font(Theme.Font.columnHead)
                            .foregroundStyle(Theme.inkFaint)
                    }
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell).font(Theme.Font.valueSmall)
                                .foregroundStyle(Theme.inkSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
            }
            if let more = table.moreWords {
                Text(more).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
            }
        }
        .textSelection(.enabled)
    }
}

/// What the assistant asks to do in words, what the gate's reason adds to that (`note`, absent
/// when it adds nothing), and a button per answer the question offers: Decline and Allow in this
/// chat (when it can be granted for the rest of the conversation, never for a delete or a cancel
/// of another client's job) as plain text, and Allow, the one filled button. No button takes Return: a delete or a takeover
/// is answered with a click, never a stray key.
struct PendingCard: View {
    @Environment(AppSession.self) private var session
    let question: PendingQuestion
    /// The call an answer is on its way for. Every button is disabled until the daemon has
    /// replied, so a quick second click never sends a second ResolveAction, which the daemon would
    /// refuse. Kept by call id, so a new question is answerable at once.
    @State private var answering: String?

    /// Sends one answer, with the buttons disabled while it goes. A click while one is on its
    /// way is dropped: two clicks in one run-loop turn both reach here before SwiftUI applies
    /// `.disabled`.
    private func answer(_ send: @escaping @MainActor @Sendable () async -> Void) {
        guard answering != question.callID else { return }
        let id = question.callID
        answering = id
        Task {
            await send()
            if answering == id { answering = nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question.question).font(Theme.Font.label).foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("assistant.card.question")
            if !question.note.isEmpty {
                Text(question.note).font(Theme.Font.aside).foregroundStyle(Theme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("assistant.card.note")
            }
            // On one line when the three fit the card, as they do in the column's 320 pt, else
            // Allow in this chat over Decline and Allow, so none is cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    decline
                    if question.offersConversation { allowForConversation }
                    allow
                }
                VStack(alignment: .trailing, spacing: 6) {
                    if question.offersConversation { allowForConversation }
                    HStack(spacing: 12) {
                        decline
                        allow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .font(Theme.Font.label)
            .disabled(answering == question.callID)
        }
        .padding(Theme.Layout.assistantCardPadding)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Layout.assistantRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Layout.assistantRadius)
                .strokeBorder(Theme.borderStrong)
        )
        .padding(.horizontal, Theme.Layout.assistantInset)
        .padding(.bottom, Theme.Layout.assistantTurnGap)
    }

    private var decline: some View {
        let session = session
        let id = question.callID
        return Button("Decline") { answer { await session.decline(callID: id) } }
            .buttonStyle(AssistantButtonStyle(filled: false))
            .accessibilityIdentifier("assistant.decline")
    }

    private var allowForConversation: some View {
        let session = session
        let id = question.callID
        return Button("Allow in this chat") {
            answer { await session.approve(callID: id, forConversation: true) }
        }
        .buttonStyle(AssistantButtonStyle(filled: false))
        .accessibilityIdentifier("assistant.allow.conversation")
    }

    private var allow: some View {
        let session = session
        let id = question.callID
        return Button("Allow") { answer { await session.approve(callID: id) } }
            .buttonStyle(AssistantButtonStyle(filled: true))
            .accessibilityIdentifier("assistant.allow")
    }
}

/// A card's button: Allow filled in `inkSecondary` with the panel's ground for its words, the
/// others plain text in `inkTertiary`; disabled, both in `inkDisabled`.
struct AssistantButtonStyle: ButtonStyle {
    let filled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .foregroundStyle(
                filled
                    ? (isEnabled ? Theme.panel : Theme.inkDisabled)
                    : (isEnabled
                        ? (pressed ? Theme.inkSecondary : Theme.inkTertiary)
                        : Theme.inkDisabled)
            )
            .padding(.horizontal, filled ? Theme.Layout.assistantButtonPaddingH : 0)
            .padding(.vertical, Theme.Layout.assistantButtonPaddingV)
            .background {
                if filled {
                    RoundedRectangle(cornerRadius: Theme.Layout.assistantButtonRadius)
                        .fill(
                            isEnabled
                                ? (pressed ? Theme.inkTertiary : Theme.inkSecondary) : Theme.border)
                }
            }
            .contentShape(Rectangle())
    }
}

/// One line about a failure, with Open Settings when Settings fixes it.
struct AssistantNoticeLine: View {
    let text: String
    let colour: Color
    let settings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text).font(Theme.Font.aside).foregroundStyle(colour)
                .fixedSize(horizontal: false, vertical: true)
            if settings {
                SettingsLink { Text("Open Settings") }
                    .buttonStyle(.bordered).controlSize(.small)
                    .accessibilityIdentifier("assistant.settings")
            }
        }
        .padding(.horizontal, Theme.Layout.assistantInset).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The usage line, then the field: it is never disabled, so the next message is written while the
/// assistant is on a turn or a question, and Return sends only once the daemon would take it;
/// until then the text stays. Stop shows beside the field while the assistant thinks or runs one
/// of the app's view tools. The text also comes back when the daemon did not take it.
/// `TuningKeyGuard` hands Space and the arrows to the field, or typing would mute and tune the
/// radio through the Tune menu's keys. The text is the session's `assistantDraft`, so what was
/// typed while a card waited is still the draft once the card goes, and Return sends it.
struct AssistantField: View {
    @Environment(AppSession.self) private var session
    let view: ConversationView?
    @FocusState private var focused: Bool
    /// A message has left `send()` and its reply is not back. `assistantSending` says the same
    /// only once the controller's change is copied to the session, and a second Return in that
    /// gap would send the message twice.
    @State private var submitting = false

    /// Return sends only while the daemon would take the message: not while one is on its way,
    /// and not while the assistant thinks or asks. With no conversation, or one that is over or
    /// lost, the message starts a new one (`AssistantController.needsStart`).
    /// The conversation is read from the session, not `view`: the field's Return action is the
    /// closure SwiftUI installed when it last drew the field, and a card that went without the
    /// field drawing again left it judging by the conversation as it waited.
    private var canSend: Bool {
        guard !submitting, !session.assistantSending else { return false }
        guard let view = session.conversationView, !session.assistantLost else { return true }
        return view.canSend || view.isOver
    }

    var body: some View {
        @Bindable var session = session
        VStack(alignment: .leading, spacing: 6) {
            if let words = session.assistantUsage.words {
                Text(words).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
            }
            HStack(spacing: 8) {
                // The placeholder is drawn in `inkFaint`, as the sidebar filter's is: the
                // field's own takes the system's colour, dimmed only by vibrancy.
                TextField("", text: $session.assistantDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body).foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .modifier(TuningKeyGuard(focused: focused))
                    .accessibilityLabel("Ask the assistant")
                    .accessibilityIdentifier("assistant.input")
                    .fieldPlaceholder(
                        "Ask the assistant", font: Theme.Font.body,
                        shown: session.assistantDraft.isEmpty)
                if view?.canStop == true {
                    Button("Stop") { Task { await session.stopTurn() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Ends this turn; the conversation goes on")
                        .accessibilityIdentifier("assistant.stop")
                }
            }
            .padding(Theme.Layout.assistantBoxPadding)
            .background(
                Theme.raised, in: RoundedRectangle(cornerRadius: Theme.Layout.assistantRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Layout.assistantRadius)
                    .strokeBorder(focused ? Theme.borderFocus : Theme.border))
            if !canSend,
                !session.assistantDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                Text(AssistantWords.returnWaits(view)).font(Theme.Font.valueSmall)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(.horizontal, Theme.Layout.assistantInset)
        .padding(.vertical, Theme.Layout.assistantFooterPadding)
    }

    private func send() {
        let text = session.assistantDraft
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        session.assistantDraft = ""
        submitting = true
        let session = session
        Task {
            // What was typed while the message was on its way stays, under the text that failed.
            if !(await session.send(text)) {
                let typed = session.assistantDraft
                session.assistantDraft = typed.isEmpty ? text : text + "\n" + typed
            }
            submitting = false
        }
    }
}
