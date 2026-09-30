# TomlBeef Parser Review

Reviewed on 2026-09-30 at commit `d65e920c1013a3a9c65154d485f4b402afe57fac`.

**Resolution (2026-09-30):** B1–B11 are fixed, each with a regression test in
`src/TomlBeef/tests/TomlRegressionTests.bf` (in memory and through a 16-byte stream buffer, in all
three metadata modes where they apply). Notes on the fixes:
- B1 writes the round-trip digits in scientific form; the text may be a shorter spelling of the
  same double. B2 made `MaxDepth` also count the table levels that headers and dotted keys build,
  so it bounds every recursive walk, not only sealing.
- B8 keeps the in-memory convention that a bad continuation byte is reported at itself.
- B9 captures the layout; single-line layouts still drop a trailing comma, as they do for a key's
  inline table. Nested multi-line indentation is open as status.md O15.

The architectural and performance suggestions remain open as status.md O10–O14; the stale
architecture note is corrected.

The parser has a sound foundation: lexical parsing and table conflict resolution are separate,
values belong to a document arena, cursors specialize at compile time, and metadata is optional.
The review nevertheless found silent numeric corruption, a parser crash, grammar errors, and
weaker resource protection than the configuration suggests. The existing verification baseline
passes despite these failures.

The review covered the parser extensions, byte and stream cursors, path resolver, resource limits,
document store, metadata capture, and related writer and public API code. It also inspected typed
binding and serialization for performance opportunities and missing features. Linux64 was the
verification target; deferred Windows/macOS support was not treated as a defect. Fetched
dependencies and `recovery/` were not changed.

This document records review evidence and recommendations. [status.md](status.md) remains the
current list of open work. Finding IDs below match its correctness rows. No implementation fixes
or permanent regression tests were added during this review.

## Evidence and priorities

- **P1:** Fix first: process crashes or silent changes to values.
- **P2:** Incorrect parsing/API behavior, ineffective resource protection, or incorrect diagnostics.
- **P3:** Presentation inconsistencies with unchanged semantic values.
- **Reproduced:** Exercised against the existing CLI in Debug and Release, with exceptions and
  differences called out explicitly.
- **Static:** Established from the implementation, but not exercised with a dedicated API test.
- **Opportunity:** A proposed improvement; no speedup or memory reduction has been measured.

## Reproduced findings

### B1 Scientific float output changes values

**P1.** With PreserveStyle enabled, parsing and writing an unchanged document changes scientific
floats. This input:

```toml
v = 3.141592653589793e0
```

becomes `v = 3.141593e0`. Re-reading gives a different binary64 value. A second reproduction,
`1.2345678901234567e10`, becomes `1.234568e10`, changing approximately `12345678901.234568` to
`12345680000`. Both builds reproduce the loss.

[TomlWriter.Formats.bf:197](../src/TomlBeef/TomlWriter.Formats.bf#L197) calls Beef's formatter with
`"e"` or `"E"` and no precision. The formatter defaults to six fractional digits. The nearby
comment describes this as round-trip precision, but that is not the behavior.

Generate scientific notation from a representation that preserves binary64 round-trip digits,
then apply exponent case, sign and width. Add exact value comparisons for long scientific
mantissas, very small and very large finite values, and scientific notation selected through the
public style API. The ordinary writer's `"R"` path did not show this failure in the review.

### B2 Dotted inline table depth can crash during sealing

**P1.** An inline table with a very long dotted key passes a low `MaxDepth` because key traversal
creates tables iteratively without increasing the parser's recursive value depth. The subsequent
sealing walk is recursive.

The input shape is `v = {a.a.a.<repeated segments>.z=1}`. At `MaxDepth = 2`, 100,000 repeated `a.`
segments produced SIGSEGV in Debug, using about 200 KB of input. Release succeeded at that size
but produced SIGSEGV with 250,000 repeated segments, using about 500 KB. These thresholds depend
on stack size and build settings; they are observations from this environment, not fixed limits.

GDB located the Debug crash in
[TomlTable.SealInlineRecursively:728](../src/TomlBeef/TomlTable.bf#L728), with repeated recursive
calls at line 739. Dotted descendants are created in
[InsertDottedKeyIntoTable:459](../src/TomlBeef/TomlParser.Containers.bf#L459).

Make sealing iterative, and audit recursive writing, cloning and merging for similarly deep
table trees. Decide whether a separate structural depth limit is needed. `MaxDepth` currently
measures recursive value parsing; it does not bound the resulting table-tree depth. A configured
`MaxPathSegments` mitigates this input, but its default is unlimited.

### B3 Array of tables headers extend sealed inline tables

**P2.** This invalid document is accepted:

```toml
a = {}
[[a.b]]
x = 1
```

The variant starting with `a = [{}]` is also accepted. Both TOML versions and both builds accept
the examples. The failure also reproduces with None, Positions and PreserveStyle metadata.

[DefineArrayOfTables:302](../src/TomlBeef/TomlPathResolver.bf#L302) lacks the sealed-parent check
used by other insertion paths. [NavigateSegment:163](../src/TomlBeef/TomlPathResolver.bf#L163)
also traverses static arrays as though they were arrays of tables.

Check whether the parent is sealed before creating an array of tables, and reject header
navigation through static arrays. Inline tables must define their descendants within their
braces; an outside header cannot extend them.
[TOML inline table rules](https://toml.io/en/v1.1.0#inline-table)

### B4 Multiline continuations leave whitespace in the value

**P2.** A continuation that crosses an indented blank line should remove the entire intervening
whitespace sequence. Instead, the parser leaves a newline and indentation in the decoded string.
The exact input bytes can be expressed as:

```python
b'v = """a\\\n  \n  b"""\n'
```

The expected string is `"ab"`; the actual string is `"a\n  b"`. Both TOML versions and builds
reproduce this, including all three metadata modes.

[TomlParser.Values.bf:192](../src/TomlBeef/TomlParser.Values.bf#L192) consumes consecutive newlines,
then horizontal whitespace only once. A subsequent newline after those spaces falls back into
ordinary string parsing. Repeatedly consume valid newlines and horizontal whitespace until
reaching content or the closing delimiter. Include spaces, tabs, multiple blank lines and CRLF
in regression coverage.
[TOML string continuation rules](https://toml.io/en/v1.1.0#string)

### B5 Multiline strings accept bare carriage returns

**P2.** A bare CR immediately after the opening delimiter is silently removed in both basic and
literal multiline strings. A bare CR after a continuation backslash is also accepted. Exact
examples, expressed as byte literals:

```python
b'v = """\rabc"""\n'       # Accepted as "abc"
b"v = '''\rabc'''\n"       # Accepted as "abc"
b'v = """a\\\rb"""\n'     # Accepted as "ab"
```

Both versions and builds reproduce these failures. The opening-delimiter paths at
[TomlParser.Values.bf:118](../src/TomlBeef/TomlParser.Values.bf#L118) and line 341 call
`SkipNewline()` directly. Continuation handling does the same. That cursor operation consumes a
bare CR; validation is performed by a separate parser helper that these paths bypass.

Provide a shared validated newline operation and use it in string parsing while keeping style
counting separate. TOML defines a newline as LF or CRLF.
[TOML newline definition](https://toml.io/en/v1.0.0#spec)

### B6 TOML 1.0 accepts comments inside inline tables

**P2.** The following input is accepted with `-toml 1.0`:

```toml
v = { a = 1 # comment
}
```

Both builds reproduce this, with all three metadata modes. The version gate in
[SkipInlineTableWs:425](../src/TomlBeef/TomlParser.Containers.bf#L425) passes `allowNewlines = false`,
but [SkipWsAndComments:550](../src/TomlBeef/TomlParser.bf#L550) still accepts comments. Its
comment helper consumes the terminating newline, indirectly bypassing the version restriction.

Reject comments in inline-table structural whitespace under TOML 1.0. Test before the first
field, after a value, after a comma, and before the closing brace. The rule should distinguish
structural newlines from newlines allowed within a value.
[TOML 1.0 inline table rules](https://toml.io/en/v1.0.0#inline-table)

### B7 Resource limits reject after expensive construction

**P2.** Several configured limits bound the accepted result but do not stop the associated work
early. Streamed CLI reproductions in both builds showed:

| Configuration | Input | Observed behavior |
|---|---|---|
| `MaxStringBytes = 8` | One 8 MiB string | The entire string is decoded before rejection |
| `MaxArrayItems = 1` | `[1, <8 MiB string>]` | The second value is fully constructed before rejection |
| `MaxPathSegments = 4` | A key with 100,001 segments | All segments are parsed before rejection |

[FinishStringValue:632](../src/TomlBeef/TomlParser.bf#L632) checks string size after decoding;
[ParsePlainArray:247](../src/TomlBeef/TomlParser.Containers.bf#L247) parses a value before checking
item count; [ParseKeyPath:457](../src/TomlBeef/TomlParser.bf#L457) checks the segment count after
the complete path. The metadata array path also checks item count after parsing the value.

Check counts before constructing another element or segment, and bound decoded string growth
during scanning and escape expansion. A final size check can remain as a backstop. Review table
entry checks for the same ordering issue. `ReadFile` loading the full file before enforcing
`MaxInputBytes` is already documented; streamed file reads are the existing alternative.

### B8 BOM prefixed streams report incorrect UTF-8 positions

**P2.** For `b'\xef\xbb\xbfv = "\xff"\n'`, streamed parsing reports column 7 instead of column 6.
After a refill the discrepancy can be much larger. An input with a BOM, `#prefix\n`, 9,000 spaces,
and `v = "` followed by byte `0xFF` reports `1:825`; the offending byte is at `2:9006`. Both builds
reproduce the diagnostic errors.

[ResetPosition:89](../src/TomlBeef/TomlBufferedStreamCursor.bf#L89) resets validator counters after
buffered bytes have already been validated. Parser and validator positions then refer to
different progress through the input. Its validator offset reset also merits checking against
the raw-byte-offset contract.

Handle the BOM before establishing validation positions, or adjust existing validator state
without discarding progress. Add exact line, column and raw offset comparisons across byte and
stream input, before and after refills, including invalid sequences split across buffers.

### B9 Inline tables inside arrays lose captured layout

**P3.** With PreserveStyle, `v=[{x=1,y=2,}]` becomes `v = [{x = 1, y = 2}]`. The inline table loses
its spacing and trailing comma in both builds.

[CaptureArrayElement:633](../src/TomlBeef/TomlParser.Style.bf#L633) captures formats for strings,
numbers, dates and arrays, but explicitly skips tables. General value metadata capture already
supports table formats. Reuse that path for table elements and test nesting and TOML 1.0
downgrade behavior. This finding concerns supported layout hints, rather than requiring
PreserveStyle to reproduce every source byte.

## Static API findings

### B10 Changing the sign of zero can be treated as an unchanged assignment

**P2, static.** [TomlValue.IsSemanticallyEqualTo:351](../src/TomlBeef/TomlValue.bf#L351) compares
floats with `==`, treating `0.0` and `-0.0` as equal. Scalar setters use this equality to skip
assignments and dirty marking, so changing the sign of zero can be ignored. The writer otherwise
deliberately preserves negative zero.

Distinguish zero signs in assignment equality. Add dedicated public-API tests for both sign
changes, table and array slots, merge overwrite, and canonical/PreserveStyle output. No dedicated
mutation reproduction was run during this review.

### B11 Exact path lookup rejects legal empty keys

**P2, static.** [TomlDocument.GetPath:761](../src/TomlBeef/TomlDocument.bf#L761) rejects every empty
segment, including the explicit-segment API. The parser accepts legal empty quoted keys, and
table lookup can address them, but document path lookup cannot.

Keep path-string syntax validation separate from exact key traversal. Add tests for empty root
and intermediate keys through both `GetPath` overloads. The treatment of empty bracketed paths
can be a separate API decision. No dedicated API reproduction was run during this review.
[TOML key rules](https://toml.io/en/v1.1.0#keys)

## Readability and architectural findings

The existing cursor specialization, arena ownership, resolver separation and optional metadata
are worth preserving. The following concerns are supported by static review; they are not
additional reproduced failures.

- **Context rules depend on callers.** Comment helpers consume newlines as a side effect, and
  sealing checks are distributed among resolver operations. B3, B5 and B6 show the consequences.
  Make allowed comment/newline behavior explicit and centralize structural insertion guards.
- **Semantic logic is duplicated.** Plain and metadata arrays have separate loops; basic-string
  keys and values have similar decoding loops; array-element format capture duplicates general
  value capture. Share validation and decoding rules while retaining cheap optional metadata
  paths. Avoid requiring a bug fix in several implementations of the same rule.
- **Layout inference scans syntax again without lexical context.**
  [CaptureTableFormat:534](../src/TomlBeef/TomlParser.Style.bf#L534) scans raw text without fully
  distinguishing punctuation in strings and nested containers. Record spacing, commas and
  indentation at the actual separators during parsing. This also avoids rescanning containers.
- **The public string payload allows mutation outside dirty tracking.**
  [TomlValue:20](../src/TomlBeef/TomlValue.bf#L20) exposes a mutable document-owned `String` through
  pattern matching. Calling its mutation methods bypasses the table/array setters and can
  invalidate existing string views. Consider a borrowed `StringView` payload or a read-only
  public value representation while keeping owned strings internal. This would be an API design
  change, not merely an implementation cleanup.
- **Some architecture notes are stale.** The public API section says document setters require
  existing intermediate tables, but
  [ResolvePath:683](../src/TomlBeef/TomlDocument.bf#L683) now creates missing parents when requested
  by setters. Bring the explanation into agreement with the implementation and tests.

## Performance opportunities

These are concrete profiling and implementation candidates. The review did not measure their
speedups, and the existing benchmarks should remain the basis for performance claims.

| Opportunity | Evidence and proposed change |
|---|---|
| Remove repeated typed-binding lookups | [TomlBind.Lookup:17](../src/TomlBeef/TomlBind.bf#L17) uses `ContainsKey` before `RequireValue` for present optional fields, searching the same key twice. Use one lookup and apply the missing/required/type checks to its result. |
| Avoid temporary path-list allocation | [TomlDocument.Get:719](../src/TomlBeef/TomlDocument.bf#L719) creates a list of segments for each dotted getter. Traverse segments directly, or offer reusable parsed paths for repeated queries. |
| Extend bulk scanning to streams | [TomlBufferedStreamCursor.ScanRun:232](../src/TomlBeef/TomlBufferedStreamCursor.bf#L232) and incremental UTF-8 validation scan byte by byte, while the byte cursor and whole-buffer validator have bulk ASCII paths. Preserve refill, Unicode column and error-position behavior when porting them. |
| Allocate scratch buffers only when used | [TomlParserImpl constructor:71](../src/TomlBeef/TomlParser.bf#L71) allocates comment buffers even without PreserveStyle. Lazy initialization could reduce overhead for small files and documents without strings/comments. |
| Capture layout without retaining whole containers | PreserveStyle marks complete values and slices them for format inference. Recording separator/layout facts during parsing could reduce retained stream spans, spill copies and repeated scanning. Strings still need original token capture when token reuse is desired. |

The stream scanning opportunity overlaps existing status item O8; typed-binding improvements
overlap O9. Retain those existing benchmark priorities instead of treating this review as evidence
of a particular performance gain.

## Missing features and lifecycle improvements

These are optional additions or design decisions, not missing core TOML value types.

- **Nullable fields:** Define absent/null behavior for typed reads and omission during writes.
- **Nested lists and fixed arrays:** Extend generated serialization beyond its current collection
  shapes, with clear ownership and replacement rules.
- **Unknown-key reporting:** Offer strict typed binding when callers want misspelled or unused
  configuration keys to be errors.
- **Full nested error paths:** Carry paths such as `server.db.port` through generated binding and
  converters instead of reporting only the immediate field name.
- **Chunked output:** A real streaming writer should emit chunks without first building the full
  output string. This is already deferred as I3.
- **Explicit release of retained memory:** Removed/replaced payloads remain in the document arena,
  and reset recycles pools from large reads. Consider a way to release cached pools when callers
  favor lower retained memory. Compaction is a separate decision because it affects borrowed
  values and views.

The serialization additions are already recorded under O9. The memory behavior is deliberate;
the proposed release operation should preserve the documented borrowing guarantees.

## Verification performed

The review built the CLI in Debug and Release before running the acceptance scripts. All of the
following completed successfully on the reviewed implementation:

| Check | Debug | Release |
|---|---|---|
| Beef tests | `beefbuild -test`: 309/309 | `beefbuild -test -config=TestRelease`: 309/309 |
| Local parser corpus | 266 semantic matches; 503 invalid fixtures rejected | 266 semantic matches; 503 invalid fixtures rejected |
| Canonical round trips | 266/266 | 266/266 |
| Encoder round trips | 266/266 | 266/266 |

Commands for the local acceptance checks were `./test-toml.sh`, `./test-roundtrip.sh` and
`./test-encoder.sh`, with `BIN=./build/Release_Linux64/TomlTester/TomlTester` for Release. These
results do not include the targeted failing inputs above. The upstream Go suite and LeakSanitizer
were not rerun as part of this review; their entries in status.md remain the earlier baseline.

The targeted grammar failures, float output loss, late resource checks and streaming diagnostic
errors were reproduced separately. The deep-nesting crash was reproduced at different sizes in
the two builds, with the Debug sealing failure confirmed by GDB. B10 and B11 remain static API
findings requiring dedicated mutation/lookup tests.

## Regression coverage recommendations

The corpus is valuable but does not cover all combinations of syntax, metadata, streaming and
mutation. Add the small reproductions above as regressions, checking decoded values and exact
error positions rather than only successful parsing or regenerated text.

Exercise TOML 1.0 and 1.1, None/Positions/PreserveStyle, byte and stream input, and small stream
buffers that force refills. For numeric writes, compare re-parsed values exactly and check zero
signs explicitly. For limits, check where reading stops as well as the returned error. For deep
tables, ensure excessive input returns a handled error or uses an iterative walk rather than
crashing. Correctness fixes should precede the optional refactoring and feature work.
