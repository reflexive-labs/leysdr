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
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(session.assistantShown ? Theme.inkSecondary : Theme.inkMuted)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Theme.border, in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(session.assistantShown ? "Hide Assistant (⇧⌘A)" : "Show Assistant (⇧⌘A)")
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
                    Image(systemName: "square.and.pencil").font(.system(size: 12))
                        .foregroundStyle(Theme.inkMuted)
                }
                .buttonStyle(.plain)
                .help("New Conversation: ends this one and starts empty")
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
            }
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
    }
}

/// A user turn right-aligned in muted ink; an assistant turn in body text with its steps.
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
                    Text(turn.text).font(Theme.Font.body).foregroundStyle(Theme.ink)
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
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
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

/// What the assistant asks to do, the reason in its gate's words, and Allow or Decline. Neither
/// button takes Return: a delete or a takeover is answered with a click, never a stray key.
struct PendingCard: View {
    @Environment(AppSession.self) private var session
    let question: PendingQuestion

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
                Button("Decline") { Task { await session.decline(callID: question.callID) } }
                Button("Allow") { Task { await session.approve(callID: question.callID) } }
            }
            .buttonStyle(.bordered).controlSize(.small)
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
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The usage line, then the field: Return sends; the field waits while the assistant is on a turn
/// or a question, and Stop shows beside it while it thinks or runs one of the app's view tools.
/// The field takes the focus back when it can be typed in again, if it had it when the message
/// went. The text stays in the
/// field until the daemon has taken it. `TuningKeyGuard` hands Space and the arrows to the field,
/// or typing would mute and tune the radio through the Tune menu's keys.
struct AssistantField: View {
    @Environment(AppSession.self) private var session
    let view: ConversationView?
    @State private var draft = ""
    @FocusState private var focused: Bool
    /// The field had the focus when the message went, so it takes it back when it can be typed
    /// in again; a field the person had left alone does not take the focus from elsewhere.
    @State private var refocus = false

    private var canType: Bool {
        guard !session.assistantSending else { return false }
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
                    .disabled(!canType)
                    .onSubmit(send)
                    .modifier(TuningKeyGuard(focused: focused))
                    .onChange(of: canType) { _, now in
                        guard now, refocus else { return }
                        refocus = false
                        focused = true
                    }
                if view?.canStop == true {
                    Button("Stop") { Task { await session.stopTurn() } }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Ends this turn; the conversation goes on")
                }
            }
            .padding(8)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(focused ? Theme.borderFocus : Theme.border))
        }
        .padding(12)
    }

    private func send() {
        let text = draft
        guard canType, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        draft = ""
        refocus = focused
        Task {
            if !(await session.send(text)) { draft = text }
        }
    }
}
