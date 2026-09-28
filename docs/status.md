# TomlBeef Status

The single source of truth for where the project stands and what is left to do. Design and rationale
live in [architecture.md](architecture.md). Keep this file current: when an item is finished, delete its
row (git history is the record), and update the baseline when test counts change.

Last reviewed: 2026-09-27.

## Verification baseline

| Check | Expected result |
|-------|-----------------|
| `beefbuild -test` (Debug checks) | 239/239 pass |
| `beefbuild -test -config=TestRelease` (Release settings) | 239/239 pass |
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
| Ownership model | Document-owned arena; non-owning `TomlValue`; typed setters/getters are the public mutation API |
| Path access | Dotted and bracketed-segment paths for getters and setters |
| Resource limits | All `TomlReadConfig` limits enforced on every input path; documented in README |
| Writer | Canonical output; TOML 1.0 downgrade; `PreserveStyle` round-trip of comments, token text, numeric/date/array/inline-table formats, blank lines; public API to edit comments, string style, and integer base |
| Error reporting | Line, column, and byte offset for lexical, UTF-8, and semantic errors |

## Open items

Sizes are rough: S ≈ hours, M ≈ a day or two, L ≈ multi-day.

### Correctness bugs

None known. Add rows here (ID `B<n>`, problem, where, size) as bugs are found.

### PreserveStyle gaps

| ID | Gap | Size |
|----|-----|------|
| P2 | No "detached comment" placement: a comment block separated from the next node by a blank line is attached to that node (or the root/footer) rather than kept free-standing where it was | M |
| P3 | Style editing covers string style and integer base only. Possible additions: float style (decimal/scientific), date-time separator/`Z`, array layout (inline/multi-line), inline-table layout, key quoting; and comments on array elements (`TomlArray.SetComment(index, ...)`) | S–M |
| P4 | Document-style defaults: `mUseTabs` never inferred; `mDefaultArrayStyle` and `mPreferDottedKeys` inferred but unused for new values; no "nearby style" fallback | S |
| P5 | `TomlNodeStyle.mRange` source locations are never populated | S |

### Streaming and I/O

| ID | Gap | Size |
|----|-----|------|
| I1 | No streaming option for files: `ReadFile` loads the whole file (then parses the bytes directly). A `ReadFile` mode that wraps a `FileStream` in `Read(Stream)` would bound memory for large files | S |
| I2 | Stream buffer is fixed at 8 KiB: no growth policy, no config for buffer size, no `MaxTokenBytes`/`MaxKeys` limits | M |
| I3 | No writer sinks: no `Write(Stream)`/`WriteBytes`; `WriteFile` builds the whole output `String` first | M |
| I4 | No benchmarks, so byte-cursor performance and generic-parser code size are unmeasured | S |

### API surface

| ID | Gap | Size |
|----|-----|------|
| A2 | No public cross-document copy (`CloneInto(TomlDocument)` or similar); only internal `CloneInto(store)` and `TomlTable.MergeFrom`. Implement or declare out of scope | M |
| A5 | `DefaultReadConfig`/`DefaultWriteConfig` are global mutable statics; consider per-document defaults | S–M |
| A6 | Neither tables nor arrays have an enumerator; walking a document means index loops over `Count` with `GetKeyAt`/`GetValueAt` | S |
| A7 | `TomlTester` reads all stdin into memory and exposes no limit flags | S |

### Tooling

| ID | Gap | Size |
|----|-----|------|
| T1 | No automatic leak detection in tests. Beef's realtime leak check (`BF_ENABLE_REALTIME_LEAK_CHECK`) is a workspace config setting; enabling it for the Test config would catch error-path leaks. **Decision needed:** workspace config change | S |

### Optional / nice to have

| ID | Idea | Size |
|----|------|------|
| O1 | Writer output limits (deep dotted paths expand into cumulative headers unless `MaxPathSegments` is set) | M |
| O2 | Validating date/time factories returning `Result`; per-month day check (Feb 31 passes the debug assert) | S |
| O3 | Plain-mode writer choosing literal strings for backslash- or quote-heavy values | S |
| O4 | `doc["a.b"]` indexer on `TomlDocument` | S |
| O5 | Single-pass UTF-8 validation for string/byte input (currently a separate `ValidateUtf8` pass) | M |
| O6 | Split `TomlParser.bf` (~3000 lines) and `TomlWriter.bf` (~1500 lines) into smaller units | L |
| O7 | Bind/type errors with source locations (depends on P5); metadata text arena instead of `List<String>` | L / S–M |

## Suggested order

1. P4 (document defaults for new values), P5, P2 (detached comments), and P3 additions as needed.
2. I1–I4 and A2, A5–A7 as needed.
3. Optional items.
