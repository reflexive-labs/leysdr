// SPDX-License-Identifier: GPL-3.0-or-later

// A `ley worker assistant` that plays a script instead of calling a model, for the daemon's
// assistant tests.
//
// It keeps the worker side of the stdio protocol in ai.proto ("Assistant worker") and nothing
// else: with LEYLINE_KEY_ON_STDIN=1 it reads one varint-delimited SetCredentialRequest, then
// WorkerEvents, and writes WorkerMessages. Its arguments are ignored, so a test can name it as
// `--ley` and the daemon's `worker assistant --conversation <id>` reaches it unchanged; `worker
// check` answers "accepted", so a test can add a key through the real RPC.
//
// FAKE_WORKER_SCRIPT names a file of blocks separated by blank lines, one block per UserMessage.
// Each line changes the assistant's turn and writes it whole:
//
//   text <words>              appends the words to the turn's text (not done)
//   tool <name> <json>        adds a RUNNING call
//   done <name> <result>      marks the newest call to <name> DONE with result_text
//   ask <name> <json> <why>   adds an AWAITING_APPROVAL call and waits for ActionResolved; a
//                             declined call goes REFUSED, an approved one RUNNING; a SetMode to
//                             AUTO meanwhile approves it once, as the worker does
//   offers <scope> ...        the scopes later asks in the block offer (once, conversation)
//   approved <line>           the line, only if the last ask was approved
//   declined <line>           the line, only if the last ask was declined
//   forconversation <line>    the line, only if the last ask was approved for the conversation
//   granted <name> <json> <why>  adds a DONE call with the reason, allowed_by the last ask's id,
//                             as a call a grant covered
//   view <name> <json>        adds an AWAITING_CLIENT call and waits for ViewToolAnswer, which
//                             marks it DONE with the answer
//   end                       marks the turn done, COMPLETED
//   fail [CODE] <message>     writes a WorkerFailure, INTERNAL unless the first word is a code
//                             (capitals and underscores), and nothing else
//   exit <n>                  exits with status n at once
//   sleep <ms>                waits
//   turnid <id>               renames the turn the following lines write
//   echokey                   the worst a worker can do with its key: puts it as it stands,
//                             JSON-escaped and percent-encoded into the turn's text, a RUNNING
//                             call's tool name, call id, arguments and result, and a stderr line
//   deaf                      as a block's first line, only in the first block: the worker reads
//                             its key and WorkerStart, then never reads stdin again
//
// `{key}` anywhere in a line is replaced with the key, so `fail` can carry it too.
//
// The assistant's turn for user turn `tN` is `tN+1`, and call ids count up across the
// conversation. WorkerStop marks the turn done (STOPPED) at once, mid-sleep or mid-wait, and skips
// the rest of the block. FAKE_WORKER_DUMP names a file the worker writes after its WorkerStart: its pid,
// the key's last four, its arguments, the WorkerStart (the transcript path and resume included),
// how many turns it resumed after, and its environment, one `name=value` per line. The key itself
// is never written anywhere.
//
// The worker keeps a transcript of its own at WorkerStart's transcript_path: one line per turn it
// played, `turn <id> calls <n>`. With `resume` it reads that file first and goes on from it: the
// next turn plays the block after the last one played, and call ids count on from the last.

import Foundation
import LeylineProto
import SwiftProtobuf

func readExactly(_ n: Int) -> [UInt8]? {
    var out = [UInt8]()
    out.reserveCapacity(n)
    var chunk = [UInt8](repeating: 0, count: max(n, 1))
    while out.count < n {
        let got = chunk.withUnsafeMutableBytes { read(0, $0.baseAddress, n - out.count) }
        if got < 0 && errno == EINTR { continue }
        guard got > 0 else { return nil }
        out.append(contentsOf: chunk[0..<got])
    }
    return out
}

func readDelimited() -> [UInt8]? {
    var length: UInt64 = 0
    var shift: UInt64 = 0
    while true {
        guard let b = readExactly(1)?.first else { return nil }
        length |= UInt64(b & 0x7F) << shift
        if b & 0x80 == 0 { break }
        shift += 7
        if shift > 63 { return nil }
    }
    if length == 0 { return [] }
    return readExactly(Int(length))
}

func writeDelimited(_ message: any Message) {
    guard let body = try? message.serializedBytes() as [UInt8] else { return }
    var out = [UInt8]()
    var n = UInt64(body.count)
    repeat {
        var b = UInt8(n & 0x7F)
        n >>= 7
        if n != 0 { b |= 0x80 }
        out.append(b)
    } while n != 0
    out.append(contentsOf: body)
    var offset = 0
    while offset < out.count {
        let written = out.withUnsafeBytes { write(1, $0.baseAddress!.advanced(by: offset), out.count - offset) }
        if written < 0 && errno == EINTR { continue }
        guard written > 0 else { exit(4) }
        offset += written
    }
}

let environment = ProcessInfo.processInfo.environment
let arguments = Array(CommandLine.arguments.dropFirst())

// `ley worker check`: one line in, one JSON line out.
if arguments.starts(with: ["worker", "check"]) {
    _ = readLine()
    print(#"{"outcome": "accepted", "message": "the fake worker accepts every key"}"#)
    exit(0)
}

/// The key, held only so `echokey` and `{key}` can play a worker that leaks it.
var secret = ""
if environment["LEYLINE_KEY_ON_STDIN"] == "1" {
    guard let bytes = readDelimited(), let key = try? Leyline_V1_SetCredentialRequest(serializedBytes: bytes),
          !key.secret.isEmpty
    else { exit(6) }
    secret = key.secret
}
let lastFour = String(secret.suffix(4))

guard let head = readDelimited(), let first = try? Leyline_V1_WorkerEvent(serializedBytes: head),
      case .start(let start)? = first.event
else {
    FileHandle.standardError.write(Data("fake worker: the first event was not WorkerStart\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("fake worker up for \(start.conversationID)\n".utf8))

var callCount = 0
var blockIndex = 0

/// The turns an earlier worker for this conversation played, read back when resuming.
var resumedLines: [String] = []
if start.resume, !start.transcriptPath.isEmpty,
   let text = try? String(contentsOfFile: start.transcriptPath, encoding: .utf8)
{
    resumedLines = text.split(separator: "\n").map(String.init)
    blockIndex = resumedLines.count
    if let last = resumedLines.last?.split(separator: " "), last.count == 4 { callCount = Int(last[3]) ?? 0 }
}

/// Notes a played turn in the transcript, for a worker that resumes after this one.
func noteTurn(_ turnID: String) {
    guard !start.transcriptPath.isEmpty else { return }
    let line = Data("turn \(turnID) calls \(callCount)\n".utf8)
    if !FileManager.default.fileExists(atPath: start.transcriptPath) {
        FileManager.default.createFile(atPath: start.transcriptPath, contents: nil, attributes: [.posixPermissions: 0o600])
    }
    guard let handle = FileHandle(forWritingAtPath: start.transcriptPath) else { return }
    handle.seekToEndOfFile()
    handle.write(line)
    try? handle.close()
}

if let dump = environment["FAKE_WORKER_DUMP"] {
    var lines = ["pid=\(getpid())", "last4=\(lastFour)", "argv=\(arguments.joined(separator: " "))",
                 "start.conversation=\(start.conversationID)", "start.provider=\(start.provider)",
                 "start.model=\(start.model)", "start.endpoint=\(start.endpoint)", "start.socket=\(start.socket)",
                 "start.view_tools=\(start.viewTools.map(\.name).joined(separator: ","))",
                 "start.transcript_path=\(start.transcriptPath)", "start.resume=\(start.resume)",
                 "start.mode=\(start.mode)",
                 "resumed.turns=\(resumedLines.count)"]
    for (name, value) in environment.sorted(by: { $0.key < $1.key }) { lines.append("env.\(name)=\(value)") }
    try? (lines.joined(separator: "\n") + "\n").write(toFile: dump, atomically: true, encoding: .utf8)
}

/// The script's blocks, one per user message, each a list of lines.
let blocks: [[String]] = {
    guard let path = environment["FAKE_WORKER_SCRIPT"],
          let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    var out: [[String]] = []
    var current: [String] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            if !current.isEmpty { out.append(current) }
            current = []
        } else {
            current.append(trimmed)
        }
    }
    if !current.isEmpty { out.append(current) }
    return out
}()

/// Events from the daemon, read on a thread of their own so a WorkerStop reaches a sleep or a wait.
/// Unchecked Sendable: `events` and `closed` are only touched under `lock`.
final class Inbox: @unchecked Sendable {
    private let lock = NSCondition()
    private var events: [Leyline_V1_WorkerEvent] = []
    private var closed = false

    func push(_ event: Leyline_V1_WorkerEvent) {
        lock.lock()
        events.append(event)
        lock.signal()
        lock.unlock()
    }

    func close() {
        lock.lock()
        closed = true
        lock.broadcast()
        lock.unlock()
    }

    /// The next event, waiting up to `seconds` (nil = for ever); nil on a timeout. Exits the
    /// process once stdin has closed and nothing is left, as a worker does.
    func next(within seconds: Double? = nil) -> Leyline_V1_WorkerEvent? {
        let deadline = seconds.map { Date().addingTimeInterval($0) }
        lock.lock()
        defer { lock.unlock() }
        while events.isEmpty {
            if closed { exit(0) }
            if let deadline {
                if !lock.wait(until: deadline) { return nil }
            } else {
                lock.wait()
            }
        }
        return events.removeFirst()
    }
}

// A worker that has stopped reading its input: the daemon's writes fill the pipe and stay there.
if blocks.first?.first == "deaf" {
    while true { sleep(60) }
}

let inbox = Inbox()
Thread.detachNewThread {
    while let bytes = readDelimited() {
        if let event = try? Leyline_V1_WorkerEvent(serializedBytes: bytes) { inbox.push(event) }
    }
    inbox.close()
}

/// The first `count` words of `line`, padded with empty ones, and the rest of the line.
func split(_ line: String, words count: Int) -> (head: [String], rest: String) {
    var parts = line.split(separator: " ", maxSplits: count, omittingEmptySubsequences: true).map(String.init)
    let rest = parts.count > count ? parts.removeLast() : ""
    while parts.count < count { parts.append("") }
    return (parts, rest)
}

func nowNs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1e9) }

/// Plays one block as the assistant's answer to the user turn `userTurnID`.
func play(_ lines: [String], userTurnID: String) {
    var turn = Leyline_V1_Turn()
    turn.turnID = "t\((Int(userTurnID.dropFirst()) ?? 0) + 1)"
    turn.role = .assistant
    turn.atNs = nowNs()
    var lastApproved: Bool?
    var lastScope = Leyline_V1_ApprovalScope.unspecified
    var lastAskID = ""
    var offers: [Leyline_V1_ApprovalScope] = []

    func send() {
        var message = Leyline_V1_WorkerMessage()
        message.turn = turn
        writeDelimited(message)
    }
    func stopped() {
        turn.done = true
        turn.stopReason = .stopped
        send()
    }
    /// Waits for an event `accept` takes; false when a WorkerStop came first.
    func wait(for accept: (Leyline_V1_WorkerEvent) -> Bool) -> Bool {
        while true {
            guard let event = inbox.next() else { continue }
            if case .stop? = event.event { return false }
            if accept(event) { return true }
        }
    }
    func addCall(_ name: String, _ json: String, _ state: Leyline_V1_ToolCallState, reason: String = "") -> Int {
        callCount += 1
        var call = Leyline_V1_ToolCall()
        call.callID = "call\(callCount)"
        call.tool = name
        call.argumentsJson = json.isEmpty ? "{}" : json
        call.state = state
        call.reason = reason
        call.atNs = nowNs()
        turn.tools.append(call)
        return turn.tools.count - 1
    }

    for raw in lines {
        var line = raw.replacingOccurrences(of: "{key}", with: secret)
        if line.hasPrefix("approved ") || line.hasPrefix("declined ") {
            guard lastApproved == line.hasPrefix("approved ") else { continue }
            line = String(line.dropFirst("approved ".count))
        }
        if line.hasPrefix("forconversation ") {
            guard lastApproved == true, lastScope == .conversation else { continue }
            line = String(line.dropFirst("forconversation ".count))
        }
        // A stop that arrived while the worker was busy is honoured before the next line.
        while let event = inbox.next(within: 0) {
            if case .stop? = event.event { return stopped() }
        }
        let (head, rest) = split(line, words: 1)
        switch head[0] {
        case "text":
            turn.text += (turn.text.isEmpty ? "" : " ") + rest
            send()
        case "tool":
            let (name, json) = split(rest, words: 1)
            _ = addCall(name[0], json, .toolCallRunning)
            send()
        case "done":
            let (name, result) = split(rest, words: 1)
            if let i = turn.tools.lastIndex(where: { $0.tool == name[0] }) {
                turn.tools[i].state = .toolCallDone
                turn.tools[i].resultText = result
            }
            send()
        case "offers":
            offers = rest.split(separator: " ").map { $0 == "conversation" ? .conversation : .once }
        case "granted":
            let (args, reason) = split(rest, words: 2)
            let i = addCall(args[0], args[1], .toolCallDone, reason: reason)
            turn.tools[i].allowedBy = lastAskID
            send()
        case "ask":
            let (args, reason) = split(rest, words: 2)
            let i = addCall(args[0], args[1], .toolCallAwaitingApproval, reason: reason)
            turn.tools[i].offers = offers
            send()
            let id = turn.tools[i].callID
            lastAskID = id
            var approved = false
            var scope = Leyline_V1_ApprovalScope.unspecified
            let answered = wait {
                if case .setMode(let m)? = $0.event, m.mode == .auto {
                    approved = true
                    scope = .once
                    return true
                }
                guard case .resolved(let r)? = $0.event, r.callID == id else { return false }
                approved = r.approved
                scope = r.scope
                return true
            }
            guard answered else { return stopped() }
            lastApproved = approved
            lastScope = scope
            turn.tools[i].state = approved ? .toolCallRunning : .toolCallRefused
            send()
        case "view":
            let (name, json) = split(rest, words: 1)
            let i = addCall(name[0], json, .toolCallAwaitingClient)
            send()
            let id = turn.tools[i].callID
            var answer = Leyline_V1_ViewToolAnswer()
            let answered = wait {
                guard case .viewAnswer(let a)? = $0.event, a.callID == id else { return false }
                answer = a
                return true
            }
            guard answered else { return stopped() }
            turn.tools[i].state = .toolCallDone
            turn.tools[i].resultText = answer.resultText
            turn.tools[i].resultJson = answer.resultJson
            turn.tools[i].isError = answer.isError
            send()
        case "end":
            turn.done = true
            turn.stopReason = .completed
            send()
        case "turnid":
            turn.turnID = rest
        case "echokey":
            let json = (try? JSONEncoder().encode(secret)).map { String(decoding: $0.dropFirst().dropLast(), as: UTF8.self) } ?? ""
            let url = secret.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            turn.text += "key \(secret) json \(json) url \(url)"
            let i = addCall("echo_\(secret)", #"{"key": "\#(json)"}"#, .toolCallRunning)
            turn.tools[i].callID = "call_\(secret)"
            turn.tools[i].resultText = "sent ?key=\(url) and \(secret)"
            FileHandle.standardError.write(Data("fake worker leaks \(secret) and \(url)\n".utf8))
            send()
        case "fail":
            let (first, after) = split(rest, words: 1)
            let isCode = first[0].count > 1 && first[0].allSatisfy { $0.isUppercase || $0 == "_" }
            var message = Leyline_V1_WorkerMessage()
            message.failure.error.code = isCode ? first[0] : "INTERNAL"
            message.failure.error.message = isCode ? after : rest
            writeDelimited(message)
        case "exit":
            exit(Int32(rest) ?? 1)
        case "sleep":
            let deadline = Date().addingTimeInterval((Double(rest) ?? 0) / 1000)
            while Date() < deadline {
                if let event = inbox.next(within: deadline.timeIntervalSinceNow), case .stop? = event.event {
                    return stopped()
                }
            }
        default:
            FileHandle.standardError.write(Data("fake worker: unknown script line: \(line)\n".utf8))
        }
    }
}

while true {
    guard let event = inbox.next() else { continue }
    // Only a user message starts a turn; anything else between turns has nothing to act on.
    guard case .user(let user)? = event.event else { continue }
    play(blockIndex < blocks.count ? blocks[blockIndex] : [], userTurnID: user.turnID)
    blockIndex += 1
    noteTurn("t\((Int(user.turnID.dropFirst()) ?? 0) + 1)")
}
