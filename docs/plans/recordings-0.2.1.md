# Recordings and transcripts for 0.2.1

What 0.2.1 changes about recordings, and why. `docs/design/recording.md` is the contract; this plan
lists the changes to it and the work, with `[ ]` items still open. Written 2026-10-23.

## What was wrong

- **A stored transcription drops overs.** `go/pkg/plugin/segmented.go` queues eight segments for
  the decoder and drops the oldest when the queue is full. On a live channel that keeps the newest
  over. On a stored recording the daemon writes every over at once, so a recording of more than
  nine overs loses most of them: the 19-part recording of 2026-10-19 on 144.750 MHz was
  transcribed twice, and both runs logged `dropped segment 2` to `11` and returned 9 records. The
  drop went to an info line only, so the Library showed a transcript with holes and no warning.
- **"Part" means three things.** The app's record button gates with a 500 ms hang, so its parts
  are one over each. `ley record --gate squelch` and a live speech job's clips hang 5 s, so their
  parts are exchanges of several overs. The Library shows one row per part, and its inspector a
  file and an overs count. A person cannot predict what a row, a file or a transcript line is.
- **`ley record` writes dead air.** Without `--gate` it records the `.audio` tap continuously,
  and 85% of a repeater recording is the zeros of a closed squelch (recording.md, "Not
  implemented"). The app's gated recordings do not have this problem: the 2026-10-19 recording
  wrote 365 s for 346 s of open squelch.
- **Recordings from before the "Nothing heard" rule stay.** Directories with zero parts, made
  before the runner discarded them, are listed by nothing and removed by nothing.

## The decisions

- **One file is one transmission.** The default hang is 500 ms everywhere: the app, `ley record
  --gate squelch`, the MCP `record` tool and a live speech job's clips. An exchange (several overs
  close together) is something a client works out from the gaps between parts; the store does not
  decide it. `--hang` still sets a longer one.
- **The files stay separate.** One WAV per transmission, not one WAV per recording with a time
  map: a crash repairs one header, `ley play` and Finder read a part as they do now, a live job
  drops its oldest parts, and time is never edited (recording.md).
- **People see transmissions, not files.** The Library lists a recording's transmissions with
  their transcript lines; "part" leaves the app's words. Show in Finder moves to a context menu;
  Export writes one WAV with the silence removed, or a file per transmission.
- **A stored transcription is lossless.** A plugin reading a stored recording waits for its
  decoder instead of dropping, and the pipe holds the daemon back. Any over still not transcribed
  (an engine error) is counted in the job's `status_detail`, and the app offers to transcribe the
  overs that have no record.
- **`ley record` gates by default when it can.** NFM and AM recordings with a squelch set are
  gated; `--gate none` records continuously. WFM, IQ and squelch off stay continuous.
- **Not in 0.2.1:** writing IQ in the device's native format (recording.md, "Not implemented") is
  the largest saving on disk and is 0.2.2.

## Work

- [x] R1. Lossless stored transcription: the daemon tells a SEGMENTED plugin its source is a
  stored recording, the plugin SDK blocks instead of dropping, `status_detail` counts overs not
  transcribed, a test with more than eight overs and a slow scripted engine.
- [ ] R2. The 500 ms hang everywhere, with the help goldens, the `record-squelch-opens` eval and
  recording.md's "a part is an exchange".
- [ ] R3. The Library lists transmissions: rows, transcript lines, Transcribe missing, Export,
  Show in Finder in the context menu. Check scenes and goldens re-recorded and named.
- [ ] R4. `ley record` gates NFM and AM by default; the daemon's start sweep removes recording
  directories with no parts whose job is not running.
- [ ] R5. CHANGELOG, recording.md and the guide pages brought up to date; one full `make
  app-check JOBS=3`.
