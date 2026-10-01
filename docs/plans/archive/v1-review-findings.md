# Review findings, v1.0 pass (2026-09-10)

The record of the deep review that `docs/plans/archive/v1-review-fixes.md` acts on: eighteen reviewers over Go quality, Swift quality, three architecture lenses and comment language, each batch of findings checked by independent verifiers told to refute (two lenses for code findings, one for comments). A finding is **confirmed** when no verifier refuted it, **contested** when one did, and **refuted** when all did; contested ones were adjudicated in the fixes plan. Severity is the verifiers' (never higher than the finder's). Line numbers are as of `dd51b21`.

Totals: 206 findings — 179 confirmed, 11 contested, 16 refuted.


## Go code quality: the verbs (`go/internal/cli` tune/set/stop/listen/play/scan/session/change/target/daemon/logs/stubs)

Coverage: Read in full (non-test): go/internal/cli/root.go, tune.go, set.go, stop.go, listen.go, play.go, scan.go, session.go, change.go, target.go, daemon.go, logs.go, stubs.go. Verified with `go build ./... && go vet ./internal/cli/` (clean) and `go test ./internal/cli/` (pass); `go test -race ./internal/cli/ -run TestListen` reproduces the P1 race, and I probed parseNegativeSafe with a throwaway in-package test (removed afterwards) to confirm the marker-substitution finding. Test files: read in full listen_test.go, session_test.go, target_test.go, scan_test.go (incl. the parity subtests), …


### q-go-verbs-1 — listen reads the session mirror while its drain goroutine writes it (data race)

`go/internal/cli/listen.go:195` · P1 · scoped · confirmed

runListen starts the background event drain at listen.go:187 and then, at line 195, calls audioWhat(s), which reads s.state and s.channel to build the stderr note. drainEvents' goroutine concurrently folds events into exactly those fields (session.go:239 -> apply -> fold -> replaceCapture), so the read and the write are unsynchronised. drainEvents' own doc comment states the contract that is being broken: "the mirror (state, capture, channel) must not be touched until it has returned."

Why it matters: Confirmed, not theoretical: `go test -race ./internal/cli/ -run TestListen` fails with WARNING: DATA RACE (write replaceCapture session.go:372 from the drain goroutine vs read leyline.ChannelFrequency <- audioWhat listen.go:234 <- runListen listen.go:195). CI runs `go test ./...` without -race (Makefile:40, .github/workflows/ci.yml:38), so it is invisible today. In the field it can produce a torn read of the capture slice or a stale/garbled frequency in the note, and it is the kind of race that silently spreads as more mirror reads are added to the streaming loop.

Suggested fix: Compute the note's text (audioWhat(s), and anything else read off the mirror) before `stopDrain := s.drainEvents()` — the channel and state are already resolved by then — or move the drain start to after s.say. A guard-rail worth adding separately: run this package with -race in CI.


### q-go-verbs-2 — listen's last row can be lost or truncated with exit 0: deferred Flush error is discarded

`go/internal/cli/listen.go:197` · P2 · mechanical · confirmed

runListen writes rows into a bufio.Writer whose only unconditional flush is `defer out.Flush()` (line 197), whose error is thrown away. The in-loop `out.Flush()` (line 220) is skipped for the final row because `--count` returns at line 218 before reaching it, so the last row (and, for --format bin, the last frame) is flushed only by the deferred call.

Why it matters: `ley listen --count 10 --format bin > /full/disk` (or into a pipe whose reader has gone) writes the first nine frames, silently drops the write error on the tenth, and exits 0. A script that trusts the exit status keeps a truncated PCM file or a JSON stream missing its final row. The same happens on the normal end-of-stream path, where the loop's last iteration is also unflushed at the point of return.

Suggested fix: Replace the bare defer with an explicit flush on every exit path, e.g. flush before each `return nil` and end with `return out.Flush()`, or use a named return and `defer func(){ if err == nil { err = out.Flush() } }()`.


### q-go-verbs-3 — parseNegativeSafe swaps a marker into a flag's value, producing a NUL-byte error message

`go/internal/cli/set.go:689` · P3 · scoped · confirmed

parseNegativeSafe replaces every word that looks like a negative number with the marker "\x00neg" before pflag sees the list, including a word that is a flag's *value*, then substitutes the saved negatives back into the positionals in order. When a flag consumes a marker the mapping shifts: the flag keeps the literal marker string and the positional takes the wrong number.

Why it matters: Probed in-process: parseNegativeSafe(cmd, []string{"--channel","-40","squelch","-50"}) returns args ["squelch" "-40"] with channel="\x00neg". The user then gets `--channel: unknown channel "\x00neg"` — an error message containing a control byte and naming a value they never typed. No wrong write reaches the daemon today only because channel resolution fails first; that safety is incidental, not designed.

Suggested fix: Skip the substitution when the previous word is a known value-taking flag of this command (--channel/--capture/--element, and their `--flag=value` form is already safe), or, at minimum, reject a selector that still equals the marker with a plain usage error rather than passing it to ResolveChannel.


### q-go-verbs-4 — runListen duplicates runTune's create-and-teardown sequence line for line

`go/internal/cli/listen.go:155` · P3 · scoped · contested

listen.go:155-173 repeats tune.go:192-217: the same coverage check + checkRange, ensureCapture, applyGain with `if s.createdCapture { s.teardown() }`, createChannel with s.teardown(), in the same order with the same error handling. Only the surrounding prose (bandWarning, modeReason, captureCenter) differs.

Why it matters: The two copies have already drifted once — tune checks range against `target` (o.captureCenter when set) while listen checks against o.freq — and any future change to the teardown rules (for instance the asymmetry where applyGain's failure is guarded by createdCapture but createChannel's is not) has to be made twice or one verb silently keeps the old behaviour.

Suggested fix: Extract a `(*session).openChannel(ctx, o *tuneOptions) error` holding the four steps and their teardown policy, and have runTune and runListen call it around their own prose.

- verifier (comment, confirmed P3): tune.go:194-217 and listen.go:155-172 are the same four-step block with the same teardown asymmetry (applyGain guarded by createdCapture, createChannel not). One correction: the claimed drift is currently inert — o.captureCenter is only ever set by play (play.go:155), never by listen, so tune's `target` and listen's `o.freq` agree today; the duplication and the doubled teardown policy are the real content.

- verifier (comment, refuted P3): The claimed drift is not real: o.captureCenter is only ever set by play.go:155 (grep: no other writer), so listen's `target` would always equal o.freq. And the extraction would make things worse — tune interleaves bandWarning/modeReason prose between checkRange and ensureCapture (tune.go:198-204) and adds attachAudio with its own teardown, so an openChannel() helper needs a callback or a reordering of tune's output to wrap ~15 lines.


### q-go-verbs-5 — stop --all can report more channels stopped than it stopped

`go/internal/cli/stop.go:165` · P3 · mechanical · confirmed

stopAll tolerates CodeChannelNotFound from DestroyChannel (the channel was already gone) but still increments `stopped` on that path, so the count in the closing line includes channels this command did not remove.

Why it matters: With a channel that another client destroyed a moment earlier, `ley stop --all` prints e.g. "stopped 3 channels and freed RTL-SDR" when it stopped two. The number is the only feedback the verb gives, and it is the number a person would quote when something else is still holding the radio.

Suggested fix: Increment only when err == nil; count the NotFound case separately (or not at all).


### q-go-verbs-6 — stopChannel prints the same line from both branches

`go/internal/cli/stop.go:99` · P3 · mechanical · confirmed

The `fmt.Fprintf(s.app.Stdout, "stopped %s\n", desc)` statement appears identically at stop.go:99 and stop.go:103; the only thing the first branch adds is the follow-up "the radio stays tuned" line.

Why it matters: Two copies of the outcome line mean a future wording change (or adding an ink role) has to be made twice, and a reader has to compare the two branches character by character to see that they are the same sentence.

Suggested fix: Print the outcome line once, then `if others == 0 && cap != nil { print the footnote }`.


### q-go-verbs-7 — fileSidecar.SampleRate is parsed and never used

`go/internal/cli/play.go:21` · P3 · mechanical · confirmed

The sidecar struct declares `SampleRate uint64 \`json:"sample_rate"\`` but nothing in the package reads sc.SampleRate; play takes the rate from the daemon's device descriptor instead (playedSource uses dev.GetSampleRates()). The doc comment above the struct describes it as "centre frequency and the first expected channel", which is what the rest of the code actually uses.

Why it matters: A reader (or the next person adding --rate handling to play) reasonably assumes the field feeds the capture's sample rate and has to grep the package to discover it is inert.

Suggested fix: Delete the field, or use it (e.g. as the default for CreateCapture's SampleRate when --rate is unset) if that was the intent.


### q-go-verbs-9 — sameIdentity's two-way substring match drops log sources that say something new

`go/internal/cli/logs.go:240` · P3 · scoped · confirmed

repeatsLabel/sameIdentity decide whether swift-log's bracketed [source] merely repeats the subsystem label, and sameIdentity accepts any substring relation in either direction after stripping case and punctuation. Short sources therefore match labels they have nothing to do with.

Why it matters: The comment two lines above states the rule — "Drop it only when it does, so a source that says something new lives" — and the implementation breaks it: a line logged as `... leyline.audio: [IO] device stalled` has identityKey "io", which is a substring of "leylineaudio", so `ley daemon logs` on a terminal silently swallows the [IO] tag. Losing information from a log relay is exactly what the file's header promises never to do.

Suggested fix: Require equality of identity keys, or a prefix/suffix match with a minimum length (say 4 characters), so short tags are always kept.


### q-go-verbs-10 — Scan ownership test relies on a bare 120 ms sleep and leaks its runner on failure

`go/internal/cli/scan_test.go:214` · P3 · scoped · confirmed

"a scan owns the radio while it runs" starts `ley scan` in a goroutine, sleeps a fixed 120 ms, then asserts that a concurrent tune is refused with "scan is sweeping". Nothing synchronises on the sweep having started or still running, and the background goroutine's run(t, ...) is never cancelled when the assertions fail.

Why it matters: On a loaded machine the sweep may not have taken the radio yet (or, if the fake ever gets faster, may already have finished), and the test fails or passes for the wrong reason; the goroutine then keeps calling into t after the test function returns. Every other timing-sensitive test in this package polls a condition with a deadline (cli_test.go:38-46, tune_test.go:237-251) — this one does not.

Suggested fix: Poll GetState (or the job table) until the scan job reports RUNNING with a 5 s deadline, as the other tests do, and cancel the scan's context before failing.


### Refuted

- **q-go-verbs-8** presetAt names the first preset within 6 kHz, not the nearest, behind an unexplained constant (`go/internal/cli/scan.go:444`) — The described mis-labelling cannot occur with the current table: presets (pkg/leyline/presets.go:24-33) are the seven NOAA channels 25 kHz apart plus 146.520, 156.800 and 121.500 MHz, so no frequency is within 6 kHz of two presets and first-match equals nearest-match. What remains is an unnamed …


## Go code quality: rendering (`go/internal/cli` spectrum/waterfall/phosphor/meter/tables/state/devices/fft and `go/internal/ui`)

Coverage: Read in full (non-test): go/internal/ui/{width,style,resolve,lipgloss,render}.go; go/internal/cli/{spectrum,spectrum_axis,spectrum_chart,spectrum_render,spectrum_watch,waterfall,waterfall_view,phosphor,phosphor_view,meter,columns,format,tables,state,devices,fft,band,helpink,errink,transmission,subaudible,version}.go. topics.go: read the structure (topic table, topicByName/topicList/newTopicCommands/newHelpCommand), formatBandwidth, topicGlossary and topicScripting in full; the prose bodies of topicSquelch/topicFrequencies/topicModes/topicGain/topicPresets (lines 126-296) were skimmed only, so …


### q-go-render-1 — meterSink.write leaves stale rows when the meter block shrinks

`go/internal/cli/meter.go:213` · P2 · scoped · confirmed

write() steps back over lastRows-1 rows and rewrites the new block, padding each row to the width of the row it replaces, but it never erases rows that existed last time and do not exist now. meterRender returns 3 lines while an audio level is measured and 1 line when it is not (meter.go:70-73), so the block legitimately shrinks mid-run.

Why it matters: Meter.audio_dbfs is documented as "NaN (never 0) whenever the value was not measured" (proto/leyline/v1/telemetry.proto:87-88), so a live `ley tune` that stops measuring audio (raw-IQ block, a gap between demod blocks) drops from 3 rows to 1 and leaves two frozen signal/audio bars on screen for the rest of the session, showing levels that are no longer being updated. TestMeterSinkTerminalRedraw (meter_test.go:132) only exercises single-line blocks, so nothing catches it.

Suggested fix: After writing the new lines, if len(lines) < m.lastRows, emit the remaining old rows as blank lines padded to m.lastLens[i] (as clear() already does) before recording the new lastRows/lastLens.


### q-go-render-2 — `ley state` orphan section order is Go map-iteration order

`go/internal/cli/state.go:158` · P2 · mechanical · confirmed

stateNodes collects captures, channels and sinks whose parent is missing from the snapshot by ranging over the three maps it built. Go randomises map iteration, so the "not attached to a listed device" block comes out in a different order on every invocation for the same daemon state.

Why it matters: Two consecutive `ley state` runs against an unchanged daemon print different screens, which reads as the state changing under the user, and makes the block undiffable in a bug report. Any golden test that grows an orphan fixture will flake.

Suggested fix: Walk st.GetCaptures()/GetChannels()/GetSinks() in wire order and emit the entries still present in the leftover maps, instead of ranging over the maps themselves.


### q-go-render-3 — spectrum --json marshals the raw median, which fft.go deliberately guards against

`go/internal/cli/spectrum.go:216` · P2 · mechanical · confirmed

runSpectrum puts `floor` (medianDb of the decoded bins) straight into SpectrumRow.FloorDb, while `ley fft` puts floorOf(bins) into the identical field. floorOf exists precisely because encoding/json refuses NaN/Inf and would turn a decode edge case into a stream that stops with an error instead of a row.

Why it matters: A payload that decodes to zero bins (short frame) or whose median bin is -Inf makes json.Marshal fail, and runSpectrum returns that error, so `ley spectrum --json` exits 1 with "json: unsupported value: NaN" where `ley fft` prints a row. FFTRow's own doc comment (fft.go:22-27) promises the two verbs "report the same number for the same row"; here they do not even agree on whether a row is emitted.

Suggested fix: Use floorOf(bins) in the SpectrumRow literal (keeping the raw `floor` for the peak threshold and the chart, which handle NaN).

- verifier (comment, downgraded P3): Real divergence: spectrum.go:216 marshals the raw medianDb while fft.go:185 uses floorOf (fft.go:256-261). But the only case where the two verbs actually differ is an empty bins slice (non-u8 payload of 1-3 bytes, since len(fr.Payload)==0 is skipped at spectrum.go:206): a NaN/-Inf bin makes json.Marshal fail on Bins in fft too. One-word fix, but reachable only from a malformed daemon frame, so P3 not P2.


### q-go-render-4 — `ley waterfall --json` and `ley phosphor --json` silently ignore the flag

`go/internal/cli/waterfall.go:140` · P2 · design · confirmed

runWaterfall and runPhosphor never consult app.JSON: with --json they still render the ANSI-free chart to stdout. The flag's only effect is that machineStdout() turns stdout's colour off, so the user gets a picture where they asked for machine output.

Why it matters: The package doc claims "Every verb honours --json" (root.go:2) and `ley help scripting` says "add --json to any command" (topics.go:346), so a script piping `ley waterfall --json | jq` gets unparseable text with exit 0. The codebase's own convention for a verb with no JSON shape is to reject the flag: daemon.go:64 returns a usage error naming what to run instead.

Suggested fix: Either reject --json on these two verbs with a usage error pointing at `ley fft`/`ley spectrum --json`, or emit an NDJSON row shape; do not leave the flag inert.


### q-go-render-5 — phosphor's mid-scale axis label is one row low

`go/internal/cli/phosphor_view.go:152` · P3 · mechanical · confirmed

Row r covers the level band [(r-1)/12, r/12) of the range (phosphor_view.go:166-167), and the top row is labelled with its top edge, floorDb+rangeDb. The interior label at r == phosphorHeight/2 instead prints floorDb + (r-1)*step, the row's bottom edge, so the two labels use different anchors.

Why it matters: With the default 50 dB range the mid label reads about 4.2 dB lower than the level the row it sits on actually starts at, so a reader lining a cell up against the axis mis-reads its level by a whole row.

Suggested fix: Label the interior row with `v.floorDb + float64(r)*step` so every label names its row's top edge, as the top row's does.


### q-go-render-6 — waterfall gutter comment names waterfallAxisEvery; the code uses a bare 4

`go/internal/cli/waterfall_view.go:165` · P3 · mechanical · confirmed

The doc comment says the elapsed time is "printed on every waterfallAxisEvery-th row" (20), but the body tests `v.rows%4 == 0`, so the timestamp appears five times as often as documented, keyed to an unnamed literal.

Why it matters: A maintainer tuning the axis cadence will change waterfallAxisEvery and see nothing move in the time gutter, then hunt for why.

Suggested fix: Name the 4 (e.g. waterfallTimeEvery) and fix the comment to refer to it.


### q-go-render-7 — Comment describes a floor-label skip the chart does not implement

`go/internal/cli/spectrum_chart.go:187` · P3 · mechanical · confirmed

The comment on the interior floor label says it "is skipped when the floor sits on the first row". floorRow is clamped to a minimum of 1 (spectrum_chart.go:172-174) and the switch has no such guard, so when the noise line lands on row 1 the label is printed anyway.

Why it matters: The comment is the only statement of intent for a branch that does not exist; a reader debugging a duplicated-looking axis will trust it and look elsewhere.

Suggested fix: Either add the guard (`case floorRow: if floorRow > 1 { label = ... }`) or delete the last sentence of the comment.


### q-go-render-8 — subAudibleTracker comment promises a "gone" line it never emits

`go/internal/cli/subaudible.go:35` · P3 · scoped · confirmed

The !on branch comments "Only say 'gone' if something was there" and then returns ("", false) unconditionally — there is no branch on t.lastOn, so a PL tone that disappears mid-transmission is never reported, whether or not one was there.

Why it matters: The comment reads as a description of a conditional, so a reader assumes the disappearance case is handled; it also hides that TestSubAudibleSilenceIsNotNarrated (subaudible_test.go:37) only covers the never-had-a-tone half.

Suggested fix: Either return a "PL gone" line when t.lastOn was true, or reword the comment to say tone loss is deliberately silent.


### q-go-render-9 — Dead type assertion binding in `ley devices --watch`

`go/internal/cli/devices.go:132` · P3 · mechanical · confirmed

The watch loop binds `p` from the Event_Device assertion, uses nothing from it, and discards it with `_ = p` at the end of the iteration.

Why it matters: `_ = p` reads as a deliberate suppression, so the next reader assumes the device payload is needed for something and looks for the missing use.

Suggested fix: `if _, ok := ev.Body.(*leylinev1.Event_Device); !ok { continue }` and drop the `_ = p`.


### q-go-render-10 — meterSink.lastLen is written but never read

`go/internal/cli/meter.go:185` · P3 · mechanical · confirmed

lastLen is documented as the visible width of the first line on screen and is maintained in both write() and clear(), but nothing in the package ever reads it — lastLens[0] is the value actually used.

Why it matters: Two fields that must be kept in step, one of which is inert, is one more thing to update in a redraw change that already has subtle bookkeeping.

Suggested fix: Delete the field and its two assignments.


### q-go-render-11 — rangesString duplicates rangesPhrase and spells a range with the reserved dash

`go/internal/cli/format.go:65` · P3 · scoped · confirmed

format.go carries two renderers for the same data: rangesString joins with "-" and returns "-" when empty; rangesPhrase joins with " to " and returns "" for the caller to fill. docs/dev/cli-style.md:136 states ranges are never written with a dash "so a dash always means" no value.

Why it matters: `ley orient` prints "tunes 24 MHz-1.766 GHz" (root.go:753) while the same device in `ley state` and `ley devices` prints "24 MHz to 1.766 GHz"; a device with no ranges renders "tunes -", which is exactly the ambiguity the style rule exists to prevent.

Suggested fix: Delete rangesString and have root.go:753 use absentIfEmpty(s, rangesPhrase(...)) as deviceNode already does.


### q-go-render-12 — `ley help scripting` omits floor_db from the documented row shape

`go/internal/cli/topics.go:352` · P3 · mechanical · confirmed

The scripting topic says fft and spectrum --json print "{seq, sample_index, center_hz, span_hz, bins} (plus peaks for spectrum)", but FFTRow also carries floor_db, and both the fft --help text and the spectrum example line list it.

Why it matters: This topic is the contract a script author reads; it now contradicts `ley fft --help` (fft.go:60) and `ley spectrum --help` (spectrum.go:85) about the shape of the row, and floor_db is the field the two verbs were deliberately made to agree on.

Suggested fix: Add floor_db to the topic's row shape.


### q-go-render-13 — waterfall's stream-ended error says "the spectrum stream"

`go/internal/cli/waterfall.go:160` · P3 · scoped · confirmed

runWaterfall reuses spectrumEnd, whose zero-row message is "the spectrum stream ended before it sent a row". A user running `ley waterfall` is told about a verb they did not run.

Why it matters: The message is the user's only clue after a silent exit; naming the wrong verb sends them to `ley spectrum` to reproduce a waterfall problem.

Suggested fix: Give spectrumEnd a verb/noun parameter ("spectrum", "waterfall", "persistence") and use it in the message.


### q-go-render-14 — spectrum and fft accept --rate 0 or negative where waterfall and phosphor reject it

`go/internal/cli/spectrum.go:120` · P3 · mechanical · confirmed

waterfall.go:88 and phosphor.go:95 both return a usage error for --rate <= 0. spectrum's RunE validates only --count, and fft validates neither, so `ley spectrum --watch --rate 0` sends rate 0 to Bulk.Subscribe and leaves the client's own stall detector on its rate<=0 fallback.

Why it matters: The same flag on four sibling verbs fails in two different places with two different messages: two answer with a clean exit-2 usage error, two hand a nonsense rate to the daemon and surface whatever it says (or hang on a stream that never ticks).

Suggested fix: Add the same `--rate must be greater than 0` check to spectrum and fft.


### q-go-render-15 — Three copies of the frequency/--band/--span/--count preamble

`go/internal/cli/phosphor.go:64` · P3 · scoped · confirmed

spectrum, waterfall and phosphor each repeat ~30 lines of identical RunE argument handling: positional-vs---band conflict, ResolveBand, ParseUserFrequency for --span, the count check and the width fallback. bandOptions already exists to share the capture-side rules; the flag-side rules were not.

Why it matters: The copies have already drifted (only two of the three validate --rate, and spectrum's resolveDialTarget hint strings differ in shape), and a fourth band view or a change to how --band interacts with a positional has to be made in three places or it is wrong in one.

Suggested fix: Extract a bindBandFlags/parseBandArgs helper taking the verb name and examples, returning the populated bandOptions plus width, and call it from all three RunEs.


### q-go-render-16 — The waterfall legend's shade swatch is dimmed, so it does not match the map

`go/internal/cli/waterfall_view.go:102` · P3 · scoped · confirmed

key() builds each legend entry with the ramp-inked glyph as headerSeg.name, and headerSeg.render wraps a non-dim segment's name in Muted. The swatch therefore renders faint-plus-colour while the identical cell in the map below renders at full intensity.

Why it matters: The legend exists so a reader can match a cell's shade to a dB step; faint-vs-normal is exactly the difference the four-step ramp is trying to convey, so the key is slightly wrong about the thing it is keying.

Suggested fix: Give headerSeg a flag (or a preinked variant) that emits name verbatim, and use it for the key's swatches.


### q-go-render-17 — replayANSI treats erase-line as a no-op and overwrites whole rows

`go/internal/cli/spectrum_watch_test.go:90` · P3 · scoped · contested

The virtual screen used by the watch tests handles \x1b[K as a comment ("the writer's content already replaced it") and flush() assigns the entire row from the current line buffer, discarding any longer text previously on that row. So the screen model cannot represent residue at all.

Why it matters: ansiEraseLine is written on every redrawn line specifically so a shorter chart cannot leave the tail of a longer one behind (spectrum_watch.go:78-81), and these are the only tests of the redraw path — deleting every ansiEraseLine from the writer would leave them green.

Suggested fix: Model rows as mutable rune buffers: write into columns at the cursor and have 'K' truncate the row there, so a missing erase shows up as leftover text.

- verifier (comment, refuted P3): The screen-model limitation is real (spectrum_watch_test.go:90 no-ops 'K' and line 62-67 assigns the whole row), but the stated consequence is false: spectrum_test.go:156 asserts `strings.Count(tty, ansiEraseLine) >= 2`, so deleting the erase writes from spectrum_watch.go would fail that test, not leave the suite green.

- verifier (comment, confirmed P3): spectrum_watch_test.go:62-67 assigns screen[row] = cur.String() and :90 treats 'K' as a no-op, so the model cannot represent residue and the ansiEraseLine writes at spectrum_watch.go:78-81 are untested. Worth the scoped fix because the same residue class is a live bug in meter.go (q-go-render-1); expect golden strings to need re-recording once rows become column-accurate.


### q-go-render-18 — Redundant loop-variable copy under go 1.25

`go/internal/cli/topics.go:64` · P3 · mechanical · confirmed

newTopicCommands opens its range body with `t := t` to capture the loop variable for the closure at topics.go:78; the module is go 1.25.0, where the range variable is already per-iteration.

Why it matters: It signals to a reader that the closure capture here is subtle when it is not, and invites the same cargo-cult copy in new loops.

Suggested fix: Delete the line.


## Go code quality: the client library, iqfile and the two binaries (`go/pkg`, `go/cmd`)

Coverage: Read in full: go/pkg/leyline/client.go, errors.go, socket.go, freq.go, bands.go, presets.go, selectors.go, userinput.go; go/pkg/iqfile/io.go, sidecar.go; go/cmd/ley/main.go; go/cmd/leyfix/main.go, generate.go, signals.go, catalog.go, dsp.go, chain.go, analyze.go, check.go, cw.go, info.go. Test files read in full: errors_test.go, socket_test.go, iqfile_test.go, leyfix_test.go, cmd/ley/main_test.go; read by function list plus the bodies of TestBandsOrderedAndDisjoint, TestSortStateOrdersByID, TestNewIDIsMonotonic and the contains/indexOf helpers: bands_test.go, bandlookup_test.go, …


### q-go-lib-1 — ChannelFrequency's doc comment is attached to ChannelCaptureRate

`go/pkg/leyline/selectors.go:147` · P2 · mechanical · confirmed

Lines 147-149 are ChannelFrequency's doc comment, but they sit immediately above the ChannelCaptureRate comment block and therefore become part of ChannelCaptureRate's godoc. ChannelFrequency at line 163 is left with no doc comment at all, and godoc for ChannelCaptureRate opens with a paragraph describing a different function.

Why it matters: This is the library an MCP adapter and a TUI build against; someone reading pkg.go.dev sees ChannelCaptureRate documented as "returns the channel's absolute frequency (capture center plus offset) ... ok is false when the capture is not in state" — a two-result signature it does not have — and the function they actually want is undocumented.

Suggested fix: Move the three-line ChannelFrequency paragraph down to sit directly above `func ChannelFrequency` at line 163.


### q-go-lib-2 — Subscription.Err() is single-shot: the second call returns nil

`go/pkg/leyline/client.go:372` · P2 · scoped · confirmed

Err() receives from the errs channel non-blockingly and discards the value into the return. The pump goroutine sends exactly one value, so the first Err() after the stream ends yields the terminal error and every later call yields nil. Nothing in the type memoises it.

Why it matters: A caller that logs the error and then re-checks it ("if sub.Err() != nil { report(sub.Err()) }"), or a TUI/MCP layer where one goroutine drains Frames and another asks Err(), silently turns a real stream failure into a clean end. The idiomatic Err() contract (bufio.Scanner, sql.Rows) is repeatable; this one is not, and the doc comment ("Err returns the stream's terminal error once Frames is closed") promises the idiomatic behaviour.

Suggested fix: Store the received error in a field guarded by sync.Once/mutex on first read and return the stored value on subsequent calls.


### q-go-lib-3 — fixture.fits() checks expectations, not sources, so scan_band is generated at any rate

`go/cmd/leyfix/catalog.go:265` · P2 · scoped · confirmed

fits() decides whether a fixture can be generated at a given sample rate by looping over f.expect(rate) and testing |offset| + bw/2 < 0.45·rate. scan_band deliberately declares no expectations (catalog.go:258-262), so the loop body never runs and fits() returns true for every rate — including rates far below what its ±800 kHz carriers need.

Why it matters: `leyfix generate --out d --rate 240000` writes a scan_band.cf32 whose four carriers at -800/-400/+400/+800 kHz all alias back into a 240 kHz span, and nothing warns: `check` skips it (no expects) and prints nothing. The repo's own TestCheckReducedGeneration generates exactly this file at 240 kHz. The sweep-detector fixture — whose entire purpose is the placement of those carriers — is silently garbage at reduced rates, while wfm_tone is correctly refused (verified: fits(240000) is true for scan_band, false for wfm_tone).

Suggested fix: Give fixture an explicit widest-signal bound (e.g. a maxOffsetHz field or a fits func) and have fits() consider the built sources as well as the expectations, so a fixture with no expect entries is still rate-checked.


### q-go-lib-4 — Subscribe rewrites the caller's SubscribeRequest in place

`go/pkg/leyline/client.go:394` · P3 · scoped · confirmed

Subscribe assigns req.Transport and, when nil, req.Start on the request the caller passed in, instead of on a copy. The mutation is invisible to the caller and outlives the call.

Why it matters: An MCP adapter that builds a SubscribeRequest from a JSON payload, or any caller that keeps a request around to retry or to log what it asked for, gets back a proto that no longer says what it said. A caller that legitimately wanted a non-GRPC transport also has its field overwritten with no error.

Suggested fix: Clone the request (proto.Clone) before setting Transport/Start, or document the mutation explicitly in the doc comment.


### q-go-lib-5 — Reader.Read with an empty dst returns (0, nil) forever

`go/pkg/iqfile/io.go:114` · P3 · mechanical · confirmed

Read computes need = len(dst)*bps; for a zero-length dst io.ReadFull returns (0, nil), n becomes 0, and the n == 0 branch falls through to `return 0, err` with err nil. The caller gets a successful read of nothing and no EOF.

Why it matters: Every documented consumption pattern for this Reader (and ReadAll's own loop at io.go:152) is `for { n, err := r.Read(buf); ... if err == io.EOF { break } }`. Hand that loop a zero-length buffer — easy when the buffer size is computed from a config value or a sidecar field — and it spins at 100% CPU forever instead of erroring.

Suggested fix: Return an error (or io.EOF) up front when len(dst) == 0.


### q-go-lib-6 — marine VHF ends at 162_024_999 Hz and the "split around it" comment describes a split that is not there

`go/pkg/leyline/bands.go:49` · P3 · scoped · confirmed

The table comment says NOAA weather "sits inside the marine VHF allocation, so it is listed first and marine VHF is split around it", but there is exactly one marine VHF entry (156.000–162.024999 MHz) and NOAA is listed after it, not first. The upper marine range above NOAA is absent, and 162.025–162.400 MHz belongs to no band. The MaxHz value 162_024_999 has an unexplained -1 that the disjointness test does not require (NOAA starts at 162.4 MHz).

Why it matters: A maintainer adding or moving a band trusts this comment to describe the invariant it is maintaining, and will look for the second marine entry that does not exist. BandFor(162_030_000) returns nil, so ley picks NFM with "no band recognised" for a frequency squarely inside marine VHF.

Suggested fix: Either add the second marine range above NOAA (and make the comment true), or rewrite the comment to say marine VHF is truncated below the NOAA block and say why the boundary is 162_024_999.


### q-go-lib-7 — FormatFrequency prints "1000.000 MHz" instead of "1.000 GHz" at the rounding boundary

`go/pkg/leyline/freq.go:56` · P3 · mechanical · confirmed

The unit is chosen from the raw value but the mantissa is then rounded to three decimals, so any value in [999_999_500, 999_999_999] Hz picks MHz and prints as 1000.000 MHz (verified: FormatFrequency(999_999_999) == "1000.000 MHz"). The same happens one decade down: 999_999 Hz prints 999.999 kHz, and values just under 1 MHz round to "1000.000 kHz".

Why it matters: FormatFrequency is the one renderer for every frequency ley prints — device ranges, selector rows, error hints — and its doc promises "the largest fitting SI unit". A tuning-range line reading "24.000 MHz – 1000.000 MHz" for a 1 GHz radio looks like a bug in the device table rather than in the formatter.

Suggested fix: Pick the unit from the rounded value (e.g. compare against 999_999_500 / 999_999.5 / 999.5), or promote to the next unit when the formatted mantissa reaches 1000.


### q-go-lib-8 — GRPCCode has no case for CodeUnavailable, so Error round-trips downgrade to codes.Unknown

`go/pkg/leyline/errors.go:178` · P3 · mechanical · confirmed

GRPCCode maps most stable codes to gRPC codes but omits CodeUnavailable, CodeUnknown, and the literals codeForGRPC can produce ("NOT_FOUND", "CANCELED", "DEADLINE_EXCEEDED"), all of which fall to the default codes.Unknown. FromStatus of a transport failure yields Code == CodeUnavailable, and feeding that Error back through ToStatus emits codes.Unknown.

Why it matters: internal/fakedaemon (daemon.go:254-255) serves errors precisely by calling err.ToStatus()/err.Trailer(), so a fake daemon asked to report UNAVAILABLE or a cancellation sends codes.Unknown on the wire; any client logic keyed on the gRPC code (retry, "daemon not running" detection) sees Unknown instead. codeForGRPC also spells three codes as bare string literals while every other code in the file has a Code* constant, so the two functions can drift apart silently.

Suggested fix: Add constants for NOT_FOUND/CANCELED/DEADLINE_EXCEEDED, add the missing cases to GRPCCode, and add a round-trip test asserting GRPCCode(codeForGRPC(c)) == c for the codes both functions know.


### q-go-lib-9 — WriteParams returns from a Send failure without closing the stream

`go/pkg/leyline/client.go:347` · P3 · scoped · contested

In the send loop, a non-EOF error from stream.Send returns immediately, skipping CloseAndRecv. The client-side stream is then never half-closed nor drained, so grpc-go keeps its transport stream and goroutine alive until the caller's context is cancelled.

Why it matters: For a long-lived process — the MCP adapter, or a TUI holding one context for the session — a burst of failed WriteParams calls accumulates leaked streams and their goroutines for the life of that context, with no error path that ever cleans them up.

Suggested fix: On a Send error, call stream.CloseSend() (or CloseAndRecv and discard) before returning, or give the call its own cancellable context that is cancelled on the error path.

- verifier (comment, confirmed P3): client.go:346-352 returns on a non-EOF Send error without CloseSend, and the only CloseAndRecv is after the loop, so grpc-go holds the stream and its goroutine until the caller's ctx is cancelled — which for the MCP adapter or a TUI is the process session. Real leak, narrow trigger; CloseSend on the error path is the correct contained fix.

- verifier (comment, refuted P3): grpc-go v1.83.2 stream.go:954-964: clientStream.SendMsg has `defer func(){ if err != nil && err != io.EOF { cs.finish(err) } }()`, so any non-EOF Send error has already finished the stream and released its transport stream and goroutines before WriteParams (client.go:346-352) returns. There is no leak to clean up; the missing CloseAndRecv on that path is harmless.


### q-go-lib-10 — Dial takes a context it never uses

`go/pkg/leyline/client.go:127` · P3 · design · contested

Dial's ctx parameter is discarded with `_ = ctx` at the end of the body; grpc.NewClient is lazy and takes no context. The signature advertises a cancellable/deadline-bearing connect that does not exist.

Why it matters: Callers reasonably pass a context.WithTimeout to Dial expecting connect-time bounds, and get none — the first RPC is where the failure shows up. `_ = ctx` also tells the next reader that the parameter is intentionally dead without saying why it is kept.

Suggested fix: Either drop the parameter, or keep it and say in the doc comment that it exists for signature stability / future eager-connect and is not consulted today (replace `_ = ctx` with that comment).

- verifier (comment, refuted P3): Dial's own doc comment already states the contract the finding says is missing: 'The connection is lazy; the first RPC fails with an UNAVAILABLE Error if no daemon is listening' (client.go:89-91), so a caller is told there is no connect-time work to bound. Keeping ctx in a Dial signature is ordinary Go practice and dropping it would be a gratuitous break of the library's API; `_ = ctx` at client.go:127 is taste, not a defect.

- verifier (comment, confirmed P3): client.go:127 is literally `_ = ctx` and grpc.NewClient at :117 takes no context, so the parameter is dead. The 'callers expect connect-time bounds' argument is partly mitigated: the doc at client.go:91-93 already says the connection is lazy and the first RPC is where UNAVAILABLE shows up. What survives is the unexplained dead parameter, which is a P3.


### q-go-lib-11 — bandlookup_test.go reimplements strings.Contains and strings.Index

`go/pkg/leyline/bandlookup_test.go:116` · P3 · mechanical · confirmed

The test file defines its own contains() and indexOf() helpers that duplicate strings.Contains and strings.Index exactly, in a package whose non-test files already import strings.

Why it matters: Sixteen lines of hand-rolled substring search in a test file is code a reviewer has to read and verify before trusting the assertions built on it, and it invites the same helpers to be copied into the next test file.

Suggested fix: Delete both helpers and call strings.Contains at the call sites.


## Go code quality: the fake daemon and e2e (`go/internal/fakedaemon`, `go/internal/e2e`)

Coverage: Read in full: go/internal/fakedaemon/daemon.go, state.go, control.go, jobs.go, telemetry.go, bulk.go, bulk_stream.go, writes.go, devices.go; go/internal/testutil/socket.go; tests read in full: daemon_test.go, streams_test.go, writes_test.go, filedevice_test.go, bulk_internal_test.go, go/internal/e2e/e2e_test.go, go/internal/e2e/stream_test.go. Swift compared for the RPCs the fake implements: Services/ControlService.swift, JobsService.swift, TelemetryService.swift, BulkService.swift (all in full), Session/SessionStore.swift (emit/presence/reap, createCapture, createChannel, destroyChannel, …


### q-go-fake-1 — Fake accepts narrow-mode bandwidths the Swift daemon refuses (0.9·r2 cap missing)

`go/internal/fakedaemon/control.go:198` · P2 · scoped · confirmed

CreateChannel only checks that the channel fits the capture (|offset|+bw/2 <= Fs/2), and the bandwidth ParamWrite only checks 0 < bw <= capture rate (writes.go:196-207). The Swift daemon builds a Channelizer, whose ChannelPlan.plan throws INVALID_ARGUMENT for any non-WFM mode with bw > 0.9·r2 (~43.2 kHz at 2.4 MSPS) — both on create and on every update.

Why it matters: `ley` asking for an NFM channel at 100 kHz (or `set bandwidth 100k`) succeeds against the fake and fails against the real daemon with INVALID_ARGUMENT. Every CLI test of wide-bandwidth handling proves the wrong thing, and the fake happily produces a channel state the daemon cannot reach.

Suggested fix: Add the engine's rule to the fake: for every mode but WFM reject bw > 0.9·r2 where r2 = audioRate(captureRate) (bulk.go already computes exactly that), in CreateChannel and in the bandwidth ParamWrite, with the daemon's INVALID_ARGUMENT code.


### q-go-fake-2 — CancelJob publishes the terminal CANCELLED event before the partial scan is stored

`go/internal/fakedaemon/jobs.go:437` · P2 · scoped · confirmed

CancelJob sets state=CANCELLED, detail="cancelled" and emits the Job event synchronously; runScan only notices at its next dwell boundary (up to 200 ms later) and only then writes detections/coverage/completed_at via keepPartial. The Swift daemon does the opposite order: `store(id, result:...)` runs first and `finish(...)` emits the terminal state afterwards, with detail "stopped in step X of Y, N found".

Why it matters: A client that reacts to the CANCELLED event by calling GetScan (which is what the CLI does after Ctrl-C) races the fake: it can read a Scan with no detections and completed_at_ns == 0, a state the daemon never exposes. The status detail also differs, so any assertion on the post-Ctrl-C summary is testing the fake.

Suggested fix: Have CancelJob flag the job (e.g. a cancel channel) and let runScan write the partial results and then emit the terminal CANCELLED event with the count-bearing detail, so the event is the last thing a cancelled scan does. Also set j.scan.Gains on the cancel path, as finishScan does.


### q-go-fake-3 — Job events carry three different (and one absent) caused_by attributions

`go/internal/fakedaemon/jobs.go:344` · P2 · mechanical · confirmed

setJobDetail, failScan and finishScan emit with `by = nil`, so the Event has no caused_by at all; StartJob and CancelJob emit attributed to the calling client. The Swift daemon publishes every job event through SessionStore.publishJob, which always attributes to `.daemon`.

Why it matters: A client rendering "who did this" or filtering events by caused_by sees the caller for some job events, the daemon for others in the real thing, and an empty ClientInfo for progress events in the fake. daemon_test.go:124 already asserts every event on a watcher carries the caller's client id — a job event on that stream would fail that assertion against the fake but not against the daemon.

Suggested fix: Attribute every job event to a single daemon ClientInfo (the one state.go:217 already builds for presence work) so the fake matches publishJob, and never pass nil to emit.

- verifier (comment, downgraded P3): Divergence is real (jobs.go:344/381/397 emit with by=nil; StartJob :99 and CancelJob :445 attribute to the caller; SessionStore.swift:475-476 publishJob always uses .daemon), but the stated test consequence is wrong: daemon_test.go:124 would fail against the real daemon too, since a job event there carries .daemon, not the caller. Actual CLI impact is limited to change.go:95 rendering — session.go:365 mine() is only consulted for WriteRejected/tune events — so this is cosmetic, not P2.


### q-go-fake-4 — WriteParams applies center_hz / sample_rate writes while a scan is sweeping the radio

`go/internal/fakedaemon/writes.go:156` · P2 · scoped · confirmed

applyLocked has no sweeping check: a capture retune or rate change is applied and confirmed while d.sweeping names the capture's device. The Swift store calls `try refuseIfSwept(id)` first on both .centerHz and .captureSampleRate and rejects with DEVICE_SWEEPING. The fake only refuses sweeping in CreateCapture and CreateChannel.

Why it matters: `ley tune` issued during a `ley scan` is accepted by the fake (and the CLI prints a confirmation) but rejected by the daemon with a WriteRejected(DEVICE_SWEEPING). The one code path where the CLI must show the "a scan is sweeping this radio" message for a write cannot be exercised against the fake, and a test of the accepted case encodes behaviour the daemon does not have.

Suggested fix: Reject center_hz and capture_sample_rate writes with DEVICE_SWEEPING (via rejectLocked) when d.sweeping equals the capture's device id.


### q-go-fake-5 — Telemetry fabricates a squelch-close transition on a subscriber's first tick

`go/internal/fakedaemon/telemetry.go:110` · P2 · scoped · confirmed

The edge test is `if prev, seen := squelchOpen[ch.ChannelId]; !seen || prev != open`, so the first tick of every subscription emits a SquelchTransition whatever the state is. When the channel's squelch is set and the synthetic power is below it, that first message is open=false with DurationSamples = st.SampleIndex - 0 (the whole elapsed capture) and PeakSnrDb/PeakAudioDbfs = 0.0 from the empty maps.

Why it matters: A CLI transmission view subscribing to a capture that has been running 10 s at 2.4 MSPS is told a transmission just ended after 24,000,000 samples that never started, with a peak of 0 dB. The file's own comment (telemetry.go:114) says NaN means "not measured" and is not the same as a peak of zero, and the Swift daemon only forwards real engine edges (TelemetryService.swift:89 `.squelch(...)`).

Suggested fix: Seed squelchOpen[ch] on first sight without emitting (or emit only when `seen && prev != open`); if a first-sight open is wanted, emit it only for open==true, which is the state that has no summary to fake.


### q-go-fake-6 — CreateChannel records no interactive activity and emits no capture event

`go/internal/fakedaemon/control.go:212` · P2 · scoped · confirmed

The fake's CreateChannel stores the channel and emits only the Channel event. The Swift store calls `touchActivity(captureID, by:)` and `emitCapture(captureID, by:)` before emitting the channel, so creating a channel both stamps last_interactive_write_ns and produces a Capture event.

Why it matters: Two visible consequences: (1) the fake's own busyReason (jobs.go:127) can never report "somebody was tuning this radio N s ago" after a channel was created and destroyed, so the don't-disturb window that makes a real `ley scan` decline is untestable and a test will conclude the radio is free; (2) an event-stream test counts one event where the daemon sends two, in a different order.

Suggested fix: In CreateChannel, stamp c.Activity.LastInteractiveWriteNs for non-job clients and emit the capture before the channel, matching writes.go's touch/emit pairing.


### q-go-fake-7 — Bulk.Stream accepts a second reader and never clears `reading`, so an abandoned stream is never reaped

`go/internal/fakedaemon/bulk_stream.go:26` · P2 · scoped · confirmed

Stream sets `s.reading = true` and never resets it on return, and it does not check whether a reader already exists. The reap timer is armed once, 10 s after Subscribe (bulk.go:176), so once anything has read the stream the entry lives in d.streams until Unsubscribe or a channel/capture teardown. The daemon's registry claims the reader exclusively (FAILED_PRECONDITION "stream already has a reader") and re-arms a 10 s grace on endReading, reaping the subscription if nobody comes back.

Why it matters: A client that opens Stream twice gets two independent frame sequences (both starting at seq 1) from the fake and an error from the daemon. A client whose Stream RPC drops keeps a live subscription in the fake for ever, while the same id is gone from the daemon 10 s later — so reconnect-after-drop tests pass against the fake and fail in production.

Suggested fix: Refuse a second reader with FAILED_PRECONDITION, and on handler return clear s.reading under the lock and arm a fresh readerReapWait timer that drops the stream if nobody has begun reading again.

- verifier (comment, downgraded P3): Facts check out (bulk_stream.go:26 sets reading with no claim check and no reset; the reap timer is one-shot at bulk.go:176; StreamRegistry.swift:248/255 claims exclusively and re-arms the grace). But no client can reach the double-reader path — pkg/leyline client.go:398-403 always pairs Subscribe with exactly one Stream — and the un-reaped subscription is a bounded leak inside a test process, so this is fidelity polish rather than a P2. The suggested fix is correct if taken.


### q-go-fake-8 — A NaN gain write is silently snapped to the first table entry instead of rejected

`go/internal/fakedaemon/writes.go:260` · P3 · scoped · confirmed

applyGainLocked passes any db straight to snapGain, whose comparisons are all false for NaN, so it returns ValidDb[0] — 0 dB on the fake RTL-SDR — and the write is reported applied. The Swift store checks `!db.isFinite` first and throws INVALID_ARGUMENT ("gain db must be finite"), precisely so `snapped` is never searched with NaN. Separately, the fake rejects `auto:false` on an element with SupportsAuto == false, where Swift only guards `auto:true`.

Why it matters: A CLI bug that lets NaN reach a gain write (a bad parse of "auto", say) looks successful against the fake and deafens the capture to 0 dB, while the daemon rejects it; the missing case means the fake can never produce the INVALID_ARGUMENT that a client's error path is supposed to handle.

Suggested fix: Reject non-finite gain db with INVALID_ARGUMENT before the element lookup, and only require SupportsAuto for auto:true.

- verifier (comment, downgraded P3): Both divergences are real (SessionStore.swift:770 rejects non-finite db before the element lookup; :783 guards supportsAuto only for auto:true, where writes.go:253-258 also rejects auto:false), but neither is reachable today: nothing in the CLI parses a gain into NaN, and the fake's only gain element (TUNER) has SupportsAuto true, so the auto:false branch cannot fire. Worth the two-line alignment, not worth P2.

- verifier (comment, downgraded P3): Both halves are real (writes.go:260 passes db straight to snapGain, whose comparisons are all false for NaN so it returns ValidDb[0] = 0 dB for R820TGains at devices.go:21; writes.go:253-255 rejects auto:false when !SupportsAuto where SessionStore.swift:783-796 only guards auto(true)), but neither is reachable from `ley`: set.go:404-408 and session.go:562-566 only ever send auto:true or a db that already passed leyline.CheckGain and snapGain. Fake-fidelity nit rather than a P2.


### q-go-fake-9 — MeterInterval above one second panics the telemetry handler with a divide by zero

`go/internal/fakedaemon/telemetry.go:69` · P3 · mechanical · confirmed

`activityEvery := time.Second / d.opts.MeterInterval` is integer Duration division, so any MeterInterval > 1 s yields 0 and telemetry.go:154 evaluates `tick % int64(0)`, which panics. Options.MeterInterval is documented as "the Meter cadence" with no stated upper bound.

Why it matters: A test that sets MeterInterval to 2 s to quiet the meters takes down the whole in-process fake daemon with an integer-divide-by-zero panic on the first tick, in a goroutine, so the failure reads as a crashed test binary rather than a bad option.

Suggested fix: `activityEvery := max(1, int64(time.Second/d.opts.MeterInterval))` and use that directly.


### q-go-fake-10 — Detections ignore the subscription's capture scope

`go/internal/fakedaemon/telemetry.go:78` · P3 · scoped · confirmed

The detection fan-out is gated only on `chanFilter == ""`; capFilter is never consulted, so a subscriber scoped to one capture receives every detection any scan produces. The Swift service asks the job hub for `detections(captureID: capFilter)`.

Why it matters: A CLI view scoped to its own capture is shown detections from an unrelated sweep, and a test asserting that scoping keeps foreign detections out passes against the fake for the wrong reason.

Suggested fix: Stamp the sweeping capture's id on fake detections and skip those whose capture id does not match capFilter.


### q-go-fake-11 — A second StartJob on a busy device resets the running scan's dedup epoch

`go/internal/fakedaemon/jobs.go:97` · P3 · scoped · confirmed

StartJob unconditionally sets `d.detectionEpoch = len(d.detectionLog)` before runScan discovers that another scan already owns the radio and fails the new job. publishDetection dedups only from detectionEpoch onward, so the still-running first scan starts re-publishing carriers it already reported.

Why it matters: Every telemetry subscriber sees the same carrier twice from one sweep, which the comment at jobs.go:35 explicitly promises will not happen ("deduped within a scan"). A CLI detection table that appends rows shows duplicates after any declined second scan.

Suggested fix: Move the epoch reset into runScan, next to where the sweep claims d.sweeping, so only a scan that actually starts opens a new dedup epoch.


### q-go-fake-12 — `renderLocked` takes a channel it never uses, and Stream looks it up every tick to pass it

`go/internal/fakedaemon/bulk_stream.go:105` · P3 · mechanical · confirmed

renderLocked's `ch *leylinev1.Channel` parameter is unused — renderFFTLocked walks d.channels itself and the audio/IQ renderers take only their params. The Stream loop does a map lookup per frame (bulk_stream.go:52-54) solely to supply it.

Why it matters: A reader assumes audio rendering depends on the channel (it does not), and the per-tick lookup is dead work under the daemon lock on the fake's hottest loop.

Suggested fix: Drop the parameter and the per-tick channel lookup.


### q-go-fake-13 — Dead `_ = id` in the job-cancelling half of reap

`go/internal/fakedaemon/state.go:225` · P3 · mechanical · confirmed

The loop ranges `for id, j := range d.jobs` but only uses j; `_ = id` at the end silences the unused variable instead of the loop simply ranging over values.

Why it matters: It reads as if the id were meant to be used (deleting the job, say) and the line was left behind; the next reader has to prove it is nothing.

Suggested fix: `for _, j := range d.jobs` and delete the line.


### q-go-fake-14 — DEVICE_SWEEPING from CreateChannel targets the device where the daemon targets the capture

`go/internal/fakedaemon/control.go:341` · P3 · mechanical · confirmed

refuseIfSweeping always sets ErrorDetail.target to the device id. The Swift store uses refuseIfSwept(captureID) inside createChannel and the param writes, so its DEVICE_SWEEPING error carries the capture id; only createCapture targets the device.

Why it matters: A client that resolves ErrorDetail.target to name the object in a message ("cap_… is being swept") prints a device id against the fake and a capture id against the daemon, and a test pinning the target encodes the wrong one.

Suggested fix: Give refuseIfSweeping an explicit target argument: the device id from CreateCapture, the capture id from CreateChannel and from the writes.


### q-go-fake-15 — After a playback EOF the fake keeps serving frozen frames to any new bulk subscriber

`go/internal/fakedaemon/bulk_stream.go:59` · P3 · scoped · confirmed

The EOF check is gated on `c.State == CAPTURE_ACTIVE`, and fileEOFLocked leaves the capture in d.captures as CAPTURE_DETACHED. Bulk.Subscribe never checks capture state, so a stream created after EOF passes the gate, never re-detects EOF, and emits frames for ever with sampleIndex pinned at file.samples.

Why it matters: A client that re-subscribes after the "file ended" event gets an endless stream of synthetic frames on a detached capture with a stopped timebase — a state the daemon (which tears every stream down on the detached capture and has no source to read) cannot produce, so a reconnect test would conclude the stream is healthy.

Suggested fix: Refuse Bulk.Subscribe on a capture that is not CAPTURE_ACTIVE, and in Stream end the RPC whenever the capture is not active rather than only on the EOF edge.


### q-go-fake-16 — Nil-capture guard in Bulk.Subscribe is written after the dereference it protects

`go/internal/fakedaemon/bulk.go:114` · P3 · mechanical · confirmed

In the ChannelId branch `c = d.captures[ch.CaptureId]` may be nil and is immediately used as `audioRate(c.GetSampleRate())`; because capture is a struct embedding *leylinev1.Capture, the promoted getter dereferences the nil *capture and panics. The `if c == nil { ... "channel has no capture" }` guard sits at bulk.go:129, after the switch.

Why it matters: The guard reads as protecting the whole branch but cannot; if the invariant it exists for ever breaks (a channel outliving its capture), the fake panics inside a gRPC handler instead of returning CAPTURE_NOT_FOUND.

Suggested fix: Move the nil check to immediately after the capture lookup in the ChannelId branch (or drop the unreachable one and check once, before the audio negotiation).


### q-go-fake-17 — Test named for since_seq 0 never sends since_seq

`go/internal/fakedaemon/daemon_test.go:393` · P3 · mechanical · confirmed

TestWatchEventsSinceSeqScoped's comment claims "seq 0 replays nothing", but the assertion uses `c.Events(evCtx, nil)`, which sends no scope and therefore no since_seq field at all. An explicit since_seq = 0 is a different case (proto3 presence: it replays the entire retained window), and both the fake and the daemon treat it that way.

Why it matters: The one behaviour the comment says is pinned is not covered: someone could change the fake to skip replay when since_seq is present-but-zero and this test would still pass, while the daemon (`request.hasSinceSeq ? request.sinceSeq : nil`) would keep replaying everything.

Suggested fix: Either fix the comment to say "an absent since_seq replays nothing", or add a case that sets since_seq explicitly to 0 and asserts the full window is replayed.


### q-go-fake-18 — Event tests sleep 20 ms to hope the watcher registered

`go/internal/fakedaemon/daemon_test.go:83` · P3 · scoped · confirmed

TestLifecycleAndEvents (and streams_test.go:40) call c.Events and then `time.Sleep(20 * time.Millisecond) // let the watcher register`, because the server handler that registers the watcher runs asynchronously. The test then requires 6 events within 2 s and fails with "only N events" if any were emitted before registration.

Why it matters: On a loaded machine the handler can miss the 20 ms window and the test fails in a way that reads as a daemon bug rather than a scheduling one — and the codebase already has the deterministic fix in hand.

Suggested fix: Subscribe with `leyline.ScopeSince(nil, st.EventSeq)` (as TestWatchEventsSinceSeq does) and drop the sleep; nothing emitted before registration can then be missed.


## Swift code quality: the DSP and hot path (`EngineCore/DSP`, rings, buffers, the two DSP cores)

Coverage: Read in full (every non-test file in my list): engine/Sources/EngineCore/Buffers.swift, Rings.swift, Capture/CaptureDSPCore.swift, Channels/ChannelDSPCore.swift, and all of DSP/: Channelizer.swift, Demodulators.swift, EnergyDetector.swift, FFT.swift, FIR.swift, Kernels.swift (both PortableKernels and the #if canImport(Accelerate) AccelerateKernels half, compared signature by signature for parity), NCO.swift, Persistence.swift, SpectrumLadder.swift, SubAudible.swift, SweepPlan.swift. Also read, to check specific claims: Channels/DefaultChannelEngine.swift:78-135 and :230-275 (sub-audible task, …


### q-swift-dsp-1 — FIRDecimator.process leaves `pending` negative when decimation > tapCount

`engine/Sources/EngineCore/DSP/FIR.swift:107` · P2 · scoped · confirmed

`consumed = outputs * decimation` can exceed `total` (the samples actually held) whenever `decimation > taps.count`. `remain = total - consumed` is then negative, the `remain > 0` guard skips the memmove, and `pending` is stored negative. The next call does `(workRe + pending).update(from: re, count: count)`, writing `count` floats starting *before* the allocation.

Why it matters: Heap corruption with no precondition to catch it. Concretely: taps=3, decimation=8, pending=2 (post-reset), count=9 -> total=11, outputs=(11-3)/8+1=2, consumed=16, remain=-5, pending=-5; the following process() writes 5 floats below workRe/workIm. No current caller configures d > nTaps (every design path yields taps >= 4*d), so this is latent, but nothing in the class states or checks that contract, and RealFIRDecimator has the identical arithmetic at :166-170.

Suggested fix: Add `precondition(decimation <= taps.count)` to both initializers (the design comment already assumes it), or handle the skip explicitly: when `remain < 0`, set `pending = 0` and carry a `skip = -remain` that the next `process` drops from the head of its input.


### q-swift-dsp-3 — ChannelDSPCore.reset() has no caller: a stream restart keeps stale filter and meter state

`engine/Sources/EngineCore/Channels/ChannelDSPCore.swift:315` · P3 · scoped · confirmed

`reset()` documents itself as 'e.g. after a stream restart', but nothing in Sources/ or Tests/ ever calls it. A device rebound at the same rate keeps the same core (DefaultChannelEngine only rebuilds on retune/structural change), so the channelizer's FIR history, NCO phase and PowerMeter noise-floor buckets carry straight across the gap.

Why it matters: After a rebound the first blocks are filtered against taps-1 samples from before the discontinuity (an audible transient), and the meter's running-minimum floor still holds pre-gap buckets, so `snrDB` and the squelch decision are computed against a floor measured from a different stream. Were the method wired up it would still be incomplete: it leaves `squelch`, `openSamples`, `peakPowerDBFS`, `peakSNRDB`, `audioSumSquares`, `audioSamples` and `audioPeak` untouched, so a transmission open across the restart would report an `openSamples` duration that spans the dead air.

Suggested fix: Call it from the capture restart path (alongside `CaptureDSPCore.expectNewAnchor()`), and extend it to clear the squelch/transmission accumulators (`openSamples`, both peaks) and the audio-meter accumulators; or delete it and document that a restart deliberately keeps filter state.

- verifier (comment, downgraded P3): Verified ChannelDSPCore.reset() (:314-320) has no caller anywhere in Sources/ or Tests/. But the consequences are inferred rather than demonstrated (a rebind at the same rate is rare, the meter floor is a 5 s running minimum that re-adapts), so this is an unwired public method a maintainer trips on, not a live bug; the honest resolution may well be 'delete it or document that state is deliberately carried', which is P3-sized.

- verifier (comment, downgraded P3): Dead code confirmed: ChannelDSPCore.reset() at Channels/ChannelDSPCore.swift:314-319 has no caller in Sources/ or Tests/ (only the inner channelizer/demodulator/meter resets show up), and a same-rate restart does keep the core — DefaultCaptureEngine.restoreStreamingOrDetach (:148-155) re-enters beginStreaming without touching sampleRate, so DefaultChannelEngine only rebuilds on retune/config (rebuild at :251-255). But the consequence is small: a taps-1 filter smear (<1 ms) and a carried …


### q-swift-dsp-4 — SubAudibleDetector.reset() is never called, so phase history spans transmissions

`engine/Sources/EngineCore/DSP/SubAudible.swift:91` · P2 · scoped · confirmed

The doc says reset() is 'Called when the squelch closes: the next transmission is a different one, and carrying phase across it would fabricate a stable estimate'. No production code calls it — the only detector instance lives in `DefaultChannelEngine.makeSubAudibleTask`, which never touches squelch state.

Why it matters: The stated failure mode is live: `prevPhase` and `recent` carry across a squelch close, so the first hops of a new transmission are measured against the previous transmission's phase and are stability-tested against its frequencies. That is a confidently wrong tone frequency at exactly the moment a client is told a new transmission started — the outcome invariant 12 and this file's own header exist to prevent.

Suggested fix: Feed squelch state into the sub-audible task (it already reads the core) and call `detector.reset()` on every close edge; if that plumbing is not wanted in v0, delete the method and change the header to say phase is carried indefinitely.

- verifier (comment, downgraded P3): The fact holds — SubAudibleDetector.reset() (DSP/SubAudible.swift:90-94) has no production caller; DefaultChannelEngine.makeSubAudibleTask (:80-127) never reads squelch state. The stated failure mode is refuted: the tap is filled inside NFMDemodulator.tapSubAudible (Demodulators.swift:147-158), which runs on every block before the squelch zeroing in ChannelDSPCore.process (:265-278), so the detector analyses a continuous stream and prevPhase is always the immediately preceding hop, never a …


### q-swift-dsp-5 — First window after reset reports the nominal bin centre as a measured tone

`engine/Sources/EngineCore/DSP/SubAudible.swift:141` · P2 · scoped · confirmed

When `havePrev[best]` is false (first window, or first after a reset) `measured` stays at `CTCSS.tones[best]` — the nominal ladder value, not a measurement. That value then flows into `out.toneHz`, `recent`, `classify` (which trivially matches it exactly) and `confidence`, and `out.detected` can be set true from that single window.

Why it matters: The detector's whole premise is that a 2 Hz bin cannot name a tone on a 2.3 Hz ladder and that the frequency must come from inter-window phase advance. On the first window it publishes a fully classified standard tone whose frequency was never measured: a strong 68.1 Hz tone lands in the 67.0 bin and is reported as exactly 67.0 with confidence > 0. `DefaultChannelEngine` publishes that first result immediately (it is edge-triggered on identity, with `lastReported == nil` counting as changed).

Suggested fix: Leave `out.detected` false (reason: 'no phase reference yet') and skip the `recent.append` when `!havePrev[best]`, so the first classified answer always rests on a measured frequency.

- verifier (comment, downgraded P3): Behaviour confirmed at SubAudible.swift:141-147 (measured stays CTCSS.tones[best] when !havePrev[best]), :152-155 (fed into toneHz and recent), :175-182 (the spread test is skipped at recent.count==1, so detected can be true on that first window) and classify/confidence then trivially match the nominal value; DefaultChannelEngine.swift:117-123 publishes it (lastReported nil counts as changed). Downgraded because it is bounded to one window per core lifetime, self-corrects at the next hop (~128 …


### q-swift-dsp-6 — Doc comment for audioSumSquares is attached to subAudibleTap

`engine/Sources/EngineCore/Channels/ChannelDSPCore.swift:177` · P3 · mechanical · confirmed

Two doc comments were merged: the paragraph explaining why the audio energy accumulator is a Double sits directly above `subAudibleTap`, followed by the sub-audible paragraph. `audioSumSquares` four lines later has no comment at all.

Why it matters: A reader (or a doc tool) sees `subAudibleTap` documented as 'Audio energy accumulated since the last meter record ... The sum is a Double because a 100 ms interval at 48 kHz is 4800 squares and Float would drift', which describes a different member entirely, and the rationale for the Double accumulator is orphaned from the field it explains.

Suggested fix: Move the first two lines of the comment down onto `audioSumSquares`.


### q-swift-dsp-7 — An .f32 buffer delivered to a capture commits an empty block and is counted as a ring overrun

`engine/Sources/EngineCore/Capture/CaptureDSPCore.swift:171` · P3 · scoped · confirmed

`deliver`'s `.f32` case commits a zero-count block into the ring, calls `noteOverrun()` and returns. A device handing the capture real audio is a programming error, but it is recorded as if the ring had been full, and the committed block carries the raw device `time` rather than the rebased `first` used on every other path.

Why it matters: The overrun counter is what `CaptureStats.overruns` and the once-a-second warning report; a misrouted device would show up as 'ring overrun: N blocks dropped' and send someone hunting a throughput problem that does not exist. The zero-count commit also spends a ring slot and pushes a SampleTime that is inconsistent with the capture timeline every other commit uses.

Suggested fix: Do not acquire a slot for an unsupported format: check `buffer.format != .f32` before the loop, and report it as its own counter or an assertion rather than as a ring overrun.


### q-swift-dsp-8 — Four XCTest failure messages have escaped interpolations and print literal `\(expr)`

`engine/Tests/EngineCoreTests/SubAudibleTests.swift:192` · P3 · mechanical · confirmed

The messages use `\\(` in source, which is a literal backslash followed by an open paren, not an interpolation. When these assertions fail the message reads `the tap produced \(ring.available) samples` instead of the value.

Why it matters: These are exactly the assertions whose diagnostic value matters — a tap that under-produces, a detection that failed with a reason string, a classification that picked the wrong tone. The failure output tells the reader nothing, so every failure needs a re-run with a print added.

Suggested fix: Replace `\\(` with `\(` at all four sites.


### q-swift-dsp-9 — testResetForgetsHistory passes whether or not reset() does anything

`engine/Tests/EngineCoreTests/SubAubibleTests.swift:134` · P3 · scoped · confirmed

The only assertion is `XCTAssertFalse(after.toneHz.isNaN)`. `toneHz` is set to `CTCSS.tones[best]` on every path that reaches it, so the assertion holds identically with the `reset()` call deleted. The test named after the reset contract does not exercise it.

Why it matters: The behaviour the test claims to protect — that a stale phase does not produce a confident wrong answer after a squelch close — is unverified, and `reset()` turns out to have no production caller at all (see the dead-code finding). A test that cannot fail hides that.

Suggested fix: Assert the observable consequence: after `reset()` the estimate is exactly the nominal bin value (`XCTAssertEqual(after.toneHz, 100.0)`), and without the reset a second analyse of the same window returns a phase-derived value that differs from it.


### q-swift-dsp-10 — CTCSS.neighbourGap returns the full gap but is documented as half of it

`engine/Sources/EngineCore/DSP/SubAudible.swift:23` · P3 · mechanical · confirmed

The doc says 'Half the distance to the nearest neighbour of tones[i]: the widest a measurement may sit from a tone and still be unambiguously that one'. The body returns `min(t[i]-t[i-1], t[i+1]-t[i])`, the full distance; callers apply their own 0.4 factor. The `gap.isFinite ? gap : 10` fallback is also unreachable — the tone table has 38 entries, so at least one neighbour always exists.

Why it matters: Anyone adding a caller and trusting the comment gets a tolerance twice as wide as intended, which is precisely the 'name the wrong tone' failure this module is built to avoid. The dead fallback additionally suggests a one-element table is supported.

Suggested fix: Reword the comment to 'Distance to the nearest neighbour', or return `gap / 2` and drop the factor at the call sites. Drop the unreachable `: 10` branch.


### q-swift-dsp-11 — confidence() hardcodes the 2.3 Hz gap instead of the tone's own neighbour gap

`engine/Sources/EngineCore/DSP/SubAudible.swift:213` · P3 · scoped · confirmed

`classify` computes its tolerance as `min(0.01 * t, 0.4 * neighbourGap(i))`; `confidence` recomputes the same idea as `min(0.01 * standard, 0.4 * 2.3)` with the tightest gap in the table baked in as a literal.

Why it matters: The two tolerances disagree for every tone whose neighbours are wider apart than 2.3 Hz (most of the table: 203.5 is 6.7 Hz from its neighbour). A measurement well inside `classify`'s acceptance can score a near-zero `near` term, so confidence understates cleanly resolved tones, and any future edit to the ladder or to the 0.4 factor has to be found in two places.

Suggested fix: Give CTCSS a `tolerance(forIndex:)` (or `tolerance(for standard: Double)`) helper and call it from both `classify` and `confidence`.


### q-swift-dsp-12 — ChannelPlan.maxNarrowBandwidthHz duplicates the d1/r1/d2 arithmetic of plan()

`engine/Sources/EngineCore/DSP/Channelizer.swift:29` · P3 · scoped · confirmed

`maxNarrowBandwidthHz` recomputes `d1`, `r1` and `d2` inline, and `plan()` independently recomputes the same three plus the `0.9 * r2` limit in its error path. Three copies of the same decimation math.

Why it matters: The public accessor and the validation that actually rejects a channel can drift: change the 240 kHz or 48 kHz constant in one place and the CLI/daemon starts advertising a maximum bandwidth that `plan()` then refuses (or, worse, accepts a bandwidth the accessor said was unavailable).

Suggested fix: Factor the rate ladder into one `static func rates(captureRate:) -> (d1: Int, r1: Double, d2: Int, r2: Double)` and have both `plan()` and `maxNarrowBandwidthHz` call it.


### q-swift-dsp-13 — Persistence row remap is documented as 'nearest bin' but truncates

`engine/Sources/EngineCore/DSP/Persistence.swift:57` · P3 · mechanical · confirmed

The comment says 'Nearest source bin'; `b * row.count / bins` is integer division, i.e. the floor of the mapped position, which is up to a full source bin low.

Why it matters: Folding a 2048-bin ladder row into a 1024-bin histogram systematically biases every cell toward the lower-frequency neighbour, so a narrow carrier draws half a bin left of where the waterfall shows it. A maintainer reading the comment will not look for that.

Suggested fix: Either implement nearest — `(b * row.count + bins / 2) / bins` — or change the comment to say the mapping floors.


### q-swift-dsp-14 — FloatRing concurrency test's producer can spin forever if the consumer gives up

`engine/Tests/EngineCoreTests/RingsTests.swift:78` · P3 · scoped · confirmed

The consumer thread bounds itself with `spins < 50_000_000` and then signals `done` and exits. The producer loop on the test thread has no bound: `if ring.free < n { continue }` spins until space appears, which never happens once the consumer has stopped draining.

Why it matters: A regression that stalls the consumer turns this test into an infinite hang instead of a failure — the `done.wait(timeout: 20)` assertion below is never reached because the producer never returns. CI blocks until the job times out with no useful message.

Suggested fix: Give the producer a deadline (`Date()` or a spin cap) and `XCTFail` when it expires, so a stalled consumer fails the test rather than hanging it.


### q-swift-dsp-15 — detect() silently ignores a single-bin believe window that windowFloorDBFS still reports on

`engine/Sources/EngineCore/DSP/EnergyDetector.swift:164` · P3 · mechanical · confirmed

`detect` guards `last > first` and returns no hits when the believed window rounds to a single bin, while `windowFloorDBFS` on the same window guards `last >= first` and happily returns a floor for it.

Why it matters: For a window one bin wide the pair reports 'here is the noise floor, and nothing was found' when the one searchable bin was never tested — the quiet wrong answer the sweep geometry doc is written against. The two guards also disagree for no stated reason, so a reader cannot tell which is intended.

Suggested fix: Use `last >= first` in `detect` so the single-bin case is searched, or make `windowFloorDBFS` return NaN under the same condition and say why in a comment.


### q-swift-dsp-16 — Unused `cap` local in testPowerMeterAndSquelch

`engine/Tests/EngineCoreTests/DSPSpectrumTests.swift:156` · P3 · mechanical · confirmed

`let cap = CaptureID()` is declared in the middle of the meter/squelch test and never used — the test never builds a SampleTime. Every other `let cap` in the file feeds a `ladder.process` call.

Why it matters: It compiles with a 'never used' warning, and it reads as if the test were meant to do something with a capture timeline that it does not, inviting a maintainer to wonder what is missing.

Suggested fix: Delete the line.


### Refuted

- **q-swift-dsp-2** PersistenceAccumulator.add blocks the DSP thread behind a whole-histogram scan (`engine/Sources/EngineCore/DSP/Persistence.swift:53`) — The contention it describes does not exist: the only caller of snapshot/rows is PersistenceFrameSink.write (StreamSources.swift:176-193), which runs on the same DSP thread that calls add, and `peak` has no production caller at all (grep over Sources/LeylineDaemon). The lock is uncontended today, so …


## Swift code quality: devices, engines, sinks, the S2 harness

Coverage: Read in full: engine/Sources/EngineCore/Devices/{DeviceRegistry,FilePlaybackDevice,IQFile,RTLSDRDevice,RTLTCPDevice}.swift; Capture/DefaultCaptureEngine.swift; Channels/DefaultChannelEngine.swift; {Model,Identifiers,BlockingWork,Signposts}.swift; Sinks/{CallbackSink,NullSink,CoreAudioSink}.swift; S2Throughput/{SyntheticDevice,main}.swift. Also read LeylineDaemon/Server.swift:140-170 and SessionStore.swift:285-310 only to confirm the attachVirtualDevice and device-event claims. Tests: DevicesTests.swift and CaptureTests.swift read by function list plus the full bodies of the helpers/fakes …


### q-swift-control-1 — RTLSDRDevice.close() re-enters its own NSLock and deadlocks on the leaked-thread path

`engine/Sources/EngineCore/Devices/RTLSDRDevice.swift:358` · P1 · mechanical · confirmed

close() runs its body inside withLock (line 345) and, on the branch where stopStreaming gave up and left the USB thread detached, interpolates descriptor.id.string into the log message. descriptor is a computed property that takes the same non-recursive NSLock (lines 141-144), so the thread deadlocks on itself while still holding the device lock. Every later caller (descriptor, gains, tune, stopStreaming) then blocks behind it and the capture actor that awaited close() never returns.

Why it matters: This is exactly the path the surrounding comment describes: stopStreaming timed out after 3 s with thread still recorded (wedged libusb loop), or a second close() after an earlier leak left dev == nil with thread set. Instead of logging and leaking the handle as designed, the daemon wedges the capture actor and every client waiting on it. No test covers it because a test that did would hang.

Suggested fix: Interpolate _descriptor.id.string inside the critical section (every other in-lock message already does, e.g. :489-490), or snapshot the id string before taking the lock.


### q-swift-control-2 — Registry never refreshes rtlIndex for a dongle one of our captures holds

`engine/Sources/EngineCore/Devices/DeviceRegistry.swift:447` · P2 · scoped · confirmed

In applyProbes the 'ours' case (state .inUse and not heldExternally) builds a descriptor and then hits 'if ours { continue }' at line 447, skipping the block at 448-454 that is the only place entry.rtlIndex and rtl.setIndex are updated for a healthy device. So while a capture streams, a USB re-enumeration that shifts the dongle's index is never recorded; the lines 442-446 that build 'd' are dead work on this path too.

Why it matters: poll() builds its 'claimed' set from entry.rtlIndex (line 265-267) and the probe gate keys on the same stale index (line 292-303). Two dongles at index 0 and 1, a capture holding index 1: unplug index 0, our dongle becomes index 0, claimed is still {1}, so every poll calls rtlsdr_open on the dongle we are actively streaming from. That breaks the documented property that the probe 'never races a capture's own rtlsdr_open' and makes librtlsdr print an open failure once per second forever.

Suggested fix: Before the 'if ours { continue }' early exit, record the index the same way the held branch does at line 421: if probe.index != entry.rtlIndex, call rtl.setIndex(probe.index), set entry.rtlIndex and store the entry (no event needed, the descriptor is unchanged).


### q-swift-control-3 — attachVirtualDevice silently drops a duplicate device without closing it, leaking a live rtl_tcp connection

`engine/Sources/EngineCore/Devices/DeviceRegistry.swift:199` · P2 · scoped · confirmed

attachVirtualDevice dedupes on the identity key and returns the existing descriptor, discarding the device it was handed. The only caller opens the device first (Server.swift:153 'try await device.open()' then :154 attachVirtualDevice), so on a duplicate the second RTLTCPDevice keeps its connected socket and its running reader thread for the life of the daemon, with nothing holding a reference that could close it.

Why it matters: Two identical rtl_tcp endpoints in the daemon config (same host:port listed twice) leak a socket and a userInteractive thread, and worse: rtl_tcp serves one client at a time, so the second connection is the one the server keeps and the registered device is the one that gets dropped, leaving a registered device whose link is dead from the moment it is attached.

Suggested fix: Make attachVirtualDevice async and 'await device.close()' before returning the existing descriptor when the incoming instance is not identical (=== check), or have Server.attachRemoteDongles attach first and open afterwards. attachFileDevice has the same shape but its discarded instance owns nothing, so only the virtual path needs the fix.


### q-swift-control-4 — FilePlaybackDevice swallows a mid-file read error: the stream stops with no event and no log

`engine/Sources/EngineCore/Devices/FilePlaybackDevice.swift:192` · P2 · mechanical · confirmed

The playback loop does 'do { n = try reader.read(...) } catch { break }'. The DEVICE_IO error IQFileReader.read throws on a failed read(2) is discarded and the loop exits with hitEOF still false, so transition(to: .disconnected) at line 213-217 is skipped. The device stays .available, streaming stays true, and no hook fires.

Why it matters: An I/O error on the samples file (a removed USB volume, a truncated fixture on a network mount) leaves the capture ACTIVE with no samples arriving and no event on any client's watch stream; clients see a silent stall they cannot diagnose. Contrast with EOF, which is reported as a device loss.

Suggested fix: Capture the error, log it, and take the same disconnect path as EOF (set hitEOF or a separate failed flag, then transition(to: .disconnected)).


### q-swift-control-5 — FilePlaybackDevice.stopStreaming blocks a cooperative-pool thread on a semaphore for up to a full block of pacing

`engine/Sources/EngineCore/Devices/FilePlaybackDevice.swift:158` · P2 · scoped · confirmed

stopStreaming is async but joins the playback thread with a bare joined.wait(). The playback thread only checks isCancelled() after its nanosleep (lines 198-207), so the wait lasts up to one block of real-time pacing. This is called from DefaultCaptureEngine.stop()/setSampleRate/deviceLost, i.e. from an actor running on the Swift concurrency pool, which is exactly what BlockingWork.swift was added to avoid.

Why it matters: blockSize is 16384 samples, so a 48 kSPS fixture parks a pool thread for ~340 ms per stop and a 16 kSPS one for ~1 s; the pool has only as many threads as cores, so a few concurrent capture teardowns can starve every other actor in the daemon. Concurrent stopStreaming calls are worse: streaming is only cleared after the join, so a second caller also waits on the single-signal semaphore and never wakes.

Suggested fix: Run the join through BlockingWork.run (as RTLSDRDevice.open and RTLTCPDevice.open do), and have the pacing sleep wake on cancel (sleep in slices, or signal a condition) so the join is short.


### q-swift-control-6 — RTLSDRDevice.streamError has a locking getter and an unlocked public setter

`engine/Sources/EngineCore/Devices/RTLSDRDevice.swift:500` · P2 · mechanical · confirmed

streamError's getter takes the device lock while its setter writes _streamError with no synchronisation, relying on a comment that says it is 'only called with lock held'. It is public, so any caller outside this file races the USB thread's write at line 489. It is also a trap in the other direction: adding the obvious lock to the setter would deadlock, because both call sites (lines 460 and 489) already hold the lock via withLock, the same self-deadlock shape as close().

Why it matters: A public settable property whose safety depends on an invisible convention will be used wrong or 'fixed' wrong; either way the result is a torn read of an Optional existential from the USB thread or a hang. Nothing in LeylineDaemon reads streamError today, so the comment at line 481 claiming it 'surfaces' device loss to the daemon is also untrue.

Suggested fix: Make the storage private and expose only a locked read plus a private setStreamError called from inside the existing critical sections, or write it via a lock-free box. Either way drop the public setter.

- verifier (comment, downgraded P3): The asymmetry is real (RTLSDRDevice.swift:497-502; both writes at :460/:489 are inside withLock, so locking the setter would self-deadlock), but I found no out-of-file setter — grep shows only tests reading it via the locked getter (DevicesTests.swift:395-404) — so the claimed race is not reachable today and the sub-claim that the comment is 'untrue' is overstated (the tests do observe it). Keep as a mechanical API cleanup.


### q-swift-control-7 — Registry test helper named 'next' has no timeout at all, so a missing event hangs the suite

`engine/Tests/EngineCoreTests/DevicesTests.swift:260` · P2 · scoped · confirmed

The helper's doc comment says it 'reads the next event with a timeout so a missing event fails instead of hanging', but the Task it creates only sleeps and returns nil, is never awaited, and is cancelled by the defer. The actual read is a bare 'await it.next()' with no bound. The same unbounded 'await events.next()' pattern is used directly in RegistryProbeTests.

Why it matters: Any regression that stops the registry publishing an event turns into a hung test process rather than a failure, and the dead Task makes a reader believe the opposite. CI then reports a timeout with no indication which assertion was waiting.

Suggested fix: Race the iterator against the sleep with a TaskGroup (first result wins) and throw TEST_TIMEOUT when the sleeper wins, then use that helper in RegistryProbeTests too.

- verifier (comment, downgraded P3): Verified: the Task at DevicesTests.swift:261-264 is never awaited, so the helper's 'with a timeout' comment is false and the read is unbounded, as are the direct awaits in RegistryProbeTests. Real but test-only and low-blast-radius, so P3; the minimum honest fix is either implementing the race or deleting the dead Task and the comment — don't let a TaskGroup rewrite grow into a test-infra project.


### q-swift-control-8 — Sub-audible detector task keeps polling a dead core after a channel goes out of capture

`engine/Sources/EngineCore/Channels/DefaultChannelEngine.swift:213` · P3 · mechanical · confirmed

captureMoved's catch clears the slot and marks the channel outOfCapture but does not cancel subAudibleTask; only rebuild() (line 258) cancels it. The task keeps its reference to the discarded ChannelDSPCore and its ring, waking every 50 ms forever while the channel is out of capture.

Why it matters: A capture retuned away from an NFM channel leaves one utility Task per channel spinning at 20 Hz and pins the old core (with its filters and rings) in memory until the channel is rebuilt or closed. With several parked channels this is measurable idle CPU on a daemon that is supposed to be quiet.

Suggested fix: Cancel and nil subAudibleTask in the catch branch of captureMoved, next to slot.store(nil).


### q-swift-control-9 — DefaultCaptureEngine.start()'s idempotency guard does not survive its own awaits

`engine/Sources/EngineCore/Capture/DefaultCaptureEngine.swift:51` · P3 · scoped · confirmed

start() checks 'guard !started' and only sets started = true after four awaits, so two concurrent start() calls on the same actor both pass the guard. The second one's device.startStreaming throws DEVICE_BUSY, and its catch block then calls device.close() (line 64), tearing down the stream the first call had just brought up while leaving started == true.

Why it matters: The actor's public API reads as safe against concurrent use and is not; the failure mode is a capture that reports started with a closed device and no samples. Today only SessionStore.createCapture calls start(), one caller per engine, which is why it has not bitten yet.

Suggested fix: Set a 'starting' flag (or set started = true) before the first await and reset it on the failure path, so a re-entrant call returns or throws instead of running a second time.


### q-swift-control-10 — DeviceEventHub.finishAll is never called

`engine/Sources/EngineCore/Devices/DeviceRegistry.swift:31` · P3 · mechanical · confirmed

finishAll() exists to end every device-event subscription but no production or test code calls it; registry.stop() only cancels the poll task. Subscribers' AsyncStreams therefore never finish, and SessionStore's mirror only ends because its Task is cancelled.

Why it matters: A maintainer reading the hub assumes shutdown finishes the streams and may write a consumer that waits for the stream to end. Either wire it into stop() or delete it, so the shutdown contract is unambiguous.

Suggested fix: Call hub.finishAll() from a registry shutdown path (or drop the method and note that consumers end by cancelling their own task).


### q-swift-control-11 — settledGainDB reports a legitimate 0 dB tuner gain as unknown

`engine/Sources/EngineCore/Devices/RTLSDRDevice.swift:55` · P3 · scoped · confirmed

settledGainDB throws (and the try? turns it into nil) when rtlsdr_get_tuner_gain returns 0, treating 0 as the librtlsdr error sentinel. 0.0 dB is the first entry of the R820T/R828D and FC2580 gain tables this very file hard-codes in knownGainTableDB, so a tuner whose AGC settled at the bottom of its range is reported as 'no reading'.

Why it matters: The whole point of this call, per its own comment, is to learn where the tuner's AGC settled; on a strong signal it settles at the minimum, which is exactly when the answer is discarded. Clients show an empty settled gain precisely in the case that matters.

Suggested fix: Only treat 0 as an error when the device's gain table does not contain 0 dB, or accept 0 and drop the sentinel check (the value is advisory).


### q-swift-control-12 — ULID equality, hashing and ordering allocate a heap array per call

`engine/Sources/EngineCore/Identifiers.swift:124` · P3 · scoped · confirmed

==, < and hash(into:) are all implemented through the computed byteArray property, which builds a fresh 16-element Array each time. Every DeviceID/CaptureID/ChannelID dictionary lookup in the registry, session store and channel tables therefore allocates at least once for the hash and once more per equality probe.

Why it matters: These ids key the hot control-plane dictionaries (entries[id], channelTable[id], sinks) that are touched on every event, poll and write. In a codebase that counts allocations elsewhere, three allocating operations on the most-used value type is an easy, purely mechanical win.

Suggested fix: Compare and hash the two 64-bit halves directly (the same hi/lo the string getter already reconstructs), or store the id as a pair of UInt64 and derive the tuple.


### q-swift-control-13 — S2 synthetic source builds an invalid timespec and ignores EINTR

`engine/Sources/S2Throughput/SyntheticDevice.swift:75` · P3 · scoped · confirmed

The pacing sleep passes the whole remaining nanosecond count as tv_nsec with tv_sec 0. nanosleep rejects tv_nsec >= 1e9 with EINVAL and does not sleep, and the return value is discarded so a signal-interrupted sleep is not resumed. FilePlaybackDevice's equivalent loop (lines 203-205) splits sec/nsec and retries on EINTR.

Why it matters: At a --rate below blockSize samples per second the harness silently turns into a busy spin, which corrupts the CPU number that is the whole output of the S2 gate. A copy of a pacing loop that already exists correctly elsewhere is also the kind of duplication that drifts.

Suggested fix: Share one pacing helper (sec/nsec split plus the EINTR retry loop) between FilePlaybackDevice and SyntheticDevice.


### q-swift-control-14 — s2-throughput traps on a negative --seconds

`engine/Sources/S2Throughput/main.swift:57` · P3 · mechanical · confirmed

parse() accepts any Double for --seconds, and the value goes straight into UInt64(options.seconds * 1e9). A negative argument traps the process with 'Negative value is not representable' instead of printing the usage line the parser prints for every other bad input.

Why it matters: The spike harness is run by hand from docs/plans/build-order.md; a typo'd flag should print usage, not a Swift runtime crash that looks like an engine fault.

Suggested fix: Validate in parse(): reject seconds <= 0 (and rate == 0, channels < 0) with the usage message and exit(2).


## Swift code quality: the daemon (`LeylineDaemon`)

Coverage: Read in full (every non-test file in scope): engine/Sources/LeylineDaemon/ClientContext.swift, WriteCoalescer.swift, Server.swift, DaemonCommand.swift, Mapping/ProtoMapping.swift, Services/ControlService.swift, Services/BulkService.swift, Services/JobsService.swift, Services/TelemetryService.swift, Bulk/FrameRing.swift, Bulk/StreamSources.swift, Bulk/StreamRegistry.swift, Jobs/JobStore.swift, Jobs/ScanRunner.swift, Jobs/SessionCaptureAllocator.swift, Session/SessionStore.swift (all 917 lines, in six sections). Also read docs/plans/archive/engine-review-fixes.md in full to avoid re-reporting fixed …


### q-swift-daemon-1 — Persistence subscribe traps the daemon on a tiny rows_per_second

`engine/Sources/LeylineDaemon/Bulk/StreamRegistry.swift:175` · P1 · scoped · confirmed

`Bulk.Subscribe(kind=PERSISTENCE)` computes `emitInterval = UInt64(Swift.max(1.0, Double(snap.sampleRate) / emitRows))` with `emitRows` taken straight from the client (`want.rowsPerSecond > 0 ? want.rowsPerSecond : 2`, StreamRegistry.swift:166), a proto3 `double`. A denormal-but-positive value such as 1e-300 makes the quotient ~2.4e306, and `UInt64(_:)` on a Double outside UInt64.max is a runtime trap, not a clamp. One RPC from any client kills the daemon and every capture it owns.

Why it matters: A single `Bulk.Subscribe` with `persistence.rows_per_second = 1e-300` aborts leylined (verified locally: `UInt64(2_400_000.0/1e-300)` -> "Fatal error: Double value cannot be converted to UInt64 because the result would be greater than UInt64.max"). The identical hostile value is already a regression test for the FFT path (MalformedInputTests.swift:64 `testDenormalRowsPerSecondClampsAndDeliversRows`), so the hardening pass simply missed the persistence branch added beside it.

Suggested fix: Clamp the requested rate before it is used, the way WI-4 clamped the ladder: reject or clamp `rows_per_second` to a documented range (e.g. `[minRowsPerSecond, maxRowsPerSecond]`), and saturate the division before converting (`UInt64(min(quotient, Double(UInt64.max / 2)))`). Add the 1e-300 case to MalformedInputTests for kind=PERSISTENCE.


### q-swift-daemon-2 — Persistence half_life_seconds traps the same way through Int(_:)

`engine/Sources/LeylineDaemon/Bulk/StreamRegistry.swift:173` · P1 · scoped · confirmed

`halfLifeRows: Swift.max(1, Int(halfLife * ladderRows))` converts a client-supplied `double half_life_seconds` (only checked for `> 0` at :170) multiplied by the ladder's max row rate into an `Int`. `half_life_seconds = 1e300` (or `inf`) makes the product unrepresentable and `Int(_:)` traps, aborting the daemon before the accumulator is even built.

Why it matters: Same one-RPC daemon kill as the rows_per_second trap, on a different field of the same message, so fixing one without the other leaves the hole open. Nothing in the validation above it bounds the value: `want.halfLifeSeconds > 0` admits 1e300 and +inf.

Suggested fix: Validate `half_life_seconds` as finite and within a stated range (e.g. 0.1...3600) and reject anything else with INVALID_ARGUMENT, or clamp the product before converting. Cover it in MalformedInputTests alongside the rows_per_second case.


### q-swift-daemon-3 — WriteParams tick loop spins at 100% CPU once its task is cancelled

`engine/Sources/LeylineDaemon/WriteCoalescer.swift:106` · P2 · scoped · confirmed

`run` paces itself only with `try? await Task.sleep(nanoseconds: tickNs)`. When the handler task is cancelled, `Task.sleep` throws `CancellationError` immediately and `try?` discards it, so the `while !finished.value` loop degenerates into an unbounded busy loop calling `flush()` (which hops to the SessionStore actor) as fast as it can, until the unstructured reader task independently observes the end of the request stream and sets the flag.

Why it matters: The loop condition tracks the reader, not cancellation, so the spin lasts as long as the inbound sequence takes to fail — and unlike `Control.watchEvents` and `Bulk.stream`, `writeParams` was never given the `withRPCCancellationHandler` treatment of FU-3, so nothing else ends the reader either. A cancelled `ley tune` session leaves a core busy and hammers the store actor, starving real RPCs.

Suggested fix: Break out on cancellation: `if (try? await Task.sleep(...)) == nil { break }` (or check `Task.isCancelled` in the loop condition) before the final `flush()`, and wrap the streaming section in `withRPCCancellationHandler` so the reader task is cancelled with the RPC like the other two streaming handlers.

- verifier (comment, downgraded P3): The stated trigger is wrong: in grpc-swift 2, RPC cancellation is not task cancellation (ServerRPCExecutor.swift:131 only calls `context.cancellation.cancel()`; the handler task is not cancelled), and a client cancel arrives as RST_STREAM -> GRPCServerStreamHandler.handleUnexpectedClose -> fireErrorCaught, which fails the inbound sequence, so the reader in WriteCoalescer.run ends and the loop exits normally. A cancelled `ley tune` therefore does not spin. The `try?`-swallowed cancellation is …


### q-swift-daemon-4 — Detections dropped by the fan-out buffer leave no seq gap, contradicting the stated contract

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:60` · P2 · scoped · confirmed

`JobStore.detections` hands each telemetry subscriber an `AsyncStream` with `bufferingNewest(64)` and `publish` discards the result of `continuation.yield`, so overflow drops are never counted. `TelemetryService` then forwards every detection with `yieldMerged(msg, gap: 0)`, so a subscriber that fell behind sees a perfectly contiguous `seq` while readings were silently thrown away.

Why it matters: Every other telemetry source was fixed to be gap-marked (WI-8, FU-4) and both file headers claim it — JobStore.swift:43-44 "Drop-oldest: a slow subscriber misses readings and the telemetry stream's seq gap says so" and TelemetryService.swift:2-5 "records lost ... advance seq without being sent". For detections that is false. A busy sweep on a slow client silently loses hits, and a client trusting `seq` continuity (which is the whole point of the gap contract) will report a scan as complete when it is not.

Suggested fix: Count `.dropped` returns per sink (an atomic beside the continuation, as `TelemetryHub` does after FU-4) and carry the delta as the `gap` argument of `yieldMerged`; or, if that is deferred, correct both header comments so they stop promising a gap that detections do not get.


### q-swift-daemon-5 — Gain writes are not refused while a sweep holds the capture

`engine/Sources/LeylineDaemon/Session/SessionStore.swift:768` · P2 · mechanical · confirmed

`applyWrite` calls `refuseIfSwept` for `.centerHz` (:737) and `.captureSampleRate` (:748) but not for `.gain` (:768). A client can therefore change the tuner gain of a capture a scan is sweeping, even though the lease deliberately froze it (`SessionCaptureLease.pinGain`: "Under AGC the gain moves after every hop and SNR measured against a moving reference is not a number").

Why it matters: The scan's dB numbers become a mix of two sensitivities: hits found before the write are compared against a floor measured at a different gain, and the `Scan.gains` field reports `lease.pinnedGains` from before the change, so the result claims a gain setting it did not run at. On release the lease restores its entry gains, silently undoing the client's write. Nothing in the answer says any of this happened.

Suggested fix: Add `try refuseIfSwept(id)` to the `.gain` branch so the write is rejected with DEVICE_SWEEPING like the other capture-level writes, and cover it in ScanSweepTests next to `testTheSweepPinsGainAndRestoresIt`.


### q-swift-daemon-6 — IQ tap truncates the payload but still reports the full sample count

`engine/Sources/LeylineDaemon/Bulk/StreamSources.swift:145` · P3 · mechanical · confirmed

`IQFrameTap.write` clamps the copy to the slot size (`min(iq.byteCount, ring.slotBytes)`) but passes `sampleCount: UInt64(iq.count)` — the untruncated count — to `ring.write`. A block larger than `CaptureDSPCore.blockSize * 8` would produce a frame whose payload holds fewer samples than its declared span, and the gap accounting would credit samples that were never sent.

Why it matters: Today the sizing happens to match exactly (StreamRegistry.swift:216 allocates `CaptureDSPCore.blockSize * 8` and every device delivers 16384-sample blocks), so this is latent — but it is exactly the kind of silent mismatch a new device with a different block size would introduce, and the client's sample-index arithmetic would drift with no error anywhere.

Suggested fix: Derive the reported count from the bytes actually copied (`UInt64(bytes / 8)`), or treat an oversized block as a programming error and log/assert rather than silently truncating.


### q-swift-daemon-7 — `first(where: { _ in true })` is a confusing spelling of `.first`

`engine/Sources/LeylineDaemon/ClientContext.swift:36` · P3 · mechanical · contested

The label is parsed with `metadata[stringValues: Self.labelKey].first(where: { _ in true }) ?? ""`, which is just `.first ?? ""`. The two lines above it use a real predicate (`first(where: { !$0.isEmpty })`), so the always-true closure reads as if some filtering were intended and invites a reader to hunt for the difference.

Why it matters: A maintainer comparing the three metadata lines has to work out that the third predicate is a no-op; the next person to "fix" it may guess the intent was `!$0.isEmpty` and change behaviour (an explicitly empty label would then fall back differently).

Suggested fix: Write `metadata[stringValues: Self.labelKey].first ?? ""` and, if an empty label really is allowed to win over a later non-empty one, say so in a short comment.

- verifier (comment, refuted P3): The suggested fix does not compile: `metadata[stringValues:]` returns GRPCCore Metadata.StringValues, which conforms to Sequence, not Collection (grpc-swift-2 Sources/GRPCCore/Metadata.swift:367), so there is no `.first` property — `first(where: { _ in true })` is the standard workaround for taking the head of a Sequence, not a confused predicate. Acting on this finding would break the build; at most it is a comment, which is below the bar.

- verifier (comment, confirmed P3): ClientContext.swift:34-36 reads as described: two real `!$0.isEmpty` predicates followed by `first(where: { _ in true })`, which is exactly `.first`. Pure readability nit, correctly graded P3.


### q-swift-daemon-8 — withPromptShutdown duplicates the whole withDaemon harness

`engine/Tests/LeylineDaemonTests/StreamCancelTests.swift:44` · P3 · scoped · confirmed

`StreamCancelTests.withPromptShutdown` re-implements `DaemonTestHarness.withDaemon` line for line — temp dir, socket, `Daemon(config:)`, `waitUntilListening`, `withGRPCClient`, `bodyError` plumbing — and differs only by a hard-coded 300 ms presence grace and a 2 s watchdog around `shutdown()`.

Why it matters: Two copies of the boot sequence drift: the harness copy asserts the pidfile exists and that the socket is unlinked on shutdown, this copy does neither, so a regression in socket cleanup would still pass here. Any future change to how a test daemon starts has to be made twice.

Suggested fix: Give `withDaemon` an optional shutdown-deadline parameter (or a `shutdownWatchdogNs`) and have both tests call it, deleting the duplicate.


### q-swift-daemon-9 — EventCollector.start pads its readiness handshake with a fixed 100 ms sleep

`engine/Tests/LeylineDaemonTests/DaemonTestHarness.swift:97` · P3 · scoped · confirmed

`EventCollector.start` polls a `ready` flag that is set inside the client's response callback, then sleeps a flat 100 ms before returning. The flag only means the client saw response headers; it does not mean the daemon ran `store.events(...)` and registered the subscriber, so the sleep is the actual synchronisation.

Why it matters: Every test that asserts "an event arrived after this point" (DaemonTests, DeviceLossTests, FailedRateWriteTests, ChannelRateRetuneTests) rests on that 100 ms. On a loaded CI box the subscription can register after the mutation the test then waits for, and the failure surfaces as an unrelated missing-event assertion rather than as a harness problem.

Suggested fix: Make readiness observable from the daemon side — e.g. after starting the watch, emit a known no-op mutation (or expose a test-only `subscriberCount` on SessionStore) and poll until the collector actually sees it — instead of the fixed sleep.


## Architecture: the thirteen invariants

Coverage: Read in full: /workspace/CLAUDE.md, /workspace/docs/dev/engine-internals.md, /workspace/docs/reference/cli.md (the relevant sections on client-side exceptions, auto-squelch, roadmap stubs, client requirements), /workspace/Makefile, /workspace/.github/workflows/ci.yml, /workspace/scripts/gen-proto.sh, /workspace/proto/leyline/v1/common.proto, /workspace/engine/Sources/LeylineDaemon/Services/{ControlService,JobsService}.swift, /workspace/engine/Sources/LeylineDaemon/Jobs/SessionCaptureAllocator.swift, /workspace/engine/Sources/LeylineDaemon/Server.swift. Read by section: proto/leyline/v1/control.proto …


### a-invariants-1 — Jobs service registers no client presence, so an orphaned job holds the radio forever

`engine/Sources/LeylineDaemon/Services/JobsService.swift:16` · P2 · scoped · confirmed

Every other service calls `store.streamOpened`/`store.touchUnary` on entry (ControlService.swift:14, TelemetryService.swift:40, BulkService.swift:12). `JobsService` calls neither, on any of its six methods. `SessionStore` only creates a presence entry in `streamOpened`/`touchUnary` (SessionStore.swift:217/233), so a client whose only contact with the daemon is `Jobs.StartJob` never gets one, `armGrace` is never scheduled for it, `reap` never runs, and `clientGoneHook` — which `Server.swift:137` wires to `JobStore.clientGone` — never fires.

Why it matters: `reap` documents itself as "the backstop for a hard kill" of a sweep whose owner is gone, but that backstop is armed only for clients that also open a stream. `ley scan` happens to hold WatchEvents (scan.go:218), so the CLI is covered; the D.16 MCP adapter, a `grpcurl` caller, or any agent that fires StartJob and dies is not. While a scan's lease is held, `SessionStore.refuseIfSwept` (SessionStore.swift:490) rejects `createChannel` and every capture write with DEVICE_SWEEPING, and the allocator declines a second scan, so a 400-470 MHz sweep at 2 s dwell locks the only dongle out of every …

Suggested fix: Give JobsService the store and call `await store.touchUnary(ClientContext.current)` at the top of each method (StartJob, GetJob, ListJobs, CancelJob), the same as ControlService. That makes a job-only client present for one grace period per call, so a poller keeps its job and a vanished client's job is cancelled by the existing `clientGoneHook` path. Add an e2e case that starts a scan over a raw connection, drops it, and asserts the capture is free within the grace window.

- verifier (comment, downgraded P2): Confirmed mechanically: JobsService.swift holds only `let jobs: JobStore` and none of its six methods touches presence, while SessionStore only creates a Presence entry in streamOpened/touchUnary (SessionStore.swift:217/233), so armGrace/reap/clientGoneHook never fire for a client whose only RPCs are Jobs.*. docs/reference/cli.md:117 states the contract this breaks ("it belongs to the connection that started it and the daemon cancels it when that connection goes"). Downgraded from P1: `ley scan` …

- verifier (comment, downgraded P2): Verified: JobsService.swift holds only `let jobs: JobStore` and never touches SessionStore, while presence is only created in streamOpened/touchUnary (SessionStore.swift:217/233), so the clientGoneHook backstop at SessionStore.swift:267 never arms for a job-only client — real gap, worth fixing. Not P1: ScanRunner.swift:189 walks plan.steps once and releases the lease at JobStore.swift:211, so the lockout is bounded by the sweep, not 'forever'; and the suggested touchUnary fix carries a policy …


### a-invariants-2 — CI never checks engine/Sources/LeylineProto for drift, so invariant 13 is unenforced on the Swift side

`.github/workflows/ci.yml:28` · P2 · scoped · contested

The `proto-and-go` job runs `scripts/gen-proto.sh` then `git diff --exit-code -- go/gen` — Go only. That job runs on ubuntu-24.04 with no Swift toolchain, and gen-proto.sh:53 silently skips Swift generation in that case (`swift not on PATH; skipping Swift generation`, guarded only by an opt-in `REQUIRE_SWIFT`). Neither Swift job runs `make proto-check` or the script; they run `make swift swift-test` and `make e2e`. `make check` (Makefile:73) does include `proto-check`, which diffs both trees, but no CI job invokes `make check`.

Why it matters: CLAUDE.md invariant 13 ("never hand-edit generated code ... run protoc validation in CI") is only half enforced. A hand edit to `engine/Sources/LeylineProto/*.pb.swift` — the exact thing the invariant forbids — merges green. So does a proto change where the author regenerated Go but not Swift: the engine keeps compiling against the stale messages and the divergence surfaces only when someone next runs `make proto` locally and gets an unexplained diff. gen-proto.sh's own header claims "CI runs this script and fails on drift", which is true for one of the two languages.

Suggested fix: Move the drift check into the swift-linux job (which already has protoc-less Swift 6.2 plus Go) as `REQUIRE_SWIFT=1 make proto-check`, or add protoc to that job and run `make proto-check` there; leave the ubuntu Go job's narrower check as-is. Either way one CI job must diff `engine/Sources/LeylineProto`.

- verifier (comment, refuted P3): Refuted by .github/workflows/ci.yml:81-91: the swift-macos job installs protoc and runs `REQUIRE_SWIFT=1 ./scripts/gen-proto.sh` then `git diff --exit-code -- engine/Sources/LeylineProto go/gen`, with a comment explaining exactly the drift case the finding claims is unchecked. The finder read only the first job.

- verifier (comment, confirmed P2): Verified: ci.yml:48-51 diffs only go/gen, the swift-linux job runs `make swift swift-test` and `make e2e` with no protoc and never `make proto-check` (Makefile:30-35), and gen-proto.sh:51-54 silently skips Swift generation without REQUIRE_SWIFT. Invariant 13's 'protoc validation in CI' is genuinely half-enforced and the fix is one CI step.


### a-invariants-3 — Capture has no destroy tombstone: destroy and device-loss are the same event on the wire

`engine/Sources/LeylineDaemon/Session/SessionStore.swift:524` · P2 · scoped · confirmed

`destroyCapture` removes the capture from the table and emits it one last time with `state = .captureDetached` — the identical state a capture gets when its dongle is unplugged (`captureDeviceLost`, SessionStore.swift:344, via ProtoMapping.swift:160). `Channel` and `Sink` both solved this with an explicit tombstone (state left unspecified; the `Sink` message even carries the rationale at control.proto:104-108), but `CaptureState` has only UNSPECIFIED/ACTIVE/DETACHED, so a client watching events cannot tell "this capture is gone" from "this capture will rebind when the dongle comes back".

Why it matters: `session.fold` handles the Channel and Sink tombstones by removing them from the mirror (session.go:340, session.go:353) but folds a Capture as a straight `replaceCapture` (session.go:334, session.go:369). A destroyed capture therefore stays in every long-lived client's mirror for the rest of the run, permanently DETACHED. Today the blast radius is small because `destroyCapture` destroys the capture's channels first and the channel tombstone is what ends a `ley tune`; but any verb that counts or lists captures from the mirror rather than re-fetching GetState reports a radio that no longer …

Suggested fix: Emit the destroy event with `state` left UNSPECIFIED, the same tombstone convention Channel and Sink already use (no proto change needed — CAPTURE_STATE_UNSPECIFIED is free), fold it in `session.fold` with a `withoutCapture`, and mirror both in `fakedaemon`. Document the convention once, next to the Sink comment at control.proto:104.


### a-invariants-4 — docs/dev/engine-internals.md, the declared implementation contract, predates the entire Jobs subsystem and states Jobs is UNIMPLEMENTED

`docs/dev/engine-internals.md:30` · P2 · scoped · confirmed

CLAUDE.md points at `docs/dev/engine-internals.md` as "the implementation contract (threads, hot path, pipeline math, daemon rules)". Its module map line 30 says `Services/ Control, Telemetry, Bulk (Jobs/Resources return UNIMPLEMENTED in v0)`, which stopped being true at commit ddbbeb9. The map has no `Jobs/` entry at all, and the DSP list omits four files that now exist: SweepPlan.swift, EnergyDetector.swift, SubAudible.swift, Persistence.swift. Grepping the whole doc for sweep, scan, job, detector, sub-audible, persistence or phosphor returns four incidental hits, none about these features.

Why it matters: Three shipped subsystems — daemon-side scan jobs with the capture allocator and lease protocol, sub-audible/CTCSS detection, and the persistence (phosphor) bulk stream — have no entry in the document a maintainer is told to read before structural changes. The doc is not merely incomplete, it actively misdirects: someone reading line 30 concludes the Jobs service is a stub and that the don't-disturb policy is unimplemented, when `SessionCaptureAllocator` already owns it and `refuseIfSwept` already blocks user writes on a swept capture. D.15 (durable jobs, watch jobs, the resource store) lands …

Suggested fix: Update the module map (add `Jobs/`, the four DSP files, `BlockingWork.swift`; correct the Services line to say scan is implemented and only watch/record/Resources are UNIMPLEMENTED) and add three short sections beside the existing Control/Telemetry/Bulk ones: the Jobs service and lease lifecycle, detections on the telemetry plane, and the persistence stream's parameters. docs/design/scan.md already carries the reasoning; this doc needs the contract summary that points at it.


### a-invariants-5 — JobRunner, JobContext and ResourceStore in CoreProtocols are unreferenced; the shipped jobs subsystem bypassed them

`engine/Sources/EngineCore/CoreProtocols.swift:415` · P3 · design · confirmed

CoreProtocols.swift is the hand-written engine contract (CLAUDE.md invariant 13 forbids generating it). Its Jobs and Store sections declare `JobRunner`, `JobContext`, `ResourceStore`, `ResourceKind`, `ResourceHandle` and `ResourceRecord`. Grepping the whole tree, none of the six has a single conformance, call site or mention outside their own declarations. `CaptureAllocator`/`CaptureLease`/`AllocationRequest` from the same section are real and used; the rest is not. `JobContext` is an empty struct whose comment says "filled in with Milestone D" — Milestone D.13 shipped and `JobStore`/`ScanRunner` never touch it.

Why it matters: A contract file that mixes live protocols with aspirational ones stops being usable as a contract: the next person implementing D.15's watch job has to determine by grep, not by reading, that `JobRunner` was never adopted and that `ScanRunner` is a bare `static func sweep` instead. `JobStore` already invented its own shape (a proto-typed table plus a detached `Task` per job) that `JobRunner`'s `start/cancel/status` does not describe, so the two will have to be reconciled or one deleted before watch jobs land — a decision better made now than mid-milestone.

Suggested fix: Either delete the three unused declarations now and re-add the shape D.15 actually needs, or (better, if the direction is settled) make `ScanRunner` conform to `JobRunner` and give `JobContext` its real members so the second job type has a pattern to follow. Whichever is chosen, the file should not carry protocols that the only implementation of their concept ignores.

- verifier (comment, downgraded P3): The grep holds — JobRunner/JobContext/ResourceStore/ResourceKind/ResourceHandle/ResourceRecord appear only at their declarations (CoreProtocols.swift:415-425, 491-511) — but they are explicitly labelled forward declarations ("// MARK: - Jobs (Milestone D)", "// MARK: - Store (Milestone C/D)", "filled in with Milestone D") and docs/plans/build-order.md:38 schedules "JobRunner respawn" and the resource store for milestone 15. That is a roadmap placeholder rather than accidental dead code, so P3, not P2.

- verifier (comment, downgraded P3): Verified by grep: JobRunner/JobContext/ResourceStore/ResourceHandle/ResourceRecord/ResourceKind appear only at their declarations in CoreProtocols.swift (the go/gen hits are generated proto). But that file is explicitly staged by milestone ('MARK: - Jobs (Milestone D)', '- Store (Milestone C/D)'), so a forward declaration there is house style, not a defect; the only concretely wrong thing is JobContext's 'filled in with Milestone D' comment now that D.13 shipped past it. Worth a minute, not a …


### a-invariants-6 — The bulk-plane payload codec lives unexported in internal/cli, above the client library that produces the payloads

`go/internal/cli/fft.go:237` · P2 · scoped · confirmed

Bulk frames are the one part of leyline.v1 with no proto message (docs/reference/cli.md calls this out as the documented exception), so their payload encoding is hand-written on both sides: the daemon encodes DB_U8 in StreamSources.swift:11 as `((db + 120) * 2).rounded()`, and Go decodes it in the unexported `decodeBins` at fft.go:237 as `float64(b)/2 - 120`. `pkg/leyline` — the library CLAUDE.md says the MCP adapter shares — offers `SubscribeFFT`, `SubscribePersistence`, `SubscribeAudio` and `SubscribeIQ` (client.go:416-469) and returns raw `Frame`s, with no way to read the bytes it just negotiated.

Why it matters: Two consequences. First, D.16: an MCP adapter built on pkg/leyline can subscribe to a spectrum but cannot turn a frame into dB without either reaching into `internal/cli` (a Cobra package full of lipgloss styles) or reimplementing the quantization — and a second implementation of `b/2 - 120` is exactly the kind of silent drift that produces a spectrum offset by 120 dB. Second, there is no cross-language test: grepping go/internal/e2e for `u8`/`U8`/`120` returns nothing, so the encoder and decoder are only ever exercised separately, and the five CLI call sites all pass `DB_F32` in their …

Suggested fix: Move the frame codec into `pkg/leyline` (exported `DecodeFFTBins(payload []byte, format leylinev1.FftBinFormat) []float64`, plus the persistence and audio equivalents), have the five CLI sites call it with `desc.GetFft().GetBinFormat()` rather than a hand-rolled bool, and add one e2e case that subscribes DB_U8 against the real daemon and checks the decoded row against a DB_F32 row of the same fixture within the quantization step.


### a-invariants-7 — `session` conflates the protocol state mirror, the tune lifecycle and terminal presentation across seven files

`go/internal/cli/session.go:50` · P2 · design · confirmed

One `session` type carries three unrelated responsibilities: (a) the leyline.v1 client mirror — `state`, `seq`, `apply`, `fold`, `awaitEvent`, gap-and-resume handling; (b) the tune lifecycle — `ensureCapture`, `createChannel`, `attachAudio`, `applyGain`, `teardown`, `cleanupFailed`; (c) terminal presentation — `app *App` with two `ui.Style`s, `say`, `banner`, `bannerSource`, `bannerSecondHint`, `sayClosed`, `printCreated`, `squelchNote`, `sourceLine`, and a `subAudibleTracker` embedded as the struct's first field. Its 30 methods are spread over session.go, tune.go, change.go, band.go, scan.go, stop.go and phosphor.go.

Why it matters: (a) is the only correct implementation in the repo of the GetState-then-WatchEvents-with-since_seq protocol, of the seq-gap rule, and of the Channel/Sink tombstone folding — and it is welded to a Cobra `*App` and to lipgloss styles. D.14's TUI needs (a) and (b) with a completely different renderer; D.16's MCP adapter needs (a) and (b) with no renderer at all. Both will either import a package whose other half writes ANSI to `app.Stderr`, or re-derive the mirror — and a second, subtly different implementation of the resume-from-seq rule is how a client starts missing events. The coupling is …

Suggested fix: Extract (a) into `pkg/leyline` as a `Mirror`/`Watcher` type that owns `state`, `seq`, `Apply`, `Fold`, `AwaitEvent` and the since_seq resume, with no `*App` and no `ui` import — the fold rules (tombstones, seq gaps) are protocol semantics that every client must share. Leave `session` in `internal/cli` as the thin composition of that mirror plus the CLI's own rendering. Do this before D.14 rather than after, so the TUI is the first consumer instead of the first duplicate.


### a-invariants-8 — Jobs advertise a ley:// result URI that no RPC can resolve and that is discarded after 16 jobs

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:140` · P3 · design · contested

`startScan` sets `job.resultUris = ["ley://scans/<scanID>"]`, the repo's documented resource-URI form (CLAUDE.md conventions). Nothing can dereference it: all three `Resources` RPCs throw UNIMPLEMENTED (JobsService.swift:64-76), and the only way to reach the data is `Jobs.GetScan` with a bare `scan_id`, which `ley scan` gets by string-stripping the prefix back off. The scan itself lives in the in-memory job entry and is deleted by `trim()` once 16 later jobs have finished.

Why it matters: The URI reads as a durable handle and is not one. An MCP agent (D.16) handed `ley://scans/01J...` from a job event has no RPC that accepts it and no way to learn it has already expired; it gets SCAN_NOT_FOUND with no distinction between "never existed" and "aged out of a 16-entry ring". The CLI only works because it knows the private convention that the URI's tail is a `GetScan` argument.

Suggested fix: Until D.15 gives resources a store, either (a) make `Resources.GetResource` resolve `ley://scans/<id>` against the in-memory table and return a distinct code when the scan has been trimmed, or (b) drop `result_uris` from a v0 scan job and let clients use `Jobs.GetScan(scan_id)` — the field is optional and an empty one promises nothing. Whichever way, say in the Job message's comment that a v0 result URI does not survive `keepFinished` jobs.

- verifier (comment, refuted P3): Refuted by docs/reference/cli.md:118-122, which states in prose that result_uris carries ley://scans/<id>, that it "is resolved by Jobs.GetScan", that it is "deliberately not yet a Resource, because an ad-hoc scan is ephemeral and there is no file", and that "the daemon keeps the last sixteen finished jobs in memory and loses them on restart". The convention is documented, not private, and the expiry the finding says nobody records is written down; the remaining gap is the intended D.15 work.

- verifier (comment, confirmed P3): Verified: JobStore.swift:140 mints ley://scans/<id>, all three ResourcesService methods throw unimplemented (JobsService.swift:63-75), trim() at JobStore.swift:327 drops the entry past keepFinished, and scan.go string-strips the prefix to call GetScan. A promise the API cannot keep, but bounded harm and the right fix (resolve it vs drop the field) is a D.15 design call — P3 is the correct weight.


### a-invariants-9 — rtl_tcp remotes can be attached only by a daemon flag and can never be detached

`engine/Sources/EngineCore/Devices/DeviceRegistry.swift:177` · P3 · scoped · contested

`DeviceRegistry.attachVirtualDevice` hosts any constructed virtual device and is how `RTLTCPDevice`s enter the registry (Server.swift:151, from `--rtltcp`/`LEYLINE_RTLTCP` at startup). No RPC exposes it. On the way out, `SessionStore.detachFileDevice` gates on `isDetachableFileDevice`, which returns false unless the driver is literally `file`, so `Control.DetachFileDevice` refuses every rtl_tcp device. A remote dongle is therefore daemon start-up configuration, not session state — the only object in the system that is.

Why it matters: Everything else about a device's lifecycle is daemon state clients drive over the one protocol; a remote source is the exception, and it is the exception in the direction the remote-access milestone (docs/design/control-plane.md:81) will have to reverse. Concretely today: an operator who typos `--rtltcp` or whose remote host moves must restart the daemon, and the CLI's refusal message for an rtltcp device is wrong — devices.go:73 tells them "is a real radio (...), not a playback file; free it with: ley stop --all", which frees captures and does not remove the remote.

Suggested fix: Either widen the guard so `isDetachableFileDevice` accepts any hosted virtual device (the registry's own `detachFileDevice` already handles them — its comment at line 182 says so) and fix devices.go:73 to allow driver `rtltcp`, or, if remotes are deliberately configuration for now, say so in the error message and in docs/reference/cli.md instead of calling an rtl_tcp source "a real radio". The general `AttachDevice`/`DetachDevice` pair belongs to the remote-access milestone, but the misleading refusal is worth fixing today.

- verifier (comment, refuted P3): Refuted: the exclusion is deliberate and documented at DeviceRegistry.swift:172-175 ("Operator-configured virtual devices (rtl_tcp) are hosted the same way but are not client-detachable") and in docs/dev/engine-internals.md:230-249 / docs/dev/setup.md:47-64. The quoted daemon error is also inaccurate — SessionStore.swift:371 names the driver: "device is not a detachable file device (driver rtltcp)" — and devices.go:73's "free it with: ley stop --all" is true of an rtl_tcp remote, which stop --all …

- verifier (comment, confirmed P3): Verified, but narrower than written: DeviceRegistry.swift:173-176 documents the exclusion deliberately ('Operator-configured virtual devices (rtl_tcp) are hosted the same way but are not client-detachable'), and the daemon's own error names the driver correctly (SessionStore.swift:372). Only devices.go:73 is actually wrong — it tells an rtltcp user their remote 'is a real radio, not a playback file; free it with: ley stop --all', which does not remove it. Fix the message; widening …


### a-invariants-10 — docs/design/control-plane.md claims the protos reserve auth fields; none do

`docs/design/control-plane.md:81` · P3 · mechanical · confirmed

The remote-access decision entry ends "Proto reserves the auth fields now so the addition is non-breaking." Grepping `proto/` for auth, token or credential returns only the words "authoritative" and "authoritative answer" in bulk.proto comments. The four `reserved` declarations that do exist (control.proto:90, telemetry.proto:95/96/113) are all for retired telemetry and channel fields, none for auth.

Why it matters: This is one of the two forward-compatibility promises the design doc makes (the other, TX-as-sibling, is genuinely honoured — CoreProtocols.swift:61 and common.proto:9 both carry the guard rails). A reader planning the remote-access milestone will believe the field numbers are already held and discover they are not. In practice gRPC auth rides in metadata and needs no proto field, so the sentence is more likely wrong than the plan is — but it should not be left as a claim someone will act on.

Suggested fix: Either add the reserved field numbers the sentence claims (in whichever message would carry them) or rewrite it to say what is actually true — that auth will travel in gRPC metadata alongside the existing `leyline-client-*` keys and so needs no v1 field numbers held today.


## Architecture: layering and where logic lives

Coverage: Fully read: engine/Sources/EngineCore/Model.swift (all 171), engine/Package.swift (all), engine/Sources/LeylineDaemon/Mapping/ProtoMapping.swift (all 235), engine/Sources/LeylineDaemon/Services/ControlService.swift (all 127), JobsService.swift (all 75), BulkService.swift (all 56), TelemetryService.swift (all 200), go/pkg/leyline/errors.go (all 207), go/internal/cli/target.go (all 78), go/internal/cli/stubs.go (all). Read by section / by declaration list: engine/Sources/EngineCore/CoreProtocols.swift (full declaration list plus the ChannelEngine/telemetry and Demodulator/AudioSink sections; …


### a-layering-1 — Jobs RPCs never register client presence; a polling client's scan is reaped

`engine/Sources/LeylineDaemon/Services/JobsService.swift:16` · P1 · scoped · confirmed

Every unary in ControlService and BulkService calls `await store.touchUnary(client)` to keep the caller present, but JobsService (startJob:16, listJobs:30, getJob:37, cancelJob:44, getScan:55) calls it on none — JobsService is constructed with only `let jobs: JobStore` and has no reference to the SessionStore. SessionStore.reap (Session/SessionStore.swift:251) fires `clientGoneHook` after presenceGraceNs, and JobStore.clientGone (Jobs/JobStore.swift:107) cancels every RUNNING job the departing client owned.

Why it matters: A client that does GetState (arms the 5 s grace via touchUnary), StartJob(scan), then polls GetJob — exactly the shape of the D.16 MCP adapter, which is request/response and holds no stream — has its sweep cancelled ~5 s in, with no error, because nothing in the Jobs plane re-arms presence. `ley scan` is masked only because openSession happens to hold a WatchEvents stream (go/internal/cli/scan.go:192 says as much). The fake daemon calls touchUnary in all five Jobs RPCs (go/internal/fakedaemon/jobs.go:69,403,423,436,458), so no CLI or fake-based test can catch this.

Suggested fix: Inject the SessionStore into JobsService and call `await store.touchUnary(ClientContext.current)` at the head of each unary, or move the touch into ClientContextInterceptor (Server.swift:80) so presence is a transport-level concern no service can forget. Add a daemon test that starts a scan and polls GetJob with no stream open for longer than presenceGraceNs.


### a-layering-2 — Swift and Go disagree on the gRPC status for four stable error codes

`engine/Sources/LeylineDaemon/Mapping/ProtoMapping.swift:197` · P2 · scoped · confirmed

`ProtoMapping.statusCode(for:)` and `leyline.GRPCCode` are two hand-maintained copies of the same code→status table and they diverge on DEVICE_BUSY/DEVICE_SWEEPING (Swift resourceExhausted, Go FailedPrecondition), DEVICE_DETACHED (Swift failedPrecondition, Go Unavailable), GAIN_ELEMENT_UNKNOWN (Swift invalidArgument, Go NotFound) and MODE_UNSUPPORTED (Swift invalidArgument, Go Unimplemented). The fake daemon serves errors through the Go table (go/internal/fakedaemon/daemon.go:254-255 `grpc.SetTrailer(ctx, err.Trailer()); return err.ToStatus().Err()`), so the fake and the real daemon return different statuses for the same rejection. No doc pins the mapping — grepping docs/ for RESOURCE_EXHAUSTED/FAILED_PRECONDITION returns nothing.

Why it matters: Any consumer that reads the gRPC code rather than the ErrorDetail trailer — a retry interceptor, a non-Go client, grpc-gateway, service-mesh policy — behaves differently against the fake than against leylined, and RESOURCE_EXHAUSTED is retriable in default gRPC retry configs while FAILED_PRECONDITION is not, so a DEVICE_BUSY could be silently retried against one daemon and not the other.

Suggested fix: Write the table once as normative prose in docs/dev/engine-internals.md next to the leyline-error-bin paragraph (line 319), pick a winner per code, and add a test on each side asserting its switch matches that table entry-for-entry.


### a-layering-3 — Error-code registry has three partial sources of truth

`engine/Sources/EngineCore/Model.swift:128` · P2 · mechanical · confirmed

`EngineError`'s static constructors are presented as the code registry ("Stable machine error codes for ErrorDetail.code"), but two codes the daemon actually emits are missing and are spelled as raw string literals at their throw sites: DEVICE_SWEEPING (Session/SessionStore.swift:410 and :492) and STREAM_NOT_FOUND (Services/BulkService.swift:20 and :50, Bulk/StreamRegistry.swift:246 and :271). ProtoMapping.swift:226 mints a third, INTERNAL, that appears in no registry at all. go/pkg/leyline/errors.go has CodeDeviceSweeping and CodeStreamNotFound but no INTERNAL, and its comment claims "The list mirrors the engine's EngineError constructors" — which is false in both directions.

Why it matters: A maintainer adding a client (or the D.16 MCP adapter's error taxonomy) reads Model.swift, gets 17 of 20 codes, and cannot know DEVICE_SWEEPING exists until a scan is running. Any typo in one of the six literal throw sites produces a code no client switch handles and no compiler catches.

Suggested fix: Add `EngineError.deviceSweeping(_:)`, `.streamNotFound(_:)` and `.internalError(_:)` to Model.swift and replace the six literal constructions; add CodeInternal to errors.go and fix its comment. One test per side enumerating the registry and asserting the two lists are equal.


### a-layering-4 — Gain quantisation implemented three times; the fake's copy ignores step_db

`go/internal/fakedaemon/devices.go:208` · P2 · scoped · confirmed

The rule "non-empty valid_db snaps to the nearest entry, else step_db>0 snaps to the grid clamped to [min_db,max_db]" exists in EngineCore (Model.swift:43 `GainElement.snapped`), in the CLI (set.go:716 `snapGain`, which even documents itself as "mirrors the daemon's gain quantisation"), and in the fake (devices.go:208 `snapGain`). The fake's version implements only the valid_db and clamp halves — it never reads StepDb — so for a discrete-step element with an empty valid_db table the fake reports a value the real daemon would have snapped.

Why it matters: An element with step_db>0 (any device that is not the R820T, which uses valid_db) confirms a different gain value from the fake than from leylined, and the CLI's confirmation predicate only passes because it happens to accept StepDb/2+eps of slop. It is also the wrong home for the rule: the CLI copy sits in go/internal/cli, so the D.14 TUI and D.16 adapter must write a fourth one, even though its sibling validator leyline.CheckGain is already in the shared library.

Suggested fix: Move the CLI's snapGain into go/pkg/leyline beside CheckGain as the single Go implementation, have both the CLI and the fake call it, and add a table test whose cases match the Swift GainElement.snapped tests.


### a-layering-5 — ProtoMapping is not the only engine<->proto boundary; the session store speaks proto

`engine/Sources/LeylineDaemon/Mapping/ProtoMapping.swift:1` · P2 · design · confirmed

ProtoMapping's header calls itself "the one place the two vocabularies meet" and Package.swift:8 repeats it, but ProtoMapping only implements the engine→proto direction. Every proto→engine conversion, and the daemon's authoritative state itself, lives in SessionStore, JobStore and WriteCoalescer: SessionStore stores and returns proto messages (`func captureProto(_:) -> Leyline_V1_Capture`, `createCapture(...) -> Leyline_V1_Capture`, `attachSink(channelID:request: Leyline_V1_Sink)`, `applyWrite(_ w: Leyline_V1_ParamWrite)`, `createChannel(..., mode: Leyline_V1_DemodMode, ...)`), WriteCoalescer keys and batches `Leyline_V1_ParamWrite` directly, and JobStore builds `Leyline_V1_Job`/`Leyline_V1_Scan` as its records.

Why it matters: The stated module rule is what a maintainer trusts when changing the wire format: today a proto field rename touches the state store's policy code, not one mapping file, and the daemon's own state has no representation independent of leyline.v1 — which is precisely the coupling the TX-as-sibling entry (CLAUDE.md invariant 11, docs/design/control-plane.md) and any second transport will run into. The gap is invisible because the comment says otherwise.

Suggested fix: Either add the proto→engine half to ProtoMapping and give SessionStore/JobStore engine-vocabulary signatures with the services doing both translations, or — if storing proto is the deliberate choice — rewrite the ProtoMapping and Package.swift comments to say "engine→proto rendering; the session and job stores hold proto messages as their record type" so the contract matches the code.

- verifier (comment, downgraded P3): The code claim holds (SessionStore holds Leyline_V1_Capture/Channel/Sink and takes Leyline_V1_ParamWrite/DemodMode in its signatures; JobStore stores Leyline_V1_Job/Scan), but the rule the docs actually state is 'EngineCore is proto-free' (docs/dev/engine-internals.md:13, Package.swift:7) and that is intact. The daemon layer holding proto records is a defensible deliberate choice; the restructure half of the fix is a large refactor with no demonstrated failure behind it. What is genuinely wrong is …


### a-layering-6 — Contract-level client behaviour is locked inside go/internal/cli

`go/internal/cli/session.go:201` · P2 · design · confirmed

go/pkg/leyline is meant to be the shared foundation for the CLI, the D.14 TUI and the D.16 MCP adapter, but its exported surface stops at dial/parse/resolve helpers. The behaviour that actually defines how a client tracks the daemon lives unexported in package cli: the GetState+WatchEvents-with-since_seq open (openSession:201), the event-folding state mirror (apply:315, fold:332, replaceCapture/Channel/Sink:369-418, stateEvents:298), the confirm-with-poll-fallback loop (awaitEvent:260), the capture reuse/retune/create decision including the DEVICE_BUSY re-read loop (ensureCapture:423), and target disambiguation (set.go:157 resolveTarget).

Why it matters: Both remaining D milestones need every one of these, and `go/internal` plus unexported identifiers means neither can import them — the TUI and the adapter will each get their own copy of the seq/staleness rules, and invariant 6 ("reconnect = GetState + resume from seq") will be implemented three times with three sets of off-by-ones. It is also why the presence bug above is unnoticed: only one client shape exists.

Suggested fix: Lift the mirror (state + seq + apply/fold/replace*) and the ensureCapture decision into go/pkg/leyline as an exported Session/Mirror type with the CLI's App-specific messaging left behind as callbacks, before D.14 starts; the CLI keeps only presentation.

- verifier (comment, downgraded P3): Facts check out: go/pkg/leyline exports only Dial/State/Events/Subscribe plus SortState/FindCapture/CurrentChannel (client.go), while the mirror (session.go:298,312-418), awaitEvent (:260) and ensureCapture (:423) are unexported in internal/cli. But nothing is broken today — there is exactly one client, and extracting a Session/Mirror API before the second consumer exists is a judgement call the owner may reasonably defer; the predicted triple-implementation cost is future, not present, so this …


### a-layering-7 — Object destruction is encoded as an UNSPECIFIED enum the proto never documents

`proto/leyline/v1/control.proto:94` · P3 · mechanical · contested

A destroyed channel or sink is emitted one final time with its state field left at the zero value, and that is the client's only signal the object is gone. Nothing in control.proto says so: `enum ChannelState { CHANNEL_STATE_UNSPECIFIED = 0; ... }` (line 94) and `enum SinkState { SINK_STATE_UNSPECIFIED = 0; SINK_ACTIVE = 1; }` (line 110) carry no comment, and neither does `ChannelState state = 8` (line 80). The convention exists only in three implementation comments — and the fake's asserts the proto documents it.

Why it matters: The .proto is the contract every non-Go client is written from (CLAUDE.md invariant 1); a Swift-app or MCP author reading it treats a tombstone as a live channel in an unknown state and never removes it from their mirror. Worse, go/internal/fakedaemon/state.go:273 points the reader at "control.proto's SinkState" for an explanation that is not there, so the one person who goes looking is sent to an empty page.

Suggested fix: Comment both enums and both state fields in control.proto — "UNSPECIFIED on an event means the object was destroyed; drop it from your mirror" — and fix the fake's comment to stop citing a proto note that does not exist. Additive-only, no field changes.

- verifier (comment, refuted P3): control.proto:104-108 does document the convention, in the Sink message: "A detached sink is emitted one last time with state unset -- the same tombstone Channel uses. Without it an attach and a detach are the same bytes on the wire". So the claim "nothing in control.proto says so" is wrong, the Channel case is covered by that cross-reference, and fakedaemon/state.go:273's pointer at control.proto's SinkState sends the reader to a real paragraph, not an empty page.

- verifier (comment, downgraded P3): The premise is partly wrong: control.proto:104-107 does document the tombstone on Sink ('A detached sink is emitted one last time with state unset -- the same tombstone Channel uses'), so the fake's pointer at state.go:273 lands on a real note and the 'sent to an empty page' rationale does not hold. What remains is that Channel.state (control.proto:80) and both enums carry no comment of their own, so the convention is only findable via the Sink message. Worth one additive comment on …


### a-layering-8 — `watch` names two different things: the D.14 dashboard and the D.15 job

`go/internal/cli/stubs.go:22` · P3 · design · confirmed

The CLI reserves the verb `ley watch` for the Bubble Tea dashboard (build-order D.14) via a hidden stub, while the wire contract already defines `WatchConfig` as a job — "Watch 146.52 and log anything heard. Owns a persistent channel; produces a transcript" — landing at D.15 with `Jobs.StartJob(watch)`, `ley://watches/<id>/transcript` and `Jobs.GetTranscript`.

Why it matters: When D.15 lands, `ley watch 146.52` reads unambiguously as "start a watch job on 146.52" to any user who has read the docs, and the verb is already taken by a no-argument dashboard; whoever implements it has to either rename a shipped verb or invent a second spelling for a first-class job type. The collision is cheap to resolve now (the dashboard verb is still a stub) and expensive after either ships.

Suggested fix: Pick now: either the dashboard becomes `ley dash`/bare `ley` only and `watch` is reserved for the job, or the job verb becomes `ley monitor`. Record the choice in docs/dev/cli-style.md and update the stub table.

- verifier (comment, downgraded P3): The collision is real — stubs.go:22-28 reserves `watch` for the D.14 dashboard (docs/plans/build-order.md:34) while jobs.proto:37-44 defines WatchConfig as the D.15 job with ley://watches/<id>/transcript (jobs.proto:109). But the dashboard verb has never shipped as a working command (hidden, exit 2), so nothing has to be renamed or deprecated later; this is a naming decision to record, not a defect.

- verifier (comment, downgraded P3): Collision is real (stubs.go:22-28 reserves `watch` for the dashboard, jobs.proto WatchConfig plus docs/plans/build-order.md:38 make watch a D.15 job), but docs/plans/build-order.md:34 already says the dashboard is bare `ley`, so `ley watch` is a redundant alias rather than a committed verb, and it is hidden and unimplemented. One-line resolution now (drop or rename the stub, reserve `watch` for the job, note it in docs/dev/cli-style.md). Touches the same stub entry as a-layering-13 — fix them together.


### a-layering-9 — The cross-language contract's only proof is two opt-in tests

`go/internal/e2e/e2e_test.go:28` · P2 · design · confirmed

e2e_test.go is described as "the living proof of the cross-language contract" but contains two test functions (TestCLIAgainstRealDaemon:185, TestScanAgainstRealDaemon:349) and skips entirely unless LEYLINED_BIN and LEY_BIN are set. Everything else — the whole go/internal/cli suite plus fakedaemon's own tests — runs against a second implementation of the contract whose package doc asserts "the same error codes, event attribution, presence rules and stream negotiation as the Swift daemon" with nothing checking the claim.

Why it matters: Three concrete divergences are already live and none is caught: Jobs-plane presence (fake touches, Swift does not), the code→gRPC-status table, and gain step_db snapping. Because the fake is the default target, a CLI change that depends on fake-only behaviour goes green and fails against the real daemon only when someone happens to run the opt-in suite.

Suggested fix: Extract the assertions that are purely contract (error code + gRPC status per rejection, presence/reap timing per plane, event attribution, tombstone encoding) into a table-driven conformance suite parameterised by a daemon address, and run it in CI against both the fake and a built leylined; keep the CLI-shaped e2e tests as they are.

- verifier (comment, downgraded P3): The premise is wrong: `make e2e` builds both binaries and runs the suite, and .github/workflows/ci.yml:60-61 runs `make e2e` on every CI run (Makefile:54-60,71) — the suite is not opt-in in practice, it is skipped only when run bare via `go test`. The residual true part is narrower: three test funcs (e2e_test.go:185,349, stream_test.go:17) are CLI-shaped, so none of them pins error-code→status, per-plane presence, or gain snapping, and a fake/real conformance table would be a genuine …


### a-layering-10 — Auto-squelch default is decided by the --json flag inside the CLI

`go/internal/cli/tune.go:100` · P3 · scoped · confirmed

With no --squelch flag, tuneFlags.parse turns auto squelch on for NFM and AM only when `!app.JSON && !f.persistent`. A presentation flag (whether output is NDJSON) therefore decides a DSP behaviour, and the rule — which is a real part of what "tune 146.52 and listen" means — lives in the CLI where the D.14 TUI and D.16 adapter cannot see it.

Why it matters: `ley tune 146.52` and `ley tune 146.52 --json` produce channels with different squelch settings for reasons unrelated to output format, which is surprising to anyone scripting the CLI; and an agent tuning through the MCP adapter gets no squelch at all unless the adapter author rediscovers and re-implements the rule.

Suggested fix: Move the default to an exported helper in go/pkg/leyline (e.g. `DefaultSquelchAuto(mode, persistent bool) bool`) keyed on mode and persistence only, and let the CLI pass its own "interactive" decision in explicitly rather than reading app.JSON inside the rule.


### a-layering-11 — ley:// resource URIs are built and parsed by string literal in four places

`go/internal/cli/scan.go:259` · P3 · scoped · contested

`ley://scans/<id>` is concatenated in the Swift daemon (Jobs/JobStore.swift:140) and in the fake (fakedaemon/jobs.go:85), and taken apart with strings.CutPrefix in the CLI (scan.go:259) and String(uri.dropFirst(...)) in a Swift test. go/pkg/leyline has no URI type, though docs/reference/cli.md:19 makes ley:// URIs the MCP adapter's resource identity one-to-one and jobs.proto:109 already lists four kinds (recordings, scans, snapshots, watches/<id>/transcript).

Why it matters: D.16 has to parse and mint all four kinds; with no shared helper the adapter becomes a fifth copy, and a plural/singular slip (`ley://scan/` vs `ley://scans/`) is caught by nothing — scanIDOf simply returns "" and the caller reports a scan with no detections rather than an error.

Suggested fix: Add a small ResourceURI type to go/pkg/leyline (kind constants + Parse/Format) covering the four kinds in jobs.proto:109, use it in the CLI and the fake, and have scanIDOf return an error rather than "" when no scans URI is present.

- verifier (comment, refuted P3): The stated harm does not happen: scan.go:160-169 explicitly handles the empty return — under --json it is `ExitError{Code:1, "the daemon started no scan: ..."}`, otherwise it prints the status detail — so a prefix slip does not silently become "a scan with no detections". Only three live sites exist for one prefix (JobStore.swift:140, fakedaemon/jobs.go:85, scan.go:259) and the other URI kinds in jobs.proto:109 are unimplemented, so what remains is "consider adding a shared URI type".

- verifier (comment, confirmed P3): Verified only three non-generated sites and one kind: JobStore.swift:140 and fakedaemon/jobs.go:85 mint `ley://scans/`, scan.go:257-263 parses it and returns "" on miss. A four-kind ResourceURI type today is building ahead of need — the concrete defect is scanIDOf swallowing a malformed/absent URI into 'no detections'. Keep it at P3 and scope the fix to returning an error there; revisit the shared type when D.15/D.16 actually mint the other kinds.


### a-layering-12 — ChannelEngine.telemetry() is a test-only duplicate of telemetrySubscription()

`engine/Sources/EngineCore/CoreProtocols.swift:260` · P3 · mechanical · confirmed

The ChannelEngine protocol requires both `telemetry() -> AsyncStream<ChannelTelemetry>` and `telemetrySubscription() -> ChannelTelemetrySubscription`. The implementation of the first is literally `hub.subscribe().stream` (DefaultChannelEngine.swift:226-228), and no production caller uses it — the only call sites are EngineCoreTests/ChannelTests.swift:410,452,500 and FixtureTests.swift:127.

Why it matters: Every future ChannelEngine (a TX-side sibling, a test double, a composite device) must implement a method nothing calls, and the engine tests exercise a subscription path production does not use, so they cannot observe the per-subscriber `dropped` counter that the real telemetry drain diffs.

Suggested fix: Delete `telemetry()` from the protocol and the implementation; the four test call sites become `.telemetrySubscription().stream`.


### a-layering-13 — Stub roadmap labels do not match docs/plans/build-order.md

`go/internal/cli/stubs.go:26` · P3 · mechanical · contested

The hidden `watch` stub tells the user its milestone is "V0.5", a label that appears nowhere in docs/plans/build-order.md; the TUI dashboard it describes is item 14 under Milestone D. The sibling `record` stub correctly says "Milestone C.12" (docs/plans/build-order.md:32), so the two entries in the same table use different vocabularies.

Why it matters: The stub message is user-facing (`ley watch` exits 2 with it, and `ley help roadmap` lists it), so a user asking when the dashboard arrives is given a milestone name they cannot find in the repo, and a maintainer reconciling the roadmap has to guess which document is authoritative.

Suggested fix: Change the watch stub's milestone to "Milestone D.14" to match docs/plans/build-order.md:34.

- verifier (comment, refuted P3): "V0.5" is not an invented label: docs/plans/user-stories.md:20 heads a section "V0.5 — TUI dashboard (Go, Bubble Tea)", docs/guide/using-ley.md:36 says "the V0.5 dashboard", and docs/reference/cli.md:168 states outright "`record` (Milestone C.12) and `watch` (the V0.5 dashboard) exist as hidden verbs". The stub matches the docs that describe it; a user can find the term in the repo, so the stale-comment claim does not hold.

- verifier (comment, confirmed P3): Verified stubs.go:26 says milestone 'V0.5' while its sibling at :20 says 'Milestone C.12' and docs/plans/build-order.md:34 puts the dashboard at D.14; 'V0.5' appears nowhere in docs/plans/build-order.md. The string is user-facing via stubMessage and `ley help roadmap`. One-word fix; sequence it with a-layering-8, which may delete or rename the same entry.


## Architecture: how the daemon bends (jobs, concurrency, shutdown, forward-compat)

Coverage: Fully read: engine/Sources/LeylineDaemon/Jobs/JobStore.swift (all 335), Jobs/SessionCaptureAllocator.swift (all 275), Server.swift (all 184), Bulk/StreamRegistry.swift (all ~356), proto/leyline/v1/jobs.proto, proto/leyline/v1/control.proto, go/pkg/leyline/client.go (all 475), docs/design/control-plane.md, docs/design/semantic-tier.md. Read in full except the tail: Jobs/ScanRunner.swift (lines 1-420 of ~500; the SweepPlan-helper tail and any trailing statics after line 372 not read). Read by section: Session/SessionStore.swift — lines 104-560 (state, events/history, presence/reap/clientGone, …


### a-evolution-1 — startScan installs the job's Task after an actor hop, so a cancel in that window cancels nothing

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:148` · P1 · scoped · confirmed

`startScan` inserts the entry, then suspends on `await store.publishJob(job)`, and only afterwards creates the sweep Task and stores it in `entries[id]?.task`. JobStore is an actor and re-entrant at that suspension: `clientGone` (wired to SessionStore.reap) or a CancelJob for that id can run in the window, find `e.task == nil`, cancel nothing, poll for 3 s and then `finish(id, state: .cancelled)`. `startScan` then resumes and launches the sweep anyway — `run` never checks the entry's state.

Why it matters: The job table reports CANCELLED while an uncancellable sweep task holds a `SessionCaptureLease` on the radio for the whole range (minutes for a wide sweep). Every subsequent CreateCapture on that device gets DEVICE_SWEEPING and every new scan is declined with "another scan already has …", with no running job anywhere to explain it. `setDetail`/`finish` are state-guarded, so the sweep is also invisible on the event stream.

Suggested fix: Create the Task before the first suspension (or hold a cancellation flag on Entry that `run` re-checks after `publishJob` and after `allocate`, releasing the lease immediately if the entry is no longer `.running`).


### a-evolution-2 — DestroyCapture is the one mutation that skips refuseIfSwept, so a client can yank a running scan's radio

`engine/Sources/LeylineDaemon/Session/SessionStore.swift:538` · P2 · mechanical · confirmed

`swept` guards every other path into a capture a job holds — CreateChannel (:577), center_hz and sample-rate writes (:737, :748), and CreateCapture on the same device (:408) — but `destroyCaptureChecked` only checks existence. ControlService.destroyCapture calls it directly, so DestroyCapture on a swept capture stops the engine underneath the lease.

Why it matters: Invariant 9 puts jobs behind the allocator precisely so a client cannot disturb them; here any client (including a polite agent that would never retune) can end a sweep. The sweep then fails at its next `lease.retune` with a device error and reports "the radio went away mid-sweep", which misattributes a client action to hardware, and `lease.release()` afterwards retunes/destroys a capture that no longer exists.

Suggested fix: Call `try refuseIfSwept(id)` in `destroyCaptureChecked` (leaving the internal `destroyCapture`, which the lease itself uses, unguarded).


### a-evolution-3 — StreamRegistry registers a subscription after its engine hookups, so a concurrent capture teardown orphans it

`engine/Sources/LeylineDaemon/Bulk/StreamRegistry.swift:232` · P2 · scoped · confirmed

`subscribe` awaits `store.captureEngine`, `capture.snapshot`, then `capture.spectrum.subscribe` / `ch.attach` / `capture.addTap`, and only at the end does `subs[id] = sub`. `SessionStore.destroyCapture` runs `teardownHook(.capture(id))` — which iterates `subs.values` — before `engine.stop()`. A Subscribe that started before the teardown registers its subscription after `teardown` has already walked the table.

Why it matters: The stream survives its capture: it holds a ladder subscription or IQ tap on a stopped engine, its ring never produces a frame, and `teardown` will never see it again. If a reader attaches within the 10 s grace, `reapIfUnread` skips it (`!sub.isReading`) and the client's Stream RPC blocks forever instead of ending when the capture died. Same window exists for `.channel` teardown.

Suggested fix: Insert a placeholder into `subs` under the capture/channel key before the first await (or re-check `store.captureEngine(captureID) != nil` immediately before `subs[id] = sub` and close the half-built source if it is gone).


### a-evolution-4 — Daemon.shutdown stops accepting connections last, after the store and devices are already torn down

`engine/Sources/LeylineDaemon/Server.swift:174` · P2 · scoped · confirmed

`shutdown()` runs `jobs.cancelAll()` (up to ~3 s per running job), `streams.closeAll()`, `store.shutdown()` and `registry.stop()`, and only then calls `server.beginGracefulShutdown()`. The listener is accepting and dispatching RPCs for the entire teardown.

Why it matters: A CreateCapture that lands during those seconds runs after `store.shutdown()` has destroyed every capture: it opens the dongle, registers a CaptureEntry nobody will ever stop, and the daemon exits with the device open and its DSP thread running. Milder variants: channels created after the reap, streams subscribed after `closeAll`. On SIGTERM mid-scan the window is a guaranteed multi-second one because `cancelAll` waits on each sweep.

Suggested fix: Call `server.beginGracefulShutdown()` first so no new RPC is accepted, then tear down jobs, streams, store and registry (and, if in-flight handlers must finish, await `serve()`'s return before `store.shutdown()`).


### a-evolution-7 — Job.result_uris advertises ley://scans/<id> that nothing resolves, and the Scan is dropped after 16 finished jobs

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:140` · P3 · design · confirmed

Every scan job publishes `result_uris = ["ley://scans/<id>"]`, but all three Resources RPCs throw UNIMPLEMENTED, so the only way to fetch one is Jobs.GetScan with the id string-stripped out of the URI. The Scan itself is a field of the in-memory job Entry, looked up by linear search, and `trim()` deletes the entry — and with it the Scan — once 16 finished jobs are ahead of it.

Why it matters: A URI handed out on the wire is a promise a client can dereference; here it resolves nowhere by the documented route and stops resolving at all after 16 more jobs, with no event and no error distinguishing "gone" from "never existed". The MCP adapter at D.16 maps resource URIs one-to-one onto these, so it inherits both the prefix-stripping hack and the silent expiry.

Suggested fix: Either stop emitting `result_uris` until a resource store backs them (and document GetScan as the v0 route), or make GetScan/GetResource accept the URI and answer SCAN_EXPIRED distinctly from SCAN_NOT_FOUND when trim dropped it.

- verifier (comment, downgraded P3): Facts check out (JobStore.swift:140 emits ley://scans/<id>, Resources RPCs all throw at JobsService.swift:63-75, trim() at :327-334 drops the Scan with the entry, and go/internal/cli/scan.go:258-259 does strip the prefix), but Resources is explicitly a D.15 deliverable (JobsService.swift:1-2) and keepFinished=16 is documented as a memory bound; the working v0 route (GetScan) resolves and nothing breaks today, so this is a nit-level API tidy-up, not a P2.

- verifier (comment, downgraded P3): The URI is dereferenceable in v0 — Jobs.GetScan resolves the id and go/internal/cli/scan.go:256-264 does the prefix strip in one commented helper — and the 16-job bound is documented at JobStore.swift:14. What survives is that Resources.* is UNIMPLEMENTED (JobsService.swift:63-75) while jobs.proto:24 advertises 'ley:// resources produced so far' with no note of the v0 route, which is a comment-sized fix, not the design change proposed.


### a-evolution-8 — Job failures pack the machine code into status_detail; Job carries no ErrorDetail

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:290` · P2 · scoped · confirmed

`finish` writes `"\(code): \(detail)"` into `status_detail`, a field jobs.proto documents as human-readable prose. `Job` has no error field, so DEVICE_BUSY, FREQ_OUT_OF_RANGE, BLIND_SPOT and NO_DEVICE reach clients only as a prefix inside an English sentence.

Why it matters: CLAUDE.md's error rule is stable machine codes in `ErrorDetail.code`, prose in `message`; every other failure path in the daemon honours it (WriteRejected carries an ErrorDetail). A client that wants to branch on "the radio cannot tune that" versus "somebody is using it" has to split the string, and any wording change silently breaks it — the CLI already string-matches on this to render scan failures.

Suggested fix: Add `ErrorDetail error = 10;` to Job (additive within v1), set it in `finish`, and leave `status_detail` prose-only.


### a-evolution-9 — DefaultDeviceRegistry.poll() runs blocking libusb enumeration and opens on the actor

`engine/Sources/EngineCore/Devices/DeviceRegistry.swift:272` · P2 · scoped · confirmed

`poll()` is a synchronous actor method that calls `RTLSDRDevice.enumerate`, which loops over USB devices calling `rtlsdr_get_device_usb_strings`, `rtlsdr_open`, `rtlsdr_get_tuner_gains` and `rtlsdr_close` inline. The registry actor — and the cooperative-pool thread running it — is blocked for the whole pass, once a second.

Why it matters: Every caller serialises behind it: `SessionStore.createCapture` awaits `registry.device(id:)` and `registry.markInUse`, the allocator's `borrow` awaits `registry.device`, and each `rtlsdr_open` on a dongle held by another program can take hundreds of milliseconds. It also parks a pool thread that Swift concurrency assumes is never blocked. The file's own neighbour does this correctly and says so: `RTLTCPDevice.open` is routed through `BlockingWork` "so the task itself never parks a pool thread".

Suggested fix: Run the enumeration through the existing `BlockingWork` off-actor helper and hop back to apply the probes (`applyProbes` is already split out for exactly this shape).


### a-evolution-13 — The daemon overwrites ScanConfig.step_hz in the Scan, so Job.config and Scan.config disagree

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:248` · P3 · scoped · confirmed

`setStep` rewrites `scan.config.stepHz` with the advance the sweep planner chose. `Job.config.scan` keeps the client's original request, so the same message field carries two different values in two places in one response set.

Why it matters: `step_hz` is a request field; a client comparing the Scan's echoed config against what it submitted sees a value it never sent, and a client rendering `ley jobs` next to `ley scan --json` sees two numbers for one parameter. The answer already has a proper home — `resolution_hz` was added as an answer field for precisely this reason.

Suggested fix: Leave `config` as the client sent it and report the chosen advance in its own answer field on Scan (alongside `resolution_hz`).


### a-evolution-14 — Design docs still use sdr:// URIs and `sdr` verbs; the contract is ley://

`docs/design/control-plane.md:76` · P3 · mechanical · confirmed

Both design docs describe resources as `sdr://recordings/<id>`, `sdr://scans/<id>`, `sdr://snapshots/<id>`, `sdr://watches/<id>/transcript`, and the CLI mirror as `sdr devices`, `sdr tune`, …. CLAUDE.md, jobs.proto and the daemon all use `ley://` and the binary is `ley`.

Why it matters: These are the documents the build order says to read before structural changes, and the D.16 MCP adapter maps resource URIs one-to-one off this text. Someone implementing Resources from the doc emits the wrong scheme.

Suggested fix: Search-and-replace `sdr://` → `ley://` and the `sdr ` verb examples → `ley ` in both design docs (docs/design/data-planes.md:66 has the same drift).


### a-evolution-15 — design-control-plane says the proto reserves auth fields for remote access; control.proto reserves none

`docs/design/control-plane.md:81` · P3 · mechanical · confirmed

The remote-access decision reads "Proto reserves the auth fields now so the addition is non-breaking." Nothing in control.proto reserves anything for auth — there is no reserved range on DaemonInfo, no auth message, no credential field on any request.

Why it matters: The forward-compat claim is load-bearing for the remote-access milestone: whoever picks it up will read this as settled and find the reservation missing, and the field numbers it assumed were held may already be taken by then.

Suggested fix: Either reserve the field numbers now (a `reserved` range on DaemonInfo/GetStateRequest, or an explicit note that auth rides in gRPC metadata) or amend the doc to say the decision is deferred with nothing reserved.


### a-evolution-16 — Allocator leaks a freshly created capture on two error paths

`engine/Sources/LeylineDaemon/Jobs/SessionCaptureAllocator.swift:85` · P3 · mechanical · confirmed

In the no-existing-capture branch, `store.createCapture` succeeds and then two `guard … else { continue }` paths abandon it without destroying: an unparseable capture id and a failed `leased.insert`. The third failure path (`borrow` returning nil) does call `store.destroyCapture`.

Why it matters: Both guards are near-unreachable today (the id comes from the daemon, the ULID is fresh), so this is cheap to fix and easy to break later: the moment a capture id can be recycled or `leased` can hold a stale entry, a scan that declines leaves the device open with a capture nobody owns and no job to cancel.

Suggested fix: Destroy the capture in both `continue` paths, or restructure so the created capture is owned by a `defer`-guarded local that destroys unless the lease is returned.


### a-evolution-17 — ScanRunner is declared an actor but has no instance state

`engine/Sources/LeylineDaemon/Jobs/ScanRunner.swift:107` · P3 · mechanical · confirmed

`actor ScanRunner` contains only static members — `bins`, `targetLooks`, `log`, `sweep`, `fold`, `merge`, `union`, `segment`. Nothing is ever instantiated, and `sweep` is therefore nonisolated despite the type reading as an isolation domain.

Why it matters: The type advertises serialisation it does not provide. `sweep` mutates `merged`, `looked` and the shared `RowCollector` across many awaits and is safe only because one task calls it; a maintainer reading `actor` may conclude the isolation is what makes it safe and add a second concurrent caller.

Suggested fix: Make it `enum ScanRunner {}` (a caseless namespace), which states exactly what it is and removes the false isolation signal.


### Refuted

- **a-evolution-5** clientGone cancels every job of a departing client, and the hook is generic enough that watch/record inherit it at D.15 (`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:107`) — The v0 scoping is deliberate and documented twice at the exact places a maintainer would look: JobStore.swift:1-6 ("an ad-hoc scan is ephemeral by design ... Durable jobs and the resource store arrive together at Milestone D.15") and JobsService.swift:1-2 plus the explicit …

- **a-evolution-6** The allocator can only express an exclusive, restore-on-release capture hold — a watch job cannot be built on it (`engine/Sources/LeylineDaemon/Jobs/SessionCaptureAllocator.swift:22`) — SessionCaptureAllocator.swift:21-24 declines `.channel` with UNIMPLEMENTED and the comment "Watch jobs land here (Milestone D.15). A sweep is the only caller today." The whole finding is about how a job type that does not exist would be built; no current path is wrong. Speculative design work for …

- **a-evolution-10** Any client can create a persistent channel with no job behind it, and nothing ever reaps it (`engine/Sources/LeylineDaemon/Session/SessionStore.swift:591`) — Client-created persistent channels are the documented product feature, not a hole: docs/dev/engine-internals.md:286 "`ley tune --persistent` creates a persistent channel and exits", the flag is shipped at go/internal/cli/tune.go:29, and `ley stop` exists to end them (go/internal/cli/stop.go:21 names …

- **a-evolution-11** The Go client has no stream resume, and a dropped WatchEvents stream costs the client its channels and jobs (`go/pkg/leyline/client.go:280`) — The library gap is real (client.go:280-290 opens one stream, pump at :309-336 reports one terminal error, ScopeSince at :266-273 is only used by callers) but the Events doc comment prescribes the resume route and the in-tree consumer uses it: go/internal/cli/session.go:212 already opens with …

- **a-evolution-12** WriteParams is one-shot per call, so nothing can hold the coalescing stream drag-to-tune was designed around (`go/pkg/leyline/client.go:341`) — client.go:341-355 is one-shot as described, but the streaming contract is exercised — the helper sends a whole batch over one open stream before CloseAndRecv, so the daemon's coalescer path is reachable from Go — and every current consumer is a one-shot verb. The failure described (a TUI dragging …


## Comment language: `go/internal/cli` (a–r)

Coverage: Fully read (non-test code, every line, every comment) for all 16 assigned files: band.go, change.go, columns.go, daemon.go, devices.go, errink.go, fft.go, format.go, helpink.go, listen.go, logs.go, meter.go, phosphor.go, phosphor_view.go, play.go, root.go (4663 lines total). Cross-checked callers/definitions in a few adjacent files outside scope only to verify claims (medianDb in spectrum.go, meterSink usage in tune.go, fmtDuration reference in play.go, the V0.5 stub in stubs.go, and docs/plans/*.md for prior-fix records) — none of those files' own code was reviewed for findings, per …


### c-go-cli-a-2 — Narrative "used to report" comment on processGone

`go/internal/cli/daemon.go:550` · P2 · mechanical · confirmed

The comment explaining processGone/isZombie says "...which is why stop used to report \"did not exit within 5 s\" for a daemon started from the same shell that ran ley", narrating a historical behavior of a prior version of `stop` rather than describing current behavior.

Why it matters: A reader with no access to the project's review history has no way to know what stop "used to" do or why that matters; the comment reads as a changelog entry left in the source rather than documentation of the current zombie-detection logic.

Suggested fix: Drop the "used to report" clause and state the current fact plainly, e.g. "...kill(pid, 0) still succeeds, so stop must also check for a zombie state or it would wait the full timeout and report a false failure for a daemon started from the same shell that ran ley."


### c-go-cli-a-3 — Narrative "used to occupy" framing in printDeviceTable doc comment

`go/internal/cli/devices.go:142` · P2 · mechanical · confirmed

The doc comment on printDeviceTable says "the ids and serials that used to occupy the two most-scanned columns move behind --wide", describing the table's current column layout by reference to a past layout the reader cannot see.

Why it matters: A stranger reading this file has no way to know what the table used to look like; the sentence only needs to justify why ID/SERIAL are behind --wide today, not narrate that they were once more prominent.

Suggested fix: Rephrase without the historical framing, e.g. "...so MODEL leads and STATE is next; ids and serials are the columns scanned least, so they move behind --wide, where the full id stays verbatim for `ley devices detach`."


### Refuted

- **c-go-cli-a-1** meterSink.write leaves stale terminal rows when the block shrinks (`go/internal/cli/meter.go:212`) — Read meter.go:187-247. The cited comment ('padded to what stood there before, so a shorter row leaves no residue') only claims per-row width padding, which the loop does correctly for i < len(m.lastLens). The finding is actually a functional/correctness claim about row-COUNT shrinkage (m.lastRows), …

- **c-go-cli-a-4** renderOrientation doc comment references an unexplained milestone name (`go/internal/cli/root.go:683`) — Checked stubs.go:17-29 and cli_test.go:305: 'V0.5' is a real, in-repo, actively-used milestone label (the 'watch' stub is literally described as 'Live dashboard: devices, channels and spectrum in one terminal', milestone V0.5), not an obscure or undefined reference confined to planning docs. The …

- **c-go-cli-a-5** Dead type-asserted variable in runDevices' watch loop (`go/internal/cli/devices.go:118`) — Confirmed devices.go:118 and :131 (`p, ok := ...` then `_ = p`) -- the dead-variable observation is technically accurate, but this is a code/dead-code issue, not a defect in a comment (no NARRATIVE/STALE-WRONG/CHATTER/DOC-COMMENT/PROSE claim is being made about any comment text). Out of scope for …


## Comment language: `go/internal/cli` (s–z)

Coverage: Fully read (non-test) all 20 assigned files: scan.go, session.go, set.go, spectrum.go, spectrum_axis.go, spectrum_chart.go, spectrum_render.go, spectrum_watch.go, state.go, stop.go, stubs.go, subaudible.go, tables.go, target.go, topics.go, transmission.go, tune.go, version.go, waterfall.go, waterfall_view.go (6037 lines total). Every comment (block, line, doc) was inspected against the narrative/stale/chatter/doc-convention/prose criteria; grepped for trigger words (used to, no longer, previously, this replaced, TODO/FIXME, etc.) and manually verified each hit and its surrounding block. …


### c-go-cli-b-1 — Doc comment for spectrumEnd narrates prior behavior instead of describing current code

`go/internal/cli/spectrum.go:245` · P2 · mechanical · confirmed

The doc comment for spectrumEnd includes 'it used to hang, then exit 0, with no output at all', narrating the function's history rather than describing its current behavior.

Why it matters: A stranger reading this with no access to the project's review history has no way to know what 'used to' refers to; the sentence is meaningless without that context and reads as project trivia embedded in the API doc.

Suggested fix: Drop the historical clause; state only what the function does now, e.g. '...a failure the user must be told about, not a silent success.'


### c-go-cli-b-2 — levelBand comment narrates a prior implementation via 'as this used to'

`go/internal/cli/spectrum_chart.go:265` · P2 · mechanical · confirmed

The doc comment for levelBand explains the rationale by referencing a previous, no-longer-existing implementation ('Keying it to the bottom of the axis instead, as this used to, meant...').

Why it matters: Without the review history, a reader cannot tell what 'as this used to' refers to — there is no such alternate implementation in the codebase to compare against, so the sentence is confusing rather than explanatory.

Suggested fix: Rephrase as a standalone rationale for the current design, e.g. 'Keying it to the bottom of the axis instead would count the row of air reserved under the floor as levels to ink, so every noise column would draw a little warm and the whole ramp would be offset.'


### c-go-cli-b-3 — spectrumLevelSteps comment references a design 'this replaced'

`go/internal/cli/spectrum_render.go:20` · P2 · mechanical · confirmed

The comment above spectrumLevelSteps says 'the three-band Muted/plain/Ok inking this replaced collapsed to plain across most of a live band', narrating a prior design that no longer exists in the code.

Why it matters: A reader with no knowledge of the earlier three-band inking scheme cannot evaluate or even parse this justification; it reads as an artifact of a review conversation rather than documentation of the current constant.

Suggested fix: Remove the comparison to the replaced scheme; keep only the rationale for the current 24-step ramp (that it lets neighbouring same-level columns merge into one escape-sequence run).


### c-go-cli-b-4 — spectrumQuietRampCap comment narrates the design it replaced

`go/internal/cli/spectrum_render.go:28` · P2 · mechanical · confirmed

The comment explains the constant's value by contrasting it with 'Forcing every column to the single coldest ink instead, which is what this replaced, was honest but unreadable... which is what the reader was actually complaining about.'

Why it matters: The phrase 'which is what this replaced' and 'what the reader was actually complaining about' assume familiarity with a review conversation that is not in the code; a stranger cannot verify or make sense of the claim.

Suggested fix: State only why the current 0.34 cap is right (keeps texture visible without ever looking busy), without describing the discarded alternative or an unnamed reader's complaint.


### c-go-cli-b-5 — Const block comment for scale/hold narrates two prior behaviors with 'used to'

`go/internal/cli/spectrum_render.go:43` · P2 · mechanical · confirmed

The comment above the spectrumHeadroomDb/spectrumHoldDecayDb const block describes two previous implementations ('The top used to reserve 30 dB...', 'The hold used to be a running maximum that never decayed...') to justify the current constants.

Why it matters: Both 'used to' clauses describe code that is gone; a maintainer reading this cold has no way to check the claim and gains nothing from the historical comparison — only the current headroom/decay behavior is verifiable.

Suggested fix: Describe only the current behavior: the scale tracks the loudest column with headroom (falling back to the minimum span on a dead-flat band), and the hold decays toward the live column each frame and is drawn only where it stands clear of it.


### c-go-cli-b-6 — rescale() inline comment narrates a prior scale-tracking bug with 'used to get'

`go/internal/cli/spectrum_render.go:236` · P2 · mechanical · confirmed

The inline comment inside rescale() justifying spectrumMinSpanDb describes a discarded per-frame tracking scheme ('while at the 1.5 dB a row an empty band used to get -- the top tracked the loudest noise column...').

Why it matters: The comparison to what an empty band 'used to get' is unverifiable and unnecessary for a reader who only has the current code; the useful fact (5 dB rows collapse noise spread into 1-2 rows, avoiding confetti) stands on its own.

Suggested fix: Drop the 'used to get' clause; contrast 5 dB rows directly with a hypothetical finer row (e.g. 'at a finer step the same floor would smear over several rows and read as confetti') instead of narrating a discarded implementation.


### c-go-cli-b-7 — spectrumWaitNote comment narrates a fixed bug with 'used to produce no output'

`go/internal/cli/spectrum_watch.go:16` · P2 · mechanical · confirmed

The comment for spectrumWaitNote says 'A stalled FFT stream used to produce no output at all', referencing a past defect rather than describing what the constant does now.

Why it matters: A stranger cannot verify or use the claim about the old behavior; it also implicitly needs the project's fix history to understand why this line exists at all.

Suggested fix: Drop the historical sentence; the first sentence already fully documents the constant's purpose.


### c-go-cli-b-8 — printArray has two stacked, inconsistent doc-comment opening sentences

`go/internal/cli/tables.go:47` · P2 · mechanical · confirmed

printArray's doc comment has two leftover first-sentence variants stacked back to back: 'printArray writes a client-local table as one JSON array line.' immediately followed by 'printArray marshals a client-local JSON shape -- an array of table rows, or the single object a band lookup answers with.' The first sentence is stale — it claims the output is always 'one JSON array line', but the second sentence (and the actual bandAnswerJSON caller) shows printArray also emits a single JSON object.

Why it matters: A reader skimming just the first line of the doc comment gets a wrong impression (array-only) that the rest of the same comment immediately contradicts; this is a rewrite that never deleted the sentence it superseded.

Suggested fix: Delete the stale first line ('printArray writes a client-local table as one JSON array line.') and keep only the accurate second sentence describing both array and single-object use.


### c-go-cli-b-9 — gutter() doc comment names the wrong constant for its refresh cadence

`go/internal/cli/waterfall_view.go:165` · P2 · scoped · confirmed

The doc comment for waterfallView.gutter says the elapsed-time label is 'printed on every waterfallAxisEvery-th row', but the implementation checks `v.rows%4 == 0` -- a hardcoded 4, unrelated to the waterfallAxisEvery constant (which is 20 and governs the frequency axis reprint cadence in a different function).

Why it matters: A maintainer changing waterfallAxisEvery to retune how often the frequency axis reprints would, per this comment, expect the time label's cadence to change too, but it would not -- the label still refreshes every 4 rows. Debugging or tuning the display cadence from the comment alone leads to a wrong mental model.

Suggested fix: Either rename the magic number 4 to a named constant and reference it correctly in the comment, or fix the comment to say 'every fourth row' instead of naming waterfallAxisEvery.


## Comment language: `go/pkg`, `go/cmd`, `go/internal/{ui,fakedaemon}`

Coverage: Fully read all non-test files in go/pkg/leyline (bands.go, client.go, errors.go, freq.go, presets.go, selectors.go, socket.go, userinput.go), go/pkg/iqfile (io.go, sidecar.go), go/cmd/ley/main.go and main_test.go, go/cmd/leyfix (all 10 non-test files), go/internal/ui (lipgloss.go, render.go, resolve.go, style.go, width.go) plus level_contrast_test.go, go/internal/fakedaemon (bulk.go, bulk_stream.go, control.go, daemon.go, devices.go, jobs.go, state.go, telemetry.go, writes.go) and skimmed/spot-read its test files (daemon_test.go headers, filedevice_test.go, streams_test.go, writes_test.go, …


### c-go-lib-1 — Doc comment for ChannelFrequency is misattached to ChannelCaptureRate

`go/pkg/leyline/selectors.go:147` · P2 · mechanical · confirmed

A 3-line doc comment beginning 'ChannelFrequency returns the channel's absolute frequency...' sits directly above func ChannelCaptureRate (no blank line), followed immediately by a second comment block 'ChannelCaptureRate is the sample rate...' also directly above the same function. Go tooling attaches the whole merged block to ChannelCaptureRate, whose doc text therefore starts with the wrong identifier's description, while the actual ChannelFrequency function six lines later has no doc comment at all.

Why it matters: godoc/go doc ChannelCaptureRate would show a doc string that starts by describing a different function, and `go doc ChannelFrequency` shows nothing at all -- exactly the DOC-COMMENT convention this review is checking for, and confusing for any external reader of the package's generated docs.

Suggested fix: Move the 'ChannelFrequency returns...ok is false when the capture is not in state.' comment down to directly precede func ChannelFrequency, leaving only the 'ChannelCaptureRate is the sample rate...' comment above func ChannelCaptureRate.


### c-go-lib-2 — Narrative before/after comparison for the level ramp's cold-end colour

`go/internal/ui/lipgloss.go:97` · P2 · mechanical · confirmed

The comment says 'The ramp used to run from a saturated {0,0,160} at the cold end, which is 1.2:1 against a dark ground -- a reader on a dark terminal could not see the noise floor at all, and since most of a chart is noise floor, most of the chart was invisible.' This narrates what an earlier version of the code did rather than describing the current design.

Why it matters: A reader with no access to the project's review history has no way to know '{0,0,160}' was ever used; the comment only makes sense as a before/after story, which is exactly what a stranger reading the shipped code should not need.

Suggested fix: Rewrite as a hypothetical/rationale instead of a history: e.g. 'A saturated blue like {0,0,160} would be only 1.2:1 against a dark ground -- unreadable, since most of a chart is noise floor sitting at the cold end.'


### c-go-lib-3 — Same narrative before/after story duplicated in the contrast test

`go/internal/ui/level_contrast_test.go:28` · P3 · mechanical · confirmed

The package doc-level comment above TestLevelRampIsLegibleOnBothGrounds repeats the same history claim as lipgloss.go:97 ('The cold end used to be a saturated {0, 0, 160}...most of the chart was invisible') and additionally uses first-person plural ('we are forbidden from asking which one that is'), which is conversational voice rather than code description.

Why it matters: Same as the lipgloss.go instance: meaningless without the project's review history, and the 'we' framing reads as a note to reviewers rather than documentation of the test's purpose.

Suggested fix: Rewrite in third person without the historical claim, e.g. 'The ramp has to be legible on the terminal the reader actually has, without querying it (no OSC background query, no HasDarkBackground). So every stop must clear the same bar against a black ground and a white one; a saturated blue like {0,0,160} would only be 1.2:1 against a dark terminal, at the cold end where most of a spectrum's noise floor sits.'


### c-go-lib-4 — Plan item id 'CLI-4 #15' leaked into a public API doc comment

`go/internal/fakedaemon/daemon.go:45` · P2 · mechanical · confirmed

The doc comment for the exported Options.WriteAwaitsWatcher field ends '...the real daemon may register the stream after the write lands (CLI-4 #15 makes the session resume from the snapshot's seq instead).' 'CLI-4 #15' is a review/plan item identifier meaningful only against the project's planning docs.

Why it matters: This is doc-comment text on an exported struct field of a package other Go code (and any godoc reader) consumes; a stranger has no way to resolve 'CLI-4 #15' to anything, and the parenthetical adds no information without that context.

Suggested fix: Drop the plan id and state the fact plainly, e.g. '...the real daemon may register the stream after the write lands, and a session resumes from the snapshot's seq rather than from zero.'


### c-go-lib-5 — Plan item id 'FU-2' in a test's doc comment

`go/internal/fakedaemon/writes_test.go:11` · P3 · mechanical · confirmed

TestStoredWritesWhileOutOfCapture's doc comment reads 'mirrors the daemon's FU-2 rule: bandwidth, mode and squelch writes on an OUT_OF_CAPTURE channel are stored, not rejected...'. 'FU-2' is docs/plans/archive/engine-review-fixes.md's internal id for this behaviour and conveys nothing on its own.

Why it matters: A stranger reading the test has no way to resolve 'FU-2'; the sentence is fully meaningful without it, so the id is pure narrative baggage from the review process.

Suggested fix: Drop '(the daemon's) FU-2 rule' and say what the rule is directly: 'TestStoredWritesWhileOutOfCapture verifies that bandwidth, mode and squelch writes on an OUT_OF_CAPTURE channel are stored, not rejected, ...'.


### c-go-lib-6 — Plan reference ('the CLI plan') in FrequencyHint's doc comment

`go/pkg/leyline/freq.go:205` · P2 · mechanical · confirmed

FrequencyHint's doc comment opens the rule description with 'The rule from the CLI plan: when re-reading a bare number as kHz lands inside a device range or a known band, suggest that spelling...'. 'The CLI plan' names an internal planning document a stranger reading this package has no access to or need of.

Why it matters: The rest of the sentence fully explains the behaviour on its own; prefacing it with an unresolvable document reference is exactly the kind of history-dependent phrasing the comment-language review targets.

Suggested fix: Drop 'The rule from the CLI plan:' and start directly with 'When re-reading a bare number as kHz lands inside a device range or a known band, suggest that spelling...'.


### c-go-lib-8 — Doubled/garbled wording in writeRecording's doc comment

`go/internal/fakedaemon/filedevice_test.go:15` · P3 · mechanical · confirmed

The comment reads 'writeRecording writes <dir>/<name>.cf32 holding samples CF32 samples and its sidecar.' -- 'holding samples CF32 samples' repeats 'samples' in a way that does not parse as a sentence.

Why it matters: A reader has to guess whether the first 'samples' is meant to be the parameter name (in which case it needs formatting to read as code) or a leftover word from editing; as written it just looks like a typo.

Suggested fix: Reword to something unambiguous, e.g. '// writeRecording writes <dir>/<name>.cf32 holding `samples` CF32 samples, plus its sidecar.'


### Refuted

- **c-go-lib-7** User-facing error message names an internal milestone id (`go/internal/fakedaemon/jobs.go:60`) — This is a runtime error-message string, not a source comment, so it's outside the comment-review lens (NARRATIVE/STALE/CHATTER/DOC-COMMENT/PROSE) this batch is checking. More importantly its 'why it matters' is factually wrong: internal/fakedaemon is imported only by _test.go files across the repo …


## Comment language: Go tests

Coverage: Read every *_test.go under go/ (excluding go/gen), 61 files total: cmd/ley/main_test.go, cmd/leyfix/leyfix_test.go, all of internal/cli/*_test.go (37 files), internal/ui/*_test.go (7 files), internal/fakedaemon/*_test.go (5 files), internal/e2e/*_test.go (2 files), pkg/leyline/*_test.go (9 files), pkg/iqfile/iqfile_test.go. Every comment (// lines, doc comments, t.Errorf/t.Fatalf/t.Logf message strings) was either read directly or covered by a full-file grep for the narrative/chatter/TODO trigger patterns plus a manual re-read of files with the highest comment density …


### c-go-tests-1 — Comment narrates a fixed regression via 'used to be' history

`go/internal/ui/level_contrast_test.go:28` · P3 · mechanical · confirmed

The comment explaining the WCAG contrast test says 'The cold end used to be a saturated {0, 0, 160}... most of the chart was invisible', narrating the bug that was fixed rather than describing current behavior.

Why it matters: A reader with no access to the project's review history gets an anecdote about a bug that no longer exists instead of a self-contained explanation of why the test enforces a 3:1 contrast minimum.

Suggested fix: Rewrite to state the invariant directly, e.g. 'The cold end must clear the same contrast bar as every other stop, because most of a spectrum's ink sits at the noise floor.'


### c-go-tests-2 — Comment narrates the tree renderer's pre-unification behavior

`go/internal/cli/state_render_test.go:118` · P3 · mechanical · confirmed

Comment says 'The tree used to print it twice where `ley devices` collapsed it; they share the renderer now', narrating history instead of describing current behavior.

Why it matters: Without the review history, 'used to' and 'now' are meaningless to a new reader; the comment should just state the current rule.

Suggested fix: Replace with 'A file device tunes to exactly one frequency, so the tree collapses it the same way `ley devices` does, sharing the renderer.'


### c-go-tests-3 — Doc comment narrates the two renderers' pre-sharing history

`go/internal/cli/format_test.go:24` · P3 · mechanical · confirmed

The doc comment for TestRangesPhraseCollapses says '`ley devices` always collapsed it; `ley state`'s tree did not, and they now share the renderer', narrating a merge instead of describing current behavior.

Why it matters: The 'now' framing requires knowing the prior state of the code to parse; it doesn't hold up once that context is gone.

Suggested fix: State the current shared behavior only, e.g. 'Both `ley devices` and `ley state`'s tree render this through the same collapsing renderer.'


### c-go-tests-4 — Table-entry comment narrates a fixed nil-panic bug

`go/internal/cli/format_test.go:41` · P3 · mechanical · confirmed

Comment on the nil-element test case reads 'A nil element used to panic; skipping it is a latent fix', narrating a past bug and using chatter-like 'latent fix' framing.

Why it matters: 'used to panic' is meaningless without the history; the test case should just document the current guarantee (nil elements are skipped, never dereferenced).

Suggested fix: Rewrite as 'A nil element is skipped rather than dereferenced.'


### c-go-tests-5 — Comment says a preset description 'no longer' restates the frequency

`go/internal/cli/tables_test.go:46` · P3 · mechanical · confirmed

Comment reads 'The description no longer restates the frequency printed beside it', narrating a change rather than stating the current rule.

Why it matters: 'No longer' presumes the reader knows the prior behavior; the invariant under test should be stated plainly.

Suggested fix: Rewrite as 'The description must not restate the frequency printed beside it.'


### c-go-tests-6 — Doc comment narrates a past bug ('used to report')

`go/internal/cli/logs_test.go:189` · P3 · mechanical · confirmed

TestProcessGoneSeesAZombie's doc comment opens with 'is the bug `ley daemon stop` used to report as "did not exit within 5 s"', narrating the historical failure mode by name instead of describing the current contract being tested.

Why it matters: A stranger reading this test needs to know what processGone is supposed to do; framing it as 'the bug X used to report' requires knowing the old, now-removed behavior.

Suggested fix: Rewrite as 'TestProcessGoneSeesAZombie covers a daemon whose parent shell has exited but is not yet reaped: kill(pid, 0) still finds it, so processGone must recognize the zombie state as gone.'


### c-go-tests-7 — Review finding number '#26 / #14' embedded in test doc comment

`go/internal/cli/session_test.go:77` · P3 · mechanical · confirmed

TestTuneDaemonClosesStreams's doc comment opens with '#26 / #14:', a review-report finding id that only the project's review docs explain.

Why it matters: A stranger has no way to resolve '#26 / #14' to anything; the rest of the sentence stands on its own and doesn't need the id.

Suggested fix: Drop the '#26 / #14:' prefix and keep the explanatory sentence.


### c-go-tests-8 — Review finding number '#15' embedded in test doc comment

`go/internal/cli/session_test.go:103` · P3 · mechanical · confirmed

TestTeardownKeepsSharedCapture's doc comment opens with '#15:', a bare review-finding id.

Why it matters: Same as the other '#N:' prefixes in this file: meaningless outside the review report.

Suggested fix: Drop the '#15:' prefix.


### c-go-tests-9 — Review finding number '#4' embedded in test doc comment

`go/internal/cli/session_test.go:133` · P3 · mechanical · confirmed

TestTuneSquelchRejected's doc comment opens with '#4:', a bare review-finding id.

Why it matters: Same issue as the file's other two '#N:' prefixes.

Suggested fix: Drop the '#4:' prefix.


### c-go-tests-10 — Review finding number '(CLI-4 #15)' embedded in inline comment

`go/internal/cli/set_fft_test.go:20` · P3 · mechanical · confirmed

Comment explaining WriteAwaitsWatcher cites '(CLI-4 #15 removes the race)', a plan-item id from docs/plans/archive/cli-review-fixes.md.

Why it matters: CLI-4/#15 is only resolvable by opening the plans doc; the mechanism it's explaining (WriteAwaitsWatcher blocking the write until WatchEvents registers) is already stated in the same sentence and doesn't need the id.

Suggested fix: Drop the parenthetical '(CLI-4 #15 removes the race)'.


### c-go-tests-11 — Doc comment narrates the meter sink's fixed bug ('is the fix for')

`go/internal/cli/meter_test.go:100` · P3 · mechanical · confirmed

TestMeterSinkRedrawIsTTYOnly's doc comment opens with 'is the fix for a redirected session collapsing into one line', framing the test as a fix for a historical bug rather than describing the invariant.

Why it matters: 'is the fix for X' presumes the reader knows X was ever broken; the invariant (off a terminal, whole lines, no carriage return) is stated right after and doesn't need the framing.

Suggested fix: Rewrite as 'TestMeterSinkRedrawIsTTYOnly checks that off a terminal the meter writes whole lines, throttled, and never a carriage return.'


### c-go-tests-12 — Review finding number '#22' embedded in test doc comment

`go/internal/cli/play_daemon_test.go:337` · P3 · mechanical · confirmed

TestDaemonStopWithoutPidfile's doc comment opens with '#22:'.

Why it matters: Bare finding id, unresolvable without the review report; the rest of the sentence is self-contained.

Suggested fix: Drop the '#22:' prefix.


### c-go-tests-13 — Review finding number '#20' embedded in test doc comment

`go/internal/cli/play_daemon_test.go:353` · P3 · mechanical · confirmed

TestDaemonStopPidReused's doc comment opens with '#20:'.

Why it matters: Same issue as the sibling comments in this file.

Suggested fix: Drop the '#20:' prefix.


### c-go-tests-14 — Review finding number '#21' embedded in test doc comment

`go/internal/cli/play_daemon_test.go:389` · P3 · mechanical · confirmed

TestDaemonStartChildExits's doc comment opens with '#21:'.

Why it matters: Same issue as the sibling comments in this file.

Suggested fix: Drop the '#21:' prefix.


### c-go-tests-15 — Review finding number '#12' embedded in test doc comment

`go/internal/cli/play_daemon_test.go:409` · P3 · mechanical · confirmed

TestDaemonStartPidfileUnwritable's doc comment opens with '#12:'.

Why it matters: Same issue as the sibling comments in this file.

Suggested fix: Drop the '#12:' prefix.


### c-go-tests-16 — Comment narrates the banner line it replaced, quoting the old text

`go/internal/cli/play_banner_test.go:20` · P3 · mechanical · confirmed

Comment explaining play's second banner line adds 'The line it replaced read "Radio FilePlaybackDevice, no gain control", which is a line spent saying nothing', quoting a since-removed line verbatim.

Why it matters: The replaced line no longer exists anywhere in the code, so this is pure history; a stranger reading the test cannot verify or use the quoted old text for anything.

Suggested fix: Drop the sentence about the replaced line; keep only the explanation of what the current line answers.


### c-go-tests-17 — Plan-item id 'VIS-2' embedded in test doc comment

`go/internal/cli/columns_test.go:58` · P3 · mechanical · confirmed

TestScreensSurviveColourOff's doc comment says 'the three screens of VIS-2', a plan-item id that is explained only in docs/plans/archive/cli-visuals.md.

Why it matters: 'VIS-2' is meaningless outside that plans doc; the three screens (devices, presets, bands) can just be named directly.

Suggested fix: Replace 'the three screens of VIS-2' with 'the devices, presets and bands screens' (or whatever the three screens actually are).


### c-go-tests-18 — Comment references an external bug report ('was the report this came from')

`go/internal/cli/target_test.go:9` · P3 · mechanical · confirmed

Comment for the target-parsing test ends '`ley spectrum noaa2` failing with a bare parse error was the report this came from', tying the test's existence to an unspecified external bug report.

Why it matters: 'was the report this came from' is meaningless without knowing what report; the concrete failure mode is already stated and stands on its own.

Suggested fix: Drop the trailing 'was the report this came from' clause.


### c-go-tests-19 — Comment frames a UI hazard as a 'reported symptom' (repeated in file)

`go/internal/cli/spectrum_watch_test.go:14` · P3 · mechanical · confirmed

Package-level comment and a second doc comment both describe the counted-frame-lines bug as 'A reported symptom' (line 14) / 'The reported symptom was' (line 123), narrating an external bug report rather than describing the invariant under test.

Why it matters: 'Reported symptom' presumes an incident a stranger cannot see; the underlying hazard (cursor-up redraw needing the writer's line count to match the screen) is already explained without it.

Suggested fix: Rewrite both as direct statements of the failure mode, e.g. 'When they disagree, two status lines can appear on screen counting different numbers of frames.'


### c-go-tests-20 — Comment narrates a prior papercut 'being fixed'

`go/internal/cli/bandlookup_test.go:46` · P3 · mechanical · confirmed

Comment says 'would be a worse papercut than the one being fixed', referring to an unnamed historical papercut this test addresses.

Why it matters: 'the one being fixed' has no antecedent for a reader who wasn't present for the fix; the design rule (band names beat frequencies only in `ley bands`) is already explained in the same sentence.

Suggested fix: Drop 'than the one being fixed' or replace with a concrete description of the alternative failure mode being avoided.


### c-go-tests-21 — Comment narrates a duplicated-default bug and its golden-file side effect

`go/internal/cli/helpink_test.go:102` · P3 · mechanical · confirmed

Comment reads 'The duplicated default is gone for good (it also changed tune.golden)', narrating a past fix and its incidental effect on an unrelated golden file.

Why it matters: 'gone for good' and the tune.golden aside describe a one-time change, not an invariant; a stranger gets no information about what TestHelpFlagInk currently checks.

Suggested fix: Rewrite as a statement of the current rule, e.g. 'A flag's default must not be printed twice.'


### c-go-tests-22 — Plan-item id 'FU-2' embedded in test doc comment

`go/internal/fakedaemon/writes_test.go:11` · P3 · mechanical · confirmed

TestStoredWritesWhileOutOfCapture's doc comment says it 'mirrors the daemon's FU-2 rule', an id defined only in docs/plans/archive/engine-review-fixes.md.

Why it matters: 'FU-2' resolves to nothing without that plans doc; the rule itself is stated in the same sentence and doesn't need the id.

Suggested fix: Drop 'FU-2' and keep the rule description.


### c-go-tests-24 — Comment narrates the test's own previous, wrong assertion

`go/internal/e2e/e2e_test.go:282` · P3 · mechanical · confirmed

Comment says 'The old form of this check looked at stdout and called what it found "the meter line", but that was the banner's squelch sentence', describing a bug in an earlier version of this very test.

Why it matters: This narrates the test file's own history rather than what the current assertion checks; a stranger gains nothing from knowing what a prior, already-replaced version of the check did wrong.

Suggested fix: Drop the two sentences narrating the old, wrong check; keep only 'A live session's prose is all on stderr, so stdout carries ids and nothing else.'


### c-go-tests-25 — Comment says persistent tune keeps 'the old behaviour' without saying old relative to what

`go/internal/cli/tune_test.go:34` · P3 · mechanical · confirmed

Comment reads 'Persistent runs leave squelch off (scripts get the old behaviour)', where 'old' has no referent for a reader unfamiliar with the feature's history (presumably an auto-squelch default added for interactive runs).

Why it matters: 'the old behaviour' is undefined in the comment itself; a stranger cannot tell what behavior is being contrasted with 'old'.

Suggested fix: State the contrast directly, e.g. '(persistent/script runs skip the auto-squelch default that interactive tune infers)'.


### c-go-tests-26 — Seven comments in spectrum_render_test.go narrate replaced designs and past bugs

`go/internal/cli/spectrum_render_test.go:83` · P3 · mechanical · confirmed

This file has more than five comments narrating prior implementations rather than describing current behavior: 'used to render byte-identically' (83-84), 'The running maximum this replaced ended up drawing the whole band as a wall' (173-176), 'The three-band Muted/plain/Ok inking this replaced collapsed to plain' (350-353), 'It used to reserve 30 dB above the noise line' (510-512), 'The scale... used to shrink to fit whatever the loudest column was' (528-533), 'Forcing every column to one colour was honest and unreadable' (591-595), and 'The chart used to paint every cell under a column... One column of noise may now leave one block' (716-719).

Why it matters: Each of these ties the current rendering rule to a rejected prior design instead of stating the rule; a stranger has to reverse-engineer the actual invariant (e.g. 'the scale must clear the peak with no fixed headroom' or 'a column of noise draws at most one block') out of a paragraph about what used to be wrong.

Suggested fix: Rewrite each to state the current rule as a standalone fact (what the render does and why), dropping the 'used to'/'this replaced'/'was' framing of the earlier design.

- verifier (comment, downgraded P3): Read all seven cited spots in full. Only 2 of 7 are genuinely narrative-only with no current-state statement (lines 83-84 'used to render byte-identically...' has zero restatement of current behavior; lines 716-719 explicitly contrasts old-vs-'now'). The other five (173-176, 350-353, 510-512, 528-533, 591-595) each open with a plain present-tense statement of the current invariant and only then explain, via contrast with a rejected design, why it's built that way -- exactly the 'explains why at …


### Refuted

- **c-go-tests-23** Comment narrates a fixed HTTP/2 ping regression in past tense (`go/internal/e2e/stream_test.go:12`) — Read the full comment (stream_test.go:12-16): after the 'Regression:' explanation it ends with 'The library dials with fixed 1 MiB windows, which disables those pings (docs/reference/cli.md, "Client requirements")' -- a direct, present-tense statement of current behavior with a doc citation. This is …


## Comment language: `EngineCore`

Coverage: Read in full (all lines): BlockingWork.swift, Buffers.swift, Rings.swift, Signposts.swift, Sinks/CallbackSink.swift, Sinks/NullSink.swift, Sinks/CoreAudioSink.swift, DSP/NCO.swift, DSP/FFT.swift, DSP/Kernels.swift, DSP/FIR.swift, DSP/Channelizer.swift, DSP/Demodulators.swift, DSP/EnergyDetector.swift, DSP/SubAudible.swift, DSP/SpectrumLadder.swift, DSP/SweepPlan.swift, DSP/Persistence.swift, Capture/CaptureDSPCore.swift, Capture/DefaultCaptureEngine.swift, Channels/ChannelDSPCore.swift, Channels/DefaultChannelEngine.swift, CoreProtocols.swift, Model.swift, Identifiers.swift, …


### c-swift-core-1 — CoreProtocols.swift header narrates the file's drafting history

`engine/Sources/EngineCore/CoreProtocols.swift:5` · P2 · mechanical · confirmed

The file banner says 'This file is the engine's contract. It was transcribed from the planning-phase signature sketch (docs/plans/archive/planning-phase.md §5) into compiling Swift', which narrates how the file came to exist rather than describing what it is.

Why it matters: A stranger reading this 'contract' file (the one review criteria single out as needing to read cleanly with no project history) gets pointed at a planning-todo doc section to understand a file that should stand on its own; the sentence would stop being true/meaningful if the planning history were erased, which is exactly the narrative-comment failure mode.

Suggested fix: Drop the 'transcribed from the planning-phase signature sketch' clause; keep the forward-looking pointers ('concrete model types live in Model.swift...', 'read docs/dev/engine-internals.md before implementing').


### c-swift-core-2 — Doc comment on subAudibleTap is actually describing audioSumSquares

`engine/Sources/EngineCore/Channels/ChannelDSPCore.swift:177` · P2 · mechanical · confirmed

The /// block above `subAudibleTap` opens with 'Audio energy accumulated since the last meter record, owned by the DSP thread alone. The sum is a Double because a 100 ms interval at 48 kHz is 4800 squares and Float would drift.' — that text describes the unrelated `audioSumSquares` field declared four lines later (line 185), which itself now has no doc comment of its own.

Why it matters: A reader of `subAudibleTap` (a FloatRing?) is told it's 'the sum' accumulated as a Double because of Float drift, which is nonsensical for a ring reference; the actual audio-energy accumulator sits undocumented below. This is the kind of doc mismatch that misleads whoever next touches either field.

Suggested fix: Move lines 177-178 down to sit directly above `audioSumSquares` (line 185); leave lines 179-180 as the doc comment for `subAudibleTap`.


### c-swift-core-4 — RTLSDRDevice and FilePlaybackDevice never reset their own sample index on restart, unlike RTLTCPDevice

`engine/Sources/EngineCore/Devices/RTLSDRDevice.swift:96` · P2 · scoped · confirmed

CaptureDSPCore.swift documents an assumed device contract: 'Devices restart their own index at 0 on every startStreaming; the capture timeline must not.' RTLTCPDevice actually implements this (a `generation` counter resets `index` to 0 in `readLoop` on every `startStreaming`), but `RTLSDRDevice.runningIndex` and `FilePlaybackDevice.runningIndex` are only ever initialized to 0 at declaration and are never reset in `startStreaming`/`beginStreaming` — they keep counting across repeated starts on the same device instance (e.g. the stop/restart `RTLSDRDevice.setSampleRate` performs on itself).

Why it matters: The capture-side rebase math in `CaptureDSPCore.deliver` happens to be robust to either behavior (it computes `indexBase` fresh from whatever the device reports), so this isn't currently an observed bug, but the documented contract is false for two of the three RadioDevice implementations in this file set, and a future change that assumes the documented invariant (e.g. a diagnostic that reads the device's own reported index as 'samples since this stream started') would silently get a running total instead.

Suggested fix: Reset `runningIndex = 0` at the top of `RTLSDRDevice.startStreaming` and `FilePlaybackDevice.startStreaming`/`beginStreaming`, matching RTLTCPDevice's generation-reset behavior, or reword the CaptureDSPCore comment to state that the rebase does not require it.


### c-swift-core-5 — PersistenceAccumulator.add holds an NSLock and does O(bins·levels) work inside a documented 'never block' hot path

`engine/Sources/EngineCore/DSP/Persistence.swift:51` · P2 · design · confirmed

`PersistenceAccumulator.add(row:)` is fed 'from the FFT ladder as an ordinary sink' — i.e. it runs as a `SpectrumSink.write` implementation on the DSP thread, whose protocol doc (CoreProtocols.swift) says 'Hot path (DSP thread): copy-or-consume, never block.' `add` takes a full `NSLock` around an O(bins) loop (plus an occasional O(bins·levels) halving pass), and the same lock guards `snapshot`/`rows`/`peek`-style readers that can run on other threads.

Why it matters: This is a literal violation of CLAUDE.md invariant 4 ('Hot path is allocation-free... no locks held across calls') applied to a call that the DSP thread makes once per spectrum row; if a subscriber ever calls `snapshot()` from another thread concurrently with `add()` (which the class's own doc anticipates: 'snapshot runs on whatever thread is serving a subscriber'), the DSP thread blocks on that lock for the duration of the snapshot's O(bins·levels) copy.

Suggested fix: Either document that PersistenceAccumulator is deliberately exempt from the hot-path no-lock rule because its only current caller (PersistenceFrameSink) invokes add/snapshot sequentially on the same thread, or make the counts array itself the copy-on-read structure (e.g. double-buffer) so add() never blocks on a concurrent reader.


### c-swift-core-6 — NullSink.swift header describes a 'forward audio' sink that isn't in this file

`engine/Sources/EngineCore/Sinks/NullSink.swift:1` · P3 · mechanical · confirmed

The file banner reads 'Sinks that discard or forward audio... both are allocation-free in `write`', but this file defines only `NullSink` (discard); there is no forwarding sink here, so 'both' has no second referent within the file.

Why it matters: A reader of just this file goes looking for the second ('forward') sink the comment promises and won't find it in this file (CallbackSink, the actual forwarding sink, lives in a separate file with its own banner).

Suggested fix: Reword to 'A sink that discards everything it receives... allocation-free in `write`' (singular), or drop the 'or forward audio' clause.


### c-swift-core-7 — Milestone-letter references in CoreProtocols.swift require the roadmap doc to parse

`engine/Sources/EngineCore/CoreProtocols.swift:393` · P3 · mechanical · confirmed

Four spots tag protocol sections with bare roadmap milestone letters — '(Milestone D.)' on Detector, 'MARK: - Jobs (Milestone D)', 'filled in with Milestone D' in JobContext, and 'MARK: - Store (Milestone C/D)' — which only make sense with docs/plans/build-order.md open alongside the file.

Why it matters: None of the four annotations explain anything about the protocol itself; they're pure roadmap bookkeeping embedded in code comments, which is exactly the 'references to milestones by letter/number that only the planning docs explain' pattern this review flags.

Suggested fix: Drop the milestone parentheticals (or move them to the doc comment above JobRunner/ResourceStore only if truly needed), since docs/plans/build-order.md already tracks what ships in which milestone.


### Refuted

- **c-swift-core-3** Most CoreProtocols.swift protocol members lack doc comments (`engine/Sources/EngineCore/CoreProtocols.swift:64`) — Checked the cited members (descriptor, open(), close(), id, deviceID, config, state, etc.) — these are self-evident from name plus the protocol-level doc comment above each, which is standard Swift practice, not accidental omission. The finding's own language ('reads as accidental omission rather …


## Comment language: `LeylineDaemon`

Coverage: Fully read every file in scope: engine/Sources/LeylineDaemon/{ClientContext.swift, DaemonCommand.swift, Server.swift, WriteCoalescer.swift, Bulk/{FrameRing.swift, StreamSources.swift, StreamRegistry.swift}, Jobs/{JobStore.swift, ScanRunner.swift, SessionCaptureAllocator.swift}, Mapping/ProtoMapping.swift, Services/{BulkService.swift, ControlService.swift, JobsService.swift, TelemetryService.swift}, Session/SessionStore.swift (all 917 lines, read in 6 sequential chunks)}, and engine/Sources/S2Throughput/{main.swift, SyntheticDevice.swift}. Every comment in every file was read (not just grep …


### c-swift-daemon-1 — Audio bulk-stream teardown drops the last produced samples; FFT/IQ/persistence don't

`engine/Sources/LeylineDaemon/Bulk/StreamRegistry.swift:341` · P2 · scoped · confirmed

In `StreamRegistry.run`, the `.fft`/`.iq`/`.persistence` branch does an extra `while let p = ring.pop() { ... }` drain after its `for await _ in ring.poke` loop ends, to catch any frame written concurrently with `finish()` whose poke wakeup got dropped (yields after `continuation.finish()` are no-ops). The `.audio` branch (lines 341-349) has no such post-loop drain: it only pops inside the `for await _ in audio.poke` loop.

Why it matters: `AudioFrameSource` uses the exact same `AsyncStream`+`finish()` pattern as `FrameRing`, and `close()` calls `channel.detach(...)` / `sink.closeSink()` then `audio.finish()` with no barrier guaranteeing the engine's audio callback (which runs on a different thread and calls `sink.push` + `pokeContinuation.yield`) has stopped. If a push+yield races with `finish()`, the yield is silently dropped and the reader never wakes to pop that final chunk of audio -- it sits in the `FloatRing` and is discarded when the subscription is torn down. On `Unsubscribe`, capture/channel teardown, or an audio-rate …

Suggested fix: Add a symmetric drain after the audio `for await` loop, mirroring the ring branch: `while let p = audio.next(s16: s16) { try await write(frame(payload: p.payload, start: p.sampleStart, count: p.sampleCount, dropped: p.droppedSamples)) }`.


### c-swift-daemon-2 — Client-facing error message leaks an internal milestone code

`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:126` · P2 · mechanical · confirmed

`startScan` rejects a recurring schedule with the literal message "a recurring scan needs a job store that survives a restart (Milestone D.15); use once", which is returned verbatim to every RPC caller (CLI, app, MCP agent) as the gRPC error detail.

Why it matters: "Milestone D.15" means nothing outside this project's internal planning docs; a stranger running `ley scan --recurring` sees a roadmap code in their terminal instead of a self-contained explanation. This is API-visible text, not just a source comment, so it should read the same to a user with zero context on the project's history.

Suggested fix: Drop the milestone reference from the message: e.g. "a recurring scan needs a job store that survives a restart, which does not exist yet; use once".


### c-swift-daemon-6 — Comment narrates a past bug instead of describing current behavior

`engine/Sources/LeylineDaemon/Jobs/ScanRunner.swift:343` · P2 · mechanical · confirmed

The doc comment on `near(_:_:_:)` has a second paragraph: "The tolerance was the *wider* bandwidth, which let a 198 kHz broadcast carrier swallow a neighbouring station 150 kHz away -- normal spacing outside the US -- and report one signal where there were two." This narrates a prior, now-fixed implementation rather than describing the code as it stands.

Why it matters: "was the wider bandwidth" only makes sense to someone who knows this code used to be different; a stranger reading it has no way to tell this is a historical note versus a currently-true fact, and the surrounding function actually uses the *narrower* bandwidth (`Swift.min(...)` at line 325), so the comment's second paragraph describes code that no longer exists.

Suggested fix: Remove or rewrite the second paragraph to state the invariant directly, e.g. "Using the wider bandwidth would let a wide broadcast carrier swallow a legitimately separate neighbouring station within normal international channel spacing; the narrower bandwidth avoids that." -- phrased as a design reason, not a history of what the code used to do.


### Refuted

- **c-swift-daemon-3** NARRATIVE comment cites internal milestone code (`engine/Sources/LeylineDaemon/Services/JobsService.swift:1`) — docs/plans/build-order.md is checked into this repo and CLAUDE.md explicitly directs every reader to "Follow docs/plans/build-order.md"; it defines Milestone D.13 and D.15 verbatim. The premise that a reader "has no way to resolve" the code is false for anyone reading this source (they have the whole repo). …

- **c-swift-daemon-4** NARRATIVE comment cites internal milestone code (`engine/Sources/LeylineDaemon/Jobs/SessionCaptureAllocator.swift:23`) — Same milestone (D.15), same in-repo doc (docs/plans/build-order.md) resolves it, same consistent convention as the other three occurrences in Jobs/. Not a defect.

- **c-swift-daemon-5** NARRATIVE comment cites internal milestone code (`engine/Sources/LeylineDaemon/Jobs/JobStore.swift:6`) — Same reasoning as c-swift-daemon-3/4: docs/plans/build-order.md is in-repo, required reading per CLAUDE.md, and defines D.15. Consistent house convention, not stale or opaque narrative.


## Comment language: engine tests

Coverage: Read every comment (line, block, and doc comments, plus XCTAssert message strings) in all 29 files under engine/Tests/EngineCoreTests/*.swift and engine/Tests/LeylineDaemonTests/*.swift (6895 lines total). No files skipped; no other directories touched.


### c-swift-tests-1 — Doc comment cites plan item WI-9 by id

`engine/Tests/EngineCoreTests/BlockingWorkTests.swift:5` · P3 · mechanical · confirmed

The type doc comment reads '`BlockingWork.run` (engine-review WI-9): blocking driver calls leave the cooperative pool.' — WI-9 is a review/plan item id that only means something with access to the (external) review docs.

Why it matters: A stranger reading this file with no access to the review history has no way to resolve 'WI-9'; the parenthetical adds nothing the surrounding sentence doesn't already say.

Suggested fix: Drop the '(engine-review WI-9)' parenthetical, keep the behavioral description.


### c-swift-tests-2 — Doc comment cites plan item WI-9 by id

`engine/Tests/EngineCoreTests/DevicesTests.swift:407` · P3 · mechanical · confirmed

Doc comment for testOpenWithoutHardwareThrowsDeviceIO parenthetically cites '(WI-9)', a plan-item id meaningless outside the review history.

Why it matters: Same as the BlockingWorkTests case: unresolvable reference for a reader without the planning docs.

Suggested fix: Drop '(WI-9)'.


### c-swift-tests-3 — Class doc comment cites review finding numbers and plan id

`engine/Tests/EngineCoreTests/DevicesTests.swift:447` · P3 · mechanical · confirmed

'/// Malformed-input hardening for the file pair (engine-review WI-4: #10, #24).' cites both a plan id (WI-4) and specific review finding numbers (#10, #24) that only make sense next to the (external) review record.

Why it matters: Finding numbers #10/#24 have no referent in this repo; a future reader can't look them up and the numbers add no information about what the tests actually check.

Suggested fix: Drop the '(engine-review WI-4: #10, #24)' parenthetical.


### c-swift-tests-4 — File header comment cites review plan id WI-4

`engine/Tests/LeylineDaemonTests/MalformedInputTests.swift:1` · P3 · mechanical · confirmed

File banner comment reads 'Malformed-input hardening across the gRPC surface (engine-review WI-4): extreme offsets, denormal spectrum rates, non-finite gains and non-regular files must be rejected cleanly, never crash or hang.' — 'engine-review WI-4' is an unresolvable plan-item reference.

Why it matters: Same class of issue: a stranger can't chase 'WI-4' anywhere in this repo.

Suggested fix: Drop '(engine-review WI-4)'.


### c-swift-tests-5 — Doc comment cites plan item id FU-3

`engine/Tests/LeylineDaemonTests/StreamCancelTests.swift:8` · P3 · mechanical · confirmed

Class doc comment opens with 'FU-3: a streaming RPC the client cancels ends its daemon-side handler...' where FU-3 is a plan/finding id with no referent in the repo.

Why it matters: A reader unfamiliar with the planning history cannot resolve 'FU-3'; the rest of the sentence already explains the behavior on its own.

Suggested fix: Drop the leading 'FU-3: ' tag.


### c-swift-tests-6 — Comment narrates a specific past incident instead of describing the test

`engine/Tests/EngineCoreTests/DSPKernelTests.swift:117` · P3 · mechanical · confirmed

Comment reads 'dbToPower and maxInPlace were added without being in this test, and a symbol that does not exist on Darwin got through as a result...' — this recounts a specific historical incident from the project's review history rather than describing what the code checks now.

Why it matters: The anecdote requires knowing the incident happened; it also risks going stale as soon as a different kernel triggers the same class of gap, since it's pinned to two named symbols from one past event rather than the general risk.

Suggested fix: Rewrite as a standing statement of the risk, e.g. 'A new kernel added here but not exercised above can reference a symbol that doesn't exist on Darwin without anyone noticing, since this container never compiles Accelerate; parity coverage is the only check for that.'


### c-swift-tests-7 — Comment narrates a near-miss bug instead of describing the test

`engine/Tests/EngineCoreTests/EnergyDetectorTests.swift:96` · P3 · mechanical · confirmed

'/// The bug that was nearly shipped: assuming a look count instead of measuring it.' recounts a specific averted incident rather than stating what the test verifies.

Why it matters: A reader with no knowledge of that near-miss gets no information from 'was nearly shipped'; the sentence only becomes meaningful with the (unavailable) project history.

Suggested fix: State the invariant directly, e.g. 'Fewer looks must measure a higher threshold; using an assumed look count instead of the actual one would get this backwards.'


### c-swift-tests-8 — Doc comment points to a nonexistent 'task notes' document

`engine/Tests/LeylineDaemonTests/DaemonTestHarness.swift:20` · P3 · mechanical · confirmed

'/// Path to a generated fixture (`leyfix generate` if absent — see the task notes).' references 'the task notes', which is not a file anywhere in this repo (checked: no task-notes/notes doc exists) — a dead 'see X' pointer.

Why it matters: A reader who goes looking for 'the task notes' to learn how fixtures are generated finds nothing in the repo; the actual generation command (`leyfix generate`) is already stated right there and is the only actionable part.

Suggested fix: Drop '— see the task notes'; the parenthetical already names the command to run.


### c-swift-tests-9 — XCTAssert failure messages use escaped backslash instead of string interpolation

`engine/Tests/EngineCoreTests/SubAudibleTests.swift:192` · P3 · mechanical · confirmed

Four XCTAssert messages in testSubAudibleTapPassesToneToDetector use `\\(...)` (a literal backslash followed by parens) instead of `\(...)` (string interpolation), so on failure they print the literal text '\(ring.available)' etc. instead of the actual value.

Why it matters: When one of these assertions actually fails, the diagnostic message is useless — it shows the unexpanded placeholder text instead of the measured value a maintainer needs to debug the failure.

Suggested fix: Replace `\\(` with `\(` at all four sites (lines 192, 205, 206, 213) so the values actually interpolate into the failure message.


## Comment language: the protos, Package.swift, Makefile, scripts, CI

Coverage: Fully read: proto/leyline/v1/common.proto, control.proto, jobs.proto, bulk.proto, telemetry.proto (all messages, enums, services, every comment); engine/Package.swift; Makefile; scripts/gen-proto.sh; scripts/bootstrap-mac.sh; .github/workflows/ci.yml; go/go.mod; engine/Sources/CRTLSDR/module.modulemap and shim.h. Cross-checked behavioral claims in proto comments against implementations in engine/Sources/LeylineDaemon, engine/Sources/EngineCore, go/internal/fakedaemon, go/internal/cli, go/internal/e2e, and engine/Sources/EngineCore/DSP/SpectrumLadder.swift where a comment made a checkable …
