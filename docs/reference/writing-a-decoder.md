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
`rssi_dbfs`, `snr_db`, `record_id`, `job_id`, `seq` or `channel_id` — the daemon overwrites them,
because only it has those values. You set the fields the protocol carries.

## The manifest

A decoder is a directory holding `manifest.json`, the proto3 JSON form of `DecoderManifest`, and the
program it names. The daemon reads the file and executes nothing while discovering, so a broken
binary still lists in `ley decoders` and a manifest that will not parse costs one log line, not a
crash. The daemon looks in every directory named by `--decoders` (repeatable) and `LEYLINE_DECODERS`
(colon-separated), then the platform default
(`~/Library/Application Support/Leyline/decoders` on macOS,
`$XDG_DATA_HOME/leyline/decoders` elsewhere), then `decoders/` beside the `leylined` executable;
the first directory to define a name wins.

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
    {"name": "comment", "type": "TEXT", "description": "the free text the station sent"},
    {"name": "temp_c", "type": "NUMBER", "unit": "degC", "description": "air temperature"}
  ],
  "executable": "leydec-aprs"
}
```

- **`recipe`** is the tuning your decoder needs, and it is what makes `ley decode aprs` need no
  arguments. `frequenciesHz` lists the protocol's frequencies; the first is the default and
  `ley decode <name> --freq` picks another or overrides it. `mode`, `bandwidthHz` and `gain`
  (`GAIN_LEAVE` keeps whatever a borrowed capture is set to; `GAIN_AUTO` asks for AGC on one the job
  creates) describe the channel. The daemon chooses the sample rate; leave it 0.
- **`input.tap`** is which stage of the channel you read. `TAP_AUDIO` is what a listener hears, after
  de-emphasis and the limiter; `TAP_DEMOD` is the discriminator before any of that, which a data
  decoder usually wants because de-emphasis tilts the tones a modem keys on. `input.mode` is
  `CONTINUOUS` for a stream; `SLOT_ALIGNED` (for slot-timed protocols like FT8) is declared here but
  not yet delivered by the daemon.
- **`outputs`** declares what shapes you produce. Every decoder produces `SHAPE_RECORDS`;
  `SHAPE_ENTITIES` says a client can fold your records into a per-transmitter table (`ley track`),
  and `entitySilenceS` is how long a station stays in that table after its last record.
- **`fields`** are advisory hints — a name, a type, a unit — that let `ley` and an agent display and
  query your open fields sensibly. They are hints only: a field you emit that is not listed still
  passes through untouched.
- **`executable`** is the program, resolved against the manifest's own directory first and `PATH`
  second, with `args` passed to it.

## The wire

Your program reads stdin and writes stdout; both carry length-delimited protobuf, the standard
"delimited" convention (a varint length, then that many bytes of message). Stderr is yours for
logging — the daemon captures it under `leyline.decoder.<name>`.

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

The daemon's write to you is non-blocking. A decoder that stops reading has its audio dropped and
gapped, not queued, so keep up with the stream or expect gaps.

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
file matches the code) and otherwise runs the read-decode-emit loop over stdin and stdout. The
bundled `leydec-aprs` (`go/cmd/leydec-aprs`, with the AFSK, AX.25 and APRS stages in
`go/pkg/decoders`) is the worked example; the fake decoder in the engine tests
(`engine/Sources/FakeDecoder`) is the smallest one, a single record per frame.

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
