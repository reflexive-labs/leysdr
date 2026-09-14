# Troubleshooting

Every error `ley` prints is one line that says what happened and what to run next:
`ley: <what went wrong>. <what to do next>`. When the daemon refused something, its stable code
follows in brackets (`[DEVICE_BUSY]`). The exit status says which kind of failure it was:

| exit | meaning |
|---|---|
| 0 | success, including a Ctrl-C that ends a live session |
| 1 | the daemon refused or failed; the line keeps the daemon's code in brackets |
| 2 | usage: a bad flag, argument, value or preset; nothing was sent to the daemon |
| 3 | the daemon is not running |
| 130 | interrupted before the live phase began |

[`ley` reference](../reference/cli.md) has the full statement, and `ley help scripting` the short one.

## The daemon is not running

`ley: the Leyline daemon is not running (socket ...). Start it with: ley daemon start` (exit 3)
means nothing is answering on the socket. `ley daemon start`; if it says a stale socket is in the
way, `ley daemon stop && ley daemon start`. `ley daemon status` is one line whose first word is
the answer, and `ley daemon logs` shows why a start failed. Under launchd a clean stop stays
stopped and a crash is relaunched; `ley daemon install` is how the daemon comes back at login
([Installing](install.md)).

## No radio in `ley devices`

`(no radios found)` with the dongle plugged in. Check, in order:

- Plugged in; try another port or cable.
- `rtl_test -t` (from `brew install librtlsdr`) sees it. If `rtl_test` sees it and `leylined` does
  not, the daemon is running against a different `librtlsdr`
  (`otool -L engine/.build/release/leylined | grep rtlsdr`).
- Nothing else has it open. `DEVICE_BUSY: another program has the device`, or a row showing the
  dongle `IN_USE` with a `0..0dB` gain column while nothing of yours is tuned, means another process
  (SDR++, GQRX, `rtl_tcp`) holds it. Quit that program; the daemon re-checks with a backoff of up to
  60 s (the `usb_claim_interface error` lines in the daemon log are librtlsdr reporting each check),
  or just tune: a capture that opens the dongle clears the flag at once.
- `ley daemon logs` for driver errors.

Nooelec dongles often ship with serial `00000001`. Two identical serials get distinct ids by
enumeration order and a `serial_collision` feature flag; set unique serials with `rtl_eeprom -s`.

## No audio

`ley state` must show a `system_audio` sink on your channel. Check the Mac's output device, then
`ley set volume 1`. The daemon plays through AVAudioEngine's default output. Full-scale static the
moment `tune` starts means the squelch is off (`--squelch off`, a non-voice mode, or no spectrum
row arrived to measure the floor): `ley set squelch auto`.

## `ley decode` says there is no decoder

`ley: there is no decoder called "aprs". ley decoders lists the ones installed [DECODER_NOT_FOUND]`
means the daemon found no plugin by that name. Decoders are not built into the daemon; they are
installed beside it. Run `make install-decoders` (or `make reload`, which does it), then
`ley decoders` lists what is installed and the directory it searched. If a decoder you wrote is
missing, check its `manifest.json` parses and names an `executable` the daemon can run;
[Writing a decoder](../reference/writing-a-decoder.md) has the contract.

## A remote radio drops

A radio attached over `rtl_tcp` that stops answering goes `DISCONNECTED`, its capture detaches, and
the daemon retries about once a second. When the server is back the device is `AVAILABLE` under the
same id and the capture rebinds by itself. An endpoint that never answered is refused at attach
time and not remembered, so a typo is an error on the spot. `rtl_tcp` serves one client at a time and
drops one that stops reading, so do not point two daemons at the same server.

## Messages `ley` prints

The ones a newcomer meets first:

| you see | what it means | do this |
|---|---|---|
| `no radio found. Check, in order:` under an empty `ley devices` table | the daemon runs but sees no radio | the checklist above |
| `ley: 1.800 GHz is outside what Generic RTL2832U (R820T) can tune (24.000 MHz – 1.766 GHz); did you mean 1.800 MHz (160 m amateur)? write 1800k [FREQ_OUT_OF_RANGE]` | a bare number is MHz, so `1800` was 1800 MHz | type the unit: `ley tune 1800k` |
| `... this device cannot tune below 24.000 MHz; HF needs an upconverter or a device with direct sampling` | the frequency is real, the radio just cannot reach it | an upconverter, or a radio that can |
| `ley: "146,52" is not a frequency; use a dot for decimals (146.52) or a unit (146520k), not a comma` | commas are refused | `ley tune 146.52` |
| `ley: no preset called "noa"; did you mean noaa1, noaa2, noaa3? Check with: ley help presets; or give a frequency such as 146.52 (MHz)` | not a preset | `ley tune noaa`, or the frequency |
| `ley: "foo" is not a setting. Settings: ...` | `set` got a parameter it does not know; the list follows | pick one from the list |
| `ley: squelch "5" is above full scale; levels are dBFS, 0 is loudest; try -40 or auto` | squelch levels are negative numbers | `ley set squelch -40` or `auto` |
| `ley: 2 channels are playing; pick one with --channel: ...` | several channels, none clearly yours | `ley set squelch -40 --channel 2` |
| `ley: no channel matches "3" (a full id, id prefix, row number or frequency); pick one:` then rows `1  chan_…  146.520 MHz NFM` | the selector fit nothing; the rows are what exists | pick a row number or id from the list |
| `ley: the radio is on 146.520 MHz with 1 channel listening; retuning to 101.100 MHz would silence it. Add --retune to move it anyway, or free it with: ley stop --all` | another channel rides on the capture and your frequency is outside its band | `ley tune 101.1 --retune`, or `ley stop all` first |
| `1010 MHz is not a band I know; for 1010 kHz AM broadcast type 1010k` (a warning, tune continues) | a bare number is MHz, and 1010 MHz is nothing in particular | `ley tune 1010k` if you meant AM broadcast |
| `ley: the radio is busy: another client holds it; ley state shows who, and ley tune reuses a capture when the frequency fits [DEVICE_BUSY]` | another client holds the radio on a band that does not cover your frequency | `ley state` shows who; tune inside its band, or stop it |
| `ley: no command or topic named "tunee".` with `Did you mean this?` and `tune` (exit 2) | a typo in the verb | take the suggestion; with no near match the topic list and `ley --help` follow instead |
| `record`, `watch` exit 2 with "not implemented yet" | planned verbs | `ley help roadmap` says what to use today |
| `ley: somebody was tuning this radio 12 s ago. ley scan --take-over sweeps anyway, and hands the radio back afterwards` | a sweep owns the radio for seconds, so it declines a radio in use rather than interrupting | wait, stop the channel, or `--take-over` |
| `ley: all of that range sits within 120.000 kHz of 146.000 MHz, where this radio's own DC spike is; a scan does not look there` | scan never reports the tuner's own centre; on a radio with one tuning point (a recording) that blind spot cannot be covered from elsewhere | `ley spectrum` draws that span instead, DC spike and all |

## When the message is not enough

`ley state` is the whole picture: every device, capture, channel and sink the daemon knows, and
who created each. `ley daemon logs -f` follows the daemon. `ley --socket PATH` talks to a daemon
on another socket. A bug report should carry `ley version` and `ley daemon status`, which name the
exact build.
