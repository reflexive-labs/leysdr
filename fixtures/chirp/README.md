# CHIRP import fixture

`sample.csv` is a CHIRP CSV export (the header CHIRP 20240801 writes) with one row per mapping rule in `docs/design/channels.md`, "CHIRP import": a repeater with `Tone`, a simplex row, `TSQL`, `DTCS`, `Cross`, a blank name on a plan channel, a blank name off any plan, a frequency that is not a number, a mode Leyline does not decode, and a repeat of the first row.
`expected.json` is the bookmarks file after one import of it into an empty store, tagged `sample`, normalised: entries ordered as the store lists them (frequency ascending, then name), the n-th counting from 1 re-keyed `bm_<n>`, and every `updated_ns` set to 0.
Both parsers are held to these two files: `go/pkg/chirp` (`chirp_test.go`, `normalise`) and `LeylineClient/CHIRP.swift` (`CHIRPTests.swift`) import `sample.csv`, normalise the result the same way, and compare it with `expected.json` as decoded JSON values, so whitespace and key order do not matter.
Both files are written by hand, not generated: a change to the mapping changes the design first, then this file, then both parsers.
