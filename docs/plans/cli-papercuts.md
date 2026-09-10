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

## PC-2 `[x]` `ley state` collapses a one-frequency tuning range

`ley state`'s per-device line printed `146.520 MHz to 146.520 MHz` for a file device where
`ley devices` collapsed it to a single frequency. (from `cli-visuals.md`, where it was recorded
twice)

**There were four renderers of a frequency range, not two**, and only one was wrong:

- `state.go rangesPhrase` -- no collapse. Used by the `ley state` tree alone. The bug.
- `devices.go deviceRangesString` -- collapses. Used by `printDeviceTable`, which also backs
  `ley state --wide`, so `--wide` already collapsed and only the tree did not.
- `format.go rangesString` -- dash separator, used by the bare `ley` orientation screen.
- `leyline.FormatRanges` -- en dash, used in error sentences.

The first two are now one pure `rangesPhrase` in `format.go`, returning `""` for none so the caller
supplies the absent form. The other two were **deliberately left alone**: both use a dash where the
style guide says a dash means "no value", but both spellings are documented in `docs/cli-guide.md`,
which section 6 freezes, and both are pinned by tests. Folding them in is a separate, deliberate
change, not a drive-by.

The shared version also skips a nil range element, which the old one would have panicked on.

Tests: `TestRangesPhraseCollapses` (including that no dash appears as a separator) and two
assertions in `TestStateTreeContent`.

## PC-3 `[ ]` `ley play`'s banner

`tune`'s banner got the one-fact-per-line treatment and `play`'s did not; it still reads as a
five-line block of ids. Symmetry only. (from `cli-visuals.md`)

## PC-4 `[x]` `ley fft` rows carry no noise floor

`ley spectrum`'s help says "everything here comes from the daemon's FFT stream: `ley fft` prints the
same rows as numbers for tools", but `spectrum --json` rows carry `floor_db` and `peaks` while `fft`
rows carry neither. A tool reading `fft` has to compute the floor itself, and will not necessarily
compute the same one.

Added, and the reasoning above contains a mistake worth keeping. **The daemon does not have the
number.** There is no floor anywhere in the FFT wire contract -- `FftParams` and `StreamDescriptor`
carry none, and the only `floor_db` in the proto is `PersistenceParams`, which is explicitly
client-supplied. The floor is `medianDb` of the row, computed client-side, so this copies a
presentation statistic into a second command rather than plumbing a measurement.

That does not make it wrong -- the two commands agreeing is the whole point, and
`TestFFTAndSpectrumAgreeOnTheFloor` is the guard -- but the help now says plainly that `ley`
measures it rather than the daemon sending it, and that `--format bin` carries none.

`SpectrumRow.FloorDb` had to be deleted rather than left: an outer field of the same name shadows
the embedded one, and the value would have been assigned twice. Key order is unchanged because
`encoding/json` serialises embedded fields in declaration order.

One hazard the plan caught: `medianDb` answers NaN for an empty row and `encoding/json` refuses to
marshal one, so a decode bug would have stopped the stream with an error instead of emitting a row
that says it measured nothing. `floorOf` guards it.

Still known to disagree: `ley waterfall` floors on the median of column *maxima*, which sits a few
dB high. That is a different statistic for a different picture, not a bug, but it is not this floor.

## PC-5 `[x]` A watch chart taller than the terminal strands lines

`ley spectrum --watch` redraws in place with cursor-up. The arithmetic is self-consistent
(`TestSpectrumWatchDrawsOneStatusLine` pins it), but cursor-up clamps at the top of the screen, so a
19-row block in a shorter terminal or pane cannot be fully addressed and the top lines are stranded.
The reported symptom was two status lines counting different frame numbers, which cleared when the
terminal did.

Done, and the height was closer to hand than expected: `ttyColumns` already asked TIOCGWINSZ for a
struct containing `rows` and threw it away. It is now `ttySize`, with `App.TermHeight`,
`ui.Options.StdoutHeight` and `ui.Style.Height` behind it.

`Height` is deliberately not part of layout -- nothing wraps to a height -- and has no flag and no
clamp, unlike `Width`. It exists for one decision: whether a block is short enough to redraw at all.

The test is the arithmetic that matters: a block needs `lines+1` rows, because after writing N lines
the cursor sits on the next one and moving back N only lands on the first if all N+1 were on screen.
When it does not fit the chart is appended instead, the status line stops trying to overwrite
something that has moved, and the reason is printed once -- a chart that silently started scrolling
would read as a bug rather than as a window that is too short. An unknown height keeps the old
behaviour, which is no worse than before.

Tests: `TestSpectrumWatchScrollsWhenTheChartIsTallerThanTheScreen` (no cursor-up is emitted at all,
the reason is said exactly once, and every frame still arrives) and
`TestSpectrumWatchRedrawsWhenHeightIsUnknown`.

## PC-6 `[x]` Reconcile the style guide on error inking

`docs/cli-style.md` section 6 said only the `ley:` prefix and the `[CODE]` suffix may take ink on an
error line, while the VIS-5 work item also allowed a muted path and a highlighted remedy. (from
`cli-visuals.md`)

The guide was widened, because the implementation is already inside the guide's own principles:
every span is redundant on words present with colour off, ink is SGR-only so ids and `ley ...`
strings stay copy-pasteable, and no span is the only difference between two states.

**The papercut undercounted, twice.** There are *five* inked spans, not four: beyond the muted path
and the `Cmd` remedy, `inkCode` mutes a trailing `[CODE]` and `inkNotRunning` gives `Err` to the
words "not running" -- a span in neither VIS-5 nor the guide. And the guide's "only in `cmd/ley`'s
printer" was simply wrong: the printer is `errorLine`/`inkMessage` in `internal/cli/errink.go`, and
`ley daemon status` reuses it on **stdout**, so a literal reading made that a violation.

The new prose names all five, says the list is closed, and names the real renderer.
`TestErrorLinePlainAndStyled` and `TestErrorLineInkTargets` already pin every span and the
strip-identity, so the guide now describes tests that exist rather than a rule nothing enforced.

## PC-7 `[ ]` The live session writes its two halves to different streams

The live meter moved to stderr so the stderr-TTY gate is coherent, but the banner still goes to
stdout in human mode, so a scraped live session sees its two halves on different streams. Worth
deciding deliberately rather than leaving as an artefact of the order the two changes landed. (from
`cli-visuals.md`)

## PC-8 `[x]` Presets work wherever a frequency does

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

Done. `resolveDialTarget` in `target.go` is the positional form and `resolveDial` the bare one, and
the split is not cosmetic: `--freq` prefixes its errors with the flag name and `ley set` appends the
values the parameter accepts, so a single function would have stapled two frames together. The same
hazard bit inside the resolver on the first cut -- a preset typo came out carrying the frequency
example twice, once from "or give a frequency such as X" and once from ". Example: X". A parse
failure gets the example; a name failure gets the near matches and the alternative, never both.

The two example strings are also deliberately separate: `usage` is whole commands, for someone who
gave no argument and needs the shape, and `example` is a readable frequency, for someone whose
argument did not parse.

Tests: `TestResolveDialTargetAcceptsBoth`, `TestResolveDialTargetErrorShapes` (which asserts the
example appears exactly once), `TestResolveDialTargetDoesNotAcceptBands`.

## PC-9 `[x]` A band as an argument: `--band`, not a positional

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

Built as `--band`. `Band` gained `Aliases`, `WidthHz()` and `CenterHz()`; `ResolveBand` looks up by
alias or full name with near-match suggestions, and `ley bands` grew an ALIAS column, without which
`--band` would be undiscoverable. That column is never dropped on a narrow terminal -- it is the
only one you can type -- and BANDWIDTH is still first to go, which incidentally gives NOTE the room
PC-1 wanted.

The band is resolved to a centre and span inside `openBand`, after the device is picked, because how
much of a band fits depends on the rates that radio supports. A positional frequency together with
`--band` is a usage error rather than a precedence rule: a range and a point say two different
things about where to put the radio.

Verified against the radio:

```
$ ley spectrum --band noaa
162.475 MHz  span 250.000 kHz  floor -48 dBFS  162.350 MHz to 162.600 MHz

$ ley spectrum --band 2m
2 m amateur is 4.000 MHz wide and this radio captures at most 3.200 MHz;
showing that much, centred on 146.000 MHz
146.000 MHz  span 3.200 MHz  floor -57 dBFS  144.400 MHz to 147.600 MHz
```

Tests: `TestResolveBandByAliasAndName`, `TestResolveBandErrorsTeach`,
`TestBandAliasesAreCompleteAndUnique` (every band reachable, no alias on two bands),
`TestMetreAliasesAlreadyParseAsFrequencies` -- which pins the collision itself, so that if `2m` ever
stops meaning 2 MHz, or a band alias is ever added to the frequency path, a test says so rather than
a user finding out. Plus `TestBandFlag*` end to end: the conflict, the unknown name, a band that
fits, one that does not, and an explicit `--span` winning.

## Not papercuts

Recorded here so they are not mistaken for one:

- **The spectrum peak threshold is a constant 15 dB over the median bin.** The honest quantity
  scales with bin count, because the maximum of N noise bins grows with ln N -- the same
  max-versus-median bias that has now bitten the spectrum scale and the ISM occupancy measurement.
  If `scan` ever wants real detection it needs the scaled form, and that is a design change rather
  than a papercut. (from `cli-visuals.md`)
