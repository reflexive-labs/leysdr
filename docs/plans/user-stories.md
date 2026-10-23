# Plan: Leyline SDR user stories by milestone

Persona baseline: a licensed ham / developer with an RTL-SDR (USB or rtl_tcp) plugged into a Mac, or IQ files. Stories are acceptance-level, not exhaustive.

Positioning note: Leyline serves the *spectrum explorer* — generic SDR hardware, wideband RX, monitoring, agents — not the operator of a commercial transceiver. "Just works, no drivers, no cables" is the baseline. Transceiver-operation features (logbook, FT8 QSO workflow, TX operation) are out of scope; entering them is a deliberate future decision, not scope drift.

## V0 — Engine + CLI only
Proves the daemon, device layer, and control/data planes with no UI investment.

- As an operator, I can run `ley devices` and see every connected SDR with its capabilities (freq range, sample rates, gain stages).
- As an operator, I can start the daemon, and a second terminal can talk to the same device — no "device busy" errors between my own tools.
- As an operator, I can `ley tune 146.52M --mode nfm` and hear audio out of my Mac's speakers/AirPods.
- As an operator, I can adjust gain, squelch, and filter width live from the CLI while listening.
- As an operator, I can `ley record --iq` and `--audio` to files with sensible metadata (freq, rate, mode, timestamp), and play IQ files back through the same demod path.
- As an operator, I can `ley fft --rate 10` and get a stream of spectrum rows (JSON or binary) suitable for piping into other tools.
- As an operator, I can `ley scan 144M..148M` and get a list of detected carriers with frequency, bandwidth, and SNR.
- As a developer, I can run two demod sessions on one wideband device (e.g., two NFM channels inside a 2.4 MHz capture).
- As a developer, every CLI verb has a `--json` output mode so scripts and agents get the same contract I do.

## V0.5 — TUI dashboard (Go, Bubble Tea)
Ships between CLI and native app; the first constrained rendering client.

- As an operator, running bare `ley` opens a full-terminal dashboard with a live shaded-cell waterfall, current channel, and signal meters.
- As an operator, I can tune, change mode, and adjust squelch from the keyboard without leaving the dashboard.
- As an operator, the dashboard works over SSH to another Mac running the daemon (once remote access lands); rendering is coarser but still accurate.

## V1a — Initial native UI
The SwiftUI app as a peer client of the same daemon.

UI principle — progressive disclosure (post SDR++ review): three layers. (0) launch → waterfall → click → hear, on opinionated defaults (a fixed mid-table gain since 2026-09-21, see `app.md`; per-mode bandwidth, always-on IQ correction, adaptive FFT — no FFT/window controls exist); (1) listener controls only: frequency, mode, squelch, volume; (2) full parameter inspector for those who know why. Rule: nothing in layer 2 is ever required for layers 0–1 to succeed. The app detects and reports failure states (flat noise floor, zero gain, no antenna) instead of failing silently.

- As a newcomer, I can pick a listening preset (FM Broadcast, NOAA Weather, Airband, 2m Repeaters, Marine VHF) and hear something real within seconds of first launch.
- As a ham, I can import my CHIRP file and my radio's channel memories become named bookmarks and scan lists.
- As an operator, I see a live spectrum + waterfall the moment I launch the app with a device connected — no setup wizard, no driver steps.
- As an operator, I can click/drag on the waterfall to tune, scroll to zoom, and the demod follows with imperceptible lag.
- As an operator, I can pick mode, gain, squelch, and filter from controls that feel like a Mac app (sliders, steppers, keyboard shortcuts), not a ported toolkit.
- As an operator, I can bookmark a frequency with a name, and bookmarks appear in a sidebar I can click to jump.
- As an operator, I can start/stop audio and IQ recording from the UI and find recordings in Finder.
- As an operator, if the CLI changes the tuning, the UI reflects it instantly (shared session state — this is the decoupling proof).
- As an operator, I can unplug and replug a dongle and the app recovers gracefully.

## V1b — MVP agent access (MCP)
The semantic tier, exposed to agents.

- As an agent user, I can connect Claude to the engine over MCP and ask "what devices are connected?" and "tune to the local NOAA weather frequency and describe the signal."
- As an agent user, I can ask "scan the 2m band and tell me what's active" and the agent gets structured detections, not raw samples.
- As an agent user, I can say "watch 146.52 for the next hour and log anything heard" and it becomes a durable job whose results I can query later — surviving the agent's session.
- As an agent user, an agent can request a spectrum snapshot as an image to reason about visually.
- As an agent user, an agent can retrieve a recording as a resource and hand it to another tool.
- As a developer, the MCP tool schemas are generated from the same control-plane schema the CLI and UI use — one contract, three consumers.

## V2 — Visually cool shit
Candidates, not commitments. The showcase layer that makes people screenshot the app.

- As an operator, I get a full-window, ProMotion-smooth Metal waterfall with fluid pinch-zoom from full capture bandwidth down to a single voice channel.
- As an operator, I can see a 3D "spectrum terrain" view of activity over time — fly through the last hour of the band.
- As an operator, detected signals are annotated live on the waterfall (band plan labels, modulation guesses, callsigns from decoded traffic).
- As an operator, I can ask for an on-demand dashboard ("show me airband + my three repeaters + APRS traffic") and an agent composes one from the app's UI primitives.
- As an operator, I can replay a recorded band capture like a DVR — scrub the waterfall timeline, tune retroactively to anything that happened.
- As an operator, a menu-bar / ambient mode shows a live mini-spectrum of a watched frequency.

## V3 — AI features on the user's own key
Accepted on 2026-10-14. Keys and usage, speech-to-text, and an assistant that runs the radio from plain requests, all on the user's own provider account. The design is [`design/ai.md`](../design/ai.md); the build items and their status are in [`ai-features.md`](ai-features.md), which cites these stories by id and keeps the later candidates that are not accepted.

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
