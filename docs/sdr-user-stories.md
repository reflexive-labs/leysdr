# Mac SDR — User Stories by Milestone

Persona baseline: a licensed ham / developer with an RTL-SDR or HackRF plugged into a Mac. Stories are acceptance-level, not exhaustive.

Positioning note (post ham-radio-apps.com review): Leyline serves the *spectrum explorer* — generic SDR hardware, wideband RX, monitoring, agents — not the commercial-transceiver operator, who is well served by the Roskosch per-brand apps (SDR-Control et al.). Zero device overlap with that catalog. Their UX standard ("just works, no drivers, no cables") is table stakes for us, not a differentiator. Transceiver-operation features (logbook, FT8 QSO workflow, TX operation) are their turf; entering it is a deliberate future decision, not scope drift.

## V0 — Engine + CLI only
Proves the daemon, device layer, and control/data planes with no UI investment.

- As an operator, I can run `sdr devices` and see every connected SDR with its capabilities (freq range, sample rates, gain stages).
- As an operator, I can start the daemon, and a second terminal can talk to the same device — no "device busy" errors between my own tools.
- As an operator, I can `sdr tune 146.52M --mode nfm` and hear audio out of my Mac's speakers/AirPods.
- As an operator, I can adjust gain, squelch, and filter width live from the CLI while listening.
- As an operator, I can `sdr record --iq` and `--audio` to files with sensible metadata (freq, rate, mode, timestamp), and play IQ files back through the same demod path.
- As an operator, I can `sdr fft --rate 10` and get a stream of spectrum rows (JSON or binary) suitable for piping into other tools.
- As an operator, I can `sdr scan 144M..148M` and get a list of detected carriers with frequency, bandwidth, and SNR.
- As a developer, I can run two demod sessions on one wideband device (e.g., two NFM channels inside a 2.4 MHz capture).
- As a developer, every CLI verb has a `--json` output mode so scripts and agents get the same contract I do.

## V0.5 — TUI dashboard (Go, Bubble Tea)
Ships between CLI and native app; the first constrained rendering client.

- As an operator, running bare `ley` opens a full-terminal dashboard with a live shaded-cell waterfall, current channel, and signal meters.
- As an operator, I can tune, change mode, and adjust squelch from the keyboard without leaving the dashboard.
- As an operator, the dashboard works over SSH to another Mac running the daemon (once remote access lands) — degraded-but-honest rendering is the point.

## V1a — Initial native UI
The SwiftUI app as a peer client of the same daemon.

UI principle — progressive disclosure (post SDR++ review): three layers. (0) launch → waterfall → click → hear, on opinionated defaults (auto gain, per-mode bandwidth, always-on IQ correction, adaptive FFT — no FFT/window controls exist); (1) listener controls only: frequency, mode, squelch, volume; (2) full parameter inspector for those who know why. Rule: nothing in layer 2 is ever required for layers 0–1 to succeed. The app detects and names failure states (flat noise floor, zero gain, no antenna) instead of sitting silently broken.

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
