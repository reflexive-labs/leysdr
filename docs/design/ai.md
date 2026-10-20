# Design: AI features on the user's own key

Status: draft. The design is settled, and the contract below is settled except the `Assistant`
service, which is settled when it is built. Nothing in this document is implemented yet;
`docs/plans/ai-features.md` holds the build order and its status. Companion to
[`decoders.md`](decoders.md) (the plugin contract speech reuses), [`recording.md`](recording.md)
(gated parts and overs), [`semantic-tier.md`](semantic-tier.md) (the state boundary and the MCP
surface), [`docs/reference/mcp.md`](../reference/mcp.md) (the tools the assistant reuses) and
[`SECURITY.md`](../../SECURITY.md) (what the daemon trusts).

## Context

An agent can already drive the radio: `ley mcp` serves the `ley` verbs as MCP tools to an agent
the user runs and configures outside Leyline. This design adds three features that put a model
inside Leyline, paid for on the user's own provider account:

1. **Keys and usage.** A place to add provider API keys, and a view of how much each feature used
   against them.
2. **Speech-to-text.** The words spoken on a recording or a live channel, as records tied to the
   over they came from.
3. **The assistant.** A conversation panel in the app, and `ley ask` in a terminal, that runs the
   radio and its configuration from plain requests such as "put on the weather radio" or "why
   can't I hear anything?".

Leyline runs no service of its own, so every model call goes from the user's Mac to a provider the
user chose, on the user's account, or to an engine on the Mac itself. With no key set and no
on-device engine chosen, Leyline behaves as it does without these features, and no screen other
than Settings, AI shows an AI control.

## Terms

| term | means | not |
|---|---|---|
| **provider** | a company or local engine that runs a model: Anthropic, OpenAI, Apple's on-device speech engine | "vendor", "backend" |
| **key** | the secret a provider issues for its API, or the credentials a cloud platform such as Amazon Bedrock takes; the contract calls it a credential | "token" (a token is what a model counts) |
| **the assistant** | Leyline's built-in agent, running on the user's key | "copilot", "the AI", "the bot" |
| **agent** | any MCP client driving `ley mcp`; the assistant is one | |
| **over** | one squelch opening: one station keyed up, from open to close | "utterance" |
| **speech record** | the words of one over as a speech decoder reports them: a `DecodeRecord` with protocol `speech` | "transcript" |
| **ledger** | the daemon's record of model usage: requests, tokens and audio seconds | "billing" |

In the contract and the other design docs a transcript is the activity log of a watch job:
squelch-open intervals, levels and coverage gaps (`jobs.proto`, `Transcript`; `semantic-tier.md`,
"Missing products"). It contains no words. Speech text is therefore a speech record, the verb that
makes one is `transcribe`, and no message or field named `transcript` gains a meaning that
involves speech.

## Keys live in the daemon

The daemon stores keys, and the contract can only write them. `SetCredential` takes a key;
`GetAIState` returns, for each key, the provider, a label, the last four characters, the endpoint,
and when the key was added, last used and last checked. No message carries the key itself. On
macOS a key is a login-keychain item created by `leylined`, so the daemon reads it without a prompt
and macOS asks the user before any other program reads it. Elsewhere, where the daemon runs for
development and CI, it is a file only the user can read.

The daemon holds keys, rather than the app, for three reasons. A kept speech job runs with no
client attached, so it needs the key while the app is closed. One usage view across the app, `ley`
and the jobs needs one place that sees every call. And `ley ai` and Settings must show the same
keys, which is invariant 7 applied to configuration.

The socket has no authentication (`SECURITY.md`, "What the daemon trusts"), so a key the contract
could return would be readable by any local process that opens it. With write-only keys, such a
process can make calls through Leyline's jobs, which appear in the ledger, but cannot copy a key.
A cap on spending belongs at the provider, in whatever terms it offers.

Adding a key runs one cheap call to the provider, and the result is stored with the key as
accepted, rejected or unavailable, with the provider's words. One provider has one key. A provider
is the name of a kind of endpoint (`anthropic`, `openai`, `deepgram`), with an optional endpoint
URL for a gateway or an OpenAI-compatible server. Removing a key will end every job that uses it,
with a line that names the key and the `ley ai add` command that adds another.

## Workers

The daemon makes no model call. Each feature's calls are made by a worker process the daemon
spawns, as it spawns decoder plugins: speech by a decoder plugin, and the assistant and the key
check by `ley`. This keeps provider SDKs, HTTP clients and prompts out of the process that carries
the hot path (invariant 4). It reuses the plugin lifecycle that restarts a crashed plugin and
records the gap, and it lets a provider be added or replaced without a daemon release. The same
reasoning keeps the MCP server out of the daemon.

The rules every worker follows:

- **The key arrives on stdin.** A command-line argument is visible in `ps`, and the environment is
  inherited by anything the worker runs. A `ley` worker reads the key as its first input. A
  decoder plugin whose manifest names a provider reads one varint-delimited
  `SetCredentialRequest` before the `StreamDescriptor`.
- **`ley` is found the way a decoder's executable is.** The daemon looks beside `leylined`, then
  on `PATH`; `--ley <path>` or `LEYLINE_LEY` overrides both, for tests. A missing `ley`, or a
  worker that prints no answer, is recorded as `UNAVAILABLE` in the key's last check and is never
  an error from the RPC.
- **The verbs are hidden**, under `ley worker`. `ley worker check --provider <name>` makes the
  check call and prints one JSON line, `{"outcome": "accepted" | "rejected" | "unavailable",
  "message": "…"}`; its exit status is 0 whenever it printed a line. For Anthropic and for an
  OpenAI-compatible endpoint the check is `GET /v1/models`: 200 is accepted, 401 rejected, and
  anything else unavailable. Other provider kinds, such as Bedrock and Vertex, define their own
  check when they are added. `ley worker assistant --conversation <id>` runs one conversation.
- **Usage is reported per response.** A `ley` worker calls `ReportUsage` over the socket like any
  client. A decoder plugin has no socket, so it puts the usage on the record it emits.

## Speech-to-text is a decoder

A speech decoder is a decoder plugin like APRS: audio in, records out. It emits one `DecodeRecord`
per segment with protocol `speech`, `time` at the segment's first sample, and `fields` holding
`text`, `language`, `model`, `callsigns`, and `confidence` when the provider reports one; `raw`
holds the provider's response bytes. Everything downstream already exists: the record store and
`ley://records/<job_id>`, `ley records`, `ley watch` predicates and notifiers, the MCP
`query_records` tool, and `keep`. An agent on `ley mcp` reads speech records with `query_records`
and needs no new tool.

**Segmented input.** In the `SEGMENTED` input mode the daemon cuts the channel's audio at squelch
transitions and hands the plugin one segment at a time: a `SEGMENT_START` frame, the segment's
audio, and an empty `SEGMENT_END` frame. A segment starts `pre_roll_ms` before the squelch opened
and ends `hang_ms` after it closed, both 500 ms by default. A squelch that reopens inside the hang
continues the same segment, so a segment holds several overs, several entries of the part's
`squelch_opens`, when they are closer together than the hang. Speech engines work on a whole
utterance, and the daemon already knows to the sample where each over starts and ends
(`SquelchTransition`; `recording.md`, "The daemon"). Audio while the squelch is shut is never sent
or billed. One record per segment gives, in the usual case, one speaker per record and one
notification per over; a plugin that wants more context can hold segments back itself.

The segmenter's default hang is shorter than the gated recorder's 5 s. A recording part is one
exchange and lists every over in it (`recording.md`, "What a recording is"); a segment is one over,
or several overs that follow each other inside the 500 ms hang.

**A recording as a source.** `DecodeConfig.source_uri` names a recording
(`ley://recordings/<id>`), and the job reads its stored audio parts as fast as the plugin accepts
them, with no capture, channel or lease. Segments come from each part sidecar's `squelch_opens`,
cut with the same pre-roll and hang as a live job, so a recording transcribed later gives the same
segments as the live job that recorded it.
Every decoder gains reprocessing of stored audio, which `decoders.md` anticipates when it requires
`raw`, and a recording from yesterday transcribes faster than real time. IQ recordings need an
offline demodulation path first and come later.

**A credential requirement.** A manifest names the provider whose key the plugin needs
(`credential_provider`) and the hosts it contacts (`contacts_hosts`). The daemon refuses to start
the job without that key (`CREDENTIAL_MISSING`), and `ley decoders` and Settings list the hosts.

**Speech text keeps its audio.** A live speech job also writes a gated recording, and each speech
record names its part (`clip_uri`) and its first over (`over`): the 1-based index, in the part's
`squelch_opens`, of the segment's first entry. Speech text
without its audio can be neither checked by ear nor redone with a better model, and the clip is the
audio that `raw` would otherwise have to carry. Records are immutable, so transcribing again with
another model adds records beside the earlier ones, and a client shows the newest by default.

**Callsigns are a pattern match.** A spoken callsign ("whiskey six alpha bravo charlie") appears
in `callsigns` as `W6ABC`, found by a pattern over the text after the phonetic alphabet is
normalised. The field is labelled as a pattern match, because it holds what a pattern matched in
the model's text.

The first-party plugins will be one that calls a cloud speech API on the user's key and one that
runs on the Mac; third parties can ship others. Before a batch of
recordings is transcribed, `ley transcribe` and the app state how many minutes of squelch-open
audio will go to which provider, and start only on confirmation. The minutes come from
`squelch_open_ms`, which each part in `recording.json` will carry, written at part close; for a
recording made before that field existed, `ley transcribe` sums the part sidecars.

## The assistant

The assistant's loop runs in Go, in a `ley` worker the daemon starts for each conversation with the
provider's key on stdin. Its tools are the `ley mcp` tools, called in-process from one registry
that both `ley mcp` and the worker build, so the assistant uses the tool surface the evals grade,
and every guard the adapter has (the don't-disturb refusal, `take_over`) applies unchanged. Its
writes reach the daemon over the socket like any client's, with client kind `mcp` and label
`assistant`, so `caused_by` attributes every change it makes to it, as for any client. It adds no
client kind, so the don't-disturb rule counts its writes as interactive, which matches a person
asking.

The conversation is daemon state, behind an `Assistant` service: start, send a message, watch,
approve or refuse a pending action, cancel, list, delete. The app's panel and `ley ask` render the same
subscription, so `ley ask --continue` continues a conversation started in the app, and a
conversation outlives the window it started in. Each event carries the whole conversation so far
(invariant 6), so a client that reconnects reads it and resumes from its `seq`.

A conversation is kept, because the user started it and comes back to it (invariant 8): the
daemon writes it to its data directory, so it survives a restart, and `ley ask --continue` and the
app find it afterwards. It ends only when the user ends it, and an ended conversation stays
readable until the user deletes it; the daemon keeps the newest 100 and drops any unused for 90
days. After 30 idle minutes the daemon stops the worker behind a conversation, not the
conversation, and the next message starts a worker that reloads the model transcript the last one
kept beside it, so the model has the same context. A daemon that stops mid-turn leaves that turn
to be closed with a note when it starts again, and the call it was waiting on is refused. What a
conversation used stays in the ledger under its id. It is not tied to the presence of the client
that started it, because `ley ask` exits between turns and `ley ask --continue` must find the
conversation again. A worker that crashes mid-turn fails its own conversation with `INTERNAL` and
leaves the others running.

A client attached to a conversation may declare view tools that it performs itself, such as moving
the app's waterfall to a band or selecting a recording in the Library. The worker offers them to
the model for that conversation, and the daemon routes each call to the client that declared it.
`ley ask` declares none. View state stays in the client, and retuning the radio goes only through
the radio tools and their don't-disturb check.

The tools the assistant needs and `ley mcp` lacks are written as MCP tools first, each with its
`ley` mirror, so every agent gains them: `set` on an existing channel, `stop`, bookmarks, bands
and presets, `watch`, `devices attach`, CHIRP import, and the `ley help` topics, read-only, so an
explanation uses Leyline's own words. The assistant reports each change as `ley tune`'s banner
does, and reads the state before each write so it can undo it. It answers from detections and the
band plan, and never reports a modulation the detector did not (invariant 12).

## Usage

Each worker reports the usage its provider returned with every response: input, output,
cache-read and cache-write tokens for a language model, audio seconds for speech, and one request
per response. The daemon adds each report to the ledger under the provider, model, feature, and job
or conversation, and sets `last_used_at_ns` on that provider's key. The ledger is control-plane
state with full-state events, so the app's usage view is a subscription like any other, and
`ley ai usage --json` prints it as the standard proto3 JSON mapping.

The ledger counts UTC days, as the providers' consoles do, so the two can be compared. Leyline
shows usage and never a price: the same model costs different amounts directly, through Amazon
Bedrock or Google Vertex AI, through a third-party gateway, or under a negotiated contract, and a
bundled price table would be wrong for most of those. Cost and spend limits stay in the provider's
console. The numbers are what the workers report, so a third-party plugin can under-report, and
`ley ai usage` says so in its header.

When a provider refuses a request for its own reason, such as a rate or spend limit, the job or
conversation shows the provider's message (`PROVIDER_REFUSED`). A kept speech job goes `DEGRADED`
and retries with the decoder's backoff; an unkept one ends with the error.

## The contract

Every item is additive within v1. `ai.proto` is a new file with two services, `Credentials` and
`Usage`. A third, `Assistant`, is settled when it is built, because its shape depends on what the
worker needs. The two settled services:

```proto
message Credential {                 // never carries the secret
  string provider = 1;
  string label = 2;
  string last_four = 3;
  string endpoint = 4;               // empty = the provider's own API
  int64 added_at_ns = 5;
  int64 last_used_at_ns = 6;         // a worker took the key for a call
  CredentialCheck last_check = 7;
}
message CredentialCheck {
  enum Outcome { OUTCOME_UNSPECIFIED = 0; ACCEPTED = 1; REJECTED = 2; UNAVAILABLE = 3; }
  Outcome outcome = 1;
  string message = 2;                // the provider's words, or why the check could not run
  int64 at_ns = 3;
}
message SetCredentialRequest { string provider = 1; string secret = 2; string label = 3; string endpoint = 4; }
message CredentialRef { string provider = 1; }
message FeatureModel { string feature = 1; string provider = 2; string model = 3; } // feature: "assistant" | "speech"
message AIState { repeated Credential credentials = 1; repeated FeatureModel features = 2; }
message GetAIStateRequest {}

service Credentials {
  rpc SetCredential(SetCredentialRequest) returns (Credential);   // stores, then checks once
  rpc DeleteCredential(CredentialRef) returns (Empty);            // ends every job using it
  rpc CheckCredential(CredentialRef) returns (Credential);
  rpc GetAIState(GetAIStateRequest) returns (AIState);
  rpc SetFeatureModel(FeatureModel) returns (FeatureModel);
}

message UsageReport {                // one per provider response, in the provider's units
  string provider = 1;
  string model = 2;
  string feature = 3;                // "assistant" | "speech" | "check"
  string job_id = 4;                 // one of these two names the scope
  string conversation_id = 5;
  uint64 requests = 6;
  uint64 input_tokens = 7;
  uint64 output_tokens = 8;
  uint64 cache_read_tokens = 9;
  uint64 cache_write_tokens = 10;
  double audio_seconds = 11;
  int64 at_ns = 12;
}
message UsageLine {                  // the ledger's grain: provider, model, feature, scope, UTC day
  string provider = 1;
  string model = 2;
  string feature = 3;
  string scope_id = 4;               // the job or conversation id
  string day = 5;                    // "2026-10-14", UTC, as the providers' consoles count
  uint64 requests = 6;
  uint64 input_tokens = 7;
  uint64 output_tokens = 8;
  uint64 cache_read_tokens = 9;
  uint64 cache_write_tokens = 10;
  double audio_seconds = 11;
  int64 last_at_ns = 12;
}
message GetUsageRequest { int64 since_ns = 1; string provider = 2; string feature = 3; string scope_id = 4; }
message GetUsageResponse { repeated UsageLine lines = 1; }

service Usage {
  rpc GetUsage(GetUsageRequest) returns (GetUsageResponse);
  rpc ReportUsage(UsageReport) returns (Empty);                   // workers call this
}
```

`ReportUsage` is a plain RPC, so any socket client can add to the ledger, as any socket client can
already start a paid job; `SECURITY.md` states both.

Additions to existing files:

| file | addition | number |
|---|---|---|
| `control.proto` `Event.body` | `AIState ai` (the whole list, so a delete is a smaller list, not a tombstone) | 11 |
| `control.proto` `Event.body` | `UsageLine usage` (the whole line after each report) | 12 |
| `control.proto` `GetStateResponse` | `AIState ai` | 9 |
| `control.proto` `GetStateResponse` | `repeated UsageLine usage` | 10 |
| `decode.proto` `InputMode` | `SEGMENTED` | 3 |
| `decode.proto` `DecoderInput` | `uint32 pre_roll_ms`, `uint32 hang_ms` (SEGMENTED only; 0 = 500 and 500) | 6, 7 |
| `decode.proto` `DecoderManifest` | `string credential_provider` (empty = none needed) | 17 |
| `decode.proto` `DecoderManifest` | `repeated string contacts_hosts` | 18 |
| `decode.proto` `DecodeConfig` | `string source_uri` (`ley://recordings/<id>`: read the stored parts instead of a radio) | 8 |
| `decode.proto` `DecodeRecord` | `UsageReport usage` (set by the plugin; the daemon fills `feature` and `job_id` and adds it to the ledger) | 15 |
| `decode.proto` `DecodeRecord` | `string clip_uri` (the part that holds this record's audio, `ley://recordings/<id>/<part>`) | 16 |
| `decode.proto` `DecodeRecord` | `uint32 over` (1-based within the part; 0 = not segmented) | 17 |
| `bulk.proto` `Frame` | `SegmentMark segment`: `SEGMENT_MARK_UNSPECIFIED`, `SEGMENT_START`, `SEGMENT_END`; the END frame carries an empty payload | 6 |

Usage from a decoder travels on its records, so the plugin framing does not change for the
decoders that exist. Playing one over from the Library needs `StartPlaybackRequest` to take a
sample range, which is a separate addition.

Four error codes join the "Error codes" table in `docs/dev/engine-internals.md`:

| code | gRPC status | raised when |
|---|---|---|
| `CREDENTIAL_MISSING` | `FAILED_PRECONDITION` | the feature or decoder needs a provider's key and none is set; the message names `ley ai add <provider>` |
| `CREDENTIAL_REJECTED` | `FAILED_PRECONDITION` | the provider refused the key itself |
| `PROVIDER_UNAVAILABLE` | `UNAVAILABLE` | the provider or the worker could not be reached |
| `PROVIDER_REFUSED` | `FAILED_PRECONDITION` | the provider refused a request for its own reason, with the provider's message |

`PROVIDER_REFUSED` is `FAILED_PRECONDITION` rather than `RESOURCE_EXHAUSTED` so that no default
gRPC retry policy repeats the request against the user's account.

Every RPC has a `ley` mirror, and the fake implements each one for `ley`'s tests:

```sh
ley ai                              # providers: label, last four characters, last used and checked
ley ai add anthropic [--label L] [--endpoint URL]   # reads the key from stdin and checks it
ley ai check anthropic
ley ai remove anthropic
ley ai use assistant anthropic claude-sonnet-5-5    # the provider and model a feature uses
ley ai usage [--since 30d] [--by day|month] [--json]
ley transcribe <recording> [--yes]
ley decode speech --freq 146.94 [--job]
ley ask "<request>" [--continue]
```

`ley ai add` reads the key from stdin so that it stays out of the shell history and `ps`. The app's
Settings shows a key added this way at once, because the daemon holds it.

## Where things are stored

`<data>` is the daemon's data directory, `~/Library/Application Support/Leyline` on macOS and
`$XDG_DATA_HOME/leyline` elsewhere; `<store>` is the record store (`decoders.md`, "Decisions").

| what | where |
|---|---|
| keys, on macOS | a login-keychain item per provider, service `com.leysdr.leyline`, account the provider's name, created by `leylined` |
| keys, elsewhere | `<data>/credentials.json`, mode 0600, written atomically |
| what `Credential` and `FeatureModel` carry | `<data>/ai.json` on both platforms, so a listing never opens the keychain |
| the ledger | `<store>/usage.jsonl`, one `UsageReport` per line |

The ledger file is appended as reports arrive and folded into lines when the daemon starts, which
also drops lines older than 400 days.

## What the assistant may do

Leyline only receives, so what an assistant can do wrong is bounded: retune or take over a radio,
delete recordings, fill the disk, make calls on the user's provider account and fire notifiers.
The worker applies this policy as a gate before each tool call. An "asks" row becomes a pending
action the daemon holds until a client approves or refuses it.

| action | policy |
|---|---|
| read state, devices, decoders, records, recordings, jobs, help topics | runs |
| tune, set, stop, scan, record, or start an unkept decode job, as the user asked | runs, and is reported |
| take over a radio another client or channel is using | asks, naming what stops |
| start a kept job, add a webhook notifier, add or remove several bookmarks | asks, showing what will be written |
| delete a recording | asks every time |
| start paid transcription | asks, stating how much audio it will send |
| run a shell command, add a shell notifier, change keys | not among the assistant's tools |

The take-over row is the don't-disturb refusal `ley mcp` already returns, put to the user as a
question. Each step of a conversation shows the tool the assistant called and its result, and the
user can stop it mid-task.

A question can be answered once or for the rest of the conversation. Answered for the conversation,
it grants each row it listed, and a later call on a granted row runs without asking and is reported
with the call id of the question that granted it (`ToolCall.allowed_by`), so a reader of the
conversation sees why it did not ask. A grant is kept by row, not by tool: one answer to a take-over
by `tune` covers a take-over by `scan` or `record`. The worker keeps grants with its transcript, so
they hold across `ley ask --continue` and a daemon restart. Each question carries the scopes it
accepts (`PendingAction.offers`), and a client shows only those: deleting a recording offers once
alone, because a delete cannot be undone, and so does cancelling a job the assistant did not start,
because a grant would cover every other client's job while the question named one; every other row,
and the received-text rule below, offers both, since otherwise a conversation that read one APRS
page would ask again before every write. Only an answer to a question grants anything: a user who
writes "you can drive the radio" has granted nothing, because the gate reads `ResolveAction` and
never the user's words.

A conversation also has a mode, set when it starts (`StartConversationRequest.mode`) and changed
by any client with `SetApprovalMode`, which the daemon keeps across a restart. In `ASK`, the
default, the table and the grants decide. In `AUTO` every row runs and is reported with the
reason it would have asked with, so the conversation never waits; a question pending when the
mode becomes `AUTO` is approved once and runs. `ley ask --yes` puts the conversation it starts or
continues in `AUTO`, for scripts and agents that cannot answer, and the model's prompt says
nothing waits. The rows outside the tool list (a shell command, a shell
notifier, the keys) stay outside in every mode. The policy, the mode's effect and the grants live
in the worker's gate alone: the daemon passes the mode, the offers and the answer through, and a
client renders a question and sends one answer.

### Received text is untrusted input

Anyone with a transmitter can put words into an APRS comment, an AIS field or a speech record, and
the assistant reads all three. The worker passes record content to the model as quoted data and
never as instructions. An action proposed in a turn that read received text needs confirmation,
even where the policy table says it runs. The shell notifier, which would turn such text into a
command on the Mac, is not one of the assistant's tools. Eval scenarios in which a fixture's decoded
text asks the agent to act will check this for the assistant and for any agent on `ley mcp`.

## Privacy and the law

Sending audio to a cloud speech API passes the content of a transmission to that provider. Some
places restrict divulging what was received (the README's "Receive only" section; `decoders.md`,
"Constraints and boundaries"). Settings, AI states, for each provider, which feature sends what to
which host, before the user chooses it. A feature set to a cloud provider says so on the screen
where it runs. On-device speech exists so that a user who must not send audio off the Mac can
still transcribe.

The assistant sends its provider the conversation and the tool results, which include frequencies,
decoded records and speech text, and Settings states that too.

## Providers

A provider is a kind (Anthropic, Bedrock, Vertex, OpenAI-compatible, a speech API) plus an optional
endpoint, and the key is whatever that kind takes. The candidates, with no default chosen yet:

| feature | provider | notes |
|---|---|---|
| assistant | Anthropic (Claude) | the Messages API with tool use and prompt caching; the tool definitions and system prompt are the same on every turn, so later turns read them from the cache |
| assistant | Claude through Amazon Bedrock or Google Vertex AI | the same model behind another endpoint and credential; not built |
| assistant | OpenAI, or any OpenAI-compatible endpoint (a gateway, a local model server) | the chat completions API with tools; the API caches a repeated prefix by itself; whether a local model passes the evals is unmeasured |
| speech | Apple's on-device speech engine (`SpeechAnalyzer`, macOS 26) | no key, no cost, no audio leaves the Mac; accuracy on NFM receiver audio unmeasured |
| speech | whisper.cpp | MIT, runs on the Mac; speed against model size on the target Macs unmeasured |
| speech | a cloud speech-to-text API (OpenAI, Deepgram, AssemblyAI and others) | billed by audio duration; most take a vocabulary or prompt hint, where callsigns and the phonetic alphabet go |

The assistant runs on Anthropic or on any OpenAI-compatible endpoint: the provider `anthropic`
calls the Messages API, and `openai`, or any other provider whose key names an endpoint, calls
chat completions ([`docs/dev/assistant.md`](../dev/assistant.md), "The model"). So one OpenAI key can serve both
features, the assistant and cloud speech. Anthropic's API has no speech-to-text endpoint, so a
user whose assistant runs on Anthropic and who wants cloud speech adds a second provider. The
default speech engine will be chosen by measuring each candidate on real receiver
audio (NOAA Weather Radio, airband ATIS, a 2 m net) for word error rate, callsign recall, cost per
hour of squelch-open audio and the delay from squelch close to text. The default assistant model
will be chosen by running the evals with the assistant as the agent, on pass rate and tokens per
completed scenario. How many tokens one conversation takes is unmeasured.

## How the invariants hold

| invariant | how this design keeps it |
|---|---|
| 1, one protocol | keys, usage, conversations and view-tool calls travel on leyline.v1; workers are children of the daemon on stdio, as decoder plugins are |
| 2, daemon-side DSP | the daemon cuts overs at squelch transitions; workers receive audio and return text |
| 4, allocation-free hot path | the segmenter reuses the gated recorder's path; no model call, HTTP request or prompt runs in the daemon's process |
| 5, sample timebase | speech records carry `SampleTime`; wall clock comes from the anchor, as for every record |
| 6, full state | ledger and conversation events carry the whole object |
| 7, state in the daemon | keys, the ledger and conversations are daemon state; view state stays in the client |
| 8, persistence follows intent | a conversation the user started is kept until the user deletes it, and its worker stops when idle; an unkept speech job ends with its client; `keep` persists speech records and their clips |
| 9, `CaptureAllocator` | speech jobs are decode jobs and allocate through it |
| 11, TX | there are no TX tools, as in `ley mcp` |
| 12, no overclaiming | speech text is labelled as model output with its confidence; the assistant cites detections and the band plan, and states what the detector cannot tell |

Invariants 3, 10 and 13 are not affected.

## Deliberately not

- **An assistant inside the app only.** A Swift loop would be a feature that works only from
  Swift, a second tool surface beside the one the evals grade, and a conversation lost when the
  window closes.
- **Model calls from the daemon's process.** Provider SDKs and HTTP clients stay out of the process
  that carries the hot path, and a provider change needs no daemon release.
- **A key the contract returns.** Anything that opens the socket could copy it.
- **Prices, cost estimates and budgets.** Prices differ by provider, platform and contract, so a
  bundled table would be wrong for many users, and a budget enforced on wrong prices would stop
  work at the wrong point.
- **A Leyline account or relay service.** Every call goes from the user's Mac to the provider the
  user chose.
- **Speech text without its audio.** A live speech job keeps the clips it transcribed.
- **The assistant's answer as a measurement.** Detections, levels and records come from the
  daemon; the assistant cites them (`semantic-tier.md`, "State boundary").
- **Digital voice.** Speech from DMR, D-STAR or C4FM needs the vocoder `decoders.md` excludes, and
  speech-to-text does not change that.
- **An unattended agent job.** The assistant acts on a person's requests: a kept conversation
  waits for the next one, and nothing runs it without a person asking.

## Open questions

- **Who owns a channel the assistant makes.** A channel belongs to the client that created it and
  ends 5 s after that client's presence does (`docs/dev/engine-internals.md`, "Client identity and
  ownership"), so "put on the weather radio" would go silent when the conversation ends. Leaning:
  in the app the assistant retunes the app's own channel; from `ley ask` it makes the channel
  persistent and says how to stop it. The `Assistant` service settles this when it is built.
- **The keychain from an SSH session.** Whether a daemon started by hand outside the login session
  can read its keychain item. Until a test on a Mac answers it, the daemon reports
  `CREDENTIAL_MISSING` with the keychain's message.
- **The speech engine's vocabulary hint.** Whether it should come from the band (callsigns and the
  phonetic alphabet on amateur bands, ATC phraseology on airband) and from the user's bookmarks and
  labels, and how much that changes the measured accuracy.
