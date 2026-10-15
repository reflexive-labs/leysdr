// SPDX-License-Identifier: Apache-2.0

// The panel's rows from hand-made conversations: every tool call state, the pending question, the
// usage line and the failure words.

import LeylineProto
import XCTest

@testable import LeylineClient

final class AssistantModelsTests: XCTestCase {
    func call(
        _ id: String, _ tool: String, args: String = "{}", state: Leyline_V1_ToolCallState,
        result: String = "", isError: Bool = false, reason: String = ""
    ) -> Leyline_V1_ToolCall {
        var c = Leyline_V1_ToolCall()
        c.callID = id
        c.tool = tool
        c.argumentsJson = args
        c.state = state
        c.resultText = result
        c.isError = isError
        c.reason = reason
        return c
    }

    func turn(
        _ id: String, _ role: Leyline_V1_Role, _ text: String, done: Bool = true,
        tools: [Leyline_V1_ToolCall] = []
    ) -> Leyline_V1_Turn {
        var t = Leyline_V1_Turn()
        t.turnID = id
        t.role = role
        t.text = text
        t.done = done
        t.tools = tools
        return t
    }

    func conversation(
        _ state: Leyline_V1_ConversationState, turns: [Leyline_V1_Turn] = []
    ) -> Leyline_V1_Conversation {
        var c = Leyline_V1_Conversation()
        c.conversationID = "conv_01"
        c.state = state
        c.provider = "anthropic"
        c.model = "claude-sonnet-5-5"
        c.turns = turns
        return c
    }

    func testEveryToolCallStateHasItsWord() {
        let calls = [
            call("c1", "tune", args: #"{"frequency":"noaa"}"#, state: .toolCallRunning),
            call(
                "c2", "get_state", state: .toolCallDone,
                result: "\n1 capture, 1 channel\nthe rest"),
            call("c3", "set", state: .toolCallDone, result: "no such channel", isError: true),
            call(
                "c4", "delete_recording", args: #"{"recording":"rec_1"}"#,
                state: .toolCallAwaitingApproval,
                reason: "delete the recording and its files; this cannot be undone"),
            call("c5", "show_band", args: #"{"band":"2m"}"#, state: .toolCallAwaitingClient),
            call("c6", "remove_bookmark", state: .toolCallRefused, result: "the user declined"),
            call("c7", "scan", state: .toolCallRefused, result: "stopped"),
            call("c8", "listen_summary", state: .toolCallDone, result: "stopped", isError: true),
        ]
        let view = ConversationView(
            conversation(
                .conversationThinking,
                turns: [
                    turn("t1", .user, "  put on the weather radio \n"),
                    turn("t2", .assistant, "Looking.", done: false, tools: calls),
                ]))
        XCTAssertEqual(view.turns.map(\.role), [.user, .assistant])
        XCTAssertEqual(view.turns[0].text, "put on the weather radio")
        XCTAssertFalse(view.turns[1].done)
        let steps = view.turns[1].steps
        XCTAssertEqual(
            steps.map(\.stateWord),
            ["running", "done", "failed", "asks", "in the app", "declined", "stopped", "stopped"])
        XCTAssertEqual(steps[0].line, "\u{2192} tune noaa")
        XCTAssertEqual(steps[1].line, "\u{2192} get_state")
        XCTAssertEqual(steps[1].resultFirstLine, "1 capture, 1 channel")
        XCTAssertEqual(steps[1].resultText, "\n1 capture, 1 channel\nthe rest")
        XCTAssertTrue(steps[2].isError)
        XCTAssertEqual(
            steps[3].reason, "delete the recording and its files; this cannot be undone")
        XCTAssertTrue(view.isThinking)
        XCTAssertFalse(view.canSend)
        XCTAssertEqual(view.stateWord, "thinking")
        XCTAssertEqual(view.model, "anthropic claude-sonnet-5-5")
    }

    func testThePendingQuestionComesFromAWaitingConversation() throws {
        var c = conversation(.conversationWaiting)
        var p = Leyline_V1_PendingAction()
        p.callID = "c4"
        p.tool = "delete_recording"
        p.argumentsJson = #"{"recording":"rec_1"}"#
        p.reason = " delete the recording and its files; this cannot be undone "
        c.pending = p
        let view = ConversationView(c)
        let q = try XCTUnwrap(view.pending)
        XCTAssertEqual(q.callID, "c4")
        XCTAssertEqual(q.question, "The assistant wants to delete_recording rec_1.")
        XCTAssertEqual(q.reason, "delete the recording and its files; this cannot be undone")
        XCTAssertFalse(q.isViewTool)
        XCTAssertEqual(view.stateWord, "waiting for you")

        c.pending.viewTool = true
        XCTAssertEqual(ConversationView(c).stateWord, "working")
        XCTAssertEqual(ConversationView(c).pending?.isViewTool, true)

        // A pending action left on a conversation that has moved on is not a question.
        c.state = .conversationIdle
        XCTAssertNil(ConversationView(c).pending)
        XCTAssertTrue(ConversationView(c).canSend)
    }

    func testAFailedConversationSaysWhy() {
        var c = conversation(.conversationFailed)
        c.error.code = "INTERNAL"
        c.error.message = "the assistant stopped unexpectedly (status 2)"
        let view = ConversationView(c)
        XCTAssertTrue(view.isOver)
        XCTAssertEqual(view.errorText, "the assistant stopped unexpectedly (status 2)")
        c.error.message = ""
        XCTAssertEqual(ConversationView(c).errorText, "INTERNAL")
        XCTAssertNil(ConversationView(conversation(.conversationEnded)).errorText)
    }

    func testArgumentsSummariseOnOneLine() {
        XCTAssertEqual(AssistantWords.summary(argumentsJSON: ""), "")
        XCTAssertEqual(AssistantWords.summary(argumentsJSON: "{}"), "")
        XCTAssertEqual(
            AssistantWords.summary(argumentsJSON: #"{"frequency": 146520000}"#), "146520000")
        XCTAssertEqual(
            AssistantWords.summary(argumentsJSON: #"{"squelch": -45, "channel": "chan_1"}"#),
            "channel chan_1 \u{00B7} squelch -45")
        XCTAssertEqual(
            AssistantWords.summary(argumentsJSON: #"{"gains": {"LNA": 16}, "keep": true}"#),
            #"gains {"LNA":16} · keep true"#)
        XCTAssertEqual(AssistantWords.summary(argumentsJSON: "not\n json"), "not json")
        let long = AssistantWords.summary(
            argumentsJSON: #"{"note": "\#(String(repeating: "x", count: 200))"}"#)
        XCTAssertEqual(long.count, AssistantWords.summaryLimit)
        XCTAssertTrue(long.hasSuffix("\u{2026}"))
        XCTAssertEqual(
            AssistantWords.pretty(json: #"{"b":1,"a":"x/y"}"#),
            "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
        XCTAssertEqual(AssistantWords.pretty(json: "plain"), "plain")
    }

    func testUsageSumsTheConversationsLinesOnly() {
        func line(_ scope: String, day: String, req: UInt64, input: UInt64, output: UInt64)
            -> Leyline_V1_UsageLine
        {
            var l = Leyline_V1_UsageLine()
            l.scopeID = scope
            l.day = day
            l.feature = "assistant"
            l.requests = req
            l.inputTokens = input
            l.outputTokens = output
            return l
        }
        var lines = [
            line("conv_01", day: "2026-10-14", req: 2, input: 900, output: 300),
            line("conv_01", day: "2026-10-15", req: 1, input: 340, output: 100),
            line("conv_02", day: "2026-10-15", req: 9, input: 9_000, output: 900),
        ]
        let usage = UsageSoFar(lines: lines, conversationID: "conv_01")
        XCTAssertEqual(usage.requests, 3)
        XCTAssertEqual(usage.words, "3 requests, 1.2k in, 400 out")
        lines[1].cacheReadTokens = 12_400
        XCTAssertEqual(
            UsageSoFar(lines: lines, conversationID: "conv_01").words,
            "3 requests, 1.2k in, 400 out, 12k from cache")
        XCTAssertNil(UsageSoFar(lines: lines, conversationID: "conv_09").words)
        XCTAssertNil(UsageSoFar(lines: lines, conversationID: "").words)
        XCTAssertEqual(
            UsageSoFar(
                lines: [line("c", day: "d", req: 1, input: 5, output: 2)], conversationID: "c"
            )
            .words, "1 request, 5 in, 2 out")
    }

    func testTokensAreShort() {
        XCTAssertEqual(AssistantWords.tokens(0), "0")
        XCTAssertEqual(AssistantWords.tokens(999), "999")
        XCTAssertEqual(AssistantWords.tokens(1_000), "1k")
        XCTAssertEqual(AssistantWords.tokens(1_240), "1.2k")
        XCTAssertEqual(AssistantWords.tokens(12_400), "12k")
        XCTAssertEqual(AssistantWords.tokens(3_400_000), "3.4M")
    }

    func testAFailedStartPointsToSettingsWhenSettingsFixIt() {
        let missing = AssistantWords.failed(
            .start, LeylineError(code: "CREDENTIAL_MISSING", message: "no anthropic key"))
        XCTAssertTrue(missing.pointsToSettings)
        XCTAssertTrue(missing.text.contains("Settings"), missing.text)
        let noModel = AssistantWords.failed(
            .start,
            LeylineError(
                code: "FAILED_PRECONDITION", message: "ley ai use assistant <provider> <model>"))
        XCTAssertEqual(
            noModel, AssistantNotice(text: AssistantWords.noModel, pointsToSettings: true))
        let rejected = AssistantWords.failed(
            .start, LeylineError(code: "CREDENTIAL_REJECTED", message: "invalid x-api-key"))
        XCTAssertTrue(rejected.pointsToSettings)
        XCTAssertTrue(rejected.text.contains("invalid x-api-key"), rejected.text)
        // Not idle is the send's own precondition, and Settings does not fix it.
        let busy = AssistantWords.failed(
            .send, LeylineError(code: "FAILED_PRECONDITION", message: "the assistant is thinking"))
        XCTAssertFalse(busy.pointsToSettings)
        XCTAssertEqual(
            busy.text, "The assistant could not take the message: the assistant is thinking")
        XCTAssertEqual(
            AssistantWords.failed(.start, LeylineError(code: "UNAVAILABLE", message: "")).text,
            "The daemon is not running, so the assistant could not start.")
    }
}
