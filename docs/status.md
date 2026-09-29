# TomlBeef Status

The single source of truth for where the project stands and what is left to do. Design and rationale
live in [architecture.md](architecture.md). Keep this file current: when an item is finished, delete its
row (git history is the record), and update the baseline when test counts change.

Last reviewed: 2026-09-27.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 301/301 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 301/301 pass |
| `./test-leaks.sh` | 301/301 under LeakSanitizer, no leaks, exit 0 |
| `./test-toml.sh` | 266 valid (semantic JSON match), 503 invalid rejected, exit 0 |
| `./test-roundtrip.sh` | 266 pass, 0 mismatch, 0 crash, exit 0 |
| `./test-encoder.sh` | 266 pass (fixture JSON → TOML → JSON), exit 0 |
| `./test-official-toml.sh` | Upstream toml-test v2.2.0 (requires Go). 1.0: 205 valid, 205 encoder, 474 invalid. 1.1: 214 valid, 214 encoder, 467 invalid. All pass |

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
| Path access | Dotted and bracketed-segment paths for getters and setters |
| Resource limits | All `TomlReadConfig` limits enforced on every input path (`MaxTokenBytes` is stream-only by design: only streams retain spans); documented in README |
| Writer | Canonical output; TOML 1.0 downgrade; `PreserveStyle` round-trip of comments, token text, numeric/date/array/inline-table formats, blank lines; public API to edit comments (keys, headers, array elements), string style, integer base, float notation, date-time style, array and inline-table layout, and key quoting, and to query source positions (also available alone through the cheaper `Positions` mode) |
| Error reporting | Source name, line, column, and byte offset for lexical, UTF-8, semantic and merge errors; `TomlParseError` needs no cleanup (message in a per-thread buffer), works with `Try!`, and formats as `source:line:column: message` |
| Validation | `Require*` getters (MissingKey/WrongType) and `MakeError` (InvalidValue) on documents, tables and arrays, located in the source with Positions/PreserveStyle; positions keep their source file across merges |
| Serialization (prototype) | `[TomlObject]` generates `TomlRead`/`TomlWrite` at compile time (architecture.md 8a): scalars, String, enums, date/times, nested objects and `List<T>`, plus any type with an `ITomlConverter<T>` (registered at compile time with `[TomlConverter]`, or per field with `[TomlUseConverter]`); key naming policies, `[TomlName]`/`[TomlIgnore]`/`[TomlRequired]`; located, range-checked errors. Document first: `doc.Deserialize(path, obj)` / `doc.Serialize(path, obj)` (and on tables) bind sections while the rest of the document is used by hand, and writing updates in place (unchanged PreserveStyle documents round-trip byte for byte). Not public in the README yet |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

### Correctness bugs

None known. Add rows here (ID `B<n>`, problem, where, size) as bugs are found.

### Streaming and I/O

| ID | Gap | Size |
|----|-----|------|
| I3 | *Deferred (2026-09-27).* No streaming writer: `WriteFile` builds the whole output `String` first. A `Write(Stream)` that also builds a full string adds nothing, so this is only worth doing as a real chunked output sink (every writer helper takes an output object instead of `String`; tail checks read a kept tail). Revisit if large outputs matter | M–L |

### Optional / nice to have

| ID | Idea | Size |
|----|------|------|
| O8 | *Optional, perf.* In the 20-library comparison (`bench/compare/`, architecture.md "TomlTester") only Rust's toml-spanner parses faster: 1.09× on average, ahead on 6 of 10 inputs, most on small arrays (1.8×), headers and the mixed config (1.4×) (2026-09-29, after the float/date/array fast paths, `TomlEntryMap` tables and arena pool reuse, which took it down from 1.48×). TomlBeef is the fastest style-preserving parser. Lookups (~70 ns) still trail zig-toml (~45) and go-toml (~55): a lookup goes `TomlTable` → entry array → index, where fingerprint bytes or keeping the index inline in the table might save a miss. From the toml-spanner study: resolve header and dotted-key segments as they are read with one find-or-add per segment (today a missing segment hashes twice), copy each string once straight into the store, smaller values (`TomlValue` is ~40 bytes because date/times are 8 × `int32`). Remaining ideas by profile: word-at-a-time scanning in the stream cursor (it still counts columns per byte), comment runs stored as source ranges in PreserveStyle (the `toml_edit` approach), multi-line strings through `ScanRun`, keeping parse errors out of `Result` payloads (return size matters: `int32` positions gave +20% on arrays) | M–L |
| O9 | *Serialization prototype → feature.* `[TomlObject]` works for the common field types (architecture.md 8a). Before documenting it in the README: `Dictionary<String, T>` fields (tables with free keys), `Nullable<T>` (absent = null, not written when null), nested lists, sized arrays, full dotted paths in error messages (`server.db.port`, not `port`), a decision on whether unknown keys can be reported (a strict mode), and whether writing should skip fields whose keys were absent when read (today it adds them with the field's value; skipping needs per-object "seen" tracking or an omit-defaults option). Possibly a direct text writer later if writing through `TomlTable` shows up in profiles | M |

## Suggested order

The remaining items are optional; take them as needed.
