# TomlBeef Architecture

This document describes how TomlBeef works today and why it was built that way. It is not a
history log or a task list. Open work and known gaps are tracked in [status.md](status.md).
User-facing API examples live in the top-level `README.md`.

## 1. Overview and goals

- A TOML parser and writer for the Beef language, covering **TOML v1.0.0 and v1.1.0**. Version is
  selected per read/write; the default is v1.1.
- **Linux64 is the primary target.** Windows/macOS are deferred.
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

## 2. Source layout

The library project is at the repo root (`BeefProj.toml`, `TargetType = "BeefLib"`). The
workspace startup project is `TomlTester/`.

| File (`src/TomlBeef/`) | Responsibility |
|---|---|
| `TomlDocument.bf` | Public entry point: `TomlReadMode`, `MergeConflict`, `TomlReadConfig`, `TomlWriteConfig`, and `TomlDocument` (read/write, file helpers, path lookup, typed path accessors and setters, transactional read/merge orchestration) |
| `TomlDocumentStore.bf` | Internal arena (`BumpAllocator`) that owns every string, table and array of a document |
| `TomlValue.bf` | `TomlTableOrigin` enum and the non-owning `TomlValue` tagged union (`Is*`, `As*`, `TryGet*`, internal `CloneInto`, `IsSemanticallyEqualTo`) |
| `TomlTable.bf` | `TomlTable`: an ordered map (`Dictionary<String, TomlValue>` plus `List<String>` key order) with origin and sealing flags, typed setters, `MergeFrom`, and the `TomlTableEntry` proxy |
| `TomlArray.bf` | `TomlArray` (static array or array of tables) and the `TomlInputValue` scalar-input wrapper |
| `TomlDateTime.bf` | `TomlOffsetDateTime`, `TomlLocalDateTime`, `TomlLocalDate`, `TomlLocalTime`. Public fields; constructors assert field ranges |
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

Other locations: tests are in `src/TomlBeef/tests/`, the fixture corpus is in `tests/valid` and
`tests/invalid`, the CLI is `TomlTester/src/Program.bf`, and the acceptance scripts are
`test-toml.sh`, `test-roundtrip.sh`, `test-encoder.sh` and `test-official-toml.sh` (with `json-compare.py`). `BJSON/`,
`toml-test/` and `recovery/` are external or forensic material (see `AGENTS.md`).

## 3. Public API model

### TomlDocument entry points

| Operation | Methods |
|---|---|
| Read | `Read(StringView[, config])`, `ReadBytes(Span<uint8>[, config])`, `Read(Stream[, config])`, `ReadFile(path[, config])` |
| Write | `Write(String output[, TomlWriteConfig])` appends and never fails; `WriteFile(path[, config])` returns `IoError` on failure |
| Lookup | `Get(dottedPath)`, `GetPath(params StringView[])`, `GetPath(List<StringView>)`, `TryGetString/Integer/Float/Bool/Table/Array/OffsetDateTime/LocalDateTime/LocalDate/LocalTime(path, out v)` |
| Mutation | `Set{String,Integer,Float,Bool,OffsetDateTime,LocalDateTime,LocalDate,LocalTime}(path, v)`, `AddTable(key)`, `AddArray(key)`, `Remove(key)`, `Clear()` |
| Inspection | `RootTable` (read-only property), `Metadata` (null unless PreserveStyle) |

- Overloads without a config use the document's own `ReadConfig` / `WriteConfig` fields (there is no
  process-global default, so documents on different threads never share settings).
- `ReadFile` loads the whole file (`File.ReadAll`) and parses the bytes with `ReadBytes`, without a
  second copy. With `TomlReadConfig.StreamBufferBytes` set it instead opens a `FileStream` and uses
  `Read(Stream)`, so input memory stays bounded by the buffer. Any BOM goes through the normal BOM
  rules; a missing or unreadable file is `IoError`.
- `Get`, `GetPath`, `TomlTable.Get`/`TryGetValue`/`GetValueAt`/`this[key]` and
  `TomlArray.GetValueAt` return a borrowed `TomlValue` of any type, for generic walking (the
  `TomlTester` serializer uses them). Typed `TryGet*` accessors are preferred when the type is known.
- Document setters resolve every path segment except the last, and **require the intermediate
  tables to already exist**. They do not create tables implicitly. Build nested content top-down
  with `AddTable`.

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
`TomlTable` APIs for such keys. Segments borrow from the input path.

## 4. Ownership and lifetime model

- **`TomlDocumentStore`** owns a `BumpAllocator(.Allow)`. Every string payload, table key,
  `TomlTable` and `TomlArray` of a document is allocated with `new:mAlloc` through `NewString`,
  `NewTable(origin)` and `NewArray()`. `.Allow` records destructors, so each table's dictionary and
  key list and each array's item list are freed when the arena is deleted. `Reset()` deletes the
  arena, creates a fresh one, and allocates a new root table.
- **`TomlValue` is a non-owning tagged union.** Scalars and date/times are stored inline;
  `.String(String)`, `.Array(TomlArray)` and `.Table(TomlTable)` are borrowed references into the
  arena. `TomlValue` has no `Dispose`, and copying one is always safe.
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
Read(StringView) / ReadBytes / ReadFile ─► TomlChar.ValidateUtf8 (whole buffer, BOM skip) ─► TomlByteCursor ─┐
Read(Stream) ─► TomlBufferedStreamCursor (BOM skip, incremental UTF-8 in Refill) ─────────────────────────────┤
                                                                                                             ▼
                            TomlParserImpl<TCursor>.Parse(cursor, TomlPathResolver) ─► TomlTable tree in a TomlDocumentStore
```

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
  - Nesting matters because PreserveStyle marks a whole value (for example an inline table)
    while inner string, key and number parsing take their own marks.
- **UTF-8 validation differs by path:**
  - String, bytes and file input: `TomlChar.ValidateUtf8` checks the whole buffer before parsing
    (lead bytes, continuation bytes, overlongs, surrogates, values above U+10FFFF) and reports
    `InvalidUtf8` with its line, column and offset.
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
| `MaxDepth` | nesting depth of values (arrays and inline tables) | `ParseValue` → `CheckDepth` (fails with `MaxDepthExceeded`) |
| `MaxStringBytes` | bytes of a decoded string value (keys excluded) | string parsers after decoding |
| `MaxArrayItems` | elements of one array, including `[[...]]` elements | array parser, `DefineArrayOfTables` |
| `MaxTableEntries` | keys of one table: root, header, inline, dotted-implicit | `InsertKeyValue`, `NavigateSegment`, `DefineTable`, inline-table insert, `InsertDottedKeyIntoTable` |
| `MaxPathSegments` | segments of a dotted key or header | `ParseKeyPath` |
| `MaxNodes` | every value node: scalars, arrays, tables (explicit, implicit, inline, array elements); the root is not counted | `ParseValue` plus each table or array the resolver or inline parser creates (`a = [1, 2]` is 3 nodes and `a.b.c = 1` is 3) |

Every limit error is `ResourceLimitExceeded`, except depth, which is `MaxDepthExceeded`. The
normal Replace/Merge failure guarantees apply.

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
  as `key = value`; (2) other sub-tables as `[full.path]` headers, recursively; (3) arrays of
  tables as `[[full.path]]` blocks. Array-of-tables output comes last so that its elements do not
  absorb the parent's keys. As a result, output can be reordered compared with the source, even
  though every table keeps insertion order.
- An empty array of tables (non-static, `Count == 0`) has no `[[header]]` form, so it is written in
  phase 1 as `key = []`.
- Keys are bare when every character is a bare-key character; otherwise they are written as basic
  quoted strings.
- Strings are basic, integers decimal, and floats use roundtrip `"R"` formatting (with `.0`
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
- Owned copies of original string tokens (`mOriginalTokens`). **Source spans are never used to
  recover text**, because the input buffer or stream is gone after the parse.
- Pools of key formats and value formats. `TomlValueFormat` is a union of the string, integer,
  float, date/time, array and table formats.
- Comment sets per node (leading comments, trailing comment, blank-line separation), plus root
  (file header) and footer comments. Inside multi-line inline tables (1.1), comments above a field
  are its leading comments, a comment on its line (before or after the comma) its trailing comment,
  and comments before `}` are stored on the inline table's own node and written before the brace.
  A 1.0 write puts the table on one line, where comments cannot be kept.
- `TomlDocumentStyle`, inferred during the parse: newline style (CRLF if CRLF lines are at least
  as common as LF-only lines), the dominant string style and the dominant array layout, dotted-key
  use, and indentation. Indentation (character and size, counted in characters so one tab is size
  1) comes from an indented top-level line if there is one, otherwise from the first indented array
  element or inline-table entry. It drives values that have no captured format of their own: new
  strings use the dominant string style, new non-empty arrays the dominant layout (multi-line with
  the document indent and a trailing comma), and all preserving-writer indentation uses tabs when
  the source did. `mPreferDottedKeys` is recorded but deliberately not used to turn `AddTable`
  headers into dotted keys: one dotted key anywhere would otherwise restyle every new table.

Node identity is stored **beside the values, not in `TomlValue`**. A table's entries are
`TomlTableSlot`s (value plus `TomlNodeId`), so one hash lookup finds both, and removal, `Rename`
and `Clear` carry the ID with the entry; an array keeps its elements' IDs in a list. Each table and
array with metadata also has a small `TomlContainerMetadataContext` holding the sidecar and the
container's own node ID. This keeps `TomlValue` small and lets style follow the slot or path. New
entries inserted after the parse get node IDs automatically.
  - *Layout:* `TomlNodeId` and the metadata references are 32-bit, and `mNanosecond` in the
    date/time structs is `int32` (0–999,999,999), which keeps `TomlOffsetDateTime` (the largest
    `TomlValue` payload) at 32 bytes, `TomlValue` at 40 and a `TomlTableSlot` at 48: the node ID
    fits in the value's alignment padding, so documents without metadata pay nothing for it.
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
  (`MarkChildrenDirty`). The parser builds the tree with `mSuppressAutoDirty` set, then clears it
  with `ClearAutoDirtySuppression()`, so a freshly parsed document is clean.
- `Style`: set by the public style setters (`SetStringStyle`, `SetIntegerBase`), which store a new
  value format on the node. Any non-clean flag stops original-token reuse, so the value is
  regenerated in the new style.

**Comment and style editing API** (`TomlTable.SetComment`/`SetTrailingComment`/`TryGetComment`/
`TryGetTrailingComment`/`SetHeaderComment`/`SetHeaderTrailingComment`/`SetStringStyle`/
`SetIntegerBase`, and on `TomlDocument` the path forms plus `SetFileHeaderComment`/
`SetFileFooterComment`): comments for a key go on the entry's node, except for a `[header]` table,
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
3. An **integer, float or date/time** with a captured value format: regenerated from the current
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
headers ~64, dotted keys ~42, small arrays ~40.
  - *Comparison* (same machine, 2026-09-28, MB/s on generated inputs with at most 1000 keys per
    table): on a config-like mixed file TomlBeef ~79, Rust `toml` ~31, Tomlyn ~17, tomlc17 ~7,
    toml11 ~2; with style preservation TomlBeef ~44, `toml_edit` ~28, Tomlyn's syntax tree ~4.
    TomlBeef leads on every shape except comment-only input, where `toml`/`toml_edit` scan faster
    (~660/635 vs ~580 plain, ~350 preserving). Each library builds its own document type, so the
    work is not identical.

- Default (decoder): reads TOML from stdin and writes toml-test tagged JSON through
  `TomlTester/src/TomlSerializer.bf`. Tagged JSON is a test format, so the serializer lives in
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
