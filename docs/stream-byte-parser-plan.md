# Stream- and Byte-Native Parser Plan

## Goal

Support both high-throughput byte-native parsing and stream-native parsing without forcing one path through the other.

Primary use cases:

- **Byte-native**: many small/medium TOML inputs already resident in memory; minimize copies and overhead.
- **Stream-native**: very large files or caller-owned I/O; avoid buffering the entire input before parsing.

The parser currently assumes contiguous input via `StringView` and frequently uses this pattern:

```bf
int start = mCursor.Offset;
while (!mCursor.IsEOF && TomlChar.IsBareValueChar(mCursor.PeekByte()))
    mCursor.AdvanceByte();

StringView token = mCursor.Slice(start, mCursor.Offset - start);
```

The plan preserves that style by introducing explicit anchored slices and concrete cursor types.

---

## Non-goals

- Do not implement a true streaming/SAX TOML reader in this phase.
- Do not avoid building the `TomlDocument` DOM; stream parsing still builds the full document tree.
- Do not use interface dispatch for hot cursor operations.
- Do not require every input path to copy into a `String` first.

---

## Key design decisions

### 1. Avoid interface-typed cursor storage (avoid vtable dispatch)

Storing a cursor as `ITomlCursor` would make every `PeekByte()`/`AdvanceByte()` call virtual. The parser stores `TCursor` via a generic type parameter constrained to `ITomlCursor`, and the compiler emits concrete calls to the struct's methods — no vtable, no boxing. The interface exists only as a compile-time constraint, not for runtime dispatch.

Use `[Inline]` on trivial cursor methods (`PeekByte`, `IsEOF`, `AdvanceByte`, `Mark`, `Offset`, `Line`, `Column`) so the compiler can eliminate call overhead entirely in hot loops.

### 2. Use explicit marks for slice-producing parse operations

Instead of arbitrary `Slice(start, len)` tied to a global offset, introduce a cursor mark:

```bf
let mark = mCursor.Mark();
while (...)
    mCursor.AdvanceByte();
StringView token = mCursor.Slice(mark, scratch);
```

`Slice(mark, scratch)` returns a `StringView` valid only until the next cursor operation that can move/refill the buffer. The parser must consume the returned view immediately and must not store it.

### 3. Byte cursor remains zero-copy

For contiguous byte input, `Slice(mark, scratch)` returns a direct view into the original bytes.

### 4. Stream cursor uses buffered anchored windows

For stream input, `Slice(mark, scratch)` returns a direct view into the stream buffer when possible. If the marked region crosses buffer boundaries or grows too large, it falls back to copying into `scratch` or an internal spill buffer.

---

## Proposed public API

### Existing string API remains

```bf
public Result<void, TomlParseError> Read(StringView input)
public Result<void, TomlParseError> Read(StringView input, TomlReadConfig config)
```

These are convenience wrappers around byte-native parsing.

### Byte-native API

```bf
public Result<void, TomlParseError> ReadBytes(Span<uint8> data)
public Result<void, TomlParseError> ReadBytes(Span<uint8> data, TomlReadConfig config)
```

`Span<uint8>` is the primary byte-native API. Beef auto-converts `List<uint8>` to `Span<uint8>`, so callers can pass lists directly without separate overloads.

Notes:

- The caller owns the backing memory.
- The backing memory must remain valid for the duration of the call.
- Parsed keys/strings are copied into owned TOML values as needed, so the resulting document does not borrow from the input after `ReadBytes` returns.

### Stream-native API

```bf
public Result<void, TomlParseError> Read(Stream stream)
public Result<void, TomlParseError> Read(Stream stream, TomlReadConfig config)
```

Notes:

- The stream remains caller-owned.
- The parser reads from the stream but does not close it.
- The parser should not require seeking.
- Stream parser still builds a full `TomlDocument` DOM.

### File helpers

File helpers become convenience wrappers, not core parser paths:

```bf
public Result<void, TomlParseError> ReadFile(StringView path)
public Result<void, TomlParseError> ReadFile(StringView path, TomlReadConfig config)
```

Implementation options:

- Open a file stream and call `Read(stream, config)`, or
- Use `File.ReadAll` and call `ReadBytes` for small-file convenience.

This can be chosen later based on desired file-helper semantics.

---

## Cursor types

### Cursor mark

A mark records the start of a slice-producing span.

```bf
struct TomlCursorMark
{
    public int64 Offset;
}
```

For byte cursors, `Offset` can map directly to an input index. For stream cursors, it is a global stream-relative byte offset.

### Byte cursor

```bf
struct TomlByteCursor
{
    private Span<uint8> mData;
    private int mOffset;
    private int mLine;
    private int mColumn;

    public int Offset => mOffset;
    public int Line => mLine;
    public int Column => mColumn;
    public bool IsEOF => mOffset >= mLength;

    [Inline] public char8 PeekByte(int lookahead = 0);
    [Inline] public char8 AdvanceByte();
    public char32 AdvanceUtf8();

    [Inline] public TomlCursorMark Mark();
    [Inline] public StringView Slice(TomlCursorMark mark, String scratch);
}
```

`Slice()` ignores `scratch` and returns a direct `StringView` into `mData`.

The cursor is an internal implementation detail. It should store `Span<uint8>` rather than raw pointer/length. Raw pointers should only appear at adapter boundaries when creating a `Span<uint8>` from `StringView`, `List<uint8>`, or other Beef APIs that expose pointer-backed storage.

### Buffered stream cursor

```bf
struct TomlBufferedStreamCursor
{
    private Stream mStream;
    private uint8[] mBuffer;
    private int mPos;
    private int mEnd;
    private int64 mBaseOffset;
    private int mLine;
    private int mColumn;

    private bool mHasMark;
    private int mMarkLocal;
    private int64 mMarkOffset;

    private int mInitialBufferBytes;
    private int mMaxBufferBytes;

    private String mSpill;     // fallback only after max buffer size/resource limit
    private bool mUsingSpill;

    public int64 Offset => mBaseOffset + mPos;
    public int Line => mLine;
    public int Column => mColumn;
    public bool IsEOF { get; }

    public char8 PeekByte(int lookahead = 0);
    public char8 AdvanceByte() mut;
    public char32 AdvanceUtf8() mut;

    public TomlCursorMark Mark();
    public StringView Slice(TomlCursorMark mark, String scratch);
    private Result<void, TomlParseError> EnsureAvailable(int lookahead) mut;
    private Result<void, TomlParseError> Refill() mut;
    public void Dispose() mut;
}
```

### Cursor structs, not classes

Cursor types should be `struct`s rather than classes. They are parser-local state machines and do not need identity or heap allocation.

Benefits:

- removes one allocation per parse for byte-native parsing;
- lets `TomlParserImpl<TCursor>` store cursor state inline;
- makes ownership clearer: the parser owns the cursor value, while the cursor borrows input/span/stream references;
- avoids destructor/finalizer concerns for the byte cursor.

Beef requirement: methods that mutate cursor fields must be marked `mut` after the signature, for example:

```bf
public char8 AdvanceByte() mut
public Result<void, TomlParseError> Refill() mut
```

`TomlByteCursor` borrows input memory and does not need `Dispose()`. `TomlBufferedStreamCursor` borrows its buffer and spill string from the caller, so it also does not need `Dispose()` beyond clearing the stream reference. The caller owns the buffer and spill lifetime.

---

## Stream buffer compaction rule

When no mark is active, refill can discard bytes before `mPos`.

When a mark is active, refill may discard bytes before the mark, but must preserve bytes at and after the mark.

Before compaction:

```text
buffer: [ discardable ][ mark ........ current/end ]
                    ^ keep from here onward
```

After compaction:

```text
buffer: [ mark ........ current/end ][ newly read bytes ... ]
        ^ markLocal = 0
```

Pseudo-code:

```bf
private void CompactForRefill() mut
{
    int keepStart = mHasMark ? mMarkLocal : mPos;
    int keepLen = mEnd - keepStart;

    if (keepLen > 0)
        Buffer.MemoryCopy(&mBuffer[keepStart], &mBuffer[0], keepLen);

    mBaseOffset += keepStart;
    mPos -= keepStart;
    mEnd = keepLen;

    if (mHasMark)
        mMarkLocal = 0;
}
```

If `keepLen` approaches buffer capacity and more bytes are needed, the cursor should first grow the buffer rather than immediately spilling. This preserves direct `StringView` slices for unusually large-but-reasonable tokens.

---

## Buffer growth and spill fallback

A marked span may exceed the current stream buffer capacity. Examples:

- very long bare values
- unusually long keys
- long date/time-like invalid tokens
- long basic/literal strings if parsed with a mark

The preferred behavior is:

1. Compact first, preserving bytes from the mark onward.
2. If the marked span plus required lookahead still cannot fit, grow the buffer.
3. Use geometric growth, usually doubling:
   ```bf
   newSize = Math.Min(mBuffer.Count * 2, mMaxBufferBytes);
   ```
4. Copy the preserved marked span into the new buffer at index 0.
5. Continue reading new bytes after `mEnd`.
6. Only spill if the marked span exceeds `mMaxBufferBytes` or a configured token/string limit.

This keeps the common and medium-large cases zero-copy while still bounding memory usage.

### Growth pseudo-code

```bf
private Result<void, TomlParseError> GrowForMarkedSpan(int requiredFreeBytes) mut
{
    int keepStart = mHasMark ? mMarkLocal : mPos;
    int keepLen = mEnd - keepStart;
    int requiredSize = keepLen + requiredFreeBytes;

    if (requiredSize <= mBuffer.Count)
        return .Ok;

    int newSize = mBuffer.Count;
    while (newSize < requiredSize && newSize < mMaxBufferBytes)
        newSize *= 2;

    if (newSize > mMaxBufferBytes)
        newSize = mMaxBufferBytes;

    if (newSize < requiredSize)
        return BeginSpillOrResourceLimit(requiredSize);

    uint8[] newBuffer = new uint8[newSize];
    if (keepLen > 0)
        Buffer.MemoryCopy(&mBuffer[keepStart], &newBuffer[0], keepLen);

    delete mBuffer;
    mBuffer = newBuffer;

    mBaseOffset += keepStart;
    mPos -= keepStart;
    mEnd = keepLen;
    if (mHasMark)
        mMarkLocal = 0;

    return .Ok;
}
```

### Spill fallback

Spill should be a rare fallback, not the primary behavior. It is useful when:

- the marked span exceeds `mMaxBufferBytes`, but the configured TOML limits still allow it;
- the caller chooses a low max buffer size but still permits large strings/tokens;
- a future streaming event parser wants to avoid very large contiguous buffers.

When spilling:

1. Copy bytes from mark through current buffered end into `mSpill`.
2. Clear the active contiguous mark.
3. Continue reading/refilling normally.
4. While spill is active, `AdvanceByte()` appends consumed bytes to `mSpill` when they are part of the marked region.
5. `Slice(mark, scratch)` returns `StringView(mSpill)` or copies to caller-provided `scratch` and returns `StringView(scratch)`.

Preferred ownership:

- Cursor borrows `mSpill` from the caller; the caller owns its lifetime.
- Parser can pass a local `scratch` for APIs where immediate consumption is guaranteed.
- Avoid returning a `StringView` to temporary stack storage after it goes out of scope.

---

## Content-aware refill heuristic

Before starting a slice-producing parse, call:

```bf
mCursor.PrepareForSlice();
let mark = mCursor.Mark();
```

For byte cursor, `PrepareForSlice()` is a no-op.

For stream cursor, `PrepareForSlice()` should:

- If current position is near the end of the buffer, compact/refill before marking.
- Try to provide at least `MinContiguousSliceBytes` bytes after current position.
- Default `MinContiguousSliceBytes` can be 8 KiB.

This makes common TOML tokens zero-copy in stream mode.

Common small slice producers:

- bare keys
- booleans
- numbers
- date/time values
- simple bare tokens

Large strings can either:

- continue using append-to-`String` parsing as today, or
- use marks with spill fallback.

---

## Parser refactor steps

### Phase 1 — introduce marks on current cursor

Keep current contiguous cursor, but replace integer offset slicing with marks:

```bf
let mark = mCursor.Mark();
while (...)
    mCursor.AdvanceByte();
StringView token = mCursor.Slice(mark, scratch);
```

Targets:

- `ParseBool`
- `ParseBareValue`
- `ParseBareKey`
- literal key parsing if it slices
- any other `Slice(start, length)` usage

This phase should not change behavior.

### Phase 2 — rename current cursor to byte cursor

Convert current `TomlCursor` class into a `TomlByteCursor` struct or equivalent.

Add a constructor for:

```bf
TomlByteCursor(Span<uint8> input)
```

`StringView` and `List<uint8>` callers should adapt to `Span<uint8>` before constructing the cursor. Keep parser behavior identical.

### Phase 3 — generic parser over cursor

Refactor:

```bf
class TomlParserImpl<TCursor>
{
    private TCursor mCursor;
}
```

Or equivalent static-dispatch approach.

Verify that cursor calls compile and tests pass. Because cursor types are structs, any parser method that mutates `mCursor` must be allowed to mutate the parser's cursor field. Watch for Beef's `mut` requirements on struct methods.

Instantiation examples:

```bf
let parser = scope TomlParserImpl<TomlByteCursor>(config.Version);
let parser = scope TomlParserImpl<TomlBufferedStreamCursor>(config.Version);
```

If Beef generics do not produce good code or syntax becomes too awkward, fall back to duplicated parser classes with shared helper functions.

### Phase 4 — add byte-native public APIs

Add `ReadBytes(Span<uint8>)` overloads to `TomlDocument`. Beef auto-converts `List<uint8>` to `Span<uint8>`, so no separate list overload is needed.

`Read(StringView)` wraps string pointer/length into a `Span<uint8>` after UTF-8 validation.

### Phase 5 — implement buffered stream cursor

Implement `TomlBufferedStreamCursor` as a struct with:

- refill
- compaction
- mark preservation
- geometric buffer growth while a marked span needs more contiguous space
- spill fallback only after max buffer size/resource limits
- line/column tracking
- `PeekByte(lookahead)` support

Initial buffer size: configurable, default 8 KiB or 16 KiB. Maximum buffer size should also be configurable to prevent unbounded memory growth.

### Phase 6 — add stream-native public APIs

Add:

```bf
public Result<void, TomlParseError> Read(Stream stream)
public Result<void, TomlParseError> Read(Stream stream, TomlReadConfig config)
```

### Phase 7 — revisit file helpers

Decide whether `ReadFile` should:

- use `File.ReadAll` + `ReadBytes` for high throughput on normal files, or
- open a stream + `Read(Stream)` for lower memory usage.

Possible config option:

```bf
public TomlFileReadMode FileReadMode = .BufferedBytes; // or .Stream
```

But avoid adding this unless there is a strong need.

---

## UTF-8 validation plan

Current parsing validates UTF-8 up front for contiguous input.

For stream input, validation must be incremental.

Options:

### Option A — validate in cursor `AdvanceUtf8`

- `AdvanceUtf8()` decodes and validates each scalar.
- String parsing calls `AdvanceUtf8()` when appending non-ASCII chars.
- Byte-level parsing still uses `AdvanceByte()` for structural ASCII.

### Option B — validate during refill

- Validate bytes as they enter the buffer.
- Must handle UTF-8 sequences split across buffer boundaries.
- More complex but catches invalid input earlier.

Recommendation:

- Start with Option A.
- Keep byte path's existing pre-validation initially.
- Later unify validation if desired.

---

## Error location tracking

Both cursors must maintain:

- byte offset
- line
- column

Newline behavior must match current cursor:

- `\n` increments line and resets column
- `\r\n` is treated as one newline where appropriate
- bare `\r` remains invalid outside permitted contexts

For stream cursor, `Offset` should be global byte offset, not local buffer offset.

---

## Resource limits

Add later to `TomlReadConfig`:

```bf
public int MaxInputBytes = 0;   // 0 = unlimited
public int MaxTokenBytes = 0;
public int MaxStringBytes = 0;
public int MaxDepth = 256;
public int MaxKeys = 0;
public int StreamBufferBytes = 8192;
public int MaxStreamBufferBytes = 1024 * 1024; // example default; tune later
```

Stream cursor should enforce:

- maximum total bytes read
- maximum marked token length
- maximum string length

Parser already has depth tracking; move hard-coded `mMaxDepth` into config eventually.

---

## Writer follow-up plan

The writer can receive a similar sink abstraction, but it should be a separate phase.

Avoid virtual sink calls in inner loops if possible.

Possible generic sink design:

```bf
class TomlWriterImpl<TSink>
{
    private TSink mSink;
}
```

Sinks:

- `TomlStringSink`
- `TomlByteListSink`
- `TomlStreamSink`

Public APIs:

```bf
public void Write(String output)
public Result<void, TomlParseError> Write(Stream stream)
public Result<void, TomlParseError> WriteBytes(List<uint8> output)
```

For now, stream/file write can serialize to `String` first and write once. Incremental stream writing can come later.

---

## Open questions

1. Does Beef monomorphize generic class methods enough to avoid dispatch overhead?
2. Cursors borrow their backing memory from the caller. `TomlByteCursor` borrows a span; `TomlBufferedStreamCursor` borrows a buffer and spill string. Both are safe to copy by value — all copies share the same borrowed memory.
3. Should `ReadFile` prefer byte-native or stream-native by default?
4. Should stream parsing be added to `TomlDocument`, or should there be a separate `TomlReader` later?
5. What should the exact lifetime contract be for `Slice(mark, scratch)`?
6. Should spill storage be cursor-owned, parser-owned, or caller-provided per parse method?

---

## Success criteria

- Existing tests continue passing.
- Byte-native parsing performs at least as well as current `StringView` parsing.
- Stream parsing can parse inputs larger than memory-friendly `String` allocation sizes.
- Common stream tokens parse without allocation when they fit in the buffer.
- No virtual calls in `PeekByte`, `AdvanceByte`, or token scanning loops.
- Error locations remain accurate.
- UTF-8 behavior remains TOML-compliant.
