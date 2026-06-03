# TOML Test Suite Rework Plan — 2026-06-03

## Summary

`src/TomlBeef/TomlTest.bf` is currently a 4,267-line junk drawer containing corpus tests, parser smoke tests, stream tests, preserve-style metadata tests, writer-format tests, mutation API tests, resource limit tests, helpers, and a custom failing stream. It technically passes, but maintainability is bad and several tests are weak, misleading, redundant, or actively masking bugs.

This plan splits the test suite by behavior, moves shared helpers into a support file, strengthens weak assertions, removes/renames legacy phase tests, and clearly separates specification/corpus coverage from implementation-detail regression tests.

## Current inventory

Current monolith:

- File: `src/TomlBeef/TomlTest.bf`
- Size: 4,267 lines
- Current test count: 166
- Current status: `beefbuild -test` passes 166/166 as of review

Current external corpus:

- `tests/valid/`
- `tests/invalid/`
- Total `tests/` files observed: 1,042
- Invalid files observed: 509

## Goals

1. Split `TomlTest.bf` into focused files by test type.
2. Keep all useful behavioral coverage.
3. Remove, rewrite, or explicitly downgrade tests that are misleading, toothless, redundant, or testing implementation details without value.
4. Improve failure diagnostics, especially corpus tests.
5. Preserve current passing behavior before semantic changes.
6. Make future test additions obvious: a new test should have an obvious destination file.

## Non-goals

- Do not change parser, writer, serializer, metadata, or public API behavior as part of the split.
- Do not edit upstream/reference material under `BJSON/`, `toml-test/`, or `recovery/`.
- Do not reorganize the external TOML corpus files unless a later task explicitly asks for corpus layout changes.
- Do not use git revert/reset/checkout to clean up mistakes. Surgical edits only. No bulldozer ballet.

## Proposed file layout

Put the Beef test source files under a dedicated test-source folder, not beside production code. Preferred layout: `tests/unit/` for `.bf` test files. Keep the existing TOML corpus under `tests/valid/` and `tests/invalid/` unchanged.

This plan originally called for `tests/unit/` but `beefbuild -test` does not discover `.bf` files outside the project source tree without a separate test project or explicit source-directory configuration. Adding a separate test project was ruled out to keep the repo simpler. Final location: `src/TomlBeef/tests/`. Files are discovered because `src/` is the default source root for the `TomlBeef` library project, and Beef compiles all `.bf` files recursively.

This means the repository's `tests/` directory has two roles:

- `tests/valid/` and `tests/invalid/`: external TOML corpus fixtures.
- `src/TomlBeef/tests/`: Beef `[Test]` source files.

Before moving everything, verify that `beefbuild -test` discovers `.bf` files. BeefLib projects compile all `.bf` files recursively under `src/`, so adding a `src/TomlBeef/tests/` subdirectory is sufficient. No separate test project or workspace config change is needed.

### `TomlTestSupport.bf`

Shared test helpers only. No `[Test]` methods.

Move here:

- `TestBaseDir`
- `ParseFile`
- `WalkTomlFiles`
- `TomlDocumentEquals`
- `TomlTableEquals`
- `TomlValueEquals`
- `TomlArrayEquals`
- `GetRelativePath`
- `AddAscii`
- `AddByte`
- `AddBytes`
- `AddRepeat`
- `ReadFromByteStream`
- `AssertReadErr`
- `FailingAfterBytesStream`

Recommendation:

- Use `public static` helpers in a `static class TomlTestSupport`.
- In test files, use either `using static TomlBeef.TomlTestSupport;` if Beef accepts it cleanly, or call helpers through `TomlTestSupport.`.
- Avoid partial classes; Beef does not appear to use C#-style `partial` as a normal pattern.

### `TomlCorpusTests.bf`

Corpus and fixture-discovery tests.

Move here:

- `VerifyTestFilesFound`
- `RoundTripValid`
- `InvalidV1_1`
- `InvalidV1_0`

Required improvements:

- `InvalidV1_0` and `InvalidV1_1` must report the specific file path for any invalid TOML that parses successfully.
- `VerifyTestFilesFound` should assert meaningful minimums or at least separate valid and invalid counts with diagnostic output.
- Keep corpus tests semantic unless explicitly adding raw-byte corpus coverage.

Optional future improvement:

- Add a second corpus path that exercises `ReadBytes` for files where raw byte behavior matters, instead of converting bytes to a `String` manually.

### `TomlReadTests.bf`

Basic document read behavior and transactional read failure behavior.

Move here:

- `SmokeTest`
- `ReadError_ReplaceLeavesDocumentBlank`
- `ReadError_MergeLeavesDocumentUnchanged`

Review notes:

- `SmokeTest` is low-value but harmless. Keep as a tiny sanity check or remove if corpus tests are considered sufficient.
- Transactional behavior tests are useful and should stay.

### `TomlStreamTests.bf`

Stream, UTF-8, BOM, and I/O error tests.

Move here:

- `Stream_CrlfCrossesBufferBoundary`
- `Stream_LongCommentCrossesBufferBoundary`
- `Stream_LongLiteralStringCrossesBufferBoundary`
- `Stream_LongBareKeyCrossesBufferBoundary`
- `Utf8_StreamRejectsInvalidLeadByte`
- `Utf8_StreamRejectsInvalidBytesInComment`
- `Utf8_StreamRejectsTruncatedSequenceAtEof`
- `Utf8_StreamRejectsOverlongSequence`
- `Utf8_StreamAcceptsValidUtf8AcrossBuffer`
- `Bom_StreamPreservesContentAfterBom`
- `Bom_DoubleBomRejected`
- `Stream_ErrorBeforeFirstByteReturnsIoError`
- `Stream_ErrorMidStringReturnsIoError`

Review notes:

- These are valid and important because they cover byte/stream behavior not covered by the string parser.
- Keep byte construction helpers in `TomlTestSupport.bf`.

### `TomlPreserveStyleMetadataTests.bf`

Tests that verify metadata capture, not emitted output.

Move here metadata-capture tests such as:

- `PreserveStyle_DetectsDottedKeys`
- `PreserveStyle_DetectsNoDottedKeys`
- `PreserveStyle_DetectsDominantStringStyle`
- `PreserveStyle_DetectsIndentation`
- `PreserveStyle_IndentDefaultForTopLevel`
- `PreserveStyle_DetectsCrlfNewlines`
- `PreserveStyle_DetectsLfNewlines`
- `PreserveStyle_DetectsMultilineArrayStyle`
- `PreserveStyle_DetectsInlineArrayStyle`
- `PreserveStyle_CapturesDottedKeyFormat`
- `PreserveStyle_CapturesQuotedKeyFormat`
- `PreserveStyle_CapturesLiteralKeyFormat`
- `PreserveStyle_CapturesBareKeyFormat`
- `PreserveStyle_CapturesDateTimeFormat*`
- `PreserveStyle_CapturesLocal*`
- `PreserveStyle_MixedNewlinesFavorsDominant`
- `PreserveStyle_LfDominantOverCrlf`
- `PreserveStyle_ArrayStringsCountForDominantStyle`
- `PreserveStyle_DefaultStringStyleBasic`
- `PreserveStyle_CapturesSpecialFloatFormat`
- integer/float/string token format capture tests
- comment metadata capture tests where the actual purpose is metadata capture

Review notes:

- These tests are allowed to inspect internals because they are explicitly metadata tests.
- They should avoid depending on `mNodeStyles[0]` unless order is part of the contract being tested.
- Prefer resolving node IDs by key through metadata context where possible.

### `TomlPreserveStyleWriterTests.bf`

Tests that verify output formatting, token reuse, comment emission, dirty propagation effects, array formatting, inline-table formatting, and reparse validity.

Move here writer/output tests such as:

- `PreserveStyle_DocumentStyleFallbackForString`
- `PreserveStyle_EofCommentEmittedAfterContent`
- `PreserveStyle_RemoveThenReinsertDoesNotReuseOldToken`
- `PreserveStyle_WriterReusesStringTokens`
- `PreserveStyle_WriterReusesLiteralStringToken`
- `PreserveStyle_WriterReusesMultilineToken`
- `PreserveStyle_IntegerFormatPreserved`
- `PreserveStyle_IntegerMinDigitsPreserved`
- `PreserveStyle_NegativeDecimalIntegerKeepsGrouping`
- `PreserveStyle_NegativeIntegerFallsBackToDecimal`
- `PreserveStyle_FloatPrecisionPreserved`
- `PreserveStyle_FloatFormatPreserved`
- `PreserveStyle_DateTimeOmittedSecondsPreservedOnDirtyWrite`
- `PreserveStyle_MultilineArrayFormatPreservedOnDirtyWrite`
- `PreserveStyle_DottedKeysReemitted`
- `PreserveStyle_DottedKeysNestedTables`
- comment emission exact-output tests
- array comment preservation tests
- inline table spacing/writer tests
- dirty propagation output tests

Required improvements:

- Use exact output assertions when the test claims exact output.
- Avoid broad `Contains` checks when formatting is the contract.
- Add reparse checks for generated TOML where missing and meaningful.

### `TomlPathTests.bf`

Path lookup and bracketed segment syntax.

Move here:

- `QuotedPath_BareDottedStillWorks`
- `QuotedPath_RootKeyWithDot`
- `QuotedPath_NestedKeyWithDot`
- `QuotedPath_MultipleBracketedSegments`
- `QuotedPath_MalformedSyntaxRejected`
- `QuotedPath_TryGetTypedInheritsBracketSyntax`
- `QuotedPath_GetPathParams`

Review notes:

- These are useful public API tests.
- Keep malformed syntax tests; they protect against accidentally accepting ambiguous string paths.

### `TomlInlineTableSealTests.bf`

Inline table recursive sealing and extension rejection.

Move here:

- `InlineTableSeal_DottedKeyChildNotExtendable`
- `InlineTableSeal_DottedKeyChildNotExtendable2`
- `InlineTableSeal_NestedInlineTableChildNotExtendable`
- `InlineTableSeal_DottedKeyWithinInlineTableStillValid`
- `InlineTableSeal_NestedInlineTablesStillValid`
- `InlineTableSeal_HeaderExtensionOfDottedChildRejected`

Required improvement:

- `InlineTableSeal_HeaderExtensionOfDottedChildRejected` currently says multiple error kinds are acceptable but asserts only `DuplicateTable`. Either:
  - assert only that parsing fails, if any rejection is acceptable, or
  - update the comment and keep the exact expected kind.

### `TomlMutationApiTests.bf`

Public API tests for typed setters, arrays, table entries, and proxy mutation.

Move here:

- `TypedSetters_DocumentLevel`
- `TypedSetters_TableAndArrayLevel`
- `Phase10_ArrayAssignmentAndAdd`
- `Phase10_SetTableAndSetArray`
- `Phase10_RemoveAtAndClear`
- `Phase11_TableEntryReadAndAssign`
- `Phase11_TableEntrySetTableAndArray`
- `Phase11_DuplicateRenameRejected`

Required improvements:

- Rename historical `Phase10_` and `Phase11_` tests to behavior names. Phase names are archaeological labels, not documentation.
- Tighten `Phase10_RemoveAtAndClear`: decide whether clearing an array should serialize as missing or empty, then assert that exact behavior.

Suggested renames:

- `Phase10_ArrayAssignmentAndAdd` -> `Array_AddAndIndexAssignment_RoundTrips`
- `Phase10_SetTableAndSetArray` -> `Array_SetTableAndSetArray_RoundTrips`
- `Phase10_RemoveAtAndClear` -> `Array_RemoveAtAndClear_RoundTripsExpectedState`
- `Phase11_TableEntryReadAndAssign` -> `TableEntry_ReadAssignRemoveRename_Works`
- `Phase11_TableEntrySetTableAndArray` -> `TableEntry_SetTableAndSetArray_RoundTrips`
- `Phase11_DuplicateRenameRejected` -> `TableEntry_RenameToDuplicateKeyRejected`

### `TomlResourceLimitTests.bf`

Resource-limit behavior.

Move here:

- all `ResourceLimit_*` tests

Review notes:

- These are useful and should stay.
- Keep transaction/replace/merge checks because resource limit failures must not corrupt document state.

## Tests requiring rewrite or deletion

The following tests should not be blindly preserved as-is.

### Weak or misleading assertions

#### `PreserveStyle_WriterReusesStringTokens`

Problem:

- The comment admits regenerated output may match preserved output.
- If canonical output is identical, this does not prove token reuse.

Action:

- Replace input with a token where semantic value would regenerate differently, or move this to a broader writer smoke test.
- If no such token exists, delete it as redundant.

#### `PreserveStyle_FloatExponentDigitWidth`

Problem:

- Current assertion is logically weak:
  - `output.Contains("2e03") || output.Contains("2e+03") == false`
- This can pass without proving the required exact format.

Action:

- Assert exact expected output or at least:
  - must contain `2e03`
  - must not contain `2e+03`
  - must not contain uppercase `E` if lowercase is required

#### `PreserveStyle_FloatFormatPreserved`

Problem:

- Only checks for `e` or `E` anywhere in output.
- That is barely a test. A random key named `cheese` would do exciting things here.

Action:

- Assert exact expected numeric token based on the captured format.

#### `PreserveStyle_FloatSpecialSignPreserved`

Problem:

- Test name says sign is preserved.
- Assertion accepts either `+nan` or `nan`.

Action:

- Decide the contract.
- If explicit plus is preserved, assert `+nan` exactly.
- If explicit plus is optional, rename the test so it stops lying.

#### `InlineTableSeal_HeaderExtensionOfDottedChildRejected`

Problem:

- Comment says multiple errors are acceptable.
- Assertion accepts only `DuplicateTable`.

Action:

- Either assert generic failure or update the comment to match the exact expected error.

#### `Phase10_RemoveAtAndClear`

Problem:

- Accepts both missing array and empty array after clear/roundtrip.
- This masks serialization behavior changes.

Action:

- Define expected behavior and assert exactly that.

### Low-value/redundant tests

#### `SmokeTest`

Problem:

- Duplicates corpus/basic parse coverage.

Action:

- Keep only if desired as a minimal sanity test. Otherwise delete.

#### `VerifyTestFilesFound`

Problem:

- `count > 0` is too weak for a large corpus.

Action:

- Replace with minimum expected counts or a clearer fixture availability check.

### Brittle implementation-detail tests

Many preserve-style tests index directly into metadata lists, especially `mNodeStyles[0]` and `mValueFormats[0]`.

Action:

- Keep internal metadata inspection only in metadata-specific files.
- Prefer looking up node IDs by key via metadata context instead of relying on insertion order.
- If a test only cares about output, assert output and stop poking internals like a raccoon in a fuse box.

## Validity policy for future tests

A test is valid if it satisfies at least one of these:

1. Verifies TOML spec behavior.
2. Verifies public API contract.
3. Verifies documented writer/read configuration behavior.
4. Protects against a known regression with a clear failure mode.
5. Verifies internal metadata only when the metadata itself is the feature under test.

A test is harmful or pointless if it does any of these:

1. Passes for multiple incompatible behaviors without saying so intentionally.
2. Uses broad `Contains` where exact formatting is the contract.
3. Tests private ordering accidentally rather than behavior intentionally.
4. Has a name/comment that promises more than the assertion proves.
5. Accepts either data loss or preservation as equally fine without an explicit contract.
6. Hides the failing corpus file path.
7. Is only there because an implementation phase once existed.

## Implementation sequence

### Phase 0 — Clean accidental/unrelated files

Before real work starts, remove any accidental file created during review-only work if present and not intentionally adopted.

Current known accidental file from prior review misstep:

- `src/TomlBeef/TomlTestSupport.bf`

Because the preferred test-source location is `src/TomlBeef/tests/`, do not keep this accidental file at `src/TomlBeef/`. Either delete it or recreate the intended support file at `src/TomlBeef/tests/TomlTestSupport.bf`. Do not pretend the gremlin was always part of the architecture.

Verification:

- `git status --short`
- Confirm only intended files are changed.

### Phase 1 — Baseline verification

Run:

```bash
beefbuild -test
```

Record:

- test count
- pass/fail result
- any warnings

Expected baseline currently:

- 166/166 passing

### Phase 2 — Extract support helpers

Create `src/TomlBeef/tests/TomlTestSupport.bf`.

Move shared helpers and `FailingAfterBytesStream` out of `TomlTest.bf`.

No test behavior should change.

Run:

```bash
beefbuild -test
```

Acceptance:

- Same tests pass.
- No helper name collisions.
- No lifetime regressions from moved helper code.

### Phase 3 — Split corpus/read/stream tests

Create:

- `TomlCorpusTests.bf`
- `TomlReadTests.bf`
- `TomlStreamTests.bf`

Move corresponding tests from `TomlTest.bf`.

Run:

```bash
beefbuild -test
```

Acceptance:

- Same tests pass.
- Corpus failures include file names where possible.

### Phase 4 — Split preserve-style tests

Create:

- `TomlPreserveStyleMetadataTests.bf`
- `TomlPreserveStyleWriterTests.bf`

Move tests by purpose:

- Metadata capture assertions go to metadata tests.
- Output/token/comment/dirty-write assertions go to writer tests.

Do not rewrite every weak test during this move unless needed for compile/pass. Keep refactor and semantic tightening mostly separate so failures have an obvious cause.

Run:

```bash
beefbuild -test
```

Acceptance:

- Same tests pass.
- No accidental test deletion.

### Phase 5 — Split API/resource tests

Create:

- `TomlPathTests.bf`
- `TomlInlineTableSealTests.bf`
- `TomlMutationApiTests.bf`
- `TomlResourceLimitTests.bf`

Move corresponding tests.

Run:

```bash
beefbuild -test
```

Acceptance:

- Same tests pass.
- `TomlTest.bf` is either deleted or reduced to nothing and then removed.

### Phase 6 — Rename legacy phase tests

Rename `Phase10_*` and `Phase11_*` to behavior-oriented names.

Run:

```bash
beefbuild -test
```

Acceptance:

- Same behavior passes.
- Test list is readable without a project-history decoder ring.

### Phase 7 — Fix weak/harmful assertions

Apply the required rewrites from "Tests requiring rewrite or deletion".

Recommended order:

1. Fix float exponent test.
2. Fix float format preservation test.
3. Fix float special sign test.
4. Fix inline table sealing comment/assertion mismatch.
5. Fix array clear roundtrip ambiguity.
6. Strengthen or delete writer token reuse test.
7. Improve fixture count checks.
8. Improve invalid corpus diagnostics.

Run after each small batch:

```bash
beefbuild -test
```

Acceptance:

- Tests still pass, or failures reveal real implementation bugs that must be triaged instead of papered over.

### Phase 8 — Final verification and reporting

Run:

```bash
beefbuild -test
```

For parser/serializer behavior changes, also run relevant acceptance scripts:

```bash
./test-toml.sh
./test-roundtrip.sh
```

Only run the shell scripts if the task changes behavior or corpus expectations. For pure test-file reorganization, `beefbuild -test` is enough.

Final report should include:

- files created
- files removed
- test count before/after
- weak tests rewritten/deleted
- remaining known weak tests, if any
- verification command output summary

## Acceptance criteria

The rework is complete when:

1. No single test file is a 4k-line blob.
2. Test files are grouped by feature/behavior.
3. Shared helpers live in one support file.
4. Historical phase names are gone or justified.
5. The listed harmful/weak tests are fixed, deleted, or explicitly documented as intentionally weak smoke tests.
6. Corpus test failures identify the specific file path.
7. `beefbuild -test` passes.
8. No upstream/reference directories were edited.

## Suggested final file checklist

Expected test files after rework:

- `src/TomlBeef/tests/TomlTestSupport.bf`
- `src/TomlBeef/tests/TomlCorpusTests.bf`
- `src/TomlBeef/tests/TomlReadTests.bf`
- `src/TomlBeef/tests/TomlStreamTests.bf`
- `src/TomlBeef/tests/TomlPreserveStyleMetadataTests.bf`
- `src/TomlBeef/tests/TomlPreserveStyleWriterTests.bf`
- `src/TomlBeef/tests/TomlPathTests.bf`
- `src/TomlBeef/tests/TomlInlineTableSealTests.bf`
- `src/TomlBeef/tests/TomlMutationApiTests.bf`
- `src/TomlBeef/tests/TomlResourceLimitTests.bf`

Expected removed file:

- `src/TomlBeef/TomlTest.bf`

Only remove `TomlTest.bf` after all tests have been moved and `beefbuild -test` passes.
