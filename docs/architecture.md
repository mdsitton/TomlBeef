# TomlBeef Architecture

This document describes how TomlBeef works today and why it was built that way. It is not a
history log or a task list. Open work and known gaps are tracked in [status.md](status.md).
User-facing API examples live in the top-level `README.md`.

## 1. Overview and goals

- A TOML parser and writer for the Beef language, covering **TOML v1.0.0 and v1.1.0**. Version is
  selected per read/write; the default is v1.1.
- **Linux64 is the primary target**; Windows is verified with the Proton-hosted Beef (`win-test.sh`).
- **Built on FormatCore** (https://github.com/mdsitton/FormatCore), the shared core of TomlBeef, KdlBeef, XmlBeef
  and JsonBeef: §1a lists what TomlBeef takes from it.
- **No garbage collector.** Every design choice around ownership exists to make lifetimes
  predictable under manual and scope-based memory management.
- **DOM model.** Every input path builds a full `TomlDocument` tree. There is no SAX/event API.
  Streaming only means the whole input does not have to be buffered in memory first.
- **Strict by default.** Invalid TOML is rejected with a located `TomlParseError`. Nothing tries
  to recover or be lenient.
- **Two write modes.** The normal writer produces canonical TOML. The optional `PreserveStyle`
  mode keeps comments and presentation hints. It aims to preserve style, not to reproduce the
  source byte for byte.
- Code conventions, Beef gotchas and doc-comment style are in `AGENTS.md`.

## 1a. FormatCore

FormatCore's `docs/architecture.md` describes each component; its `docs/migration.md` lists what each
sibling replaced. TomlBeef uses:

| FormatCore | In TomlBeef |
|---|---|
| `ByteCursor<TomlText>`, `BufferedStreamCursor<TomlText>`, `InputStart`, `Utf8.FindInvalid` | Input checks (size, UTF-16/32, BOM, UTF-8) for every read path; the stream window behind `TomlWindowCursor` (§5) |
| `Utf8`, `Hex` | Decoding, encoding, hex digits |
| `ParseError<TomlErrorKind>`, `Diagnostic<TomlErrorKind>` | `TomlParseError` and `TomlDiagnostic` are typealiases |
| `DecimalParse`, `IntegerText`, `ShortestDouble` | Plain-number fast paths and the culture-free float parse; PreserveStyle integer formats and the scientific float format (the canonical float stays on corlib's round-trip text: ShortestDouble measured 20% slower on float-heavy writes) |
| `OrderedMap`, `ByteHash` | Table entries (`TomlEntryMap`), the index seeded per table |
| `TextArena`, `ReadShell` | The metadata sidecar's text; `ReadFile` |
| `MappingDriver`, `Registry`, `Naming`/`NamingPolicy`, `Literal`, `IntegerBounds`, `TypeShapes` | The `[TomlObject]` generator (§8a): bodies in the mixin stage; `TomlKeyNaming` is `NamingPolicy` |
| Vendored scripts and bench-kit | `test-leaks.sh`, `win-test.sh`, `test-codegen.sh`, `tools/test-lib.sh`, `bench/instructions.sh`, `bench/compare/merge.sh`; AGENTS.md's shared rules |

## 2. Source layout

The library project is at the repo root (`BeefProj.toml`, `TargetType = "BeefLib"`). The
workspace startup project is `TomlTester/`.

| File (`src/TomlBeef/`) | Responsibility |
|---|---|
| `TomlDocument.bf` | Public entry point: `TomlReadMode`, `MergeConflict`, `TomlReadConfig`, `TomlWriteConfig`, and `TomlDocument` (read/write, file helpers, path lookup, typed path accessors and setters, transactional read/merge orchestration) |
| `TomlDocumentStore.bf` | Internal arena (`BumpAllocator`) that owns every string, table and array of a document |
| `TomlTextArena.bf` | Append-only text blocks for the metadata sidecar's comments and original tokens |
| `TomlValue.bf` | `TomlTableOrigin` enum and the non-owning `TomlValue` tagged union (`Is*`, `As*`, `TryGet*`, internal `CloneInto`, `IsSemanticallyEqualTo`) |
| `TomlTable.bf` | `TomlTable`: an ordered map (a `TomlEntryMap`) with internal origin and sealing flags, `Set`, `MergeFrom`, validation (`Require*`, `MakeError`), and the `TomlTableEntry` proxy |
| `TomlEntryMap.bf` | A table's entries (`TomlTableSlot`: key, value, metadata node ID) in insertion order: scanned up to 8 entries, hash-indexed past that |
| `TomlArray.bf` | `TomlArray` (static array or array of tables) and the `TomlInputValue` scalar-input wrapper |
| `TomlDateTime.bf` | `TomlOffsetDateTime`, `TomlLocalDateTime`, `TomlLocalDate`, `TomlLocalTime`, and the internal `TomlDateRules` (RFC 3339 validity: years 0–9999, real month lengths with leap years, times to 23:59:60, offsets within ±23:59) shared with the parser. Public fields; constructors assert the rules (a programming error is fatal), `Create` factories return `Result` for untrusted input |
| `TomlCursor.bf` | `ITomlCursor` interface, `TomlCursorMark`, and `TomlByteCursor` (zero-copy over contiguous bytes) |
| `TomlBufferedStreamCursor.bf` | `TomlBufferedStreamCursor` (fixed buffer, nested marks, spill) and `TomlStreamState` (incremental UTF-8 validation, I/O and size-limit flags) |
| `TomlParser.bf` | `TomlParserImpl<TCursor>`: fields, `Parse`, document loop, `[header]`s, key/value statements, key paths, whitespace skipping, error and limit helpers. The class is split across files with `extension TomlParserImpl<TCursor>`: |
| `TomlParser.Values.bf` | value dispatch, strings and escapes, booleans, bare tokens, numbers |
| `TomlParser.DateTime.bf` | offset/local date-times, dates and times |
| `TomlParser.Containers.bf` | arrays and inline tables |
| `TomlParser.Comments.bf` | comment skipping, capture, and attachment to nodes |
| `TomlParser.Style.bf` | PreserveStyle capture: source ranges, value/key/container formats, style counts, document style inference |
| `TomlPathResolver.bf` | Table-tree navigation for headers and dotted keys, implicit table creation, all structural conflict rules |
| `TomlResourceLimitState.bf` | Per-read limit counters and `Check*` helpers shared by the parser and the resolver |
| `TomlMetadataTransfer.bf` | Carries PreserveStyle metadata across a merge: attaches node IDs to copied subtrees and copies tokens, formats and comments between sidecars |
| `TomlMetadata.bf` | The Positions/PreserveStyle sidecar: `TomlMetadataMode`, node IDs, `TomlNodeStyle`, dirty flags, comment sets, format structs, `TomlContainerMetadataContext`, `TomlDocumentMetadata` |
| `TomlWriter.bf` | `TomlWriterImpl`: entry point and the normal (canonical) writer, plus shared value, string, date and key helpers. Split with `extension TomlWriterImpl`: |
| `TomlWriter.Preserving.bf` | the PreserveStyle writer: table walk, token reuse, per-node styles, dotted keys, arrays and inline tables, comments and blank lines |
| `TomlWriter.Formats.bf` | regenerating numbers and date/times from captured formats |
| `TomlChar.bf` | Internal character classes, UTF-8 decode/encode, and whole-buffer `ValidateUtf8` (with BOM handling) |
| `TomlError.bf` | `TomlErrorKind` and `TomlParseError` |
| `TomlVersion.bf` | `TomlVersion { V1_0, V1_1 }` |
| `TomlObjectAttribute.bf` | `[TomlObject]` (with `TomlKeyNaming`), `[TomlName]`, `[TomlIgnore]`, `[TomlRequired]`: compile-time serialization (section 8a) |
| `TomlSerializerCodeGen.bf` | The comptime generator behind `[TomlObject]`: classifies fields and emits `TomlRead`/`TomlWrite` source |
| `TomlBind.bf` | Runtime helpers the generated code calls, one per value kind (lookup, type and range checks, located errors) |
| `TomlSerializer.bf` | `TomlSerializer.Read`/`Write`, the entry points for `[TomlObject]` types |
| `ITomlSerializable.bf` | The interface `[TomlObject]` adds (`TomlRead`, `TomlWrite`) |
| `ITomlConverter.bf` | `ITomlConverter<T>`, `TomlConvertContext`, and the `[TomlConverter]` registration and `[TomlUseConverter]` field attributes |

Other locations: tests are in `src/TomlBeef/tests/`, the fixture corpus is in `tests/valid` and
`tests/invalid`, the CLI is `TomlTester/src/Program.bf`, and the acceptance scripts are
`test-toml.sh`, `test-roundtrip.sh`, `test-encoder.sh` and `test-official-toml.sh` (with `json-compare.py`). BJSON is a
package dependency of `TomlTester` and toml-test runs through `go run`; `recovery/` is forensic
material (see `AGENTS.md`).

## 3. Public API model

### TomlDocument entry points

| Operation | Methods |
|---|---|
| Read | `Read(StringView[, config])`, `ReadBytes(Span<uint8>[, config])`, `Read(Stream[, config])`, `ReadFile(path[, config])` |
| Write | `Write(String output[, TomlWriteConfig])` appends and never fails; `WriteFile(path[, config])` returns `IoError` on failure |
| Lookup | `Get(dottedPath)`, `this[dottedPath]`, `GetPath(params StringView[])`, `GetPath(List<StringView>)`, `TryGetString/Integer/Float/Bool/Table/Array/OffsetDateTime/LocalDateTime/LocalDate/LocalTime(path, out v)` |
| Mutation | `Set{String,Integer,Float,Bool,OffsetDateTime,LocalDateTime,LocalDate,LocalTime}(path, v)`, `AddTable(key)`, `AddArray(key)`, `Remove(key)`, `Clear()` |
| Inspection | `RootTable` (read-only property), `Metadata` (null unless PreserveStyle) |

- Overloads without a config use the document's own `ReadConfig` / `WriteConfig` fields (there is no
  process-global default, so documents on different threads never share settings).
- `ReadFile` loads the whole file (`File.ReadAll`) and parses the bytes with `ReadBytes`, without a
  second copy. With `TomlReadConfig.StreamBufferBytes` set it instead opens a `FileStream` and uses
  `Read(Stream)`, so input memory stays bounded by the buffer. Any BOM goes through the normal BOM
  rules; a missing or unreadable file is `IoError`.
- `Get`, `GetPath`, the document's `this[dottedPath]` (get-only: a Beef indexer's setter takes the
  getter's `Result` type, and `Set` already writes), `TomlTable.Get`/`TryGetValue`/`GetValueAt`/`this[key]` and
  `TomlArray.GetValueAt` return a borrowed `TomlValue` of any type, for generic walking (the
  `TomlTester` serializer uses them). Typed `TryGet*` accessors are preferred when the type is known.
- Document setters (`Set`, `AddTable`, `AddArray`) resolve every path segment except the last and
  create missing intermediate tables (as `AddTable` would: written as `[header]` tables). A segment
  that exists but is not a table fails the call. `Remove` never creates tables.

### Configuration

`TomlReadConfig`: `Mode` (`Replace` by default | `Merge`), `OnConflict` (`Error` by default |
`Skip` | `Overwrite`), `Version` (`V1_1` by default), `MetadataMode` (`None` by default |
`Positions` | `PreserveStyle`), plus the resource limits in section 6. `TomlWriteConfig`: `Version` only.

### Replace vs Merge, and failure guarantees

- **Replace** clears the document and parses directly into its store. On any failure (UTF-8,
  size limit, I/O, parse or resolver error) the document is `Clear()`ed, so it is **left empty**.
- **Merge** into an empty document behaves like Replace, because nothing needs preserving.
- **Merge** into a non-empty document parses into a **temporary `TomlDocumentStore`**. Only after
  that parse fully succeeds does `TomlTable.MergeFrom` deep-merge the incoming tree into the real
  store (`CloneInto`). A parse failure therefore leaves the **existing content unchanged**.
- **Merge is deep**, designed for layering config files (defaults, then site, then user):
  - A table present on both sides is merged recursively; that is never a conflict.
  - Everything else is a **leaf**: scalars, whole arrays, whole arrays of tables, and type
    mismatches (table vs value, array vs table). Arrays are replaced, never merged element-wise or
    appended, because element-wise merging has no unambiguous meaning and overrides of `[[x]]`
    lists are expected to redefine them.
  - Only a leaf present on both sides conflicts: `Error` fails, `Skip` keeps the existing leaf,
    `Overwrite` replaces it with a deep copy (the whole subtree, on a type mismatch).
  - An existing table keeps its origin, so a base-file inline table can gain keys from an override
    `[header]` and is still written inline.
- `MergeFrom` makes two passes. With `OnConflict = .Error`, `ValidateMerge` first walks the whole
  incoming tree and fails with `DuplicateKey` **before changing anything**. The message names the
  conflicting dotted path in document path syntax (e.g. `server.port`, `a.[b.c].x`); the position
  is 0:0 because the conflict has no single source location. `ApplyMerge` then inserts, recurses,
  and resolves leaves.
- A merge **keeps the destination's PreserveStyle metadata** and carries style across
  (`TomlMetadataTransfer`). New keys, including new keys inside shared tables, get destination node
  IDs throughout their copied subtree. When the incoming document was also read with PreserveStyle,
  each merged node takes the incoming original token, value/key formats and comments, and is clean,
  so it is written exactly as the incoming file had it. An `Overwrite` takes the incoming value style
  but keeps the destination slot's key format and comments. Without incoming metadata, new nodes use
  default styling and overwritten values are marked dirty (regenerated in the slot's format). The
  destination's document-wide style is kept. The public `TomlTable.MergeFrom` behaves the same way,
  finding the source sidecar through the source table's context.

### Tables, arrays and entries

- `TomlTable` keeps insertion order (`GetKeyAt`, `GetValueAt`, `Count`, `ContainsKey`,
  `TryGetValue`, `Get`, `this[StringView]`). It has typed `TryGet*(key, out v)` readers, one
  `Set(key, TomlInputValue)` setter (insert or replace), `AddTable`/`AddArray` (return null if the key
  exists), `Remove`, `Clear` and `MergeFrom`.
- `table[i]` returns a `TomlTableEntry` struct proxy (table plus index). It provides `Key`, typed
  `TryGet*`, `Value = <scalar>` assignment, `SetTable()`/`SetArray()` (replace with a new empty
  container), `Rename(newKey)` (keeps the position and the metadata node ID; fails with
  `DuplicateKey` on a collision), `Remove()`, and `GetValue()` (the borrowed `TomlValue`).
- `for (let entry in table)` yields those proxies in insertion order (`TomlTableEnumerator`) and
  `for (let value in array)` yields borrowed `TomlValue`s (`TomlArrayEnumerator`). Assignments and
  renames during iteration are fine; adding or removing keys/elements is a fatal error because the
  index-based enumerators would skip or repeat entries.
- `TomlArray` provides `Add(TomlInputValue)`, `AddTable()`, `AddArray()`, index
  assignment `arr[i] = <scalar>`, `SetTable(i)`/`SetArray(i)`, `RemoveAt`, `Clear`, typed
  `TryGet*(index, out v)`, and `IsArrayOfTables` (true for `[[...]]` arrays of tables; the
  internal `IsStatic` flag is its inverse). Reading through the indexer is a fatal error, so reads go through `TryGet*`,
  or `GetValueAt(i)` for elements of unknown type (mirrors `TomlTable.GetValueAt`).
- `TomlInputValue` is a scalar-only struct with implicit conversions from `StringView`, `int64`,
  `double`, `bool` and the four date/time structs. It is the single input type for every scalar
  setter (`Set`, `Add`, `arr[i] =`, `entry.Value =`), so there are no per-type setters. Callers
  never build a `TomlValue` or a container themselves. The value is materialized into the
  document's store on assignment.
- Programmatic `TomlTable.AddTable` creates an `ExplicitHeader`-origin table, which is written as
  `[header]`. `TomlTableEntry.SetTable` creates an `InlineTable`-origin table.
  `TomlArray.AddTable`/`SetTable` create `ArrayElement` tables.

### Path syntax

Used by `TomlDocument.Get`, the `TryGet*` path accessors and the path mutators `Set`, `Remove`,
`AddTable` and `AddArray` (`TomlDocument.ParseDottedPath`). `Set`, `AddTable` and `AddArray`
create missing parent tables; `Remove` does not. Segments are split on `.` outside brackets. A segment that
itself contains dots must be wrapped in `[...]`.

| Input | Segments | Result |
|---|---|---|
| `a.b.c` | `a`, `b`, `c` | valid |
| `a.[b.c]` | `a`, `b.c` | valid |
| `[a.b]` | `a.b` | valid |
| `a.[b]` | `a`, `b` | valid |
| `a..b`, `.a`, `a.` | | invalid (empty segment) |
| `a.[b`, `a.b]` | | invalid (unmatched bracket) |
| `a.[].b` | | invalid (empty bracketed segment) |
| `a.[b]c` | | invalid (a bracket must be followed by `.` or the end) |

The path syntax deliberately has no escapes, no quoted-string segments and no nesting, so a key
containing `]` cannot be reached with a path string. Use `GetPath(segments...)` or single-key
`TomlTable` APIs for such keys; `GetPath` takes segments as exact keys, so it also reaches the
empty key (`"" = 1`), which a path string cannot express. Segments borrow from the input path.

## 4. Ownership and lifetime model

- **`TomlDocumentStore`** owns a `BumpAllocator(.Allow)`. Every string payload, `TomlTable` and
  `TomlArray` of a document is allocated with `new:mAlloc` through `NewString`, `NewTable(origin)`
  and `NewArray()`; table keys are plain bytes (`NewKey`, no `String` object). `.Allow` records
  destructors, so each table's entry and index arrays and each array's item list are freed when the
  arena is deleted. `Reset()` deletes the arena, creates a fresh one, and allocates a new root
  table. The arena's pools go back to a cache the store keeps rather than to the system, and the
  next arena takes them from there: reading into the same document again reuses the memory, where
  freeing it let glibc trim the heap and every page fault back in on the next parse (296,000 page
  faults against 7,000 over a `strings` benchmark run, 40% of parse time). The cache never holds
  more than the pools of the largest document read, and is freed with the document (or earlier
  through `ReleaseCachedMemory`, which frees only the cached pools, so live values never move).
- **`TomlValue` is a non-owning tagged union.** Scalars and date/times are stored inline;
  `.String(StringView)`, `.Array(TomlArray)` and `.Table(TomlTable)` are borrowed references into
  the arena. `TomlValue` has no `Dispose`, and copying one is always safe.
  - String text is plain arena bytes (like keys), exposed as a `StringView`. An earlier `String`
    payload let callers mutate document text through pattern matching, bypassing the setters' dirty
    tracking (the writer then reused the stale original token) and reallocating under views others
    held; it also cost a `String` object per value. Text changes go through `Set`, which copies.
  - *Why:* an earlier design made `TomlValue` own its payload and have `Dispose()`/`Clone()`, and
    later added parallel `TomlValueView`/`TomlTableView` types. Because Beef structs copy freely
    and have no destructors, any accessor that returned a `TomlValue` gave callers a way to
    double-free or re-own document memory. Moving every payload into the document arena removed
    that whole class of bug and made the view types unnecessary.
- **Replaced and removed payloads are not freed individually.** They stay in the arena until
  `Clear()` or `delete doc`. This keeps any borrowed `TomlValue` or `StringView` a caller already
  holds valid (though possibly stale). The cost is that memory grows under heavy repeated
  mutation of one document. There is no compaction.
- `Set` skips allocation (and dirty marking) when the new scalar equals the existing value, to
  avoid churning the arena.
- **Containers can only be created by the store.** `TomlTable`/`TomlArray` constructors are
  `internal`, and every container carries `mStore`, so a container can always allocate children in
  the right arena. Raw `TomlValue` insertion (`TomlTable.Insert`, `ReplaceValue`,
  `TomlArray.Add(TomlValue)`) is `internal` for the same reason.
- **`CloneInto(store)`** on `TomlValue`, `TomlTable` and `TomlArray` is the only deep-copy path.
  It re-allocates strings and containers in the target store and keeps table origin, inline
  sealing and `IsStatic`. `MergeFrom` uses it, so after a merge the temporary source store can be
  deleted safely. `TomlTable.MergeFrom` is also the public cross-document copy (clone a document
  into a cleared one, or copy a table under a new `AddTable` key); a separate clone API was judged
  redundant.
- `TomlParseError` owns nothing. Its constructor copies the message into a per-thread `String`
  (`LazyTLS`, freed at thread exit) and `mMessage` views it, so the text is valid until the next
  error is constructed on that thread. A message built from a previous error's view is copied
  through a temporary first.
  - *Why:* errors used to own a heap `String` and need `Dispose()`. Forgetting it, matching
    `case .Err` without binding, or using `Try!` leaked the message. A document-owned message
    would not survive `TomlDocument.Parse` deleting the document on failure, and an inline buffer
    in the struct either costs a few hundred bytes per `Result` or truncates key paths. The
    per-thread rule matches `errno`-style APIs: copy the message to keep it past another failure.
  - The library never builds an error it then discards, apart from the stream paths that replace
    a secondary parse error with the cursor's own cause, so an error seen by the caller is always
    the most recent one on its thread.
- Positions/PreserveStyle metadata (`TomlDocumentMetadata`, per-container
  `TomlContainerMetadataContext`) lives on the normal heap, not in the arena. The document owns it and deletes it on `Clear`, on
  Replace, and after a non-empty merge.

## 5. Parsing pipeline

```
Read(StringView) / ReadBytes / ReadFile ─► FormatCore ByteCursor<TomlText>.Begin (size, encoding, BOM, UTF-8) ─► TomlMemoryCursor ─┐
Read(Stream) ─► TomlWindowCursor<BufferedStreamCursor<TomlText>> (same checks; each refill UTF-8 checked) ─────────────────────────┤
                                                                                                                                ▼
                            TomlParserImpl<TCursor>.Parse(cursor, TomlPathResolver) ─► TomlTable tree in a TomlDocumentStore
```

- **Input checks are FormatCore's on every path**, so memory and stream input report the same first
  error: MaxInputBytes, UTF-16/32 input (`UnsupportedEncoding`, named), one BOM skipped (a second one
  is `ControlCharInDocument`), UTF-8 per Unicode table 3-7 at the sequence's lead byte. A stream's
  input error (I/O, size, MaxTokenBytes, UTF-8) stops its window and takes precedence over whatever
  the parser then reports.
- **`TomlWindowCursor<TInput>`** is the stream cursor: the `ITomlCursor` API over a window of
  FormatCore's input cursor (`data[offset]` for the window, absolute offsets). Marks keep their span
  in the window, which grows for a long one (no spill copy); `MaxTokenBytes` is a hard limit on a
  marked span plus the lookahead the parser asks for. Lines are counted as the parser crosses line
  breaks, columns on request (SWAR past 32 bytes) from the line start or the last answer, a base the
  cursor moves forward before a refill drops the line's start. It made stream reads 20-68% cheaper.
- **`TomlMemoryCursor`** reads memory input after FormatCore's checks: the window cursor over a
  ByteCursor measured 2-8% more on document reads, spread across the parser rather than one cause.
- **The parser fails with an empty token** (`TomlFailure`, KdlBeef's/XmlBeef's/JsonBeef's pattern): the
  parser, path resolver and limit checks return `Result<T, TomlFailure>` and the error is kept once per
  thread when it is made (`TomlFailure.Raise`); `Parse` hands it out. `TomlFailure` has a byte field on
  purpose: Beef converts any struct to an empty struct implicitly, which compiled
  `.Err(TomlParseError(...))` into a silently dropped error.

### Cursor abstraction

- `ITomlCursor` provides byte peeks (`PeekByte`, `PeekByte(n)`, `PeekByteAt(n)`),
  `AdvanceByte` (treats CRLF as one newline), `Advance` (decodes one UTF-8 scalar),
  `SkipWhitespace`, `SkipNewline`, `Offset`/`Line`/`Column`/`IsEOF`, and the mark API:
  - `Mark()` begins a retained region. Marks **nest**: each `Mark()` must be released exactly once,
    innermost first, by either `Slice(mark, scratch)` (returns the text from the mark to the
    current position and releases the mark) or `ReleaseMark(mark)`.
  - A slice is only valid until the cursor next advances or peeks. The parser uses it immediately
    or copies it.
- `ScanRun(stopMask, appendTo)` is the bulk path: it advances over a run of bytes whose
  `TomlChar.ScanClass` has none of the mask's bits (`StopBasicString`, `StopLiteralString`,
  `StopComment`, `StopBareKey`, `StopBareValue`), appending them to a string in one copy. Every
  class stops at `\r` and `\n`, so a run never crosses a line: cursors only add the run's code-point
  count (non-continuation bytes) to the column. The stream cursor continues a run across refills.
  Keys, string bodies, comments and bare values are scanned this way; the per-byte loops only handle
  the stop byte (quote, escape, newline, control character). Strings are copied as raw bytes, which
  is safe because both paths validate UTF-8 (the whole input up front, or each refill).
- The parser avoids per-key and per-string allocations: key paths come from a per-nesting-level
  pool of `TomlKeyPathBuffer`s (list and Strings reused), and string values are decoded into one
  reused scratch buffer before the single copy into the store.
- **Generic, not virtual.** The parser is `TomlParserImpl<TCursor> where TCursor : ITomlCursor`,
  and cursors are structs with `[Inline]` hot methods. The interface is only a compile-time
  constraint, so peek/advance calls are never virtual. `TomlDocument.ReadWithCursor<TCursor>` is
  the shared driver.
- **`TomlByteCursor`** wraps a `Span<uint8>` and is zero-copy. `Slice` returns a view into the
  caller's input, and marks cost nothing.
  - It tracks lines eagerly (they change only at line breaks) but computes the **column on
    demand**. It keeps the offset where the current line starts and counts code points from there
    when `Column` is read. Reads are inline and free at a line start, which is where most statements
    begin. A one-entry cache (offset, column) continues from the last answer on the same line, so
    repeated reads along one long line (array elements with positions) stay linear. The input is
    valid UTF-8 (checked first), so a code point is any byte that is not a continuation byte.
  - This matches go-toml and toml_edit, which keep only offsets and compute positions on error.
    Per-byte column counting had kept every scan byte-at-a-time. Without it, `ScanRun` is a bare
    stop-class loop and `SkipWhitespace` only moves the offset.
  - The change was verified by running the old counter alongside for the full test suite and
    corpus (valid and invalid, both versions) with a Debug assertion that the two always matched.
  - Same-build A/B (2026-09-28, MB/s, plain / PreserveStyle): comment-only 1240 → 1780 /
    543 → 634, commented config 407 → 442 / 221 → 237, strings 395 → 431 / 256 → 244. Shapes
    whose parse cost lies elsewhere moved within ±7% from code-layout changes in the parser
    (for example ints 111 → 103, with `LooksLikeDateTime`/`ParseBareToken` taking more of the
    profile though untouched).
  - `TomlBufferedStreamCursor` still counts columns per byte: the start of the line may already
    have left its buffer.
  - With columns gone from the scan, `ScanRun` tests comment and string text **eight bytes at a
    time** (`ScanTextRun`, the go-toml technique). A word test flags any byte below 0x20, DEL, or
    the string's quote and backslash. Only a flagged word is walked byte by byte, which either
    stops or steps past a tab. Bytes 0x80 and up are never stops, since the input is UTF-8 checked
    first. `ScanRun_WordAtATimeMatchesByteLoop` checks every byte value at every position against
    the byte loop. Same-build A/B against the build before on-demand columns (MB/s, plain /
    PreserveStyle): comment-only 1220 → 2900 / 533 → 680, commented config 397 → 547 / 222 → 257,
    strings 397 → 508 / 256 → 270, mixed 88 → 93 / 51.5 → 54.
- **`TomlBufferedStreamCursor`** uses a fixed buffer of `TomlReadConfig.StreamBufferBytes` bytes
  (default 8192, minimum 16 because the parser peeks a few bytes ahead; tests use 64 to force
  refills) plus a spill `String`.
  - `mMarkDepth` counts active marks. `mRetainStart` is the absolute offset of the **outermost**
    mark. While any mark is active, bytes from `mRetainStart` onward are retained.
  - On refill, `CompactForRefill` shifts the retained bytes to the front of the buffer. If the
    retained region plus the requested lookahead no longer fits, the consumed part is appended to
    `mSpill`, so the spill always holds `[mRetainStart, mBaseOffset)` and stays contiguous with the
    buffer. The buffer never grows.
  - `Slice` returns a direct buffer view when the mark is still buffered. Otherwise it joins the
    spill suffix and the buffered prefix into `scratch`. Releasing the last mark clears the spill.
  - Nesting matters because PreserveStyle marks a scalar value's whole token while inner string,
    key and number parsing take their own marks. Arrays and inline tables are never marked: they
    record their layout at their own separators as they are parsed (see
    [PreserveStyle layout](#preservestyle-layout)), so a long container is not retained.
  - `MaxTokenBytes` bounds the retained span (`CheckRetainedBytes`). It is checked before a refill,
    against the outermost mark, which is the only time the spill grows, so the spill never exceeds
    the limit. It is also checked in `Slice`, which catches spans shorter than the buffer. A breach
    fails the stream like an input-size overflow, recording the position where it was detected.
    `TryGetStreamError` then reports it instead of the parser's secondary error. In-memory cursors
    retain nothing, so the limit is stream-only.
- **UTF-8 validation differs by path:**
  - String, bytes and file input: `TomlChar.ValidateUtf8` checks the whole buffer before parsing
    (lead bytes, continuation bytes, overlongs, surrogates, values above U+10FFFF) and reports
    `InvalidUtf8` with its line, column and offset. The check itself (`IsValidUtf8`) tracks no
    position and skips ASCII 8 bytes at a time. Only when it fails does `LocateUtf8Error` re-scan
    with line and column tracking to build the error, so errors are unchanged. The per-byte position
    tracking had made this pass 12–34% of a parse on comment-heavy input (it ran over every byte).
    With the fast pass it is under 5%, and on string input comment-only files parse ~2.4× faster
    plain (~490 → ~1190 MB/s) and ~1.6× with PreserveStyle (~316 → ~502). A single-pass validator
    inside the cursor (formerly O5) would now save little.
  - Stream input: `TomlStreamState` validates bytes incrementally as each `Refill` brings them in,
    including sequences split across refills and a sequence truncated at EOF. It records the first
    error position (the lead byte of a bad sequence).
  - After a stream parse finishes, stream-level state wins over any parser error, in this order:
    size limit exceeded (`ResourceLimitExceeded`), then read error (`IoError`), then
    `InvalidUtf8`. Parse errors caused by truncated or garbage bytes are never reported in their
    place.
- **BOM:** exactly one leading UTF-8 BOM is skipped. Line and column restart at 1:1 after it
  while byte offsets stay raw (they count the BOM) on every input path; the byte cursor starts at
  offset 3 instead of slicing the BOM off. A
  second BOM right after it fails with `ControlCharInDocument`, and the parser rejects a BOM
  anywhere else in the document.

### Parser (`TomlParserImpl<TCursor>`)

- A recursive-descent, byte-oriented document loop handles whitespace, comments, newlines,
  `[header]`/`[[header]]` and key/value lines. It rejects bare CR and control characters, and
  requires a newline or comment after a key/value pair and after a header.
- A value is dispatched on its first byte: `"`/`'` (strings, including the multi-line forms),
  `[` (array), `{` (inline table), `t`/`f` (bool). Anything else is scanned as a **bare token**
  and classified as a date/time, float, or integer (dec/hex/oct/bin, with underscore, leading-zero
  and overflow checks). Keys are parsed separately, so `3.14 = 1` is the dotted key `3`→`14` and
  never a float.
- Strings are decoded into a scratch `String` and copied into the store with `NewString`.
- For every statement the parser builds the key path, parses the value, and hands both to the
  resolver. Before that it calls `SyncPathResolver()`, so **resolver (semantic) errors report the
  start of the statement**: the key start or the header `[`.

### Path resolver (`TomlPathResolver`) and table origins

The resolver owns the "current table" and every rule about how tables may be defined or
extended. Each table records a `TomlTableOrigin`:

| Origin | Created by |
|---|---|
| `Root` | the document root |
| `Implicit` | intermediate segments of a dotted key (`a.b.c = 1` creates `a` and `b`) |
| `ImplicitHeaderSuper` | intermediate segments of a header (`[x.y.z]` creates `x` and `y`) |
| `ExplicitHeader` | the last segment of `[header]`, or programmatic `AddTable` |
| `InlineTable` | `{ ... }` and the dotted sub-tables inside it, or `TomlTableEntry.SetTable` |
| `ArrayElement` | each `[[header]]` element, or `TomlArray.AddTable` |

Rules enforced (`EnterTable`, `EnterArrayOfTables`, `SetKeyValue`, `NavigateSegment`,
`DefineTable`, `DefineArrayOfTables`, `InsertKeyValue`):

- `[x]` twice fails with `DuplicateTable`. A header on a table created by dotted keys
  (`Implicit`) or on an inline table also fails with `DuplicateTable`.
- A header on an `ImplicitHeaderSuper` table is allowed once and **upgrades** it to
  `ExplicitHeader` (for example `[x.y.z]` followed by `[x]`). A header on a sub-table of an
  implicit table is allowed (`[fruit.apple.texture]` after `apple.color = ...`).
- Dotted keys cannot extend a table that was opened by a `[header]` elsewhere, and cannot step
  into an array of tables. Both fail with `TypeConflict`.
- Header navigation through an array of tables goes into its **last element**. An empty array of
  tables fails with `ArrayElementOrdering`.
- `[[x]]` on a static array (`x = []`) fails with `AppendToStaticArray`. `[x]` against an array,
  `[[x]]` against a table, and a scalar used as a table all fail with `TypeConflict`. A key
  defined twice fails with `DuplicateKey`.
- **Inline-table sealing:** after an inline table closes, `SealInlineRecursively()` seals it and
  every `InlineTable`-origin descendant, including sub-tables created by dotted keys inside the
  braces and inline tables that are elements of arrays. Adding keys or sub-tables to a sealed
  table afterwards fails with `InlineTableSealed` (or `DuplicateTable` from a header). Recursive
  sealing was needed because `{ name.first = "x" }` creates a nested table that the outer seal
  alone would not cover.
- The resolver also runs the limit checks for tables and nodes it creates. With metadata (Positions
  or PreserveStyle) it allocates node IDs for headers, array-of-tables elements and key/value
  entries, and passes each to `TomlTable.Insert`, which registers it under the table's own key.

### Error model

`TomlParseError { mKind, mMessage, mSource, mLine, mColumn, mOffset, mLength }`. Line and column
are 1-based (line 0: no position) and `mOffset` is a byte offset. `mSource` names the input: the
public `Read*` methods tag a failed read with `TomlReadConfig.SourceName` unless the error already
names one (`WithSource`), `ReadFile`/`WriteFile` use the path, and `ToString` formats
`source:line:column: message`. The same type carries validation errors built from a document
(`MakeError`, `Require*`), located through the node ranges, so parse, merge and validation errors
print alike. A merge read rejected for a conflicting leaf is located at the incoming key when the
incoming side has positions. `TomlErrorKind` groups:

- lexical: `UnexpectedChar`, `UnexpectedToken`, `UnterminatedString`, `InvalidEscape`,
  `ReservedEscape`, `InvalidUnicodeScalar`, `ControlCharInString`, `ControlCharInDocument`,
  `InvalidUtf8`
- numeric: `InvalidInteger`, `IntegerOverflow`, `InvalidFloat`, `LeadingZero`,
  `InvalidUnderscore`
- date/time: `InvalidDateTime`, `InvalidDate`, `InvalidTime`
- structural: `DuplicateKey`, `DuplicateTable`, `TypeConflict`, `InlineTableSealed`,
  `AppendToStaticArray`, `ArrayElementOrdering`, `MaxDepthExceeded`, `ResourceLimitExceeded`
- document: `MissingNewlineAfterKeyVal`, `EmptyBareKey`, `InvalidKey`
- `IoError`
- validation: `MissingKey`, `WrongType`, `InvalidValue`

Where each error is reported:

- Lexical errors: the cursor position of the offending byte.
- Resolver errors: the start of the statement.
- UTF-8 errors: the validator's position.
- Stream I/O errors, stream size-limit errors, merge conflicts, and mutation-API errors (a bad
  path, `Rename` onto an existing key): 0:0:0, because they have no source position.
- A `MaxInputBytes` failure on string or bytes input: 1:1:0.

## 6. Resource limits

`TomlReadConfig` fields. `0` means unlimited for every field, including `MaxDepth`, whose default
is 256. Each read creates one `TomlResourceLimitState`, which the parser and resolver share.
Limits therefore count only the incoming document (in Merge mode too) and never apply to
programmatic mutation. The user-facing table is in `README.md`.

| Limit | Counted | Enforced in |
|---|---|---|
| `MaxInputBytes` | raw bytes, including the BOM | `Read`/`ReadBytes` before validation. `ReadFile` after loading the file. The stream path in `Refill` through `TomlStreamState` |
| `MaxDepth` | depth of every container (table or array) counted from the root, whatever built it; scalars do not count | the resolver's `Descend` as a header walks (one level per table segment, two per array of tables: the array and its element), `ParseKeyPath` per segment (a dotted key's parent tables below `mTableDepth`), and `ParseArray`/`ParseInlineTable` → `CheckDepth` at `mValueDepth` (fails with `MaxDepthExceeded`) |
| `MaxStringBytes` | bytes of a decoded string value (keys excluded) | string loops as the string grows (`ScanRun` stops one byte past the limit), and `FinishStringValue` as a backstop |
| `MaxArrayItems` | elements of one array, including `[[...]]` elements | array parser before each element is parsed, `DefineArrayOfTables` |
| `MaxTableEntries` | keys of one table: root, header, inline, dotted-implicit | before any key's value is parsed, on the table that would take the new entry (`TomlTable.TableForNewEntry`: the current table, or a parent along a dotted path), and `CheckCanAddEntry` as the resolver inserts |
| `MaxPathSegments` | segments of a dotted key or header | `ParseKeyPath`, before each segment |
| `MaxNodes` | every value node: scalars, arrays, tables (explicit, implicit, inline, array elements); the root is not counted | `ParseValue` plus each table or array the resolver or inline parser creates (`a = [1, 2]` is 3 nodes and `a.b.c = 1` is 3) |

Every limit error is `ResourceLimitExceeded`, except depth, which is `MaxDepthExceeded`. The
normal Replace/Merge failure guarantees apply.

Limits are checked before the work they bound, so an oversized input fails where it crosses the
limit rather than after building the oversized part (a megabyte string under `MaxStringBytes = 8`
stops after nine bytes). `MaxDepth` counts the resulting tree, not the syntax, because sealing,
writing, cloning and merging walk it recursively: counting only value nesting let `v = {a.a.a…=1}`
or a long header build a tree deep enough to overflow the stack in those walks, and counting key
segments separately still missed arrays below headers (`[a]` then `v = [[]]`) and the element level
of arrays of tables. So there is one measure: the parser tracks the depth of the table receiving keys
(`mTableDepth`, from the resolver for headers) and the depth a value would take as a container
(`mValueDepth`), and every container is checked before it is built. With `MaxDepth = 0` the depth
is the caller's responsibility.

## 7. TOML 1.0 vs 1.1 as implemented

Every parser gate checks `mVersion == .V1_0`. The gated features are all v1.1 additions:

| Feature | v1.0 | v1.1 | Where |
|---|---|---|---|
| `\e` escape | `ReservedEscape` | ESC (0x1B) | `ParseEscapeSequence` |
| `\xHH` escape | `ReservedEscape` | accepted | `ParseEscapeSequence` |
| Omitted seconds (`HH:MM`) in times and date-times | `InvalidTime` | accepted, seconds = 0 | `TryParse{Offset,Local}DateTime`, local time |
| Newlines and comments inside inline tables | rejected | accepted | `ParseInlineTable` via `SkipInlineTableWs` |
| Trailing comma in an inline table | `UnexpectedToken` | accepted (recorded as `mHasTrailingComma`) | `ParseInlineTable` |

Writer downgrades when `TomlWriteConfig.Version = .V1_0`:

- ESC is written as `\u001b` instead of `\e`. Other control characters are always written as
  `\u00XX`; the writer never emits `\x`.
- PreserveStyle always writes seconds (normal mode always does anyway).
- Multi-line inline tables are written on one line.
- PreserveStyle does not reuse an original string token containing `\e` or `\x` when writing
  1.0 (`IsTokenValidForVersion`); the string is regenerated instead.

The test corpus follows the same split: fixtures under `tests/invalid/spec-1.1.0/` are rejected
under v1.1, and all other invalid fixtures under v1.0.

## 8. Writer

`TomlWriterImpl.Write` picks the preserving path when `doc.Metadata != null`. Otherwise it uses
the normal path. Output is appended to the caller's `String`, and writing never fails.

### Normal mode (canonical)

- Each table is written in **three phases**: (1) scalars, inline-origin tables and static arrays
  as `key = value`, and tables created by dotted keys (`Implicit` origin) as dotted lines
  (`WriteLines`); (2) other sub-tables as `[full.path]` headers, recursively; (3) arrays of
  tables as `[[full.path]]` blocks. Array-of-tables output comes last so that its elements do not
  absorb the parent's keys. As a result, output can be reordered compared with the source, even
  though every table keeps insertion order.
- **Output stays linear in the input.** Two rules keep it that way; before them, 8 KB of dotted
  keys wrote 16 MB:
  - Dotted-key tables are written back as dotted lines. Their `[header]` descendants still get
    full-path headers in phase 2 (`WriteTable` with `writeLines: false`). Writing them as headers
    would repeat the enclosing header's path once per table, so a long header followed by N dotted
    sub-tables would cost path length × N. Only the parser creates `Implicit` tables (API tables
    are `ExplicitHeader`), so documents built in code keep their headers. A dotted-key table emptied
    in code is written as `a.b = {}`, so it does not disappear.
  - A table's header is left out when it has no lines of its own and a sub-table header defines
    it implicitly (`IsHeaderImplied`: `[a.b.c]` defines `a` and `a.b`). Otherwise a deep key writes
    cumulative `[k]`, `[k.k]`, … headers. A table with no content and no sub-table headers keeps its
    header.
  - The header path is one shared buffer, appended and truncated per level, so deep documents
    need no per-level copies.
- An empty array of tables (non-static, `Count == 0`) has no `[[header]]` form, so it is written in
  phase 1 as `key = []`.
- Keys are bare when every character is a bare-key character; otherwise they are written as basic
  quoted strings.
- Strings are basic, except that a value with a backslash or double quote is written as a literal
  string when one can hold it (no `'`, no control characters, tab included), so Windows paths and
  regexes stay readable (`PrefersLiteral`). Integers are decimal, and floats use roundtrip `"R"` formatting (with `.0`
  appended when needed). `inf`/`-inf`/`nan` and `-0.0` are kept. Times always include seconds and
  trim trailing zeros from the fraction. An offset of 0 is written as `Z`. Nested containers are
  written inline.

### PreserveStyle mode

The metadata is a **sidecar**, so normal mode pays nothing for it. It is entirely `internal`: callers
see only `doc.PreservesStyle`, `doc.HasSourcePositions` and the comment/style/source-range methods,
whose public types are `TomlMetadataMode`, `TomlStringStyle`, `TomlIntegerBase` and
`TomlSourceRange`. Tests reach the sidecar through `using internal TomlBeef;`.

**Positions mode** uses the same sidecar but captures only node IDs and source ranges. The parser
keeps two references to it: `mMetadata` (set in both modes) for node IDs and ranges, and `mStyle`
(set only in PreserveStyle, `TomlDocumentMetadata.CapturesStyle`) for comments, tokens, formats and
document style, so style code keeps its plain null checks and Positions skips the cursor marks and
slices too. The writer's preserving path and the comment/style setters require `CapturesStyle`;
`TryGetSourceRange` accepts any sidecar. A sidecar's mode only upgrades (`Upgrade`): reading or
merging with a more capable mode raises it, a lesser one never lowers it.
  - *Cost:* on a 5 MB synthetic file (`TomlTester -bench`, one Release run) a plain read takes
    ~109 ms / 81 MB peak RSS, Positions ~121 ms / 96 MB, PreserveStyle ~156 ms / 121 MB. Node
    storage is laid out for this (below): the node ID lives in the table's entry slot, ranges are a
    compact array, and style records exist only in PreserveStyle. Before that layout the shared
    per-node machinery dominated both modes (Positions ~140 ms / 146 MB).

`TomlDocumentMetadata` holds:

- Source ranges (`mRanges`, `TomlPackedRange`: 32-bit line, column, offset, length) indexed by
  `TomlNodeId`, one per allocated node in every mode: the start of the key, header `[`, or array
  element, and the length through the value or header. Exposed through
  `TryGetSourceRange`/`TryGetHeaderSourceRange`, and left unset for values added in code. Each range
  also records its source: an index into `mSourceNames`, registered per read from
  `TomlReadConfig.SourceName` (`ReadFile` defaults it to the path). Merges copy ranges with their
  source (`CopySourceRange`), so a document layered from several files reports each value's own file.
- `TomlNodeStyle` records, also indexed by `TomlNodeId`, only while capturing style: an
  original-token reference, dirty flags, and key-format and value-format references (16 bytes).
  `GetNodeStyle` returns null without style capture; after an upgrade from Positions it creates the
  missing records for earlier nodes on first access. A document merged from a PreserveStyle read is
  upgraded *before* the merge so the copied styles have records to land in (and restored if the
  merge is rejected).
- Copies of original tokens (`mOriginalTokens`). **Source spans are never used to recover text**,
  because the input buffer or stream is gone after the parse.
- `mText`, a `TomlTextArena` holding the text of original tokens and comments. Text is appended into
  16 KB blocks that never move, so the `StringView`s stored for tokens and comment lines stay valid
  as long as the sidecar, and a captured comment costs one copy instead of its own `String`. The
  parser reads a comment into one reused scratch buffer and then copies it in. Comment setters
  append new text and leave the old copy behind until the sidecar is freed. Before the arena, a
  PreserveStyle parse of a commented config ran at ~148 MB/s; with it, ~174 MB/s (5 MB, Release,
  2026-09-28), with preserving output byte-identical across the corpus.
- Pools of key formats and value formats. `TomlValueFormat` is a union of the string, integer,
  float, date/time, array and table formats.
  - <a id="preservestyle-layout"></a>*PreserveStyle layout.* Scalar formats come from the value's
    token. Array and inline-table formats are recorded by `ParseArray`/`ParseInlineTable` at their
    own separators while they parse (`FinishArrayLayout`, `FinishTableLayout`, handed to the caller
    in `mLastArrayFormat`/`mLastTableFormat`): a newline between the container's own separators
    makes it multi-line, the column of its first entry that starts a line is its indent, and the
    spacing inside the braces and around `=` and `,` is seen where those bytes are. Reading the
    layout back from the container's text instead needed that whole text (retained across stream
    refills) and could not tell the container's own newlines, indentation and punctuation from those
    of nested values or strings: `[{` + newline + `a=1}]` became a multi-line array, and a table's
    indent was its deepest nested line's.
  - Captured indents are columns. The preserving writer passes each value the indent of the line
    it starts on (`baseIndent`): a nested multi-line container indents its entries deeper than that
    (its captured column, or one document indent step further when the column is not deeper) and
    puts its closing bracket at that line's indent.
  - The parser keeps separate array loops with and without metadata (`ParsePlainArray`): the plain
    one is the common case and carries none of the comment, range and layout bookkeeping.
- Comment sets per node (leading comments, trailing comment, blank-line separation), plus root
  (file header) and footer comments. Lines are views into `mText`. A view with a null pointer means
  absent: a blank-line marker among the leading lines, or no trailing comment
  (`TomlCommentSet.IsAbsent`, `HasTrailing`). An empty view is a bare `#`, and `== null` on a
  `StringView` compares content, so it cannot tell the two apart. Inside multi-line inline tables (1.1), comments above a field
  are its leading comments, a comment on its line (before or after the comma) its trailing comment,
  and comments before `}` are stored on the inline table's own node and written before the brace.
  A 1.0 write puts the table on one line, where comments cannot be kept.
- `TomlDocumentStyle`, inferred during the parse: newline style (CRLF if CRLF lines are at least
  as common as LF-only lines), the dominant string style, the dominant array layout and whether
  multi-line arrays end with a trailing comma (ties favor the comma), dotted-key use, and indentation. Indentation (character and size, counted in characters so one tab is size
  1) comes from an indented top-level line if there is one, otherwise from the first indented array
  element or inline-table entry. It drives values that have no captured format of their own: new
  strings use the dominant string style, new non-empty arrays the dominant layout (multi-line with
  the document indent and the document's trailing-comma habit), and all preserving-writer
  indentation uses tabs when the source did.
- **Nearby style**: an integer, float or date/time added in code (`Set`, `Add`) takes the value
  format of the nearest earlier entry of the same type in the same table, or element in the same
  array, so a new key among hex values is written in hex. Sharing the neighbor's format ref is
  safe because formats are never edited in place (style setters add new ones). Strings, arrays and
  inline tables deliberately keep the document-wide habits above: quoting and layout are habits of
  the whole file, and copying one neighbor's `'''` string or inline array surprises. Values
  inserted by a merge keep their source's format (or none, if the source had no metadata), never
  a neighbor's. `mPreferDottedKeys` is recorded but deliberately not used to turn `AddTable`
  headers into dotted keys: one dotted key anywhere would otherwise restyle every new table.

Node identity is stored **beside the values, not in `TomlValue`**. A table's entries are
`TomlTableSlot`s (key, value and `TomlNodeId`), so one lookup finds both, and removal, `Rename`
and `Clear` carry the ID with the entry; an array keeps its elements' IDs in a list. Each table and
array with metadata also has a small `TomlContainerMetadataContext` holding the sidecar and the
container's own node ID. This keeps `TomlValue` small and lets style follow the slot or path. New
entries inserted after the parse get node IDs automatically.
  - *Layout:* `TomlNodeId` and the metadata references are 32-bit, and `mNanosecond` in the
    date/time structs is `int32` (0–999,999,999), which keeps `TomlOffsetDateTime` (the largest
    `TomlValue` payload) at 32 bytes, `TomlValue` at 40 and a `TomlTableSlot` at 56 (a 16-byte key
    view, then the value): the node ID fits in the value's alignment padding, so documents without
    metadata pay nothing for it.
    `Layout_ValueAndTableSlotStayCompact` guards these sizes. The root table's context is attached before parsing, so every
table created during the parse (including intermediate tables of dotted keys) inherits one. A
`[header]` table is a single node: the parent's entry ID and the table's own context ID are the same
(the resolver passes the ID to `Insert`). Inline tables get their context as soon as the parser opens
them, so every field (including dotted sub-tables inside the braces) is captured like a top-level
key/value (`CaptureValueMetadata`). `TomlTable.Clear()` keeps the table's own context (node ID,
header comments); the entries' IDs go with the entries. The root table is not an entry of anything, so
its dirty flags live in `TomlDocumentMetadata.mRootDirtyFlags`, next to `mRootComments`.

The sidecar is only deleted together with a store reset (`Clear`, Replace, destruction). Tables the
caller removed earlier are still alive in the arena and keep their contexts, so freeing the sidecar
while the store lives would leave them pointing at freed memory. For the same reason a Merge into an
empty document reuses its existing sidecar instead of replacing it.

**Dirty tracking** (`TomlDirtyFlags`):

- `Value`: set on an entry or item when its value is replaced (`MarkEntryDirty`, `MarkItemDirty`).
- `Children`: set on a container when an entry or item is inserted or removed after the parse
  (`MarkChildrenDirty`). The parser fills the store with `TomlDocumentStore.mSuppressAutoDirty` set
  and clears that one flag afterwards, so a freshly parsed document is clean.
- `Style`: set by the public value-style setters (`SetStringStyle`, `SetIntegerBase`,
  `SetFloatNotation`, `SetDateTimeStyle`, `SetArrayLayout`, `SetInlineTableLayout`), which store a
  new value format on the node, starting from the captured one. Any non-clean flag stops
  original-token reuse, so the value is regenerated in the new style. `SetKeyQuoting` stores a new
  key format instead; keys are always regenerated from their format, so it needs no flag.

**Comment and style editing API** (`TomlTable.SetComment`/`SetTrailingComment`/`TryGetComment`/
`TryGetTrailingComment`/`SetHeaderComment`/`SetHeaderTrailingComment`/`TryGetHeaderComment`/
`TryGetHeaderTrailingComment` and the style setters above; `TomlArray.SetComment`/
`SetTrailingComment`/`TryGetComment`/`TryGetTrailingComment` by element index, which for an
array-of-tables element act on its `[[header]]`; and on `TomlDocument` the path forms plus
`SetFileHeaderComment`/`SetFileFooterComment`). The comment text rules and storage live on
`TomlDocumentMetadata` (`SetLeadingCommentText` etc.), shared by tables and arrays. Formats set in
code start from the captured format and reset what no longer applies: a float changing notation
drops its captured digit counts (a missing exponent width means the minimal `1.5e3`), and an
array turned multi-line takes the document's indentation. An array with element comments is always
written multi-line, as inline tables with comments are on 1.1: comments for a key go on the entry's node, except for a `[header]` table,
whose comments live on the table's own node (where the parser puts header comments). An array of
tables has one header per element, so key-level calls on it are rejected and `SetHeaderComment` is
used on the element. Comment text is validated (no control characters except tab; trailing comments
single-line) so the output stays valid. A comment on a field of a single-line inline table switches
that table to the multi-line layout on 1.1 writes, since only that layout can hold comments.
- Every setter skips a semantically equal value, so the node stays clean and a string's original
  token remains reusable. `IsSemanticallyEqualTo` compares scalars by value (treating NaN as equal
  to NaN) and containers by identity; `TomlInputValue.Matches` does the same without copying the
  incoming string into the arena first.

**How a value is written in PreserveStyle** (`WriteValuePreserving`, `WriteArrayElementPreserving`,
`WriteValueWithDocumentStyle`), checked in this order:

1. A **string** with a node that is **completely clean** (`mDirtyFlags == .None`) and has an
   original token: the token is copied verbatim.
2. Any other **string**: written in its **own** captured style (style follows the slot), including
   whether a multi-line string started with a newline. A string with no captured format (e.g. a
   newly added key) uses the document's dominant style. Literal forms fall back to basic when they
   cannot represent the content.
3. An **integer, float or date/time** with a captured (or nearby-style) value format: regenerated from the current
   value using that format (base, digit case and underscore grouping; exponent style, special-value
   sign and `-0.0`; `T`/`t`/space separator, `Z`/`z` vs offset, seconds and fraction precision). The value always
   comes from the semantic model, so an edited number keeps its original formatting. Floats are
   always written from the exact round-trip representation; a captured fraction precision only
   pads zeros (`5.50`) and never rounds, because fixed-point formatting keeps only ~15 significant
   digits and would change the value. Captured tokens are trimmed first, since a bare value's slice
   can end in the whitespace before a comment.
4. An **array** with a metadata context: inline or multi-line according to its `TomlArrayFormat`
   (indent, trailing comma, per-element comments). Elements recurse through these rules.
5. An **inline table**: `TomlTableFormat` spacing, and multi-line layout on v1.1 only.
6. Otherwise, the normal-mode writer.

Tables use the same three-phase order as normal mode, with some additions. Leading and trailing
comments are written around entries and headers. Header blocks are separated by a blank line. A
sub-table that was created by a dotted key (origin `Implicit`) or whose entries were written as
dotted keys (`HasDottedPreference`) is written back as `parent.key = value` lines instead of a
`[header]`; under a `[header]` those keys are relative to it. Newlines follow the document's
newline style.

**Blank lines** are kept (runs collapse to one). A blank line before a node's comment block (or
before the node itself) is the comment set's `mSeparatedByBlankLine`; a blank line inside or after
the comment block is a `null` entry in `mLeading`, so a comment separated from its key by a blank
line stays detached. File-header comments are always followed by a blank line (that separation is
what made them file-header comments), and footer comments keep a preceding blank line. The writer
never emits two blank lines in a row (`WriteBlankLine`).
Keys keep their captured quoting (`WriteKeyPreserving`): a quoted key stays quoted even if it could be
bare, and a literal-quoted key stays literal unless its (possibly renamed) text cannot be written
that way. Dotted keys only captured their first segment's style, so they use normal-mode quoting,
as do header keys (header key style is not captured).

The **functional-equivalence invariant** is the safety rule: `parse(write(parse(x,
PreserveStyle)))` must give the same semantic document as `x`. Tokens are reused only for values
that are verifiably unchanged; everything else is regenerated from the semantic value. Key order,
whitespace around `=`, exact blank-line layout and byte-for-byte identity are **not** goals.

## 8a. Compile-time serialization (`[TomlObject]`, prototype)

`[TomlObject]` on a class or struct is an `IComptimeTypeApply` attribute (the pattern BJSON's
`[JsonObject]` uses). While the type compiles, `TomlSerializerCodeGen.Emit` walks its fields,
adds `ITomlSerializable`, and emits `TomlRead(TomlTable)` and `TomlWrite(TomlTable)` as source
text through `Compiler.EmitTypeBody`.

- *Document first.* The entry points are on the document and on tables:
  `doc.Deserialize("server", server)` fills an object from the table at a path, and
  `doc.Serialize("server", server)` writes it back (creating the path if needed); `table.Deserialize`
  / `table.Serialize` do the same for any table. So typed sections and hand-written data mix in one
  document, read and written through the same API. `TomlSerializer.Read`/`ReadFile`/`Write`/
  `WriteFile` are one-call wrappers for whole documents: a scoped document, its read or write, and
  its `Deserialize` or `Serialize` with `root: true`, so there is one code path.
- *Where a type lives.* Without a path, the document calls use the type's home table: `Key` on
  `[TomlObject]` (a dotted path), or the type's name through its `Naming` policy. The generator emits
  it as `static StringView TomlKey`, a static member of `ITomlSerializable`, so `T.TomlKey` resolves at
  compile time. The root is opt-in (`root: true`) in the document API, where binding sections is the
  common case, and implied by the whole-file `TomlSerializer` calls. Serialization libraries map a
  type to the whole document by default; configuration binders (Spring's
  `@ConfigurationProperties(prefix)`, .NET `GetSection`, Viper `UnmarshalKey`) bind sections, and the
  document API is closer to them. A type's key only places it at the top level: as a field of
  another `[TomlObject]`, the field's name decides.
- *Renames.* `[TomlAlias("old")]` (repeatable, on fields and types) lists older names, the pattern
  of Jackson's `@JsonAlias`, kotlinx `@JsonNames` and serde's `alias`: reading tries the current name
  and then each alias (`TomlBind.FindKey`; for a type, `FindHome` over `TomlKeyAliases`), and writing
  uses the current name. Those libraries never write into an existing document; here writing would
  leave the old key beside the new one, so the old entry is renamed in place first
  (`TomlBind.RenameAlias`, `TomlTable.RenameKey`: value, node ID, comments and position kept) and a
  document migrates on its next save. A type's table under a different parent is moved instead
  (removed and re-inserted under the new parent).
- *Writing updates in place.* Scalars go through `Set`, which leaves an unchanged value (and its
  PreserveStyle token and comments) untouched; existing sub-tables and arrays are reused
  (`TomlTable.WriteTableAt`/`WriteArrayAt`), so keys the type does not know and their comments stay;
  list items are written by position (`TomlBind.WriteItem`/`ItemTable`) and the array trimmed to
  the list's length; a null String, object or List field removes its key. Reading a PreserveStyle
  document, binding a section, and writing it back unchanged reproduces the input byte for byte
  (`Document_MixesTypedAndHandWrittenData`); changed values keep their format (a hex port stays hex).
  Writing states every field, so a key that was absent when read is added with the field's value.

- *Through the table API, not text.* Generated code reads with `TomlTable` lookups and writes with
  `Set`/`AddTable`/`AddArray`/`AddArrayOfTables`, so quoting, escaping, key syntax and table layout
  stay with the tested parser and writer, and a hand-built or merged document can be bound too.
- *Small emitted code.* Each field is one call into `TomlBind` (lookup, type check, integer range
  check, located error) plus an assignment; the logic lives in ordinary, testable code.
- *Errors.* Located errors from the table API: MissingKey at the table, WrongType or InvalidValue
  at the value (`port: expected integer, found string`), with line and column because `Read` parses
  with at least Positions metadata. Messages name the key, not yet the full dotted path.
- *Enums without reflection.* Beef emits reflection data only on request, so `Enum.Parse` and enum
  `ToString` are not used; the generator writes `switch` statements over the case names, and error
  messages list the cases from compile time.
- *Fields.* Public instance fields not marked `[TomlIgnore]`; keys from the field name through
  `TomlKeyNaming` (words split at case changes, acronyms kept whole: `HTTPPort` → `http_port`) or
  `[TomlName]`. The default is `.AsDeclared`, the field name as written, which is what every
  library surveyed does (BJSON, Tomlyn/System.Text.Json, serde, toml-spanner, glaze, zig-toml, and
  the Go libraries on write); renames are per field or opt-in per type. Keys match exactly: the
  Go libraries' case-insensitive fallback on read was not adopted. Supported: bool, integers (range-checked both ways; 64-bit unsigned up to
  `int64.MaxValue`), float/double (integers accepted), String, simple enums, the four date/time
  types, `[TomlObject]` types (tables), `List<T>` of those (a list of objects is an array of
  tables) and `Dictionary<String, T>` of those or of such a list. Anything else stops the build
  with a message naming the field (so do `Dictionary<int, T>`, nested dictionaries and lists of
  dictionaries).
- *Dictionaries.* A `Dictionary<String, T>` field is a table whose keys are free: the dictionary
  owns that whole table. Reading creates the dictionary if it is null, otherwise deletes its keys
  and reference-type values (heap reads only) and clears it, then adds one entry per table key; each
  value is read by the same generated code as a field of type `T`, aimed at the dictionary slot
  (`Dictionary.this[key]` returns `ref T`) and at the sub-table. Writing updates the table in place:
  keys the dictionary no longer has are removed, kept keys keep their comments and position, and new
  keys are appended in dictionary iteration order (Beef's `Dictionary` is unordered, so a fresh
  write's key order is not the insertion order). A null dictionary removes the key. Struct values
  holding Strings leak those Strings on re-read, as for any struct field (structs have no
  destructor).
- *Converters for other types.* An `ITomlConverter<T>` (static `Read(TomlValue, TomlConvertContext,
  ref T)` and `Write(T, TomlConvertContext)`) handles a type the serializer does not know.
  `[TomlConverter(typeof(T))]` on the converter registers it: when the generator meets a field or
  list item of a non-scalar type, it scans `Type.TypeDeclarations` (the one type enumeration Beef
  allows at compile time) for a registration the compiling project can see (declared in it or a
  dependency), before the built-in enum, object and List handling; two visible registrations for
  one type stop the build. `[TomlUseConverter(typeof(C))]` on a field overrides everything for
  that field. `TomlConvertContext` is "key in a table" or "item of an array": located errors, and
  `Set`/`SetTable`/`SetArray` for writing in place, so one converter serves fields and list items. `Read`
  fills `ref T` in place, so a converter for a class decides allocation (a list item starts null
  and is added to the list before reading, so the list owns it on failure). Registration is
  compile-time only: nothing is looked up at run time, and the generated code calls the converter's
  static methods directly.
- *Allocators.* `TomlRead` and every `Deserialize`/`TomlSerializer.Read` take an optional
  `ITypedAllocator`. With one, everything the read creates (Strings, nested objects, Lists and their
  items, struct fields, and a converter's objects through `TomlConvertContext.Allocator`) comes from
  it through `new:alloc`, so a `scope BumpAllocator` gives a whole object graph a stack lifetime.
  `ITypedAllocator` rather than `IRawAllocator`, so the arena records destructors (a List still
  frees its item buffer). The allocator owns what it produced: the type's fields must not delete
  (no `~ delete _`), and a list read again drops its old items instead of deleting them. A
  per-call parameter rather than a document option, because the allocator's lifetime belongs to the
  object being filled, and one document may fill heap and scoped objects alike; a document option
  would also leave the document holding a pointer to an arena that can go out of scope first.
- *Reading fills an existing object:* absent keys keep their values unless `[TomlRequired]`; null
  String, object and List fields get new instances the type then owns; reading a list deletes its
  old String or object items first. A `[TomlObject]` base class is read and written first through
  `base.TomlRead`/`TomlWrite`.

## 9. Testing strategy

Run `beefbuild -test` from the repo root. It runs 206 `[Test]` methods; fixture paths are
relative to `tests/`. Shared helpers are in `src/TomlBeef/tests/TomlTestSupport.bf`:

- corpus: `ParseFile`, `WalkTomlFiles`, `GetRelativePath`
- structural equality: `TomlDocumentEquals`, `TomlTableEquals`, `TomlValueEquals`,
  `TomlArrayEquals`
- metadata lookup by key rather than by allocation order: `NodeIdFor`, `StyleFor`,
  `CommentsFor`, `ValueFormatFor`, `KeyFormatFor`
- byte and stream builders: `AddAscii`, `AddBytes`, `AddRepeat`, `ReadFromByteStream`
- `AssertReadErr`

| File | Covers |
|---|---|
| `TomlCorpusTests.bf` | Every valid fixture decodes identically through `ReadFile`, `Read(string)`, `ReadBytes` and `Read(Stream)`. PreserveStyle output from a stream with a 64-byte buffer matches the bytes path. The normal writer round-trips and is deterministic. Invalid fixtures are rejected under v1.1 and v1.0. Fixture-count floors (266 valid, 503 invalid) |
| `TomlReadTests.bf` | Replace and Merge failure guarantees, `MergeConflict` modes, accessor type mismatches, BOM, error locations (lexical vs statement start) |
| `TomlStreamTests.bf` | Buffer-boundary crossings (CRLF, comments, strings, keys, bare values), incremental UTF-8 errors and their positions, BOM on streams, I/O failures at various points |
| `TomlResourceLimitTests.bf` | Each limit on each construct, exact `MaxNodes` counting, limits on stream and merge input, Replace clearing on oversize input |
| `TomlLifetimeTests.bf` | `Clear` and reuse, repeated parse and merge cycles, replaced or removed payloads staying readable until `Clear`, `MergeFrom` copying |
| `TomlMutationApiTests.bf` | Typed setters, array and `TomlTableEntry` operations, rename collisions |
| `TomlPathTests.bf` | Bracketed path syntax, including malformed paths |
| `TomlInlineTableSealTests.bf` | Recursive sealing cases |
| `TomlPreserveStyleMetadataTests.bf` | Capture of formats, comments, document style and dirty flags |
| `TomlPreserveStyleWriterTests.bf` | Token reuse, format-driven regeneration, comment output, the effects of dirty writes |

Test validity policy: a test must check spec behavior, a public API contract, documented config
behavior, or a named regression. It may inspect metadata internals only when metadata is the
feature under test. Assertions should be exact where the formatting is the contract, and corpus
failures must name the fixture.

**Corpus**: `tests/valid/**.toml` (266 files, each with a toml-test tagged-JSON `.json` expectation)
and `tests/invalid/**.toml` (503 files). They were copied from toml-test, so no upstream checkout
is needed.

**Acceptance scripts** (build first with `beefbuild`; they use
`build/Debug_Linux64/TomlTester/TomlTester`, which can be overridden with `BIN`):

- `./test-toml.sh`: valid fixtures must parse, and their JSON must match the expected `.json`
  semantically (`json-compare.py`: order-insensitive, float-tolerant). Invalid fixtures must be
  rejected without a segfault (`spec-1.1.0/` with `-toml 1.1`, the rest with `-toml 1.0`).
  Needs Python 3.
- `./test-roundtrip.sh`: parse → `-encode` (the normal writer) → re-parse, then compare the two
  JSON outputs semantically.
- `./test-encoder.sh`: every fixture `.json` → `-from-json` → TOML → decoder → tagged JSON,
  compared semantically against the fixture.
- `./test-official-toml.sh`: runs the pinned upstream `toml-test` v2 runner (via `go run`, or
  `TOML_TEST_BIN`) for 1.0 and 1.1 with both `-decoder` and `-encoder`, writing
  `test-official-toml-<ver>.log`.

**TomlTester CLI** (`TomlTester/src/Program.bf`) takes `-toml 1.0|1.1` (default 1.1), `-preserve`
(read with PreserveStyle, so `-encode` exercises the preserving writer), and one flag per
`TomlReadConfig` limit (`-max-input-bytes`, `-max-depth`, `-max-string-bytes`, `-max-array-items`,
`-max-table-entries`, `-max-path-segments`, `-max-nodes`). TOML input is parsed straight from the
stdin stream (`Read(Stream)`), so the acceptance scripts also run the whole corpus through the
stream path. Unknown options or bad values exit with 2. `-bench N` reads stdin once and times N
parses through `Read(string)`, `ReadBytes` and `Read(Stream)`, plus `Write` (combine with
`-preserve`; build with `-config=Release`). On a generated 736 KB file (Release, Linux64,
2026-09-27): string and byte input ~59 MB/s, stream ~51 MB/s, write ~257 MB/s. String and byte input
cost the same (the byte cursor is zero-copy over either). The stream path was ~43 MB/s until the
buffered cursor's hot paths were inlined (`EnsureAvailable` split into an inline check and an
out-of-line `Fill`; inline `AdvanceByte` and ASCII `Advance` with newlines and multi-byte
sequences out of line; `IsEOF` reading a struct flag instead of the shared state). The remaining
~15% is the copy into the buffer and incremental UTF-8 validation. Bulk scanning (`ScanRun`) and
the key-path and string-buffer reuse then gave (5 MB mixed bench, same-run comparison, 2026-09-28)
+17% overall, 2× on string-heavy input, +47% on comments, +20% on integer and header input. A
`perf` pass then removed per-document and per-entry overhead: dirty-marking suppression is one flag
on the store (`TomlDocumentStore.mSuppressAutoDirty`) instead of a flag per container cleared by a
tree walk after every parse; `Clear()` no longer walks the tree to delete metadata contexts (the
store reset's destructors do); new keys are inserted with one hash lookup (`TomlTable.TryInsertNew`,
the resolver checks the sealed/limit errors first); the parser's limit checks compare inline and only
call out when a limit is exceeded; and `TomlParseError`'s positions are `int32`, which shrinks every
parser `Result` (copied on each return up the call chain) from ~80 to 64 bytes. Together (same-run,
2026-09-28): the 5 MB mixed bench went from ~40 to ~77 MB/s, integers ~94, dates ~109, strings ~270,
headers ~64, dotted keys ~42, small arrays ~40. A one-pass fast path for plain decimal integers
(`TryParsePlainInteger`: optional sign, 1–18 digits, no leading zero, so valid and unable to
overflow) then let them skip the keyword, date and two-pass number checks. Everything else,
including every invalid token, still takes the full parser. Same-build A/B against the pre-change
build: ints 111 → 150 MB/s, small arrays 41 → 58, headers 64 → 74, dotted 47 → 52. Digit-first
tokens also skip the `true`/`false`/`inf`/`nan` comparisons (keywords never start with a digit), and
parsed date/times are built with internal `Validated` factories that skip the public constructors'
Release-mode asserts (the parser has already checked `TomlDateRules`; Debug still asserts): dates
~127 → ~131, floats ~85 → ~92. Array element lists start with an 8-slot buffer appended to the list
object, one heap allocation per small array instead of three: small arrays ~59 → ~64. Allocating
those lists in the document arena instead was tried and was 23% slower, because fresh arena pages
per document take page faults that malloc's reused memory avoids. The same pattern later covered
floats and date/times (2026-09-29, same-build A/B): `TryParsePlainFloat` takes
`[sign]digits[.digits][e[sign]digits]` without underscores in one pass, and when the digits fit an
exact double mantissa (≤ 2^53) and the decimal exponent is within ±22 it divides or multiplies once
by an exact power of ten, which IEEE rounds correctly (Clinger's fast path; a test compares 20,000
generated floats bit for bit with `Double.Parse`); everything else still goes to `Double.Parse`,
now without copying tokens that have no underscores. `TryParsePlainDateTime` reads the date, time
and offset in one pass instead of the classify-then-parse scans, and fractional seconds are summed
arithmetically instead of through a `String`. Both decline anything unusual, so errors come from
the full path unchanged. Floats 87 → 143 MB/s, dates 131 → 157. The date part sits in a separate
`ParseOtherBareToken`: inlined into `ParseBareToken` it cost plain integers ~6%. Without metadata,
arrays use `ParsePlainArray` (whitespace, value, whitespace, then `,` or `]`), skipping the
per-element position, node-ID and comment bookkeeping: small arrays 66 → 79.
  - *Comparison* (`bench/compare/`: `fetch.sh`, `build.sh`, `gen-inputs.py`, `run.sh`, `plot.py`;
    results in `bench/compare/results.md`, chart in `docs/benchmark.svg`). 20 libraries parse the
    same generated inputs (2–9 MB, at most 1000 keys per table) into their own schema-less
    documents. Every harness uses one rule (documented in `run.sh`): warm up for at least 1 s,
    then time single operations until at least 5 samples were taken and at least 60% lie within
    ±10% of their median, or 10 s / 1000 samples pass; report the median sample. Each cell is the
    median of 3 fresh processes, and a run past 60 s is DNF. (A first version used ±2%: lookups
    rarely converged and a full run took hours; with the median reported, ±10% is enough to show
    the samples have settled.) C/C++ at `-O3` and Zig at `ReleaseFast`, without `-march=native`,
    like TomlBeef's Release build. A full parse run takes ~45 min, the lookup run ~8 min.
    Partial reruns (`merge.sh`): with `ONLY` set to a grep pattern of parser names, `run.sh`,
    `lookup.sh` and `typed.sh` measure only those, copy every other cell from their saved results
    file, and rewrite it (only when the run succeeded). `update-tomlbeef.sh` uses it to rebuild and
    remeasure every TomlBeef figure (plus `modes.sh` and `beef.sh`, which only time Beef code) and
    redraw the charts; the other libraries keep the figures of their last full run.
    Versions: tomlc17 R260821, toml-c 6a38d40, toml11 v4.4.0, toml++ v3.4.0, glaze v9.0.0; Rust
    1.98.1 with `toml` 1.1.6, `toml_edit` 0.25.15, toml-spanner 1.0.3, toml-span 0.7.1; zig-toml
    8685923 (zig-0.16 branch) with Zig 0.16.0; BurntSushi/toml v1.6.0, go-toml v2.4.3; tomlj
    2.1.1, jtoml 1.8.1 (Java 26); Tomlyn 2.10.1 (.NET 10); js-toml 2.0.1, smol-toml 1.9.0,
    toml 5.0.0 (Node 26).
  - *Standings* (2026-09-29, after the fast paths and `TomlEntryMap`; geometric mean of MB/s
    relative to TomlBeef over the 10 inputs). Of the data-model parsers only **toml-spanner** is
    faster: 1.09× on average (1.48× before those changes), ahead on 6 of the 10 inputs (178 vs 124
    MB/s on the mixed config, 141 vs 79 on small arrays, 127 vs 92 on headers) and behind on
    comments, commented, ints and floats (2976 vs 1723 on comment-only, 197 vs 170 on ints). It
    validates fully, and its tree borrows strings from the input (only escaped strings are copied,
    into an arena), where TomlBeef copies every string into its document store. Next come zig-toml
    0.62×, glaze 0.50×, smol-toml and Rust `toml` 0.20×; the rest are 0.13× or slower. Among
    parsers that keep comments and formatting TomlBeef is fastest: `toml_edit` 0.47×, Tomlyn's
    syntax tree 0.065×.
  - *Lookups after parsing* (`bench/compare/lookup.sh`, results in `lookup-results.md`): 100,000
    random `root[table][key]` integer reads through each library's table API, checked to find the
    same values. TomlBeef takes 73 ns in 200 tables of 1000 keys and 71 ns with 15000 sections at
    the root (PreserveStyle: 70 / 71; before `TomlEntryMap` 101 / 85), level with the fastest
    JavaScript libraries (smol-toml 72 / 105, `toml` 71 / 116); zig-toml 45 / 45, go-toml 54 / 62
    and BurntSushi/toml 69 / 67 are faster; Tomlyn, glaze, `toml_edit` (215 / 165), toml11 and Rust
    `toml` (305 / 227, a B-tree) slower. Libraries that scan a table's entries grow with table size:
    toml-spanner 1697 / 14835, tomlc17 1780 / 19285, toml-c 2414 / 38313, and Tomlyn's syntax tree
    (no lookup API; the harness scans headers) 17731 / 104325. toml-spanner's hash index exists only
    during the parse, for duplicate detection, so its parse-speed lead on the mixed config (~10 ms)
    is used up after ~650 lookups. Any move toward its table layout must keep indexed lookups for
    large tables.
  - *Table storage* (`TomlEntryMap`, 2026-09-29). Tables were a corlib `Dictionary<String,
    TomlTableSlot>` plus a `List<String>` key order. That cost 4–6 heap allocations per table (the
    dictionary grows 1→3→7→15), a re-hash per entry whenever the writer walked a table (about half
    of Write's time on table-heavy input), and slow lookups: corlib hashes keys under 8 bytes one
    byte at a time and picks buckets with `%` over `2^n−1` sizes, which together walk 2.12 entries
    per hit in a 1000-key table. Now a table's entries sit in one array in insertion order (writers
    and `GetValueAt` never hash). Up to 8 entries a lookup compares keys directly (toml-spanner's
    layout, without its unbounded scans). Past that, an open-addressing index at most half full,
    with a power-of-two mask and each slot holding the entry position and full 32-bit hash, so a
    probe reads a key only on a hash match. The hash takes one or two overlapping loads for keys
    under 8 bytes and 8 bytes per step above, then a splitmix64 finalizer. Removal and rename
    rebuild the index, as removal shifts positions anyway. With the arena pool reuse above,
    same-build A/B against the previous commit (MB/s, parse): mixed 101 → 124, commented 514 →
    610, strings 505 → 696, ints 147 → 179, floats 143 → 171, dates 156 → 190, arrays 78 → 80,
    headers 74 → 95, dotted 52 → 84; PreserveStyle dotted 40 → 47. Writing: ints 232 → 425, headers
    166 → 271, dotted 56 → 174. Lookups: 100 → 69 ns (ints), 84 → 71 ns (mixed).
  - *TomlBeef's own modes* (`modes.sh`, results in `modes-results.md`, chart
    `docs/benchmark-modes.svg`, first in the README's Performance section). Every read and write path
    on `typed.toml`, relative to the plain document: reads 25 ms (document), 30 (+ positions), 49
    (+ PreserveStyle), 35 (typed), 41 (typed + positions), 39 (typed + positions through an arena);
    writes 12 ms (document), 16.5 (PreserveStyle), 25 (typed into a new document), 22 (typed update of
    a PreserveStyle document in place, byte-for-byte identical output when nothing changed). It gives
    the per-library charts context: each compares one of these modes.
  - *Typed serialization* (`typed.sh`, results in `typed-results.md`, 2026-09-29). Every library with
    a typed mapping reads `typed.toml` (3.8 MB: 20000 `[[servers]]`, each with strings, integers, a
    float, a bool, a string list and a nested table) into matching native types and writes them
    back; each prints the same checksum after the read and after re-reading its own output. Read /
    write in ms (second run, with the arena row): glaze 16 / 3.7, toml-spanner (derive) 21 / 12,
    TomlBeef 34 / 23.5 without positions (37 through an arena, 40 through `TomlSerializer.Read`, which
    records positions), zig-toml 39 / n/a (its serializer does not compile for an array of tables),
    go-toml 55 / 30, Rust `toml` (serde) 78 / 28, Tomlyn 124 / 48 with its source generator and 136 /
    50–76 with reflection (its write varies between runs), BurntSushi 294 / 200. TomlBeef's read
    is 25 ms of parsing into a document plus ~11 ms of binding (7 objects allocated per server, one
    key lookup and one `Result`-returning `TomlBind` call per field); glaze and toml-spanner bind
    while parsing, with no document in between, which is also why they cannot offer the
    document-first API (8a). Reading through a `scope BumpAllocator` (`read-arena`) instead of the
    heap saves only ~6% (37.2 vs 39.7 ms), so allocation is not most of the binding cost; the
    lookups and helper calls are the next thing to measure.
  - *Beef's built-in reader* (`bench/compare/beef/`, `beef.sh`, results in `beef-results.md`).
    `Beefy.utils.StructuredData` (Beefy2D; IDE and BeefBuild project files) is built from the
    installed Beef (`fetch.sh` copies `StructuredData.bf` and `DisposeProxy.bf`) into one program with
    TomlBeef, so both use the same compiler and settings. Its data model: parallel lists of boxed
    values and keys in a bump arena, each table a linked list (no hash map, no duplicate check),
    integers boxed `Int64`, floats `float` (32-bit), dates and anything else containing `-` or `:`
    kept as raw text. It errors on dotted keys, literal and multi-line strings, trailing commas and
    comments inside arrays, and validates almost nothing. `check` walks both trees and classifies
    each file (exact match / match except date text or float32 / values differ / error); only
    exact matches count as like-for-like. Findings (2026-09-29): 6 of the 10 generated inputs and
    133 of 134 real project files read identically; toml-test valid 109 exact + 32 with date or
    float32 differences + 4 wrong of 266, invalid 179 of 492 accepted. After TomlBeef's fast paths
    and `TomlEntryMap` (same day), StructuredData parses the real project files 1.3× faster (202 vs
    152 MB/s) and small arrays 1.6× faster (no hashing, no validation), headers 1.25× faster, is
    even on ints and strings and slower on comments (3.3×) and commented (1.4×); writing is mixed
    (StructuredData ~1.1–1.5× faster on strings, ints and commented, TomlBeef faster on arrays and
    headers); its lookups (Open + TryGet, a linear scan) are ~27× slower (2026 vs 75 ns). The one rejected project file
    (`BeefManaged/…/BeefProj.toml`) repeats a key in an inline table.
  - An earlier run of 13 libraries (before toml-spanner and the others were added) lost on
    comment-heavy input (glaze 2657, go-toml 1912, toml-c 1230 vs 1114 MB/s; `toml_edit` 636 vs 535
    preserving), the commented config (glaze 418 vs 398) and small arrays (glaze 49 vs 41).
    Studying those libraries led to the changes described under `TomlByteCursor` (columns on
    demand, eight bytes at a time) and the integer, keyword/date and array-allocation changes below.
  - Validation differs, so some speeds buy less work. Checked with duplicate keys and tables,
    extending an inline table, two pairs on one line, a leading zero, February 30, a bare CR, a
    control character in a comment and invalid UTF-8: zig-toml accepts all of them; smol-toml
    accepts February 30; glaze and toml-c skip UTF-8 validation. toml-spanner, toml-span, tomlj,
    jtoml, js-toml and toml (JS) reject the rest (the Java and JavaScript libraries take decoded
    strings, so UTF-8 is not theirs to check). The same check found TomlBeef accepting a bare CR
    after a value, since fixed. Other notes:
    - glaze reads TOML into known C++ types. Its schema-less value is JSON-shaped, has no date/time,
      and fails on dates (FAIL). Reading into that value picks the type from the first byte, so a
      document starting with `[table]` is taken for an array; the harness reads into the generic
      object type instead. toml-span has no date/time support either.
    - Some parsers are superlinear: go-toml in the number of tables (~20 s per parse on `headers`),
      jtoml in document size (~90 s for the 3.9 MB config), tomlj on the 8.9 MB comment-only file.
      Cells past the limit print TIMEOUT and count at input size / limit, which flatters them.
    - Each library builds a different document type, so the work is not identical.

- Default (decoder): reads TOML from stdin and writes toml-test tagged JSON through
  `TomlTester/src/TomlTestJson.bf`. Tagged JSON is a test format, so the serializer lives in
  `TomlTester` and uses only the public API (`GetKeyAt`/`GetValueAt` walks). Each scalar becomes `{"type": ..., "value": ...}`, with types `string`,
  `integer`, `float`, `bool`, `datetime`, `datetime-local`, `date-local` and `time-local`.
- `-encode`: reads TOML and writes it back with the normal writer.
- `-from-json` (encoder): reads tagged JSON and writes TOML (`TomlTester/src/JsonToToml.bf`). The
  JSON is parsed with **BJSON**, a `TomlTester`-only dependency; the library never depends on it.
  An object with exactly two string members `type` and `value` is a scalar, any other object a
  table, any array an array. The document is built only through the public typed API
  (`Set`, `AddTable`, `AddArray`, `TomlArray.Add`), so this mode also exercises that API.
  Integer, float and date/time values are converted by parsing `v = <value>` with TomlBeef itself,
  so the encoder shares the decoder's grammar. BJSON stores short strings inline in `JsonValue`,
  so tag and value text are copied out rather than viewed.
- On a parse error: prints `Parse error at line L:C: msg` to stderr and exits with 1.

## 10. Glossary

| Term | Meaning |
|---|---|
| Store / arena | `TomlDocumentStore`: the bump allocator that owns all payloads of one document |
| Borrowed value | A `TomlValue`, `StringView`, `TomlTable` or `TomlArray` obtained from a document. Valid until `Clear()` or `delete`, and possibly stale after a mutation |
| Origin | `TomlTableOrigin`: how a table came to exist. It drives the conflict rules and how the table is written |
| Sealed | An inline table (and its inline descendants) that cannot be extended after its closing `}` |
| Static array | An array written as `[...]` (internal `IsStatic = true`, public `IsArrayOfTables = false`), as opposed to an array of tables built from `[[...]]` |
| Mark / slice / spill | Cursor retention: a mark pins input from its offset, a slice reads and releases it, and the spill holds retained bytes that the stream buffer evicted |
| Sidecar | PreserveStyle metadata kept outside the semantic tree and linked by `TomlNodeId` |
| Clean / dirty | Whether a node's value or children changed since the parse. Only fully clean string nodes reuse their original token |
