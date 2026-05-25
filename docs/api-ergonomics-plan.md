# API Ergonomics — Implementation Plan

## Goal

Reduce boilerplate when reading TOML values. Today every typed lookup requires two `Result` unwraps:

```bf
// TODAY — 2 unwraps
if (doc.Get("name") case .Ok(let val))
    if (val.TryGetString() case .Ok(let name))
        Console.WriteLine($"Hello, {name}!");
```

Target: one call per typed lookup.

---

## Changes

### 1. `TomlValue.bf` — `out` param variants (10 methods)

Every existing `TryGetXxx(): Result<T>` gets a sibling that returns `bool` with an `out` parameter.

```bf
// Existing (keep)
public Result<StringView> TryGetString() { ... }

// New
public bool TryGetString(out StringView value)
{
    if (this case .String(let s)) { value = s; return true; }
    value = default; return false;
}
```

All 10 types: `String`, `Integer`, `Float`, `Bool`, `OffsetDateTime`, `LocalDateTime`, `LocalDate`, `LocalTime`, `Array`, `Table`.

**Lines:** ~55 (5 per method × 10 methods + whitespace)

---

### 2. `TomlTable.bf` — indexer (1 property)

```bf
public Result<TomlValue> this[StringView key]
{
    get
    {
        if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
            return val;
        return .Err;
    }
}
```

**Lines:** ~8

---

### 3. `TomlDocument.bf` — typed path accessors (10 methods)

Traverse a dotted path and perform the type check in one call.

```bf
public bool TryGetString(StringView dottedPath, out StringView value)
{
    switch (Get(dottedPath))
    {
    case .Ok(let val):
        if (val.TryGetString(out value))
            return true;
    default:
    }
    value = default;
    return false;
}
```

Priority list (most-used first):

| # | Method | Use frequency |
|---|--------|---------------|
| 1 | `TryGetString` | Very common |
| 2 | `TryGetInt64` | Very common |
| 3 | `TryGetFloat` | Common |
| 4 | `TryGetBool` | Common |
| 5 | `TryGetTable` | Common (nested lookups) |
| 6 | `TryGetArray` | Common |
| 7 | `TryGetOffsetDateTime` | Uncommon |
| 8 | `TryGetLocalDateTime` | Uncommon |
| 9 | `TryGetLocalDate` | Rare |
| 10 | `TryGetLocalTime` | Rare |

**Lines:** ~65 (6 per method × 10 + whitespace)

---

### Result

```bf
// AFTER — 1 call
if (doc.TryGetString("name", var name))
    Console.WriteLine($"Hello, {name}!");
```

```bf
// Chain nested lookups
if (doc.TryGetTable("server", var server) &&
    server.TryGetString("host", var host))
    Console.WriteLine($"Connecting to {host}");
```

```bf
// Indexer with out param
if (doc.RootTable["server"] case .Ok(let val) && val.TryGetTable(var t))
    ...
```

---

## File summary

| File | Additions | Lines |
|------|-----------|-------|
| `TomlValue.bf` | 10 × `TryGetXxx(out T): bool` | ~55 |
| `TomlTable.bf` | `this[StringView]` indexer | ~8 |
| `TomlDocument.bf` | 10 × `TryGetXxx(path, out T): bool` | ~65 |
| **Total** | | **~128** |

---

## Not in scope

- Implicit conversion operators (`operator StringView()`) — tagged union enums cannot define operators in Beef.
- Serialization/deserialization via `[Reflect]` — requires reflection support not yet available.
- Fluent/chaining API (`doc["a"]["b"].AsString`) — deferred.
- `TomlDocument.GetValue(path)` panicking accessor — deferred; the `out` pattern covers the common case.
