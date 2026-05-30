# Quoted Dotted-Path Syntax

## Status

**Implemented.** `TomlDocument.Get()`, `GetPath()`, and all `TryGetXxx()` accessors support
bracket-delimited path segments. See `TomlDocument.bf` for the implementation and `TomlTest.bf`
for tests.

## Location

- `src/TomlBeef/TomlDocument.bf`
  - `Get(StringView dottedPath)` — bracket-aware path parsing.
  - `GetPath(List<StringView> segments)` — exact segment traversal.
  - `ParseDottedPath(StringView, List<StringView>)` — internal parser.
  - All 10 `TryGetXxx(StringView, out T)` helpers delegate to `Get()`.
- `src/TomlBeef/TomlTable.bf`
  - `Get`, indexer, `TryGetValue`, `TryGetXxx`, `Insert`, `ReplaceValue`, and `Remove` are
    single-key table APIs. They remain unchanged.

## Syntax

Wrap path segments containing dots inside `[...]`:

| Input | Segments | Result |
|-------|----------|--------|
| `"a.b.c"` | `["a", "b", "c"]` | valid |
| `"a.[b.c]"` | `["a", "b.c"]` | valid |
| `"[a.b]"` | `["a.b"]` | valid |
| `"a.[b]"` | `["a", "b"]` | valid |
| `"a..b"` | — | invalid empty segment |
| `"a.[b"` | — | invalid unmatched `[` |
| `"a.b]"` | — | invalid unmatched `]` |
| `"a.[].b"` | — | invalid empty bracketed segment |
| `"a.[b]c"` | — | invalid (missing dot after bracketed segment) |

## API

```bf
doc.Get(path)                         // Result<TomlValue>
doc.GetPath(segments)                 // Result<TomlValue>, exact segment list
doc.TryGetString(path, var val)       // bool + out
doc.TryGetInteger(path, var val)
doc.TryGetFloat(path, var val)
doc.TryGetBool(path, var val)
doc.TryGetTable(path, var val)
doc.TryGetArray(path, var val)
doc.TryGetOffsetDateTime(path, var val)
doc.TryGetLocalDateTime(path, var val)
doc.TryGetLocalDate(path, var val)
doc.TryGetLocalTime(path, var val)
```

For programmatic callers or when segments are already available, use `GetPath`:

```bf
// params StringView[] — ergonomic multi-segment lookup
doc.GetPath("a", "b", "c");

// List<StringView> overload for programmatic callers
var segs = scope List<StringView>();
segs.Add("a");
segs.Add("b");
doc.GetPath(segs);
```

`TomlTable` single-key APIs are unchanged — use them when you already have a table reference:

```bf
if (doc.TryGetTable("servers", var servers) &&
    servers.TryGetTable("192.168.1.1", var server))
{
    // ...
}
```

## Parsing rule

- Split on `.` only outside bracketed segments.
- Strip the outer `[` and `]` from bracketed segments.
- Unbracketed segments are used as-is.
- Bare segments must not contain `[` or `]`.
- After a bracketed segment, the next character must be `.` or end-of-path.
- Empty segments are invalid.
- Malformed bracket syntax returns `.Err`.

## Non-goals

- No full TOML key grammar in API paths.
- No quoted string parsing inside paths.
- No escaped brackets inside bracketed path segments.
- No bracket nesting.
- No attempt to represent keys containing `]` through the string path syntax.
- No changes to TOML parser quoted-key handling.
- No changes to `TomlTable` single-key accessors.
- No dotted mutator behavior (future work if needed).
