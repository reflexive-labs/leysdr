# leysdr.com for 0.2

The brief for the agent that maintains leysdr.com, for the 0.2.0 release. That agent works in the
site's own repository (an Astro site: `src/pages/index.astro`, the sections in
`src/components/`, shared copy and links in `src/config/site.ts`) and never in this one. It takes
its images from a `shots-*` release of `reflexive-labs/leysdr` (`scripts/fetch-shots.sh` pins the
tag) and its download from the `v*` release `src/updates/TAG` pins. This brief was written
against the site's `main` at `af180bf` ("Ship Leyline 0.1.1"), read on 2026-10-23.

The site's voice is the first reader in `docs/writing-guide.md`: a ham or an RF hacker who knows
radio and does not know Leyline's terms. Plain words, the behaviour and its reason, no sales. The
words the site may not use for the new features are under "What the site must not claim".

## What is new in 0.2, for a visitor

The source is `CHANGELOG.md`, "Unreleased", which `make release` dates as 0.2.0. In site terms:

- **An assistant in the app.** A column beside the inspector takes plain requests ("put on the
  weather radio", "scan 2 m and tell me what's active") and runs the radio with the same tools
  `ley mcp` gives any agent: it tunes, sets the squelch, scans, records, keeps bookmarks, and
  moves the window to a band, the Library or a recording. Each step it takes opens to show what it
  called and what came back. Before it takes the radio from another listener, deletes a recording,
  starts a job that outlives the conversation or starts paid transcription, it asks in words, with
  Decline, Allow in this chat and Allow. It answers from the detector's measurements and the band
  plan, and never hears the audio.
- **Your own key.** The AI features run on a provider account the user already has: an Anthropic
  or OpenAI API key, or an OpenAI-compatible server such as a gateway or a model server on the
  user's own network. The key is added in Settings > AI or with `ley ai add`, and both show the
  requests and tokens each feature used by day or month. Leyline shows no prices; the provider's
  bill is the authority.
- **Speech-to-text.** Each over on a gated recording or a live channel becomes text, tied to the
  audio it came from, with the callsigns a pattern found in it. The Library transcribes a
  recording, shows each over's words, searches them, plays the one over a line came from, and
  exports text or SRT subtitles. `ley watch speech --where 'text~net control'` sends a
  notification when an over says "net control".
- **The window follows the radio.** When the assistant, a terminal's `ley tune` or an agent makes
  a channel on the window's radio, the window moves to it, audio included, and the inspector says
  who tuned.
- **More for agents.** `ley mcp` has eleven more tools (changing and stopping a channel,
  bookmarks, bands and presets, watches, attaching a radio, CHIRP import and the help topics).
- **App changes and fixes.** A tidier sidebar, a tuning field that tunes to the hertz, and the
  fixes in the changelog. These need no copy of their own; the re-shot images show them.

Without a key nothing changes: Leyline works as 0.1 did, and the assistant's toggle stays
disabled until a key is added.

## Privacy facts the site may state

Each fact is true of 0.2 and has its source in this repository. Quote the fact, not a stronger
paraphrase of it.

| fact | source |
|---|---|
| Leyline runs no service of its own. Every model call goes from the user's Mac to the provider the user chose, on the user's account. There is no Leyline account or relay. | `docs/design/ai.md`, "Context" and "Deliberately not" |
| With no key added, no AI feature runs and nothing is sent. | `docs/design/ai.md`, "Context" |
| The key is kept by Leyline's background engine in the macOS login keychain. No part of Leyline displays or returns it after it is added; Settings and `ley ai` show only its last four characters. | `docs/design/ai.md`, "Keys live in the daemon"; `SECURITY.md`, "What the daemon reads and writes" |
| The key goes only to the provider it was added for, or to the endpoint it was added with, and that endpoint must be `https` unless it is on the Mac itself. | `docs/dev/assistant.md`, "The loop" and "The model" |
| Speech-to-text sends the audio of each over, from half a second before the squelch opened to half a second after it closed, and a short vocabulary hint (the phonetic alphabet and a few net phrases). The audio while the squelch is shut is never sent. It goes to `api.openai.com`, or to the OpenAI-compatible server the key names. | `docs/guide/using-ley.md`, "Transcribing a recording"; `docs/design/ai.md`, "Speech-to-text is a decoder" |
| Before a recording is transcribed, Leyline states how many minutes of audio will go to which host, and starts only when the user agrees. | `ley transcribe --help` (`go/internal/cli/testdata/help/transcribe.golden`) |
| The assistant sends its provider the conversation and the results of the tools it called, which include frequencies, decoded records and speech text. Settings > AI says, under each feature, what it sends and to which host. | `docs/design/ai.md`, "Privacy and the law"; `AISettings.privacy` in `app/Sources/LeylineClient/AISettings.swift` |
| The assistant never hears the audio. It reads levels, squelch openings, tones and decoded records. | `go/internal/assistant/prompt.go`; `docs/dev/assistant.md`, "The tools" |
| Conversations are kept on the Mac, readable only by the user's account, until the user deletes them; Leyline keeps the newest 100 and drops any unused for 90 days. | `SECURITY.md`, "What the daemon reads and writes" |
| The assistant cannot run a shell command, change a key or transmit; it asks before it takes over a radio, deletes a recording, starts a kept or paid job, adds a webhook, or acts after reading text received over the air. | `docs/dev/assistant.md`, "The gate"; `docs/design/ai.md`, "What the assistant may do" |
| Text received over the air (an APRS comment, an AIS field, a transcribed over) is passed to the model as quoted data, never as instructions. | `docs/dev/assistant.md`, "Received text" |
| Some places restrict passing on what was received; sending audio to a cloud speech service is passing it on. Where that applies, leave speech off or transcribe on a server of your own. | `docs/design/ai.md`, "Privacy and the law"; `docs/guide/using-ley.md`, "Transcribing a recording" |

### What the site must not claim

- **On-device or offline speech.** 0.2 has no on-device speech engine. Apple's speech engine and
  whisper.cpp are candidates in `docs/design/ai.md`, "Providers", and neither is built. A Whisper
  server on the user's own network works through an OpenAI-compatible endpoint; say that, and no
  more.
- **"Private AI", "your data never leaves your Mac", "nothing is sent".** With a cloud provider
  chosen, audio and conversations leave the Mac for that provider.
- **That the key never leaves the Mac.** It is sent to its provider with every call.
- **Accuracy or quality.** Neither the speech word error rate nor the assistant's pass rate on the
  evals has been measured on real receiver audio or a real key yet (`docs/plans/ai-features.md`,
  AI-0 and AI-12). The default models (`gpt-5`, `whisper-1`, `claude-sonnet-5-5`) are defaults,
  not recommendations; `gpt-5` is a placeholder until the evals choose one.
- **Cost.** No prices, no "cheap", no "free AI". The features bill the user's provider account,
  and Leyline shows usage only.
- **Providers that are not built.** Amazon Bedrock, Google Vertex AI, Deepgram and AssemblyAI are
  not in 0.2. A ChatGPT or Claude subscription is not a key: the features need an API key.
- **That a local model works well with the assistant.** An OpenAI-compatible local server can be
  chosen; whether a local model handles the tools is unmeasured.
- **That the assistant listens, identifies signals or runs on its own.** It never hears audio,
  reports only what the detector and decoders measured, never names a modulation the detector did
  not, and acts only on a request in an open conversation.
- **Digital voice.** DMR, D-STAR and C4FM are not decoded, and speech-to-text does not change that.
- **`ley ask`.** It is a hidden test harness, not a feature. People talk to the assistant in the
  app; other agents use `ley mcp`.
- **The words to avoid**: AI-powered, smart, intelligent, copilot, "the AI", seamless, magic, and
  any comparison with other SDR software. Call it "the assistant".

## Page by page

The site is one page (`src/pages/index.astro`) of sections plus `/download`. Each change below
names its file.

### `src/config/site.ts`

- `intro`: add one clause for 0.2, for example: "…records every transmission, decodes APRS,
  weather alerts and AIS, and, on your own AI key, turns each over into text and takes requests
  in plain words." Keep it one sentence.
- `description` stays under about 125 characters; 0.2 does not need to be in it.

### Hero (`src/components/Hero.astro`)

- The `specs` list gains one row, `AI`: an assistant and speech-to-text on your own key, for
  example `['AI', 'Assistant and speech-to-text, on your key']`. Decided 2026-10-23: one row for
  both features, rather than a `Speech` row.
- The nav's `app · terminal · agents` can stay; "agents" still covers the assistant and `ley mcp`.
- The fine print (`Free · macOS 26 or later · signed and notarized · receive only`) stays.
  Leyline is still free; the AI features bill the user's own provider, which the AI section says.

### The app section (`index.astro`, `#app`)

- `app-radio-2m.png`, re-shot, stays. The lede still holds. If the re-shot window shows the
  assistant's toolbar button, the lede can end: "…and the Library holds everything you've
  recorded. With a key added, an assistant sits beside the inspector."

### Features (`src/components/Features.astro`)

The five existing features stay, with their images re-shot. Two need a line changed and two are
new.

- **Auto-recording** ("Every over, its own clip"): add a sentence that a gated recording's overs
  can be turned into text. `library-net.png` stays; `library-speech.png` goes in the new speech
  feature, not here.
- **Scanning**: the copy holds. The app's Scan band is now a row under the open band's header;
  "Scan band lists the hits under the band" is still true.
- **New: the assistant**, after Decoding or before Ways. Eyebrow "The assistant"; title such as
  "Ask for the weather radio. It tunes it and says what it did." Copy from "What is new" above:
  what it does, that every step shows what it called, the questions it asks before it takes over a
  radio or deletes, and that it never hears the audio. Visual: `app-assistant.png`, with
  `app-assistant-ask.png` beside or under it as the question card.
- **New: speech**. Eyebrow "Speech-to-text"; title such as "Read the net. Play the over it came
  from." Copy: each over to text, kept with its audio, callsign chips, search, export as text or
  SRT, and the watch that notifies on a phrase. State in the copy that the audio goes to OpenAI or
  the user's own OpenAI-compatible server. Visual: `library-speech.png`, stacked with
  `ley-watch-speech.png` (a terminal capture, so `stacked` as Decoding is).

### Your key, your provider (new section, or a Feature)

A short section that carries the privacy facts, placed after the two new features or inside
`Need.astro`'s neighbourhood. Copy: which providers, that the key stays in the keychain and goes
only to its provider, what each feature sends to which host, no prices, and the sentence on places
that restrict passing on what was received. Visual: `settings-ai.png`, with `ley-ai.png` as the
terminal equivalent. This is the section to link from anywhere else that mentions AI.

### Ways (`src/components/Ways.astro`)

- The heading "One engine. Drive it from the app, the terminal or an assistant." holds, and now
  means the built-in assistant as well as any agent.
- The lede's last clause ("an assistant can sweep a band and tell you what's on it") holds. Add
  that the window follows a channel the terminal or the assistant makes.
- `ways-sync.png` stays. `app-follow-terminal.png` shows the newer behaviour (the window moving to
  a terminal's `ley tune`); use it beside `ways-sync.png` or in its place, whichever the layout
  takes.
- The terminal card's hand-written transcript must match what `ley` prints now. A squelch the
  daemon measured now reads `(auto)` after its level, so the `ley set squelch -45` line reads
  `squelch -53 dBFS (auto) → -45 dBFS on 146.520 MHz NFM (channel 1)` when the first squelch was
  automatic. Better: show `ways-terminal.png`, which is a recorded run.
- The "An assistant" card's mock chat: replace it with a crop or a scaled `app-assistant.png`, and
  keep the line that `ley mcp` gives other agents (Claude Code, Claude Desktop, Cursor) the same
  tools. If the mock stays, its reply must remain one the scan scene produces (five carriers, with
  144.390 seen once), as it is today.

### What you need (`src/components/Need.astro`)

Add a fifth item, marked optional: label "For the AI features", title "Your own API key", body
"Anthropic or OpenAI, or an OpenAI-compatible server on your network. Leyline works without
one."

### Download (`src/components/Download.astro`, `src/pages/download.astro`)

- The version line reads `release.version` from `src/updates/release.json`, and the download page
  takes its notes from the release, so 0.2.0 arrives through the **Update app release** pull
  request that the site's workflow opens once `v0.2.0` is published. Merging it ships the update
  to every installed copy through Sparkle, so it is merged only once the release is checked.
- The site currently pins `v0.1.1` (`src/updates/TAG`) although `v0.1.2` is published; the 0.2.0
  pull request moves it past both.
- "Free for Mac." holds. Add nothing about AI here beyond, at most, "AI features use your own
  provider key".

### Footer (`src/components/Footer.astro`)

The "Receive only" paragraph holds. It can gain one sentence: "Transcribing with a cloud service
passes what you received to that provider."

## Images

Every image is a release asset of a `shots-YYYY-MM-DD` release (`docs/plans/site-shots.md`). Every
image of a scene with signals has alt text ending "Simulated signals.", which `shots.json`
carries; the site takes the alt text from `shots.json` and does not write its own. The captions
below are suggestions for the copy beside an image. The speech scenes run the scripted speech
decoder, so the words in them are written for the scene: a caption must not present them as a
model's output on real audio.

### The 14 existing assets, re-shot for the 0.2 window

Same names, same places on the page. `chirp-csv-before.png` and `app-icon-1024.png` have no app
UI and look as they did.

| asset | where it stays |
|---|---|
| `app-radio-2m.png` | `#app` section |
| `sidebar-chirp-import.png`, `chirp-csv-before.png` | Features, Memories by band |
| `inspector-tone.png`, `inspector-dcs.png` | Features, Tone discovery |
| `scan-2m.png`, `scan-app.png` | Features, Scanning |
| `library-net.png` | Features, Auto-recording |
| `aprs-track.png`, `ais-track.png` | Features, Decoding |
| `ways-app.png`, `ways-terminal.png`, `ways-sync.png` | Ways |
| `app-icon-1024.png` | Download |

The site pins `shots-2026-10-03`; `shots-2026-10-05-2` is newer and already marks
`chirp-csv-before.png` and `app-icon-1024.png` as not simulated, so the `notSimulated` workaround
in `src/lib/shots.ts` can go when the tag moves.

### New assets

None of these is in `site/shots/scenes.yaml` yet; each needs a scene there before `make shots`
takes it.

| asset | what it shows | where | suggested alt (before "Simulated signals.") | suggested caption |
|---|---|---|---|---|
| `app-assistant.png` | the window with the assistant column open after a request such as "put on the weather radio", the steps it took and its reply | the assistant feature; Ways' assistant card | The Leyline window with the assistant beside the inspector: a request to put on the weather radio, the tune it ran, and its reply naming the channel. | It tunes, then says what it did. Open a step to see what it called. |
| `app-assistant-ask.png` | a question card: a take-over or a delete, with Decline, Allow in this chat and Allow | the assistant feature, beside `app-assistant.png` | The assistant asking before it moves a radio another channel is using, naming that channel, with Decline, Allow in this chat and Allow. | Before it takes a radio from someone or deletes a recording, it asks. |
| `settings-ai.png` | Settings > AI: a key with its last four characters, the features with their models, and each feature's line saying what it sends to which host | the key section | Leyline's Settings, AI: an OpenAI key shown by its last four characters, the assistant and speech models it set, and what each sends to which host. | The key stays in your keychain. Each feature says what it sends, and where. |
| `library-speech.png` | the Library on a transcribed net: each over's words under its part, callsign chips, one over playing | the speech feature | The Leyline Library on a net recorded on 147.180 MHz, with the words of each over under its part, the callsigns found in them, and one over playing. | Every over's words, kept with the audio they came from. |
| `app-follow-terminal.png` | a terminal running `ley tune` beside the window, which has moved to that channel and whose inspector names who tuned | Ways | A terminal running ley tune 146.94 beside the Leyline window, which has moved to 146.940 MHz and says another terminal tuned it. | Tune from the terminal and the window follows. |
| `ley-ai.png` | `ley ai` in a terminal: the key's provider, label, last four characters, when it was used and checked, and each feature's provider and model | the key section, under `settings-ai.png` | ley ai in a terminal: one OpenAI key shown by its last four characters, accepted by the provider, and the models the assistant and speech use. | The same keys, from the terminal. |
| `ley-watch-speech.png` | `ley watch speech --freq … --where 'text~net control'` printing the overs that matched | the speech feature, stacked under `library-speech.png` | ley watch speech in a terminal: the overs on a 2 m net whose words include "net control", each with its time, part and callsigns. | A notification when someone says the phrase you are waiting for. |

## The tag to pin

`shots-YYYY-MM-DD`: left as a placeholder until the owner publishes the 0.2 set with
`make shots-publish`. The site moves `TAG` in `scripts/fetch-shots.sh` to it (or merges the
**Update screenshots** pull request), runs `make shots`, and checks each changed image against the
copy beside it, as the site's README says.

## The download

Leyline 0.2.0, tag `v0.2.0` on `reflexive-labs/leysdr`, Apple silicon, macOS 26 or later. The
DMG is `Leyline-0.2.0.dmg`, served from `/updates/` once the site pins the tag. Nothing in the
download link changes: it is `/download`, which reads the pinned release.
