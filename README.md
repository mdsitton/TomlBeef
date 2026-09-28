# TomlBeef

A TOML v1.1.0 parser and writer for the [Beef programming language](https://www.beeflang.org/).

Compliant with the full [TOML v1.1.0 specification](https://toml.io/en/v1.1.0). Validated against the official [toml-test](https://github.com/toml-lang/toml-test) suite.

## Quick Start

```bf
using TomlBeef;

// Parse a TOML string (TomlDocument.ParseFile(path) reads a file)
TomlDocument doc;
switch (TomlDocument.Parse(input))
{
case .Ok(let parsed):
    doc = parsed;
case .Err(let err):
    Console.Error.WriteLine($"Parse error at {err.mLine}:{err.mColumn}: {err.mMessage}");
    return;
}
defer delete doc;
// Errors need no cleanup; Try!(TomlDocument.Parse(input)) works too

if (doc.TryGetString("name", var name))
    Console.WriteLine($"Hello, {name}!");
int64 port = doc.GetInteger("server.port", 8080);   // default when missing

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
    // handle error, log, return...
}
```

`TomlDocument.Parse(input[, config])` and `TomlDocument.ParseFile(path[, config])` are shortcuts that create the document and return `Result<TomlDocument, TomlParseError>`; on failure no document is left behind. Use `Read` on an existing document to reuse it or to merge.

`doc.Read` returns `Result<void, TomlParseError>`. On success, the document is populated. On error, the document is left in a defined state: `Replace` failures leave it empty, while `Merge` failures leave existing content unchanged. The caller owns the document and must eventually `delete` it.

A TOML specification version can be passed: `doc.Read(input, .() { Version = .V1_0 })`. Defaults to V1_1. Overloads without a config use the document's own `doc.ReadConfig` / `doc.WriteConfig`, so settings can be made once per document:

```bf
doc.ReadConfig.MetadataMode = .PreserveStyle;
doc.WriteConfig.Version = .V1_0;
doc.ReadFile("config.toml");   // uses doc.ReadConfig
doc.WriteFile("config.toml");  // uses doc.WriteConfig
```

Use `Replace` mode (the default) to clear existing content before parsing. Use `Merge` mode to layer another file on top of existing content:

```bf
doc.Read(baseFile);                                                     // Replace (default)
doc.Read(overrideFile, .() { Mode = .Merge, OnConflict = .Overwrite }); // Merge on top
```

Merging is deep: tables that exist on both sides are combined key by key, so a base `[server] host = "a"` merged with an override `[server] port = 80` yields both keys. Only individual values conflict (arrays count as single values and are replaced whole). `OnConflict` decides what happens then: `Error` (default) fails and leaves the document unchanged, naming the conflicting path; `Skip` keeps the existing value; `Overwrite` takes the incoming one.

`TomlDocument` owns the entire parsed tree. Dispose it when done (`defer delete doc`).

#### Resource Limits

When parsing untrusted input, cap resource usage through `TomlReadConfig`. Exceeding a limit fails the read with `TomlErrorKind.ResourceLimitExceeded` (`MaxDepthExceeded` for `MaxDepth`), and the usual transactional guarantees apply (`Replace` leaves the document empty, `Merge` leaves it unchanged).

```bf
var config = TomlReadConfig() { MaxInputBytes = 1024 * 1024, MaxNodes = 100000, MaxDepth = 64 };
if (doc.Read(input, config) case .Err(let err)) { /* ... */ }
```

| Field | Default | What it limits |
|-------|---------|----------------|
| `MaxDepth` | `256` | Nesting depth of arrays and inline tables |
| `MaxInputBytes` | `0` | Raw input size in bytes, including any BOM. Enforced for `Read(StringView)`, `ReadBytes()`, and `ReadFile()` (checked after the file is loaded), and for `Read(Stream)` as bytes are consumed |
| `MaxStringBytes` | `0` | Byte length of any single string value after escape decoding (keys are not counted) |
| `MaxArrayItems` | `0` | Elements in any single array, including `[[array-of-tables]]` elements |
| `MaxTableEntries` | `0` | Keys in any single table: root, `[header]`, inline, and dotted-key implicit tables |
| `MaxPathSegments` | `0` | Segments in a dotted key or `[table]` / `[[array]]` header path |
| `MaxNodes` | `0` | Total value nodes: every scalar, array, and table (explicit, implicit, inline, or array element); the root table is not counted. `a = [1, 2]` is 3 nodes and `a.b.c = 1` is 3 nodes |

A value of `0` means unlimited for every field, including `MaxDepth`. Limits apply only to the document being parsed: in `Merge` mode they count the incoming content, not the existing document. They do not apply to programmatic mutation through `Set`/`Add`.

For large files, set `StreamBufferBytes` (e.g. `65536`): `Read(Stream)` uses a buffer of that size, and `ReadFile` then streams the file through it instead of loading it whole.

### Reading Values

**Path-based lookup** — dotted keys with bracket support for segments containing dots:

```bf
// Generic lookup — returns Result<TomlValue>
if (doc.Get("fruit.apple.color") case .Ok(let val))
    ...

// The indexer is the same lookup (read-only; write with doc.Set)
if (doc["fruit.apple.color"] case .Ok(let val))
    ...
let port = Try!(doc["server.port"]).AsInteger;

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

**Defaults** — `GetString`, `GetInteger`, `GetFloat` and `GetBool` return a fallback when the path is missing or holds another type. They exist on both `TomlDocument` (dotted path) and `TomlTable` (key):

```bf
StringView host = doc.GetString("server.host", "localhost");
int64 port      = doc.GetInteger("server.port", 8080);
bool verbose    = server.GetBool("verbose", false);
```

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
child.Set("name", "replacement");

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

// Safe accessors — return bool, no crash on type mismatch
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
// Entries come in insertion order as TomlTableEntry proxies
for (let entry in table)
{
    Console.WriteLine(entry.Key);
    if (entry.TryGetString(let s))
        Console.WriteLine(s);
    else if (entry.GetValue().IsTable)
        Console.WriteLine("  (sub-table)");
}
```

Assigning values (`entry.Value = 42`) and renaming keys are fine while iterating; adding or removing keys is a fatal error. `table[i]` gives the same proxy by index.

### Iterating Arrays

```bf
for (let value in arr)
{
    if (value.TryGetInteger(let n)) { /* ... */ }
    else if (value case .Table(let element)) { /* array-of-tables element */ }
}

// Or typed readers by index:
if (arr.TryGetString(0, let s)) { }
```

Values yielded while iterating are borrowed from the document (valid until it is cleared).

### Writing TOML

```bf
String output = scope String();
doc.Write(output);
```

Or with v1.0 compatibility: `doc.Write(output, .() { Version = .V1_0 })`.

The writer produces valid TOML v1.1 output. Sub-tables are emitted as `[header]` blocks. Array-of-tables use `[[header]]`. Scalar values within a table are grouped before sub-table headers.

### Preserving Formatting and Comments

By default the writer produces canonical TOML. To edit a file and keep its look, read it with `MetadataMode = .PreserveStyle`:

```bf
doc.ReadFile("config.toml", .() { MetadataMode = .PreserveStyle });
doc.Set("server.port", 8080);   // only this value is regenerated
doc.WriteFile("config.toml");
```

Comments, blank lines between sections, string quoting and escapes, number formats (`0xFF`, `1_000`, `1e3`), date/time formats, key quoting, array and inline-table layout are kept. A changed value is regenerated in the style it had. A new number or date/time follows its nearest neighbour of the same type (a new key among hex values is written in hex); new strings and arrays follow the document's dominant style. Merging another file (also read with `PreserveStyle`) brings its comments and formats along. The goal is a faithful, valid file, not byte-for-byte identity: key order within a table is canonical, and whitespace details may be normalized.

Comments and styles can also be edited (these return `false` unless `doc.PreservesStyle` is true):

```bf
doc.SetFileHeaderComment("Generated by mytool\nDo not edit by hand");
doc.SetComment("server.port", "Port to listen on");       // lines above the key
doc.SetTrailingComment("server.port", "default 80");      // end of the key's line
doc.SetStringStyle("server.name", .Literal);              // 'value' instead of "value"
doc.SetIntegerBase("permissions", .Octal);                // 0o755
doc.SetFloatNotation("limits.ratio", .Scientific);        // 1.5e-3 instead of 0.0015
doc.SetDateTimeStyle("created", .() { Separator = ' ', UseZ = false, MinFractionDigits = 3 });
                                                          // 1979-05-27 07:32:00.000+00:00
doc.SetArrayLayout("server.hosts", .Multiline);           // one element per line
doc.SetInlineTableLayout("point", .Compact);              // {x=1,y=2}; also .Spaced, .Multiline (1.1)
doc.SetKeyQuoting("server.port", .Literal);               // 'port' = 80; also .Bare, .Basic
if (doc.TryGetTable("server", var server))
    server.SetHeaderComment("Server settings");           // above [server] (or a [[...]] element)
if (doc.TryGetArray("server.hosts", var hosts))
    hosts.SetComment(0, "primary");                       // above the first element
```

The same methods exist on `TomlTable` taking a key, along with `TryGetComment` and `TryGetTrailingComment` for reading comments back; `TomlArray` has `SetComment`, `SetTrailingComment`, `TryGetComment` and `TryGetTrailingComment` by element index (an array with element comments is written one element per line). Comment text is given without the `#` marker, one line per `\n`. Values are always written exactly: a float in scientific notation keeps every digit, and `MinFractionDigits` only pads. A key that cannot be quoted as asked (a bare key with spaces, a literal key containing `'`) falls back to basic quotes.

A document read with `PreserveStyle` also knows where each value came from, which is handy for reporting validation errors against the file. When you only need positions (validating a config you will not write back), read with `MetadataMode = .Positions` instead: it records the same source ranges without capturing comments, tokens or formats, and writes canonical TOML. `doc.HasSourcePositions` and `doc.PreservesStyle` tell the modes apart.

```bf
doc.ReadFile("config.toml", .() { MetadataMode = .Positions });
if (doc.TryGetSourceRange("server.port", var range))
    Console.WriteLine($"server.port is at {range}");   // config.toml:12:3
```

`TomlSourceRange` gives the source name, 1-based line and column, byte offset, and length of the entry (from its key through its value; for a table, its `[header]`). `TomlTable.TryGetSourceRange(key)`, `TomlTable.TryGetHeaderSourceRange()` and `TomlArray.TryGetSourceRange(index)` do the same for tables, `[[array]]` elements, and array items. Values added in code have no position; values merged from another document with metadata keep theirs, including which file they came from.

### Validating Values

The `Require*` getters and `MakeError` turn validation problems into errors that point into the file. They return `TomlParseError`, so they compose with `Try!`, and `ToString` formats them as `source:line:column: message`:

```bf
Result<int64, TomlParseError> LoadPort(TomlDocument doc)
{
    let port = Try!(doc.RequireInteger("server.port"));
    if (port <= 0)
        return .Err(doc.MakeError("server.port", "must be positive"));
    return port;
}

doc.ReadFile("config.toml", .() { MetadataMode = .Positions });
if (LoadPort(doc) case .Err(let err))
    Console.Error.WriteLine($"{err}");   // config.toml:12:3: server.port: must be positive
```

- `RequireString`, `RequireInteger`, `RequireFloat`, `RequireBool`, `RequireTable` and `RequireArray` exist on `TomlDocument` (dotted path) and `TomlTable` (key). A missing value is a `MissingKey` error at the table that should hold it (`config.toml:10:1: server.port: missing required integer`); a value of another type is a `WrongType` error at the value (`server.port: expected integer, found string`). Integers are not accepted as floats.
- `MakeError` builds an `InvalidValue` error for your own checks, on `TomlDocument` (dotted path), `TomlTable` (key) and `TomlArray` (index, `[2]: ...`).
- Positions need `MetadataMode = .Positions` (or `.PreserveStyle`); without them the messages still name the path. `ReadFile` names the source after its path; for other inputs set `TomlReadConfig.SourceName`. After merging several files each value reports its own file, and a merge read rejected for a conflicting key points at that key in the incoming file.
- `TomlValue.TypeName` gives the TOML type name ("integer", "local date", ...) for your own messages.

### Building Values Programmatically

```bf
var doc = new TomlDocument();
var root = doc.RootTable;

// Scalar setter — takes any scalar (string, integer, float, bool, date/time)
root.Set("name", "TomlBeef");
root.Set("version", 1);
root.Set("released", true);

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
tbl.Set("name", "replacement");

var nested = arr.SetArray(2);
nested.Add("x");

// Deletion
arr.RemoveAt(0);
arr.Clear();

// Sub-tables — created through the document store
var sub = doc.AddTable("section");
sub.Set("key", "value");

// Dates
root.Set("created", TomlLocalDate(2024, 7, 15));
root.Set("timestamp", TomlOffsetDateTime(2024, 7, 15, 14, 30, 0, 0, 0));

// Dotted paths on the document create missing parent tables
doc.Set("database.primary.port", 5432);
var replicas = doc.AddArray("database.replicas");
```

> **Note:** `doc.Set`, `doc.AddTable` and `doc.AddArray` take a dotted path and create missing intermediate tables.
> `doc.Set` returns `false` (and `AddTable`/`AddArray` return `null`) when a path segment is malformed or names an existing non-table value.
> `doc.Remove(path)` never creates anything.
>
> `TomlArray.IsArrayOfTables` tells a `[[...]]` array of tables apart from a `[...]` array.

### Copying Between Documents

`TomlTable.MergeFrom` deep-copies into the destination document, so the source can be deleted afterwards:

```bf
// Clone a whole document
dest.Clear();
dest.RootTable.MergeFrom(source.RootTable);

// Copy one table into another document under a new key
if (source.TryGetTable("server", var server))
    dest.AddTable("server_backup").MergeFrom(server);
```

If both documents were read with `PreserveStyle`, the copied values keep their comments and formats.

### Date/Time Types

| TOML type | Beef struct | Example construction |
|-----------|------------|---------------------|
| offset-date-time | `TomlOffsetDateTime` | `.(2024, 7, 15, 14, 30, 0, 0, 0)` |
| local-date-time | `TomlLocalDateTime` | `.(2024, 7, 15, 14, 30, 0, 0)` |
| local-date | `TomlLocalDate` | `.(2024, 7, 15)` |
| local-time | `TomlLocalTime` | `.(14, 30, 0, 0)` |

All date/time structs have public `int32` fields (`mYear`, `mMonth`, `mDay`, `mHour`, `mMinute`, `mSecond`, `mNanosecond` with 0–999,999,999). `TomlOffsetDateTime` also has `mOffsetMinutes` (UTC offset in minutes, e.g. 330 for +05:30, 0 for Z).

The constructors (`TomlLocalDate(2024, 7, 15)`) are for values known to be valid: an impossible date or time is a fatal error. For values from outside (user input, other formats), use the `Create` factories, which check the same rules as the parser (years 0–9999, real month lengths including leap years, times up to 23:59:60, offsets within ±23:59) and return an `InvalidDate`/`InvalidTime`/`InvalidDateTime` error instead:

```bf
switch (TomlLocalDate.Create(year, month, day))
{
case .Ok(let date): doc.Set("release", date);
case .Err(let err): Console.Error.WriteLine($"{err}");   // Invalid date: day 31 is outside 1-30 for 2024-04
}
```

Assertions in debug builds validate field ranges. Release builds trust the caller.

### Error Handling

```bf
struct TomlParseError
{
    TomlErrorKind mKind;   // Category of error
    StringView mMessage;   // Human-readable description (see lifetime below)
    StringView mSource;    // Source name (SourceName, or the ReadFile/WriteFile path); may be empty
    int mLine;             // 1-based line number (0 when there is no position)
    int mColumn;           // 1-based column number
    int mOffset;           // Byte offset into input
    int mLength;           // Length of erroneous span
}
```

`TomlParseError` owns nothing and needs no cleanup, so it can be ignored, matched with `case .Err`, or passed up with `Try!` (including into a plain `Result<T>`, which drops it):

```bf
Result<void> LoadConfig(TomlDocument doc)
{
    Try!(doc.ReadFile("base.toml"));
    Try!(doc.ReadFile("local.toml", .() { Mode = .Merge }));
    return .Ok;
}
```

`err.ToString(output)` (or `$"{err}"`) formats it as `source:line:column: message`, leaving out the parts that are unknown.

**Message lifetime:** `mMessage` and `mSource` view per-thread buffers. It stays valid until the next TomlBeef error on the same thread, which replaces it. Copy it if you keep it past another failing call:

```bf
if (doc.ReadFile(path) case .Err(let err))
    messages.Add(new String(err.mMessage));
```

### Memory Management

- `TomlDocument` owns the entire parsed tree via an internal arena (`TomlDocumentStore`). `delete doc` frees everything.
- `TomlValue` is a non-owning tagged union — it holds borrowed references to document-owned `String`, `TomlArray`, and `TomlTable` objects.
- Tables and arrays created via `AddTable`/`AddArray` are store-backed and freed when the document is cleared or destroyed.
- `StringView` returned by `TryGetString` is borrowed from document-owned strings. Do not use after the document is cleared.
- Mutate documents through `Set`, `AddTable`, `AddArray`, `TomlArray.Add`, etc.; raw `TomlValue` insertion is not public API.
- Replaced or removed values are not freed individually; their payloads stay in the document arena until `Clear()` or `delete`. This keeps borrowed `TomlValue`/`StringView` copies valid, but memory grows under heavy repeated mutation of one document.

## Supported TOML Features

| Feature | Parse | Write |
|---------|-------|-------|
| Bare keys | ✅ | ✅ |
| Quoted keys (basic, literal) | ✅ | ✅ (basic only) |
| Dotted keys | ✅ | — (emitted as `[header]`) |
| Basic strings | ✅ | ✅ |
| Multi-line basic strings | ✅ | — (emitted as basic) |
| Literal strings | ✅ | ✅ (for values with `\` or `"` that a literal can hold) |
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

Local tests use the fixtures checked into `tests/`; a separate `toml-test/` checkout is not required.
The semantic comparison and roundtrip scripts require Python 3.

```bash
# Build
beefbuild

# Run Beef tests with Debug checks, then with Release optimizations
beefbuild -test
beefbuild -test -config=TestRelease

# Compare decoded values against the tracked fixtures
./test-toml.sh

# Roundtrip test
./test-roundtrip.sh

# Encoder test: fixture JSON -> TOML -> JSON, compared against the fixture
./test-encoder.sh

# Run the pinned upstream decoder and encoder suites for TOML 1.0 and 1.1 (requires Go)
./test-official-toml.sh
```

## Requirements

- Beef language toolchain
- Linux x64 (primary target)

## License

MIT
