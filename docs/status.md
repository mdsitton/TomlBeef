# TomlBeef Status

The single source of truth for where the project stands and what is left to do. Design and rationale
live in [architecture.md](architecture.md). Keep this file current: when an item is finished, delete its
row (git history is the record), and update the baseline when test counts change.

Last reviewed: 2026-09-27.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 288/288 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 288/288 pass |
| `./test-leaks.sh` | 288/288 under LeakSanitizer, no leaks, exit 0 |
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
| O8 | *Optional, perf.* Parsing is ~85 MB/s on the mixed bench and fastest in the comparison (`bench/compare/`, architecture.md "TomlTester") on every input except comment-heavy ones and small arrays, where glaze (and go-toml/toml-c on comments) lead; judged good enough (2026-09-28). Remaining ideas by profile: a faster comment skip when not capturing (bulk scan for `\n`), per-element overhead in arrays, multi-line strings through `ScanRun`, fewer allocations per table (dictionary and key list), keeping parse errors out of `Result` payloads (return size matters: `int32` positions gave +20% on arrays) | M |

## Suggested order

The remaining items are optional; take them as needed.
