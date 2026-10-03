# TomlBeef Status

The single source of truth for where the project stands and what is left to do. Design and rationale
live in [architecture.md](architecture.md). Keep this file current: when an item is finished, delete its
row (git history is the record), and update the baseline when test counts change.

Last reviewed: 2026-09-30. The [parser review](review.md) found B1–B11; their original examples are
addressed, with regression tests in `src/TomlBeef/tests/TomlRegressionTests.bf`. Review of the
actioned changes found resource-limit gaps B12/B13 and test-coverage follow-up O16, now fixed
(`MaxDepth` counts every container from the root; dotted keys check table room before their value;
`ReadBoth` compares the documents both reads produce). The architectural and performance follow-ups (O10–O15) are done
too: layout captured at the containers' own separators (no container text retained), nested
multi-line indentation, read-only `StringView` string payloads, shared key/value string decoding,
one insertion guard in the resolver, allocation-free path walking, `ReleaseCachedMemory`.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 327/327 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 327/327 pass |
| `bash ./test-leaks.sh` | PASS: no leaks detected |
| `./test-toml.sh` | 266 valid (semantic JSON match), 503 invalid rejected, exit 0 |
| `./test-roundtrip.sh` | 266 pass, 0 mismatch, 0 crash, exit 0 |
| `./test-encoder.sh` | 266 pass (fixture JSON → TOML → JSON), exit 0 |
| `./test-official-toml.sh` | Upstream toml-test v2.2.0 (requires Go). 1.0: 205 valid, 205 encoder, 474 invalid. 1.1: 214 valid, 214 encoder, 467 invalid. All pass |
| `bash ./test-codegen.sh` | 10/10 `[TomlObject]` build fixtures as expected (tests/codegen, with a second project depending on TomlBeef) |
| `bash ./win-test.sh` (Windows, Proton) | 327/327 in Test and TestRelease |
| FormatCore's `bash tools/sync.sh <TomlBeef> --check` (run in a FormatCore checkout) | PASS (vendored scripts and AGENTS.md's shared block match FormatCore) |
| `bash bench/instructions.sh` | The table below (instructions per byte; Release `TomlTester -bench-loop`) |

Instructions per byte, `bash bench/instructions.sh`, after the move onto FormatCore (before: `cd799f0`):

| Input | document | preserve | stream | stream1k | write |
|---|---|---|---|---|---|
| mixed | 84.01 → 78.17 | 138.03 → 130.98 | 118.68 → 90.06 | 118.85 → 90.56 | 41.06 → 41.05 |
| strings | 16.10 → 16.00 | 26.64 → 25.98 | 40.43 → 20.50 | 40.62 → 21.13 | 58.19 = |
| ints | 66.45 → 58.83 | 98.49 → 90.93 | 100.99 → 68.98 | 101.18 → 69.48 | 32.66 = |
| floats | 74.20 → 64.54 | 125.26 → 115.66 | 109.44 → 75.36 | 109.63 → 75.79 | 37.53 → 37.31 |
| dates | 62.42 → 56.55 | 96.21 → 90.39 | 92.55 → 64.06 | 92.80 → 64.52 | 46.86 = |
| arrays | 179.22 → 133.77 | 369.33 → 324.78 | 247.25 → 149.12 | 247.38 → 149.59 | 57.72 = |
| headers | 123.74 → 117.12 | 168.26 → 161.85 | 166.87 → 132.64 | 167.08 → 133.09 | 48.84 → 48.83 |
| dotted | 132.48 → 123.84 | 184.66 → 176.01 | 174.97 → 135.48 | 175.16 → 135.95 | 58.05 = |
| comments | 6.16 → 5.61 | 9.92 → 8.80 | 30.69 → 9.88 | 30.84 → 10.43 | 0 |
| commented | 17.47 → 15.01 | 35.50 → 32.48 | 43.57 → 19.76 | 43.72 → 20.30 | 4.89 = |

Any change to `.bf` files must keep these green **in both Debug and Release**: run `beefbuild -test`
and `beefbuild -test -config=TestRelease`, and run the shell scripts against both binaries
(`beefbuild` then the scripts; `beefbuild -config=Release` then the scripts with
`BIN=./build/Release_Linux64/TomlTester/TomlTester`). `beefbuild -test` does not rebuild the
`TomlTester` binary the scripts use, so always run `beefbuild` first.

## Feature status

| Area | State |
|------|-------|
| TOML 1.0 and 1.1 parsing | Complete; full valid/invalid corpus passes for both versions |
| Encoding | `TomlTester -from-json` builds documents from toml-test tagged JSON through the public API; passes the upstream encoder suite for both versions |
| Input paths | `Read(StringView)`, `ReadBytes`, `Read(Stream)`, `ReadFile`, all decoding identically |
| Read modes | `Replace` and deep `Merge` (`Error`/`Skip`/`Overwrite` on conflicting leaves), transactional on failure; PreserveStyle metadata is kept and carried across merges |
| Ownership model | Document-owned arena; non-owning `TomlValue`; `Set`/`Add` (taking `TomlInputValue`) and typed getters are the public API |
| Public surface | Metadata sidecar, parser, cursors, path resolver and table origin/sealing (`TomlTableOrigin`, `Origin`, `IsInlineSealed`) are `internal`. Metadata is reached only through `doc.PreservesStyle`, `doc.HasSourcePositions` and the comment/style/source-range methods, with `TomlMetadataMode`, `TomlStringStyle`, `TomlIntegerBase` and `TomlSourceRange` as the public types |
| Path access | Dotted and bracketed-segment paths for getters and setters; `GetPath` takes exact keys (including the empty key) |
| Resource limits | All `TomlReadConfig` limits enforced on every input path (`MaxTokenBytes` is stream-only by design), each checked before the work it bounds: strings stop growing, arrays and tables (dotted paths included) take no further value, key paths no further segment. `MaxDepth` counts every container from the root (header segments, both levels of an array of tables, dotted-key tables, arrays, inline tables), so the recursive tree walks stay within the stack |
| Writer | Canonical output; TOML 1.0 downgrade; `PreserveStyle` round-trip of comments, token text, numeric/date/array/inline-table formats, blank lines; public API to edit comments (keys, headers, array elements), string style, integer base, float notation, date-time style, array and inline-table layout, and key quoting, and to query source positions (also available alone through the cheaper `Positions` mode) |
| Error reporting | Source name, line, column, and byte offset for lexical, UTF-8, semantic and merge errors; `TomlParseError` needs no cleanup (message in a per-thread buffer), works with `Try!`, and formats as `source:line:column: message` |
| Validation | `Require*` getters (MissingKey/WrongType) and `MakeError` (InvalidValue) on documents, tables and arrays, located in the source with Positions/PreserveStyle; positions keep their source file across merges |
| Serialization | `[TomlObject]` generates `TomlRead`/`TomlWrite` at compile time (architecture.md 8a): scalars, String, enums, date/times, nested objects and `List<T>`, plus any type with an `ITomlConverter<T>` (registered at compile time with `[TomlConverter]`, or per field with `[TomlUseConverter]`); key naming policies, `[TomlName]`/`[TomlIgnore]`/`[TomlRequired]`; located, range-checked errors. Document first: `doc.Deserialize(path, obj)` / `doc.Serialize(path, obj)` (and on tables) bind sections while the rest of the document is used by hand, and writing updates in place (unchanged PreserveStyle documents round-trip byte for byte). Optional allocator for stack-scoped object graphs. In the README (Serializing Types) with the typed benchmark (`docs/benchmark-typed.svg`) |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

### Correctness bugs

None known. Add rows here (ID `B<n>`, problem, where, size) as bugs are found. (B1–B13 from the
[review](review.md) are fixed. Fixed in the move onto FormatCore (2026-10-03), with regression tests:
the slow-path float parse followed the current culture's decimal separator (FormatCore B2,
`FloatsIgnoreTheCurrentCulture`); the table index was unseeded (B3, `TableIndexesAreSeededPerTable`);
converters registered in the user's project vanished once a second project depended on TomlBeef (B1,
tests/codegen `OkRegisteredConverter`).)

### Streaming and I/O

| ID | Gap | Size |
|----|-----|------|
| I3 | *Deferred (2026-09-27).* No streaming writer: `WriteFile` builds the whole output `String` first. A `Write(Stream)` that also builds a full string adds nothing, so this is only worth doing as a real chunked output sink (every writer helper takes an output object instead of `String`; tail checks read a kept tail). Revisit if large outputs matter | M–L |

### Optional / nice to have

| ID | Idea | Size |
|----|------|------|
| O8 | *Optional, perf.* In the 20-library comparison (`bench/compare/`, architecture.md "TomlTester") only Rust's toml-spanner parses faster: 1.09× on average, ahead on 6 of 10 inputs, most on small arrays (1.8×), headers and the mixed config (1.4×) (2026-09-29, after the float/date/array fast paths, `TomlEntryMap` tables and arena pool reuse, which took it down from 1.48×). TomlBeef is the fastest style-preserving parser. Lookups (~70 ns) still trail zig-toml (~45) and go-toml (~55): a lookup goes `TomlTable` → entry array → index, where fingerprint bytes or keeping the index inline in the table might save a miss. From the toml-spanner study: resolve header and dotted-key segments as they are read with one find-or-add per segment (today a missing segment hashes twice), copy each string once straight into the store, smaller values (`TomlValue` is ~40 bytes because date/times are 8 × `int32`). Remaining ideas by profile: word-at-a-time scanning in the stream cursor (it still counts columns per byte), comment runs stored as source ranges in PreserveStyle (the `toml_edit` approach), multi-line strings through `ScanRun`, keeping parse errors out of `Result` payloads (return size matters: `int32` positions gave +20% on arrays) | M–L |
| O9 | *Serialization follow-ups.* `[TomlObject]` covers the common field types (architecture.md 8a) and is documented in the README. Still open: `Nullable<T>` (absent = null, not written when null), nested lists, sized arrays, full dotted paths in error messages (`server.db.port`, not `port`), a decision on whether unknown keys can be reported (a strict mode), and whether writing should skip fields whose keys were absent when read (today it adds them with the field's value; skipping needs per-object "seen" tracking or an omit-defaults option). Speed: typed reads trail glaze and toml-spanner (34–40 ms vs 16–21 on `typed.sh`); ~11 ms is binding, and an arena only saves ~6%, so profile the per-field lookups and `TomlBind` calls next (removing `Lookup`'s second search for present keys made no measurable difference, 2026-09-30). Possibly a direct text writer later if writing through `TomlTable` shows up in profiles | M |

## Suggested order

The remaining items are optional; take them as needed.
