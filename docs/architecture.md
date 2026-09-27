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
| `TomlParser.bf` | `TomlParserImpl<TCursor>`: recursive-descent parser, version gates, and PreserveStyle capture (tokens, formats, comments, document style inference) |
| `TomlPathResolver.bf` | Table-tree navigation for headers and dotted keys, implicit table creation, all structural conflict rules |
| `TomlResourceLimitState.bf` | Per-read limit counters and `Check*` helpers shared by the parser and the resolver |
| `TomlMetadata.bf` | The PreserveStyle sidecar: `TomlMetadataMode`, node IDs, `TomlNodeStyle`, dirty flags, comment sets, format structs, `TomlContainerMetadataContext`, `TomlDocumentMetadata` |
| `TomlWriter.bf` | `TomlWriterImpl`: the normal writer and the preserving writer |
| `TomlChar.bf` | Character classes, UTF-8 decode/encode, and whole-buffer `ValidateUtf8` (with BOM handling) |
| `TomlError.bf` | `TomlErrorKind` and `TomlParseError` |
| `TomlVersion.bf` | `TomlVersion { V1_0, V1_1 }` |
| `TomlMixins.bf` | Placeholder for container-cleanup mixins (currently empty) |

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

- Overloads without a config use the static `TomlDocument.DefaultReadConfig` /
  `DefaultWriteConfig`. These are process-global and not thread-safe; set them once at startup.
- `ReadFile` loads the whole file (`File.ReadAll`) and then uses the string path. The file is
  treated as raw bytes, so any BOM goes through the normal BOM rules.
- Document setters resolve every path segment except the last, and **require the intermediate
  tables to already exist**. They do not create tables implicitly. Build nested content top-down
  with `AddTable`.

### Configuration

`TomlReadConfig`: `Mode` (`Replace` by default | `Merge`), `OnConflict` (`Error` by default |
`Skip` | `Overwrite`), `Version` (`V1_1` by default), `MetadataMode` (`None` by default |
`PreserveStyle`), plus the resource limits in section 6. `TomlWriteConfig`: `Version` only.

### Replace vs Merge, and failure guarantees

- **Replace** clears the document and parses directly into its store. On any failure (UTF-8,
  size limit, I/O, parse or resolver error) the document is `Clear()`ed, so it is **left empty**.
- **Merge** into an empty document behaves like Replace, because nothing needs preserving.
- **Merge** into a non-empty document parses into a **temporary `TomlDocumentStore`**. Only after
  that parse fully succeeds does `TomlTable.MergeFrom` copy the incoming top-level entries into the
  real store (`CloneInto`). A parse failure therefore leaves the **existing content unchanged**.
- `MergeFrom` makes two passes. With `OnConflict = .Error` it first checks every incoming
  top-level key and fails with `DuplicateKey` (position 0:0) **before changing anything**. The
  second pass inserts new keys; for an existing key it does nothing (`Skip`) or replaces the value
  with a deep copy (`Overwrite`).
- **Merge is shallow**: conflicts are decided per top-level key. `Overwrite` replaces the whole
  subtree under that key; it does not merge tables recursively.
- A successful merge into a non-empty document **drops PreserveStyle metadata**
  (`ClearMetadata`). Merging metadata is not implemented, and keeping stale node IDs would be
  unsafe.

### Tables, arrays and entries

- `TomlTable` keeps insertion order (`GetKeyAt`, `GetValueAt`, `Count`, `ContainsKey`,
  `TryGetValue`, `Get`, `this[StringView]`). It has typed `TryGet*(key, out v)` readers, typed
  `Set*(key, v)` setters (insert or replace), `AddTable`/`AddArray` (return null if the key
  exists), `Remove`, `Clear` and `MergeFrom`.
- `table[i]` returns a `TomlTableEntry` struct proxy (table plus index). It provides `Key`, typed
  `TryGet*`, `Value = <scalar>` assignment, `SetTable()`/`SetArray()` (replace with a new empty
  container), `Rename(newKey)` (keeps the position and the metadata node ID; fails with
  `DuplicateKey` on a collision) and `Remove()`.
- `TomlArray` provides typed `Add*`, `Add(TomlInputValue)`, `AddTable()`, `AddArray()`, index
  assignment `arr[i] = <scalar>`, `SetTable(i)`/`SetArray(i)`, `RemoveAt`, `Clear`, typed
  `TryGet*(index, out v)`, and `IsStatic` (true for `[...]` arrays, false for `[[...]]`
  arrays of tables). Reading through the indexer is a fatal error, so reads go through `TryGet*`,
  or `GetValueAt(i)` for elements of unknown type (mirrors `TomlTable.GetValueAt`).
- `TomlInputValue` is a scalar-only struct with implicit conversions from `StringView`, `int64`,
  `double`, `bool` and the four date/time structs. Callers never build a `TomlValue` or a container
  themselves. The value is materialized into the document's store on assignment.
- Programmatic `TomlTable.AddTable` creates an `ExplicitHeader`-origin table, which is written as
  `[header]`. `TomlTableEntry.SetTable` creates an `InlineTable`-origin table.
  `TomlArray.AddTable`/`SetTable` create `ArrayElement` tables.

### Path syntax

Used by `TomlDocument.Get`, the `TryGet*` path accessors and the `Set*` path setters
(`TomlDocument.ParseDottedPath`). Segments are split on `.` outside brackets. A segment that
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
- `SetString` skips allocation when the new value equals the existing string, to avoid churning
  the arena.
- **Containers can only be created by the store.** `TomlTable`/`TomlArray` constructors are
  `internal`, and every container carries `mStore`, so a container can always allocate children in
  the right arena. Raw `TomlValue` insertion (`TomlTable.Insert`, `ReplaceValue`,
  `TomlArray.Add(TomlValue)`) is `internal` for the same reason.
- **`CloneInto(store)`** on `TomlValue`, `TomlTable` and `TomlArray` is the only deep-copy path.
  It re-allocates strings and containers in the target store and keeps table origin, inline
  sealing and `IsStatic`. `MergeFrom` uses it, so after a merge the temporary source store can be
  deleted safely.
- `TomlParseError` is a struct that owns `mMessage` (a heap `String`). Callers must `Dispose()`
  it, usually with `defer err.Dispose()`.
- PreserveStyle metadata (`TomlDocumentMetadata`, per-container `TomlContainerMetadataContext`)
  lives on the normal heap, not in the arena. The document owns it and deletes it on `Clear`, on
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
- **Generic, not virtual.** The parser is `TomlParserImpl<TCursor> where TCursor : ITomlCursor`,
  and cursors are structs with `[Inline]` hot methods. The interface is only a compile-time
  constraint, so peek/advance calls are never virtual. `TomlDocument.ReadWithCursor<TCursor>` is
  the shared driver.
- **`TomlByteCursor`** wraps a `Span<uint8>` and is zero-copy. `Slice` returns a view into the
  caller's input, and marks cost nothing.
- **`TomlBufferedStreamCursor`** uses a fixed buffer of `TomlDocument.sStreamBufferBytes` bytes
  (internal, 8192; tests lower it to force refills) plus a spill `String`.
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
  (byte offsets currently exclude the BOM on string input but include it on streams; status.md B11). A
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
- The resolver also runs the limit checks for tables and nodes it creates. In PreserveStyle mode
  it allocates node IDs for headers, array-of-tables elements and key/value entries.

### Error model

`TomlParseError { mKind, mMessage, mLine, mColumn, mOffset, mLength }`. Line and column are
1-based and `mOffset` is a byte offset. `TomlErrorKind` groups:

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
| Newlines and comments inside inline tables | rejected | accepted | `ParseInlineTable` via `SkipWsAndComments(mVersion != .V1_0)` |
| Trailing comma in an inline table | `UnexpectedToken` | accepted (recorded as `mHasTrailingComma`) | `ParseInlineTable` |

Writer downgrades when `TomlWriteConfig.Version = .V1_0`:

- ESC is written as `\u001b` instead of `\e`. Other control characters are always written as
  `\u00XX`; the writer never emits `\x`.
- PreserveStyle always writes seconds (normal mode always does anyway).
- Multi-line inline tables are written on one line.
- **Caveat:** in PreserveStyle, a clean string's original token is copied verbatim whatever the
  write version is, so a 1.1-only escape can leak into 1.0 output (status.md B9).

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
- An empty array of tables (non-static, `Count == 0`) is not written, so the key is lost on round
  trip (status.md B10).
- Keys are bare when every character is a bare-key character; otherwise they are written as basic
  quoted strings.
- Strings are basic, integers decimal, and floats use roundtrip `"R"` formatting (with `.0`
  appended when needed). `inf`/`-inf`/`nan` and `-0.0` are kept. Times always include seconds and
  trim trailing zeros from the fraction. An offset of 0 is written as `Z`. Nested containers are
  written inline.

### PreserveStyle mode

The metadata is a **sidecar**, so normal mode pays nothing for it. `TomlDocumentMetadata` holds:

- `TomlNodeStyle` records indexed by `TomlNodeId`. Each has a source range, an original-token
  reference, dirty flags, and key-format and value-format references.
- Owned copies of original string tokens (`mOriginalTokens`). **Source spans are never used to
  recover text**, because the input buffer or stream is gone after the parse.
- Pools of key formats and value formats. `TomlValueFormat` is a union of the string, integer,
  float, date/time, array and table formats.
- Comment sets per node (leading comments, trailing comment, blank-line separation), plus root
  (file header) and footer comments.
- `TomlDocumentStyle`, inferred once at the end of the parse: newline style (CRLF if CRLF lines
  are at least as common as LF-only lines), indent size, dotted-key preference, the dominant
  string style and the dominant array style.

Node identity is stored **beside the slots, not in `TomlValue`**. Each table and array has a
`TomlContainerMetadataContext` (only in PreserveStyle) that maps entry key or item index to a
`TomlNodeId` and holds the container's own node ID. This keeps `TomlValue` small and lets style
follow the slot or path. New entries inserted after the parse get node IDs automatically, and
`Rename` moves the ID to the new key.

**Dirty tracking** (`TomlDirtyFlags`):

- `Value`: set on an entry or item when its value is replaced (`MarkEntryDirty`, `MarkItemDirty`).
- `Children`: set on a container when an entry or item is inserted or removed after the parse
  (`MarkChildrenDirty`). The parser builds the tree with `mSuppressAutoDirty` set, then clears it
  with `ClearAutoDirtySuppression()`, so a freshly parsed document is clean.
- `Style` is defined but no current code sets it.
- `ReplaceValue` and `SetString` skip a semantically equal value, so the node stays clean. Other
  setters (array indexer, `TomlTableEntry.Value`, `Insert` on an existing key) still mark it dirty
  (status.md B4). `IsSemanticallyEqualTo` compares scalars by value (treating NaN as equal to NaN)
  and containers by identity.

**How a value is written in PreserveStyle** (`WriteValuePreserving`, `WriteArrayElementPreserving`,
`WriteValueWithDocumentStyle`), checked in this order:

1. A **string** with a node that is **completely clean** (`mDirtyFlags == .None`) and has an
   original token: the token is copied verbatim.
2. Any other **string**: written in the document's dominant string style (literal or multi-line
   forms), falling back to basic when that style cannot represent the content. The node's own
   captured string format is not consulted yet (status.md B5).
3. An **integer, float or date/time** with a captured value format: regenerated from the current
   value using that format (base, digit case and underscore grouping; exponent style, special-value
   sign and `-0.0`; `T` vs space, `Z` vs offset, seconds and fraction precision). The value always
   comes from the semantic model, so an edited number keeps its original formatting.
4. An **array** with a metadata context: inline or multi-line according to its `TomlArrayFormat`
   (indent, trailing comma, per-element comments). Elements recurse through these rules.
5. An **inline table**: `TomlTableFormat` spacing, and multi-line layout on v1.1 only.
6. Otherwise, the normal-mode writer.

Tables use the same three-phase order as normal mode, with some additions. Leading and trailing
comments are written around entries and headers. Header blocks are separated by a blank line. A
sub-table whose entries were written as dotted keys (`HasDottedPreference`) is written back as
`parent.key = value` lines instead of a `[header]`. Newlines follow the document's newline style.
Key quoting is the same as normal mode: the captured quoted-literal key style is not reused.

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

**TomlTester CLI** (`TomlTester/src/Program.bf`) takes `-toml 1.0|1.1` (default 1.1).

- Default (decoder): reads TOML from stdin and writes toml-test tagged JSON through
  `TomlTester/src/TomlSerializer.bf`. Tagged JSON is a test format, so the serializer lives in
  `TomlTester` and uses only the public API (`GetKeyAt`/`GetValueAt` walks). Each scalar becomes `{"type": ..., "value": ...}`, with types `string`,
  `integer`, `float`, `bool`, `datetime`, `datetime-local`, `date-local` and `time-local`.
- `-encode`: reads TOML and writes it back with the normal writer.
- `-from-json` (encoder): reads tagged JSON and writes TOML (`TomlTester/src/JsonToToml.bf`). The
  JSON is parsed with **BJSON**, a `TomlTester`-only dependency; the library never depends on it.
  An object with exactly two string members `type` and `value` is a scalar, any other object a
  table, any array an array. The document is built only through the public typed API
  (`Set*`, `AddTable`, `AddArray`, `TomlArray.Add*`), so this mode also exercises that API.
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
| Static array | An array written as `[...]` (`IsStatic = true`), as opposed to an array of tables built from `[[...]]` |
| Mark / slice / spill | Cursor retention: a mark pins input from its offset, a slice reads and releases it, and the spill holds retained bytes that the stream buffer evicted |
| Sidecar | PreserveStyle metadata kept outside the semantic tree and linked by `TomlNodeId` |
| Clean / dirty | Whether a node's value or children changed since the parse. Only fully clean string nodes reuse their original token |
