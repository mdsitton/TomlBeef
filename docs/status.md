# TomlBeef Status

The single source of truth for where the project stands and what is left to do. Design and rationale
live in [architecture.md](architecture.md). Keep this file current: when an item is finished, delete its
row (git history is the record), and update the baseline when test counts change.

Last reviewed: 2026-09-27.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 261/261 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 261/261 pass |
| `./test-leaks.sh` | 261/261 under LeakSanitizer, no leaks, exit 0 |
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
| Public surface | Metadata sidecar, parser, cursors and path resolver are `internal`. Metadata is reached only through `doc.PreservesStyle`, `doc.HasSourcePositions` and the comment/style/source-range methods, with `TomlMetadataMode`, `TomlStringStyle`, `TomlIntegerBase` and `TomlSourceRange` as the public types |
| Path access | Dotted and bracketed-segment paths for getters and setters |
| Resource limits | All `TomlReadConfig` limits enforced on every input path; documented in README |
| Writer | Canonical output; TOML 1.0 downgrade; `PreserveStyle` round-trip of comments, token text, numeric/date/array/inline-table formats, blank lines; public API to edit comments, string style, and integer base, and to query source positions (also available alone through the cheaper `Positions` mode) |
| Error reporting | Line, column, and byte offset for lexical, UTF-8, and semantic errors; `TomlParseError` needs no cleanup (message in a per-thread buffer) and works with `Try!` |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

### Correctness bugs

None known. Add rows here (ID `B<n>`, problem, where, size) as bugs are found.

### PreserveStyle gaps

| ID | Gap | Size |
|----|-----|------|
| P3 | Style editing covers string style and integer base only. Possible additions: float style (decimal/scientific), date-time separator/`Z`, array layout (inline/multi-line), inline-table layout, key quoting; and comments on array elements (`TomlArray.SetComment(index, ...)`) | S–M |
| P4 | *Optional.* "Nearby style" for new values: a new key could copy the format of its siblings (e.g. hex like its neighbours) instead of the document-wide default. New multi-line arrays always get a trailing comma rather than following the document's habit | S |
| P6 | *Optional, perf.* Metadata node storage: every table with metadata gets a context object with a key → node ID dictionary, and every node a `TomlNodeStyle` record. This shared machinery is most of the cost of both modes (5 MB bench: None ~46 MB/s, Positions ~35, PreserveStyle ~28; peak RSS 82 / 147 / 163 MB). Storing node IDs inline in tables/arrays (parallel to the key order) and ranges in a compact array would cut both | M |

### Streaming and I/O

| ID | Gap | Size |
|----|-----|------|
| I2 | *Optional.* No `MaxTokenBytes` limit: a token longer than the stream buffer is accumulated in the spill string, bounded only by `MaxInputBytes` / `MaxStringBytes` | S |
| I3 | *Deferred (2026-09-27).* No streaming writer: `WriteFile` builds the whole output `String` first. A `Write(Stream)` that also builds a full string adds nothing, so this is only worth doing as a real chunked output sink (every writer helper takes an output object instead of `String`; tail checks read a kept tail). Revisit if large outputs matter | M–L |
| I4 | *Optional.* Parse throughput (~59 MB/s bytes, ~51 MB/s stream; `TomlTester -bench`) is limited by the parser handling one byte per call. Cursor methods that scan runs (whitespace, comments, bare keys, escape-free string text) directly over the buffer would speed up both paths; it touches the parser's hottest loops | M |

### API surface

| ID | Gap | Size |
|----|-----|------|

### Tooling

| ID | Gap | Size |
|----|-----|------|

### Optional / nice to have

| ID | Idea | Size |
|----|------|------|
| O1 | Writer output limits (deep dotted paths expand into cumulative headers unless `MaxPathSegments` is set) | M |
| O2 | Validating date/time factories returning `Result`; per-month day check (Feb 31 passes the debug assert) | S |
| O3 | Plain-mode writer choosing literal strings for backslash- or quote-heavy values | S |
| O4 | `doc["a.b"]` indexer on `TomlDocument` | S |
| O5 | Single-pass UTF-8 validation for string/byte input (currently a separate `ValidateUtf8` pass) | M |
| O7 | Bind/type errors that carry source locations automatically (building on `TryGetSourceRange`); metadata text arena instead of `List<String>` | L / S–M |

## Suggested order

1. I1–I4 (streaming and writer output) as needed.
2. P3, P4, P6 as needed.
3. Optional items.
