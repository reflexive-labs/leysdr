# Leyline documentation

Start with who you are. The first section is for someone who wants to use Leyline; the rest is for
people and agents working on it. Prose in this directory follows the [writing guide](writing-guide.md).

## Using Leyline

You have an RTL-SDR or a HackRF (or an IQ recording) and a Mac.

| read | when |
|---|---|
| [Installing Leyline](guide/install.md) | building the daemon and `ley`, starting at login, a radio on another machine, uninstalling |
| [Using `ley`](guide/using-ley.md) | the tasks in the order a newcomer meets them: see the radio, hear a station, adjust it, see the band, scan, watch, the waveform, two channels, play a recording, make one, decode packets, scripts |
| [Troubleshooting](guide/troubleshooting.md) | the daemon is not running, no radio listed, a busy dongle, no audio, and every message `ley` prints |
| [`ley` reference](reference/cli.md) | the command tree, input conventions, every `--json` shape, exit status |
| [IQ files and fixtures](reference/iq-files.md) | the `.cf32` + sidecar format `ley play` reads, and the generated signals |
| [Writing a client](reference/clients.md) | a script, agent or program that speaks the contract without `ley` |
| [MCP adapter](reference/mcp.md) | letting an agent drive the radio through `ley mcp`: the tools, their shapes, the trust it hands over, client configuration |
| [Writing a decoder](reference/writing-a-decoder.md) | a plugin that turns a channel's audio into typed records |

`ley help <topic>` contains the same facts at the prompt: `squelch`, `frequencies`, `modes`,
`gain`, `presets`, `glossary`, `scripting`, `roadmap`. Current implementation status is in
the "Where things stand" section of the [README](../README.md) and `ley help roadmap`;
[`plans/build-order.md`](plans/build-order.md) is the order features arrive in.

## Working on Leyline

Contributors and coding agents. Read first, in this order:

1. [`CONTRIBUTING.md`](../CONTRIBUTING.md): building and testing, the gate (`make check`), how to
   propose a change, sign-off, the licence of your contribution.
2. [Writing guide](writing-guide.md): the voice, the words, and which kind of document goes where.
3. [`AGENTS.md`](../AGENTS.md): the thirteen invariants as a condensed rule list for coding agents,
   also used as the review checklist. Each has its rationale in a design doc below.

### Contracts and setup (`dev/`)

| read | before |
|---|---|
| [Developer setup](dev/setup.md) | building on the Mac or on Linux, regenerating protos, cutting a release |
| [Engine internals](dev/engine-internals.md) | touching the engine or daemon: threads, the hot path, pipeline math, devices, services, the error-code table, daemon lifecycle |
| [CLI style](dev/cli-style.md) | changing anything a `ley` user sees: colour, streams, glyphs, layout, the frozen contracts |
| [Swift style](dev/swift-style.md) | writing Swift anywhere in the repository: file headers and SPDX, comment and doc-comment voice, naming and unit suffixes, isolation and `Task`, the session, mirror and coalescer patterns, what only the Mac can check |
| [Release checklist](dev/release-checklist.md) | tagging a release: the mechanical gate, licence obligations, the acceptance pass on a real dongle |
| [Agent evals](dev/evals.md) | measuring an agent's use of `ley mcp` against fixtures: running `leyeval`, reading a transcript, adding a scenario and its checks |
| [App internals](dev/app.md) | touching the Mac app: the `app/` package, the client façade (identity, mirror, coalescer, streams), building, bundling and testing it against the daemon |

### Why it is built this way (`design/`)

Each design document opens with its status and scope. Change the document before implementing
behaviour that contradicts it.

| doc | question | status |
|---|---|---|
| [Control plane](design/control-plane.md) | how clients discover, tune, share and arbitrate; gRPC over UDS; the session model | partial: local control is implemented; remote access and watch jobs are not |
| [Data planes](design/data-planes.md) | telemetry and bulk: the sample timebase, latest-wins and gap-marked delivery, negotiation | partial: gRPC streams are implemented; shared memory and historical positions are not |
| [Semantic tier](design/semantic-tier.md) | detections, scans, transcripts, jobs and resources; the MCP surface | partial: scans, recordings, monitor and decode jobs are implemented; watch jobs and transcripts are not |
| [Scan](design/scan.md) | the sweep geometry and the detector, with every number measured | implemented |
| [Signal views](design/signal-views.md) | the waterfall, the channel view and sub-audible tones | implemented except tone squelch and the sonogram |
| [Scope](design/scope.md) | the audio waveform and the demod tap under it | implemented (`ley scope`) |
| [Audio meters](design/audio-meters.md) | `ley levels` and `ley waveform` as instruments | implemented |
| [Band watching](design/band-watching.md) | persistence (`ley phosphor`), burst capture, occupancy | partial: persistence and `ley monitor` implemented; occupancy and burst capture not |
| [Decoders](design/decoders.md) | turning demodulated signal into typed records: the plugin contract, the record envelope and store, the state boundary, the surfaces | implemented for APRS, SAME and AIS; more decoders planned |
| [Recording](design/recording.md) | recording as a job whose output is a resource: parts, the squelch gate, the manifest, the store, the `Resources` service | implemented |
| [Brand](design/brand/README.md) | the mark and the splash, drawn in code; how the icon is made | implemented |
| [Bands, channels and bookmarks](design/channels.md) | the three kinds of frequency; plan channels as data in the band table; bands as the sidebar's spine; Scan band over the scan job; tone, note and tags; CHIRP import; the engine and CLI pass | implemented |

### Decisions (`decisions/`)

One current decision per document, dated, with its rationale, tradeoffs and reopening conditions.
[D2 licensing](decisions/D2-licensing.md) (everything ships open; engine GPL-3.0-or-later, all else
Apache-2.0), [S2 throughput](decisions/S2-throughput.md) (20 MSPS on one fifth of a core: the
all-Swift engine stands) and [S3 USB posture](decisions/S3-usb-posture.md) (librtlsdr/libusb now,
IOUSBHost later).

### Plans (`plans/`)

What is being built, in what order, and the record of what each step found.

- [Build order](plans/build-order.md): milestones A to E and the spikes, with acceptance criteria,
  and "Closing the core", the gate between the engine milestones and the app.
  [User stories](plans/user-stories.md) are the acceptance tests of record.
- Live plans, with `[ ]` items still open: [v1 release](plans/v1-release.md) (the gap analysis and
  work list for the first shared release), [signal views](plans/signal-views.md) (the sonogram
  remains), [band watching](plans/band-watching.md) (occupancy and burst capture remain),
  [decoders](plans/decoders.md) (APRS, SAME and AIS are done; more decoders follow),
  [site screenshots](plans/site-shots.md) (`make shots` and the release assets leysdr.com pulls),
  [MCP adapter](plans/mcp.md) (the tools the daemon can back are done; the rest wait on their
  milestones) and [the Mac app](plans/app.md) (Milestone E: the window, recording and the bands
  sidebar are done; lifecycle and distribution remain).
- [`plans/archive/`](plans/archive/): finished plans and review records, among them
  [bands, channels and bookmarks](plans/archive/channels.md), kept because commit messages cite
  their item ids. Nothing in there is a work list any more.

### For coding agents

`AGENTS.md` is the agent guide (`CLAUDE.md` only points to it, for tools that load that name);
this directory is where its rules come from. The four reads
that prevent the most rework: the design doc for the area before a structural change,
[CLI style](dev/cli-style.md) before changing output, [Engine internals](dev/engine-internals.md)
plus the fixture round-trips in [IQ files and fixtures](reference/iq-files.md) before DSP, and
[Swift style](dev/swift-style.md) before writing Swift — its last two sections say what a Linux
build can verify, what only the Mac catches, and what to say when handing over work that was
never compiled.

Two documents are parsed by tests, so their shape is part of the contract: the "Error codes" table
in `dev/engine-internals.md` (`ErrorTableTests` on the Swift side, the error registry test on the Go
side) and `ley`'s help texts (golden files under `go/internal/cli/testdata/help/`). A page that
moves takes every `docs/` reference in the repository with it.

## Map

```
docs/
├── README.md              this page
├── writing-guide.md       voice, words, document kinds
├── guide/                 using Leyline: install, using-ley, troubleshooting
├── reference/             lookup: cli, iq-files, clients, mcp, writing-a-decoder
├── design/                why it is built this way, with the measured numbers; brand/
├── decisions/             decision records (D2, S2, S3)
├── dev/                   contributor contracts: setup, engine-internals, cli-style, swift-style, app, evals, release-checklist
└── plans/                 build-order, user-stories, live plans; archive/ for finished ones
```
