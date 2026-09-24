# Using `ley`

`ley` is the command-line client of the Leyline daemon, the background process that owns your SDR
and does all the radio work. This guide walks the V0 stories from `docs/plans/user-stories.md` in
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

Run `ley` with no arguments. It prints where things stand and the next two or three commands chosen
from that state — coloured on a terminal, the same words plain when piped, so `ley | tee log`
records what a screenshot would show; `ley --help` is the command list and `--json` prints exactly
what `ley state --json` prints. The screen exits 0 in every state, including "daemon not running";
`ley --json` fails the way `ley state --json` does when there is no daemon to ask.

```console
$ ley
Daemon    daemon fake-0.1 pid 4242 up 46s socket /tmp/leyline/d.sock
Devices   Generic RTL2832U (R820T) (rtlsdr, serial 00000001) in use, tunes 24.000 MHz to 1.766 GHz
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
MODEL                     STATE      RANGE                    RATES                GAIN
Generic RTL2832U (R820T)  AVAILABLE  24.000 MHz to 1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0–49.6 dB auto
ley devices --wide  adds DRIVER, SERIAL, ID
```

MODEL and STATE come first because they show whether the radio is usable; RANGE is what the radio
can tune, RATES is how wide a band it can take in at once, and GAIN lists the amplifier stages
`ley set gain` adjusts. `ley devices --wide` adds the driver, serial and full device id (and any
column too wide for the terminal), and `--json` always carries all of them. Row numbers from this
list work wherever a device id is accepted (`ley tune 146.52 --device 2`). An empty list prints
`(no radios found)`, and on a terminal a checklist follows
(plugged in? does `rtl_test` see it? does anything else have it open? what does `ley daemon logs` say?). `ley devices --watch`
prints a line when a radio is plugged in or removed.

### A radio on another machine

A dongle need not be in this Mac. Run `rtl_tcp -a 0.0.0.0` on the machine it is plugged into (a Pi
with the antenna on the roof, say) and tell the daemon where it is:

```console
$ ley devices attach rtltcp pi.local:1234
device dev_01J8Z6K2T7QF3N9WX4RBV5MCDE
attached rtl_tcp pi.local:1234 (R820T) as dev_01J8Z6K2T7QF3N9WX4RBV5MCDE; the daemon remembers it. Forget it with: ley devices detach 2
```

From here it is a radio like any other: it has a row in `ley devices`, and `ley tune`, `ley scan`
and the rest take it with `--device 2`. The daemon remembers it across restarts, so this is done
once; `ley devices detach 2` removes it and stops it coming back. Attaching connects once, so a
host that cannot be reached is an error on the spot and nothing is remembered — a radio never
reached is usually a typo. A radio that drops later is not an error: it goes DISCONNECTED and the
daemon reconnects when it answers again. Attaching an endpoint twice is not an error either; the
second time prints the radio the daemon already has.

The daemon keeps running after you close the terminal; `ley daemon status` reports whether it is
answering (exit 3 when not), `ley daemon stop` stops it, and on macOS `ley daemon install`
starts it at login. Status is one line whose first word is the daemon's state:

```console
$ ley daemon status
running  0.1.0-dev  pid 4242  up 46s  socket /tmp/leyline/d.sock
```

`ley daemon logs` prints the daemon's log. On a terminal it re-lays each line it recognises into
columns — the clock (the date on its own line when it changes), the level, one subsystem token,
then the message — and colours the level; piped, and for any line it does not recognise, the log
comes through byte for byte, so `ley daemon logs | grep` keeps working. `-f` marks where the
backlog ends before it follows.

## 2. Hear a station

Give `tune` a frequency. A bare number is MHz; add a unit to be exact (`1010k`, `146520000`);
or give a preset name (`noaa`, `calling`, `marine16`, `guard` — `ley help presets`). Everything
else is chosen for you and printed, so you can see a wrong choice.

```console
$ ley tune 146.52
using NFM: 2 m amateur band default
Listening to 146.520 MHz (NFM, 2 m amateur)
Radio Generic RTL2832U (R820T), gain auto
Squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS).
Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set gain 30 · ley spectrum
█████████░░░▲░░░  146.520 MHz NFM  signal -39 dBFS  audio
```

What was decided, and how to override it:

- **Mode** (how the signal is decoded) comes from the band: NFM on 2 m, WFM on FM broadcast, AM
  on airband, and so on; outside every band it is NFM and says so. `--mode` overrides; `fm`
  picks WFM on the broadcast band and NFM elsewhere, `ssb` picks USB at and above 10 MHz and LSB
  below. `ley help modes` explains which one to use where.
- **Squelch** (mute the audio while the signal is weaker than a level) defaults to `auto` for voice
  modes: `tune` reads one row of the daemon's spectrum, takes the band's noise floor and sets the
  threshold 10 dB above it. `--squelch -50` sets a level (dBFS: 0 is the loudest the radio can hear,
  the floor depends on gain; the banner prints it), `--squelch off` never mutes. If no spectrum row
  arrives within two seconds squelch stays off and the banner says so. `ley help squelch`.
- **Bandwidth** (`--bw`, a bare number is kHz) has the mode's usual value. **Volume**
  (`--volume 50%`) defaults to 100% for every mode. Gain starts on auto; `ley help gain`.

The last line is a live meter: on a terminal a bar scaled from -90 dBFS to 0 with a marker at
the squelch threshold, then the signal level and whether audio is playing or `muted, waiting for
a signal`. It is written to stderr and redrawn in place; redirected or piped it loses the bar and
prints one whole line a second instead, so a `tee`d session stays readable. Ctrl-C stops, removes
the channel and reports what happened to the radio (exit 0).

On an NFM channel the daemon also listens under the voice for a squelch code, and `tune` prints
one line above the meter when it finds one and again when it changes: `PL  100.0 Hz  dev 620 Hz
tone/band 18 dB` for a CTCSS tone, `DCS  023  dev 550 Hz` for a DCS code, in the three octal
digits a radio's menu shows. A move from a PL tone to a DCS code is a change and prints. Nothing is
printed when the code stops, or on a channel that never had one. A DCS code sent inverted is the
same bit stream as another code sent normal (023 inverted is 047 normal), and the daemon names the
normal reading, so a radio set to 023 inverted shows `DCS  047`.

Two problems the radio's numbers show get a line of their own. When nothing on the band stands
15 dB above the floor, the banner says so once, at tune (`Nothing is above the noise: …`), and
never again in the session. When the radio clips (the daemon counts samples at the converter's
rails), one line appears once the clipping has lasted a second, with the count that raised it
and the thing to try: `The radio is clipping: 20494 of 655360 samples (3.1 %) hit the
converter's rails. Lower the LNA or VGA gain.` Nothing more is printed while it goes on, and
nothing when it stops; after two seconds clean, the next second of clipping prints again. On a
radio with several gain stages the line names the ones above their lowest, and "at the lowest
gain" means every stage you can set is at the bottom; the HackRF's AMP, an on/off switch, does
not count.

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
on the radio
  gain       auto
through the speakers
  volume     100%
change one with: ley set squelch -50 · ley set gain 30 · ley set freq 146.62

$ ley set squelch -45
squelch -80 dBFS → -45 dBFS on 146.520 MHz NFM (channel 1)

$ ley set squelch auto
squelch auto → -80 dBFS (10 dB above the band's noise floor, -90 dBFS)
squelch -45 dBFS → -80 dBFS on 146.520 MHz NFM (channel 1)

$ ley set gain 30
gain auto → 29.7 dB on the radio (TUNER)

$ ley set freq 146.62
frequency 146.520 MHz → 146.620 MHz on channel 1 (NFM)
```

In the gain line, you asked for 30, the radio has 29.7, and that is what is printed. The
parameters are `freq` (or `frequency`), `mode`, `bw` (or `filter`), `squelch`, `gain` and
`volume`; `ley set --help` lists the forms each accepts. `gain` takes what `--gain` takes on every
verb (`ley help gain`): on a radio with several stages a bare value sets the first, and
`ley set gain LNA=0,VGA=20` sets each stage named, in that order, and the line names every stage
it set (`gain LNA 8 dB, VGA 20 dB → LNA 0 dB, VGA 20 dB on the radio (cap_…)`). A wrong
parameter name or value is refused before anything reaches the daemon (exit 2), with the accepted
forms in the message — `ley set squelch 5`, for example, explains that levels are dBFS and 0 is
the loudest, so try `-40` or `auto`.

Which channel does `set` change? The only active one; among several, the one a `ley` command
made when there is exactly one such, and `set` says which; otherwise it lists them and asks
(see [Two channels](#5-two-channels-on-one-radio)).

## 4. See the band

`spectrum` draws the band as a bar chart — left to right is frequency, taller is louder — and
lists the loudest bins, with how far the strongest sits above the noise, so you can read a
frequency straight off. Without a frequency it shows the band the radio is already tuned to,
which is the useful form while `tune` is running.

```console
$ ley spectrum 146.62
146.520 MHz  span 2.400 MHz  floor -90 dBFS  145.320 MHz to 147.720 MHz
1024 bins of 2.344 kHz
 -20 dBFS│                                     ▄▇
         │                                     ██
         │                                     ██
         │                                     ██
         │                                     ██
 -59     │                                     ██
         │                                     ██
         │                                     ██
         │                                     ██
         │▃▁▁▂─▄▄─▁▄▃▁▆▁▁▃▁▄▂─▂▂▁▂▄▂▁▄─▆▃▁▁▃▃▁▂██─▁─▁▃─▂▄▃▃──▃▄▄▁▃▅▁▃─▅──▅▄▁▂▁▁▁
 -85     ──────│─────────────│──────────────│──────────────│─────────────│──────
                                               ▲ 146.620 MHz
          145.500 MHz   146.000 MHz    146.500 MHz    147.000 MHz   147.500 MHz
peak    146.622 MHz  -21 dBFS  69 dB above the floor
tune with: ley tune 146.622
```

The chart reads from the noise up: the rule along the bottom is the noise line, the dim stipple
on it is noise, and anything that stands clear of it is worth looking at. The level axis is
labelled at three points with `dBFS` once, the frequency axis carries a tick per label, and the
`▲` marks the frequency you asked for. On a terminal without UTF-8, or with `--ascii`, the same
chart is drawn with `#` and `-`; with colour, columns near the floor are dim and loud ones green.

A bin is one narrow slice of frequency (here 2.344 kHz); the floor is the median bin, which is
what `auto` squelch measures against. With a frequency (`ley spectrum 101.1`) the radio must be
free or already covering it; a capture is created for the run and removed on exit. When other
channels are listening on a band that does not cover the frequency, `spectrum` refuses to move
the radio and says so; `--retune` moves it anyway (they fall silent). `--watch` (`-w`) keeps
redrawing until Ctrl-C, `--bins 2048` sharpens it, `--width 72` fits a narrow terminal. `--span`
is the width of the band shown, which is the capture's sample rate: for a fresh capture `ley`
snaps it to the nearest rate the radio supports and says so (`showing 250.000 kHz, the closest
this radio can do to 200.000 kHz`); when the radio is already capturing at a different width,
`spectrum` exits 2 naming the current width — drop `--span`, ask for that width, or free the
radio with `ley stop all`. When it draws a capture that is already tuned somewhere else it
says which centre it is showing (`showing the capture at 146.520 MHz, which covers
146.000 MHz`). The loudest bins are only that: only bins at least 15 dB above the
floor are listed, one entry per carrier rather than a padded five, and a quiet band says
`peak    nothing above the floor; the band looks quiet` (and draws the chart cold to match);
`spectrum` does not call them signals or guess bandwidths; `ley scan` (section 5) is the verb
that does, with a threshold calibrated to a false-alarm rate rather than to a constant. `--watch` holds the dB scale for the run
(it moves once, and says so, if something louder arrives), keeps a faint max-hold trace
where a column still stands clear of the live trace (so a transient is marked and noise fades
away), and ends with a status line — `frame 12  2.0/s  6 s elapsed`, or
`waiting for data` when the daemon has sent nothing, which is also what a one-shot says on
stderr before giving up.

## 5. Find what is on a band

`ley spectrum` draws a band and lists its loudest bins. `ley scan` answers the next question:
sweep a range, and list the carriers that are really there.

```console
$ ley scan 144M..148M
sweeping 144.000 MHz to 148.000 MHz
step 4/7, 2 found
FREQUENCY    WIDTH            SNR (dB)  SEEN  BAND
145.230 MHz  11.400 kHz             21   8/8  2 m amateur
146.520 MHz  11.900 kHz             34   8/8  2 m amateur (calling)
146.940 MHz  under 2.344 kHz         9   1/8  2 m amateur
3 signals, floor -88 dBFS per 2.344 kHz bin
  ley listen 146.520
```

The sweep runs in the daemon, which owns the radio for the few seconds it takes. It will not
interrupt somebody who is listening: it reports who has the radio instead, and `--take-over`
overrides that. The radio goes back where it was afterwards, at the gain it was on.

**`SEEN` is how often it was detected.** 8/8 means the signal was there every time scan looked at
that frequency; 1/8 means it caught one burst. No row is filtered out on that count -- an
intermittent packet is exactly what you might be scanning for -- so read it rather than trusting a
row on its own. What a scan finds is what is sitting on the band while it looks; for how busy a
frequency is over time, use `ley phosphor`.

**`WIDTH` is an equivalent rectangular width**: the width a flat signal with the same spread would
have. It does not grow with signal strength the way the width of a peak above a threshold does, and
below the analysis resolution it says `under 2.344 kHz` rather than quoting a number it cannot
measure.

**The floor is per bin**, and that is why it reads far lower than the level `ley tune`'s meter shows
for the same signal: a voice channel is thousands of bins wide, and each bin holds a thousandth of
the noise. The threshold over it is not a constant -- it is computed from how many spectrum rows
were averaged and how many bins the sweep looked at, so that a whole sweep produces on average about
0.1 false signals. `docs/design/scan.md` has the measurements.

`--band 2m` sweeps a named band; a range positional never takes a band name, because `2m` is 2 MHz
everywhere else in `ley`. `--dwell 1000` looks longer at each stop and finds weaker signals.
`--sort snr` puts the loudest first. `--json` prints one `Scan` object and nothing before it.

A sweep belongs to the terminal that started it, so Ctrl-C there stops it and hands the radio back.
From anywhere else, **`ley jobs`** lists what the daemon is working on -- today that means sweeps --
and `ley jobs cancel 1` stops the job on that row (an id works too, which is what a script that
started a scan with `--json` has). The daemon keeps the last sixteen finished jobs, so `ley jobs` is
also where to see how the last scan ended.

```console
$ ley jobs
WHAT  RANGE                       STATE    AGE  DETAIL
scan  144.000 MHz to 148.000 MHz  running  3 s  step 4/7, 2 found
$ ley jobs cancel 1
job_01JB2M3K4P5Q6R7S8T9V0WXYZA cancelled
```

## 6. Watch a band over time

`spectrum` and `scan` both show what is on the band right now. Two more views show history
instead, and answer different questions.

**`ley waterfall`** draws the band as a scrolling map: left to right is frequency, down the screen
is time, newest row at the bottom, a denser cell for a stronger signal. It is the only view that
answers *is that signal always there, or did it start and stop?* — a birdie draws a dead straight
line, a transmission draws a block with a beginning and an end, a pager burst draws a dash, and none
of the three can be told apart in a single `spectrum` frame. Each row covers the whole interval
since the last one, not an instant: the daemon takes as many looks as the interval allows and each
bin keeps the loudest of them, which is what the note on stderr counts, so a transmission shorter
than a row still shows up. The dB scale is chosen from the first rows and held for the run so
shading stays comparable across it. At a wide span each column covers tens of kHz — a map of where
energy is, not a picture of a signal's shape — so narrow `--span` to see shape.

```console
$ ley waterfall 146.52              # is the local repeater busy?
$ ley waterfall 162.55 --span 250k  # narrow: a channel at a time
$ ley waterfall --rate 4            # four rows a second
$ ley waterfall 101.1 --count 40    # forty rows, then stop
```

**`ley phosphor`** draws the band the way `spectrum` does — frequency across, level up — but shades
each cell by how often that frequency has sat at that level, not by where it is right now. Bright
means usual, faint means it happens but rarely. That answers *what is here that I keep missing*: a
signal that transmits for 80 ms once a minute is invisible on a live spectrum and obvious here,
because the display accumulates over time instead of trying to catch the moment — a steady carrier
piles into one thin line, noise spreads into a band, an intermittent burst leaves a faint mark
at its frequency. Counts fade on a half-life (`--half-life`, seconds, default 20) so "usual"
means "usual lately", not "at some point since you started" — the header states the window. Use
it when you suspect something is on a band but never see it: ISM and paging bands, telemetry,
anything bursty.

```console
$ ley phosphor 910                      # what lives on the 915 MHz ISM band?
$ ley phosphor 462.5625 --half-life 60  # a slower fade, for rare traffic
$ ley phosphor 144.39 --span 250k       # narrow in on one channel
```

Both share `spectrum`'s device and framing flags (`--span`, `--band`, `--bins`, `--device`,
`--retune`, `--width`) plus `--rate` (rows or redraws a second) and `--count` (stop after N, default
runs until Ctrl-C). Neither lists carriers the way `scan` does.

## 7. See the waveform

`ley scope` draws the demodulator's output: one window of samples a frame, fitted to the signal top
to bottom, redrawn where it stands. It answers two questions the level meter and the spectrum
cannot, because both of those are measured before demodulation. The first is *what does this mode
actually do* — FM voice through the AM detector is a flat line with ripple, a carrier in CW is a
sine, NFM voice looks like voice, and `ley set mode am` from another terminal changes the picture
while you watch. The second needs the other tap.

`--tap audio` (the default) is what the speakers get, after the high-pass, de-emphasis and gain
control. `--tap demod` is the detector's own output before any of that, and on an NFM channel that
is where the CTCSS (PL) tone lives: the audio chain high-passes at 300 Hz precisely to remove it,
so a picture of what you hear cannot show it. The demod tap also keeps drawing while the squelch is
closed, so you can see what the transmitter sends between words, and its DC offset is
the tuning error, which the header reads out in hertz against the deviation the top of the trace
stands for. That deviation is the channel's own, which the header names: a 12.5 kHz NFM channel
cannot carry more than ±2.5 kHz, a 25 kHz one goes to ±5 kHz, and WFM is broadcast's ±75 kHz.

```console
$ ley scope 145.23 --tap demod --window 10
145.230 MHz NFM  tap demod  window 10 ms  peak -4 dBFS  rms -9 dBFS  scale ±1
full scale ±2.5 kHz  tuning +50 Hz
PL 100.0 Hz (measured 100.12 Hz, 18 dB, confidence 0.9)
   +1│
     │⠀⢠⢄⠀⠀⠀⠀⠀⠀⣀⡀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⢀⡀⠀⠀⠀⠀⠀⢀⣤⠀⠀⠀⠀⠀⠀⡤⣄
     │⢠⠃⠈⢇⠀⠀⠀⠀⡜⠀⢣⠀⠀⠀⠀⢀⠏⠱⡀⠀⠀⠀⠀⡰⠒⡄⠀⠀⠀⠀⢀⠖⢦⠀⠀⠀⠀⠀⡰⠲⡀⠀⠀⠀⠀⢰⠋⢆⠀⠀⠀⠀⢀⠏⠙⡄⠀⠀⠀⠀⡎⠀⢣⠀⠀⠀⠀⡸⠀⠘⡄
     │⡎⠀⠀⠘⡄⠀⠀⢠⠃⠀⠀⢇⠀⠀⠀⡜⠀⠀⢣⠀⠀⠀⢰⠃⠀⠸⡀⠀⠀⠀⡜⠀⠘⡆⠀⠀⠀⢰⠁⠀⢱⠀⠀⠀⢀⠇⠀⠈⡆⠀⠀⠀⡎⠀⠀⢱⠀⠀⠀⢸⠀⠀⠈⡆⠀⠀⢠⠃⠀⠀⢱
    0│⠀⠀⠀⠀⢣⠀⢀⠎⠀⠀⠀⠘⡄⠀⡸⠁⠀⠀⠈⡆⠀⠀⡎⠀⠀⠀⢣⠀⠀⢰⠁⠀⠀⠸⡀⠀⢀⠇⠀⠀⠀⡇⠀⠀⡜⠀⠀⠀⠸⡀⠀⣰⠁⠀⠀⠀⢇⠀⢠⠇⠀⠀⠀⠸⡀⢀⡎⠀⠀⠀⠀⢇⠀⣸
     │⠀⠀⠀⠀⠀⠳⠞⠀⠀⠀⠀⠀⠳⣠⠃⠀⠀⠀⠀⠸⣄⡼⠀⠀⠀⠀⠘⡄⢠⠇⠀⠀⠀⠀⢣⠀⡼⠀⠀⠀⠀⠸⡄⣰⠁⠀⠀⠀⠀⢣⣠⠇⠀⠀⠀⠀⠘⠦⠎⠀⠀⠀⠀⠀⠑⠞⠀⠀⠀⠀⠀⠘⠒⠃
     │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠈⠀⠀⠀⠀⠀⠀⠈⠉⠀⠀⠀⠀⠀⠈⠉⠁⠀⠀⠀⠀⠀⠈⠁
   -1│
     ─│─────────────│──────────────│──────────────│──────────────│─────────────│
      0 ms        2 ms           4 ms           6 ms           8 ms        10 ms
```

The header's values come from the daemon: the tone comes from the same sub-audible detector `ley
tune` prints, and `scope` never estimates one itself, so the picture and the number can disagree,
and both are shown so you can compare them. Both scales are drawn: the gutter down the left is the
vertical one, the scale the header shows (hertz are the header's tuning line), and the rule beneath
the trace is milliseconds from the start of the frame out to the window length. `--window` (5 to 500
ms, default 40) is the timebase: 40 ms is a syllable of voice, four cycles of a 100 Hz tone, and a
narrower window spreads a 1 kHz note out into a wave. `--trigger auto` starts each frame at a rising
zero crossing when the window repeats steadily, which holds a tone still; `--trigger free` lets the
trace run. On a terminal without UTF-8, or with `--ascii`, the same trace is drawn with three levels
per character.

The default scale is for looking at speech. `--scale auto` fits the trace to the ninetieth
percentile of the frame peaks the last second held, with a little headroom, snapped to a round
number (0.02, 0.05, 0.1, 0.2, 0.5 or 1) so the gutter stays readable. Reading the percentile
rather than the peak is what keeps the picture still through a squelch tail — one frame several
times full scale draws clamped rather than shrinking the next second of speech to a dot — and the
second of hold is what keeps it from resizing between syllables. `--scale full` draws the whole
range the tap can carry instead, which on the demod tap is the channel's whole deviation: a
narrow handheld fills that trace, because full scale there is the ±2.5 kHz its own channel can
carry rather than a number the mode was assigned. `--scale 0.2` fixes it at 0.2. Use `--window 250
--trigger free` to watch the envelope of speech, the shape of the words; `--window 40` with the
trigger left alone to hold a tone still enough to count its cycles.

On the audio tap a closed squelch draws a flat line, because a flat line is what the speaker gets. A
note under the header explains it — `squelch closed: the audio tap is muted; --tap demod shows what
the detector hears` — because a flat trace beneath a header that still names a PL tone otherwise
reads as "the tone is there but my voice is not". Nothing is printed on the demod tap, which the
squelch does not silence.

`scope` takes a frequency, a preset or a channel id the way `listen` does, opens no speakers, and
removes whatever it created on exit; `--rate` (frames a second, at most 20), `--count`, `--width`
and the tune flags behave as they do elsewhere. A raw-IQ channel has no detector, so the daemon
refuses `--tap demod` on one and says why.

`--json` prints the frame statistics and no samples: one object per frame,
`{seq, sample_index, sample_rate, tap, window_ms, peak_dbfs, rms_dbfs, dc, scale, tone_hz}`, where
`scale` is the vertical scale the frame was drawn at and `tone_hz` is absent until the daemon has
reported a tone. A DCS code is not a tone and leaves `tone_hz` absent; the header shows it as
`DCS 023` where a PL would go, and `ley levels` does the same. The samples themselves are
`ley listen --format json`.

## 8. Hear it with your eyes

`ley scope` draws one window of samples — a syllable, a few cycles. Two more views take the same
audio at the two scales either side of it. `ley levels` is an octave-band meter like the one on the
front of a rack unit: the level in each band right now. `ley waveform` is level over time: when
something came through, over seconds or minutes. Neither opens the speakers, both take a frequency,
a preset or a channel id, and both take their squelch state from the daemon's meter. `ley levels`
reads the daemon's audio spectrum and groups its bins into bands on screen, with the peak-hold and
decay; `ley waveform` reads the channel's audio samples and computes each column's peak, RMS and DC
offset on screen.

```console
$ ley levels 145.23 --tap demod
145.230 MHz NFM  tap demod  full scale ±2.5 kHz  squelch open  PL 100.0 Hz
  0 │░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
 -6 │░░░   ░░░   ░░░   ░░░   ▃▃▃   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
    │░░░   ░░░   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-12 │░░░   ░░░   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-18 │░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ███ ─ ░░░ ─ ░░░ ─ ░░░ ─ ░░░ ─ ─ ░░░ ─ ░░░
    │░░░   ▅▅▅   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-24 │░░░   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-30 │▃▃▃   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
-40 │███   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ░░░
    │███   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ░░░   ▁▁▁
-50 │███   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ▄▄▄   ███
-60 │███   ███   ░░░   ░░░   ███   ░░░   ░░░   ░░░   ░░░     ███   ███
    ──────────────────────────────────────────────────────────│─────│────
     63    125   250   500   1k    2k    4k    8k    16k Hz  rms  peak
                                                             -50   -46 dBFS
```

Nine ladders on the standard ISO octave centres, and the master pair —
rms and peak, from the daemon's meter — set apart at the right. That is one still: the bare verb
draws the bands as one row measured them and exits, the way `ley spectrum` does. `ley levels 145.23
-w` is the meter itself, redrawn twenty times a second until Ctrl-C. There a cap hangs above each
bar at the loudest of the last second and a half before it falls, and the bars rise the instant the
level does and fall at 20 dB a second, so a syllable leaves a trail you can read after it has gone.
That shaping is display-only: the two numbers under the master pair are the current row's own, and
`--json` carries the rows before any of it.

While the daemon's squelch is shut every ladder is drawn unlit and the header says `squelch
closed`. Nothing is coming through, and the detector keeps putting out noise behind a shut squelch
that a lit bar would report as sound. Between words the squelch is open, which is why the PL still
stands in the picture above.

The scale is fixed, like a meter's — 6 dB a row from 0 down to −24 dBFS, then 10 dB a row
to −60, held whatever the signal does, so a bar of a given height means the same dB tomorrow — and
the dashed rule across −18 dBFS is the alignment level a speaking voice should sit around. `OVER`
appears above the ladders when the radio is clipping — the daemon counts the samples at the
converter's rails, and a band reading full scale is not that — and stays up for two seconds,
because a clip is over before you have looked up. The header's `radio peak` is the converter's own
peak, the headroom you have left.

The lit 125 Hz bar above is the CTCSS tone. A 100 Hz tone falls in that band
(88 to 177 Hz), and it stands there on `--tap demod`, the detector's own output. Run the same
command with `--tap audio` — what the speakers get — and that bar drops out of sight: the audio
chain high-passes at 300 Hz precisely to remove it. Voice falls in the 250 Hz to 2 kHz bars, hiss
in the 4 kHz and up, mains hum in the 63 Hz one. `--bands third` draws twenty-five third-octave
bands instead of nine, on a terminal at least 100 columns wide.

The other view is the same audio spread out over time.

```console
$ ley waveform 145.23 --squelch -50
145.230 MHz NFM  tap audio  10 s  scale ±1  squelch closed
   +1│                                                                         │
     │                                                                         │
     │█              ███████████████               ███████████████             │
     │█              ███████████████               ███████████████             │
    0│█              ███████████████               ███████████████             │
     │█              ███████████████               ███████████████             │
     │                                                                         │
   -1│                                                                         │
     ─│─────────────│──────────────│─────────────│──────────────│─────────────│
      -10 s       -8 s           -6 s          -4 s           -2 s         -0 s
```

Each column is a slice of audio drawn as the loudest it got, up and down from the centre, filled
the way an editor draws a clip, with the newest at the right under the playhead; the axis counts
seconds back from now. What you are looking for here is shape and timing: how long the
transmissions are, how long the gaps between them, whether one starts strong and fades. A slice the squelch was shut for is left blank rather than
drawn as a flat line, so a gap in the picture is a gap in what came through — above, a squelch at
−50 dBFS is opening and closing on a signal that drifts across it. Silence that did come through
is the centre rule, which is what a live but quiet channel looks like.

`--seconds` sets how much the picture holds, 2 to 120, default 10; a wider terminal buys resolution
rather than more time. `--scale auto`, the default, fits the trace to the signal the way `scope`
does, and `--scale 0.2` fixes it at 0.2. The colour is read against whatever the scale came out at —
the `scale ±n` in the header shows what full colour means — so the loudest thing on screen is hot
and a quiet passage under `--scale 0.1` still has colour in it. On `--tap demod` the DC offset — the
tuning error — is taken out before the envelope is drawn and the header says how much, because
otherwise a mistuned channel draws its whole clip off centre.

Both views carry their frames raw. `ley levels --json` prints one object per spectrum row, before
any of the ballistics: `{seq, sample_index, tap, bands: [{center_hz, db}], rms_dbfs, peak_dbfs,
squelch_open}`, where `rms_dbfs`, `peak_dbfs` and `squelch_open` are `null` until the daemon has
measured a block. `ley waveform --json` prints one object per column as it completes,
`{sample_index, seconds, peak_dbfs, rms_dbfs, squelch_open}`, carrying the same slice the picture
would have drawn at that width — which is what makes `ley waveform --seconds 120 --json` a way to
log when a repeater was busy without drawing anything at all.

## 9. Two channels on one radio

A capture is a wide slice of the band (2.4 MHz on an RTL-SDR), so one radio can feed several
channels at once. `--persistent` leaves a channel running after the command exits and prints
the ids scripts need; a second `tune` inside the same band reuses the capture instead of
claiming the device again.

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
squelch off (audio always on) → -40 dBFS on 146.620 MHz NFM (channel 2)

$ ley stop 2                        # remove one channel; the radio stays tuned
stopped 146.620 MHz NFM (channel 2, chan_01M1S9VB621DNPDV56D9NRD6NG)
the radio stays tuned, free it with: ley stop --all

$ ley stop all                      # remove everything on the radio and free it
stopped 1 channel and freed Generic RTL2832U (R820T) (dev_01M1S9TR56S46QTCK0SZS2YPJA)
```

A third `tune` outside the band the capture covers (`ley tune 101.1` while 146.52 plays) is
refused rather than silencing the channels already on it: `the radio is on 146.520 MHz with
1 channel listening; retuning to 101.100 MHz would silence it. Add --retune to move it anyway,
or free it with: ley stop --all`. `--retune` (on `tune` and `spectrum`) moves the radio and the
others fall silent; a capture with no active channels is retuned without asking, and `tune`
says so. `--gain 30` (or `auto`) on `tune` and `play` sets the receiver gain once the radio is
tuned, and the banner shows the value the radio applied. On a radio with several gain stages a
bare value sets the first; `--gain LNA=0,VGA=0` sets each stage named, in that order, and the
banner lists every stage (`Radio HackRF Pro, gain LNA 0 dB, VGA 0 dB, AMP off`; the AMP is a
switch, so it prints on or off). A stage the radio does not have is refused with the ones it has.
`ley scan --gain` and `ley set gain` take the same forms, and every screen prints a capture's
gain the same way: `gain 28 dB` on a one-stage radio, each stage by name on a radio with several.

`--channel`, `--capture` and `--device` all accept the same selectors: a full id, an id prefix,
the row number from the printed list (`ley state`, `ley devices`) or a frequency
(`--channel 146.62`); a selector that matches nothing, or more than one thing, lists the rows
(`1  chan_…  146.620 MHz NFM`) to pick from. Scripts should use full ids. `ley state` shows every
capture, channel and sink with its owner; a persistent channel lives until the daemon restarts or
something removes it (`ley stop`, `ley devices detach` for playback devices; the app or an agent
for its own).

`ley state` draws that as a tree — each radio, the captures on it, the channels in each capture
and the sinks under each channel — so the relationship is the indentation and no id is repeated
as a column. Ids print whole on the dim line under the object they identify, ready to copy:

```console
$ ley state
daemon 0.1.0-dev  up 39s
pid 4242  socket /tmp/leyline/d.sock  event seq 11

Generic RTL2832U (R820T)  rtlsdr  in use
  device dev_01M1S9TR56S46QTCK0SZS2YPJA  serial 00000001
  tunes 24.000 MHz to 1.766 GHz
  └─ 146.500 MHz  2.4 MSPS  active  gain 20.7 dB
     capture cap_01M1S9VA1XVX9M2K9V0S6Q1J6D  by cli:ley
     └─ 146.620 MHz NFM  bw 12.5 kHz  squelch -80.0 dB  active
        channel chan_01M1S9VA2F5E5G6KK85YNJQ7MS  offset +120.000 kHz  persistent  by cli:ley
        └─ system_audio  volume 1.00 BuiltInSpeakerDevice
           sink snk_01M1S9VA2G0YV6QK6X9T0J7R4W
```

`ley state --wide` keeps the flat tables — one row per object, every id, owner and column — for
a state too large to read as a tree or a line you want to `awk`; `--ascii` swaps the tree
drawing for `+-` and `\-`. `ley state --json` is still the machine snapshot, and it is unchanged
by any of this.

## 10. Play a recording

`play` attaches an IQ recording (a `.cf32` file: the raw samples a radio produced) as a pretend
radio and tunes on it exactly as `tune` would, so `set` and `spectrum` work on it unchanged. No
hardware is needed; the `fixtures/` directory has generated signals with known content.

```console
$ ley play fixtures/nfm_tone.cf32
using NFM: the recording's sidecar says NFM
Listening to 146.620 MHz (NFM, 2 m amateur)
Playing nfm_tone.cf32, 1.0 s at 2.4 MSPS
Squelch off.
Ctrl-C stops.
From another terminal: ley set squelch -50 · ley set mode am · ley spectrum
████░░░░░░░░░░░░  146.620 MHz NFM  signal -63 dBFS  audio
```

The frequency and mode come from the `.json` sidecar beside the file; `--freq` and `--mode`
override, `--loop` starts over at the end. The pretend radio is removed on exit unless
`--persistent`; then `ley devices` lists it as a `file` device, `ley stop` removes the channel
and `ley devices detach <id>` (or its row number) removes the pretend radio together with its
channels.

## 11. Record what you hear

`ley record` writes the received signal to files the daemon keeps. It is a job, so it outlives
the terminal that started it, and what it writes is a resource: `ley recordings` lists them and
`ley recordings path` prints where they are.

```console
$ ley record 146.52 --for 2m
Recording 146.520 MHz (NFM, 2 m amateur)
Writing   audio WAV, 48 kHz mono
Until     2 min have passed
/Users/you/Library/Application Support/Leyline/recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB
Ctrl-C stops; the recording stays.
recording audio: 1 m 12 s, 1 part, 6.9 MB
Recorded 2 min in 1 part, 11.5 MB
Find it again: ley recordings show job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB
ley://recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB
```

The banner states what the daemon decided rather than what you asked for, so a recording of the
wrong thing is caught in the first line and not in the file. `--listen` plays it through the
speakers while it records, so you can hear what is going into the file without a second command. The URI on stdout is what a script
keeps; everything else is for you. Ctrl-C stops the job and leaves a complete recording, not a
damaged one: the file is closed properly and the manifest says it was cancelled. `--detach`
starts it and exits, printing the id `ley jobs cancel` takes.

`--gain` sets the receiver gain for the take, as on `tune`: `--gain 20` sets the first stage, and
`--gain LNA=0,VGA=0` each stage named, which is what a HackRF a metre from a keyed handheld needs.
When a stage was set, the banner gains a line with every stage the take started at, read from
the recording's manifest (`Radio     HackRF Pro, gain LNA 0 dB, VGA 0 dB, AMP off`), so a
gain that did not apply shows before the file does. A stage the radio does not have fails the job
before anything is written: `ley: the gain asked for could not be set: no gain element named IF;
this radio's are LNA, VGA and AMP [GAIN_ELEMENT_UNKNOWN]`. Before 2026-09-24 the daemon dropped
`--gain` on every real radio and recorded at whatever gain it was on.

Recording a busy channel continuously fills a disk with silence, so `--gate squelch` records only
while something is on the air, one file per exchange:

```console
$ ley record 146.52 --gate squelch --stop-after-quiet 10m --detach
Recording 146.520 MHz (NFM, 2 m amateur)
Writing   audio WAV, 48 kHz mono
Gate      squelch, 500 ms pre-roll, 5 s hang, below -92 dBFS is silence
Until     10 min with nothing on the air
/Users/you/Library/Application Support/Leyline/recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB
Left running; ley jobs cancel 1 stops it
```

The squelch it shows is the one it measured from the channel's own noise floor, the way
`ley tune` does; `--squelch -40` sets one yourself.

The pauses *between overs* stay inside one file (`--hang`, 5 s by default) and half a second
before each key-up is kept (`--pre`), so an exchange plays back whole. Silence is never edited out
of a file: the gaps between files are stated in the manifest instead, so playback keeps the
original timing within each file.

`--iq` records the radio's raw samples instead of demodulated audio — the format another tool
reads, and what `ley play` tunes back. It is large (about 19 MB a second at 2.4 MSPS), so it is
cut into a new file every minute unless `--part` says otherwise.

To find one again:

```console
$ ley recordings
STARTED   FREQUENCY    MODE  KIND   LENGTH  PARTS  SIZE     ID
14:03:22  146.520 MHz  NFM   audio  2 min   1      11.5 MB  job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB

$ ley recordings show job_01J8
Recording 146.520 MHz NFM audio, wav-s16
Holds     2 min of signal in 1 part, 11.5 MB of samples
Started   2026-09-17 14:03:22, ended by duration
Radio     Nooelec NESDR SMArt (rtlsdr), gain 29.7 dB
/Users/you/Library/Application Support/Leyline/recordings/job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB

PART  STARTED   LENGTH  PEAK        OVERS  FILE
1     14:03:22  2 min   -6.2 dBFS   -      2026-09-17_14-03-22_146.520MHz_NFM_001.wav
Listen: ley play job_01J8XQ2M7V3N9K5R4T6W8Y0ZAB
```

An id prefix is enough, as everywhere else in `ley`. The files are a plain directory Finder can
open, so `open -R "$(ley recordings path job_01J8)"` reveals one. To hear a recording, give its id
to `ley play`, whichever kind it is:

```console
$ ley play job_01J8
$ ley play job_01J8 --part 2      # or any other part
```

`ley play` works on either kind: an IQ recording is tuned back
as if it were a radio, and an audio recording is played by the daemon through the same speakers
`ley tune` uses — a WAV holds what the demodulator already produced, and there is no signal left
in it to tune. Either way Ctrl-C stops it. (If the daemon has no audio device, `ley play` hands
the file to your own player instead and says so.)

Moving the radio while a recording runs leaves a gap in it, so `ley tune` and `ley set freq`
refuse and name the job; `--retune` goes ahead, and the recording logs the gap rather than
failing. The daemon drops the oldest recordings when the store passes its cap (20 GiB by
default).

`ley recordings delete` removes one recording whole, every part and its manifest. On a terminal it
names the recording and asks first; `--yes` skips the question, and a script has to pass it. This
was recorded against the fake daemon, which is why the recording is two seconds long:

```console
$ ley recordings delete job_01M3
Delete 146.520 MHz NFM, 2 s in 1 part, 185 KB? [y/N] y
Deleted job_01M38P70S3EHR1GYNEPA4FZFMD, 185 KB freed
```

A recording that is still being made is refused, because the daemon has a part open: stop it with
`ley jobs cancel job_…` first, and the recording is complete when it stops. Deleting the
directory in Finder does the same as `delete`, and the daemon does not need to be told.

## 12. Decode what is being said

`ley decode` shows what the packets on a frequency contain. The daemon runs a decoder,
a separate program that turns a channel's audio into typed records, and `decode` prints one
line per record. `ley decoders` lists what is installed and where each one listens:

```console
$ ley decoders
NAME  FREQUENCY         MODE        OUTPUTS            VERSION
aprs  144.390 MHz (+1)  NFM 15 kHz  records, entities  0.1.0
looked in /workspace/decoders, /home/dpup/.local/share/leyline/decoders
kept records in /home/dpup/.local/share/leyline/store, 2 GiB or 90 days, whichever comes first
```

A decoder carries its own recipe (the frequency, the mode, the bandwidth), so `decode` takes no
tune flags. APRS is the first one: position, weather, telemetry, status and message packets that
amateur stations send on 144.390 MHz in North America (`--freq 144.8` is the European
allocation). The transcripts in this section were recorded against the real daemon playing the
`aprs_afsk` fixture, three packets from three test stations, because 144.39 MHz was quiet at
the author's location; on the air the stations are real and the lines look the same.

```console
$ ley decode aprs --count 3
decoding aprs on 144.390 MHz, chan_01M2BEV2YV9AZ3EWN8RJ51ZYWF on cap_01M2BEV016C9Q19GP9HZ1G9MK3. Ctrl-C stops
18:42:25  LEYTST-1      position   37.7600N 122.4167W /> test position
18:42:26  LEYTST-2      weather    25.0 °C wind 6 km/h @ 220°
18:42:26  LEYTST-3      status     test status
```

The daemon found a capture already covering 144.39 MHz (the one `play` made; on a radio it would
make one, or say who has the radio and offer `--take-over`). Each line is the time the packet was
received, the station's callsign and SSID, the kind of record, and a summary of what it carried.
`--json` prints the whole record instead, one `DecodeRecord` per line, with every field the
decoder extracted and the raw bytes it decoded them from.

Ctrl-C stops decoding and hands the radio back. `--job` keeps the decoder running after `ley`
exits and stores the records, so you can see later what was decoded overnight:

```console
$ ley decode aprs --job --count 1
decoding aprs on 144.390 MHz, chan_01M2BEV3ZGXTDG3EF1NQDCNTMP on cap_01M2BEV016C9Q19GP9HZ1G9MK3. kept: it runs on after ley exits
18:42:26  LEYTST-1      position   37.7600N 122.4167W /> test position
left running; ley jobs cancel 2 stops it
$ ley records --device-id LEYTST-2 --limit 2
TIME      PROTOCOL  DEVICE    KIND     SUMMARY
18:43:10  aprs      LEYTST-2  weather  25.0 °C wind 6 km/h @ 220°
18:43:09  aprs      LEYTST-2  weather  25.0 °C wind 6 km/h @ 220°
more records matched than were returned; --limit asks for more
```

`ley records` searches everything kept jobs have stored: `--protocol`, `--since 1h`,
`--device-id`, `--kind`, `--near 37.76,-122.42 --radius 10km`, and `--in-effect` for records
whose validity window contains now. The store lives in a plain directory `ley decoders` prints,
and it is trimmed to a size and an age the daemon was started with.

`ley track` is the other view of the same records: a table with one row per station, kept up to
date as packets arrive and dropped after the decoder's silence timeout, the way an aircraft
display works. It starts the decoder for you, so `ley track aprs` is one command; if a decoder is
already running for the protocol it renders that one rather than starting a second on the radio,
and `ley track aprs --attach` only displays an existing one without touching the radio. The table is
computed in `ley` from the record stream, so a second terminal running it sees exactly the same
table; the daemon keeps no station list of its own.

```console
$ ley track aprs
tracking aprs. a row drops off after 30 m of silence
DEVICE    LAST HEARD  SEEN  HEARD (30 m)  POSITION            LAST
LEYTST-2  now         2            ▂      -                   25.0 °C wind 6 km/h @ 220°
LEYTST-1  now         2            ▂      37.7600N 122.4167W  37.7600N 122.4167W /> test position
LEYTST-3  now         1            ▁      -                   test status
```

HEARD is SEEN spread over time: eight cells covering the window a row lives for, one ramp step per
packet in each, so a station that beacons every few minutes fills a row of low cells and one heard
once shows a single mark at that time. The header shows what a cell covers.

`ley devices-seen` is the longer memory: one row per transmitter the kept records have ever heard,
with how many times, and how long ago it was first and last on the air. Where `ley track` is the
live table for one protocol, `devices-seen` is the registry across everything that was stored, and
it is where a discovered device gets a name you will recognise.

```console
$ ley label LEYTST-1 greenhouse
LEYTST-1  greenhouse
$ ley devices-seen
DEVICE    LABEL       PROTOCOL  KIND     SEEN  FIRST  LAST  SUMMARY
LEYTST-2              aprs      weather  4     3 s    now   21.0 °C wind 12 km/h @ 270°
LEYTST-1  greenhouse  aprs      position  4     3 s    now   37.7600N 122.4200W /> fake station
LEYTST-3              aprs      status   3     2 s    now   fake daemon, monitoring nothing
```

`ley label <device-id> <name>` gives a transmitter a human name, `ley label <device-id>` reads it
back, and `--clear` removes it. Labels are stored in a small JSON file in your config directory
(`$LEYLINE_LABELS` overrides the path) and outlive any job: the registry is computed from the
records, and a name you chose cannot be computed from them. `--quiet-since 48h` shows only the
transmitters *not* heard within the last two days, so a soil probe with a dead battery shows up and
one that is only quiet for the moment does not. By default `devices-seen` scans the whole store, so
it can find transmitters silent since the oldest record; `--since` bounds the scan to a window and
`--protocol` narrows it to one decoder.

### Wait for one thing: `ley watch`

`ley decode` shows everything a decoder hears. `ley watch` shows only what you are waiting for and
can hand a match to a notifier, so an alert reaches you when you are not looking. It is a decode job
with a filter and, optionally, a place for the matches to go. The second decoder is SAME, the
weather-radio alert format on the NOAA channels (162.400 to 162.550 MHz); this transcript was
recorded against the real daemon playing the `same_alert` fixture, a Required Weekly Test for two
Kansas counties.

```console
$ ley watch same --county 20103 --notify=shell:'echo alert | mail -s "wx" me'
watching same on 162.400 MHz, chan_01M2BR7DBPJBBHYJ6NRJ4E93P8
  filter: fips names one of 20103
  notify: shell: echo alert | mail -s "wx" me
Ctrl-C stops
21:26:27  KEAX/NWS      alert      ZCZC-WXR-RWT-020103-020209+0030-1051700-KEAX/NWS-
```

`--county` matches the alert's FIPS county codes, so a county the alert does not name sees nothing
and the notifier stays silent. `--where field=value` filters on any field a decoder emits (with
`!=`, `~` for "contains", and numeric `>`, `>=`, `<`, `<=`), and `--near LAT,LON --radius 10km`
filters on position. `--notify` hands each match to a macOS notification (bare `--notify`), a
webhook (`--notify=webhook:URL`), or a shell command (`--notify=shell:CMD`) with the record's JSON
on its input.

`ley watch` stays attached and streams the matches, like `decode`. A watch is most useful
unattended: `--detach` leaves the job running in the daemon after `ley` exits, so the notifier fires
headless. Stop it with `ley jobs cancel`.

A SAME record carries a validity window, the span the alert is in effect, so `ley records
--in-effect` lists only alerts that have not expired.

Three decoders are built: APRS, SAME, and AIS (marine vessels -- `ley decode ais`, `ley track
ais`, or `ley track vessels` -- a decoder can carry friendly aliases, which `ley decoders` shows in
parentheses beside its name and which `ley decode`, `ley track` and `ley watch` all accept. The
contract every decoder speaks is in
`docs/design/decoders.md` and [writing a decoder](../reference/writing-a-decoder.md); the plan for
the others (ADS-B aircraft, 433 MHz sensors, FT8) is `docs/plans/decoders.md`, and `ley help
roadmap` names what is next.

## 13. For scripts and agents

`ley help scripting` is the authoritative short version; every `--json` shape and exit code is
in the [`ley` reference](../reference/cli.md), and [Writing a client](../reference/clients.md) is
for a program that speaks the contract directly.

- **`--json` on any command** prints the proto3 JSON mapping of the `leyline.v1` messages
  (lowerCamelCase keys, 64-bit integers as strings, one object per line for streams).
  Everything meant for a person — banners, `using NFM: ...`, the meter — goes to stderr, so
  stdout is always parseable.
- **`ley state --json`** is the snapshot (a `GetStateResponse`): devices, captures, channels,
  sinks, activity. Read it instead of scraping tables.
- **`ley fft`** is the number feed behind `spectrum`: rows of bin levels across the band,
  `--rate` times a second, `--count` rows or until Ctrl-C, `--format json` or `bin`. `spectrum
  --json` emits one row with a `floor_db` and a `peaks` list (only peaks that clear the threshold:
  often one entry, sometimes none). These rows are bulk data with no proto message, so their
  shape (`{seq, sample_index, center_hz, span_hz, bins, floor_db}`) is the one documented
  exception to the proto3 rule. `fft` rows are delivered gap-marked: when the daemon had to
  drop rows, a `{"gap":{"from_sample":A,"to_sample":B}}` line precedes the next row (gap lines
  do not count toward `--count`; `--format bin` carries no gap records). `--format bin` writes
  binary, so it is refused when stdout is a terminal — redirect or pipe it; piped, the bytes
  are unchanged.
- **`ley listen`** is the audio feed behind `tune`: the daemon decodes the station and `listen`
  writes the samples to stdout instead of the speakers. It resolves a frequency or preset the
  way `tune` does, making a capture and channel when none exists and removing them on exit, or
  taps a channel already running when given its id (`chan_...`). `--format json` prints
  `{seq, sample_index, sample_rate, format, pcm}` rows with `pcm` base64-encoded — part of the
  same bulk-row exception as `fft` — and `--format bin` writes the raw PCM frames back to back
  (mono, little-endian, `S16` in this build; the rate and format go to stderr). It attaches no
  system-audio sink and leaves the squelch off unless `--squelch` asks for one.
- **`ley presets` and `ley bands`** print the client-local tables grouped under their band (for
  presets) or their family (for bands), so a family of near-identical rows reads as one block;
  `--json` gives the flat arrays with every field, including the description a table trims. No
  RPC is made. `ley help presets` is the same data in prose.
- **`ley mcp`** is the same radio for an agent: an MCP client (Claude Code, Claude Desktop, Cursor)
  starts `ley mcp` as a subprocess and gets a tool per verb -- `list_devices`, `tune`, `scan`,
  `snapshot` (a spectrum PNG), `listen_summary`, `query_records`, `list_entities`, the jobs -- each
  returning the verb's `--json` shape and a short summary. `claude mcp add leyline -- ley mcp`
  registers it in Claude Code; other clients take `{"command": "ley", "args": ["mcp"]}`. What an
  agent tunes ends when its conversation does unless it asks to keep it. The
  [MCP adapter reference](../reference/mcp.md) documents every tool and what it returns to an agent.
- **Be explicit about the rest.** A voice channel is squelched with `--json` too:
  `tune --json` and `tune --persistent` measure the floor too and print the threshold on stderr
  with the run's other decisions (`--squelch off` keeps the channel open). Pass `--mode`
  explicitly rather than relying on band defaults, and give frequencies with a unit (`146.52M`).
- **Exit codes:** 0 ok (including Ctrl-C during a live phase); 1 the daemon refused or failed,
  and the message keeps the daemon's stable code in brackets (`ley: <message> [DEVICE_BUSY]`)
  unless `ley` has a plainer sentence for it; 2 usage error — a bad flag or argument, an unknown
  verb, setting, value form or preset — nothing was sent to the daemon; 3 the daemon is not
  running (any verb); 130 interrupted before the live phase began (a Ctrl-C during a live
  `tune`, `play`, `fft`, `listen` or `spectrum --watch` exits 0). Error lines read
  `ley: <what went wrong>. <what to do next>`.

```console
$ ley tune 146.52M --mode nfm --persistent --json        # ids on stdout, prose on stderr
$ ley set squelch -40 --channel chan_01J... --json
$ ley fft --freq 101.1M --rate 10 | jq .bins[0]
$ ley listen 162.55 --count 10 | jq -r .sample_index      # decoded audio, ten rows
$ ley listen chan_01J... --format bin | play -t raw -r 48000 -e signed -b 16 -c 1 -
$ ley presets --json | jq -r '.[].name'                  # client-local tables, no daemon
$ ley spectrum 101.1 --json                              # {seq, sample_index, center_hz, span_hz, bins, floor_db, peaks}
$ ley daemon status --json                               # DaemonInfo; exit 3 and no pid when not running
```

## 14. When things go wrong

Every error is one line that says what happened and what to run next, and the exit status says
which kind of failure it was. [Troubleshooting](troubleshooting.md) lists the messages a newcomer
meets first, what each means and what to do, and covers the daemon not running, an empty
`ley devices`, a busy radio and no audio. When the message is not enough: `ley state` is the whole
picture, `ley daemon logs -f` follows the daemon, and `ley --socket PATH` talks to a daemon on
another socket.
