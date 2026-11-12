# Writing a decoder

A decoder turns a channel's demodulated audio into typed records: APRS packets into positions and
weather, ADS-B frames into aircraft, a weather-radio burst into an alert. The daemon runs each one
as a separate program and never links it, so a decoder is written and shipped on its own, in any
language, under any licence. This page is what an author needs before the first record; the contract
it describes is [`decode.proto`](../../proto/leyline/v1/decode.proto), and the reasons behind it are
in the [decoder design](../design/decoders.md). A decoder is not a general client: it never opens the
socket, never tunes, and never sees the control plane. It reads samples on stdin and writes records
on stdout.

## What the daemon does, and what you do

The daemon owns the radio. When a decode job starts, it creates the capture and the channel your
recipe asks for, spawns your program, and streams the channel's demodulated audio to it. You decode
the audio and emit records. The daemon stamps each record with the levels it measured and the ids it
owns, stores it if the job asked to keep records, and hands it to every client watching. A crash in
your program is logged as a gap and restarted; it never takes the daemon down.

So the division is fixed: **the daemon measures the signal, you interpret it.** You never set
`rssi_dbfs`, `snr_db`, `record_id`, `job_id`, `seq`, `channel_id`, `clip_uri` or `over` — the daemon overwrites them,
because only it has those values. You set the fields the protocol carries.

## The manifest

A decoder is a directory holding `manifest.json`, the proto3 JSON form of `DecoderManifest`, and the
program it names. The daemon reads the file and executes nothing while discovering, so a broken
binary still lists in `ley decoders` and a manifest that will not parse costs one log line, not a
crash. The daemon looks in every directory named by `--decoders` (repeatable) and `LEYLINE_DECODERS`
(colon-separated), then the platform default
(`~/Library/Application Support/Leyline/decoders` on macOS,
`$XDG_DATA_HOME/leyline/decoders` elsewhere), then `../Resources/decoders` relative to the
`leylined` executable (an app bundle's own decoders); the first directory to define a name wins. A
bare `executable` name resolves in the plugin's directory, then beside `leylined`, then on `PATH`.

The manifest for the bundled APRS decoder, trimmed to the fields that carry meaning:

```json
{
  "name": "aprs",
  "version": "0.1.0",
  "description": "APRS over AX.25, Bell 202 AFSK at 1200 baud on 2 m",
  "license": "Apache-2.0",
  "recipe": {
    "frequenciesHz": ["144390000", "144800000"],
    "bandwidthHz": 15000,
    "mode": "NFM",
    "gain": "GAIN_LEAVE"
  },
  "input": { "mode": "CONTINUOUS", "tap": "TAP_AUDIO" },
  "outputs": ["SHAPE_RECORDS", "SHAPE_ENTITIES"],
  "entitySilenceS": 1800,
  "fields": [
    {"name": "comment", "label": "Comment", "type": "TEXT", "description": "the free text the station sent"},
    {"name": "temp_c", "label": "Temperature", "type": "NUMBER", "unit": "degC", "description": "air temperature"}
  ],
  "display": {
    "title": "APRS",
    "symbol": "antenna.radiowaves.left.and.right",
    "summaries": {
      "status": "{comment}",
      "weather": "[{temp_c:1} °C][ wind {wind_kmh:0} km/h][ @ {wind_dir_deg:0}°]"
    },
    "columns": ["symbol", "path"],
    "positions": true
  },
  "executable": "leydec-aprs"
}
```

- **`recipe`** is the tuning your decoder needs, and it is what makes `ley decode aprs` need no
  arguments. `frequenciesHz` lists the protocol's frequencies; the first is the default and
  `ley decode <name> --freq` picks another or overrides it. `mode`, `bandwidthHz` and `gain`
  (`GAIN_LEAVE` keeps whatever a borrowed capture is set to; `GAIN_AUTO` asks for AGC on one the job
  creates; `GAIN_FIXED` sets `gainDb` on the radio's first stage) describe the channel. A fixed
  gain goes only on a capture the job creates or retunes, and a retuned one gets its own gain back
  when the job ends; a capture the job shares keeps its owner's gain, and the job's status says the
  gain it was left at. `ley decode --gain` overrides the recipe. Fix the gain when the protocol
  needs one the radio's default does not give: ADS-B's recipe is 40 dB because at 30 an RTL-SDR
  heard nothing on 1090 MHz. The daemon chooses the sample rate; leave it 0.
- **`input.tap`** is which stage of the channel you read. `TAP_AUDIO` is what a listener hears, after
  de-emphasis and the limiter; `TAP_DEMOD` is the discriminator before any of that, which a data
  decoder usually wants because de-emphasis tilts the tones a modem keys on. `input.mode` is
  `CONTINUOUS` for a stream, or `SEGMENTED` for one over at a time, cut at the squelch (below), which
  is what a speech decoder wants; `preRollMs` and `hangMs` set how much audio a segment keeps before
  the squelch opened and after it closed, 500 ms each when left 0. `SLOT_ALIGNED` (for slot-timed
  protocols like FT8) is declared here but not yet delivered by the daemon.
- **`credentialProvider`** names the provider whose key your decoder calls with (`deepgram`,
  `openai`), and **`contactsHosts`** lists the hosts it sends data to. With a provider named, the
  daemon refuses to start the job until a key is set (`CREDENTIAL_MISSING`, whose message names
  `ley ai add <provider>`) and hands the key to your program when it starts it (below, "The key").
  When the user has chosen a speech model on that provider (`ley ai use speech <provider>
  <model>`), the daemon adds `--model <model>` after your `args`. `contactsHosts` is advisory and
  nothing enforces it; `ley transcribe` states it before it sends anything, so a person can see
  where the audio goes, and `ley decoders --json` carries it. Leave both empty when your decoder
  calls nobody.
- **`testOnly`** marks a decoder that exists for tests, such as `speech-scripted`, which replays a
  script, or `iqstat`, which checks the IQ path. The daemon leaves it out of `ListDecoders` (so out
  of `ley decoders` and the app) unless it runs with `--no-hardware`, as tests, evals and check
  scenes do; a job can still name it.
- **`outputs`** declares what shapes you produce. Every decoder produces `SHAPE_RECORDS`;
  `SHAPE_ENTITIES` says a client can fold your records into a per-transmitter table (`ley track`),
  and `entitySilenceS` is how long a station stays in that table after its last record.
- **`fields`** are advisory hints — a name, a type, a unit — that let `ley` and an agent display and
  query your open fields sensibly. They are hints only: a field you emit that is not listed still
  passes through untouched. A hint's `label` is the short name a person reads, in sentence case
  and without the unit ("Ground speed", "County"): `ley track` heads a column with it and `ley
  watch` writes its filter with it, and a field with no label goes by its name.
- **`display`** says how clients show your decoder and its records: the next section.
- **`executable`** is the program, resolved against the manifest's own directory first and `PATH`
  second, with `args` passed to it.

## Display

The manifest's `display` block is how `ley` and the Mac app show your decoder, so a new decoder
needs no client change to be shown. Every part is optional, and a client given no display prints
its own line per record and names each transmitter by its `device_id`.

- **`title`** is the decoder's name in the app and in the TITLE column of `ley decoders`:
  "Vessels" rather than `ais`.
- **`symbol`** is an [SF Symbol](https://developer.apple.com/sf-symbols/) name the app draws beside
  the title, such as `airplane` or `ferry`.
- **`summaries`** maps a record `kind` to the template for its one-line summary, which `ley decode`,
  `ley records`, `ley track`'s LAST column and the app all print. The key `""` applies to every kind
  without a template of its own.
- **`entityName`** is a template for a transmitter's name, rendered over the newest value of every
  field it has sent: AIS uses `{name}`, so a vessel keeps the name from its static report while its
  position reports arrive. `ley track` shows it in a NAME column. Leave it empty when `device_id` is
  the name, as an APRS callsign is.
- **`columns`** lists fields shown as columns of the transmitter table (`ley track`), in order of
  importance: a narrow terminal drops the last first. A column is headed by its field's label, and a
  field with a unit in `fields` has the unit after it, so `ground_speed_kn` labelled "Ground
  speed" in `kn` is `GROUND SPEED (kn)`; a field with no label is headed by its name, the unit
  suffix dropped, so `sog_kn` is `SOG (kn)`. An entry may carry a precision as a template name
  does, `ground_speed_kn:0`, so the table prints whole knots as the summary does; the header drops
  it. `testdata/decoders/column-cases.json` pins the cells and `head-cases.json` the headers.
- **`positions`** says your records carry positions, so the app's page has a Map tab from the
  start, disabled with "No positions yet" until a record has one, instead of gaining the tab a
  moment after it opens. Leave it out and the tab appears with the first position.

A template is text with names in braces:

- `{name}` is one of the promoted names `device_id`, `kind`, `position`, `altitude_m`, `rssi_dbfs`,
  `snr_db` and `label` (the user's own name for the transmitter), or else a field of the record. A
  promoted name wins over a field of the same name.
- `{name:N}`, N from 0 to 6, prints a number with up to N decimals: `{altitude_m:0}` prints
  `124`, `{a1:3}` keeps `0.001`. Without it a number keeps up to two.
- `[ ... ]` is an optional group, printed only when every name inside it resolved. Groups do not
  nest.
- A backslash escapes `{`, `}`, `[`, `]` and itself: `[ \{{msg_id}\}]` prints the id in braces.
  In `manifest.json` the backslash is itself escaped, so that template is written
  `"[ \\{{msg_id}\\}]"`. A backslash before any other character makes the template
  malformed.

A value prints by its type. TEXT prints as sent, with every control character (a newline, a tab,
any C0 or C1 control) replaced by one space so a value cannot break the line. INTEGER prints in
decimal. NUMBER prints as `printf("%.Nf")` would, then drops trailing zeros and a bare point, and
never prints `-0`: `21`, `21.5`, `21.46`. FLAG prints the field's own name when true, DATA prints
as lower-case hex, and `position` prints as `37.7600N 122.4200W`, where a coordinate that rounds to
zero takes N or E. The unit is not appended, so the template writes it: `[{temp_c:1} °C]`. A name is
unresolved when the record lacks it, its text is empty, its number is NaN or infinite (a level the
daemon did not measure, or either coordinate of a position) or its flag is false.

The finished line is trimmed of leading and trailing whitespace, a no-break space included. The
client prints its own line instead of the template's when a name outside a group is unresolved,
when the line is empty, or when the template is malformed (an unclosed brace or group, a nested
group, a lone `}` or `]`, a precision outside 0 to 6, a stray backslash). So
`{position}[ {speed_kmh:0} km/h]` on a record with no position falls back rather than printing half
a line. A test in `go/pkg/records` parses every template under `decoders/`, so a malformed one in a
bundled manifest fails CI. The cases in `testdata/decoders/summary-cases.json` are the full
specification: every client that renders templates passes them.

## The wire

Your program reads stdin and writes stdout; both carry length-delimited protobuf, the standard
"delimited" convention (a varint length, then that many bytes of message). Stderr is yours for
logging — the daemon captures it under `leyline.decoder.<name>`.

0. **If your manifest names a `credentialProvider`, read one `SetCredentialRequest` before
   anything else.** It carries `provider`, `secret` (the key) and `endpoint` (empty for the
   provider's own API). The daemon reads the key as it stands each time it starts you, restarts
   included. Keep it in memory only: never write it to stderr, a file or a record. The daemon
   replaces it in your stderr before logging, but a record goes where the user sends it.
1. **Read one `StreamDescriptor` first.** It names the audio `sample_rate` and `format` (`F32` mono
   in this build), the `tap` you are served, and, in `center_hz` and `span_hz`, the channel's
   frequency and the capture's sample rate. A demodulator's filters depend on the audio rate, so
   build them from this, not from a guess.
2. **Then read `Frame`s.** Each carries a block of samples in `payload` and the `SampleTime` of its
   first sample. When delivery dropped audio before a frame, the frame's `gap` names the missing
   sample range — reset any partial state (a half-assembled packet, a bit clock) when you see one,
   because the samples on either side are not continuous.
3. **Write a `DecodeRecord` for each thing decoded.** Fill the promoted fields your protocol has —
   `protocol`, `device_id`, `position`, `validity`, `kind`, `fields`, and always `raw`, the payload
   bytes you decoded, so a better decoder can reprocess it later — and stamp `time` from the frame
   the packet finished in. Leave the daemon's fields unset.
4. **Stdin closing is how a job stops.** Read until EOF and exit 0; it is not an error.
5. **Exit 75 when your provider refuses.** A decoder that calls a paid service and is turned away
   for the provider's own reason, such as a rate or spend limit, writes the provider's message as
   its last line on stderr and exits with status 75 (`EX_TEMPFAIL`). A kept job waits and starts
   the decoder again on the restart backoff; any other job ends with `PROVIDER_REFUSED` and that
   message.
6. **Exit 3 when you cannot decode your input.** A decoder that reads in the descriptor that it
   cannot work on what it is given (a capture centred too far from its band, a rate too slow for
   its signal) writes why as its last line on stderr, in a sentence a person reads ("the capture is
   centred on 1090.600 MHz, too far from 1090.000 MHz for a reply to fit in it"), and exits with
   status 3. The job ends `FAILED` with `FAILED_PRECONDITION` and that sentence as its detail, kept
   or not, and the decoder is not started again: a restart would read the same descriptor. Do not
   read on and decode nothing; a job that says RUNNING and never answers looks like a quiet band.

Any other exit while stdin is open is a crash, and the daemon restarts the decoder. On a stored
recording it gives up after the fourth exit in a row that answered nothing new (see "Reading a
stored recording").

### The key

When the manifest names a `credentialProvider`, the daemon writes one varint-delimited
`SetCredentialRequest` (`provider`, `secret`, `endpoint`) to stdin before the `StreamDescriptor`,
every time it starts your program. It goes by the installed manifest, not one built into your
program, and sets `LEYLINE_KEY_ON_STDIN=1` in your environment exactly when it sends the key, so
read the key when that variable is `1` (the Go SDK does). Pass the secret to the provider's API and nowhere else: not to
stderr, a record, a file or a child process's environment. The daemon replaces the key in the last
stderr line of a decoder that exits 75, but no other output is scrubbed. Report what each call
used in the record's `usage` (a `UsageReport`: `provider`, `model`, `requests`, and the provider's
own units, `audio_seconds` for speech); the daemon fills in `feature` and `job_id` and adds it to
the ledger `ley ai usage` prints.

The daemon's write to you is non-blocking. A decoder that stops reading has its audio dropped and
gapped, not queued, so keep up with the stream or expect gaps. The stall rule is per frame: a
frame the pipe has taken part of must finish within 2 s or the daemon replaces your program. No
frame carries more than 4096 samples, so a decoder that does slow work, such as a call to a
provider, keeps reading stdin while it works.

### Segmented input

Under `input.mode = SEGMENTED` you get one over at a time, never the audio between overs:

- **The first frame of a segment** carries `segment = SEGMENT_START` and audio. Its `time` is the
  segment's first sample, `preRollMs` before the squelch opened (or the start of the recording
  part, or the end of the segment before, whichever is later). Stamp the record for the segment
  with this `time`: it is how the daemon matches the record to its over, allowing up to 1 ms early.
  The pre-roll may span several frames; only the first is marked.
- **The frames after it** carry audio and no mark. A `gap` on one of them is audio inside the
  segment that was lost.
- **One last frame** carries `segment = SEGMENT_END`, no payload, and the `time` of the sample after
  the segment's last, `hangMs` after the squelch closed. Decode the segment when it arrives.
- **A squelch that reopens inside the hang** continues the same segment, so a segment can hold more
  than one opening when they are closer together than `hangMs`.
- **Segments never overlap.** Every START you are given is followed by its END before the next
  START. A segment the daemon could not start delivering is skipped whole, and the next START
  carries a `gap` covering it. Stdin closing inside a segment is the job stopping; the segment is
  incomplete.

The daemon fills `clip_uri` and `over` on your records: `clip_uri` is the recording part that
holds the segment's audio, and `over` the index of the segment's first opening in that part's
`squelch_opens`. On a live job the recording is the one the daemon writes of the channel under the
job's id, so a record from a live job and one from transcribing that recording later name the same
part and over.

### Reading a stored recording

A decode job can read a recording instead of a radio (`ley://recordings/<id>` as
`DecodeConfig.source_uri`). Nothing changes for you: the descriptor is `AUDIO`, `F32` mono at the
recording's rate, and the frames come as fast as you read them rather than at the speed of the air,
with segments cut by the same rule. When the recording has all gone your stdin closes: write the
records you still owe and exit 0, and the job ends once you have. You have 30 s, plus 2 s for each
segment you have not answered yet; after that the daemon stops you and the job fails. If you die
part way, you are started again at the first segment you had not answered, so answer each segment
with at least one record (an empty `text` will do) or expect it again. A decoder that exits four
times in a row without answering anything new fails the job with `DECODER_FAILED`, naming its
last exit status and its last line on stderr; a live job is restarted however often it exits.

Stamping `time` precisely means turning a sample offset within a frame into a `SampleTime` on the
capture's timeline, which runs at `span_hz` while your audio runs at `sample_rate`. The Go SDK's
`SampleTimeAt(frameTime, offsetSamples, audioRate, captureRate)` does the arithmetic; in another
language it is `frame.time.sample_index + round(offset * captureRate / audioRate)`.

## The Go SDK

A decoder in Go writes one type and a few lines of wiring; `go/pkg/plugin` does the framing, the
sample conversion and the manifest handling. Implement `Decoder`:

```go
type Decoder interface {
    Feed(samples []float32, at *leylinev1.SampleTime, gap *leylinev1.Gap, emit func(*leylinev1.DecodeRecord))
}
```

`Feed` is called once per frame with the block's samples, the time of its first sample, the `gap`
before it (nil when none), and an `emit` callback for each record the block completes. A decoder that
needs the capture rate for `SampleTimeAt` also implements the optional `Start(*StreamDescriptor)`.
`main` is then:

```go
func main() {
    plugin.Main(manifest, func(audioRateHz uint32) plugin.Decoder {
        return newMyDecoder(audioRateHz)
    })
}
```

`plugin.Main` handles `--manifest` (it prints the manifest and exits, which is how a build checks the
file matches the code) and otherwise runs the read-decode-emit loop over stdin and stdout.

A decoder that cannot decode what the descriptor names calls `plugin.RefuseInput` with the
sentence, from its factory, from `Start`, or from `Feed` or `FeedIQ`:

```go
func (d *decoder) Start(desc *leylinev1.StreamDescriptor) {
    if off := int64(desc.GetCenterHz()) - 1_090_000_000; off > 200_000 || off < -200_000 {
        plugin.RefuseInput("the capture is centred on %.3f MHz, too far from 1090.000 MHz", float64(desc.GetCenterHz())/1e6)
    }
}
```

It does not return. `RunStreams` and its siblings return a `*plugin.InputRefusedError` carrying the
sentence, which is what a test checks, and `Main`, `MainIQ` and `MainSegmented` write it as the last
line on stderr and exit `plugin.InputRefusedExit` (3). A `SegmentDecoder`'s `Segment` runs on
another goroutine and must not call it. `leydec-adsb` is the worked example.

A decoder with `SEGMENTED` input implements `SegmentDecoder` instead and calls `plugin.MainSegmented`:

```go
type SegmentDecoder interface {
    Segment(samples []float32, at *leylinev1.SampleTime, emit func(*leylinev1.DecodeRecord))
}

func main() {
    plugin.MainSegmented(manifest, func(audioRateHz uint32, key *leylinev1.SetCredentialRequest) plugin.SegmentDecoder {
        return newMyDecoder(audioRateHz, key)
    })
}
```

`Segment` is called once per segment with all of its audio, a gap inside it filled with silence,
and `at` is the START frame's time; the buffer is the decoder's to keep. The SDK reads stdin on one
goroutine and calls `Segment` on another, in order and one at a time, with up to eight complete
segments waiting. On a live channel, when a slow engine lets more pile up, the oldest waiting one
is dropped with a line on stderr (`dropped segment N: the engine is behind`). When the source is a
stored recording (`StreamDescriptor.stored`, set by the daemon), nothing is dropped: the SDK stops
reading stdin until the decoder takes a segment, and the pipe holds the daemon back. At the end of
input it waits for every queued segment and writes its records before it returns. `MainSegmented` reads the key first when `LEYLINE_KEY_ON_STDIN` is `1` or its own manifest
names a provider (`plugin.ReadCredential` does the read for a decoder that wires stdin itself)
and passes it to the factory; `key` is nil when no key was sent. `Main` and `MainIQ` read it the
same way and drop it. A segment longer than `plugin.MaxSegment` (ten minutes), a segment cut
off by the end of input, and audio outside a segment are logged on stderr and dropped. The
bundled `leydec-aprs` (`go/cmd/leydec-aprs`, with the AFSK, AX.25 and APRS stages in
`go/pkg/decoders`) is the worked example; the fake decoder in the engine tests
(`engine/Sources/FakeDecoder`) is the smallest one, a single record per frame.

## Speech decoders

A speech decoder emits one record per segment with `protocol` the manifest's `name` (`speech` for
the bundled one; leave it empty and the daemon fills it in, which a program that serves more than
one manifest must do), `time` at the START frame, and these `fields`:

| field | type | holds |
|---|---|---|
| `text` | text | what the engine heard, as it wrote it |
| `language` | text | the language transcribed, an ISO 639-1 code |
| `model` | text | the model that produced the text |
| `confidence` | number | the engine's own confidence, 0 to 1; absent when the engine reports none |
| `callsigns` | text | callsigns in the text, upper case and comma-separated, empty when none |

`raw` holds the provider's response bytes as they arrived, and `usage` what the call used. The
`callsigns` field is a pattern match over the text, and its field hint says so: `go/pkg/callsign`
folds the phonetic alphabet, spoken digits and spelled letters into compact runs ("whiskey six
alpha bravo charlie" is `W6ABC`), ends a run at a comma, a semicolon or the end of a sentence, and
matches the amateur callsign pattern on each run: a prefix of one or two letters or of a digit and
a letter, one digit, and a suffix of one to three letters, with `/P` and `/M` dropped. A one-letter
prefix must be one the ITU issues alone (B, F, G, K, M, N, R, W; I is left out because a lone
capital I is the pronoun), and with one a one-letter suffix counts only when it was spelled out
phonetically, so `B2B` and `C3PO` are not callsigns. A four-letter suffix such as `N0CALL` is not
matched.

The bundled `leydec-speech` (`go/cmd/leydec-speech`) is the worked example, and one program with two
manifests: `decoders/speech/` runs it with `--engine openai` and names `openai` as its
`credentialProvider` and `api.openai.com` in `contactsHosts`, and `decoders/speech-scripted/` runs
it with `--engine scripted` and names neither. `leydec-speech --manifest` prints the first, and
with `--engine scripted` the second, because the built-in manifest's `credentialProvider` decides
whether the SDK waits for a key. `--model` is the model asked for and recorded on each record, and
`--language` (default `en`; empty lets the engine detect it) is the language asked for. The
engines:

- **`openai`** sends each over to an OpenAI-compatible transcription endpoint,
  `POST {base}/v1/audio/transcriptions`, on the key the daemon hands over. The base is
  `https://api.openai.com`, or the endpoint the key was added with (`ley ai add openai --endpoint
  URL`), which is how a gateway or a local Whisper server is reached; a trailing `/` or `/v1` on it
  is ignored, it must be `https` unless it is this machine, it may carry no user name, password or
  query string, and a redirect is refused rather than followed, so the key reaches no other host.
  A message names the endpoint's host only, never the whole URL. The request is a multipart form:
  `file`, the segment as a 16-bit mono WAV at the descriptor's rate; `model` (default `whisper-1`);
  `response_format` `verbose_json`; `language`; and `prompt`, the vocabulary hint (below). The
  record's `text` is the response's, trimmed; `language` is the language the response names, as
  its code; `confidence` is 1 less the mean of the response segments' `no_speech_prob`, absent
  when none reports one; `raw` is the response body; and `usage` names the key's provider,
  `openai`, whatever its endpoint, so the ledger line and the key's last use line up with the
  credential, with the model, one request and the segment's length in `audio_seconds`. A model
  that answers only plain `json` (`gpt-4o-transcribe` and its kin) is asked again in it, and its
  records have no confidence. Each call has 60 s plus one second per 256 KB uploaded, at most 5
  minutes, so a long over on a slow uplink is not taken for a provider that stopped answering.
  OpenAI takes at most 25 MB in one call, about 4.5 minutes of WAV at 48 kHz, and a longer over is
  logged and not sent. How a call that fails ends:

  | the provider answers | the plugin |
  |---|---|
  | 401 or 403 | exits 1: the key was rejected, and the last stderr line says to run `ley ai check openai` |
  | 429, a 5xx, a 400 about credit or billing, or nothing (offline, a timeout) | exits 75 with the provider's words as the last stderr line |
  | a redirect or a 404 | exits 1: the endpoint is not a transcription API |
  | any other 4xx (audio too short, say) | logs it; that over has no record, and the next is sent |

  The key goes in the `Authorization` header and nowhere else, and is cut out of any provider
  message before it is logged.

  A rejected key is not a refusal the daemon waits out. On a live job it shows in the job's status
  as "the decoder exited (status 1); restarting in …", again on every restart, until the key is
  replaced with `ley ai add openai`; `ley ai check openai` shows why the provider turned it away.
  A job on a stored recording fails with `DECODER_FAILED` after four such exits.

  The vocabulary hint is sent to the provider with the audio, as the `prompt` field, so it is
  never somewhere to put what should stay on the Mac. It starts with the phonetic alphabet,
  spelled the way `go/pkg/callsign` reads it, and the words of a net ("net control", "check-in",
  "go ahead", "73"), which steer a model towards writing a spoken callsign as the words the pattern
  folds back. `--hint <text>`, which a manifest's `args` can carry, adds words after those: a
  club's callsigns, a repeater's name. `LEYDEC_SPEECH_HINT` in the daemon's environment takes the
  place of `--hint` when it is set, so a measurement can vary the hint without reinstalling the
  manifest. Whisper reads only the last 224 tokens of a prompt, so keep the addition short.
- **`scripted`** ignores the audio and returns the lines of the file `LEYDEC_SPEECH_SCRIPT` names,
  one per segment, repeating the last line when they run out and returning `segment N` with no
  file. It calls no provider, and it exists so that a test of the whole path knows the words in
  advance.

## Wrapping an existing tool

A mature C decoder — `rtl_433`, `dump1090`, `direwolf` — becomes a decoder by writing a thin adapter
that speaks this wire on one side and drives the tool on the other: feed it the audio or IQ samples
it expects, parse its native output, and emit records. The adapter is the decoder;
the tool is an implementation detail of it. The out-of-process contract exists partly so a decoder
under a licence the engine could not link, or of uncertain provenance, stays the author's choice and
not the project's.

## What a decoder may not do

- **Decode only what is in the clear.** No decryption of protected traffic.
- **No patent-encumbered voice.** The digital-voice vocoders (AMBE and its kin) are out of scope;
  the unencrypted metadata in those same protocols may be decoded. The
  [decoder design](../design/decoders.md), "Constraints and boundaries", is the full statement.
- **Never touch the radio.** A decoder receives samples and emits records. Retuning, sink
  management and everything on the control plane belong to the daemon.
