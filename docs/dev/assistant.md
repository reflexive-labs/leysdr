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
   endpoint, the view tools the starting client declared, the daemon's socket, the transcript
   path, `resume`, and the conversation's `mode`.
3. stdin, until it closes: `UserMessage`, `ActionResolved`, `ViewToolAnswer`, `WorkerStop`, `SetMode`.
4. stdout: a `WorkerMessage.turn` each time the assistant's turn changes, whole, or one
   `WorkerMessage.failure` when the conversation cannot go on.

stderr is a log for a person reading the daemon's log; it never holds the key, and a provider's
message that echoes the key back has it replaced with `…` before it is logged or sent.

The worker exits 0 when stdin closes, during a turn or between turns, because that is how the
daemon ends a conversation or stops the worker of an idle one. After writing a failure it exits 1.

## The transcript

The worker keeps the model transcript, the messages it sends the model, in the file
`WorkerStart.transcript_path` names (`<data>/conversations/<id>/transcript.jsonl`, beside the
daemon's `conversation.json`), so a worker started later for the same conversation gives the model
the context it had. Each message the loop adds is appended as it is added, one `Message` a line as
JSON, in one `write(2)`: the user's text, each model response, each turn's tool results. The file
is created 0600, and the key, as it stands and JSON-escaped, is replaced with `[key]` in a line
before it is written. The daemon never reads the file; it only names it, and removes it with the
conversation.

The daemon starts a worker with `resume` set when the conversation went on before it: after the
idle sweep stopped the last worker, after a worker exited between turns, or after a restart. Such a
worker loads the file before its first model call (`LoadTranscript`): lines of one role in a row
join into one message (the loop writes the user's next text as a line of its own after a turn's
tool results), a line that is not a message (one a crash cut short) is skipped, and the next
append starts on a line of its own when the file does not end in a newline, so a torn line never
takes a whole one with it; a `tool_use`
left without a `tool_result`, from a worker stopped mid-call, is given one that says the call was
cut short, since the Messages API refuses a transcript without it. The call ids go on from the
`tool_use` blocks the file holds, so they stay unique within the conversation, and a
`tool_result` that quotes received text makes later writes ask, as it did before. A missing or
unreadable file is logged and the worker starts from an empty transcript; it never fails the
conversation for it. The worker appends a user message as soon as it has it and the daemon saves
the conversation on its own schedule, so a crash between the two can leave a user line in the
transcript that the conversation lacks; the next user line is then joined to it on load, and the
model reads both. The undo stack is not kept: a resumed worker undoes only what it did.

The user's grants for the rest of the conversation (below, under "The gate") are kept in the same
file, one line each, `{"role": "grant", "grant": {"rows": [...], "call_id": "c3"}}`, appended
when the answer arrives. A load gives them to the gate and leaves them out of the messages, so the
model is never sent one, and a grant line is not counted as skipped. They share the file rather
than taking one of their own because the transcript is already where a resumed worker looks, it
goes with the conversation when the daemon removes it, and its append keeps a line whole.

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
model that keeps calling tools without finishing. A response that stops with `max_tokens` (cut
at the output limit, perhaps mid tool call) or `refusal` ends the turn too: its text is kept, its
tool calls do not run, and the turn ends with a line saying which it was.

The model reads at most 32 KB of one result; a longer one is cut there and ends with "(result cut
at 32 KB; ask for fewer)". The client's `result_text` and `result_json` stay whole.

After every response the worker sends `Usage.ReportUsage` over the socket: provider, model,
feature `assistant`, the conversation id as the scope, one request, and the four token counts
the provider reported (input, output, cache read, cache write). A report the daemon does not take
is logged, and the turn goes on.

`WorkerStop` cancels whatever the turn is waiting on: the model call (its context is cancelled),
a running tool call, which ends `DONE` with `is_error` and `result_text` "stopped", or a wait for
approval or for a client, which ends `REFUSED` with "stopped". The turn is written `done` at once
(the tests hold it under 2 s), and the worker waits for the next `UserMessage`. The daemon
reports no usage for a conversation itself; the worker's reports are the ledger's only source.
Every `tool_use` the model made still gets a `tool_result` ("the user stopped the turn before
this ran"), because the Messages API refuses a transcript without one. A cancelled context
(SIGTERM) ends any wait the same way and the worker exits.
A turn stopped before the model answered leaves the user's message last in the transcript; the
next message joins it.

A model error is written as a `WorkerFailure` with its code: `CREDENTIAL_REJECTED` for a key the
provider refused, `PROVIDER_REFUSED` for a rate or spend limit or an overloaded provider, with the
provider's words (a 400 `invalid_request_error` that mentions credit or billing is an account
out of credit, and is `PROVIDER_REFUSED` too), and `PROVIDER_UNAVAILABLE` for anything else; each
model's mapping is under "The model" below. A provider the worker has no model for (neither
`anthropic` nor `openai`, and no endpoint) fails at start with `PROVIDER_UNAVAILABLE`, and a
provider with no key with `CREDENTIAL_MISSING`, naming `ley ai add <provider>`. So does an
endpoint that would send the key in the clear, with `PROVIDER_UNAVAILABLE`: it must be `https`, or
plain `http` to `localhost`, `127.0.0.1` or `::1` only ("the endpoint must be https").

## The tools

The worker hosts the `ley mcp` server in its own process (`cli.NewAssistantToolServer`) and drives
it through an in-memory MCP client, so the assistant calls exactly the tools an agent on
`ley mcp` calls, with the same guards: the don't-disturb refusal, `take_over`, the shell notifier
that `watch` refuses. The server dials the daemon as client kind `mcp` with the label
`assistant`, so every change it makes is attributed to the assistant in the app and in `ley`
like any other client's. The server's own instructions follow the assistant's system prompt
(`go/internal/assistant/prompt.go`).

The model is offered, in this order: every tool the server lists, with its description and input
schema; the view tools from `WorkerStart`; and `undo`. A view tool is left out, with a line on
stderr, when its name is not 1 to 64 letters, digits, `_` or `-` (what the Messages API accepts),
when it is named like a server tool or `undo` (so a client cannot take over a radio tool), or
when it is declared twice. A view tool call waits as `AWAITING_CLIENT` until a `ViewToolAnswer`
with its call id arrives, and the answer is the result; the model reads it quoted, as received
text (below). Each result reaches the `ToolCall` as `result_text` (the prose) and `result_json` (the
JSON block); `snapshot`'s PNG is not passed on, and the model reads the row's numbers instead.

A channel `tune` makes is kept (`keep: true` unless the model set `keep` itself), because the
worker's connection ends with the conversation and a channel the user asked for should not. The
prompt has the assistant say that `ley stop` ends it.

## The gate

`go/internal/assistant/policy.go` decides, before each call, whether it runs or waits for the
user. A call that waits is `AWAITING_APPROVAL` with `reason` set to what will happen, in words;
when several rows apply, every reason is listed. A refused call is `REFUSED`, and the model is
told "the user declined". An approved call runs.

A call that waits also carries `offers`, the scopes `ResolveAction` may approve it with, which the
daemon copies into `PendingAction.offers`: `ONCE` and `CONVERSATION`, or `ONCE` alone when one of
the rows it lists asks every time: a delete, which cannot be undone, and cancelling a job the
assistant did not start, where a grant would cover every other client's job while the question named
one. An approval with scope `CONVERSATION` grants every row the question listed for the rest of the
conversation. The gate keeps grants by row, not by tool, so one answer to a take-over by `tune` lets
a take-over by `scan` or `record` run too. A later call whose rows are all granted runs without
asking, with `reason` set as it would have asked and `allowed_by` set to the call id of the question
that granted it; a call with a granted row and one that is not asks about the one that is not, and
its answer can grant that one. A grant comes only from `ActionResolved`: words in a user message
grant nothing. An approval for the conversation that the question did not offer is taken as once and
logged.

`WorkerStart.mode` sets the baseline, and `WorkerEvent.set_mode` (which `SetApprovalMode` sends)
changes it from the next call on. In `ASK`, the default, the table below decides. In `AUTO` every
row runs, the delete and the received-text rule included, with `reason` set and `allowed_by` empty,
so the conversation never waits; a call waiting on a question when the mode becomes `AUTO` is
approved once and runs. `ley ask --yes`, the test harness (`../design/ai.md`, "The assistant"),
starts a conversation in `AUTO`, or sets it on the one `--continue` carries on. The system prompt's
paragraph on approval follows the mode, so the model is not told a call will wait when none does.
The shell notifier and the keys stay outside in every mode, because they are not among the tools.

| call | decision | reason it asks with |
|---|---|---|
| a read: `get_state`, `list_devices`, `help`, `list_bands`, `list_presets`, `list_bookmarks`, `query_records`, `find_recordings`, `get_recording`, `list_decoders`, `list_jobs`, `get_job`, `daemon_logs` | runs | |
| `tune`, `set`, `stop`, `scan`, `record`, `listen_summary`, `snapshot`, `list_entities`, `attach_device`, `start_decode_job` without `keep`, `watch` without `keep` to `macos` or no notifier, a first or second bookmark change | runs | |
| any call with `take_over: true` | asks | another channel or client is using the radio: the channels and owners from the last refusal |
| `watch`, `start_decode_job` or `record` with `keep: true` | asks | start a kept job that runs on after this conversation ends |
| `watch` with `notify: webhook:URL` | asks | add a webhook notifier: every matching record is sent to the URL |
| `delete_recording` | asks every time; offers once only | delete the recording and its files; this cannot be undone |
| `remove_bookmark` | asks | remove the bookmark from your bookmarks |
| `cancel_job` of a job no call in this conversation started | asks every time; offers once only | cancel the job, which the assistant did not start |
| `import_chirp` without `dry_run` | asks | import every channel in the file into your bookmarks |
| the third and later `add_bookmark` in one turn | asks | a third bookmark change this turn |
| `start_decode_job` or `watch` whose decoder is `speech` or one of its aliases (`transcribe`) | asks | paid transcription, live and unbounded |
| `start_decode_job` or `watch` whose decoder the daemon cannot resolve | asks | the assistant could not check whether it is paid transcription |
| any write after the conversation has read received text | asks | the assistant read text received over the air earlier in this conversation |

A write is a server tool without the read-only annotation, or `undo`; a view tool is not a write.
Bookmark changes count `add_bookmark`, `remove_bookmark` and `import_chirp` without `dry_run`
that ran. The jobs the conversation started are read from the `jobId` in the results of
`start_decode_job`, `watch`, `scan` and `record`, and only a whole id matches, since a prefix or
row number could name another client's job. The take-over reason names the listeners from the
newest refusal that offered `take_over`, and any call that works clears it, so a later prompt
never names a listener who may have gone. The decoder is resolved through `ListDecoders` before
the gate, so an alias of the speech decoder asks as `speech` does, and a name that cannot be
checked asks rather than runs. A speech job is always described as live and
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

so nothing in them reads as an instruction, and the prompt says such text is data to report. A
view tool's answer is quoted the same way, because the client may answer with decoded text it
shows. Once the conversation has read one, every later write, in that turn and every turn after
it, waits for the user with the reason "the assistant read text received over the air earlier in
this conversation", whatever its row says: what the model read in one turn is still in its
context in the next. The client sees the result as the tool returned it; the quoting is only for
the model.

## Undo

Before a `set` the worker reads `get_state` through the tools, and after it reads the confirming
event the tool returns: the value the event's channel (or, for a gain, its capture) had before
goes onto a stack as the form `set` takes (Hz, a mode name, a bandwidth in Hz, a squelch in dBFS
or `off`, gains by stage name or `auto`). A `tune` makes a channel of its own, so the stack keeps
that channel. `undo` pops one entry: a `set` with the old value on the same channel, with
`take_over` when the original needed it, reporting the `set` line with the old and new values;
or a `stop` of the tune's channel. A change whose old value could not be read (a volume, since
the state has no sink volume) still goes on the stack, and undoing it is a tool error, "cannot
undo volume", that pops it, so the change before it is next rather than undone in its place.
When the entry's channel is gone (the user stopped it), undo pops it and says "that channel was
already stopped", so one gone channel does not block every undo behind it. An empty stack is a
tool error that says there is nothing to undo.

## The model

`Model` is one method, `Respond(ctx, system, tools, messages)`, returning text and tool-use
blocks, the stop reason and the usage. The messages are in the worker's own form, the Messages
API's blocks (`go/internal/assistant/model.go`), whatever the provider; the transcript file holds
the same form, so a resumed worker loads it the same way for either model. A conversation keeps
the provider it started with.

The worker picks the model from `WorkerStart`:

| `provider` | `endpoint` | model | default model |
|---|---|---|---|
| any, with `LEY_ASSISTANT_SCRIPT` set | | Scripted | |
| `anthropic` | empty: `https://api.anthropic.com` | Anthropic | none |
| `openai` | empty: `https://api.openai.com` | OpenAI | `gpt-5` |
| any other | set: a gateway or a local model server | OpenAI | none: fails `FAILED_PRECONDITION`, naming `ley ai use assistant <provider> <model>` |
| any other | empty | none: fails `PROVIDER_UNAVAILABLE` | |

`gpt-5` is a placeholder until the evals choose a default. The usage reports name the model that
ran, the default included. Both models make one call at a time with the same rules: the call has
3 minutes, the client follows no redirect (Go re-sends a header set by hand to the redirect's
host), an endpoint written with `/v1` on the end does not get a second one, and the provider's
words reach the failure on one line of at most 300 characters with the key cut out.

**Anthropic** (`go/internal/assistant/anthropic.go`) speaks the Messages API with `net/http`:
`POST {endpoint}/v1/messages` with `x-api-key` and `anthropic-version: 2023-06-01`, non-streaming,
the system prompt as one text block and the last tool definition each marked
`cache_control: {"type": "ephemeral"}`, because both are the same on every call of a
conversation and every call after the first reads them from the provider's cache. It is not
`anthropic-sdk-go`: the SDK's module graph brings the AWS and Google Cloud SDKs for its Bedrock
and Vertex clients, dozens of rows in `third_party/licenses` for one request shape and four error
outcomes. A 401 or 403 is `CREDENTIAL_REJECTED`; a 429, a 529, an `overloaded_error`, or a 400
`invalid_request_error` that mentions credit or billing is `PROVIDER_REFUSED`; anything else is
`PROVIDER_UNAVAILABLE`.

**OpenAI** (`go/internal/assistant/openai.go`) speaks the chat completions API, which OpenAI
serves and gateways and local model servers copy, with `net/http`: `POST {endpoint}/v1/chat/completions`
with `Authorization: Bearer <key>`, non-streaming, `tool_choice: "auto"`. The transcript is
converted on every call:

| the worker's form | chat completions |
|---|---|
| the system prompt | the first message, role `system` |
| a user message's `text` blocks | one `user` message, the texts joined |
| an assistant message | one `assistant` message: its text as `content` (`null` when it has none), each `tool_use` block as an entry of `tool_calls` (`{id, type: "function", function: {name, arguments}}`) in order |
| a `tool_result` block | a `tool` message with `tool_call_id` and `content`, before the user message's text so it follows the call it answers; `is_error` becomes the prefix `error: ` on the content, since the API has no flag for it |
| a tool definition | `{type: "function", function: {name, description, parameters}}`, the input schema as `parameters` |

Back the other way, the first choice's content is a `text` block (a refusal in the message's
`refusal` field too), and each entry of `tool_calls` is a `tool_use` block in the order given;
parallel calls run one at a time through the gate as any others. A call with no id (some local
servers send none) is given one, since its result must name it. `arguments` is a JSON string the
model writes, and it may not be JSON: such a call is kept in the transcript as a JSON string, sent
back as the model wrote it, and refused without running, the model told "the arguments are not a
JSON object". `finish_reason` maps onto the loop's stop reasons: `tool_calls` (or tool calls under
any reason, as some servers send `stop`) is `tool_use`, `stop` is `end_turn`, `length` is
`max_tokens`, and `content_filter`, or a `refusal`, is `refusal`. The usage is `prompt_tokens`,
`completion_tokens` and `prompt_tokens_details.cached_tokens`; since `prompt_tokens` counts the
cached tokens too, the input reported is `prompt_tokens` less the cached ones, so input and cache
read add up to what was sent as they do for Anthropic, and cache write is 0. The API caches a
repeated prefix by itself, so nothing is marked.

The response is bounded with `max_completion_tokens`, 16384 because a reasoning model counts its
hidden reasoning in it. An endpoint that takes only the older `max_tokens` refuses it with a 400
that names it; the call is made again with `max_tokens`, and the rest of the conversation sends
`max_tokens` from the start. Errors map as the speech engine's do: a 401 or 403 is
`CREDENTIAL_REJECTED`; a 429, any 5xx, an error whose type or code says `overloaded`, the code
`insufficient_quota`, or a 400 that mentions credit or billing is `PROVIDER_REFUSED`; anything
else, a redirect and a response with no choices included, is `PROVIDER_UNAVAILABLE`.

**Scripted** (`go/internal/assistant/scripted.go`) plays the file `LEY_ASSISTANT_SCRIPT` names,
whatever the provider: one JSON object a line, each one model response, played in order across
the whole conversation. Once the lines run out, every response is the text `done`. A worker that
resumes skips a line for each model response its transcript holds, so a conversation carried on
by a new worker plays on through the same script. When `LEY_ASSISTANT_RECORD` names a file, each
call appends the messages it was sent there as one JSON array a line, which is how a test reads
what context a call carried.

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
with the daemon's state after each, the speech decoder's alias included, on both the scripted model
and the OpenAI model; the offers of each row, a grant covering a later call on its row and not
another, several rows granted by one answer, a delete never granted, `AUTO` running every row,
and a grant surviving a resume (`grant_test.go`, `grant_worker_test.go`); undo, of a stopped
channel and of a volume; received text across turns and from a view tool; `WorkerStop` during a
slow response, a running tool and a wait; a response cut at `max_tokens`; the 32 KB cut; usage on
the ledger per response; view tools and the names left out; each model's request shape, error
mapping and the https rule against `httptest`, and for the OpenAI model the tool-result order, the
`max_completion_tokens` fallback, the default model, a provider with an endpoint and arguments
that are not an object; the transcript's round trip, a torn last line,
a call left without a result, a resumed worker's first call (on both models) and a missing file
(`transcript_test.go`); and the key on no stream but stdin, and not in the transcript.

A test runs the OpenAI model with `workerConfig.via = "openai"`: the harness starts a chat
completions endpoint that plays the same script lines (`openai_loop_test.go`), one per request,
and refuses a request the API would: the system prompt not first, or a tool call not answered by a
`tool` message, in order, before anything else.
`TestWorkerAssistantCommand` in `go/internal/cli/worker_test.go` runs the same protocol through
`ley worker assistant` itself.

The tests import `go/internal/cli` from the external test package, because the tool server lives
there and `cli` imports this package for the subcommand. A caller outside `cli` passes its own
`Options.NewToolServer`.
