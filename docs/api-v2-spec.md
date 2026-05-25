# TomlBeef API Specification — v2

## Overview

`TomlDocument` is the sole public entry point. No separate parser class, no writer class, no `Toml` static class. Everything flows through the document.

```
┌──────────────────────────────────────────────────┐
│                  TomlDocument                     │
│                                                   │
│  Create  new TomlDocument()                       │
│  Read    doc.Read(input)                          │
│  Read    doc.Read(input, config)                  │
│  Write   doc.Write(output)                        │
│  Write   doc.Write(output, config)                │
│  Access  doc.Get(path), doc.TryGetString(...)     │
│  Build   doc.mRootTable.Insert(...), etc.         │
│  Dispose defer delete doc                         │
└──────────────────────────────────────────────────┘
```

---

## Core Types

### TomlReadMode

```bf
public enum TomlReadMode
{
    Replace,   // Clear existing root table, populate from input
    Merge      // Retain existing content, insert new top-level keys
}

public enum MergeConflict
{
    Error,     // Duplicate key → error (default — strict TOML semantics)
    Skip,      // Keep existing value, ignore the incoming duplicate
    Overwrite  // Replace existing value with the incoming one
}
```

### TomlReadConfig

```bf
public struct TomlReadConfig
{
    public TomlReadMode Mode = .Replace;
    public MergeConflict OnConflict = .Error;  // only consulted when Mode == .Merge
    public TomlVersion Version = .V1_1;
}
```

Field initializers set the defaults for `default(TomlReadConfig)` and `.()`.

### TomlWriteConfig

```bf
public struct TomlWriteConfig
{
    public TomlVersion Version = .V1_1;
}
```

Currently tracks only the TOML version. A struct is used rather than a bare parameter to allow
adding output-formatting options (indentation, key ordering, etc.) without breaking existing call sites.

### Static defaults

```bf
public static TomlReadConfig DefaultReadConfig = .();
public static TomlWriteConfig DefaultWriteConfig = .();
```

Set once at startup to change behavior globally:

```bf
TomlDocument.DefaultReadConfig = .() { Mode = .Merge };
TomlDocument.DefaultWriteConfig = .() { Version = .V1_0 };
```

---

## TomlDocument API

### Lifecycle

```bf
/// @brief The root of a parsed TOML document.
/// Owns the complete value tree; disposal cleans up everything.
public class TomlDocument
{
    public TomlTable mRootTable ~ delete _;

    /// @brief Create an empty document with a fresh root table.
    public this()
    {
        mRootTable = new TomlTable(.Root);
    }
```

### Read — no config (uses DefaultReadConfig)

```bf
    /// @brief Parse a TOML string into this document according to the current DefaultReadConfig.
    /// @param input The TOML text to parse. Must be valid UTF-8.
    /// @return .Ok on success, or .Err with line/column info on failure.
    public Result<void, TomlParseError> Read(StringView input)
    {
        return Read(input, DefaultReadConfig);
    }
```

### Read — explicit config

```bf
    /// @brief Parse a TOML string into this document with an explicit configuration.
    /// @param input The TOML text to parse. Must be valid UTF-8.
    /// @param config Read mode and TOML version.
    /// @return .Ok on success, or .Err with line/column info on failure.
    public Result<void, TomlParseError> Read(StringView input, TomlReadConfig config)
    {
        let parser = scope TomlParserImpl(config.Version);

        // Fast path: nothing to preserve — parse directly into root
        if (mRootTable.Count == 0 || config.Mode == .Replace)
        {
            if (config.Mode == .Replace)
                mRootTable.Clear();
            let resolver = scope TomlPathResolver(mRootTable);
            return parser.Parse(input, resolver);
        }

        // Merge with existing content — transactional via temp table
        var incoming = new TomlTable(.Root);
        defer delete incoming;
        {
            let resolver = scope TomlPathResolver(incoming);
            if (parser.Parse(input, resolver) case .Err(let e))
                return .Err(e);
        }
        return mRootTable.MergeFrom(incoming, config.OnConflict);
    }
```

**Semantics by mode:**

| Mode | Existing content | On success | On error |
|------|-----------------|------------|----------|
| Replace | Cleared, then parsed directly into root | Document holds new content | Table may have partial data; caller checks `.Err` |
| Merge (non-empty) | Preserved | New top-level keys merged via temp table | Document **unchanged** — parsing used a temp table |
| Merge (empty root) | — | Parsed directly into root | Table may have partial data; caller checks `.Err` |

The flow optimizes the common paths: if the root table is empty or mode is Replace, parsing writes directly into `mRootTable` (no temp table allocation). Merge into an already-populated document uses a temp table for transactional safety — the existing data is never touched until parsing succeeds.

### TomlTable — new methods

```bf
/// @brief Remove all entries from this table, freeing owned values.
public void Clear()

/// @brief Merge keys from another table into this one.
/// @param source The table whose entries to merge. Unchanged on return.
/// @param onConflict How to handle duplicate keys (default: error).
/// @return .Ok on success, or .Err if a duplicate key was found with OnConflict == .Error.
public Result<void, TomlParseError> MergeFrom(TomlTable source, MergeConflict onConflict = .Error)
```

`MergeFrom` uses a two-pass strategy for transactional safety: first it validates all keys (checking for conflicts when `onConflict == .Error`), then it inserts or replaces. If validation fails, `this` is **unchanged** — no partial data leaks in.

**Merge conflicts:** Duplicate top-level keys during merge are handled according to `OnConflict`:
- `Error` — returns `.Err(DuplicateKey)`
- `Skip` — existing value is kept, incoming is ignored
- `Overwrite` — existing value is replaced with a clone of the incoming value

### Write — no config (uses DefaultWriteConfig)

```bf
    /// @brief Serialize this document to a TOML string using the current DefaultWriteConfig.
    /// @param output The destination string to append to.
    public void Write(String output)
    {
        Write(output, DefaultWriteConfig);
    }
```

### Write — explicit config

```bf
    /// @brief Serialize this document to a TOML string with an explicit configuration.
    /// @param output The destination string to append to.
    /// @param config Write options.
    public void Write(String output, TomlWriteConfig config)
    {
        TomlWriterImpl.Write(this, output, config.Version);
    }
```

### Path-based access (existing, unchanged)

```bf
    public Result<TomlValue> Get(StringView dottedPath)
```

### Typed path accessors (existing, unchanged)

```bf
    public bool TryGetString(StringView dottedPath, out StringView value)
    public bool TryGetInteger(StringView dottedPath, out int64 value)
    public bool TryGetFloat(StringView dottedPath, out double value)
    public bool TryGetBool(StringView dottedPath, out bool value)
    public bool TryGetTable(StringView dottedPath, out TomlTable value)
    public bool TryGetArray(StringView dottedPath, out TomlArray value)
    public bool TryGetOffsetDateTime(StringView dottedPath, out TomlOffsetDateTime value)
    public bool TryGetLocalDateTime(StringView dottedPath, out TomlLocalDateTime value)
    public bool TryGetLocalDate(StringView dottedPath, out TomlLocalDate value)
    public bool TryGetLocalTime(StringView dottedPath, out TomlLocalTime value)
```

---

## Caller Examples

### Parse and access (the common case)

```bf
var doc = new TomlDocument();
defer delete doc;

if (doc.Read(input) case .Err(let err))
{
    defer err.Dispose();
    Console.Error.WriteLine($"Error at {err.mLine}:{err.mColumn}: {err.mMessage}");
    return;
}

if (doc.TryGetString("name", var name))
    Console.WriteLine($"Hello, {name}!");
```

### Build programmatically and write

```bf
var doc = new TomlDocument();
defer delete doc;

doc.mRootTable.Insert("name", .String(new String("TomlBeef")));
doc.mRootTable.Insert("version", .Integer(42));

String output = scope String();
doc.Write(output);
```

### Multi-file merge

```bf
var doc = new TomlDocument();
defer delete doc;

// Base config (default Replace mode)
doc.Read(baseFile);

// Override layer — merge on top
doc.Read(overrideFile, .() { Mode = .Merge });
doc.Read(envFile,      .() { Mode = .Merge });

// Write combined
String output = scope String();
doc.Write(output);
```

### Set global default at startup

```bf
static void Main()
{
    // All Read() calls without an explicit config use Merge mode
    TomlDocument.DefaultReadConfig = .() { Mode = .Merge, Version = .V1_1 };
    ...
}
```

### Roundtrip

```bf
var doc = new TomlDocument();
defer delete doc;

doc.Read(originalInput);

String rewritten = scope String();
doc.Write(rewritten);
// rewritten is semantically equivalent to originalInput
```

### TOML v1.0

```bf
var doc = new TomlDocument();
defer delete doc;

doc.Read(v10Input, .() { Version = .V1_0 });

String output = scope String();
doc.Write(output, .() { Version = .V1_0 });
```

---

## Internal Design

### Parser (`TomlParserImpl`)

Not public. The class exists to thread mutable parse state (cursor, path resolver, depth counter) through private methods.

```bf
class TomlParserImpl
{
    private TomlCursor mCursor ~ delete _;
    private TomlPathResolver mPathResolver ~ delete _;
    private TomlVersion mVersion;
    private int mDepth = 0;
    private const int mMaxDepth = 256;

    public this(TomlVersion version = .V1_1)

    public Result<void, TomlParseError> Parse(StringView input, TomlPathResolver resolver)
```

Key changes from current:
- `mDocument` / `mRootTable` field removed — the target table is threaded through `TomlPathResolver` only
- Target table passed in by caller; parser constructs path resolver with it and never holds a direct reference
- On error: `target` may contain partial data from the failed parse. The caller handles cleanup
- On success: `target` is populated; caller integrates it into the document
- `TomlPathResolver` constructed with the target table directly

### Path resolver (`TomlPathResolver`)

Changed from holding a `TomlDocument` to holding a `TomlTable`:

```bf
public class TomlPathResolver
{
    private TomlTable mRootTable;  // was TomlDocument
    private TomlTable mCurrentTable;

    public this(TomlTable rootTable)  // was TomlDocument
    {
        mRootTable = rootTable;
        mCurrentTable = rootTable;
    }

    public void Reset()
    {
        mCurrentTable = mRootTable;
    }
}
```

### Writer (`TomlWriterImpl`)

Internal static class. No instance state. Version threaded as parameter from config.

```bf
static class TomlWriterImpl
{
    public static void Write(TomlDocument doc, String outStr, TomlVersion version)
    // ...
}
```

---

## Files

### New

| File | Contents |
|------|----------|
| (none) | TomlReadConfig and TomlReadMode defined in TomlDocument.bf |

### Modified

| File | Change |
|------|--------|
| `TomlDocument.bf` | Add `DefaultReadConfig`, `DefaultWriteConfig`, `Read()` × 2, `Write()` × 2. Add TomlReadConfig, TomlReadMode, TomlWriteConfig. |
| `TomlParser.bf` | `mDocument` → `mRootTable`, `Parse` signature change, path resolver construction |
| `TomlPathResolver.bf` | Constructor + field: `TomlDocument` → `TomlTable` |
| `TomlTest.bf` | Use `doc.Read(input)` / `doc.Write(output)` |
| `TomlTester/src/Program.bf` | Use `doc.Read(input)` / `doc.Write(output)` |
| `README.md` | Rewrite Quick Start and API sections |

### Deleted

| File | Reason |
|------|--------|
| `Toml.bf` | Superseded by TomlDocument |

### Unchanged

| File | Note |
|------|------|
| `TomlValue.bf` | TryGetXxx(out T) already added |
| `TomlTable.bf` | Indexer already added; add `Clear()` and `MergeFrom()`. |
| `TomlWriter.bf` | Already static, no further changes |
| `TomlArray.bf` | No changes |
| `TomlCursor.bf` | No changes |
| `TomlError.bf` | No changes |
| `TomlDateTime.bf` | No changes |
| `TomlChar.bf` | No changes |
| `TomlMixins.bf` | No changes |
| `TomlVersion.bf` | No changes |
| `TomlSerializer.bf` | No changes (used by toml-test harness) |

---

## Beef-Specific Notes

- **`out` vs `var`**: `doc.Read(input, out rootTable)` requires pre-declared variable. `out var x` does not compile in Beef. Use `var x` alone for inline declaration.
- **`default` for structs**: `default(TomlReadConfig)` and `.()` both respect field initializers, giving `{ Mode = .Replace, Version = .V1_1 }`.
- **Static field init**: `public static TomlReadConfig DefaultReadConfig = .();` is valid. Creates default-initialized config.
- **`scope` parser**: `let parser = scope TomlParserImpl(config.Version);` — parser lives for the `Read` call scope, destructor cleans up `~ delete _` fields.

---

## Error Handling Patterns

### Read error — do not use document

```bf
if (doc.Read(input) case .Err(let err))
{
    defer err.Dispose();
    // For Replace or empty root: mRootTable may have partial data from the failed parse.
    // For Merge into populated root: mRootTable is untouched.
    // In all cases: check .Err before accessing values.
    return;
}
```

### Merge error — document untouched

```bf
if (doc.Read(overrideFile, .() { Mode = .Merge }) case .Err(let err))
{
    defer err.Dispose();
    // doc retains original content; no keys from overrideFile were inserted
    return;
}
```

Note: if the root table was empty before the merge, the parser writes directly (optimization), so partial data may be present on error — same as Replace.

### Write never fails

`Write` appends to a `String` and has no failure modes. No `Result` needed.

---

## What Goes Away

| Before | After |
|--------|-------|
| `TomlParser parser = scope TomlParser();` | Nothing — eliminated |
| `parser.Parse(input)` | `doc.Read(input)` |
| `parser.TryParse(input, out doc)` | Merged into `doc.Read(input)` |
| `TomlWriter writer = scope TomlWriter();` | Nothing — eliminated |
| `writer.Write(doc, output)` | `doc.Write(output)` |
| `Toml.Read(input, out doc)` | `doc.Read(input)` |
| `Toml.Write(doc, output)` | `doc.Write(output)` |
| `Toml.bf` | File deleted |
