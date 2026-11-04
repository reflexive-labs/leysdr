# leysdr.com for 0.3

The brief for the agent that maintains leysdr.com, for the 0.3.0 release. That agent works in the
site's own repository (`reflexive-labs/leysdr.com`, an Astro site) and never in this one; the
layout, voice and image rules of `site-0.2.md` still hold and are not repeated here. Written
2026-11-03, after `v0.3.0` shipped through the site's update feed (PR #7).

## What is new in 0.3, for a visitor

The source is `CHANGELOG.md`, `## 0.3.0`. In site terms:

- **Aircraft.** Leyline decodes ADS-B on 1090 MHz: each aircraft's callsign, position, altitude,
  speed and track. `ley decode aircraft` prints the messages; `ley track aircraft` keeps a table of
  the aircraft heard, by callsign. The app shows them on a map.
- **The Decoders place.** A third place in the window, beside Radio and Library, for everything
  Leyline decodes: aircraft, APRS stations, AIS vessels and NOAA weather alerts (SAME). For each
  decoder: a running log, a table of the transmitters heard, a map when they report a position,
  and an inspector that shows every field a message carried. A transmitter can be given a name,
  which the terminal's `ley label` shares. A decoder started in the app keeps running after the app
  quits, until it is stopped.
- **Alerts.** The bell on a decoder's page builds a watch from that decoder's own fields (a SAME
  county, an APRS callsign, a place and a radius) and posts a macOS notification on each match,
  with the app closed.
- **Names on the waterfall.** While a decoder runs, the callsign it decoded appears on the
  waterfall at the row and frequency it came from.
- **Decode a recording.** Any recording in the Library can be run through a decoder that reads it,
  after the fact.
- **One radio, many uses, and it says so.** A dongle has one tuning. Leyline now keeps track of
  everything that depends on it (your listening, a decoder, a recording, a spectrum view) and
  says, before anything moves, what would pause: the app asks "Take the radio?" or "Move the
  radio?" naming what stops; `ley tune` refuses a move that would pause a decoder unless told to;
  `--dry-run` says what a command would do without doing it. When a decoder that took the radio
  stops, the radio goes back to where it was. An agent connected through `ley mcp` gets the same
  answers and asks before taking the radio.
- **The fixes and smaller changes** in the changelog need no copy of their own; the re-shot
  images show the third place in the toolbar and the Claims group in the inspector.

## Facts the site may state

| fact | source |
|---|---|
| Decoding happens on the Mac. Records, labels and watches stay in the user's Library folder; nothing about what is decoded is sent anywhere. | `docs/design/decoders.md`, "The state boundary" |
| The map is Apple's MapKit: drawing it fetches map tiles from Apple for the area shown. Nothing else about what is decoded leaves the Mac for it. | `app/Sources/LeylineApp/DecoderMap.swift`; `docs/plans/decoders-app.md`, "Future work" |
| A watch's notification comes from Leyline's background engine, so it fires with the app closed. | `docs/design/decoders.md`, section 7 |
| On an R820T dongle with an indoor antenna (2026-11-02), ADS-B decoded at 40 dB of gain and not at 30, which is why the decoder sets 40 dB itself. | `CHANGELOG.md`, 0.3.0; `docs/plans/decoders-app.md`, "What the owner's air carries" |
| A displaced decoder or recording says who moved the radio and resumes when the radio comes back; nothing is silently decoded at the wrong frequency. | `docs/design/claims.md`, "Displacement, uniformly" |

### What the site must not claim

- **Who an aircraft is.** 0.3 shows an aircraft's 24-bit address and the callsign it transmits.
  It does not look up registrations, aircraft types, operators or routes; that is future work
  (`docs/plans/decoders-app.md`, "Future work").
- **Range or reliability.** ADS-B reception depends on the antenna and where it is. The owner's
  indoor setup heard one or two aircraft at a time. No range figure, no "see every plane".
- **Flight tracking as a service.** Leyline does not feed or use FlightAware, ADS-B Exchange or
  any network, and has no flight database.
- **Offline maps.** The map needs a network for its tiles.
- **Decoders that are not built.** No 433 MHz sensors (`rtl_433`), no pagers, no ACARS, no FT8, no
  satellite images. Digital voice (DMR, D-STAR, C4FM) is still not decoded.
- **Several radios at once from one dongle.** One dongle has one tuning; decoders share it only
  when their frequencies fit in what it is tuned to. The site says Leyline tells you what would
  pause, not that it avoids pausing.
- **The words to avoid** from `site-0.2.md`, and "real-time flight tracker", "radar".

## Images

The site pins the `shots-*` release the owner published on 2026-11-03 for the re-shot window
(every existing asset, now with the third place in the toolbar). The new assets below need scenes
in `site/shots/scenes.yaml` and a second `shots-*` release; until that lands, the Decoders copy
can use `aprs-track.png` and `ais-track.png`, which are re-shot with the table ordered by name.

| asset | what it shows | where | suggested caption |
|---|---|---|---|
| `app-decoders-map.png` | the Decoders place, Aircraft on the map with one aircraft selected and the inspector showing its fields | the Decoders feature | Aircraft on the map, every field each one sent beside it. |
| `app-decoders-table.png` | Aircraft as a table: callsign, altitude, speed, track, squawk, last heard | the Decoders feature, beside the map | A table of what was heard, by name. |
| `app-waterfall-names.png` | the Radio place on 2 m with APRS running: station names on the waterfall rows they came from, the decoding row in the sidebar | the Decoders feature, or the app section | Decoded callsigns, on the waterfall where they were heard. |
| `app-move-radio.png` | "Move the radio?" before Scan band on 2 m, naming the APRS decoder on 144.390 MHz that the sweep would pause | the sharing feature | Before you move the radio, it says what stops. |
| `ley-dry-run.png` | with APRS running, `ley decode aprs --dry-run` saying it would share the capture and retune nothing | Ways, or the sharing feature | Ask first: --dry-run says what would happen. |

The scenes play recordings, and a file radio tunes only where its recording was made, so two
assets differ from the first plan. Decoders' "Take the radio?" asks only when Start would retune
the radio, which no recording can reach, so the sharing picture is the Radio's "Move the radio?"
(`app-move-radio.png`), the same question from the other side. For the same reason `ley tune`
off the recording fails as out of range before any claim is weighed, so `ley-dry-run.png` shows a
dry run that shares, not a refused tune.

Alt text comes from `shots.json`, ending "Simulated signals." as before: the aircraft are the
synthetic `scene_adsb` fixture, and a caption must not present them as real traffic.

## The download

Leyline 0.3.0, tag `v0.3.0`, Apple silicon, macOS 26 or later, already served from `/updates/`
since PR #7. The `/download` page reads the pinned release and needs no change.
