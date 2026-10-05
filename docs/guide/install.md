# Installing Leyline

What you will have at the end: the daemon (`leylined`) running on your Mac, the `ley` command on
your `PATH`, and a radio (or an IQ recording) it can see. There are two ways to get there: the Mac
app, which carries the daemon, `ley`, the decoders and the radio drivers, or a build from source.

## Install the app

The app is a disk image, `Leyline-<version>.dmg`, signed with a Developer ID and notarized by
Apple. While Leyline is in a closed alpha, testers receive the link to it; anyone else builds from
source ("Build from source" below). It needs:

- A Mac with Apple silicon. The alpha has no Intel build, because the radio drivers it carries are
  arm64 only.
- macOS 26 or later.
- An RTL-SDR (RTL2832U) or a HackRF One / HackRF Pro, or nothing ("Without a radio" below). The
  drivers for both are inside the app, so Homebrew is not needed.

1. Open the disk image and drag Leyline to Applications.
2. Open Leyline from Applications. macOS asks once whether to open an app downloaded from the
   Internet; click Open.
3. On its first launch the app registers the daemon as a login item, which starts it now and at
   every login. macOS posts a notification that Leyline added a background item. The daemon is
   listed in System Settings > General > Login Items & Extensions, under "Allow in the
   Background".

If that switch is off, the daemon does not run and the window shows "Login Items has the engine
switched off" with an Open Login Items button, which opens that settings page. Switch Leyline on
there; the window connects on its next retry.

If the switch is on but the daemon has stopped (it crashed, or `ley daemon stop` stopped it), the
window shows "The engine is not running" with a Restart engine button, which starts it again
through launchd. `~/Library/Logs/Leyline/leylined.log` says why it stopped.

The app leaves a daemon built from source alone: when `~/Library/LaunchAgents/com.leysdr.daemon.plist`
exists (`ley daemon install` wrote it), the app registers nothing and connects to that daemon.
Remove it with `ley daemon uninstall` to let the app start its own.

### `ley` from the app

The app carries `ley` at `Leyline.app/Contents/Helpers/ley`. Link it onto your `PATH`;
`/usr/local/bin` is on the default `PATH` but does not exist on a new Apple silicon Mac, so create
it first:

```sh
sudo mkdir -p /usr/local/bin
sudo ln -s /Applications/Leyline.app/Contents/Helpers/ley /usr/local/bin/ley
ley daemon status
ley devices
```

The link follows the app through updates, because an update replaces the app in place. `ley
daemon start` and `ley daemon stop` drive the app's login item through `launchctl`. A stop stays
stopped until the next `start` or login. `ley daemon install` and `ley daemon
uninstall` refuse the app's daemon and point at Login Items, because the app owns that job.

### Updates

The app checks for updates automatically, and Leyline > Check for Updates… checks now. An update
downloads, is verified against the key the app was built with, and replaces the app; the app then
restarts the daemon onto the new build. If a recording or decode job is running, a restart would
end it, so the window shows "Leyline was updated; restart the engine to finish" with a Restart
button instead.

### Logs and data

The daemon logs to `~/Library/Logs/Leyline/leylined.log` (`ley daemon logs`), and the app to
`app.log` beside it. Recordings, decode records, bookmarks and the remembered `rtl_tcp` radios are
under `~/Library/Application Support/Leyline/`; "Where things live" below lists each.

### Uninstall the app

1. Switch Leyline off in System Settings > General > Login Items & Extensions, which stops the
   daemon.
2. Quit Leyline and drag it from Applications to the Trash. The login item goes with it.
3. Remove the `ley` link and the data:

```sh
sudo rm /usr/local/bin/ley
rm -rf ~/Library/Application\ Support/Leyline ~/Library/Logs/Leyline
```

## Build from source

A build from source needs:

- macOS 26 with Xcode 26 (the Swift 6.2 toolchain).
- Homebrew, Go 1.27 or later.
- An RTL-SDR (RTL2832U) or a HackRF One / HackRF Pro.
  No radio? See "Without a radio" below.

The daemon built from source loads the drivers from Homebrew. If the app is installed too, switch
it off in Login Items first: `ley daemon install` refuses while the app starts the daemon, because
both use the launchd label `com.leysdr.daemon`.

### Build and start

```sh
brew install go
brew install librtlsdr                 # local RTL-SDR support
brew install hackrf                    # local HackRF support; either driver is optional
git clone https://github.com/reflexive-labs/leysdr.git && cd leysdr
make go swift-release fixtures       # go/bin/ley + leyfix, engine/.build/release/leylined, IQ fixtures
make install-decoders                # the APRS, SAME and AIS decoders ("Decoders" below)
export PATH=$PWD/go/bin:$PATH
ley daemon start --bin $PWD/engine/.build/release/leylined
```

`scripts/bootstrap-mac.sh` runs the same steps; `--rtl-only` or `--hackrf-only` limits it to one
driver. `make go` builds the Go clients, `make swift-release` the daemon, and `make fixtures` the IQ
recordings the "Without a radio" section and the test suites use; `make install-decoders` puts the
decoder plugins where the daemon looks for them. The native libraries are loaded
at daemon startup, independently: neither is needed to build, and a missing one does not disable
the other, `rtl_tcp`, or file playback. Restart the daemon after installing a driver.

Check that the daemon responds and can see your radio. The output below was recorded against the
contract's fake daemon, so your socket path, model and version will differ:

```console
$ ley daemon status
running  0.1.0-dev  pid 4242  up 46s  socket /tmp/leyline/d.sock

$ ley devices
MODEL                     STATE      RANGE                    RATES                GAIN
Generic RTL2832U (R820T)  AVAILABLE  24.000 MHz to 1.766 GHz  0.25..3.2 MSPS (11)  TUNER 0–49.6 dB auto
```

`ley tune 101.1M --mode wfm` on a local broadcaster is the "is my radio alive" test. A HackRF
starts at the same conservative LNA 8 dB / VGA 20 dB defaults as `hackrf_transfer`. While that
command runs, adjust either stage from another terminal with, for example,
`ley set gain LNA=16` or `ley set gain LNA=16,VGA=24`. From here,
[Using `ley`](using-ley.md) walks every task, and [Troubleshooting](troubleshooting.md) covers an
empty device list, a busy radio and no audio.

### Start at login

`ley daemon install` writes a LaunchAgent so the daemon starts when you log in and is restarted if
it crashes:

```sh
ley daemon install --bin $PWD/engine/.build/release/leylined   # writes ~/Library/LaunchAgents/com.leysdr.daemon.plist
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

Attaching connects once (5 s timeout) and fails naming the endpoint if the server does not respond,
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
The fixtures are generated in a checkout; the app does not carry them, so with the app alone play
an IQ recording of your own (`ley play <file>`).
[IQ files and fixtures](../reference/iq-files.md) describes the format and lists the catalog.

## Decoders

`ley decode`, `ley records` and `ley watch` need decoder plugins installed where the daemon looks
for them. Four ship in `decoders/`: APRS, SAME weather alerts, marine AIS, and `iqstat`, a test
decoder that reports the block power of a capture's IQ and is used to check the IQ input path.
The app carries all four in `Leyline.app/Contents/Helpers/decoders/`, and its daemon finds them
there with nothing to install; a decoder of the same name in the decoders directory below takes
precedence over the bundled one. In a build from source, `make reload` installs all four as part
of the rebuild; to install them without a full reload:

```sh
make install-decoders                 # copies decoders/*/ into ~/Library/Application Support/Leyline/decoders/
ley daemon stop && ley daemon start   # the daemon reads the decoder directory when it starts
```

`ley decoders` lists what is installed and prints the directory it searched. On a fresh daemon with
no decoders installed, `ley decode aprs` returns `there is no decoder called "aprs"
[DECODER_NOT_FOUND]`; `make install-decoders` is the fix. Writing your own is
[Writing a decoder](../reference/writing-a-decoder.md).

## Where things live

| what | where |
|---|---|
| socket | `~/Library/Application Support/Leyline/leyline.sock` (`ley daemon status` prints it; `--socket` and `LEYLINE_SOCKET` override) |
| pidfile, `devices.json` (remembered `rtl_tcp` radios) | beside the socket |
| log | `~/Library/Logs/Leyline/leylined.log` (`ley daemon logs`) |
| decoders | `~/Library/Application Support/Leyline/decoders/<name>/` (`make install-decoders`; `--decoders` and `LEYLINE_DECODERS` add more), then `decoders/` beside `leylined` (the app's bundled ones) |
| recordings | `~/Library/Application Support/Leyline/recordings/` (`--recordings`, `--recordings-cap`, `--recordings-age`) |
| decode records store | `~/Library/Application Support/Leyline/store/` (kept decode jobs; `--store`, `--store-cap`, `--store-age`) |
| app log | `~/Library/Logs/Leyline/app.log` |
| bookmarks | `~/Library/Application Support/Leyline/bookmarks.json` (the app's) |
| login item (app) | `Leyline.app/Contents/Library/LaunchAgents/com.leysdr.daemon.plist`, registered by the app; switched in System Settings > General > Login Items & Extensions |
| LaunchAgent (source build) | `~/Library/LaunchAgents/com.leysdr.daemon.plist` (`ley daemon install` writes it, `uninstall` removes it) |

The daemon opens no network listener, and anything that can open the socket controls the radio.
[SECURITY.md](../../SECURITY.md) has the full statement of what it trusts.

## Uninstall a build from source

```sh
ley daemon uninstall                                   # stop the daemon, remove the LaunchAgent
rm -rf ~/Library/Application\ Support/Leyline ~/Library/Logs/Leyline
```

Then delete the checkout; the binaries live in `go/bin` and `engine/.build` inside it.
