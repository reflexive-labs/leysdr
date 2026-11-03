# Shared decoder display vectors

These files pin the client-side logic that `ley` (Go) and the Mac app (Swift) both
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

## `column-cases.json`

`{cases}`, each `{name, column, record, value, valid}`: fold `record` into an empty table and print
`column`, one entry of a display's `columns`, for its row. An entry is `name` or `name:N` and prints
as the template `{name}` or `{name:N}` would. `value` is the printed cell, or `null` when the row
has not sent the name or the entry is malformed. `valid` is whether the entry parses (a name, then
optionally one colon and a precision from 0 to 6); a client's display check rejects an invalid
entry, and its cell never resolves. A column is headed by the entry's name with the precision
dropped.

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
- `columns` maps each of the display's `columns` entries, as written (`sog_kn:1`), that resolves
  for the row to its printed value; a column the row has not sent is absent.

## `watch-cases.json`

`{cases}`, each `{name, where, county, near, radius, predicate, error}`, every key but `name`
optional: the filter flags of `ley watch` (`--where` and `--county` repeated, `--near` and
`--radius` as typed) and the `Predicate` they make, in the proto3 JSON mapping, or `null` for no
filter; `error: true` marks input both clients refuse, whatever the words. `buildPredicate` in
`go/internal/cli/watch.go` and `Watches.predicate` in the app read the same file
(`watch_vectors_test.go`, `WatchesTests`), so a watch made in the app's Notify Me… sheet filters as
one made with `ley watch`. Pick radii whose metres are exact in binary (`2mi`, not `3mi`), since
the predicates are compared exactly.
