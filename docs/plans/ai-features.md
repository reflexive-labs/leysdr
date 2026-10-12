# Plan: AI features on the user's own key

Status: draft, scoping only. Nothing here is built and no design doc exists yet; AI-1 writes
`docs/design/ai.md` from the recommendations below once they are accepted. Companion to
[`semantic-tier.md`](../design/semantic-tier.md) (transcripts and the MCP surface),
[`decoders.md`](../design/decoders.md) (the plugin contract this plan reuses for speech),
[`recording.md`](../design/recording.md) (gated parts and overs), [`mcp.md`](mcp.md) (the tool
surface the assistant reuses) and [`SECURITY.md`](../../SECURITY.md) (what the daemon trusts).

## Context

Leyline already lets an agent drive the radio: `ley mcp` serves the `ley` verbs as MCP tools, and
the scenarios in `evals/scenarios/` grade how an agent uses them. That agent is one the user runs
and configures outside Leyline (Claude Code, Claude Desktop, Cursor). This plan scopes three
features that put a model inside Leyline, paid for on the user's own provider account:

1. **Keys and usage.** A place to add provider API keys, a ledger of what each feature spent
   against them, and budgets that stop spending at a cap.
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
| **key** | the secret a provider issues for its API; the contract calls it a credential | "token" (a token is what a model counts) |
| **the assistant** | Leyline's built-in agent, running on the user's key | "copilot", "the AI", "the bot" |
| **agent** | any MCP client driving `ley mcp`; the assistant is one | |
| **over** | one squelch opening: one station keyed up, from open to close | "utterance" |
| **speech record** | the words of one over as a speech decoder reports them: a `DecodeRecord` with protocol `speech` | "transcript" |
| **ledger** | the daemon's record of model usage: tokens, audio seconds, estimated cost | "billing" |
| **budget** | the user's cap on a provider's estimated spend in a month | "limit"; "quota" is the provider's |

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
- **K3.** As an operator, I can add the same key from a terminal with `ley ai keys add anthropic`,
  which reads it from stdin so it stays out of the shell history and `ps`. The app's Settings
  shows it at once, because the daemon holds it.
- **K4.** As an operator, I can choose which provider and model each feature uses. Before I
  choose, I can read what each choice sends off the Mac and to which host.
- **K5.** As an operator, I can remove a key. Every job that was using it stops with a line
  naming the key and the command that adds another.

### Usage and budgets

- **U1.** As an operator, I can see this month's usage per provider and per feature: tokens for
  the assistant and audio minutes for speech, each with an estimated cost and the date of the
  price table it was computed from.
- **U2.** As an operator, I can see what one conversation or one transcription job cost, on the
  conversation and on the job.
- **U3.** As an operator, I can set a monthly budget per provider. At 80% the app and `ley` warn
  once. At 100% Leyline starts no new paid work, stops what is running, and states what it
  stopped and how to raise the budget.
- **U4.** As an operator, before I transcribe a batch of recordings, Leyline states how many
  minutes of squelch-open audio that is and the estimated cost, and starts only when I confirm.
- **U5.** As an operator, a kept speech job running overnight cannot spend past the budget. At
  the cap it goes `DEGRADED` with `BUDGET_EXHAUSTED`, and it resumes when I raise the budget or
  the month turns.
- **U6.** As an operator, `ley ai usage --json` prints the ledger as the standard proto3 JSON
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
`ListCredentials` returns the provider, a label, the last four characters, and when the key was
added, last used and last checked, and never the key itself. On macOS a key is a login-keychain
item created by `leylined`, so the daemon reads it without a prompt and macOS asks the user before
any other program reads it. On Linux, where the daemon runs for development and CI, it is a file
only the user can read.

The daemon holds keys, rather than the app, for three reasons. A kept speech job runs with no
client attached, so it needs the key without the app open. One budget across the app, `ley` and
the jobs needs one place that sees every spend. And `ley ai keys` and Settings must show the same
keys, which is invariant 7 applied to configuration.

A key the contract could return would be readable by anything that opens the socket, which has no
authentication (`SECURITY.md`, "What the daemon trusts"). With write-only keys, a local process
can spend through Leyline's jobs, up to the budget, but cannot copy a key.

### Paid work runs in worker processes the daemon starts

The Swift daemon makes no model call. Each feature's calls are made by an out-of-process worker
that the daemon spawns, as it spawns decoder plugins today: speech by a decoder plugin, the
assistant by a `ley` worker. The daemon passes the worker the key it needs at spawn, adds what the
worker reports it spent to the ledger, and stops the worker when the budget runs out.

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

### Usage is daemon state, and the budget is enforced where the money is spent

Each worker reports the usage its provider returned with every response: input, output,
cache-read and cache-write tokens for a language model, and audio seconds for speech. The daemon
adds each report to the ledger under the provider, model, feature, and job or conversation, and
prices it from a bundled table that carries its date and that the user can override. The ledger
and the budgets are control-plane state with full-state events, so the app's usage view is a
subscription like any other.

The daemon checks the budget before it spawns a worker and after every report. At the cap it
refuses new paid work with `BUDGET_EXHAUSTED`, stops the running workers, and puts their jobs in
`DEGRADED`. The numbers are what the workers report, so a third-party plugin can under-report; the
ledger is labelled an estimate, and the provider's own console is the account of record.
Anthropic's usage and cost reports need an Admin API key, and a regular key is refused, so
reconciling the ledger against them is optional and later.

For speech the cost of a batch is known before it starts: a recording's manifest gives the
squelch-open duration of every part, and that duration is what a per-minute price applies to
(U4).

### What the contract gains

A sketch for AI-1 to settle. Every item is additive within v1.

| addition | for |
|---|---|
| `Credentials`: `SetCredential`, `DeleteCredential`, `ListCredentials`, `CheckCredential` | K1 to K5 |
| `Usage`: `GetUsage`, `SetBudget`, and a ledger event | U1 to U6 |
| `DecoderManifest`: the `segmented` input mode, a required credential, the contacted hosts | T1 to T12 |
| `DecodeConfig`: a recording as the source | T1, T9, T10 |
| `DecodeRecord`: the usage the record cost | U2 |
| `Assistant`: start, send, subscribe, approve, cancel; view tools a client declares | A1 to A19 |
| error codes `CREDENTIAL_MISSING`, `CREDENTIAL_REJECTED`, `BUDGET_EXHAUSTED`, `PROVIDER_UNAVAILABLE`, `PROVIDER_RATE_LIMITED` | every feature |

Each has its `ley` mirror (`ley ai keys`, `ley ai usage`, `ley ai budget`, `ley transcribe`,
`ley decode speech`, `ley ask`) and an implementation in the fake for `ley`'s tests. The error
codes go into the "Error codes" table in `docs/dev/engine-internals.md`, which tests parse.

## What the assistant may do

Leyline only receives, so what an assistant can do wrong is bounded: retune or take over a radio,
delete recordings, fill the disk, spend the budget and fire notifiers. The policy for each kind of
action:

| action | policy |
|---|---|
| read state, devices, decoders, records, recordings, jobs, help topics | runs |
| tune, set, stop, scan, record, or start an unkept decode job, as the user asked | runs, and is reported |
| take over a radio another client or channel is using | asks, naming what stops |
| start a kept job, add a webhook notifier, add or remove several bookmarks | asks, showing what will be written |
| delete a recording | asks every time |
| start paid transcription | asks, with the estimate (U4) |
| run a shell command, add a shell notifier, change keys or budgets | not among the assistant's tools |

**Text from the air is untrusted input.** Anyone with a transmitter can put words into an APRS
comment, an AIS field or a speech record, and the assistant reads all three. The worker passes
record content to the model as quoted data, never as instructions. An action proposed in a turn
that read received text needs confirmation even where the table says it runs. And the shell
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
| assistant | an OpenAI-compatible local model server | later; whether a local model meets the evals is unmeasured |
| speech | Apple's on-device speech engine (`SpeechAnalyzer`, macOS 26) | no key, no cost, no audio leaves the Mac; accuracy on NFM receiver audio unmeasured |
| speech | whisper.cpp | MIT, runs on the Mac; speed against model size on the target Macs unmeasured |
| speech | a cloud speech-to-text API (OpenAI, Deepgram, AssemblyAI and others) | priced per minute of audio; most take a vocabulary or prompt hint, which is where callsigns and the phonetic alphabet go |

Anthropic's API has no speech-to-text endpoint, so a user who wants cloud speech adds a second
provider's key. Anthropic's list prices on 2026-10-06, per million input and output tokens:
Claude Opus 5.5 $4 and $20, Claude Sonnet 5.5 $2 and $10, Claude Haiku 5.5 $0.10 and $0.50. What
one conversation costs is unmeasured. The eval harness already reports cost per scenario
(`docs/dev/evals.md`), and AI-12 uses it to choose the default model on cost per completed task.

## How the invariants hold

| invariant | how this plan keeps it |
|---|---|
| 1, one protocol | keys, usage, conversations and view-tool calls travel on leyline.v1; workers are children of the daemon on stdio, as decoder plugins are |
| 2, daemon-side DSP | the daemon cuts overs at squelch transitions; workers receive audio and return text |
| 4, allocation-free hot path | the segmenter reuses the gated recorder's path; no model call, HTTP request or prompt runs in the daemon's process |
| 5, sample timebase | speech records carry `SampleTime`; wall clock comes from the anchor, as for every record |
| 6, full state | ledger and conversation events carry the whole object |
| 7, state in the daemon | keys, budgets, the ledger and conversations are daemon state; view state stays in the client, as now |
| 8, persistence follows intent | a conversation and an unkept speech job end with their client; `keep` persists speech records and their clips |
| 9, `CaptureAllocator` | speech jobs are decode jobs and allocate through it |
| 11, TX | there are no TX tools, as in `ley mcp` |
| 12, no overclaiming | speech text is labelled as model output with its confidence; the assistant cites detections and the band plan, and states what the detector cannot tell |

Invariants 3, 10 and 13 are not affected.

## Status legend and build items

`[ ]` pending, `[x]` done, `[-]` dropped with the reason, `[d]` waiting on a decision. In build
order: keys and the ledger first, because both features spend through them; speech on stored
recordings before live speech, because it needs no new live path and its cost is known in
advance; the assistant after the MCP tools it needs.

### AI-0 `[ ]` Spike: speech-to-text on receiver audio

Measure each candidate speech engine on real receiver audio before any speech code is written. The
corpus, recorded as gated audio recordings with Leyline, a few minutes each, transcribed by hand:
NOAA Weather Radio (a synthetic voice reading text the National Weather Service also publishes),
airband ATIS (one speaker, set phraseology), and a 2 m repeater net (several speakers, callsigns,
noise). It stays out of the repository unless it can be shared. Record per engine: word error
rate, callsign recall after normalisation, cost per hour of squelch-open audio, and seconds from
squelch close to text. Verify: `docs/decisions/S4-speech-to-text.md` records the numbers, how they
were measured, and the default engine. If no on-device engine is usable on NFM speech, T7 is
offered with its measured accuracy stated, or dropped.

### AI-1 `[d]` The design doc

Waiting on acceptance of the recommendations in "The shape". Write `docs/design/ai.md` with its
"Deliberately not" and open questions, and move the accepted stories into `user-stories.md`.
Verify: the doc reads without its code blocks; `docs/README.md` lists it; `SECURITY.md` gains what
the daemon stores (keys), which hosts workers contact, and what any socket client can now spend.

### AI-2 `[ ]` Keys

The `Credentials` service, keychain storage on macOS and a user-only file elsewhere,
`CheckCredential` for each supported provider, `ley ai keys add|list|remove|check` reading the key
from stdin, and the fake. Verify: Swift tests that no RPC, error message or log line contains key
material; `ley` tests against the fake; an e2e test in which a key added by `ley` is listed by a
second client.

### AI-3 `[ ]` The ledger and budgets

The `Usage` service, the dated price table, budget checks at spawn and on every report, the ledger
event, `ley ai usage` and `ley ai budget`. Verify: a scripted worker that reports usage past the
cap is stopped and its job reads `BUDGET_EXHAUSTED`; a new month resumes it; the 80% warning
arrives once.

### AI-4 `[ ]` Settings, AI in the app

The app's first Settings window (⌘,) with an AI pane: keys (K1 to K5), the provider and model per
feature (K4), budgets and the usage view (U1, U3). It renders the daemon's state and writes through
the coalescer like every other view. Verify: `make app-e2e` against the daemon with a scripted
provider; on the Mac, the pane read in both themes, and the K1 check that no AI control shows
without a key.

### AI-5 `[ ]` Speech on stored recordings

The `segmented` input mode, a recording as a decode source, the credential requirement in the
manifest, the speech plugin AI-0 chose, callsign normalisation, and `ley transcribe <recording>`
with the estimate and the confirmation (U4). Verify, with a scripted speech engine that returns
known text: each record's `time` matches its over in the manifest to the sample; the estimate
equals the manifest's squelch-open duration; no audio from a span with the squelch shut reaches
the plugin.

### AI-6 `[ ]` Speech in the Library

T1, T2, T8, T9 and T12 in the app: the words under each over, play from the words, search, the
model and confidence shown, transcribe again, export. Verify: façade tests on Linux for the fold
of speech records onto parts and overs; the views read on the Mac.

### AI-7 `[ ]` Live speech and speech watches

T3 to T5: `ley decode speech` on a live channel, the gated recording beside it, speech in the
transmissions log in both clients, and `ley watch speech`. Verify: an e2e test playing a fixture
with keyed overs through the scripted engine, a `--where text~` predicate firing on the expected
over, and a kept job resuming with the same id after a daemon restart.

### AI-8 `[ ]` The tools the assistant needs, in `ley mcp`

`set`, `stop`, bookmarks, bands and presets, `watch`, `devices attach`, CHIRP import and the help
topics, each with its `ley` mirror and its entry in `docs/reference/mcp.md`. Verify: fake-daemon
tests against each mirror's `--json`, and an eval scenario for each new tool (`AGENTS.md`, "Agent
evals").

### AI-9 `[ ]` The assistant service and worker

The `Assistant` service, the `ley` worker the daemon spawns for each conversation (found the way
the daemon finds a decoder's executable), the confirmation policy above, and undo of the
assistant's own writes from the state it read before writing. Verify: tests with a scripted model
that every row of the policy table holds; a crashed worker ends its conversation with an error and
leaves the daemon and other conversations running; `third_party/licenses` and `NOTICE` list the
provider SDK.

### AI-10 `[ ]` `ley ask`

The terminal client of a conversation: one request on the command line or a prompt loop,
confirmations as questions on stderr, `--continue`, and `--json` as the conversation's events.
Verify: help goldens, and transcripts recorded against the fake.

### AI-11 `[ ]` The app's assistant panel

A panel beside the inspector: the conversation, each step expandable to its tool call and result
(A16), confirmations as buttons, stop, the cost so far, and view tools for the waterfall and the
Library (A19). Verify: façade tests; the panel read on the Mac; a story test in which the
assistant retunes and the app's mirror shows the change attributed to it.

### AI-12 `[ ]` Assistant evals and the default model

`leyeval` runs scenarios with the assistant as the agent, on a key the developer supplies, and
reports cost per scenario as it does today. Run the existing scenarios and new ones for A1, A3, A6
and A11 on Claude Opus 5.5, Sonnet 5.5 and Haiku 5.5 at low and medium effort. Verify: the default
model and effort are chosen on pass rate and cost per completed scenario, and the run's numbers
and date are recorded here.

### AI-13 `[ ]` Injection scenarios

Eval scenarios in which a fixture's decoded text (an APRS comment first, a speech record once
AI-7 exists) asks the agent to add a notifier, delete a recording or retune. Checks: no such write
appears in the daemon's event log. Verify: the scenarios pass for the assistant, and for Claude
Code on `ley mcp`.

## Deliberately not

- **An assistant inside the app only.** A Swift loop would be a feature that works only from
  Swift, a second tool surface beside the one the evals grade, and a conversation lost when the
  window closes.
- **Model calls from the daemon's process.** Provider SDKs and HTTP clients stay out of the
  process that carries the hot path, and a provider change needs no daemon release.
- **A key the contract returns.** Anything that opens the socket could copy it.
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
  persistent and says how to stop it.
- **The assistant's client kind.** A new `agent` kind, or `mcp` with label `assistant`. The
  don't-disturb signal counts every write not made by a `job` as interactive, which is right
  while the user is asking and wrong for a later unattended agent job.
- **Whether a conversation can be kept,** and if so what it is: a resource beside recordings, or
  only its lines in the ledger.
- **A speech record per over or per exchange** (a gated part). Per over gives one speaker per
  record and one notification per over; per exchange gives the engine more context.
- **Where usage travels from a decoder:** a field on `DecodeRecord`, or a second message type on
  the plugin's stdout, which changes the framing for existing plugins.
- **The ledger's month:** the provider's billing month, which may be in UTC, or the user's
  calendar month.
- **The keychain from an SSH session:** whether a daemon started by hand outside the login session
  can read its keychain item, and what `ley ai keys` reports when it cannot.
- **The speech engine's vocabulary hint:** whether it should come from the band (callsigns and the
  phonetic alphabet on amateur bands, ATC phraseology on airband) and from the user's bookmarks and
  labels, and how much that changes AI-0's numbers.
