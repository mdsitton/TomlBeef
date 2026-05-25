# TomlBeef

A TOML v1.1.0 parser and writer for the [Beef programming language](https://www.beeflang.org/).

Compliant with the full [TOML v1.1.0 specification](https://toml.io/en/v1.1.0). Validated against the official [toml-test](https://github.com/toml-lang/toml-test) suite.

## Quick Start

```bf
using TomlBeef;

// Read a TOML string
var doc = new TomlDocument();
defer delete doc;

if (doc.Read(input) case .Err(let err))
{
    defer err.Dispose();
    Console.Error.WriteLine($"Parse error at {err.mLine}:{err.mColumn}: {err.mMessage}");
    return;
}

// doc is valid here — no nesting, straight-line code
if (doc.TryGetString("name", var name))
    Console.WriteLine($"Hello, {name}!");

// Write back to TOML
String output = scope String();
doc.Write(output);
Console.WriteLine(output);
```

## API Overview

### Reading

```bf
var doc = new TomlDocument();
defer delete doc;

// Recommended: early-exit pattern
if (doc.Read(input) case .Err(let err))
{
    defer err.Dispose();
    // handle error, log, return...
}
// doc is valid — code continues at top level, no nesting
```

`doc.Read` returns `Result<void, TomlParseError>`. On success, the document is populated. On error, the document's content is undefined — do not use. The caller owns the document and must eventually `delete` it.

A TOML specification version can be passed: `doc.Read(input, .() { Version = .V1_0 })`. Defaults to V1_1.

Use `Replace` mode (the default) to clear existing content before parsing. Use `Merge` mode to layer additional keys on top of existing content:

```bf
doc.Read(baseFile);                              // Replace (default)
doc.Read(overrideFile, .() { Mode = .Merge });   // Merge on top
```

`TomlDocument` owns the entire parsed tree. Dispose it when done (`defer delete doc`).

### Reading Values

**Path-based lookup** — bare dotted keys only (no quoted segments):

```bf
// Generic lookup — returns Result<TomlValue>
if (doc.Get("fruit.apple.color") case .Ok(let val))
    ...

// Typed one-call accessors — navigate path + type check in one call
if (doc.TryGetString("fruit.apple.color", var color))
    Console.WriteLine(color);

if (doc.TryGetTable("server", var server))
    server.TryGetString("host", var host);
```

Full set of document-level typed accessors: `TryGetString`, `TryGetInteger`, `TryGetFloat`, `TryGetBool`, `TryGetTable`, `TryGetArray`, `TryGetOffsetDateTime`, `TryGetLocalDateTime`, `TryGetLocalDate`, `TryGetLocalTime`.

**Navigating the tree directly:**

```bf
doc.mRootTable           // The root table
table["key"]             // Indexer → Result<TomlValue> (.Err if missing)
table.Entries            // Dictionary<String, TomlValue>
table.KeyOrder           // List<String> in insertion order
table.ContainsKey("key")
table.TryGetValue("key", out value)
```

**Inspecting a TomlValue** — pattern matching is the idiomatic approach:

```bf
switch (value)
{
case .String(let s):  Console.WriteLine(s);
case .Integer(let i): Console.WriteLine($"{}", i);
case .Float(let f):   Console.WriteLine($"{}", f);
case .Bool(let b):    Console.WriteLine(b ? "yes" : "no");
case .Table(let t):   // navigate into t
case .Array(let a):   // iterate a
case .OffsetDateTime(let dt): // dt.mYear, dt.mMonth, ...
case .LocalDateTime(let dt):
case .LocalDate(let d):
case .LocalTime(let t):
}
```

**Convenience methods:**

```bf
// Type-checking properties
value.IsString   value.IsInteger   value.IsFloat   value.IsBool
value.IsTable    value.IsArray
value.IsOffsetDateTime  value.IsLocalDateTime
value.IsLocalDate       value.IsLocalTime

// Safe accessors — return Result, no crash on type mismatch
value.TryGetString()   // → Result<StringView>
value.TryGetInteger()  // → Result<int64>
value.TryGetFloat()    // → Result<double>
value.TryGetBool()     // → Result<bool>
value.TryGetTable()    // → Result<TomlTable>
value.TryGetArray()    // → Result<TomlArray>
// ... same for date/time types

// Out-parameter variants — return bool, no crash on type mismatch
value.TryGetString(var s)        // → true/false
value.TryGetInteger(var i)       // → true/false
value.TryGetFloat(var f)         // → true/false
value.TryGetBool(var b)          // → true/false
value.TryGetTable(var t)         // → true/false
value.TryGetArray(var a)         // → true/false
value.TryGetOffsetDateTime(var dt)
value.TryGetLocalDateTime(var dt)
value.TryGetLocalDate(var d)
value.TryGetLocalTime(var t)

// Unsafe accessors — FatalError on type mismatch (use only when type is known)
value.AsString   value.AsInteger   value.AsFloat   value.AsBool
value.AsTable    value.AsArray
value.AsOffsetDateTime  value.AsLocalDateTime
value.AsLocalDate       value.AsLocalTime
```

### Iterating Tables

```bf
for (int i = 0; i < table.KeyOrder.Count; i++)
{
    String key = table.KeyOrder[i];
    TomlValue value = table.Entries[key];
    // ...
}
```

### Iterating Arrays

```bf
for (int i = 0; i < arr.Count; i++)
{
    TomlValue item = arr[i];
    // ...
}
```

### Writing TOML

```bf
String output = scope String();
doc.Write(output);
```

Or with v1.0 compatibility: `doc.Write(output, .() { Version = .V1_0 })`.

The writer produces valid TOML v1.1 output. Sub-tables are emitted as `[header]` blocks. Array-of-tables use `[[header]]`. Scalar values within a table are grouped before sub-table headers.

### Building Values Programmatically

```bf
var doc = new TomlDocument();
var root = doc.mRootTable;

// Scalars
root.Insert("name", .String(new String("TomlBeef")));
root.Insert("version", .Integer(1));
root.Insert("released", .Bool(true));

// Arrays
var arr = new TomlArray();
arr.Add(.Integer(1));
arr.Add(.Integer(2));
arr.Add(.Integer(3));
root.Insert("numbers", .Array(arr));

// Sub-tables
var sub = new TomlTable(.ExplicitHeader);
sub.Insert("key", .String(new String("value")));
root.Insert("section", .Table(sub));

// Dates
root.Insert("created", .LocalDate(TomlLocalDate(2024, 7, 15)));
root.Insert("timestamp", .OffsetDateTime(
    TomlOffsetDateTime(2024, 7, 15, 14, 30, 0, 0, 0)));
```

### Cloning

```bf
TomlValue copy = original.Clone();      // Deep copy of a value
TomlTable clonedTable = table.Clone();  // Deep copy of a table
TomlArray clonedArr = arr.Clone();      // Deep copy of an array
```

### Date/Time Types

| TOML type | Beef struct | Example construction |
|-----------|------------|---------------------|
| offset-date-time | `TomlOffsetDateTime` | `.(2024, 7, 15, 14, 30, 0, 0, 0)` |
| local-date-time | `TomlLocalDateTime` | `.(2024, 7, 15, 14, 30, 0, 0)` |
| local-date | `TomlLocalDate` | `.(2024, 7, 15)` |
| local-time | `TomlLocalTime` | `.(14, 30, 0, 0)` |

All date/time structs have public fields (`mYear`, `mMonth`, `mDay`, `mHour`, `mMinute`, `mSecond`, `mNanosecond`). `TomlOffsetDateTime` also has `mOffsetMinutes` (UTC offset in minutes, e.g. 330 for +05:30, 0 for Z).

Assertions in debug builds validate field ranges. Release builds trust the caller.

### Error Handling

```bf
struct TomlParseError
{
    TomlErrorKind mKind;   // Category of error
    String mMessage;       // Human-readable description
    int mLine;             // 1-based line number
    int mColumn;           // 1-based column number
    int mOffset;           // Byte offset into input
    int mLength;           // Length of erroneous span
}
```

**Important:** `TomlParseError` must be explicitly disposed to free the message string. When using `Result.Err`, wrap with `defer`:

```bf
case .Err(let err):
    defer err.Dispose();
    // ... handle error ...
```

### Memory Management

- `TomlDocument` owns the entire parsed tree. `delete doc` frees everything.
- `TomlValue` is a value type (enum). It may contain heap references (`String`, `TomlArray*`, `TomlTable*`). Call `Dispose()` when discarding an owned value.
- Tables and arrays own their contents. Deleting a table or array disposes all children.
- `StringView` returned by `TryGetString()` and `AsString` is borrowed — it points into the owning `TomlValue`. Do not use after the value is disposed.
- The caller owns the document and must `delete` it when done (`defer delete doc`).
- Use `Clone()` for deep copies when you need independent ownership of a subtree.

## Supported TOML Features

| Feature | Parse | Write |
|---------|-------|-------|
| Bare keys | ✅ | ✅ |
| Quoted keys (basic, literal) | ✅ | ✅ (basic only) |
| Dotted keys | ✅ | — (emitted as `[header]`) |
| Basic strings | ✅ | ✅ |
| Multi-line basic strings | ✅ | — (emitted as basic) |
| Literal strings | ✅ | — (emitted as basic) |
| Multi-line literal strings | ✅ | — (emitted as basic) |
| Integers (dec, hex, oct, bin) | ✅ | ✅ (decimal only) |
| Floats (incl. ±inf, ±nan, −0) | ✅ | ✅ |
| Booleans | ✅ | ✅ |
| Offset date-time | ✅ | ✅ |
| Local date-time | ✅ | ✅ |
| Local date | ✅ | ✅ |
| Local time | ✅ | ✅ |
| Arrays | ✅ | ✅ |
| Inline tables | ✅ | ✅ |
| Tables `[header]` | ✅ | ✅ |
| Array of tables `[[header]]` | ✅ | ✅ |
| Comments | ✅ | ✅ (discarded) |
| UTF-8 BOM | ✅ | — |

## Running Tests

```bash
# Build
BeefBuild

# Run toml-test suite (requires Go)
go run github.com/toml-lang/toml-test/v2/cmd/toml-test@v2.2.0 -- \
  test -decoder ./build/Debug_Linux64/TomlTester/TomlTester -toml 1.1

# Roundtrip test
./test-roundtrip.sh
```

## Requirements

- Beef language toolchain
- Linux x64 (primary target)

## License

MIT
