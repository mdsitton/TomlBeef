# Remaining Work Plan — TomlBeef

## Constraint

**No BJSON dependency in the TomlBeef library.** BJSON is restricted to `TomlTester` only (future JSON ingest for encoder testing). The TomlBeef library must be self-contained.

---

## Phase 1: Float Round-Trip Formatting (4 test failures → 0)

### Problem

`WriteTaggedFloat` uses `value.ToString(outStr)` — Beef's default `double.ToString()` outputs ~10 significant digits. This truncates long decimals (`3.141592653589793` → `3.1415926536`), uses scientific notation where exact decimal is expected (`9007199254740991` → `9.0072e+15`), and underflows tiny values to zero (`6.626e-34` → `0`).

### Fix

Beef's `Double` supports the `"R"` round-trip format specifier (same semantics as .NET):

```bf
// In WriteTaggedFloat, replace:
value.ToString(outStr);

// With:
value.ToString(outStr, "R", null);
```

The `"R"` format uses `ToString(val, str, roundTrip=true)` internally, which guarantees that parsing the output string reproduces the exact same `double` value. This is a one-line change in `TomlSerializer.bf`.

### Verification

The 4 failing tests all become passing because toml-test compares floats numerically (`strconv.ParseFloat` on both sides), not as strings. Round-trip format ensures the parsed value matches exactly.

---

## Phase 2: TOML Writer — `TomlWriter`

### Goal

Enable "parse TOML → modify document → write TOML" roundtrip. The output must be valid TOML v1.1 that a parser can re-ingest.

### New file: `src/TomlBeef/TomlWriter.bf`

```bf
public class TomlWriter
{
    public void Write(TomlDocument doc, String outStr);
    public void Write(TomlDocument doc, Stream stream);
}
```

### Design decisions

**Output style:** Produce canonical-ish TOML. Not necessarily identical to input formatting, but semantically equivalent.

- Tables: use `[header]` form (not dotted keys). Emit in tree order.
- Array-of-tables: use `[[header]]` form. Walk arrays depth-first.
- Bare keys when possible, quoted keys when needed (non-bare chars).
- Strings: prefer basic strings; use literal strings when the value contains many backslashes or quotes.
- Integers: decimal form always (even if originally hex). Simpler and lossless.
- Floats: `"R"` round-trip format for exact reproduction.
- Dates: RFC 3339 format.
- Key ordering: emit in insertion order (from `KeyOrder`).

**Implementation approach:**

```
WriteDocument(doc, outStr)
  → write key/values in root table
  → for each sub-table, write [header] + its key/values
  → for each array-of-tables, iterate elements, write [[header]] for each
```

Helper methods:
- `WriteKey(StringView key)` — quotes if needed
- `WriteString(StringView value, bool preferLiteral)` — basic or literal with proper escaping
- `WriteInteger(int64 value)` — decimal format
- `WriteFloat(double value)` — "R" format, special-case ±inf/±nan (always lowercase)
- `WriteBool(bool value)` — lowercase
- `WriteDateTime(TomlOffsetDateTime)` — RFC 3339
- `WriteLocalDateTime(TomlLocalDateTime)` — RFC 3339 sans offset
- `WriteLocalDate(TomlLocalDate)` — `YYYY-MM-DD`
- `WriteLocalTime(TomlLocalTime)` — `HH:MM:SS[.fff]`
- `WriteArray(TomlArray)` — `[v1, v2, ...]` with proper indentation
- `WriteInlineTable(TomlTable)` — `{k = v, ...}` for leaf inline tables

**Path tracking:** Track the current table path while walking the tree. When encountering a sub-table value in the current table, emit a `[path]` header and recurse.

**Important subtleties:**
- Root table key/vals come first (no header).
- Then walk remaining tables in insertion order, skipping already-emitted ones.
- Need to track which tables have been emitted to avoid duplicates.
- Empty tables still need headers (TOML allows empty tables).
- Arrays that are NOT array-of-tables should be written as inline values. Arrays created by `[[header]]` are array-of-tables — detect via `mIsStatic = false`.

### File changes

- **New:** `src/TomlBeef/TomlWriter.bf`
- No modifications to existing files.

---

## Phase 3: Deep Copy — `Clone()`

### Problem

No way to duplicate a `TomlValue`, `TomlTable`, or `TomlArray`. If a user wants to modify a document while keeping the original, they must re-parse.

### Implementation

Add `Clone()` methods that perform deep copies:

```bf
// TomlValue.bf — add inside enum:
public TomlValue Clone()
{
    switch (this)
    {
    case .String(let s):      return .String(new String(s));
    case .Integer(let v):     return .Integer(v);
    case .Float(let v):       return .Float(v);
    case .Bool(let v):        return .Bool(v);
    case .OffsetDateTime(let v): return .OffsetDateTime(v);
    case .LocalDateTime(let v):  return .LocalDateTime(v);
    case .LocalDate(let v):      return .LocalDate(v);
    case .LocalTime(let v):      return .LocalTime(v);
    case .Array(let arr):     return .Array(arr.Clone());
    case .Table(let tbl):     return .Table(tbl.Clone());
    }
}
```

```bf
// TomlTable.bf — add method:
public TomlTable Clone()
{
    TomlTable result = new TomlTable(mOrigin);
    result.mIsInlineSealed = mIsInlineSealed;
    for (int i = 0; i < mKeyOrder.Count; i++)
    {
        String key = mKeyOrder[i];
        TomlValue val = mEntries[key];
        result.Insert(key, val.Clone());
    }
    return result;
}
```

```bf
// TomlArray.bf — add method:
public TomlArray Clone()
{
    TomlArray result = new TomlArray(mItems.Count);
    result.mIsStatic = mIsStatic;
    for (int i = 0; i < mItems.Count; i++)
        result.Add(mItems[i].Clone());
    return result;
}
```

Scalar types (int64, double, bool, date/time structs) are bitwise-copied. Heap types (String, TomlArray, TomlTable) are deep-copied.

### File changes

- `src/TomlBeef/TomlValue.bf` — add `Clone()` to enum
- `src/TomlBeef/TomlTable.bf` — add `Clone()` method
- `src/TomlBeef/TomlArray.bf` — add `Clone()` method

---

## Phase 4: Safe Accessors — `TryGetXxx`

### Problem

`TomlValue.AsString`, `AsInteger`, etc. call `Runtime.FatalError` on type mismatch — they kill the process. This is appropriate for internal code that knows the type statically, but hostile for external API consumers who are exploring a dynamic document.

### Implementation

Add `TryGet` methods that return `Result<T, void>` or use `out` parameters:

```bf
// TomlValue.bf — add to enum:
public Result<StringView> TryGetString()
{
    if (this case .String(let s))
        return StringView(s);
    return .Err;
}

public Result<int64> TryGetInteger()
{
    if (this case .Integer(let v))
        return v;
    return .Err;
}

public Result<double> TryGetFloat()
{
    if (this case .Float(let v))
        return v;
    return .Err;
}

public Result<bool> TryGetBool()
{
    if (this case .Bool(let v))
        return v;
    return .Err;
}

// ... similar for date/time types, Array, Table
```

Keep the existing `AsXxx` properties for internal use (they assert correctness).

### File changes

- `src/TomlBeef/TomlValue.bf` — add 10 `TryGetXxx()` methods

---

## Phase 5: Document Convenience Access

### Problem

Users must reach into `doc.RootTable` and manually navigate the table tree. No path-based lookup.

### Implementation

Add to `TomlDocument`:

```bf
// TomlDocument.bf — add methods:
public Result<TomlValue> Get(StringView dottedPath)
{
    // Split on '.', walk tables, return value at final segment
    TomlTable current = mRootTable;
    // ... split and navigate ...
}

public Result<TomlTable> GetTable(StringView dottedPath)
{
    // Like Get but asserts the result is a table
}
```

Could also add indexer syntax: `doc["fruit.apple.color"]`.

A simple split-on-dot implementation works for most paths. Full key-path parsing (supporting quoted keys with dots inside) would use the existing key parser, but that's overkill for v1 — bare dotted paths cover the common case.

### File changes

- `src/TomlBeef/TomlDocument.bf` — add `Get()` method

---

## Phase 6: Date/Time Validation

### Problem

`TomlLocalDate(2024, 13, 40)` compiles silently. No validation on construction.

### Implementation

Add validation to each date/time struct constructor using `Runtime.Assert` (debug-only) or by returning `Result` from factory methods.

For a struct (value type), constructors can't return `Result` — they must either assert or set to a sentinel. Since these are API types users construct directly, the best approach is debug assertions:

```bf
public this(int32 year, int32 month, int32 day)
{
    Runtime.Assert(month >= 1 && month <= 12);
    Runtime.Assert(day >= 1 && day <= 31);
    // ...
    mYear = year; mMonth = month; mDay = day;
}
```

For release builds, the assertions are stripped — invalid dates are "garbage in, garbage out", which is standard for value-type constructors in systems languages.

Alternatively, provide `static Result<TomlLocalDate> Create(...)` factory methods that validate and return errors. Keep the direct constructor for trusted internal use.

### File changes

- `src/TomlBeef/TomlDateTime.bf` — add assertions to constructors

---

## Phase 7 (Optional): UTF-8 Validation Integration

### Problem

`Parse()` runs a full UTF-8 validation pass over the input, then the cursor walks it again. For large files, this doubles scan cost.

### Implementation

Remove the separate pre-pass from `Parse()`. Instead, validate UTF-8 incrementally in `TomlCursor.AdvanceByte()` — since every byte of input passes through it, validation there catches all invalid sequences with no extra scan.

Add a `bool mUtf8Valid = true` flag to the cursor. In `AdvanceByte()`, when encountering a byte with the high bit set, call `Utf8SequenceLength()`. If invalid, set `mUtf8Valid = false` and record the position. The parser checks this flag periodically (or at document end) and returns an error.

Low priority — the current approach is correct, just slightly slower.

---

## Implementation Order

| Phase | What | Files | Effort |
|-------|------|-------|--------|
| 1 | Float "R" format | `TomlSerializer.bf` (1 line) | Trivial |
| 2 | TOML Writer | New: `TomlWriter.bf` | Medium |
| 3 | Clone() | `TomlValue.bf`, `TomlTable.bf`, `TomlArray.bf` | Small |
| 4 | TryGet accessors | `TomlValue.bf` | Small |
| 5 | Document Get() | `TomlDocument.bf` | Small |
| 6 | Date validation | `TomlDateTime.bf` | Trivial |
| 7 | UTF-8 integration | `TomlCursor.bf`, `TomlParser.bf` | Optional |

**Recommended order:** 1 → 4 → 3 → 5 → 6 → 2 → 7

Phases 1-6 are independent and can be done in any order. Phase 2 (TOML writer) is the largest piece. Phase 1 unblocks 100% valid test pass immediately.
