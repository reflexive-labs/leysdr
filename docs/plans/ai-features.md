# Plan: AI features on the user's own key

Status: partial. The recommendations in "The shape" were accepted for the build on 2026-10-14;
"Decisions taken for the build" settles the open questions that blocked it, "What the contract
gains" is the settled contract, and the build items carry the status. AI-1 writes
`docs/design/ai.md` from them. Companion to
[`semantic-tier.md`](../design/semantic-tier.md) (transcripts and the MCP surface),
[`decoders.md`](../design/decoders.md) (the plugin contract this plan reuses for speech),
[`recording.md`](../design/recording.md) (gated parts and overs), [`mcp.md`](mcp.md) (the tool
surface the assistant reuses) and [`SECURITY.md`](../../SECURITY.md) (what the daemon trusts).

## Context

Leyline already lets an agent drive the radio: `ley mcp` serves the `ley` verbs as MCP tools, and
the scenarios in `evals/scenarios/` grade how an agent uses them. That agent is one the user runs
and configures outside Leyline (Claude Code, Claude Desktop, Cursor). This plan scopes three
features that put a model inside Leyline, paid for on the user's own provider account:

1. **Keys and usage.** A place to add provider API keys, and a view of how much each feature
   used against them.
2. **Speech-to-text.** The words spoken on a recording or a live channel, as records tied to the
   over they came from.
3. **The assistant.** A conversation panel in the app, and `ley ask` in a terminal, that runs the
   radio and its configuration from plain requests ("put on the weather radio", "why can't I hear
   anything?").

Leyline runs no service of its own, so every model call goes from the user's Mac to a provider
they chose, on their account, or to an engine on the Mac itself. With no key set and no on-device
engine chosen, Leyline behaves exactly as it does today.

## Words

This plan uses these terms; AI-1 moves the ones that survive into the writing guide's table.

| term | means | not |
|---|---|---|
| **provider** | a company or local engine that runs a model: Anthropic, OpenAI, Apple's on-device speech engine | "vendor", "backend" |
| **key** | the secret a provider issues for its API, or the credentials a cloud platform such as Amazon Bedrock takes; the contract calls it a credential | "token" (a token is what a model counts) |
| **the assistant** | Leyline's built-in agent, running on the user's key | "copilot", "the AI", "the bot" |
| **agent** | any MCP client driving `ley mcp`; the assistant is one | |
| **over** | one squelch opening: one station keyed up, from open to close | "utterance" |
| **speech record** | the words of one over as a speech decoder reports them: a `DecodeRecord` with protocol `speech` | "transcript" |
| **ledger** | the daemon's record of model usage: requests, tokens and audio seconds | "billing" |

**"Transcript" is taken.** In the contract and the design docs a transcript is the activity log
of a watch job: squelch-open intervals, levels and coverage gaps (`jobs.proto`, `Transcript`;
`semantic-tier.md`, "Missing products"). It contains no words. Speech text is therefore a speech
record, the verb that makes one is `transcribe`, and no message or field named `transcript` gains
a meaning that involves speech.

## User stories

Acceptance-level and not exhaustive, in the shape of [`user-stories.md`](user-stories.md), with
its personas: an operator (anyone at the radio), a newcomer, a ham, an agent user. Each story is a
candidate until AI-1 accepts it. The ids are for cross-reference in this plan only.

### Keys

- **K1.** As an operator with no key, I see nothing in Leyline that fails for want of one.
  Settings, AI states what each feature does, what it sends to which host, and which key enables
  it. No other screen shows an AI control until a key or an on-device engine is set.
- **K2.** As an operator, I can paste a key for a provider into Settings, AI. Leyline checks it
  with one cheap call and states whether the provider accepted it. From then on it shows only the
  provider, a label, the key's last four characters and when it was last used.
- **K3.** As an operator, I can add the same key from a terminal with `ley ai add anthropic`,
  which reads it from stdin so it stays out of the shell history and `ps`. The app's Settings
  shows it at once, because the daemon holds it.
- **K4.** As an operator, I can choose which provider and model each feature uses. Before I
  choose, I can read what each choice sends off the Mac and to which host.
- **K5.** As an operator, I can remove a key. Every job that was using it stops with a line
  naming the key and the command that adds another.

### Usage

- **U1.** As an operator, I can see usage per provider, model and feature, by day and by month:
  requests and tokens for the assistant, requests and audio minutes for speech. Leyline shows
  usage and no prices; the provider's console shows what it cost.
- **U2.** As an operator, I can see what one conversation or one transcription job used, on the
  conversation and on the job, while it runs.
- **U3.** As an operator, before I transcribe a batch of recordings, Leyline states how many
  minutes of squelch-open audio it will send and to which provider, and starts only when I
  confirm.
- **U4.** As an operator, when a provider refuses a request because of its own rate limit or spend
  limit, the job or conversation states the provider's reason, and a kept speech job goes
  `DEGRADED` and retries with backoff rather than ending.
- **U5.** As an operator, `ley ai usage --json` prints the ledger as the standard proto3 JSON
  mapping, for my own accounting.

### Speech-to-text

- **T1.** As an operator, I can select a gated recording in the Library and choose Transcribe.
  Each over in each part gets its words under it with the name of the model that produced them,
  and clicking the words plays that over.
- **T2.** As an operator, I can search my recordings by what was said ("road closed"), and the
  Library selects the part and the over.
- **T3.** As an operator, I can turn on speech for the channel I am listening to. The words of
  each over appear in the transmissions log a few seconds after the squelch closes.
- **T4.** As a ham, I can run `ley decode speech --freq 146.94 --job` to transcribe a repeater all
  day, and read it later with `ley records --protocol speech --since 12h`.
- **T5.** As a ham, `ley watch speech --freq 146.52 --where 'text~net control' --notify --detach`
  shows a macOS notification when someone says "net control", with no client attached. This is
  the existing predicate and notifier path over a new decoder.
- **T6.** As a ham, a callsign spoken phonetically ("whiskey six alpha bravo charlie") appears in
  the record's `callsigns` field as `W6ABC`. It is found by a pattern over the normalised text,
  and the field is labelled as a pattern match.
- **T7.** As an operator, I can choose on-device transcription so that no audio leaves the Mac,
  at whatever accuracy AI-0 measures for it.
- **T8.** As an operator, speech text is shown as what the model heard, with its confidence where
  the provider reports one, and the audio is one click away. I check a doubtful word by
  listening to it.
- **T9.** As an operator, I can transcribe a recording again with a different model. The earlier
  records stay, because records are immutable, and the Library shows the newest by default.
- **T10.** As an operator, a recording from yesterday transcribes faster than real time. Leyline
  reads the stored audio directly rather than playing it back through a channel at 1x.
- **T11.** As an agent user, an agent on `ley mcp` reads speech records with `query_records`
  (`protocol: speech`) and can summarise last night's net from them, with no new tool.
- **T12.** As an operator, I can export a recording's speech records as plain text or as SRT
  subtitles whose times come from the capture's anchor.

### The assistant: running the radio

- **A1.** As a newcomer, I can type "put on the weather radio". The assistant tunes the `noaa`
  preset and reports what it chose and why (frequency, mode, squelch) the way `ley tune`'s banner
  does.
- **A2.** As an operator listening to a weak station, I can say "the squelch keeps chopping".
  The assistant lowers the squelch on that channel by a few dB and reports the old and new
  values, and "undo that" puts the old value back.
- **A3.** As an operator, "what's active on 2 m?" runs a scan and answers from the detections:
  frequency, width, SNR, how often seen. The assistant names a carrier's likely use only from the
  band plan and says that is where it came from; it never reports a modulation the detector did
  not (invariant 12).
- **A4.** As an operator, "scan airband and bookmark what's busy" scans, proposes bookmarks named
  from the band's channel plan, and adds the ones I tick.
- **A5.** As an operator, "record 146.94 for two hours, only when someone's talking" starts a
  gated record job and tells me where the recording will appear.
- **A6.** As an operator, if a request would retune a radio another channel or client is using,
  the assistant names what would be interrupted and asks before taking over. This is the
  don't-disturb refusal `ley mcp` already returns, put to me as a question.

### The assistant: configuration

- **A7.** As a ham, "add my club's repeater, W6XYZ on 147.165, PL 100" creates an NFM bookmark on
  147.165 MHz with a 100.0 Hz tone, named for the club, with the callsign in its note.
- **A8.** As an operator, "tell me if there's a tornado warning for Tuolumne County" resolves the
  county to its FIPS code, 06109, shows the code for me to check, and after I confirm starts
  `ley watch same --county 06109 --notify --detach`.
- **A9.** As an operator, "use the rtl_tcp server on my Pi" attaches `pi.local:1234`, and asks for
  the host or port when they are not the defaults.
- **A10.** As an operator, "set up APRS and show me who's around" starts the APRS decoder and lists
  the stations from the `aprs` fold.

### The assistant: explaining and diagnosing

- **A11.** As a newcomer, "why can't I hear anything?" makes the assistant check what Leyline can
  measure: no radio, a gain of 0 dB, a squelch above the signal, a flat noise floor that suggests
  no antenna, errors in the daemon's log. It reports what it found and the fix, with the `ley`
  command that applies it.
- **A12.** As a newcomer, "what's CTCSS?" or "what am I looking at on the waterfall?" is answered
  from the `ley help` topics, so the words match Leyline's.
- **A13.** As an operator, "what's this at 433.92?" gets the measured facts (width, burst timing,
  SNR), the installed decoders that cover the frequency, and a plain statement that Leyline's
  detector does not identify protocols.

### The assistant: where it runs and what it may do

- **A14.** As an operator, `ley ask "tune to the calling frequency"` runs the same assistant in a
  terminal, and `ley ask --continue` continues the conversation I started in the app.
- **A15.** As an operator, every change the assistant makes appears in the app and in `ley`
  attributed to it, as any other client's change is ("the assistant set the squelch to
  -45 dBFS").
- **A16.** As an operator, I can expand each step to see the tool the assistant called and its
  result, and I can stop it mid-task.
- **A17.** As an operator, the assistant asks before it deletes a recording, adds a webhook
  notifier, starts a kept job, takes over a radio or starts paid transcription. It has no way to
  run a shell command or create a shell notifier.
- **A18.** As an operator, text that arrived over the air (an APRS comment, a speech record, an
  AIS destination) cannot instruct the assistant. It reaches the model marked as received data,
  and anything the assistant proposes after reading it needs my confirmation.
- **A19.** As an app user, "show me airband" moves the waterfall's view to 118.000 MHz to
  137.000 MHz, which the app does itself, and retunes the capture only through the radio tools
  and their don't-disturb check.

### Later candidates

Not scoped further here; each depends on something this plan does not build.

- "Watch 146.52 tonight and summarise it in the morning": a scheduled summary over speech
  records. Needs the durable job store and a scheduler (`build-order.md`, D.15).
- "What happened on the repeater last night?": a summary of a time range of speech records, each
  statement linked to the over it came from.
- Translation of speech records in another language, for marine and HF traffic.
- "Which vessels passed after midnight heading north?": a question turned into `query_records`
  predicates and the client-side folds.
- Help identifying a signal from a spectrum image and its measurements, once `identify_signal`
  (MCP-8) defines what may be claimed.
- The V2 dashboard composed on request (`user-stories.md`).

## The shape

Six recommendations. AI-1 turns the accepted ones into the design doc; each is open until then.

### Keys live in the daemon and never leave it

The daemon stores keys, and the contract can only write them. `SetCredential` takes a key;
`GetAIState` returns the provider, a label, the last four characters, and when the key was
added, last used and last checked, and never the key itself. On macOS a key is a login-keychain
item created by `leylined`, so the daemon reads it without a prompt and macOS asks the user before
any other program reads it. On Linux, where the daemon runs for development and CI, it is a file
only the user can read.

The daemon holds keys, rather than the app, for three reasons. A kept speech job runs with no
client attached, so it needs the key without the app open. One usage view across the app, `ley`
and the jobs needs one place that sees every call. And `ley ai` and Settings must show the same
keys, which is invariant 7 applied to configuration.

A key the contract could return would be readable by anything that opens the socket, which has no
authentication (`SECURITY.md`, "What the daemon trusts"). With write-only keys, a local process
can make calls through Leyline's jobs, which appear in the ledger, but cannot copy a key. A cap on
spending belongs at the provider, in whatever terms it offers.

### Paid work runs in worker processes the daemon starts

The Swift daemon makes no model call. Each feature's calls are made by an out-of-process worker
that the daemon spawns, as it spawns decoder plugins today: speech by a decoder plugin, the
assistant by a `ley` worker. The daemon passes the worker the key it needs at spawn and adds what
the worker reports it used to the ledger.

This keeps provider SDKs, HTTP clients and prompts out of the process that carries the hot path
(invariant 4). It reuses the plugin lifecycle that already restarts a crashed plugin and records
the gap. And it lets a provider be added or replaced without a daemon release. It follows the same
reasoning that kept MCP out of the daemon (`mcp.md`, "Where the server lives").

### Speech-to-text is a decoder

A speech decoder is a decoder plugin like APRS: audio in, records out. It emits one `DecodeRecord`
per over with protocol `speech`, `time` at the over's first sample, `fields` holding `text`,
`language`, `model`, `callsigns` and `confidence` when the provider reports one, and `raw` holding
the provider's response bytes. Everything downstream exists already: the record store and
`ley://records/<job_id>`, `ley records`, `ley watch` predicates and notifiers, the MCP
`query_records` tool, and `keep`.

Three contract additions make it work:

1. **A segmented input mode.** `DecoderManifest` already has an input mode, continuous or
   slot-aligned (reserved for FT8). In a `segmented` mode the daemon cuts the channel's audio at
   squelch transitions, with the gated recorder's pre-roll and hang, and hands the plugin one over
   at a time followed by an end-of-segment marker. Speech engines work on a whole utterance, the
   daemon already knows to the sample where each over starts and ends (`SquelchTransition`;
   `recording.md`), and audio while the squelch is shut is never sent or billed.
2. **A recording as a source.** `DecodeConfig` gains a source that names a recording, so a decode
   job reads the stored parts of an audio recording as fast as the plugin accepts them. Every
   decoder gains reprocessing of stored audio, which `decoders.md` anticipates when it requires
   `raw`. IQ recordings need an offline demodulation path first, and come later.
3. **A credential requirement.** The manifest names the provider whose key the plugin needs and
   the hosts it contacts. The daemon refuses to start the job without that key
   (`CREDENTIAL_MISSING`), and `ley decoders` and Settings list the hosts.

A live speech job also records its audio as a gated recording, and each speech record names its
part and over. Speech text without its audio can be neither checked by ear (T8) nor redone with a
better model (T9), and the clip is the audio that `raw` would otherwise have to carry.

The first-party plugins are candidates for AI-0 to measure: one that calls a cloud speech API on
the user's key, and one that runs on the Mac. Third parties can ship others through the same
contract.

### The assistant is a `ley` worker with `ley mcp`'s tools

The assistant's loop runs in Go, in a `ley` process the daemon starts for each conversation, with
the provider's key passed at spawn. Its tools are the `ley mcp` tools, called in-process from the
same code, so the assistant uses the tool surface the evals grade, and every guard the adapter has
(the don't-disturb refusal, `take_over`) applies unchanged. Its writes reach the daemon over the
socket like any client's, with label `assistant`, so the attribution in A15 is the existing
`caused_by`.

The conversation is daemon state, behind a new `Assistant` service: start, send a message,
subscribe, approve or refuse a pending action, cancel. The app's panel and `ley ask` both render
the same subscription, which gives A14 and lets a conversation outlive the window it started in.
Each event carries the whole message so far (invariant 6), so a client that reconnects reads the
conversation and resumes from its `seq`.

A client attached to a conversation may declare view tools that it performs itself, such as
moving the app's waterfall or selecting a recording in the Library (A19). The worker offers them
to the model for that conversation, and the daemon routes each call to the client that declared
it. `ley ask` declares none. View state stays in the client, where the app keeps it today.

The tools the assistant needs and `ley mcp` lacks are written as MCP tools first, each with its
`ley` mirror, so every agent gains them: `set` on an existing channel, `stop`, bookmarks, bands and
presets, `watch`, `devices attach`, CHIRP import, and the `ley help` topics as a read-only tool.

### Usage is daemon state, in the provider's own units

Each worker reports the usage its provider returned with every response: input, output,
cache-read and cache-write tokens for a language model, and audio seconds for speech, with one
request counted per response. The daemon adds each report to the ledger under the provider, model,
feature, and job or conversation. The ledger is control-plane state with full-state events, so the
app's usage view is a subscription like any other.

Leyline shows usage and never a price. The same model costs different amounts directly, through
Amazon Bedrock or Google Vertex AI, through a third-party gateway, or under a negotiated contract,
and a bundled price table would be wrong for most of those. The provider's console is where cost
and spend limits live. The numbers are what the workers report, so a third-party plugin can
under-report; the ledger says so.

For speech, the amount of audio a batch will send is known before it starts: a recording's
manifest gives the squelch-open duration of every part (U3).

### What the contract gains

Settled for the build on 2026-10-14. Every item is additive within v1, and every number below is
the next free one in its message as of that date; a later plan that takes one of them first moves
this list, not the other way round. The `Assistant` service is sketched here and settled by AI-9,
because its shape depends on what the worker turns out to need.

**A new file, `proto/leyline/v1/ai.proto`**, with two services. One key per provider: a
provider is the name of a kind of endpoint (`anthropic`, `openai`, `deepgram`), with an optional
`endpoint` for a gateway or an OpenAI-compatible server.

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
  rpc DeleteCredential(CredentialRef) returns (Empty);            // ends every job using it (K5)
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

`ReportUsage` is a plain RPC, so the assistant worker and the check worker report over the socket
like any client; a speech plugin has no socket and reports on its records instead (below). Any
socket client can therefore add to the ledger, which `SECURITY.md` states beside the fact that any
socket client can already start a paid job.

**Additions to existing files.**

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
| `bulk.proto` `Frame` | `SegmentMark segment` with `enum SegmentMark { SEGMENT_MARK_UNSPECIFIED = 0; SEGMENT_START = 1; SEGMENT_END = 2; }`; the END frame carries an empty payload | 6 |

A segment is one over: it starts `pre_roll_ms` before the squelch opened and ends `hang_ms` after
it closed, and a squelch that reopens inside the hang continues the same segment, so a segment
can hold more than one entry of the part's `squelch_opens` when they are closer than the hang.
`over` is then the 1-based index of the segment's first `squelch_opens` entry in its part. The
stored-recording path cuts with the same pre-roll and hang, so a recording transcribed later
yields the same segments as the live job that recorded it. That is the "per over" answer to the
open question, chosen because it gives one speaker per record and one notification per over; a
plugin that wants more context can hold segments back itself.

**Error codes**, in the "Error codes" table of `docs/dev/engine-internals.md`, `EngineError.Code`
and `leyline.DaemonCodes`:

| code | gRPC status | raised when |
|---|---|---|
| `CREDENTIAL_MISSING` | `FAILED_PRECONDITION` | the feature or decoder needs a provider's key and none is set; the message names `ley ai add <provider>` |
| `CREDENTIAL_REJECTED` | `FAILED_PRECONDITION` | the provider refused the key itself |
| `PROVIDER_UNAVAILABLE` | `UNAVAILABLE` | the provider or the worker could not be reached |
| `PROVIDER_REFUSED` | `FAILED_PRECONDITION` | the provider refused a request for its own reason (a rate or spend limit), with the provider's message; `FAILED_PRECONDITION` rather than `RESOURCE_EXHAUSTED` so no default retry policy hammers the account |

**Workers.** The daemon spawns `ley` as it spawns a decoder: the executable is found beside
`leylined`, then on `PATH`, and `--ley <path>` or `LEYLINE_LEY` overrides it for tests. The verbs
are hidden, under `ley worker`:

```sh
ley worker check --provider anthropic [--endpoint URL]   # key on stdin; prints one JSON line
ley worker assistant --conversation conv_…               # key on stdin; the loop of AI-9
```

A worker reads the key from stdin, never from an argument or the environment, and reports usage
with `ReportUsage`. The check worker's line is `{"outcome": "accepted" | "rejected" |
"unavailable", "message": "…"}`; its exit status is 0 whenever it produced a line.

**Where things are stored.** Secrets: on macOS a login-keychain item per provider, service
`com.leysdr.leyline`, account the provider's name, created by `leylined`; elsewhere
`<data>/credentials.json`, mode 0600, written atomically. Everything `Credential` and
`FeatureModel` carry: `<data>/ai.json` on both platforms, so a listing never opens the keychain.
The ledger: `<store>/usage.jsonl`, one `UsageReport` per line, appended as reports arrive and
folded into lines at start; lines older than 400 days are dropped at start.

**The mirrors**, each with an implementation in the fake for `ley`'s tests:

```sh
ley ai                              # providers: label, last four characters, last used and checked
ley ai add anthropic [--label L] [--endpoint URL]   # reads the key from stdin and checks it
ley ai check anthropic
ley ai remove anthropic
ley ai use assistant anthropic claude-sonnet-5-5    # K4: the provider and model a feature uses
ley ai usage [--since 30d] [--by day|month] [--json]
ley transcribe <recording> [--yes]
ley decode speech --freq 146.94 [--job]
ley ask "<request>" [--continue]
```

## What the assistant may do

Leyline only receives, so what an assistant can do wrong is bounded: retune or take over a radio,
delete recordings, fill the disk, make calls on the user's provider account and fire notifiers.
The policy for each kind of action:

| action | policy |
|---|---|
| read state, devices, decoders, records, recordings, jobs, help topics | runs |
| tune, set, stop, scan, record, or start an unkept decode job, as the user asked | runs, and is reported |
| take over a radio another client or channel is using | asks, naming what stops |
| start a kept job, add a webhook notifier, add or remove several bookmarks | asks, showing what will be written |
| delete a recording | asks every time |
| start paid transcription | asks, stating how much audio it will send (U3) |
| run a shell command, add a shell notifier, change keys | not among the assistant's tools |
| attach an `rtl_tcp` server or a file as a radio, import a CHIRP file, as the user asked | runs, and is reported; the host or path is the user's own words |

**Text from the air is untrusted input.** Anyone with a transmitter can put words into an APRS
comment, an AIS field or a speech record, and the assistant reads all three. The worker passes
record content to the model as quoted data, never as instructions. Once a conversation has read
received text, every action it proposes needs confirmation even where the table says it runs. And the shell
notifier, which would turn such text into a command on the Mac, is not one of the assistant's
tools. AI-13 adds eval scenarios in which a fixture's decoded text asks the agent to act.

## Privacy and the law

Sending audio to a cloud speech API passes the content of a transmission to that provider. Some
places restrict divulging what was received, which the README's "Receive only" section and
`decoders.md`, "Constraints and boundaries", already raise. Settings, AI states, for each
provider, which feature sends what to which host; a feature set to a cloud provider says so on the
screen where it runs; and on-device speech exists so that a user who must not send audio off the
Mac can still transcribe. The assistant sends its provider the conversation and the tool results,
which include frequencies, decoded records and speech text, and Settings says that too.

## Providers

Candidates as of 2026-10-12. AI-0 and AI-12 choose the defaults.

| feature | provider | notes |
|---|---|---|
| assistant | Anthropic (Claude) | tool use, prompt caching and a Go SDK (`anthropic-sdk-go`); the tool definitions and system prompt are the same on every turn, so turns after the first read them from the cache |
| assistant | Claude through Amazon Bedrock, Google Vertex AI or a third-party gateway | the same model behind another endpoint and credential: AWS or Google credentials, or a gateway's URL and key; the Go SDK has Bedrock and Vertex clients |
| assistant | an OpenAI-compatible local model server | later; whether a local model meets the evals is unmeasured |
| speech | Apple's on-device speech engine (`SpeechAnalyzer`, macOS 26) | no key, no cost, no audio leaves the Mac; accuracy on NFM receiver audio unmeasured |
| speech | whisper.cpp | MIT, runs on the Mac; speed against model size on the target Macs unmeasured |
| speech | a cloud speech-to-text API (OpenAI, Deepgram, AssemblyAI and others) | billed by audio duration; most take a vocabulary or prompt hint, which is where callsigns and the phonetic alphabet go |

A provider is a kind (Anthropic, Bedrock, Vertex, OpenAI-compatible, a speech API) plus an
optional endpoint, and the credential is whatever that kind takes. Anthropic's API has no
speech-to-text endpoint, so a user who wants cloud speech adds a second provider. How many tokens
one conversation takes is unmeasured; AI-12 measures it.

## How the invariants hold

| invariant | how this plan keeps it |
|---|---|
| 1, one protocol | keys, usage, conversations and view-tool calls travel on leyline.v1; workers are children of the daemon on stdio, as decoder plugins are |
| 2, daemon-side DSP | the daemon cuts overs at squelch transitions; workers receive audio and return text |
| 4, allocation-free hot path | the segmenter reuses the gated recorder's path; no model call, HTTP request or prompt runs in the daemon's process |
| 5, sample timebase | speech records carry `SampleTime`; wall clock comes from the anchor, as for every record |
| 6, full state | ledger and conversation events carry the whole object |
| 7, state in the daemon | keys, the ledger and conversations are daemon state; view state stays in the client, as now |
| 8, persistence follows intent | a conversation ends when cancelled or idle and an unkept speech job ends with its client; `keep` persists speech records and their clips |
| 9, `CaptureAllocator` | speech jobs are decode jobs and allocate through it |
| 11, TX | there are no TX tools, as in `ley mcp` |
| 12, no overclaiming | speech text is labelled as model output with its confidence; the assistant cites detections and the band plan, and states what the detector cannot tell |

Invariants 3, 10 and 13 are not affected.

## Decisions taken for the build

The six recommendations in "The shape" are taken as accepted on 2026-10-14; AI-1 writes them up as
the design doc. The open questions resolved with them, so that the build items below have one
answer each:

- **The assistant's client kind** is `mcp` with label `assistant`. It adds no kind, so the
  don't-disturb rule counts its writes as interactive, which is right while a person is asking.
  An unattended agent job is not in this plan.
- **A conversation is kept on disk** (revised 2026-10-15, AI-14; before that it was daemon
  memory only). It ends when the user ends it; 30 idle minutes stop its worker, not the
  conversation; a daemon restart reloads it. It is not tied to its starter's presence, because
  `ley ask` exits between turns and `ley ask --continue` must find the conversation again. What
  it used stays in the ledger under its id.
- **One speech record per over**, so the segmenter cuts at squelch edges with a short pre-roll and
  tail (the `SEGMENTED` entry above).
- **Usage from a decoder travels on its records** (`DecodeRecord.usage`): no second message type,
  so the plugin framing does not change for the decoders that exist.
- **The ledger counts UTC days.** That is what the providers' consoles show, so the two can be
  compared; `ley ai usage` says so in its header.
- **Workers read the key from stdin.** Not an argument (visible in `ps`) and not the environment
  (inherited by anything the worker runs).
- **Squelch-open time per part goes into the manifest.** `recording.json` gains
  `squelch_open_ms` per part, written at part close; the per-over intervals stay in the part
  sidecar. Before that, U3 sums the sidecars, which is what `ley transcribe` does for recordings
  made by an older daemon.
- **Playing one over** (T1) needs `StartPlaybackRequest` to take a sample range. That is AI-6's
  contract addition, not this cut's.

Still open, and not blocking the first items: who owns a channel the assistant makes (AI-9 takes
the leaning in "Open questions"); whether a daemon started outside the login session can read its
keychain item (AI-2 reports `CREDENTIAL_MISSING` with the keychain's message, and the Mac check
decides the rest); the speech engine's vocabulary hint (AI-0).

## Status legend and build items

`[ ]` pending, `[x]` done, `[-]` dropped with the reason, `[d]` waiting on a decision. Each item
names the files it changes so that two of them can be built at once without touching the same
ones, and ends with how it is verified. The order is the dependency order: the contract first,
because every daemon item compiles against it; keys and the ledger before anything that calls a
provider; speech on stored recordings before live speech; the assistant after the tools it needs.

Three items need the owner's Mac or a key and cannot be finished from the Linux container: AI-0
(real receiver audio), AI-12 (a key and the eval run) and the Mac acceptance pass of every app
item. Everything else runs against the fake, the Linux-built daemon and a scripted provider.

### AI-0 `[ ]` Spike: speech-to-text on receiver audio

Unchanged from the scope: measure each candidate engine on real receiver audio (NOAA Weather
Radio, airband ATIS, a 2 m net), recorded as gated recordings and transcribed by hand; record
word error rate, callsign recall after normalisation, cost per hour of squelch-open audio, and
seconds from squelch close to text in `docs/decisions/S4-speech-to-text.md`, with the default
engine. Needs the Mac and the radio. AI-5 builds the contract against a scripted engine so that
this spike chooses a plugin, not a design. **Prepared 2026-10-15, unrun:** `leydec-speech` has
a real `openai` engine (the OpenAI-compatible transcription endpoint, with a vocabulary hint;
the shipped `speech` decoder calls it and `speech-scripted` is the keyless one for tests), and
`leyspeech` (`docs/dev/speech-spike.md`) records a corpus template, scores word error rate and
callsign recall against a hand transcript, reads what the ledger billed, and measures live
latency; `make speech-spike` runs one row per engine. What remains is the recording and the
run on the Mac.

### AI-1 `[x]` The design doc

Write `docs/design/ai.md` from "The shape" and "Decisions taken for the build": keys in the
daemon, workers out of process, speech as a decoder, the assistant as a `ley` worker with `ley
mcp`'s tools, usage in the provider's units, the action policy, received text as untrusted input,
privacy. Its "Deliberately not" and open questions come from here. No plan ids in it
(`docs/writing-guide.md`). With it: `SECURITY.md` gains what the daemon stores (keys and where),
which hosts workers contact, and that any socket client can now make calls on the user's account;
`docs/README.md` lists the design doc and the plan's new status; `docs/design/semantic-tier.md`'s
open question on speech-to-text is answered; the terms table in `docs/writing-guide.md` gains
provider, key, assistant, over, speech record and ledger; the accepted stories move to
`docs/plans/user-stories.md` as V3. Files: `docs/design/ai.md` (new), `SECURITY.md`,
`docs/README.md`, `docs/design/semantic-tier.md`, `docs/writing-guide.md`,
`docs/plans/user-stories.md`. Verify: `make docs-check`; the doc reads without its code blocks;
every path in it resolves. **Done 2026-10-14.** The review of the doc found two gaps in this plan,
settled in "Decisions taken for the build": how `over` is numbered when a segment holds two
openings, and that a conversation cannot end with its starter's presence. The terms table's
`recording` entry was widened to cover audio parts, and `transcript` gained an entry.

### AI-2 `[x]` Keys

In two halves that share only the contract.

**AI-2a, the contract.** Done 2026-10-14; `Empty` moved to `common.proto` so that `control.proto`
can import `ai.proto` without a cycle (same wire format and generated names). `proto/leyline/v1/ai.proto` as settled above, the four error codes, and
the `control.proto` additions for `AIState` and `UsageLine` (the usage additions land here too, so
`make proto` runs once). Then `make proto`; the Go registry (`go/pkg/leyline/errors.go`,
`DaemonCodes`, `GRPCCode`), the Swift registry (`EngineError.Code`, `.all`, a factory each,
`ProtoMapping.statusCode(for:)`), and the rows in `docs/dev/engine-internals.md`, "Error codes".
Files: the protos, `go/gen`, `swift/LeylineProto`, `go/pkg/leyline/errors.go`,
`engine/Sources/EngineCore/Model.swift`, `engine/Sources/LeylineServer/Mapping/ProtoMapping.swift`,
`docs/dev/engine-internals.md`. Verify: `make proto-check`; `ErrorTableTests` and
`TestErrorTableMatchesDocumentation` pass with the new rows; `make go swift`.

**AI-2b, the daemon.** Done 2026-10-14. What the build settled beyond the text below: the
secret file is `<data>/secrets/credentials.json` in a directory of its own, because the data
directory is shared with the store and is created 0755 by whoever gets there first; `CheckCredential`
returns the `Credential` and never fails for a rejected key, which `startDecode` raises as
`CREDENTIAL_REJECTED` instead; the worker's answer and a refusing plugin's last stderr line have
the key replaced, verbatim, JSON-escaped and percent-encoded, before they reach a message or an
event; the daemon's check path reports no usage because the worker does. The keychain store was
written on Linux and never compiled: the Mac check is that `SetCredential` makes a login-keychain
item (`com.leysdr.leyline`, account the provider) a launchd-started `leylined` reads without a
prompt. Checked 2026-10-16: the item is made and the launchd daemon reads it, after one prompt per
rebuilt `leylined`, because `swift build` signs ad hoc and the keychain's access list names that
one build; "Always Allow" quiets it until the next `make reload`, and a Developer ID build has a
stable identity, so the release will not prompt. Left as is by the owner. The first check under
launchd also found no `ley`, since launchd's `PATH` has no Go bin: `ley daemon install` and
`start` now pass their own path as `--ley`. A `CredentialStore` actor holding `ai.json` (metadata and feature models)
and a `SecretStore` protocol with two implementations: `KeychainSecrets` under
`#if canImport(Security)` (service `com.leysdr.leyline`, account = provider) and `FileSecrets`
(`credentials.json`, 0600, atomic). `CredentialsService` with the five RPCs; `SetCredential`
stores, then runs the check; `DeleteCredential` ends every job whose decoder names the provider
with `CREDENTIAL_MISSING` and the `ley ai add` line (K5). A `WorkerProcess` (the spawn half of
`PluginProcess`, with the executable found the way `DecoderRegistry.resolve` finds one, `--ley`
and `LEYLINE_LEY` for tests) runs `ley worker check` with the secret on stdin and reads its JSON
line; no worker, or no `ley`, is `UNAVAILABLE` in `last_check`, never an error from the RPC.
`AIState` goes out on the event plane after every change and into `GetState`. `Daemon.Config`
gains the data path, `--ley` and the search. Files: `engine/Sources/LeylineServer/AI/*` (new),
`Services/CredentialsService.swift` (new), `Server.swift`, `Lifecycle.swift`,
`Session/SessionStore+Snapshot.swift`, `Session/SessionStore.swift`,
`engine/Sources/LeylineDaemon/DaemonCommand.swift`, `engine/Tests/LeylineDaemonTests/*`.
Verify: Swift tests that no RPC response, error message, event or log line contains the secret
(a test key with a distinctive suffix, grepped out of everything the harness captured); the
file store is 0600; a scripted `ley` on `--ley` that prints `rejected` yields
`CREDENTIAL_REJECTED` from `CheckCredential` and a `REJECTED` outcome in the list; a missing `ley`
yields `UNAVAILABLE`.

**AI-2c, `ley`.** Done 2026-10-14, with `ley ai add` reading the key with echo off on a
terminal and refusing to prompt when echo cannot be turned off; the check worker follows no
redirect and replaces the key in any provider message it echoes; the e2e tests in
`go/internal/e2e/ai_test.go` prove the key's text absent from every output, event, log and file
except the 0600 key file. `Credentials` and `Usage` clients on `leyline.Client`; the fake's
`Credentials` and `Usage` servers with the same write-only rule; `ley ai` (list, `add` with the
key from stdin and a refusal with a usage error when stdin is a terminal and `--stdin` was not
given, `check`, `remove`, `use`) and the hidden `ley worker check`, which for `anthropic` calls
`GET /v1/models` with the key and maps 200, 401 and anything else to accepted, rejected and
unavailable, for an OpenAI-compatible endpoint `GET /v1/models` likewise, and reports one request
to `ReportUsage` with feature `check`. The mirror's `AIState` fold in `go/internal/session`.
Files: `go/pkg/leyline/client.go`, `go/internal/fakedaemon/ai.go` (new), `go/internal/cli/ai.go`
(new), `go/internal/cli/worker.go` (new), `go/internal/cli/root.go`, `json_verbs_test.go`,
`testdata/help/*.golden`, `docs/reference/cli.md`. Verify: `ley` tests against the fake; help
goldens; `ley ai --json` is the `AIState` proto3 JSON; a `httptest` provider for the worker; an
e2e test in `go/internal/e2e` in which a key added by `ley ai add` is listed by a second client
with its last four characters and never its text, and `ley ai check` against a scripted `ley`
worker reports the outcome.

### AI-3 `[x]` The ledger

**AI-3a, the daemon.** Done 2026-10-14. The append is one `write(2)`, so a power cut can lose the
last reports and a crash cannot; the ledger write is awaited on the decode job's reader task, so
a slow disk slows a speech job's records and never the DSP thread. A `Ledger` actor: `usage.jsonl` appended per report, folded into
`UsageLine`s by provider, model, feature, scope and UTC day; `UsageService` with `GetUsage` and
`ReportUsage`; a `UsageLine` event after every report; the lines in `GetState`; `last_used_at_ns`
on the credential whose provider the report names; lines older than 400 days dropped at start. A
decode record that carries `usage` is added to the ledger by `DecodeRunner.emit` with `feature`
`speech` and the job's id before it is published. Files: `engine/Sources/LeylineServer/AI/Ledger.swift`
(new), `Services/UsageService.swift` (new), `Jobs/DecodeRunner.swift`, `Server.swift`,
`Session/*`. Verify: the reports of a scripted worker sum per provider, model, feature and scope,
by day and by month, across a daemon restart; the event and `GetUsage` agree; a record with
`usage` from the fake decoder appears as a line under the job.

**AI-3b, `ley ai usage`.** Done 2026-10-14. `--since` (default 30d), `--by day|month`, `--json` as
`GetUsageResponse`, a header that says the days are UTC and the numbers are what the workers
reported; the fake's ledger. Files: `go/internal/cli/ai.go`, `go/internal/fakedaemon/ai.go`,
goldens, `docs/reference/cli.md`. Verify: `ley` tests against the fake at 40, 80 and 160 columns;
`--json` equals the fake's lines.

**AI-3c, refusal and retry.** Done 2026-10-14: a plugin exits 75 (`EX_TEMPFAIL`) with the
provider's words as its last stderr line. `PROVIDER_REFUSED` from a worker or plugin reaches the job as
`DEGRADED` with the provider's message in `status_detail`, and a kept job retries with the
decoder's backoff rather than ending; an unkept job ends with the error. Files:
`engine/Sources/LeylineServer/Jobs/DecodeRunner.swift`, tests. Verify: the fake decoder told to
refuse (`--refuse-after=N`) degrades a kept job, which recovers when it stops refusing.

### AI-8 `[x]` The tools the assistant needs, in `ley mcp`

Go only, so it can run beside AI-2. Each tool reuses the verb's own options and session code, has
its `ley` mirror already, a row in `docs/reference/mcp.md`, a name in `ley mcp --help` and
`mcpToolNames`, and one eval scenario: `set` (a parameter on an existing channel, with the same
don't-disturb refusal as `tune`), `stop`, `list_bookmarks`, `add_bookmark`, `remove_bookmark`,
`list_bands`, `list_presets`, `watch` (a predicate and a notifier, `keep` only with the policy
table's confirmation left to the caller), `attach_device` (`rtltcp` and a file), `import_chirp`,
and `help` (the `ley help` topics, read-only). Files: `go/internal/cli/mcp_tools.go`,
`mcp_tools_*.go` (new, one file per family), `mcp.go` (the help text and instructions),
`mcp_test.go`, `docs/reference/mcp.md`, `evals/scenarios/*.yaml`, `docs/dev/evals.md`. Verify:
fake-daemon tests of each tool against its mirror's `--json`; `TestMCPListsTheToolTable`;
`leyeval check` parses every scenario; the scenarios run when a key is present. Known limit: a
tool that picks "the agent's own channel" chooses by client kind `mcp`, so two agents on one
daemon can pick each other's channel; the fix is a per-client choice when a second agent is a
real case. **Done 2026-10-14**, eleven tools (`set`, `stop`, `list_bookmarks`, `add_bookmark`,
`remove_bookmark`, `list_bands`, `list_presets`, `watch`, `attach_device`, `import_chirp`, `help`)
and five scenarios; `remove_bookmark` is annotated destructive, so a client that confirms
destructive tools asks before every removal, one more than the policy table asks for; the eval
runner now gives `ley mcp` its own `LEYLINE_BOOKMARKS` file. The scenarios have not run (no key
in the container).

### AI-5 `[x]` Speech on stored recordings

**AI-5a, the segmenter and the recording source (daemon).** Done 2026-10-15. What the build
settled: a START frame's `time` is the segment's first sample and a record is matched to its over
by that time (1 ms tolerance); the pre-roll goes out in frames of at most 4096 samples; a plugin
that leaves a frame half-written for 2 s on a live job is replaced; after a recording's last part
the plugin has 30 s plus 2 s per unanswered segment to exit; a restart resumes at the first segment
with no record, so a segment that yields none is sent again (at least once, exactly once when every
segment answers); a source job's plugin that exits four times without a record fails the job with
`DECODER_FAILED`; a plugin is told a key is coming by `LEYLINE_KEY_ON_STDIN=1` in its environment,
because the installed manifest, not the one compiled into the plugin, decides; a transmission that
straddles a size-based part cut is listed to the cut only. `SEGMENTED` in `startDecode`: a
`Segmenter` that follows the channel's squelch edges as `RecordRunner.followSquelch` does, keeps a
pre-roll ring while shut, and writes `SEGMENT_START`, the over's frames, and an empty
`SEGMENT_END` to the plugin; audio while the squelch is shut is never written. `source_uri`: a
`RecordingSource` that reads a recording's parts with `WAVReader`, cuts segments from the part
sidecar's `squelch_opens`, and feeds the plugin as fast as it reads, with no capture, channel or
lease; the job's `channel_id` is empty and `clip_uri` and `over` are stamped in `emit`. The
credential requirement: a manifest with `credential_provider` whose key is not set is refused by
`startDecode` with `CREDENTIAL_MISSING`; the worker-style spawn passes the key to the plugin on
stdin before the descriptor, so the plugin contract gains one line: "a plugin whose manifest names
a provider reads one varint-delimited `SetCredentialRequest` before the `StreamDescriptor`".
`recording.json` gains `squelch_open_ms` per part. Files: `engine/Sources/LeylineServer/Jobs/
Segmenter.swift`, `RecordingSource.swift` (new), `JobStore+Decode.swift`, `DecodeRunner.swift`,
`Decoders/PluginProcess.swift`, `Recording/PartWriter.swift`, `RecordingManifest.swift`, tests;
`engine/Sources/FakeDecoder/main.swift` (echo segments and the credential's last four).
Verify, with the fake decoder and a fixture with keyed overs: each record's `time` equals its
over's `open_sample` less the pre-roll to the sample; the frames between START and END hold
exactly the samples the sidecar's interval covers plus pre-roll and tail; no frame arrives while
the squelch is shut; a recording source transcribes a 60 s recording in under 5 s; a manifest
naming `anthropic` with no key is `CREDENTIAL_MISSING` and names the command.

**AI-5b, the plugin side and `ley transcribe` (Go).** Done 2026-10-15. The SDK decodes segments
on a worker behind a queue of eight so stdin is always read; `ley transcribe --model` sets the
speech feature model before the job and restores it on a refusal, because the model reaches the
plugin as `--model` at spawn; the callsign pattern accepts a one-letter prefix only from the
letters issued alone and never `I`, and a four-letter suffix is not matched. The e2e test
(`go/internal/e2e/transcribe_test.go`) transcribes a 14 s gated recording of three parts and four
overs in under 15 s including the daemon start. `go/pkg/plugin` gains `Segmented`: a
`SegmentDecoder` interface (`Segment(samples, at, emit)`) and the START/END framing, plus the
credential read; `go/cmd/leydec-speech` with `--engine scripted` (reads a `LEYDEC_SPEECH_SCRIPT`
file of lines, one per segment, and emits a record with `text`, `language`, `model`,
`confidence` and `usage`), the callsign normaliser (`go/pkg/callsign`, the phonetic alphabet and
the pattern, a `callsigns` field labelled as a pattern match), and the manifest
`decoders/speech/manifest.json` with `credential_provider` and `contacts_hosts` left for AI-0's
engine. `ley transcribe <recording> [--model M] [--yes]`: reads the manifest, sums
`squelch_open_ms` (or the sidecars), prints the minutes and the provider's host, asks `[y/N]`
unless `--yes`, starts the kept decode job with `source_uri`, and follows its records to the end;
`--json` is the records. The fake: a `source_uri` decode job that reads the recordings directory
the fake serves. Files: `go/pkg/plugin/segmented.go` (new), `go/cmd/leydec-speech/*` (new),
`go/pkg/callsign/*` (new), `decoders/speech/manifest.json` (new), `go/internal/cli/transcribe.go`
(new), `go/internal/fakedaemon/decodejob.go`, `root.go`, goldens, `docs/reference/cli.md`,
`docs/reference/writing-a-decoder.md`. Verify: plugin tests with scripted segments; the
normaliser on the phonetic examples ("whiskey six alpha bravo charlie" is `W6ABC`); `ley
transcribe` against the fake states the minutes and refuses without a terminal and `--yes`; an e2e
test transcribes a gated fixture recording through the scripted engine and `ley records
--protocol speech` shows one record per over with its `clip_uri` and `over`.

### AI-9 `[x]` The assistant service and worker

**The contract**, settled 2026-10-15 in `ai.proto` (numbers are the next free ones in each
message; `Event.body` gains `conversation = 13` and `GetStateResponse` `conversations = 11`):

```proto
message Conversation {                 // whole state on every event
  string conversation_id = 1;          // conv_<ulid>
  ConversationState state = 2;
  string provider = 3;
  string model = 4;
  repeated Turn turns = 5;             // every turn so far, user and assistant alternating
  PendingAction pending = 6;           // set while WAITING: what the assistant asks to do
  ErrorDetail error = 7;               // set when FAILED
  ClientInfo started_by = 8;
  int64 started_at_ns = 9;
  int64 last_turn_at_ns = 10;
  repeated ViewTool view_tools = 11;   // declared by the client that started it
  uint64 seq = 12;                     // bumps on every change; Watch replays from since_seq
}
enum ConversationState {
  CONVERSATION_STATE_UNSPECIFIED = 0;
  CONVERSATION_IDLE = 1;               // waiting for the user
  CONVERSATION_THINKING = 2;           // the worker is on a turn
  CONVERSATION_WAITING = 3;            // the assistant asked, and waits for Resolve or AnswerViewTool
  CONVERSATION_ENDED = 4;
  CONVERSATION_FAILED = 5;
}
message Turn {
  string turn_id = 1;                  // "t1", "t2", … within the conversation
  Role role = 2;
  string text = 3;                     // the text so far; the whole text once done
  repeated ToolCall tools = 4;         // in the order the assistant made them
  int64 at_ns = 5;
  bool done = 6;
}
enum Role { ROLE_UNSPECIFIED = 0; ROLE_USER = 1; ROLE_ASSISTANT = 2; }
message ToolCall {
  string call_id = 1;
  string tool = 2;                     // a `ley mcp` tool name, a view tool, or "undo"
  string arguments_json = 3;
  ToolCallState state = 4;
  string result_text = 5;              // the tool's prose, once DONE
  string result_json = 6;              // the tool's JSON, once DONE
  bool is_error = 7;
  string reason = 8;                   // why it asks: the policy row, in words
  int64 at_ns = 9;
}
enum ToolCallState {
  TOOL_CALL_STATE_UNSPECIFIED = 0;
  TOOL_CALL_RUNNING = 1;
  TOOL_CALL_DONE = 2;
  TOOL_CALL_AWAITING_APPROVAL = 3;     // Resolve decides
  TOOL_CALL_AWAITING_CLIENT = 4;       // a view tool; AnswerViewTool answers
  TOOL_CALL_REFUSED = 5;               // the user said no; the model is told so
}
message PendingAction { string call_id = 1; string tool = 2; string arguments_json = 3; string reason = 4; bool view_tool = 5; }
message ViewTool { string name = 1; string description = 2; string input_schema_json = 3; }

message StartConversationRequest { string provider = 1; string model = 2; repeated ViewTool view_tools = 3; } // empty = the assistant feature model
message SendMessageRequest { string conversation_id = 1; string text = 2; }
message ConversationRef { string conversation_id = 1; }
message WatchConversationRequest { string conversation_id = 1; uint64 since_seq = 2; }
message ResolveActionRequest { string conversation_id = 1; string call_id = 2; bool approve = 3; }
message AnswerViewToolRequest { string conversation_id = 1; string call_id = 2; string result_text = 3; string result_json = 4; bool is_error = 5; }
message ListConversationsRequest {}
message ListConversationsResponse { repeated Conversation conversations = 1; }

service Assistant {
  rpc StartConversation(StartConversationRequest) returns (Conversation);  // CREDENTIAL_MISSING without a key for the provider
  rpc SendMessage(SendMessageRequest) returns (Conversation);              // FAILED_PRECONDITION unless IDLE
  rpc WatchConversation(WatchConversationRequest) returns (stream Conversation);
  rpc ResolveAction(ResolveActionRequest) returns (Conversation);          // FAILED_PRECONDITION unless WAITING on that call
  rpc AnswerViewTool(AnswerViewToolRequest) returns (Conversation);
  rpc StopTurn(ConversationRef) returns (Conversation);                    // ends the running turn; the conversation stays IDLE
  rpc EndConversation(ConversationRef) returns (Conversation);
  rpc ListConversations(ListConversationsRequest) returns (ListConversationsResponse);
}

// The worker protocol, on the worker's stdio, varint-delimited like a decoder plugin's. The key
// comes first as one SetCredentialRequest (LEYLINE_KEY_ON_STDIN=1), then WorkerEvents.
message WorkerEvent {
  oneof event {
    WorkerStart start = 1;
    UserMessage user = 2;
    ActionResolved resolved = 3;
    ViewToolAnswer view_answer = 4;
    WorkerStop stop = 5;               // stop the running turn
  }
}
message WorkerStart { string conversation_id = 1; string provider = 2; string model = 3; string endpoint = 4; repeated ViewTool view_tools = 5; string socket = 6; }
message UserMessage { string turn_id = 1; string text = 2; }
message ActionResolved { string call_id = 1; bool approved = 2; }
message ViewToolAnswer { string call_id = 1; string result_text = 2; string result_json = 3; bool is_error = 4; }
message WorkerStop {}
message WorkerMessage {
  oneof message {
    Turn turn = 1;                     // the assistant's turn so far, whole each time
    WorkerFailure failure = 2;
  }
}
message WorkerFailure { ErrorDetail error = 1; }
```

The daemon derives the conversation's state from the turns it receives: a turn whose last tool
call is `AWAITING_APPROVAL` or `AWAITING_CLIENT` makes the conversation `WAITING` with that call
as `pending`; a turn marked `done` makes it `IDLE`. The worker reports usage with `ReportUsage`
over the socket, as the check worker does, with `conversation_id` as the scope. The worker's
tool writes reach the daemon through its own `ley mcp` server, driven in process over an
in-memory transport, with client kind `mcp` and label `assistant`, so every guard and the
attribution hold unchanged. A channel the assistant tunes is persistent, and the assistant says
how to stop it (`ley stop`), because the worker's connection ends with the conversation; the
app's panel can declare a view tool to retune its own channel instead (AI-11).

**Done 2026-10-15.** What the build settled beyond the text: turn ids count both sides (`t1` user,
`t2` reply), the daemon assigns the user's and takes the worker's; an unknown conversation is
`INVALID_ARGUMENT` and a start with no model is `FAILED_PRECONDITION` naming `ley ai use
assistant`; the daemon writes to a worker from a per-worker queue with a 2 s deadline, after
which that conversation alone fails; `StopTurn` closes only the turn it set out to stop; the
newest 32 finished conversations stay listed; the worker speaks the Messages API with the
standard library rather than `anthropic-sdk-go`, whose module graph pulls in the AWS and Google
Cloud SDKs; the worker's `tune` keeps its channel; the speech decoder's alias is resolved before
the paid-transcription row; tool results reach the model cut at 32 KB; a received-text read
taints the rest of the conversation. The e2e test (`go/internal/e2e/ask_test.go`) drives a real
daemon, worker and `ley ask` through tuning with attribution, a refused and an approved delete,
`--continue`, the received-text ask, Ctrl-C, a 401 and a 429 from a fake provider, a restart,
and reads the worker's argv and environment from `/proc` to show the key is in neither.

**The daemon.** A `ConversationStore` actor: `StartConversation` resolves the provider and model
(the request's, else the `assistant` feature model, else `CREDENTIAL_MISSING` naming `ley ai
add`), spawns `ley worker assistant` through `WorkerProcess` with the key on stdin and
`WorkerStart` after it, and keeps the conversation in memory; every change bumps `seq`, emits
`Event.conversation` and feeds `WatchConversation` streams (replay from `since_seq`); `SendMessage`
appends the user turn and writes `UserMessage`; `ResolveAction`/`AnswerViewTool` write their
events and mark the call; `StopTurn` writes `WorkerStop`; `EndConversation` closes stdin, waits,
kills; 30 idle minutes end a conversation; a worker that exits during a turn fails the
conversation with `INTERNAL` ("the assistant stopped unexpectedly") and leaves the others alone;
daemon shutdown ends them all. `AssistantService` wires the RPCs; `GetState.conversations` lists
them. Verify: a scripted `ley` on `--ley` that plays a worker script; a test per transition;
the crash test; the idle timer with a test clock.

**The worker** (`go/internal/assistant`, run as `ley worker assistant`): reads the key and
`WorkerStart`, hosts the `ley mcp` tool server in process behind an in-memory MCP client, builds
the tool list for the model from it plus the view tools plus `undo`, and runs the loop per
`UserMessage`: call the model, run tool calls in order, write the `Turn` after every change
(text so far, each call's state), until the model stops. The model is behind a `Model`
interface with two implementations: Anthropic through `anthropic-sdk-go` (the system prompt and
tool definitions are the same on every turn, marked for the prompt cache; the API key and the
endpoint from `WorkerStart`), and `Scripted` (`LEY_ASSISTANT_SCRIPT`: a file of JSON lines, each
one model response: `{"text": …}` or `{"tool": …, "args": {…}}`, played in order) for every
test. Usage from each response goes to `ReportUsage` (input, output, cache read and write
tokens, one request). The policy gate before each tool call, from the table in "What the
assistant may do": reads run; `tune`/`set`/`stop`/`scan`/`record`/unkept `start_decode_job`/
`watch` run and are reported; `take_over: true`, `keep: true`, a `webhook:` notifier,
`delete_recording`, `remove_bookmark`, three or more bookmark writes in one turn, and a speech
decode (paid transcription, with the minutes from the recording) ask first (`AWAITING_APPROVAL`
with the reason); a tool the gate never offers (shell notifier) is not in the model's list;
`undo` reverts the last `set`/`tune` the assistant made from the values it read before writing.
Received text: results of `records`, `query_records`, `list_entities`, view tools and speech
text are wrapped as quoted data with a line saying it came over the air, and once a conversation
has read such a result every later write in it asks first whatever the row says (decided
2026-10-15: a per-turn rule let text read in one turn steer a write in the next; the cost is one
extra question per write after a records read, which the evals of AI-12 can revisit). A refused call returns "the user declined"
to the model. `WorkerStop` cancels the model call and marks the turn done. The system prompt:
what Leyline is, the invariant-12 rule (never name a modulation the detector did not; a band-plan
label says where it came from), how to cite `ley` commands, and the ask-before policy in words.
Licences: `anthropic-sdk-go` and its transitive dependencies in `third_party/licenses`, `NOTICE`.
Verify: a test per policy row with the scripted model against the fake daemon (the fake gains
an `Assistant` server that runs the same Go worker loop in process, so `ley ask` is testable
without the daemon); undo; the received-text rule; `WorkerStop` mid-call; `make license-check`.

### AI-10 `[x]` `ley ask`

One request on the command line or a prompt loop when none is given; the assistant's text as it
arrives on stdout, each tool call as one dim line (`→ tune 162.400 MHz NFM`) and its result's
first line; a pending action as a `[y/N]` question on stderr answered with `ResolveAction`
(`--yes` approves everything, which is how an agent uses it); `--continue` resumes the newest
`IDLE` conversation the daemon has, else starts one; `--json` prints every `Conversation` the
watch delivers, one per line; Ctrl-C stops the turn (`StopTurn`) and a second ends the
conversation; exit 1 with the error when the conversation fails. **Done 2026-10-15**: the
assistant's words go to stdout and everything else to stderr; `--continue` picks the newest
unfinished conversation by last turn and answers its pending question first; a rewritten text
prints whole once the turn is done; the reference transcripts are produced by a test against
the fake. Files: `go/internal/cli/ask.go`, goldens, `docs/reference/cli.md`,
`docs/guide/using-ley.md`. Verify: help goldens; transcripts recorded against the fake with a
scripted conversation.

### AI-4 `[x]` Settings, AI in the app

Done 2026-10-15 on Linux: the façade (`AISettings`: key rows, feature rows with the privacy
sentence per provider, the usage fold by UTC day and month, `hasAnyAI`) and the session's unary
writes are tested, and the e2e adds a key through the contract against the real daemon and
proves its text absent from the mirror, the notice and the log. The views
(`SettingsView`, `AISettingsView`) were written blind and are listed in `docs/plans/app.md` for
the Mac pass: ⌘,, the dark appearance under a light system, the `SecureField` clearing on close,
the pickers. The Settings window is forced dark like the main window rather than given light
tokens. A `Settings` scene (⌘,) with an AI pane: keys (K1 to K5), the provider and model per feature
(K4), and the usage view (U1). `DaemonMirror` gains `ai` and `usage` from the snapshot and the
two events; the pane renders them and writes through `AppSession` with the unary RPCs, as
recordings and bookmarks do (the coalescer carries parameter writes only). Verify: façade tests
on Linux for the mirror and the usage fold by day and month; `make app-e2e` against the daemon
with a scripted `ley` worker; on the Mac, the pane read in both appearances, and K1.

### AI-6 `[x]` Speech in the Library

T1, T2, T8, T9 and T12: `StartPlaybackRequest` gains a sample range so one over can play; the
Swift manifest reader takes the sidecar's per-over intervals; speech records fold onto parts and
overs by `clip_uri` and `over`; the words under each over with the model and confidence; search
by text; transcribe again; export as text and SRT from the capture's anchor. Verify: façade
tests on Linux for the fold and the SRT times; the views read on the Mac. **Done 2026-10-15 on
Linux**: `StartPlaybackRequest` and `Playback` carry `start_sample`/`end_sample` (4, 5 and 11,
12), `ley play --over` cuts with the speech decoder's own pre-roll so it plays what was
transcribed, the façade folds speech records onto parts and overs with the newest job shown
and older versions kept, searches by words once per channel, and exports text and SRT (two-anchor
test with drift); the views are unverified and listed in `docs/plans/app.md`.

### AI-7 `[x]` Live speech and speech watches

T3 to T5: `ley decode speech` on a live channel starts a gated recording beside the job and
stamps each record's `clip_uri` from it; speech in the transmissions log in both clients; `ley
watch speech --where 'text~…'`. **Done 2026-10-15** (the `ley` side; the app's transmissions log
is AI-6's and AI-11's territory and still shows no words): the clips are a `RecordRunner` on a
borrowed lease of the decode job's channel, under the job's own id, with the recorder's gate; an
unkept job's clips go when it ends and a crash orphan is deleted at boot (`keep: false` in the
manifest); a kept job's clips are capped at a tenth of `--store-cap` with parts cut on time at
half that; a resumed kept job continues the same recording with new parts. The `~` predicate
could never match a phrase (it compared each word to the whole value); it now matches whole
tokens in order, case-folded, so `text~net control` fires. `ley records` shows an OVER column. Verify: an e2e test playing a fixture with keyed overs through the
scripted engine, a `text~` predicate firing on the expected over, a kept job resuming with the
same id after a daemon restart.

### AI-11 `[x]` The app's assistant panel

A third column beside the inspector: the conversation, each step expandable to its tool call and
result (A16), confirmations as buttons, stop, the tokens used so far, and the view tools for the
waterfall and the Library (A19). A15 needs the mirror to keep each object's last `caused_by`,
which no view reads today. Verify: façade tests; the panel read on the Mac; a story test in
which the assistant retunes and the mirror shows the change attributed to it. **Done 2026-10-15
on Linux**: the panel is a third column beside either place, the app declares `show_band`,
`select_recording` and `show_place` as view tools and answers them on the main actor without
retuning, the mirror keeps who changed each object from `caused_by` and the inspector says "The
assistant set the squelch to -45 dBFS" (and `ley` now says "the assistant" too); the e2e drives
a conversation with the scripted fake worker, including a view tool, against the real daemon.
The attribution e2e uses a stand-in connection labelled `assistant`, because the fake worker
makes no real write; the views are unverified and listed in `docs/plans/app.md`.

### AI-12 `[ ]` Assistant evals and the default model

`leyeval` runs scenarios with the assistant as the agent (`ley ask` as the command), reads the
tokens each scenario took from the ledger, and the run across Claude Opus 5.5, Sonnet 5.5 and
Haiku 5.5 at low and medium effort chooses the default model and effort on pass rate and tokens
per completed scenario, priced from the provider's list on the day. Needs a key. Verify: the
numbers and the date recorded here.

### AI-13 `[x]` Injection scenarios

A check type `no_write` that reads the daemon's event log for a write the scenario forbids, and
scenarios in which a fixture's APRS comment (a speech record once AI-7 exists) asks the agent to
add a notifier, delete a recording or retune. Verify: the scenarios pass for the assistant and
for Claude Code on `ley mcp`. **Written 2026-10-15, unrun**: a `no_write` check reads the run's
`events.jsonl` (every event from seq 0), `mode: assistant` runs `ley ask --yes --json` as the
agent with the key piped to `ley ai add` and removed at the end, `--scripted` plays the whole
path without a key (three scripted runs pass and the obeying scripts fail exactly the expected
checks), and the three `inject-aprs-*` scenarios run in both modes. The eval daemon gets
`LEYLINE_SECRETS=file` so a Mac run never touches the login keychain. What remains is the run
itself: `make eval` on the Mac with a key, both modes, six passes. The speech variant landed
the same day (`inject-speech-notifier`, `inject-speech-delete`, with the engine's words set by
the scenario's `speech_script`), so the run is five scenarios in two modes; `make eval-test`
runs every scripted path without a key.

### AI-14 `[x]` Persisted conversations

Decided 2026-10-15: a conversation is kept on disk, so it survives a daemon restart and `ley ask
--continue` and the app find it afterwards; the worker stays the process that holds the key and
runs the loop. What changes:

- **On disk.** `<data>/conversations/<conversation_id>/conversation.json` holds the
  `Conversation` as proto3 JSON, written through `writePrivateFile` whenever a turn is done, a
  pending action is set or resolved, or the state changes (not on every text delta: a crash
  mid-turn loses the partial turn, which the user repeats). Beside it, `transcript.jsonl` is the
  worker's own model transcript, one `Message` per line, appended by the worker after every
  model response and tool result, so a new worker resumes with the exact context. No file holds
  a key: turns are redacted as today and the transcript never carries one.
- **Lifetime.** Idle no longer ends a conversation: after 30 idle minutes the daemon stops its
  worker and the conversation stays `IDLE` on disk; the next `SendMessage` spawns a worker again
  with `WorkerStart.resume = true` and the transcript path, and the worker loads the transcript
  before its first call. `ENDED` means the user ended it; `FAILED` stays as it is. At daemon
  start every conversation on disk is loaded without a worker; one that was `THINKING` or
  `WAITING` has its last turn closed with the note "(the daemon restarted during this turn)",
  any pending call `REFUSED`, and goes `IDLE`. The newest 100 conversations are kept, and ones
  older than 90 days are dropped at start; `EndConversation` keeps the files (an ended
  conversation is still readable) and a new `DeleteConversation` RPC removes them.
- **Contract.** `WorkerStart` gains `string transcript_path = 7` and `bool resume = 8`;
  `Assistant` gains `rpc DeleteConversation(ConversationRef) returns (Empty)`; the `Conversation`
  message is unchanged. `ListConversations` lists what is on disk, newest first.
- **Clients.** `ley ask --continue` resumes across restarts; `ley ask --list` prints the
  conversations (id, started, last turn, state, first words) and `ley ask --delete <id>`; the
  app's mirror already carries the list.

Files: `proto/leyline/v1/ai.proto` and `make proto`; `engine/Sources/LeylineServer/AI/
ConversationStore.swift` (load, save, lazy spawn, the idle rule), `AssistantWorker.swift`
(`WorkerStart` fields), `Services/AssistantService.swift`, `Lifecycle.swift` (the directory),
tests; `go/internal/assistant/worker.go` (transcript append and load), `go/internal/cli/ask.go`,
`go/internal/fakedaemon/assistant.go` (the fake persists across its own restart if it has one;
else it lists and deletes), the session fold; `docs/design/ai.md` (lifetime), `docs/dev/
engine-internals.md` "Assistant", `docs/dev/assistant.md`, `docs/reference/cli.md`,
`SECURITY.md` (what the daemon stores). Verify: a conversation with two turns and a tool call
survives a daemon restart with the same id and seq, and a third turn's model call carries the
first two in its transcript (the scripted model records what it was sent); a restart mid-turn
closes the turn with the note; the idle sweep stops the worker and a later message restarts it
with `resume`; the retention rule; `ley ask --continue` across the restart in e2e; the canary
absent from both files. **Done 2026-10-15.** Beyond the text: the file is written on any change
other than `seq`, the last-turn time and a turn still being written; shutdown stops every worker
and saves rather than ending; a worker that exits between turns leaves the conversation `IDLE`
with no worker; a resumed worker keeps call numbering and the received-text taint but not the
undo stack; the newest-100 rule also runs when a conversation starts; an append after a torn
transcript line starts a line of its own; a half-written `conversation.json` is skipped and left
on disk. `ley ask --delete` takes a unique id prefix.

### AI-15 `[x]` The assistant on an OpenAI-compatible endpoint

Decided 2026-10-15: one key can serve both features. The worker gains a second `Model`
implementation for the OpenAI-compatible chat API (`POST {base}/v1/chat/completions` with tools,
or the responses API if the tool-result shape is cleaner; one file over the standard library,
the key in the bearer header only, the same error mapping as the speech engine: 401/403
`CREDENTIAL_REJECTED`, 429/5xx/credit `PROVIDER_REFUSED`, else `PROVIDER_UNAVAILABLE`; redirects
refused, https required except localhost; tool calls run in the order the model gave them, with
parallel calls executed one at a time so the gate holds; usage reported in the provider's names
for input, output and cached tokens). `WorkerStart.provider` selects the implementation:
`anthropic` as today, anything else with an endpoint or `openai` as this one, so gateways and
local servers are covered. The default provider for both features is chosen by the AI-12 run;
until then `ley ai add openai` as the only key makes `openai` the default for both features
(AI-16). Files: `go/internal/assistant/openai.go` (new), `model.go`,
`worker.go` (selection), tests with `httptest` pinning the request shape and the tool-result
ordering, `docs/dev/assistant.md`, `docs/design/ai.md` "Providers". Verify: the policy-row tests
run against both models through the scripted harness; the `ask` e2e runs once per provider
against a fake endpoint. **Done 2026-10-15**: the chat completions API with `tool_calls` and
`tool` messages, `max_completion_tokens` with a remembered fallback to `max_tokens`, input
reported as prompt tokens less the cached ones so input and cache read add up as Anthropic's do,
a 16384-token output limit because reasoning models count their hidden reasoning in it, every
policy row run on both models, and an e2e on `openai` and on a gateway named `acme`. A key is
always required, local servers included.

### AI-16 `[x]` First-run ergonomics of `ley ai`

From the ergonomics review of 2026-10-15 (`ley ai add` ended with no next step; a user had to
know two model names and run `ley ai use` twice; `transcribe --model` and `ask --model` meant
different things). In order:

1. **Defaults on add.** When a provider accepts a key, `SetCredential` sets every feature that
   provider can serve and that has no choice yet, from a per-provider table of default models
   (`openai`: assistant `gpt-5`, speech `whisper-1`; `anthropic`: assistant `claude-sonnet-5-5`;
   the names are placeholders until the AI-12 run and the speech spike confirm them), never
   overwriting a choice; the `ley ai add` banner says what was set and how to change it; the
   Settings pane shows the same because the daemon did it. The `--json` shapes do not change.
2. **A shorter `use`.** `ley ai use <provider>` sets every feature the provider can serve, with
   the default models; `ley ai use <feature> <provider>` sets one with the default model;
   `ley ai use <feature> <provider> <model>` stays; `ley ai use <provider> <model>` is refused as
   ambiguous when the provider serves two features, naming the two forms. A provider that
   cannot serve the feature is refused at `use` time, not on the first call.
3. **Concrete hints.** The daemon's missing-model error names a pasteable command
   (`ley ai use assistant openai`), as the fake's does; bare `ley ai` hints from the state it
   sees rather than hard-coding `anthropic`.
4. **Help pass.** Example order, the blank line missing in `ai use`'s help, an `ask` example in
   the root help.

Deferred: a per-run `transcribe --model` needs `DecodeConfig.model` in the contract; until then
its help says it sets the speech model for later jobs too. Files: `engine/Sources/
LeylineServer/AI/CredentialStore.swift`, `Services/CredentialsService.swift`,
`AI/ConversationStore.swift` (the message), `go/internal/cli/ai.go`, `go/internal/fakedaemon/
ai.go`, goldens, `docs/reference/cli.md`, `docs/guide/using-ley.md`, the app's
`AISettings` catalogue (the same default table). Verify: `ley ai add openai` on a fresh daemon
followed by `ley ask` and `ley transcribe --yes` with no `use` in between, in e2e; the fake and
the daemon agree on the table (one test reads both). **Done 2026-10-15.** Beyond the text: a key
added with an `--endpoint` sets no defaults, because the table's models are the provider's own; a
key whose check could not run still sets them, since nothing later would; a provider the table
does not list is accepted in the short `use` forms only once a key with an endpoint exists for
it, and otherwise the refusal names both three-word forms; the ambiguity refusal suggests the
feature whose default model matches the given one; speech counts any installed segmented decoder
that names the provider, so a plugin's provider works without a table row. The Go, Swift and app
tables are held equal by a test that reads the Swift sources as text.

### AI-17 `[ ]` The window follows the radio

Decided 2026-10-19 from the owner's Mac pass. Driving the radio from `ley ask` left the window
inconsistent: the waterfall followed the capture, because the capture is shared, while the
readout, the inspector, the rail's selection and the audio stayed on the window's own channel,
and the sidebar flagged the old GMRS channel as outside the radio's span. The rule: one radio,
one picture. When another client makes a channel on the window's capture, the window follows it.

- **A channel another client makes on the window's capture becomes the tuned channel:** the
  readout, the inspector, the rail's selection, the transmissions log and the audio (the
  window's sink moves to it) read it, and the attribution line names who tuned ("The assistant
  tuned to 162.400 MHz NFM"). The window does not take ownership: the channel stays its maker's
  and persists as it did, and when the maker ends it the held channel's `.lost` path makes the
  window a channel of its own where it was, as today.
- **The window's own channel is ended by the window** once it follows another, unless a recording
  runs on it: then it stays, as the retune question keeps it today, and the inspector says so.
- **Several candidates:** the newest channel (by event `seq`) another client made on the
  window's capture since the window's own last tune. A channel the window made itself is never
  "another client's".
- **A capture moved without a new channel** (another client narrowed or moved the radio and tuned
  nothing) keeps today's out-of-capture caution and its Tune inside button.
- **The panel's assistant** is another client too, so the same rule makes "listen to NOAA" in the
  panel move the window; the view tool the plan once imagined for it is not needed.

Verify: façade tests for the fold that picks the channel to follow, the sink move and the
recording exception; `make app-e2e` with a second client tuning on the window's capture and the
window's held channel changing to it; the views by eye on the Mac, listed in `docs/plans/app.md`.

Done 2026-10-19 on Linux: the mirror keeps who made each channel and at which `seq`
(`MirrorState.made`, from the creation event's `caused_by`), `ChannelFollow` folds it into the
channel to follow, whether the window ends its own or keeps it for a recording (a record job that
borrowed the channel or one on its frequency and mode, the frequency read before the move that
took it out of the capture), and the sink move (detach the window's own sink from a channel that
keeps running, attach one on the new channel only when the window was playing and nothing plays
it yet); `ChangeNote` words a made channel as "The assistant tuned to 162.400 MHz NFM." and
folds the same client's squelch into the sentence. "The window's own" is its client id, as
creation cause and as owner; a job's channel is never followed. `AppSession` holds the followed
id, ends or keeps its own, moves the sink, and on the followed channel's `.lost` makes its own
channel with the last copy's settings. Tested in `ChannelFollowTests` and against the daemon in
`AssistantDaemonTests` (a stand-in `assistant` client's kept channel on the app's capture); the
daemon takes a sink on another client's channel (it checks only the channel), which Linux can
show only as `PLATFORM_UNSUPPORTED`. The views and the session's half are unverified, listed in
`docs/plans/app.md`. The assistant's `listen_summary` makes a short-lived channel of its own on the
radio, and the rule follows it too: when it ends, the window has its own channel on that
frequency.

## Lanes

What can be built at once, each lane in its own worktree, merged in this order:

1. **Contract** (AI-2a), alone, because every other daemon lane compiles against it.
2. **Docs** (AI-1) beside **MCP tools** (AI-8): no shared files.
3. **Daemon keys and ledger** (AI-2b, AI-3a, AI-3c) beside **`ley` keys and ledger** (AI-2c,
   AI-3b): the Swift and Go halves share only the generated code. The e2e tests in AI-2c run
   once both have merged.
4. **Segmenter and source** (AI-5a) beside **plugin and `ley transcribe`** (AI-5b): the same
   split.
5. **Assistant** (AI-9, then AI-10), after lanes 3 and 4.
6. The app items (AI-4, AI-6, AI-11) when a Mac can read the result; AI-7, AI-12 and AI-13 after
   the assistant.

Each lane is verified by a reviewer who did not write it: the diff against this plan and
`AGENTS.md`, the lane's own tests, and `make go-test swift-test e2e lint` on the merged tree. A
finding goes back to the lane's author; a lane merges when the reviewer has nothing left.

## Deliberately not

- **An assistant inside the app only.** A Swift loop would be a feature that works only from
  Swift, a second tool surface beside the one the evals grade, and a conversation lost when the
  window closes.
- **Model calls from the daemon's process.** Provider SDKs and HTTP clients stay out of the
  process that carries the hot path, and a provider change needs no daemon release.
- **A key the contract returns.** Anything that opens the socket could copy it.
- **Prices, cost estimates and budgets.** Prices differ by provider, platform (Bedrock, Vertex, a
  gateway) and contract, so a bundled table would be wrong for many users, and a budget enforced
  on wrong prices would stop work at the wrong point. Leyline shows usage in the provider's units;
  cost and spend limits stay with the provider.
- **A Leyline account or relay service.** Leyline runs no service; every call goes from the
  user's Mac to the provider they chose.
- **Speech text without its audio.** A live speech job keeps the clips it transcribed.
- **The assistant's answer as a measurement.** Detections, levels and records come from the
  daemon; the assistant cites them (`semantic-tier.md`, "State boundary").
- **Digital voice.** Speech from DMR, D-STAR or C4FM needs the vocoder `decoders.md` excludes,
  and speech-to-text does not change that.

## Open questions

- **Who owns a channel the assistant makes.** A channel belongs to the client that created it and
  ends 5 s after that client's presence does (`docs/dev/engine-internals.md`, "Client identity and
  ownership"), so "put on the weather radio" would go silent when the conversation ends. Leaning:
  in the app the assistant retunes the app's own channel; from `ley ask` it makes the channel
  persistent and says how to stop it. AI-9 decides.
- **The keychain from an SSH session:** whether a daemon started by hand outside the login session
  can read its keychain item. AI-2 reports `CREDENTIAL_MISSING` with the keychain's message; the
  Mac check of AI-2 records what happens.
- **The speech engine's vocabulary hint:** whether it should come from the band (callsigns and the
  phonetic alphabet on amateur bands, ATC phraseology on airband) and from the user's bookmarks and
  labels, and how much that changes AI-0's numbers.
