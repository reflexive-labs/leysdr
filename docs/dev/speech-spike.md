# The speech-to-text spike

How to measure a speech engine on real receiver audio, so that the choice of default engine rests
on numbers from this radio rather than on a provider's benchmark. The tool is `leyspeech`
(`go/cmd/leyspeech`): it transcribes a gated recording with a named speech decoder through `ley
transcribe`, scores the text against a hand transcript, and reports what the provider counted and
how long it took. The result goes into a new decision record, `S4-speech-to-text.md` in
`docs/decisions/`, in the format of the others (see [S2 throughput](../decisions/S2-throughput.md)).
The plan behind it is [`docs/plans/ai-features.md`](../plans/ai-features.md); speech as a decoder
is [`docs/design/ai.md`](../design/ai.md).

Four numbers per engine:

| number | what it is | where it comes from |
|---|---|---|
| word error rate | substitutions, deletions and insertions over the words in the hand transcript, after normalising both sides | `leyspeech run` against `transcript.txt` |
| callsign recall | the callsigns spoken that the engine wrote, each counted once per over | the same run |
| cost per hour of squelch-open audio | what the provider counted for the job (audio seconds, tokens or requests, in its own units), scaled to one hour of the time the squelch was open | the daemon's usage ledger, the line for the job |
| seconds from squelch close to text | for each over, the time from the squelch closing to the record arriving | `leyspeech live` on the air |

Any decoder that `ley decoders` lists with `SEGMENTED` input can be measured: the bundled `speech`
decoder (OpenAI's transcription API, `whisper-1` unless `--model` says otherwise), any other
decoder that calls a provider or runs on the Mac, and `speech-scripted`, the keyless test engine
that replays a script and is how the tool itself is tested. A decoder that calls a provider needs
its key in the daemon (`ley ai add <provider>`; `openai` for `speech`) and takes a model with
`--model`.

## Recording the corpus

Three sources, each a gated audio recording made on the Mac with the radio:

```sh
ley record 146.94 --gate squelch --for 60m      # a 2 m net: replace with your net's frequency and time
ley record noaa --gate squelch --for 3m         # NOAA Weather Radio
ley record 118.85 --mode am --gate squelch --for 3m   # an airband ATIS: replace with your airport's
```

Set the gain you know works for each source with `--gain`: an RTL-SDR at auto gain can overload on
a strong local signal, and an overloaded recording measures the radio, not the engine.

A net is many short overs from different stations, which is what the word error rate and the
latency are about. Weather radio and ATIS transmit without a break, so the squelch opens once and
the whole recording is one over; keep them to a few minutes, because a speech plugin drops a
segment longer than ten minutes (`plugin.MaxSegment`), and a cloud API may refuse a long request
before that. `ley recordings`
lists what was made; each recording is a job id (`job_01…`).

## Writing the hand transcript

`leyspeech ref` prints a template with one line per over, cut as the speech decoder cuts them
(half a second before the squelch opens to half a second after it closes, so two openings closer
together than that are one over), each under a comment saying when it was heard and for how long:

```sh
leyspeech ref job_01J... > "$(ley recordings path job_01J...)/transcript.txt"
ley play job_01J... --part 1 --over 3     # listen to one over while you write it down
```

The format is one line per over: `part/over`, a tab, and the words as spoken.

- Write a callsign as it was said or as written: `whiskey six alpha bravo charlie` and `W6ABC`
  score the same, because both sides are normalised before they are compared. A portable or
  mobile suffix folds away (`W6ABC/P` and `whiskey six alpha bravo charlie slash papa` are both
  `W6ABC`), so a suffix is never scored; `slash portable` spelled as a word is not folded.
- Put a comma between two callsigns said back to back. Without one, the spelled words run
  together into one token that is no callsign, so it is scored as the words written and counts
  as no callsign on either side. An engine that writes two callsigns with nothing between them
  is scored the same way, which is what a reader of its text would face.
- Write numbers as digits where you expect an engine to (`146.94`, `PL 100`). Outside a callsign,
  `six` and `6` are different words.
- Leave the text empty for an over in which nobody said anything you can make out (a kerchunk).
  Any word an engine writes there is an insertion.
- Leave `?` on an over you have not transcribed. It is left out of the score, with every record
  and transcribed line whose audio overlaps it: an engine with a longer hang may hear a `?` over
  and the next one as one segment, and that whole stretch is left out. The notes under the table
  count what was left out.
- Case and punctuation never count.

`leyspeech run` reads `transcript.txt` beside `recording.json`, or the file `--ref` names. The
daemon's retention removes the whole recording directory when it ages out, so keep a copy of the
transcript elsewhere as well.

## Running the comparison

On the Mac, against the running daemon:

```sh
make go
leyspeech run --recording job_01J... --engine speech
leyspeech run --recording job_01J... --engine speech --model gpt-4o-transcribe
make speech-spike RECORDING=job_01J... ENGINES="speech=whisper-1 speech=gpt-4o-transcribe"
```

`make speech-spike` runs `leyspeech compare` once over every engine in `ENGINES` (a decoder, or
`decoder=model`), against the same transcript, and prints one row each; `SPIKE_ARGS="--json"`
prints them as JSON. Each run is a `ley transcribe --yes` job of its own, so it sends the
recording's squelch-open audio to wherever that decoder sends it, and a cloud engine bills for
it. Each run also stays in the owner's daemon: a kept job, its records (`ley records --protocol
speech --job-id <job>`) and its ledger lines in `ley ai usage`. `--daemon` (below) leaves nothing
there. `--model` makes `ley transcribe` choose the model for later jobs too; `leyspeech` puts the
previous choice back after each run, or clears it when there was none. Ctrl-C interrupts `ley
transcribe`, which cancels its job and keeps the records it made.

The scripted engine, `speech-scripted`, is how the tool itself is tested. Its output, from the
end-to-end test against the real daemon with one wrong word in the transcript:

```
ENGINE           MODEL     OVERS  WER   S/D/I  CALLSIGNS  OPEN     REQUESTS  BILLED     PER OPEN HOUR  SPEED
speech-scripted  scripted  4/4    8.3%  1/0/0  4/4        0.1 min  4         9 s audio  6769 s audio   40.3x real time

speech-scripted scripted, the overs with errors:
  1/1  S1 D0 I0
    ref: whiskey six alpha bravo charlie checking out
    hyp: whiskey six alpha bravo charlie checking in
```

The columns:

- **OVERS** is the records scored against the transcript lines scored.
- **WER** and **S/D/I** are summed over the whole recording: total errors over total reference
  words. The table does not show the reference word count; `--json` does, as `ref_words` in the
  score's `counts`, per over and in total. An over with no record counts all its words as
  deletions; a record for an over the transcript does not list counts all its words as
  insertions. When an engine cuts a part differently from the transcript (a decoder whose manifest
  sets a longer hang joins two openings the template lists apart), the overs that share audio are
  scored as one stretch, named `1/1+2`.
- **CALLSIGNS** is the callsigns found against the callsigns spoken, by the pattern in
  `go/pkg/callsign` applied to both sides: a pattern match, not a decoded identity. It counts from
  the reference only: each callsign in a transcript line is found or not in the engine's text for
  the same over. A callsign the engine wrote that nobody said does not lower it; its words are
  insertions in the WER.
- **OPEN** is the minutes the squelch was open, which is what the cost per hour is counted against.
  The audio sent is a little longer, because each over carries its pre-roll and hang.
- **BILLED** is the job's ledger line in the provider's unit: audio seconds, else tokens, else
  requests. The line is read by the job's id, taken from its records, or from `ListJobs` (the new
  job reading this recording) when the job made no record, so an engine that heard nothing still
  shows what it was billed. **PER OPEN HOUR** is the same scaled to one hour of squelch-open audio. Leyline shows
  no prices; the provider's price sheet turns these into money.
- **SPEED** is seconds of squelch-open audio transcribed per second of wall clock, for a stored
  recording. It is throughput, not latency.

Below the table, every over with an error is printed with both texts, so a high word error rate
can be read rather than guessed at. `leyspeech run --daemon` starts a hermetic `leylined` on a copy
of the recording instead of using the running daemon (with a provider key in `$LEYSPEECH_KEY`,
passed to `ley ai add` on stdin); the owner's daemon and recordings are not touched.

## Measuring latency

Latency is the live number, so it is measured on the air, on the 2 m net:

```sh
leyspeech live --freq 146.94 --engine speech --model whisper-1 --seconds 1800
```

`live` runs `ley decode <decoder> --freq F --job --json` for `--seconds`, stamps each record as it
arrives, then cancels the job and reads, from the recording the job kept of its overs, when each
over's squelch closed. It reports the delay per over with its median, 90th percentile and maximum.

It runs on the owner's daemon and takes the radio as `ley decode` does: it tunes an idle radio or
a capture that already covers the frequency, and refuses, as `ley decode` refuses, when somebody
else is using the radio (it never passes `--take-over`). With `--model` the speech model is
switched for the whole `--seconds` window, so any other speech job started meanwhile uses it too,
and put back afterwards. The job is cancelled on every way out: at the end of the window, when
`ley decode` fails, and on Ctrl-C.
The close is on the capture's clock, through the anchor, and the arrival is on the Mac's clock, so
the two agree because the daemon and `leyspeech` run on the same machine. Every delay includes the
decoder's hang (half a second unless its manifest says otherwise), because the daemon ends a
segment only that long after the squelch closes; the table's cell and a note under it say so
(`0.6 s median (0.5 s hang), 0.6 s p90`). The end-to-end test measures 0.60 to 0.62 s with the
scripted engine, which answers at once: the hang plus about a tenth of a second of plumbing. A
record whose over the recording's sidecars do not hold cannot be given a delay; the note under the
table counts such records, and `--json` gives the count as `unplaced`.

The job's records and its recording are kept, so `leyspeech ref` and `leyspeech run --recording
<job>` can score the same overs afterwards.

## What goes into the decision record

`S4-speech-to-text.md` in `docs/decisions/`, in the shape of the other decision records:

```markdown
# S4: <the default speech engine, and why>

Status: decided <date> and current. <One sentence on anything the measurement did not cover.>

## Decision

**<Engine and model> is the default speech engine.** <The deciding numbers, in a sentence each:
word error rate on the net, callsign recall, cost per hour of squelch-open audio, and the median
delay from squelch close to text.> <What the runner-up is better at, and when a user would choose
it.>

## What was measured

<Mac model, macOS version, radio and antenna, date.> The corpus: <each recording: source,
frequency, mode, gain, minutes of squelch-open audio, overs, words in the hand transcript>.

`make speech-spike RECORDING=<id> ENGINES="<...>"` for each recording, and `leyspeech live
--freq <net> --seconds <n>` per engine for the delay.

| engine | model | WER (S/D/I) | callsigns | per open hour | delay median / p90 | speed |
|---|---|---|---|---|---|---|
| <decoder> | <model> | <x.x% (s/d/i)> | <found/spoken> | <provider units> | <s / s> | <x real time> |

<One table per source if they differ in kind: the net, weather radio, ATIS.>

## Where the engines fail

<The overs with errors that tell the engines apart, quoted from the run: callsigns, numbers,
clipped first words, weak signals, two stations doubling.>

## The vocabulary hint

<Whether a prompt or vocabulary hint (the phonetic alphabet, callsigns from the bookmarks) changed
the numbers, measured as two rows of the same engine.>

## Not measured

<What would change the decision: another Mac, another band, a longer net, a provider's newer model.>
```
