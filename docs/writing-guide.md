# Writing guide

How prose is written in this repository: the documents under `docs/`, the root files, `ley`'s
help texts and error lines, commit messages and code comments. It applies to people and to
agents alike. [`docs/README.md`](README.md) says which page is for whom; this page says how a
page sounds and what goes in it.

## Who is reading

Three readers, in this order of priority:

1. **Someone using Leyline.** They own an RTL-SDR and know roughly what a radio does. They may
   not know what dBFS, an FFT row, a capture or a channel is, and they should not have to before
   they hear a station. This is the default reader: when a page does not say otherwise, it is
   written for them.
2. **A coding agent working on the repository.** It reads `CLAUDE.md` first and these documents
   for the rationale. It needs the rule, the reason, and the path to the thing the rule is about.
3. **A contributor.** A person doing the same work, with the same needs and less patience for
   repetition.

The reader is told where they are by the directory a page lives in (`guide/`, `reference/`,
`design/`, `dev/`, `plans/`), not by a preamble. A page for the first reader never assumes the
vocabulary of the third; a page for the third never re-explains the first's.

## Voice

**Say what it does, and why, in the same breath.** A rule without its reason is a rule the next
person breaks. The reason is usually one clause.

| avoid | prefer |
|---|---|
| Use `--retune` to move the capture. | `tune` refuses to retune a capture other channels ride on, because moving it would silence them; `--retune` says you meant to. |
| Clients should not ping on every data frame. | The daemon drops a connection that sends more than 200 control frames in 30 s, so a client that pings on every data frame loses every busy stream after about a second. |

**Be honest about what does not exist.** Name what is not implemented and the milestone it waits
on. A reader who finds the gap before the docs admit it stops trusting the docs.

| avoid | prefer |
|---|---|
| Recording support is coming soon. | The Mac app is not in this build: `ley` is the only client today (Milestone E). |
| The waterfall shows LoRa packets. | The waterfall is the right instrument, and ours cannot resolve the signal: a symbol is shorter than a row. |

**Numbers are measured, and say where.** Every number in a design doc was measured before it was
written down, and the doc says how (a fixture, a Monte Carlo run, a real handheld on a date). A
number without a source is a guess, and a guess is labelled as one.

| avoid | prefer |
|---|---|
| A settling time of about 200 ms is enough. | The tuner relocks in under a millisecond; the 218 ms is librtlsdr's USB queue, 32 buffers of 32768 bytes captured at the old frequency and delivered after the new one is set. |
| The detector is accurate. | At M = 16 looks the threshold is 4.17 dB over the local floor, and against Gaussian noise through the real FFT and floor estimator it produced 0 false detections in 60 sweeps. |

**Never call a peak a signal.** The detector stays honest (invariant 12). A local maximum of one
row is a *peak*, presentation only; a *detection* is what the detector reports with its floor, its
SNR and how many looks saw it; a *carrier* is what a person concludes. "Loudest bins" once quoted
noise as carriers, and that is the failure every word here guards against.

**Tell the reader what to type next.** Every error line ends with a command; every guide section
ends with the next thing to try; every "not yet" names what to use today.

**Recorded, not typed.** A transcript in a code block was produced by running the command, against
the contract's fake daemon or a real radio, and the page says which. Ids, model names and levels
differ on the reader's machine; say so once per page. Never hand-edit a transcript into a shape
the renderer does not print.

**Plain words, active voice, no sales.** The daemon *drops* the oldest row; it does not "may drop"
it. Nothing here is seamless, powerful, robust, simple, easy, elegant, blazing or magical; say
what it does and the reader will decide. Do not compare with other SDR software; describe
Leyline's approach and stop.

**Open with the reader's question.** A section's first sentence names what it answers:
"`ley spectrum` answers *what is on the air now*. Three things it cannot answer:". A design doc's
Context section is the question that prompted it.

## Words

Use these terms and not their neighbours. When a term is introduced to the first reader, define it
in the sentence where it appears; `ley help glossary` is the reference.

| term | means | not |
|---|---|---|
| **Leyline** | the product | "the app", "the system" |
| **`leysdr`** | the repository and module path | |
| **`ley`** | the command-line client, one Go binary | "the CLI" is fine in dev docs; never "the tool" |
| **`leylined`**, **the daemon** | the background process that owns the radio | "the server", "the backend" |
| **the engine** | the Swift package inside the daemon that does the signal processing (`EngineCore`) | use "the daemon" for behaviour a client sees, "the engine" for the code |
| **the contract** | `leyline.v1`, the protos | "the API"; "the protocol" is gRPC |
| **client** | anything that speaks the contract: `ley`, a script, an agent, a future app | "consumer", "frontend" |
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
| **invariant** | one of the thirteen rules in `CLAUDE.md` | "principle", "guideline" |
| **milestone**, **spike**, **decision**, **work item** | A.1 to D.17; S1 to S3; D2; SV-8, R-4, DEC-2 | |

Capitalise Leyline, RTL-SDR, the modes (NFM, WFM, AM, USB, LSB, CW), CTCSS, macOS, Homebrew,
Xcode, GitHub. Do not capitalise daemon, capture, channel, sink, squelch, spectrum, waterfall,
dongle, preset, band, job.

Units take a space in prose and none in what the user types: `146.520 MHz` and `-40 dBFS` on the
page, `ley tune 146.52M` and `ley set squelch -40` at the prompt. A bare number typed to `ley` is
MHz; say so wherever a newcomer might type one. Ranges read `24.000 MHz to 1.766 GHz`, with "to",
because in `ley`'s tables a dash means "no value". Shorten an id with an ellipsis
(`chan_01J…`); never invent one with a different shape.

## Which document, and what goes in it

| kind | lives in | answers | opens with | the test |
|---|---|---|---|---|
| **guide** | `guide/` | how do I…? | the outcome, then the steps as recorded transcripts | a newcomer follows it start to finish and gets the result |
| **reference** | `reference/` | what exactly? | one sentence of scope, then everything, organised for lookup | any option is found in ten seconds; the wording is frozen (`dev/cli-style.md`, "Frozen contracts") |
| **design** | `design/` | why this way, and what did we measure? | `Status:` and companions; Context; the numbers; "Deliberately not"; open questions | remove the code blocks and it still reads; the doc changes before code that contradicts it |
| **decision** | `decisions/` | what was decided, when, and what would reopen it | `Status: decided <date>`, the decision in bold, then why and what it costs | one decision per file, named after the item it resolves (`D2-`, `S3-`) |
| **plan** | `plans/` | what lands, in what order, and what each step found | the design it implements, a status legend, items in build order | every item says how it is verified; a closing section records what the second look found |
| **contract** | `dev/` | how the engine keeps its promises; how `ley` looks | the contract's scope and who must read it | code comments cite it by heading; tests parse the parts they can |

Plan items carry an id (`SV-8`, `BW-2`, `R-4`) and a box: `[ ]` pending, `[x]` done, `[-]` dropped
with the reason, `[d]` waiting on a decision. An item is ticked only when its tests pass and the
gate is green. A plan whose items are all closed moves to `plans/archive/`; commit messages cite
item ids, so the file is kept and never rewritten.

The root files have fixed jobs: `README.md` is a stranger's first page and its "Where things
stand" section must agree with `plans/build-order.md` (the release checklist checks);
`CONTRIBUTING.md` is the short version of how to work here; `SECURITY.md` says what the daemon
trusts; `CHANGELOG.md` is dated sections of what changed for a user; `CLAUDE.md` is the
invariants, written as instructions to an agent and used as the review checklist.

## Page shape

- **Title.** A guide or reference page is a noun phrase: "Installing Leyline", "`ley` reference".
  A design doc is `# Design: <subject>`, a plan `# Plan: <subject>`, a decision `# <id>: <subject>`.
- **Status line.** Design, plan and decision docs open with `Status: draft` /
  `decided <date>` / `implemented <date>`, and name their companions: "Companion to
  `data-planes.md`, which owns the plane split this builds on."
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
- **No callout boxes.** A warning is a sentence that says what happens and what to do; it needs
  no label.
- **Dashes.** An em dash is allowed where a comma would be wrong; a sentence that wants two is
  two sentences. A dash never stands in for "because".

## `ley`'s own prose

The CLI is documentation the user cannot avoid, so it follows the tightest rules:

- An error line reads `ley: <what went wrong>. <what to do next>`, with the daemon's stable code
  in brackets when there is one (`[DEVICE_BUSY]`). The sentence is the verb's own words and is
  never rewritten for colour (`dev/cli-style.md`, "Frozen contracts").
- Everything meant for a person goes to stderr; stdout is for tables, ids, JSON and rows, so a
  pipe always gets something parseable.
- A banner states the decisions the verb made and why (`using NFM: 2 m amateur band default`,
  `Squelch auto → -80 dBFS (10 dB above the band's noise floor)`), because a default the user
  cannot see is a default they cannot change.
- Help texts are golden files (`go/internal/cli/testdata/help/`). A wording change is a deliberate,
  reviewed diff, and the guide quotes the help rather than paraphrasing it.
- A planned verb (`record`, `watch`) exists as a stub that says what is coming and what to use
  today. It never silently does nothing.

## Commit messages and comments

A subject line is `area: what changed`, imperative, under 72 characters, and reads as a sentence
about behaviour: `engine: NFM full scale follows the channel's bandwidth`, not
`engine: update demod`. Areas in use: `engine`, `ley`, `proto`, `go`, `docs`, `test`, `build`, and
`fix(<area>)` or `feat(<area>)` when the kind of change matters more than where it landed.
The body says why, in prose; the tests say what. Every commit is signed off (`git commit -s`).

A code comment says why, and cites the document that owns the rule by path and heading; the code
says what. A comment that promises behaviour the code does not have is a bug, and the v1 review
found several, so a comment changes in the same commit as the code it describes.

## Before a documentation change lands

- The page is in the directory for its reader, and [`docs/README.md`](README.md) lists it if it is
  new, moved or retired.
- What is not implemented is named, with its milestone.
- Every transcript came from a run, and the page says against what.
- Every number says where it was measured.
- Every `docs/` path in the repository still resolves (`grep -rn 'docs/' --include='*.md'
  --include='*.go' --include='*.swift'`). Two documents are parsed by tests and keep their shape: the "Error codes" table in
  `dev/engine-internals.md`, and the help goldens.
- If a status section changed, `README.md` "Where things stand" and `plans/build-order.md` still
  agree.
