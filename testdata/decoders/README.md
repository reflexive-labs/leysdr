# Shared decoder display vectors

These files pin two pieces of client-side logic that `ley` (Go) and the Mac app (Swift) both
implement: the display template language of a manifest's `DecoderDisplay`
(`docs/reference/writing-a-decoder.md`, "Display") and the entity fold that `ley track` and the
app's transmitter table build from records. `go/pkg/records/vectors_test.go` reads them; a Swift
test reads the same files, so the two clients print the same line for the same record.

The JSON is plain, not the proto3 JSON mapping, so `Codable` structs with `snake_case` keys read
it with no protobuf library. Every key below is present unless marked optional. A display whose
name matches a directory under `decoders/` must equal that manifest's `display` block; the Go test
fails when they drift.

## Shared shapes

- **display**: `{title, symbol, summaries, entity_name, columns}`. `summaries` is an object from
  record kind to template; `columns` is an array of field names. All optional. The vectors spell
  the key `entity_name` in snake_case; a `manifest.json` spells it `entityName`, the proto3 JSON
  name. A template's backslashes are doubled in the JSON, as in any JSON string.
- **record**: `{protocol, kind, device_id, position, rssi_dbfs, snr_db, fields, raw}`, all optional.
  `position` is `{latitude, longitude, altitude_m}` with `altitude_m` optional. An absent
  `rssi_dbfs` or `snr_db` means NaN, a level the daemon did not measure. `raw` is the payload as a
  UTF-8 string.
- **field value**: an object with exactly one key, which the Go test checks: `text` (string),
  `integer` (a JSON integer that fits in 64 bits), `number` (a JSON number), `flag` (boolean) or
  `data` (a hex string).
- **non-finite numbers**: a `number`, a coordinate or a level that is NaN or infinite is written as
  the string `"NaN"`, `"Infinity"` or `"-Infinity"`. A Swift `JSONDecoder` reads them with
  `nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "Infinity",
  negativeInfinity: "-Infinity", nan: "NaN")`.

## `summary-cases.json`

`{displays, cases}`. `displays` maps a display name to a display; `rules` and `default` exist only
to exercise the language. Each case is `{name, display, record, label, summary, fallback}`:
render `record` with `displays[display]` and the optional `label` (the user's name for the
transmitter, empty when absent) and expect `summary`. `fallback` (optional, false when absent)
marks a case no template renders: `summary` is then the client's own line, `records.Summary` in
Go, and a client that does not port that line checks only that its template did not render.

The rules the cases pin, beside the proto comment on `DecoderDisplay`:

- A NUMBER is `String(format: "%.Nf", value)` (Go: `strconv.FormatFloat(v, 'f', N, 64)`) with
  trailing zeros and a bare point dropped and `-0` printed as `0`. N is 2, or the `{name:N}`
  precision. Both round the double itself, so 2.675 prints `2.67`, and neither ever prints an
  exponent: 1e21 is `1000000000000000000000`.
- A TEXT value has every control character (C0, DEL and C1, `\n` and `\t` among them) replaced by
  one space before it is substituted.
- The finished line is trimmed of Unicode whitespace: Go's `strings.TrimSpace`, Swift's
  `trimmingCharacters(in: .whitespacesAndNewlines)`. A no-break space counts.
- A position whose latitude or longitude is NaN or infinite is unresolved, and a coordinate that
  rounds to zero at four decimals takes N or E.

## `fold-*.json`

`{name, decoder, display, entity_silence_s, steps, rows}`. `decoder` names the manifest the display
is copied from. Start an empty table whose clock reads `at_s` seconds after an arbitrary epoch at
each step, then for each step in order: apply `record` when it is present, and expire entities
silent for longer than `entity_silence_s` when `expire` is true. A record with no `device_id`
makes no row.

`rows` is the table afterwards, newest first and ties broken by `device_id`, each
`{device_id, protocol, name, kind, summary, count, first_heard_s, last_heard_s, position, fields,
columns}`:

- `name` is the display's `entity_name` rendered over the row, or `device_id` when that is empty or
  does not render.
- `kind` and `summary` come from the newest record, the summary through the display.
- `first_heard_s` and `last_heard_s` are the table's clock when the row's first and newest records
  arrived.
- `position` is the newest position (or `null`), and `fields` the newest value of every field the
  transmitter has sent.
- `columns` maps each of the display's `columns` that resolves for the row to its printed value; a
  column the row has not sent is absent.
