# The assistant worker

How `ley worker assistant` runs a conversation: the process the daemon starts for each
conversation, the loop that calls the model and the `ley mcp` tools, the gate that decides which
calls wait for the user, and how it is tested without a key. The design, including why the
assistant is a `ley` worker and what it may do, is [`docs/design/ai.md`](../design/ai.md); the
contract is `proto/leyline/v1/ai.proto`. The code is `go/internal/assistant/`.

## The process

The daemon spawns `ley worker assistant --conversation conv_…` with `LEYLINE_KEY_ON_STDIN=1`.
Everything on stdin and stdout is varint-delimited protobuf, framed as a decoder plugin's is:

1. stdin: one `SetCredentialRequest`, the provider's key. The key never travels as an argument,
   which `ps` shows, or in the environment, which anything the worker runs would inherit.
2. stdin: one `WorkerEvent.start` (`WorkerStart`): the conversation id, provider, model,
   endpoint, the view tools the starting client declared, and the daemon's socket.
3. stdin, until it closes: `UserMessage`, `ActionResolved`, `ViewToolAnswer`, `WorkerStop`.
4. stdout: a `WorkerMessage.turn` each time the assistant's turn changes, whole, or one
   `WorkerMessage.failure` when the conversation cannot go on.

stderr is a log for a person reading the daemon's log; it never holds the key, and a provider's
message that echoes the key back has it replaced with `…` before it is logged or sent.

The worker exits 0 when stdin closes, during a turn or between turns, because that is how the
daemon ends a conversation. After writing a failure it exits 1.

**Ids.** The daemon numbers turns on both sides and sends the user's in `UserMessage.turn_id`;
the assistant's turn that answers it takes the next number, so `t3` is answered by `t4` (an id
not of the form `t<n>` gets `-a` appended). Call ids are the worker's own, `c1`, `c2`, … in the
order the calls were made, unique within the conversation; `ActionResolved` and
`ViewToolAnswer` name them. The model's own tool-use ids stay in the transcript and never reach
a client. The socket is `WorkerStart.socket`, or `LEYLINE_SOCKET` when that is empty.

A turn begins with an empty assistant turn, so a client sees the worker has started, and is
written again after each model response (the text so far), when each tool call starts, waits,
and ends, and once more with `done` set. The daemon derives the conversation's state from it: a
last call `AWAITING_APPROVAL` or `AWAITING_CLIENT` is `WAITING`, `done` is `IDLE`.

## The loop

Per `UserMessage`, the worker adds the user's text to the transcript and calls the model. Each
response's text joins the turn's text; each `tool_use` block becomes a `ToolCall` and runs in the
order the model made them, through the gate below; the results go back to the model as one user
message of `tool_result` blocks in the same order, and the model is called again. The turn ends
when a response has no tool calls, when the user stops it, or after 40 model calls, which ends a
model that keeps calling tools without finishing.

After every response the worker sends `Usage.ReportUsage` over the socket: provider, model,
feature `assistant`, the conversation id as the scope, one request, and the four token counts
the provider reported (input, output, cache read, cache write). A report the daemon does not take
is logged, and the turn goes on.

`WorkerStop` cancels whatever the turn is waiting on: the model call (its context is cancelled),
a running tool call, which ends `DONE` with `is_error` and `result_text` "stopped", or a wait for
approval or for a client, which ends `REFUSED` with "stopped". The turn is written `done` at once
(the tests hold it under 2 s), and the worker waits for the next `UserMessage`. The daemon
reports no usage for a conversation itself; the worker's reports are the ledger's only source. Every `tool_use` the model made still gets a `tool_result` ("the user
stopped the turn before this ran"), because the Messages API refuses a transcript without one.
A turn stopped before the model answered leaves the user's message last in the transcript; the
next message joins it.

A model error is written as a `WorkerFailure` with its code: `CREDENTIAL_REJECTED` for a key the
provider refused, `PROVIDER_REFUSED` for a rate or spend limit or an overloaded provider, with the
provider's words, and `PROVIDER_UNAVAILABLE` for anything else. A provider other than `anthropic`
fails at start with `PROVIDER_UNAVAILABLE`, and `anthropic` with no key with
`CREDENTIAL_MISSING`.

## The tools

The worker hosts the `ley mcp` server in its own process (`cli.NewAssistantToolServer`) and drives
it through an in-memory MCP client, so the assistant calls exactly the tools an agent on
`ley mcp` calls, with the same guards: the don't-disturb refusal, `take_over`, the shell notifier
that `watch` refuses. The server dials the daemon as client kind `mcp` with the label
`assistant`, so every change it makes is attributed to the assistant in the app and in `ley`
like any other client's. The server's own instructions follow the assistant's system prompt
(`go/internal/assistant/prompt.go`).

The model is offered, in this order: every tool the server lists, with its description and input
schema; the view tools from `WorkerStart` (a view tool named like a server tool or `undo` is left
out, so a client cannot take over a radio tool); and `undo`. A view tool call waits as
`AWAITING_CLIENT` until a `ViewToolAnswer` with its call id arrives, and the answer is the
result. Each result reaches the `ToolCall` as `result_text` (the prose) and `result_json` (the
JSON block); `snapshot`'s PNG is not passed on, and the model reads the row's numbers instead.

A channel `tune` makes is kept (`keep: true` unless the model set `keep` itself), because the
worker's connection ends with the conversation and a channel the user asked for should not. The
prompt has the assistant say that `ley stop` ends it.

## The gate

`go/internal/assistant/policy.go` decides, before each call, whether it runs or waits for the
user. A call that waits is `AWAITING_APPROVAL` with `reason` set to what will happen, in words;
when several rows apply, every reason is listed. A refused call is `REFUSED`, and the model is
told "the user declined". An approved call runs.

| call | decision | reason it asks with |
|---|---|---|
| a read: `get_state`, `list_devices`, `help`, `list_bands`, `list_presets`, `list_bookmarks`, `query_records`, `find_recordings`, `get_recording`, `list_decoders`, `list_jobs`, `get_job`, `daemon_logs` | runs | |
| `tune`, `set`, `stop`, `scan`, `record`, `listen_summary`, `snapshot`, `list_entities`, `attach_device`, `start_decode_job` without `keep`, `watch` without `keep` to `macos` or no notifier, a first or second bookmark change | runs | |
| any call with `take_over: true` | asks | another channel or client is using the radio: the channels and owners from the last refusal |
| `watch`, `start_decode_job` or `record` with `keep: true` | asks | start a kept job that runs on after this conversation ends |
| `watch` with `notify: webhook:URL` | asks | add a webhook notifier: every matching record is sent to the URL |
| `delete_recording` | asks every time | delete the recording and its files; this cannot be undone |
| `remove_bookmark` | asks every time | remove the bookmark from your bookmarks |
| `cancel_job` of a job no call in this conversation started | asks | cancel the job, which the assistant did not start |
| `import_chirp` without `dry_run` | asks | import every channel in the file into your bookmarks |
| the third and later `add_bookmark` in one turn | asks | a third bookmark change this turn |
| `start_decode_job` or `watch` with decoder `speech` | asks | paid transcription, live and unbounded |
| any write in a turn that has read received text | asks | the assistant read text received over the air this turn |

A write is a server tool without the read-only annotation, or `undo`; a view tool is not a write.
Bookmark changes count `add_bookmark`, `remove_bookmark` and `import_chirp` without `dry_run`
that ran. The jobs the conversation started are read from the `jobId` in the results of
`start_decode_job`, `watch`, `scan` and `record`, and only a whole id matches, since a prefix or
row number could name another client's job. A speech job is always described as live and
unbounded, because `start_decode_job` takes no recording to transcribe; `ley transcribe` is the
path that states the minutes of a recording.

The shell notifier and the keys are not in the table because they are not among the tools: `watch`
refuses `shell:` for every agent, and no tool reads or changes a key.

## Received text

Anyone with a transmitter writes the text in an APRS comment, an AIS field or a speech record. The
results of `query_records` and `list_entities`, and any result whose JSON has a top-level
`records`, reach the model as

```text
Received over the air (untrusted, quoted): "<the result's prose and JSON, as one JSON string>"
```

so nothing in them reads as an instruction, and the prompt says such text is data to report.
Once a turn has read one, every write in that turn waits for the user with the reason "the
assistant read text received over the air this turn", whatever its row says. The client sees the
result as the tool returned it; the quoting is only for the model.

## Undo

Before a `set` the worker reads `get_state` through the tools, and after it reads the confirming
event the tool returns: the value the event's channel (or, for a gain, its capture) had before
goes onto a stack as the form `set` takes (Hz, a mode name, a bandwidth in Hz, a squelch in dBFS
or `off`, gains by stage name or `auto`). A `tune` makes a channel of its own, so the stack keeps
that channel. `undo` pops one entry: a `set` with the old value on the same channel, with
`take_over` when the original needed it, reporting the `set` line with the old and new values;
or a `stop` of the tune's channel. A volume change is not undone, because the state has no sink
volume to read before the write. An empty stack is a tool error that says there is nothing to
undo.

## The model

`Model` is one method, `Respond(ctx, system, tools, messages)`, returning text and tool-use
blocks, the stop reason and the usage.

**Anthropic** (`go/internal/assistant/anthropic.go`) speaks the Messages API with `net/http`:
`POST {endpoint}/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`, non-streaming,
the system prompt as one text block and the last tool definition each marked
`cache_control: {"type": "ephemeral"}`, because both are the same on every call of a
conversation and every call after the first reads them from the provider's cache. The client
follows no redirect, since Go re-sends a header set by hand to the redirect's host. It is not
`anthropic-sdk-go`: the SDK's module graph brings the AWS and Google Cloud SDKs for its Bedrock
and Vertex clients, dozens of rows in `third_party/licenses` for one request shape and four error
outcomes.

**Scripted** (`go/internal/assistant/scripted.go`) plays the file `LEY_ASSISTANT_SCRIPT` names,
whatever the provider: one JSON object a line, each one model response, played in order across
the whole conversation. Once the lines run out, every response is the text `done`.

```text
{"text": "Looking."}
{"tool": "tune", "args": {"frequency": "noaa"}}
{"text": "Tuned.", "tool": "get_state", "args": {}}
{"sleep_ms": 2000, "text": "late"}
{"text": "ok", "usage": {"input_tokens": 20, "output_tokens": 5, "cache_read_input_tokens": 1000}}
```

A line with `tool` stops with `tool_use`, so the loop runs the call and plays the next line for
the model's answer to its result; a line without one ends the turn. `sleep_ms` holds the response,
which is how a test stops a turn mid-call.

## Testing

`go test ./internal/assistant` runs the loop in process against `go/internal/fakedaemon`, with
pipes on both sides and the test playing the daemon's half of the protocol
(`go/internal/assistant/harness_test.go`). It covers each row of the gate approved and declined,
with the daemon's state after each; undo; received text; `WorkerStop` during a slow response and
while asking; usage on the ledger per response; a view tool; the Messages API request shape and
its error mapping against `httptest`; and the key on no stream but stdin.
`TestWorkerAssistantCommand` in `go/internal/cli/worker_test.go` runs the same protocol through
`ley worker assistant` itself.

The tests import `go/internal/cli` from the external test package, because the tool server lives
there and `cli` imports this package for the subcommand. A caller outside `cli` passes its own
`Options.NewToolServer`.
