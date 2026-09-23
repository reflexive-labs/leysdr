# Installing Leyline

What you will have at the end: the daemon (`leylined`) running on your Mac, the `ley` command on
your `PATH`, and a radio (or an IQ recording) it can see. Nothing has been released as a binary yet,
so this is a build from source.

## Requirements

- macOS 26 with Xcode 26 (the Swift 6.2 toolchain).
- Homebrew, Go 1.25 or later.
- An RTL-SDR (RTL2832U) or a HackRF One / HackRF Pro.
  No radio? See "Without a radio" below.

## Build and start

```sh
brew install go
brew install librtlsdr                 # local RTL-SDR support
brew install hackrf                    # local HackRF support; either driver is optional
git clone https://github.com/dpup/leysdr.git && cd leysdr
make go swift-release fixtures       # go/bin/ley + leyfix, engine/.build/release/leylined, IQ fixtures
export PATH=$PWD/go/bin:$PATH
ley daemon start --bin $PWD/engine/.build/release/leylined
```

`scripts/bootstrap-mac.sh` runs the same steps; `--rtl-only` or `--hackrf-only` limits it to one
driver. `make go` builds the Go clients, `make swift-release` the daemon, and `make fixtures` the IQ
recordings the "Without a radio" section and the test suites use. The native libraries are loaded
at daemon startup, independently: neither is needed to build, and a missing one does not disable
the other, `rtl_tcp`, or file playback. Restart the daemon after installing a driver.

Check that the daemon answers and can see your radio. The output below was recorded against the
contract's fake daemon, so your socket path, model and version will differ:

```console
$ ley daemon status
running  0.1.0-dev  pid 4242  up 46s  socket /tmp/leyline/d.sock

$ ley devices
MODEL                     STATE      RANGE                    RATES                GAIN
Generic RTL2832U (R820T)  AVAILABLE  24.000 MHz to 1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0..49.6dB(auto)
```

`ley tune 101.1M --mode wfm` on a local broadcaster is the "is my radio alive" test. A HackRF
starts at the same conservative LNA 8 dB / VGA 20 dB defaults as `hackrf_transfer`. While that
command runs, adjust either stage from another terminal with, for example,
`ley set gain 16 --element LNA` or `ley set gain 24 --element VGA`. From here,
[Using `ley`](using-ley.md) walks every task, and [Troubleshooting](troubleshooting.md) covers an
empty device list, a busy radio and no audio.

## Start at login

`ley daemon install` writes a LaunchAgent so the daemon starts when you log in and is restarted if
it crashes:

```sh
ley daemon install --bin $PWD/engine/.build/release/leylined   # writes ~/Library/LaunchAgents/com.leyline.daemon.plist
ley daemon status
ley daemon logs --follow
ley daemon uninstall                                            # stops it and removes the plist
```

`ley daemon start|stop` work with or without the plist; without it they spawn and kill the binary
directly. A clean `stop` stays stopped; only a crash is relaunched.

To watch the daemon's log as it starts, run it in the foreground instead:

```sh
./engine/.build/release/leylined --log-level debug
```

## A radio on another machine

A dongle plugged into another machine (a Raspberry Pi on the roof, a Linux box in the shack) can be
served with osmocom's `rtl_tcp` and used by the daemon as a virtual device:

```sh
# on the machine with the dongle
rtl_tcp -a 0.0.0.0 -p 1234

# on the Mac
ley devices attach rtltcp pi.local:1234    # the way in: the daemon remembers it across restarts
ley devices                                # shows driver rtltcp, model "rtl_tcp pi.local:1234 (R820T)"
ley devices detach 2                       # the way out: the daemon forgets it
```

Attaching is a request to the running daemon, so nothing needs restarting, and the remembered
list (`devices.json` beside the socket) survives a daemon restart. A foreground run started from a terminal can
also be given its radios on the command line:

```sh
leylined --rtltcp pi.local:1234            # repeatable: --rtltcp a:1234 --rtltcp b:1234
LEYLINE_RTLTCP=pi.local:1234,shack:1234 leylined   # same thing via the environment
```

Attaching connects once (5 s timeout) and fails naming the endpoint if the server does not answer,
remembering nothing. A remembered or flag-given server that is unreachable at startup is logged and
kept, so a dead remote never stops local dongles from working. Tune, gain, sample rate, bias tee,
ppm and AGC all work the same as on a local dongle (they are sent as `rtl_tcp` commands). `rtl_tcp`
serves one client at a time and drops one that stops reading, so do not point two daemons at the
same server. If the link drops, the device goes `disconnected` (its capture detaches) and the
daemon retries the connection on every device poll (about once a second, 5 s timeout per attempt);
once the server is back the device is `available` again under the same id and a detached capture
rebinds to it by itself. Samples cross the network as raw 8-bit I/Q (2.4 MSPS is about 4.8 MB/s),
so a wired LAN or good Wi-Fi is needed.

Nothing on that link is authenticated or encrypted; use it on a network you trust
([SECURITY.md](../../SECURITY.md)).

## Without a radio

`make fixtures` generates IQ recordings of known signals (an NFM tone, AM, SSB, CW, a calibrated
noise floor, a band with four carriers). `ley play fixtures/nfm_tone.cf32 --loop` plays one through
the same pipeline as a radio, and you should hear a 1 kHz tone. The whole test suite runs this way.
[IQ files and fixtures](../reference/iq-files.md) describes the format and lists the catalog.

## Decoders

`ley decode`, `ley records` and `ley watch` need decoder plugins installed where the daemon looks
for them. `make reload` installs the two that ship (APRS and SAME weather alerts) as part of the
rebuild; to install them without a full reload:

```sh
make install-decoders   # copies decoders/*/ into ~/Library/Application Support/Leyline/decoders/
ley daemon start        # a running daemon picks them up on its next start
```

`ley decoders` lists what is installed and prints the directory it searched. A fresh daemon with no
decoders installed answers `ley decode aprs` with `there is no decoder called "aprs"
[DECODER_NOT_FOUND]`; `make install-decoders` is the fix. Writing your own is
[Writing a decoder](../reference/writing-a-decoder.md).

## Where things live

| what | where |
|---|---|
| socket | `~/Library/Application Support/Leyline/leyline.sock` (`ley daemon status` prints it; `--socket` and `LEYLINE_SOCKET` override) |
| pidfile, `devices.json` (remembered `rtl_tcp` radios) | beside the socket |
| log | `~/Library/Logs/Leyline/leylined.log` (`ley daemon logs`) |
| decoders | `~/Library/Application Support/Leyline/decoders/<name>/` (`make install-decoders`; `--decoders` and `LEYLINE_DECODERS` add more) |
| recordings | `~/Library/Application Support/Leyline/recordings/` (`--recordings`, `--recordings-cap`, `--recordings-age`) |
| decode records store | `~/Library/Application Support/Leyline/store/` (kept decode jobs; `--store`, `--store-cap`, `--store-age`) |
| LaunchAgent | `~/Library/LaunchAgents/com.leyline.daemon.plist` (`ley daemon install` writes it, `uninstall` removes it) |

The daemon opens no network listener, and anything that can open the socket controls the radio.
[SECURITY.md](../../SECURITY.md) has the full statement of what it trusts.

## Uninstall

```sh
ley daemon uninstall                                   # stop the daemon, remove the LaunchAgent
rm -rf ~/Library/Application\ Support/Leyline ~/Library/Logs/Leyline
```

Then delete the checkout; the binaries live in `go/bin` and `engine/.build` inside it.
