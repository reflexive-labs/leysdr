# Plan: CLI Papercuts

Small, self-contained improvements to the CLI. Each one should be an afternoon at most; anything
that needs a design decision belongs in a `design-*.md` instead.

The point of this file is that papercuts otherwise get recorded in the Closing section of whatever
plan happened to be open when they were noticed, and then never found again. Items collected from
`cli-visuals.md` say so, so the original context is still reachable.

## PC-1 `[ ]` `ley bands <frequency>`

The question a reader actually has is "what is 146.52, and what will `ley tune` do with it?"
`bands` can only answer it by making them scan fifteen rows and do the range comparison themselves.

`leyline.BandFor(hz)` already answers it exactly, and nothing exposes it. The tell is in the
command's own help:

```
  ley tune 146.52                # 2 m amateur: NFM, 12.5 kHz
```

That comment is hand-written. The documentation is doing by hand what the lookup would do, and
`ley tune` has no dry-run, so today the only way to find out which mode you will get is to seize the
radio and tune it.

- `ley bands [frequency]` with no argument keeps the current table byte for byte.
- With one, print the band that contains it and what `tune` would pick: the name, the range, the
  mode and bandwidth, and the note. Fall back honestly when nothing matches -- outside every band
  `tune` uses NFM and says so, and this should say the same thing in the same words.
- `usb/lsb` resolves for a concrete frequency (USB at and above 10 MHz, LSB below), so the answer
  here can be more specific than the table's: at 3.7 MHz it should say LSB, not `usb/lsb`.
- `--json` returns the single band object rather than the array, or `null` when unrecognised.
- Then delete the hand-written comment from the help and point the example at the new form.

Related, and worth doing in the same pass since it is the same command:

- **The NOTE column truncates** to about 15 columns at 80 wide, because NAME, RANGE, MODE and
  BANDWIDTH already spend 63. Dropping BANDWIDTH from the table would give NOTE room; the frequency
  lookup above is a better place to report bandwidth anyway, since that is where someone is asking
  about one band rather than scanning all of them. (from `cli-visuals.md`)

Open question this does **not** settle, and should not try to: there are three overlapping
presentations of the same data -- `ley bands` (ranges), `ley presets` (points, grouped by band) and
`ley help presets` (both, in prose). NOAA appears twice, as a band and as seven presets. Worth
deciding deliberately at some point rather than growing a fourth.

## PC-2 `[ ]` `ley state` collapses a one-frequency tuning range

`ley state`'s per-device line prints `146.520 MHz to 146.520 MHz` for a file device where
`ley devices` collapses it to a single frequency. They should share the helper. (from
`cli-visuals.md`, where it was recorded twice)

## PC-3 `[ ]` `ley play`'s banner

`tune`'s banner got the one-fact-per-line treatment and `play`'s did not; it still reads as a
five-line block of ids. Symmetry only. (from `cli-visuals.md`)

## PC-4 `[ ]` `ley fft` rows carry no noise floor

`ley spectrum`'s help says "everything here comes from the daemon's FFT stream: `ley fft` prints the
same rows as numbers for tools", but `spectrum --json` rows carry `floor_db` and `peaks` while `fft`
rows carry neither. A tool reading `fft` has to compute the floor itself, and will not necessarily
compute the same one.

Either add `floor_db` to the `fft` row shape or correct the sentence. Adding it is probably right --
the daemon already has the number, and two clients disagreeing about where the noise floor is, is
the kind of thing that makes two screens contradict each other. Noticed while writing an offline
render harness that defaulted the missing field to 0 and drew a chart claiming a 0 dBFS floor.

## PC-5 `[ ]` A watch chart taller than the terminal strands lines

`ley spectrum --watch` redraws in place with cursor-up. The arithmetic is self-consistent
(`TestSpectrumWatchDrawsOneStatusLine` pins it), but cursor-up clamps at the top of the screen, so a
19-row block in a shorter terminal or pane cannot be fully addressed and the top lines are stranded.
The reported symptom was two status lines counting different frame numbers, which cleared when the
terminal did.

The fix needs the terminal's **height**, which `ui.Resolve` does not currently read -- only width.
With it, fall back to append-mode (as `ley waterfall` already does) when the block does not fit.
Bigger than the rest of this file; it is here because it is where it will be looked for.

## PC-6 `[ ]` Reconcile the style guide on error inking

`docs/cli-style.md` section 6 says only the `ley:` prefix and the `[CODE]` suffix may take ink on an
error line, while the VIS-5 work item also allowed a muted path and a highlighted remedy. The
implementation followed the item. The guide should be reconciled to match, or the implementation
pulled back to the guide -- but they should not disagree. (from `cli-visuals.md`)

## PC-7 `[ ]` The live session writes its two halves to different streams

The live meter moved to stderr so the stderr-TTY gate is coherent, but the banner still goes to
stdout in human mode, so a scraped live session sees its two halves on different streams. Worth
deciding deliberately rather than leaving as an artefact of the order the two changes landed. (from
`cli-visuals.md`)

## PC-8 `[ ]` Presets work wherever a frequency does

`ley spectrum noaa2` fails with a bare parse error that does not even mention presets:

```
ley: frequency: cannot read "noaa2"; try 146.52 (MHz), 7040k or 146520000
```

`ley tune` accepts a preset there; nothing else does. The logic exists as `resolveTuneTarget` in
`tune.go` and is private to that file, so `spectrum`, `waterfall`, `phosphor`, `fft --freq`,
`play --freq` and `set frequency` all call `leyline.ParseUserFrequency` directly and lose both the
preset lookup and its "did you mean" hint.

- Lift `resolveTuneTarget`'s frequency-or-preset half into a shared helper and use it for every
  positional or flag that takes a *point* on the dial.
- Not `--span`, which is a width: a preset there would be meaningless.
- The band views need only the Hz; `tune` additionally uses the preset's mode as a default, so the
  helper should return the preset and let each caller take what it needs.
- The error message is most of the value. `ley spectrum noaa2` should fail the way `ley tune noaa2`
  does, naming presets and suggesting near matches.

## PC-9 `[?]` A band as an argument: `--band`, not a positional

Asked whether `ley spectrum $BAND` makes sense. It does, and the obvious spelling does not work.

**A positional band name is out.** The metre names already parse as frequencies, and the frequency
reading is tried first:

```
2m   -> 2000000        160m -> 160000000
20m  -> 20000000       70cm -> (does not parse)
```

So `ley spectrum 20m` today means 20 MHz, not the 20 m band at 14.0-14.35 MHz. Adding band aliases
to the positional would make that silently mean something else for seven of the fourteen bands,
which is the exact class of quiet wrong answer the honesty invariants exist to prevent. `noaa`
collides too, in the other direction: it is already an alias of the `noaa1` preset (a point at
162.550), where as a band it would be the 162.400-162.550 range.

A `--band` flag has neither problem, and reads fine: `ley spectrum --band "2 m amateur"`. It needs
short aliases on `Band` (which has none today: `Name`, `MinHz`, `MaxHz`, `Mode`, `BandwidthHz`,
`Note`) so it is not quoted prose on the command line.

**Most bands fit a single capture, so this is mostly exact.** Nine of fourteen are under 2.4 MHz:

```
FITS      160m 0.200  40m 0.300  20m 0.350  CB 0.440  80m 0.500
          NOAA 0.150  AM bcast 1.170  15m 0.450  10m 1.700
DOES NOT  2 m 4.000   marine 6.025   airband 19.000   FM bcast 20.500   70 cm 30.000
```

For one that fits: centre on the band's midpoint, set the span to the nearest supported rate at or
above its width. For one that does not: centre and show what fits, and say so -- the same shape as
the message `spectrum` already prints when it reuses an off-centre capture ("showing the capture at
X, which covers Y"). Refusing would be honest and useless; sweeping is a `scan` feature, not this.
An explicit `--span` wins over the band's width, and should say so when it is narrower.

Marked `[?]` rather than `[ ]`: PC-8 is unambiguous and should just be done, while this one wants a
call on whether the convenience earns a flag plus a new alias table on `Band`.

## Not papercuts

Recorded here so they are not mistaken for one:

- **The spectrum peak threshold is a constant 15 dB over the median bin.** The honest quantity
  scales with bin count, because the maximum of N noise bins grows with ln N -- the same
  max-versus-median bias that has now bitten the spectrum scale and the ISM occupancy measurement.
  If `scan` ever wants real detection it needs the scaled form, and that is a design change rather
  than a papercut. (from `cli-visuals.md`)
