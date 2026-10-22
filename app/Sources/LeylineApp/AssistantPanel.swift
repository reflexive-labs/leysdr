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
                .accessibilityIdentifier("assistant.new")
            }
        }
        .padding(.horizontal, 16)
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The turns, oldest first, kept scrolled to the newest.
struct AssistantTranscript: View {
    let view: ConversationView

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Layout.assistantTurnGap) {
                ForEach(view.turns) { turn in
                    TurnView(turn: turn)
                }
                if view.isWaitingOnModel {
                    WaitingRow(since: view.waitingSince(now: Date()))
                }
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
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

/// A user turn right-aligned in muted ink; an assistant turn's steps, then its text in secondary
/// ink, the brightest in the column after the field's own typing, which keeps `ink`.
struct TurnView: View {
    let turn: TurnRow

    var body: some View {
        switch turn.role {
        case .user:
            HStack {
                Spacer(minLength: Theme.Layout.assistantUserInset)
                Text(turn.text).font(Theme.Font.body).foregroundStyle(Theme.inkMuted)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 6) {
                ForEach(turn.steps) { step in
                    StepView(step: step)
                }
                if !turn.text.isEmpty {
                    Text(turn.text).font(Theme.Font.body).foregroundStyle(Theme.inkSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// One tool call: `→ tool arguments` and its state word, the result's first line under it, and
/// when opened the arguments and the whole result.
struct StepView: View {
    let step: StepRow
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Button {
                open.toggle()
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "chevron.right").font(Theme.Font.glyph)
                        .foregroundStyle(Theme.inkFaintest)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(step.line).font(Theme.Font.value).foregroundStyle(Theme.inkTertiary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(step.stateWord).font(Theme.Font.valueSmall)
                        .foregroundStyle(stateColour)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !open, !step.resultFirstLine.isEmpty {
                Text(step.resultFirstLine).font(Theme.Font.valueSmall)
                    .foregroundStyle(step.isError ? Theme.recording : Theme.inkFaint)
                    .lineLimit(1).truncationMode(.tail)
                    .padding(.leading, Theme.Layout.assistantStepIndent)
            }
            if open {
                VStack(alignment: .leading, spacing: 6) {
                    if !step.reason.isEmpty {
                        Text(step.reason).font(Theme.Font.aside).foregroundStyle(Theme.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !step.arguments.isEmpty {
                        StepBlock(title: "Arguments", text: step.arguments)
                    }
                    if !step.resultText.isEmpty {
                        StepBlock(title: "Result", text: step.resultText)
                    }
                    if !step.resultJSON.isEmpty {
                        StepBlock(title: "JSON", text: AssistantWords.pretty(json: step.resultJSON))
                    }
                }
                .padding(.leading, Theme.Layout.assistantStepIndent)
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

/// A section of an opened step: a section header over mono text that can be selected.
struct StepBlock: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(text: title)
            Text(text).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

/// What the assistant asks to do, the reason in its gate's words, and a button per answer the
/// question offers: Decline, Allow for this conversation when it can be granted for the rest of
/// the conversation (never for a delete or a cancel of another client's job), and Allow. No
/// button takes Return: a delete or a takeover is answered with a click, never a stray key.
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
            if !question.reason.isEmpty {
                Text(question.reason).font(Theme.Font.aside).foregroundStyle(Theme.caution)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer()
                let session = session
                let id = question.callID
                Button("Decline") { answer { await session.decline(callID: id) } }
                    .accessibilityIdentifier("assistant.decline")
                if question.offersConversation {
                    Button("Allow for this conversation") {
                        answer { await session.approve(callID: id, forConversation: true) }
                    }
                    .accessibilityIdentifier("assistant.allow.conversation")
                }
                Button("Allow") { answer { await session.approve(callID: id) } }
                    .accessibilityIdentifier("assistant.allow")
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(answering == question.callID)
        }
        .padding(12)
        .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderStrong))
        .padding(.horizontal, 12).padding(.bottom, 10)
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
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The usage line, then the field: it is never disabled, so the next message is written while the
/// assistant is on a turn or a question, and Return sends only once the daemon would take it;
/// until then the text stays. Stop shows beside the field while the assistant thinks or runs one
/// of the app's view tools. The text also comes back when the daemon did not take it.
/// `TuningKeyGuard` hands Space and the arrows to the field, or typing would mute and tune the
/// radio through the Tune menu's keys.
struct AssistantField: View {
    @Environment(AppSession.self) private var session
    let view: ConversationView?
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// A message has left `send()` and its reply is not back. `assistantSending` says the same
    /// only once the controller's change is copied to the session, and a second Return in that
    /// gap would send the message twice.
    @State private var submitting = false

    /// Return sends only while the daemon would take the message: not while one is on its way,
    /// and not while the assistant thinks or asks. With no conversation, or one that is over or
    /// lost, the message starts a new one (`AssistantController.needsStart`).
    private var canSend: Bool {
        guard !submitting, !session.assistantSending else { return false }
        guard let view, !session.assistantLost else { return true }
        return view.canSend || view.isOver
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let words = session.assistantUsage.words {
                Text(words).font(Theme.Font.valueSmall).foregroundStyle(Theme.inkFaint)
            }
            HStack(spacing: 8) {
                TextField("Ask the assistant", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(Theme.Font.body).foregroundStyle(Theme.ink)
                    .lineLimit(1...4)
                    .focused($focused)
                    .onSubmit(send)
                    .modifier(TuningKeyGuard(focused: focused))
                    .accessibilityIdentifier("assistant.input")
                if view?.canStop == true {
                    Button("Stop") { Task { await session.stopTurn() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Ends this turn; the conversation goes on")
                        .accessibilityIdentifier("assistant.stop")
                }
            }
            .padding(8)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Theme.borderFocus : Theme.border))
            if !canSend, !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(AssistantWords.returnWaits(view)).font(Theme.Font.valueSmall)
                    .foregroundStyle(Theme.inkFaint)
            }
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        guard canSend, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        draft = ""
        submitting = true
        Task {
            // What was typed while the message was on its way stays, under the text that failed.
            if !(await session.send(text)) { draft = draft.isEmpty ? text : text + "\n" + draft }
            submitting = false
        }
    }
}
