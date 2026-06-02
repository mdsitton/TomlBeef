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

if (doc.Read(input) case .Err(let err))
{
    defer err.Dispose();
    // handle error, log, return...
}
```

`doc.Read` returns `Result<void, TomlParseError>`. On success, the document is populated. On error, the document is left in a defined state: `Replace` failures leave it empty, while `Merge` failures leave existing content unchanged. The caller owns the document and must eventually `delete` it.

A TOML specification version can be passed: `doc.Read(input, .() { Version = .V1_0 })`. Defaults to V1_1.

Use `Replace` mode (the default) to clear existing content before parsing. Use `Merge` mode to layer additional keys on top of existing content:

```bf
doc.Read(baseFile);                              // Replace (default)
doc.Read(overrideFile, .() { Mode = .Merge });   // Merge on top
```

`TomlDocument` owns the entire parsed tree. Dispose it when done (`defer delete doc`).

### Reading Values

**Path-based lookup** — dotted keys with bracket support for segments containing dots:

```bf
// Generic lookup — returns Result<TomlValue>
if (doc.Get("fruit.apple.color") case .Ok(let val))
    ...

// Access a key whose name contains a dot: use [brackets]
if (doc.TryGetInteger("servers.[192.168.1.1].port", var port))
    ...

// Exact-segment API — ergonomic multi-segment lookup
if (doc.GetPath("a", "b", "c") case .Ok(let val))
    ...

// List overload for programmatic callers
var segs = scope List<StringView>();
segs.Add("a");
segs.Add("b");
if (doc.GetPath(segs) case .Ok(let val))
    ...

// Typed one-call accessors — convenient for one-off lookups
if (doc.TryGetString("fruit.apple.color", var color))
    Console.WriteLine(color);

// For several values under one prefix, look up the table once, then query locally.
// This avoids repeated dotted-path traversal.
if (doc.TryGetTable("server", var server))
{
    if (server.TryGetString("host", var host))
        Console.WriteLine(host);
    if (server.TryGetInteger("port", var port))
        Console.WriteLine($"{}", port);
    if (server.TryGetBool("tls", var tls))
        Console.WriteLine(tls ? "TLS enabled" : "TLS disabled");
}
```

Full set of document-level typed accessors: `TryGetString`, `TryGetInteger`, `TryGetFloat`, `TryGetBool`, `TryGetTable`, `TryGetArray`, `TryGetOffsetDateTime`, `TryGetLocalDateTime`, `TryGetLocalDate`, `TryGetLocalTime`.

**Navigating the tree directly:**

```bf
doc.RootTable           // The root table (read-only property)
table.Count              // Number of entries
table.ContainsKey("key")

// Advanced: raw TomlValue access (borrowed, internal). Prefer typed entry proxy.
table.TryGetValue("key", out value)  // advanced borrowed access

// Entry proxy iteration — typed access without raw TomlValue:
for (int i = 0; i < table.Count; i++)
{
    var entry = table[i];

    Console.WriteLine(entry.Key);

    if (entry.TryGetString(out var s))
        Console.WriteLine(s);
    else if (entry.TryGetInteger(out var n))
        Console.WriteLine($"{}", n);
}

// Safe assignment through entry proxy — no new String / new TomlValue:
table[0].Value = "new value";
table[0].Value = 42;

// Container replacement:
TomlTable child = table[0].SetTable();
child.SetString("name", "replacement");

// Key rename and removal:
table[0].Rename("new_key");
table[1].Remove();
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
// Entry proxy — typed access without raw TomlValue
for (int i = 0; i < table.Count; i++)
{
    var entry = table[i];
    Console.WriteLine(entry.Key);

    StringView s = ?;
    if (entry.TryGetString(out s))
        Console.WriteLine(s);
}
```

### Iterating Arrays

```bf
// Typed readers — no raw TomlValue needed:
StringView s = ?;
if (arr.TryGetString(0, out s)) { }

int64 n = ?;
if (arr.TryGetInteger(1, out n)) { }
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
var root = doc.RootTable;

// Scalar setters — no new String / new TomlValue needed
root.SetString("name", "TomlBeef");
root.SetInteger("version", 1);
root.SetBool("released", true);

// Arrays — created through the document store
var arr = doc.AddArray("numbers");
arr.Add(1);       // implicit conversion
arr.Add(2);
arr.Add(3);

// Indexer assignment — no raw TomlValue
arr[0] = 10;
arr[1] = 20;

// Typed readers — safe without exposing Dispose/ownership
StringView s = ?;
if (arr.TryGetString(0, out s)) { ... }

// Container replacement
var tbl = arr.SetTable(1);
tbl.SetString("name", "replacement");

var nested = arr.SetArray(2);
nested.AddString("x");

// Deletion
arr.RemoveAt(0);
arr.Clear();

// Sub-tables — created through the document store
var sub = doc.AddTable("section");
sub.SetString("key", "value");

// Dates — typed setters
root.SetLocalDate("created", TomlLocalDate(2024, 7, 15));
root.SetOffsetDateTime("timestamp",
    TomlOffsetDateTime(2024, 7, 15, 14, 30, 0, 0, 0));
```

> **Note:** Document setters (`SetString`, `SetInteger`, etc.) require intermediate path segments to already exist as tables.
> Use `doc.AddTable(...)` to create intermediate tables first.
> For deeply nested values, build the tree top-down: create tables via `AddTable`, then populate them.

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

- `TomlDocument` owns the entire parsed tree via an internal arena (`TomlDocumentStore`). `delete doc` frees everything.
- `TomlValue` is a non-owning tagged union — it holds borrowed references to document-owned `String`, `TomlArray`, and `TomlTable` objects.
- Tables and arrays created via `AddTable`/`AddArray` are store-backed and freed when the document is cleared or destroyed.
- `StringView` returned by `TryGetString()` is borrowed from document-owned strings. Do not use after the document is cleared.
- Prefer typed setters (`SetString`, `SetInteger`, etc.) over low-level `Insert`/`Add` APIs.

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
