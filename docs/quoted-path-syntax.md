# Quoted Dotted-Path Syntax — Overview

## Problem

`TomlDocument.Get("a.b.c")` splits on every `.`, so there's no way to reference a key that literally contains a dot:

```toml
[servers]
"192.168.1.1" = { host = "db1", port = 5432 }
```

```bf
doc.Get("servers.192.168.1.1")  // wrong: 5 segments, not 2
```

## Proposed syntax: bracket-delimited segments

Wrap segments containing dots inside `[...]`:

```
"servers.[192.168.1.1]"    → ["servers", "192.168.1.1"]
"a.b.c"                      → ["a", "b", "c"]
"a.[b.c].[d.e.f]"           → ["a", "b.c", "d.e.f"]
"abc.def.[apples.car]"     → ["abc", "def", "apples.car"]
```

## Why brackets

- `[` and `]` never appear in bare TOML keys, so they're unambiguous delimiters
- Visually match TOML's table header syntax (`[header]`, `[[header]]`)
- No escape sequences, no backslash-hell
- Nestable? Probably not needed — brackets inside brackets would be rare and ambiguous

## Where it applies

All path-based accessors on `TomlDocument`:

```bf
doc.Get(path)                              // returns Result<TomlValue>
doc.TryGetString(path, var val)           // bool, out StringView
doc.TryGetInteger(path, var val)           // ... all 10 typed accessors
doc.Remove(path)                           // future: dotted Remove
doc.Set<T>(path, value)                    // future: dotted Set
```

## Parsing rule

```
Split on '.' outside of [...];
Strip '[' and ']' from each bracketed segment;
Unbracketed segments are used as-is.
```

Examples:

| Input | Segments |
|-------|---------|
| `"a.b.c"` | `["a", "b", "c"]` |
| `"a.[b.c]"` | `["a", "b.c"]` |
| `"[a.b]"` | `["a.b"]` |
| `"a.[b]"` | `["a", "b"]` |

Edge cases: unmatched `[` or `]` is treated as a literal character in the segment (not an error), since brackets can appear in quoted TOML keys — but callers should not rely on this.

## Non-goals (for now)

- No escaped brackets inside brackets (`[[...]]` etc.)
- No bracket nesting
- No changes to quoted-key support in TOML parsing (already works)
- No change to existing `Get(StringView)` behavior for bare-key-only paths

## Implementation outline

1. Factor the current `Get(StringView)` loop into a private helper that takes a list of segments
2. Add a `ParsePathSegments(StringView path, List<String> outParts)` helper that implements the bracket-split rule
3. `Get(StringView)` calls `ParsePathSegments` → segment list → existing traversal logic
4. Add `Get(params StringView[] segments)` overload as a secondary API for callers who build segments programmatically
5. All `TryGetXxx` accessors continue to delegate to `Get`, so they inherit the behavior for free
