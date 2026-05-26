# Beef Test Suite Expansion Plan

## Goal

Expand the native Beef `[Test]` coverage so parser, cursor, and API edge cases are caught directly by `beefbuild -test`, without relying only on external `toml-test` scripts or ad hoc stream probes.

The Beef tests should cover:

- public API behavior (`Read`, `ReadBytes`, `Read(Stream)`, `ReadFile`, merge/replace modes);
- byte cursor and stream cursor parity;
- stream buffer boundary behavior;
- UTF-8 validation and BOM handling;
- error precedence and location stability;
- ownership/lifetime-sensitive APIs where practical.

## Current state

`src/TomlBeef/TomlTest.bf` currently provides broad coverage through repository TOML files:

- validates that test files are present;
- smoke parses a simple document;
- round-trips all `tests/valid` files through `Read`/`Write`/`Read`;
- rejects `tests/invalid` files for TOML v1.0/v1.1 mode.

This is useful, but it misses implementation-specific edge cases discovered during byte/stream parser work:

- stream cursor behavior at the 8192-byte buffer boundary;
- invalid UTF-8 in comments or document-level positions;
- truncated UTF-8 at EOF;
- I/O errors mid-parse;
- BOM handling with already-buffered bytes;
- parser behavior parity across `StringView`, `Span<uint8>`, and `Stream` inputs.

## Design principles

1. **Keep Beef tests self-contained.** Prefer inline TOML strings/bytes for targeted edge cases.
2. **Test public APIs first.** Most new tests should use `TomlDocument.Read*` rather than cursor internals.
3. **Use helpers to avoid noisy tests.** Add small helpers for expected success/error and stream construction.
4. **Assert error kind and key locations.** Exact messages are less important than `TomlErrorKind`, line, column, and offset for known tricky cases.
5. **Exercise all input paths.** For selected cases, test string, bytes, and stream paths with the same input.
6. **Keep external suites separate.** `toml-test` remains acceptance coverage; Beef tests should target regressions and internals-sensitive edge cases.

## Proposed organization

Keep tests in `src/TomlBeef/TomlTest.bf` initially. If the file becomes too large, split into package-private test classes/files:

- `TomlApiTests.bf`
- `TomlInputPathTests.bf`
- `TomlStreamCursorTests.bf`
- `TomlUtf8Tests.bf`
- `TomlErrorLocationTests.bf`

All `[Test]` methods must be `static`.

## Shared test helpers

Add helper utilities to reduce boilerplate:

```bf
private static void AssertReadOk(StringView name, StringView input)
private static void AssertReadErr(StringView name, StringView input, TomlErrorKind kind)
private static void AssertReadBytesErr(StringView name, Span<uint8> input, TomlErrorKind kind)
private static void AssertReadStreamErr(StringView name, StringView input, TomlErrorKind kind)
private static void AssertReadStreamOk(StringView name, StringView input)
private static MemoryStream MakeMemoryStream(StringView input)
```

For byte inputs containing invalid UTF-8, build bytes with `List<uint8>` and pass as `Span<uint8>` or wrap in `MemoryStream`.

Add a small failing stream test class in the test file:

```bf
class FailingStream : Stream
class FailingAfterBytesStream : Stream
```

These should be test-only implementation types.

## Phase 1 — API input-path parity

Add tests proving the same simple documents parse through every public input path.

### Cases

- `Read(StringView)`
- `ReadBytes(Span<uint8>)`
- `Read(Stream)`
- `ReadFile(path)` if a temporary file helper is acceptable

### Assertions

For each path:

- parse succeeds;
- expected keys exist;
- typed getters return expected values;
- resulting document trees are equivalent.

### Suggested tests

- `InputPaths_ParseSameSimpleDocument`
- `InputPaths_ParseSameNestedDocument`
- `InputPaths_ReadBytesAcceptsListViaSpanConversion`

## Phase 2 — stream buffer boundary regressions

Add targeted stream tests using content around the default 8192-byte buffer boundary.

### Cases

1. Long comment crossing buffer boundary.
2. CRLF split across buffer boundary.
3. Long literal string crossing buffer boundary.
4. Long bare key crossing buffer boundary.
5. Long bare token crossing buffer boundary where the expected parse result is clear.
6. Marked slice spill path: token longer than buffer.

### Suggested tests

- `Stream_LongCommentCrossesBufferBoundary`
- `Stream_CrlfCrossesBufferBoundary`
- `Stream_LongLiteralStringCrossesBufferBoundary`
- `Stream_LongBareKeyCrossesBufferBoundary`
- `Stream_LongMarkedSliceUsesSpill`

### Notes

Use exact sizes that place important bytes at indexes 8191/8192:

- `\r` at 8191 and `\n` at 8192;
- UTF-8 lead byte at 8191 and continuation at 8192;
- closing quote after 8192.

## Phase 3 — UTF-8 validation coverage

Add direct tests for byte and stream validation behavior.

### Valid UTF-8 cases

- ASCII-only input;
- non-ASCII in basic string;
- non-ASCII in literal string;
- non-ASCII in comment;
- multi-byte sequence split across stream buffer boundary.

### Invalid UTF-8 cases

- invalid lead byte;
- unexpected continuation byte;
- invalid continuation byte;
- overlong sequence;
- surrogate range;
- codepoint above U+10FFFF;
- truncated sequence at EOF;
- truncated sequence before a structural character;
- invalid bytes in comment;
- invalid bytes at document/key position.

### Required assertions

- `TomlErrorKind.InvalidUtf8` for both byte and stream paths;
- error offset points to the invalid sequence start where feasible;
- stream path does not downgrade invalid UTF-8 to syntax errors like `InvalidKey`.

### Suggested tests

- `Utf8_BytePathRejectsInvalidSequences`
- `Utf8_StreamRejectsInvalidSequences`
- `Utf8_StreamRejectsInvalidBytesInComments`
- `Utf8_StreamRejectsInvalidBytesAtDocumentLevel`
- `Utf8_StreamRejectsTruncatedSequenceAtEof`
- `Utf8_StreamAcceptsValidSequenceAcrossBufferBoundary`

## Phase 4 — BOM behavior

Add tests for BOM parity across string, bytes, stream, and file helpers.

### Cases

- single leading UTF-8 BOM is accepted and skipped;
- content buffered after BOM is preserved;
- double BOM is rejected;
- BOM after non-BOM content is rejected;
- UTF-16 BOM is rejected as invalid UTF-8 or invalid document content, depending on path.

### Suggested tests

- `Bom_StringByteStreamAcceptSingleLeadingBom`
- `Bom_StreamPreservesContentAfterBom`
- `Bom_DoubleBomRejectedAtOffsetThree`
- `Bom_BomAfterContentRejected`

## Phase 5 — stream I/O error behavior

Add tests using custom streams.

### Cases

1. stream fails before any bytes;
2. stream fails after partial valid content;
3. stream fails while parser is inside a string;
4. stream fails while parser is inside a comment;
5. stream fails while a UTF-8 sequence is pending.

### Expected behavior

- public `Read(Stream)` returns `TomlErrorKind.IoError` when an actual stream read error occurs;
- I/O error takes precedence over secondary parse errors caused by truncation;
- no crashes or leaked owned values.

### Suggested tests

- `Stream_ErrorBeforeFirstByteReturnsIoError`
- `Stream_ErrorMidStringReturnsIoError`
- `Stream_ErrorMidCommentReturnsIoError`
- `Stream_ErrorDuringUtf8SequenceReturnsIoError`

## Phase 6 — read mode and transactional behavior

Add focused tests around `TomlReadConfig`.

### Cases

- `.Replace` clears old content;
- `.Merge` preserves old content;
- `.Merge + .Error` rejects duplicates;
- `.Merge + .Skip` keeps existing value;
- `.Merge + .Overwrite` replaces existing value;
- parse failure during merge leaves original document unchanged where intended.

### Suggested tests

- `ReadMode_ReplaceClearsExistingContent`
- `ReadMode_MergePreservesExistingContent`
- `ReadMode_MergeConflictError`
- `ReadMode_MergeConflictSkip`
- `ReadMode_MergeConflictOverwrite`
- `ReadMode_MergeParseErrorDoesNotMutateExistingDocument`

## Phase 7 — public accessor and dotted-path behavior

Add API-level regression coverage for lookup helpers.

### Cases

- root-level `TryGetXxx` helpers;
- cached `TomlTable` direct lookup pattern;
- missing paths return false/.Err;
- type mismatch returns false without crashing;
- dotted path with empty segment rejects;
- currently unsupported quoted dotted path behavior is explicit.

### Suggested tests

- `Accessors_TypedGettersReturnExpectedValues`
- `Accessors_TypeMismatchReturnsFalse`
- `Accessors_DottedPathMissingReturnsFalse`
- `Accessors_DirectTableLookupAvoidsDottedTraversal`

## Phase 8 — error location smoke tests

Add small exact-location tests for common diagnostics.

### Cases

- invalid key at start;
- control char in document;
- control char in comment;
- unterminated string;
- invalid UTF-8 at line 1 and line > 1;
- missing newline after key/value.

### Suggested tests

- `Errors_InvalidKeyLocation`
- `Errors_ControlCharLocation`
- `Errors_InvalidUtf8Location`
- `Errors_MissingNewlineLocation`

## Phase 9 — version-specific behavior

Add direct Beef tests for TOML v1.0/v1.1 differences that currently explain accepted-invalid external cases.

### Cases

- omitted seconds;
- multiline inline tables;
- trailing comma in inline tables;
- `\xHH` escapes.

### Suggested tests

- `Version_V1_1AllowsOmittedSeconds`
- `Version_V1_0RejectsOmittedSeconds`
- `Version_V1_1AllowsInlineTableNewlines`
- `Version_V1_0RejectsInlineTableNewlines`
- `Version_V1_1AllowsBasicByteEscapes`
- `Version_V1_0RejectsBasicByteEscapes`

## Phase 10 — memory/ownership regression guards

Beef tests cannot fully prove absence of ownership misuse, but they can catch crashes and double-free patterns.

### Cases

- parse document, get borrowed string view, delete document only after use;
- repeated parse/clear/delete cycles;
- failed parse followed by document deletion;
- merge conflict cleanup;
- array/table replacement cleanup.

### Suggested tests

- `Ownership_RepeatedParseClearDeleteDoesNotCrash`
- `Ownership_FailedParseDocumentDeleteDoesNotCrash`
- `Ownership_MergeConflictCleanupDoesNotCrash`

Avoid tests that intentionally call `Dispose()` on borrowed `TomlValue`; that would be known-invalid API misuse and may crash.

## Implementation order

Recommended order:

1. Add shared helpers and stream test streams.
2. Add stream boundary tests.
3. Add UTF-8 validation tests.
4. Add BOM tests.
5. Add I/O error tests.
6. Add read-mode/accessor/error-location tests.
7. Add version-specific direct tests.
8. Add ownership regression smoke tests.

This order locks down the most recently changed parser architecture first.

## Verification

After adding tests:

```bash
beefbuild -test
beefbuild
./test-toml.sh toml-test/tests
./test-roundtrip.sh toml-test/tests/valid
```

Expected current baseline:

- Beef tests should pass completely.
- `test-toml.sh` should keep the known 266 valid pass / 494 invalid rejected / 9 accepted-invalid result until version-policy work changes it.
- `test-roundtrip.sh` may continue to report the known 5 JSON ordering mismatches until writer ordering is addressed.

## Definition of done

- New Beef tests reproduce the stream/UTF-8/BOM/I/O bugs found during parser architecture work.
- The tests pass under `beefbuild -test`.
- Each future parser/cursor behavior change can be validated without rerunning external scripts first.
- External scripts remain acceptance tests, not the only guard against core parser regressions.
