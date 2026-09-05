# Using `ley` — a task-by-task guide

`ley` is the command-line client of the Leyline daemon, the background process that owns your SDR
and does all the radio work. This guide walks the V0 stories from `docs/sdr-user-stories.md` in
the order a newcomer meets them. It is written from `ley`'s own help texts (a golden-file test
keeps them from drifting), so when a section is short, the longer explanation is one command
away: `ley help squelch`, `ley help frequencies`, `ley help modes`, `ley help gain`,
`ley help presets`, `ley help glossary`, `ley help scripting`, `ley help roadmap`. Every
transcript below was recorded against the contract fake daemon; ids, model names and levels
will differ on your machine.

Three words you will meet: a **capture** is a radio tuned to a band; a **channel** is one
station picked out of a capture (frequency, mode, squelch); a **sink** is where the audio goes.
`ley tune` makes all three in one go. `ley help glossary` has the rest.

## Orientation: bare `ley`

Run `ley` with no arguments. On a terminal it prints where things stand and the next two or
three commands chosen from that state; piped, it prints the command list; `--json` points you at
`ley state --json`. It exits 0 in every state, including "daemon not running".

```console
$ ley
Daemon    daemon fake-0.1 pid 4242 up 46s socket /tmp/leyline/d.sock
Devices   Generic RTL2832U (R820T) (rtlsdr, serial 00000001) in use, tunes 24.000 MHz-1.766 GHz
Playing   146.620 MHz NFM, squelch -80.0 dB, active (chan_01M1S9VA2F5E5G6KK85YNJQ7MS)

Next:
  ley set squelch -40          mute the audio below a level (or: auto)
  ley set gain 30              change the radio's gain (or: auto)
  ley spectrum                 see the band around what is playing
  ley state                    everything the daemon knows
```

This screen is the placeholder for the V0.5 dashboard, which will take over the terminal when
you run bare `ley` on a TTY.

## 1. See your radio

Start the daemon once, then ask it what it can see.

```console
$ ley daemon start
started leylined (pid 4242); check with: ley daemon status

$ ley devices
ID                              DRIVER  MODEL                     SERIAL    STATE      RANGE                 RATES                GAIN
dev_01M1S9TR56S46QTCK0SZS2YPJA  rtlsdr  Generic RTL2832U (R820T)  00000001  AVAILABLE  24.000 MHz-1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0..49.6dB(auto)
```

RANGE is what the radio can tune; RATES is how wide a band it can take in at once; GAIN lists the
amplifier stages `ley set gain` adjusts. Row numbers from this list work wherever a device id is
accepted (`ley tune 146.52 --device 2`). An empty list on a terminal is followed by a checklist
(plugged in? does `rtl_test` see it? does anything else have it open? what does `ley daemon logs` say?). `ley devices --watch`
prints a line when a radio is plugged in or removed.

The daemon keeps running after you close the terminal; `ley daemon status` says whether it is
answering (exit 3 when not), `ley daemon stop` stops it, and on macOS `ley daemon install`
starts it at login.

## 2. Hear a station

Give `tune` a frequency. A bare number is MHz; add a unit to be exact (`1010k`, `146520000`);
or give a preset name (`noaa`, `calling`, `marine16`, `guard` — `ley help presets`). Everything
else is chosen for you and printed, so a wrong guess is visible rather than silent.

```console
$ ley tune 146.52
using NFM: 2 m amateur band default
Listening to 146.520 MHz (NFM, 2 m amateur) on Generic RTL2832U (R820T), gain auto. Squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS). Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum
146.520 MHz NFM  signal -39 dBFS  audio
```

What was decided, and how to override it:

- **Mode** (how the signal is decoded) comes from the band: NFM on 2 m, WFM on FM broadcast, AM
  on airband, and so on; outside every band it is NFM and says so. `--mode` overrides; `fm`
  picks WFM on the broadcast band and NFM elsewhere, `ssb` picks USB at and above 10 MHz and LSB
  below. `ley help modes` explains which one to use where.
- **Squelch** (mute the audio while the signal is weaker than a level) defaults to `auto` for
  voice modes: `tune` reads one row of the daemon's spectrum, takes the band's noise floor and
  sits 10 dB above it. `--squelch -50` sets a level (dBFS: 0 is the loudest the radio can hear,
  the floor depends on gain; the banner prints it), `--squelch off` never mutes. If no spectrum row arrives
  within two seconds squelch stays off and the banner says so. `ley help squelch`.
- **Bandwidth** (`--bw`, a bare number is kHz) and **volume** (`--volume 50%`) have the mode's
  usual values. Gain starts on auto; `ley help gain`.

The last line is a live meter: the signal level, and whether audio is playing or `muted,
waiting for a signal`. Ctrl-C stops and removes the channel (exit 0).

```console
$ ley tune noaa                     # NOAA weather channel 1 (162.550 MHz); try noaa2..7
$ ley tune 101.1 --mode fm          # FM broadcast; fm means WFM here
$ ley tune 7.040 --mode lsb         # 40 m amateur band, lower sideband
$ ley tune 162.55 --squelch -50 --volume 50%
```

## 3. Adjust it while it plays

Leave `tune` running and use `set` from another terminal. With no arguments it shows the
current settings; with a parameter and a value it changes one thing and reports the value the
radio actually applied.

```console
$ ley set
channel chan_01M1S9VA2F5E5G6KK85YNJQ7MS on Generic RTL2832U (R820T)
  frequency  146.520 MHz (2 m amateur)
  mode       NFM
  bandwidth  12.500 kHz
  squelch    -80 dBFS
  gain       auto
  volume     100%
change one with: ley set squelch -50 · ley set gain 30 · ley set freq 146.62

$ ley set squelch -45
squelch → -45 dBFS on 146.520 MHz NFM (channel 1, chan_01M1S9VA2F5E5G6KK85YNJQ7MS)

$ ley set squelch auto
squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS)
squelch → -80 dBFS on 146.520 MHz NFM (channel 1, chan_01M1S9VA2F5E5G6KK85YNJQ7MS)

$ ley set gain 30
gain → 29.7 dB on the radio (TUNER)

$ ley set freq 146.62
frequency → 146.620 MHz NFM (channel 1, chan_01M1S9VA2F5E5G6KK85YNJQ7MS)
```

Note the gain line: you asked for 30, the radio has 29.7, and that is what is printed. The
parameters are `freq` (or `frequency`), `mode`, `bw` (or `filter`), `squelch`, `gain` (with
`--element` for radios that have more than one stage) and `volume`; `ley set --help` lists the
forms each accepts. A wrong parameter name or value is refused before anything reaches the
daemon (exit 2), with the accepted forms in the message — `ley set squelch 5`, for example, explains that levels are dBFS and 0 is the
loudest, so try `-40` or `auto`.

Which channel does `set` change? The only active one; among several, the one a `ley` command
made when there is exactly one such, and `set` says which; otherwise it lists them and asks
(see [Two channels](#5-two-channels-on-one-radio)).

## 4. See the band

`spectrum` draws the band as a bar chart — left to right is frequency, taller is louder — and
lists the loudest bins so you can read a frequency straight off. Without a frequency it shows
the band the radio is already tuned to, which is the useful form while `tune` is running.

```console
$ ley spectrum
146.520 MHz, span 2.400 MHz (145.320 MHz to 147.720 MHz), 1024 bins of 2.344 kHz, floor -100 dB
 -41 |                                   #
 -47 |                                   #
 -54 |                                   #
 -60 |                                   #
 -67 |                                   #
 -73 |                                   #
 -79 |                                   #
 -86 |                                   #
 -92 |                                   #
 -99 |#################################################################
     +-----------------------------------------------------------------
      145.320 MHz                146.520 MHz                147.720 MHz
loudest bins: 146.622 MHz -41 dB
```

A bin is one narrow slice of frequency (here 2.344 kHz); the floor is the median bin, which is
what `auto` squelch measures against. With a frequency (`ley spectrum 101.1`) the radio must be
free or already covering it; a capture is created for the run and removed on exit. When other
channels are listening on a band that does not cover the frequency, `spectrum` refuses to move
the radio and says so; `--retune` moves it anyway (they fall silent). `--watch` (`-w`) keeps
redrawing until Ctrl-C, `--span 200k` narrows the view, `--bins 2048` sharpens it, `--width 72`
fits a narrow terminal. The loudest bins are just that — only bins at least 6 dB above the floor
are listed, and a quiet band says `loudest bins: nothing above the floor`; `spectrum` does not
call them signals or guess bandwidths; `scan` will do detection later (`ley help roadmap`).

## 5. Two channels on one radio

A capture is a wide slice of the band (2.4 MHz on an RTL-SDR), so one radio can feed several
channels at once. `--persistent` leaves a channel running after the command exits and prints
the ids scripts need; a second `tune` inside the same band reuses the capture instead of
fighting for the device.

```console
$ ley tune 146.52 --persistent --no-audio
using NFM: 2 m amateur band default
capture cap_01M1S9VA2F2ZN0M4ZHKR7T6X42
channel chan_01M1S9VA2F5E5G6KK85YNJQ7MS
adjust with: ley set squelch -40 --channel chan_01M1S9VA2F5E5G6KK85YNJQ7MS

$ ley tune 146.62 --persistent --no-audio
using NFM: 2 m amateur band default
capture cap_01M1S9VA2F2ZN0M4ZHKR7T6X42
channel chan_01M1S9VB621DNPDV56D9NRD6NG
adjust with: ley set squelch -40 --channel chan_01M1S9VB621DNPDV56D9NRD6NG

$ ley set squelch -40
ley: 2 channels are playing; pick one with --channel:
  1  146.520 MHz NFM, chan_01M1S9VA2F5E5G6KK85YNJQ7MS (cli:ley)
  2  146.620 MHz NFM, chan_01M1S9VB621DNPDV56D9NRD6NG (cli:ley)
e.g. ley set squelch -40 --channel 2

$ ley set squelch -40 --channel 2
squelch → -40 dBFS on 146.620 MHz NFM (channel 2, chan_01M1S9VB621DNPDV56D9NRD6NG)

$ ley stop 2                        # remove one channel; the radio stays tuned
stopped 146.620 MHz NFM (channel 2, chan_01M1S9VB621DNPDV56D9NRD6NG); the radio stays tuned, free it with: ley stop --all

$ ley stop all                      # remove everything on the radio and free it
stopped 1 channel and freed Generic RTL2832U (R820T) (dev_01M1S9TR56S46QTCK0SZS2YPJA)
```

A third `tune` outside the band the capture covers (`ley tune 101.1` while 146.52 plays) is
refused rather than silencing the channels already on it: `the radio is on 146.520 MHz with
1 channel listening; retuning to 101.100 MHz would silence it. Add --retune to move it anyway,
or free it with: ley stop --all`. `--retune` (on `tune` and `spectrum`) moves the radio and the
others fall silent; a capture with no active channels is retuned without asking, and `tune`
says so. `--gain 30` (or `auto`) on `tune` and `play` sets the receiver gain once the radio is
tuned, and the banner shows the value the radio applied.

`--channel`, `--capture` and `--device` all accept the same selectors: a full id, an id prefix,
the row number from the printed list (`ley state`, `ley devices`) or a frequency
(`--channel 146.62`); a selector that matches nothing, or more than one thing, lists the rows
(`1  chan_…  146.620 MHz NFM`) to pick from. Scripts should use full ids. `ley state` shows every
capture, channel and sink with its owner; a persistent channel lives until the daemon restarts or
something removes it (`ley stop`, `ley devices detach` for playback devices; the app or an agent
for its own).

## 6. Play a recording

`play` attaches an IQ recording (a `.cf32` file: the raw samples a radio produced) as a pretend
radio and tunes on it exactly as `tune` would, so `set` and `spectrum` work on it unchanged. No
hardware is needed; the `fixtures/` directory has generated signals with known content.

```console
$ ley play fixtures/nfm_tone.cf32
playing nfm_tone.cf32 as device dev_01M1S9W2Y0CESFVYYGNM805N9P
using NFM: the recording's sidecar says NFM
Listening to 146.620 MHz (NFM, 2 m amateur) on FilePlaybackDevice, gain unknown. Squelch off. Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum
146.620 MHz NFM  signal -63 dBFS  audio
```

The frequency and mode come from the `.json` sidecar beside the file; `--freq` and `--mode`
override, `--loop` starts over at the end. The pretend radio is removed on exit unless
`--persistent`; then `ley devices` lists it as a `file` device, `ley stop` removes the channel
and `ley devices detach <id>` (or its row number) removes the pretend radio together with its
channels.

Recording is not in this build: `ley record` exits 2 and says so (Milestone C.12;
`ley help roadmap`).

## 7. For scripts and agents

`ley help scripting` is the authoritative short version; the contract is `docs/interfaces.md`.

- **`--json` on any command** prints the proto3 JSON mapping of the `leyline.v1` messages
  (lowerCamelCase keys, 64-bit integers as strings, one object per line for streams).
  Everything meant for a person — banners, `using NFM: ...`, the meter — goes to stderr, so
  stdout is always parseable.
- **`ley state --json`** is the snapshot (a `GetStateResponse`): devices, captures, channels,
  sinks, activity. Read it instead of scraping tables.
- **`ley fft`** is the number feed behind `spectrum`: rows of bin levels across the band,
  `--rate` times a second, `--count` rows or until Ctrl-C, `--format json` or `bin`. `spectrum
  --json` emits one row with a `peaks` list. These rows are bulk data with no proto message,
  so their shape (`{seq, sample_index, center_hz, span_hz, bins}`) is the one documented
  exception to the proto3 rule.
- **Defaults meant for people are off for scripts.** Under `--json` or `--persistent` squelch
  defaults to `off` (pass `--squelch auto` or a level); pass `--mode` explicitly rather than
  relying on band defaults; give frequencies with a unit (`146.52M`).
- **Exit codes:** 0 ok (including Ctrl-C during a live phase); 1 the daemon refused or failed,
  and the message keeps the daemon's stable code in brackets (`ley: <message> [DEVICE_BUSY]`)
  unless `ley` has a plainer sentence for it; 2 usage error — a bad flag or argument, an unknown
  verb, setting, value form or preset — nothing was sent to the daemon; 3 the daemon is not
  running (any verb); 130 interrupted before the live phase began. Error lines read
  `ley: <what went wrong>. <what to do next>`.

```console
$ ley tune 146.52M --mode nfm --persistent --json        # ids on stdout, prose on stderr
$ ley set squelch -40 --channel chan_01J... --json
$ ley fft --freq 101.1M --rate 10 | jq .bins[0]
$ ley spectrum 101.1 --json                              # {seq, sample_index, center_hz, span_hz, bins, peaks}
$ ley daemon status --json                               # DaemonInfo; exit 3 and no pid when not running
```

## 8. When things go wrong

Every error is one line that says what happened and what to run next. The ones a newcomer
meets first:

| you see | what it means | do this |
|---|---|---|
| `ley: the Leyline daemon is not running (socket ...). Start it with: ley daemon start` (exit 3) | nothing is answering on the socket | `ley daemon start`; if it says a stale socket is in the way, `ley daemon stop && ley daemon start` |
| `no radio found. Check, in order:` under an empty `ley devices` table | the daemon runs but sees no radio | the checklist: plugged in (try another port or cable), `rtl_test` sees it, nothing else has it open, `ley daemon logs` for driver errors |
| `ley: 1.800 GHz is outside what Generic RTL2832U (R820T) can tune (24.000 MHz – 1.766 GHz); did you mean 1.800 MHz (160 m amateur)? write 1800k` | a bare number is MHz, so `1800` was 1800 MHz | type the unit: `ley tune 1800k` |
| `... this device cannot tune below 24.000 MHz; HF needs an upconverter or a device with direct sampling` | the frequency is real, the radio just cannot reach it | an upconverter, or a radio that can |
| `ley: frequency: "146,52" contains a comma; use a dot for decimals (146.52) or a unit (146520k)` | commas are refused | `ley tune 146.52` |
| `ley: preset: unknown name "noa"; did you mean noaa1, noaa2, noaa3? (ley help presets lists them all); or give a frequency such as 146.52 (MHz)` | not a preset | `ley tune noaa`, or the frequency |
| `ley: "foo" is not a setting. Settings: ...` | `set` got a parameter it does not know; the list follows | pick one from the list |
| `ley: squelch: "5" is above full scale; levels are dBFS, 0 is loudest; try -40 or auto` | squelch levels are negative numbers | `ley set squelch -40` or `auto` |
| `ley: 2 channels are playing; pick one with --channel: ...` | several channels, none clearly yours | `ley set squelch -40 --channel 2` |
| `ley: no channel matches "3" (a full id, id prefix, row number or frequency); pick one:` then rows `1  chan_…  146.520 MHz NFM` | the selector fit nothing; the rows are what exists | pick a row number or id from the list |
| `ley: the radio is on 146.520 MHz with 1 channel listening; retuning to 101.100 MHz would silence it. Add --retune to move it anyway, or free it with: ley stop --all` | another channel rides on the capture and your frequency is outside its band | `ley tune 101.1 --retune`, or `ley stop all` first |
| `1010 MHz is not a band I know; for 1010 kHz AM broadcast type 1010k` (a warning, tune continues) | a bare number is MHz, and 1010 MHz is nothing in particular | `ley tune 1010k` if you meant AM broadcast |
| `ley: the radio is busy: another client holds it; ley state shows who, and ley tune reuses a capture when the frequency fits` | another client holds the radio on a band that does not cover your frequency | `ley state` shows who; tune inside its band, or stop it |
| `ley: unknown command "tunee" for "ley"` with `Did you mean this? tune` (exit 2) | a typo in the verb | take the suggestion |
| full-scale static as soon as `tune` starts | squelch is off (scripts, `--persistent`, non-voice modes, or no spectrum row arrived) | `ley set squelch auto` |
| `record`, `scan`, `watch` exit 2 with "not implemented yet" | planned verbs | `ley help roadmap` says what to use today |

When the message is not enough: `ley state` is the whole picture, `ley daemon logs -f` follows
the daemon, and `ley --socket PATH` talks to a daemon on another socket.
