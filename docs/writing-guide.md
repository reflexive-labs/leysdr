# Writing guide

How prose is written in this repository: the documents under `docs/`, the root files, `ley`'s
help texts and error lines, commit messages and code comments. It applies to people and to
agents alike. [`docs/README.md`](README.md) says which page is for whom; this page says how a
page sounds and what goes in it.

## Who is reading

Three readers, in this order of priority:

1. **Someone using Leyline: a ham or an RF hacker.** They own an RTL-SDR or a HackRF and know
   radio: modes, squelch, CTCSS, dBFS, what a spectrum and a waterfall show. Do not explain those.
   They do not know Leyline's own terms (capture, channel, sink, row), and they should not need
   them before they hear a station; define one where it first appears. This is the default
   reader: when a page does not say otherwise, it is written for them.
2. **A coding agent working on the repository.** It reads `AGENTS.md` first and these documents
   for the rationale. It needs the rule, the reason, and the path to the thing the rule is about.
3. **A contributor.** A person doing the same work, with the same needs and less patience for
   repetition.

The directory identifies the audience (`guide/`, `reference/`, `design/`, `dev/`, `plans/`), so
a page does not need an audience preamble. A page for the first reader never assumes the vocabulary
of the third; a page for the third never re-explains the first's.

## Voice

**State the behaviour and its reason.** Put the reason in the same sentence when it directly
explains the behaviour. The reason is usually one clause.

| avoid | prefer |
|---|---|
| Use `--retune` to move the capture. | `tune` refuses to retune a capture used by other channels because moving it would silence them. Pass `--retune` to confirm that interruption. |
| Clients should not ping on every data frame. | The daemon drops a connection that sends more than 200 control frames in 30 s, so a client that pings on every data frame loses every busy stream after about a second. |

**State what is unavailable.** Name what is not implemented and what to use instead. Link the
plan when it helps a contributor find the remaining work.

| avoid | prefer |
|---|---|
| Recording from the app is coming soon. | The Mac app cannot record yet: use `ley record`. |
| The waterfall shows LoRa packets. | Leyline's waterfall cannot resolve a LoRa symbol shorter than one row. |

**Report how numbers were obtained.** Every number in a design doc includes its measurement method,
such as a fixture, a Monte Carlo run or a real handheld on a stated date. Label an unmeasured number
as a guess.

| avoid | prefer |
|---|---|
| A settling time of about 200 ms is enough. | The tuner relocks in under a millisecond; the 218 ms is librtlsdr's USB queue, 32 buffers of 32768 bytes captured at the old frequency and delivered after the new one is set. |
| The detector is accurate. | At M = 16 looks the threshold is 4.17 dB over the local floor, and against Gaussian noise through the real FFT and floor estimator it produced 0 false detections in 60 sweeps. |

**Never call a peak a signal.** Invariant 12 limits what the detector may claim. A local maximum
of one row is a *peak*, used for presentation. A *detection* includes the floor, SNR and look count
reported by the detector. A person may identify a *carrier* from that evidence.

**Provide the next action.** Every error line ends with a command. Every guide section ends with
the next command to try. Every unavailable feature names the current alternative.

**Transcripts are recorded.** A transcript in a code block was produced by running the command
against the contract's fake daemon or a real radio. State which one. Ids, model names and levels
differ on the reader's machine; state that once per page. Never hand-edit a transcript into a
shape the renderer does not print.

**Plain words, active voice, no sales.** Write "the daemon drops the oldest row" when that behaviour
is unconditional. Nothing here is seamless, powerful, robust, simple, easy, elegant, blazing or
magical. Describe the behaviour without comparing Leyline with other SDR software.

**No literary register.** The readers are hams and RF hackers; write the way a good datasheet or
application note reads. Use the standard RF and DSP term (LO, decimation, noise floor, FFT bin,
USB transfer queue) rather than a metaphor for it. Specifically:

- No aphorisms that restate a rule as a maxim ("a default the user cannot see is a default they
  cannot change"). State the fact once.
- No personification. Code, hardware and documents do not promise, admit, lie, stay honest or
  answer the hand; say what they do ("the label warns that auto gain is poor on weak signals").
- No "X, not Y" or chiasmus unless the reader would otherwise assume Y.
- No dramatic framing: "This is the point", "That is the trap", "on purpose", "without apology",
  bold or italics for emphasis rather than lookup.
- No workflow metaphors such as work that "lands", a document that "owns" work or a change that
  "unlocks" another change. Use `implements`, `specifies`, `depends on` or `enables` as
  appropriate.
- Prefer the precise verb over "says" and "names": prints, shows, specifies, lists, returns.
- A sentence that needs two reads is two sentences in normal word order.

**Describe the current system.** Every document outside `plans/` is evergreen. It describes the
current behaviour and remains accurate when a work session ends. It does not name "the owner",
cite an internal plan item id (`APP-5`, `M2-6`, `R-23`, `D.15`, `SV-7`, `DEC-1`, `MCP-1`) or
recount review rounds. A decision record includes its decision date, rationale and current status.
A measurement may include its date because the date identifies the test conditions.

Plans may retain implementation history, but only when it helps complete or verify the remaining
work. Record item status, completion dates, test results and findings that changed later steps. Do
not narrate working sessions, attribute preferences to "the owner" or preserve review chronology.
Commit messages and the version-control history contain that detail.

| avoid | prefer |
|---|---|
| The owner decided on 2026-09-17 that the cap is 20 GiB (R-21). | The cap is 20 GiB, a guess until a day of real use measures it. |
| The second run showed the hang was too short, so APP-5 raised it. | The hang is 5 s: a simplex exchange pauses longer than the squelch's 500 ms tail. |

**Open with the scope or result.** The first sentence states what the section covers or what the
reader will accomplish. A design document's Context section states the problem that prompted the
design.

## Words

Use these terms and not their neighbours. When a term is introduced to the first reader, define it
in the sentence where it appears; `ley help glossary` is the reference.

| term | means | not |
|---|---|---|
| **Leyline SDR**, **Leyline** | the product: the full name on first mention in a page, "Leyline" after | "the system" |
| **`leyline`** | the wordmark in the logo, always lower case | |
| **the app** | the Mac app, `app/`: a client like `ley` | "the GUI", "the frontend" |
| **`leysdr`** | the repository (github.com/reflexive-labs/leysdr) and module path | |
| **`ley`** | the command-line client, one Go binary | "the CLI" is fine in dev docs; never "the tool" |
| **`leylined`**, **the daemon** | the background process that owns the radio | "the server", "the backend" |
| **the engine** | the Swift package inside the daemon that does the signal processing (`EngineCore`) | use "the daemon" for behaviour a client sees, "the engine" for the code |
| **the contract** | `leyline.v1`, the protos | "the API"; "the protocol" is gRPC |
| **client** | anything that speaks the contract: `ley`, the app, a script, an agent | "consumer", "frontend" |
| **the fake** | `go/internal/fakedaemon`, the in-memory contract the `ley` tests run against | "the mock" |
| **radio** | what the user has, in guide prose | "SDR" as a noun for the hardware |
| **device** | the same thing in the contract (`DeviceDescriptor`) and in reference prose | |
| **dongle** | an RTL-SDR stick specifically | |
| **capture** | a radio tuned to a band at a sample rate | "session", "stream" |
| **channel** | one station picked out of a capture: frequency, mode, squelch | "demod", "VFO" |
| **sink** | where a channel's audio goes | "output" |
| **verb** | a `ley` subcommand (`tune`, `scan`) | "subcommand"; "command" is the whole line typed |
| **topic** | a `ley help` page that is not a verb (`squelch`, `glossary`) | |
| **plane** | control, telemetry or bulk: the three kinds of traffic on the contract | "layer", "channel" |
| **row** | one FFT row on the bulk plane | "frame" (a frame is one bulk message of audio or IQ) |
| **block** | the engine's unit of samples through the hot path | "chunk", "buffer" |
| **peak** | a local maximum of one row; presentation | "signal" |
| **detection** | what the detector reports: centre, width, SNR, floor, looks | "signal", "hit" |
| **floor** | the noise floor a level is measured against, in dBFS | "baseline" |
| **squelch** | the level below which a channel is muted | "gate", "threshold" (a threshold is the detector's) |
| **preset**, **band** | client-local tables `ley tune` accepts in place of a frequency | |
| **job**, **resource** | a declared intent the daemon runs, and the durable thing it produces | "task", "file" |
| **decoder**, **plugin** | a program the daemon runs to turn a channel's audio into records; "decoder" in guide prose, "plugin" when the process itself is meant | "codec", "module" |
| **record** | one thing a transmitter said, as a decoder reports it (`DecodeRecord`) | "packet" (a packet is what was on the air), "message" |
| **entity**, **station** | what a client's fold over records shows per transmitter; "station" for APRS | "track", "target" |
| **fixture** | a generated IQ file with expectations in its sidecar | |
| **recording** | an IQ file that came from a radio | |
| **sample time**, **anchor** | the timebase every frame carries, and the one wall-clock mapping per capture | "timestamp" |
| **invariant** | one of the thirteen rules in `AGENTS.md` | "principle", "guideline" |
| **milestone**, **spike**, **decision**, **work item** | A.1 to E.7; S1 to S3; D2; SV-8, R-4, DEC-2, APP-4 (used in `plans/` and `decisions/` only) | |

Capitalise Leyline, RTL-SDR, the modes (NFM, WFM, AM, USB, LSB, CW), CTCSS, macOS, Homebrew,
Xcode, GitHub. Do not capitalise daemon, capture, channel, sink, squelch, spectrum, waterfall,
dongle, preset, band, job.

Units take a space in prose and none in what the user types: `146.520 MHz` and `-40 dBFS` on the
page, `ley tune 146.52M` and `ley set squelch -40` at the prompt. A bare number typed to `ley` is
MHz; say so wherever a newcomer might type one. Ranges read `24.000 MHz to 1.766 GHz`, with "to",
because in `ley`'s tables a dash means "no value". Shorten an id with an ellipsis
(`chan_01J…`); never invent one with a different shape.

## Which document, and what goes in it

| kind | lives in | purpose | opens with | verification |
|---|---|---|---|---|
| **guide** | `guide/` | how do I…? | the outcome, then the steps as recorded transcripts | a newcomer follows it start to finish and gets the result |
| **reference** | `reference/` | what exactly? | one sentence of scope, then everything, organised for lookup | any option is found in ten seconds; the wording is frozen (`dev/cli-style.md`, "Frozen contracts") |
| **design** | `design/` | why this way, and what did we measure? | `Status:` and companions; Context; the numbers; "Deliberately not"; open questions | remove the code blocks and it still reads; the doc changes before code that contradicts it |
| **decision** | `decisions/` | the current decision, its rationale and what would reopen it | `Status: decided <date>`, the decision in bold, then its rationale and tradeoffs | one current decision per file, named after the item it resolves (`D2-`, `S3-`) |
| **plan** | `plans/` | implementation order, status and verification | the design it implements, a status legend, items in build order | every item states its verification; unresolved findings remain open items |
| **contract** | `dev/` | the engine's implementation contract; how `ley` looks | the contract's scope and who must read it | code comments cite it by heading; tests parse the parts they can |

Plan items carry an id (`SV-8`, `BW-2`, `R-4`) and a box: `[ ]` pending, `[x]` done, `[-]` dropped
with the reason, `[d]` waiting on a decision. An item is ticked only when its tests pass and the
gate is green. A plan whose items are all closed moves to `plans/archive/`; commit messages cite
item ids, so the file is kept and never rewritten.

Each root file has a defined purpose. `README.md` is a new reader's first page and its "Where things
stand" section must agree with `plans/build-order.md` (the release checklist checks);
`CONTRIBUTING.md` is how a person builds, tests and proposes a change; `SECURITY.md` says what the daemon
trusts; `CHANGELOG.md` is dated sections of what changed for a user; `AGENTS.md` is the
invariants, written as instructions to an agent and used as the review checklist, and
`CLAUDE.md` only points to it. `AGENTS.local.md`, when it exists, holds one machine's notes and
is never committed.

## Page shape

- **Title.** A guide or reference page is a noun phrase: "Installing Leyline", "`ley` reference".
  A design doc is `# Design: <subject>`, a plan `# Plan: <subject>`, a decision `# <id>: <subject>`.
- **Status line.** Design and plan docs open with `Status: draft`, `partial` or `implemented`;
  a decision opens with `Status: decided <date>`. Each names its companions: "Companion to
  `data-planes.md`, which defines the plane split used here." A plan may date its items; a
  design doc carries no dates beyond its measurements.
- **Headings** in sentence case, short, never skipping a level. Number sections only when the
  order is the point, as the guide does.
- **Paragraphs** wrap at about 100 columns. One idea per paragraph; a paragraph that needs a
  second "but" is two paragraphs.
- **Lists** carry full sentences. A list of rules bolds the lead phrase of each item. Steps a
  reader must follow in order are numbered; everything else is bulleted.
- **Tables** are for lookup: options, error codes, fixtures, terms. Keep cells short; a cell that
  needs a second sentence is a paragraph under the table.
- **Code blocks** name their language: `console` for a transcript with `$ ` prompts, `sh` for
  commands to run, then `json`, `proto`, `swift`, `go`. Say where a transcript was recorded.
- **Links** are repository paths in backticks (`docs/dev/engine-internals.md`) or relative
  Markdown links, and cite a section by its heading in quotes: `docs/dev/engine-internals.md`,
  "Error codes". A code comment cites a doc the same way. From a page under `docs/<section>/`,
  a sibling section is `../<section>/`, the root is `../../`.
- **No callout boxes.** A warning states what happens and what to do; it needs no label.
- **Dashes.** An em dash is allowed where a comma would be wrong; a sentence that wants two is
  two sentences. A dash never stands in for "because".

## `ley`'s own prose

Every user reads the CLI's output, so it follows the tightest rules:

- An error line reads `ley: <what went wrong>. <what to do next>`, with the daemon's stable code
  in brackets when there is one (`[DEVICE_BUSY]`). The verb defines this text, and colour output
  does not rewrite it (`dev/cli-style.md`, "Frozen contracts").
- Everything meant for a person goes to stderr; stdout is for tables, ids, JSON and rows, so a
  pipe always gets something parseable.
- A banner states the decisions the verb made and why (`using NFM: 2 m amateur band default`,
  `Squelch auto → -80 dBFS (10 dB above the band's noise floor)`), so the user can see a default
  and override it.
- Help texts are golden files (`go/internal/cli/testdata/help/`). A wording change is a deliberate,
  reviewed diff, and the guide quotes the help rather than paraphrasing it.
- A planned verb (`record`, `watch`) exists as a stub that says what is coming and what to use
  today. It never silently does nothing.

## Commit messages and comments

A subject line is `area: what changed`, imperative, under 72 characters, and reads as a sentence
about behaviour: `engine: NFM full scale follows the channel's bandwidth`, not
`engine: update demod`. Areas in use: `engine`, `ley`, `app`, `proto`, `go`, `docs`, `test`, `build`, and
`fix(<area>)` or `feat(<area>)` when the kind of change matters more than the affected area.
The body explains why in prose; tests verify the behaviour. Every commit is signed off
(`git commit -s`).

A code comment explains why and cites the document that specifies the rule by path and heading.
The code implements the behaviour. Cite code by symbol name, never by `file:line`, because line
numbers change. Follow "Describe the current system" above: no dates, no plan item ids and no
"the owner". A comment that describes behaviour the code does not have is a bug, so a comment
changes in the same commit as the code it describes.

## Before committing documentation

- The page is in the directory for its reader, and [`docs/README.md`](README.md) lists it if it is
  new, moved or retired.
- Every page outside `plans/` describes the current system. A decision record states whether its
  decision is still current.
- What is not implemented is named, with what to use instead.
- Nothing outside `plans/` narrates work history: no "the owner", review chronology or plan item
  ids. Decision and measurement dates remain when they identify the current decision or test.
- Every transcript came from a run, and the page says against what.
- Every number says where it was measured.
- Every `docs/` path in the repository still resolves (`grep -rn 'docs/' --include='*.md'
  --include='*.go' --include='*.swift'`). Two documents are parsed by tests and keep their shape: the "Error codes" table in
  `dev/engine-internals.md`, and the help goldens.
- If a status section changed, `README.md` "Where things stand" and `plans/build-order.md` still
  agree.
