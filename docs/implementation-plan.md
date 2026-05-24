# TomlBeef Implementation Plan (Revised)

## Overview

A TOML v1.1.0 parser library for the Beef programming language, with a companion `TomlTester` application for validating against the `toml-test` suite.

## Repository Layout

```
TomlBeef/
├── BeefProj.toml                # Workspace root (BeefLib)
├── BeefSpace.toml               # Workspace config
├── src/
│   └── TomlBeef/
│       ├── TomlError.bf         # Error types with location info
│       ├── TomlValue.bf         # Core value type + ownership/disposal
│       ├── TomlArray.bf         # Array value (List<TomlValue> wrapper)
│       ├── TomlTable.bf         # Table with metadata (origin, sealed, etc.)
│       ├── TomlDocument.bf      # Root document + full-tree disposal
│       ├── TomlCursor.bf        # UTF-8 input cursor with line/col tracking
│       ├── TomlScanner.bf       # Structural token classification
│       ├── TomlParser.bf        # Recursive descent parser
│       ├── TomlPathResolver.bf  # Table path navigation + conflict detection
│       ├── TomlDateTime.bf      # Custom date/time types (4 variants)
│       └── TomlSerializer.bf    # Tagged JSON serializer for toml-test
├── TomlTester/                  # Test runner application
│   ├── BeefProj.toml
│   └── src/
│       └── Program.bf           # stdin → parse → tagged JSON → stdout
├── toml-test/                   # Test suite (git submodule)
├── BJSON/                       # JSON library (git submodule)
└── docs/
    ├── toml-v1.1.0.md           # TOML specification
    ├── toml.abnf                # ABNF grammar
    └── implementation-plan.md   # This file
```

## Dependencies

- **BJSON** (`BJSON/`) — `JsonValue`, `JsonWriter` for tagged JSON output in toml-test format
- **corlib** — Beef standard library (`String`, `StringView`, `Result<T,E>`, `List<T>`, `Dictionary<K,V>`)

---

## Critical Design Decisions (addressing high-risk areas)

### Decision 1: Struct-based value types with explicit Dispose (BJSON pattern)

Beef structs have **no destructors**, **no move semantics**, and are **freely copyable**. This makes heap-owning structs dangerous: an accidental copy shares the same heap pointers, leading to double-free or use-after-free.

We follow BJSON's established pattern:
- `TomlValue` is a struct implementing a manual `Dispose()` method
- The root `TomlDocument` owns the full tree and calls `Dispose()` on teardown
- Every type that holds heap resources (`TomlArray`, `TomlTable`, strings in values) provides its own `Dispose()`
- Copies are **avoided by convention** — pass by `ref` or pointer internally
- A `Clone()` method provides explicit deep copy when needed

```bf
// Ownership rules:
// - TomlDocument: owns the root TomlTable, calls Dispose() on the full tree
// - TomlTable:    owns its Dictionary<String, TomlValue>, disposes all children
// - TomlArray:    owns its List<TomlValue>, disposes all children
// - TomlValue:    if type is String, owns the String; if Table, points to owned TomlTable
//                 if Array, points to owned TomlArray; scalars are inline
// - String values are owned heap Strings (class); delete in Dispose()
// - Never store a borrowed StringView in a long-lived TomlValue
```

### Decision 2: Arrays-of-tables are arrays, not flagged tables

An array of tables (`[[fruits]]`) is represented as `TomlValue.Array(List<TomlTable>)` — NOT as a `TomlTable` with an `IsArrayOfTables` flag.

This correctly models:
- `[[fruits]]` appends a new `TomlTable` to the array
- `[fruits.physical]` resolves through the *last element* of the array
- `fruits = []` followed by `[[fruits]]` is an error (append to static array)
- `[[fruits.varieties]]` after `[fruits.varieties]` is an error (table→array conflict)

The path resolver tracks "does this path segment resolve to an array?" and, if so, targets the last element.

### Decision 3: Table metadata for conflict detection

Every table carries provenance metadata. This prevents patching conflict detection later:

```bf
enum TomlTableOrigin
{
    Root,             // The top-level implicit table
    Implicit,         // Created automatically by a dotted key (fruit.apple.color)
    ExplicitHeader,   // Created by [table] header
    DottedKey,        // The final segment of a dotted key (fruit.apple when defined inline)
    InlineTable,      // Created by { key = value }
    ArrayElement      // Created by [[array]] header
}

class TomlTable
{
    TomlTableOrigin mOrigin;
    bool mIsInlineSealed;      // Inline tables cannot have keys added later
    Dictionary<String, TomlValue> mEntries;
    List<String> mKeyOrder;    // Insertion order for serializer
}
```

Conflict rules enforced via this metadata:
| Operation | Rule |
|-----------|------|
| `[x]` after `[x]` | Error — duplicate explicit table |
| `[fruit.apple]` after `fruit.apple.color` (in `[fruit]`) | Error — cannot redefine implicit table with explicit header |
| `[fruit.apple.texture]` after `fruit.apple.color` | OK — sub-table of implicit table |
| `fruit.apple = 1` then `fruit.apple.smooth = true` | Error — scalar→table conflict |
| `product.type.edible = false` after `product.type = { name = "Nail" }` | Error — inline table is sealed |
| `x = []` then `[[x]]` | Error — cannot append to static array |
| `[[x]]` then `[x]` | Error — array→table conflict |
| `[x]` then `[[x]]` | Error — table→array conflict |
| `x = 1` then `x = 2` | Error — duplicate key |

### Decision 4: Token classification before value parsing

At a value position, we first classify the next token span, then dispatch:

```
ReadBareValueToken():
  - if matches "true"/"false": Bool
  - if matches "inf"/"+inf"/"-inf"/"nan"/"+nan"/"-nan": SpecialFloat
  - if matches date-time pattern (has 'T' or ' ' or 'Z' or time offset): DateTime
  - if matches local date pattern (YYYY-MM-DD with no time): LocalDate
  - if matches local time pattern (HH:MM with no date): LocalTime
  - if matches float pattern (has '.' or 'e'/'E'): Float
  - if matches integer pattern: Integer
  - otherwise: Error (unknown bare token)
```

At a key position, `3.14159` is a dotted key (parts `"3"` and `"14159"`), NOT a float. The parser explicitly switches context: `ParseKey()` never calls float parsing.

---

## Data Model

### `TomlParseError` — Rich error with location

```bf
enum TomlErrorKind
{
    // Lexical
    UnexpectedChar,
    UnexpectedToken,
    UnterminatedString,
    InvalidEscape,
    ReservedEscape,
    InvalidUnicodeScalar,
    ControlCharInString,
    ControlCharInComment,
    InvalidUtf8,

    // Numeric
    InvalidInteger,
    IntegerOverflow,
    InvalidFloat,
    LeadingZero,
    InvalidUnderscore,

    // Date/Time
    InvalidDateTime,
    InvalidDate,
    InvalidTime,

    // Structure
    DuplicateKey,
    DuplicateTable,
    TypeConflict,          // table vs array, scalar vs table, etc.
    InlineTableSealed,     // attempt to add to sealed inline table
    AppendToStaticArray,   // [[x]] after x = []
    ArrayElementOrdering,  // child before parent array element
    MaxDepthExceeded,

    // Document
    MissingNewlineAfterKeyVal,
    EmptyBareKey,
    InvalidKey,
    HeaderAfterValue,      // headers must appear before any key/value in their scope
}

struct TomlParseError
{
    TomlErrorKind mKind;
    String mMessage;       // Human-readable description
    int mLine;
    int mColumn;
    int mOffset;           // Byte offset into input
    int mLength;           // Length of erroneous span
}
```

### `TomlValue` — Tagged union with disposal

```bf
enum TomlValueType : uint8
{
    String,
    Integer,
    Float,
    Bool,
    OffsetDateTime,
    LocalDateTime,
    LocalDate,
    LocalTime,
    Array,
    Table
}

struct TomlValue : IDisposable
{
    TomlValueType mType;
    // Union data — manual management per Dispose()
    String mStringVal;
    int64 mIntVal;
    double mFloatVal;
    bool mBoolVal;
    TomlOffsetDateTime mOffsetDtVal;
    TomlLocalDateTime mLocalDtVal;
    TomlLocalDate mDateVal;
    TomlLocalTime mTimeVal;
    TomlArray* mArrayVal;
    TomlTable* mTableVal;

    public void Dispose();
    public TomlValue Clone();

    // Factory methods — each creates the right variant
    public static TomlValue FromString(StringView s);
    public static TomlValue FromInteger(int64 v);
    public static TomlValue FromFloat(double v);
    public static TomlValue FromBool(bool v);
    public static TomlValue FromOffsetDateTime(TomlOffsetDateTime v);
    public static TomlValue FromLocalDateTime(TomlLocalDateTime v);
    public static TomlValue FromLocalDate(TomlLocalDate v);
    public static TomlValue FromLocalTime(TomlLocalTime v);
    public static TomlValue FromArray(TomlArray* arr);
    public static TomlValue FromTable(TomlTable* tbl);
}
```

### `TomlArray` — Owned list of values

```bf
class TomlArray
{
    List<TomlValue> mItems;
    ~this();  // Disposes all items
}
```

### `TomlTable` — Owned ordered map with metadata

```bf
enum TomlTableOrigin : uint8
{
    Root,
    Implicit,
    ExplicitHeader,
    InlineTable,
    ArrayElement
}

class TomlTable
{
    TomlTableOrigin mOrigin;
    bool mIsInlineSealed;
    Dictionary<String, TomlValue> mEntries;   // Owns values
    List<String> mKeyOrder;                    // Insertion order

    public ~this();                            // Disposes all entries
    public Result<void, TomlParseError> Insert(StringView key, TomlValue value);
    public Result<TomlValue*, TomlParseError> Get(StringView key);
    public bool ContainsKey(StringView key);
}
```

### Custom date/time types

```bf
struct TomlOffsetDateTime
{
    int32 mYear, mMonth, mDay;
    int32 mHour, mMinute, mSecond;
    int64 mNanosecond;    // Fractional seconds in nanoseconds
    int32 mOffsetMinutes; // UTC offset in minutes (Z = 0)
}

struct TomlLocalDateTime
{
    int32 mYear, mMonth, mDay;
    int32 mHour, mMinute, mSecond;
    int64 mNanosecond;
}

struct TomlLocalDate
{
    int32 mYear, mMonth, mDay;
}

struct TomlLocalTime
{
    int32 mHour, mMinute, mSecond;
    int64 mNanosecond;
}
```

Beef's `DateTime` and `DateTimeOffset` could technically store some of these, but they don't distinguish TOML's four semantic types and their kind flags (Utc/Local/Unspecified) don't align with TOML's offset-tagged vs offset-free distinction. Custom types make the serializer straightforward and preserve TOML semantics.

### `TomlDocument` — Root document, owns the full tree

```bf
class TomlDocument
{
    TomlTable mRootTable;  // TomlTableOrigin.Root

    ~this();               // Delegates to mRootTable disposal
}
```

---

## Parser Architecture

### Parser state

```bf
class TomlParser
{
    TomlCursor mCursor;                    // UTF-8 input cursor with position tracking
    TomlDocument mDocument;                // Output document (owned)
    TomlPathResolver mPathResolver;        // Navigates table tree, enforces conflicts
    int mMaxDepth = 256;                   // Nesting guard
}
```

### `TomlCursor` — Input cursor with UTF-8 decoding

```bf
class TomlCursor
{
    StringView mInput;
    int mOffset;        // Byte offset
    int mLine;          // 1-based
    int mColumn;        // 1-based

    // Returns '\0' at EOF
    public char32 Peek();
    public char32 Advance();
    public void SkipWhitespace();
    public void SkipNewline();       // Handles LF and CRLF
    public void SkipComment();
    public void SkipToNextLine();
    public SourceSpan CurrentSpan();
}
```

### `TomlScanner` — Structural token classification

Minimal token layer for document-level structure. Value tokens are still parsed manually.

```bf
enum TomlTokenKind
{
    BareText,           // Unquoted text (could be key name, bool, number, date)
    BasicString,        // "..."
    LiteralString,      // '...'
    MultiLineBasicString,   // """..."""
    MultiLineLiteralString, // '''...'''
    LBracket,           // [
    DoubleLBracket,     // [[
    RBracket,           // ]
    DoubleRBracket,     // ]]
    LBrace,             // {
    RBrace,             // }
    Equals,             // =
    Dot,                // .
    Comma,              // ,
    Newline,
    Comment,
    EOF
}
```

### `TomlPathResolver` — Navigates table tree and enforces conflicts

```bf
class TomlPathResolver
{
    TomlDocument* mDocument;
    List<String> mCurrentPath;          // e.g., ["fruits", "apple"]
    TomlTable* mCurrentTable;           // Resolved from current path

    // Walk to a path, creating implicit tables as needed. Returns error on conflicts.
    public Result<void, TomlParseError> EnterTable(List<StringView> path);
    public Result<void, TomlParseError> EnterArrayOfTables(List<StringView> path);

    // Set a key/value in the current table. Handles dotted keys recursively.
    public Result<void, TomlParseError> SetKeyValue(List<StringView> keyPath, TomlValue value);

    // Final validation after parsing
    public Result<void, TomlParseError> Validate();
}
```

### Parsing methods (in TomlParser)

```bf
public Result<TomlDocument, TomlParseError> Parse(StringView input);

// Document level
private Result<void, TomlParseError> ParseDocument();
private Result<void, TomlParseError> ParseExpression();
private Result<void, TomlParseError> ParseKeyVal();
private Result<void, TomlParseError> ParseTableHeader();
private Result<void, TomlParseError> ParseArrayOfTablesHeader();

// Keys (key-position context — never parses floats or dates)
private Result<List<StringView>, TomlParseError> ParseDottedKey();
private Result<StringView, TomlParseError> ParseBareKey();
private Result<StringView, TomlParseError> ParseQuotedKey();

// Value classification
private enum BareValueKind { Bool, SpecialFloat, DateTime, LocalDateTime,
                              LocalDate, LocalTime, Float, Integer }
private Result<BareValueKind, TomlParseError> ClassifyBareToken(
    StringView token, out BareValueKind kind);

// Value parsing
private Result<TomlValue, TomlParseError> ParseValue();
private Result<TomlValue, TomlParseError> ParseString();
private Result<TomlValue, TomlParseError> ParseInteger(StringView token);
private Result<TomlValue, TomlParseError> ParseFloat(StringView token);
private Result<TomlValue, TomlParseError> ParseBool(StringView token);
private Result<TomlValue, TomlParseError> ParseOffsetDateTime(StringView token);
private Result<TomlValue, TomlParseError> ParseLocalDateTime(StringView token);
private Result<TomlValue, TomlParseError> ParseLocalDate(StringView token);
private Result<TomlValue, TomlParseError> ParseLocalTime(StringView token);
private Result<TomlValue, TomlParseError> ParseArray();
private Result<TomlValue, TomlParseError> ParseInlineTable();
```

### Value parsing dispatch flow

```
ParseValue():
  switch Peek():
    '"'  → peek for """ → ParseMultiLineBasicString() : ParseBasicString()
    '''  → peek for ''''' → ParseMultiLineLiteralString() : ParseLiteralString()
    '['  → peek for '[[' → ERROR (headers handled at document level, not values)
                           → ParseArray()
    '{'  → ParseInlineTable()
    else → token = ReadBareValueToken()
           classify token → dispatch ParseBool/ParseFloat/ParseInteger/ParseDateTime/etc.
```

### Key parsing dispatch flow

```
ParseDottedKey():
  parts = []
  loop:
    if Peek() is '"':  parts.Add(ParseBasicString())
    elif Peek() is ''': parts.Add(ParseLiteralString())
    else:               parts.Add(ParseBareKey())
    if Peek() is '.':  Advance(), continue
    else: break
  return parts
```

---

## String Parser Details (dedicated phase)

Each string form has its own parser with distinct rules:

### Basic String (`"..."`)
- Escapes: `\b \t \n \f \r \e \" \\ \xHH \uHHHH \UHHHHHHHH`
- `\e` is new in TOML v1.1.0 (escape character U+001B)
- `\xHH` is new in TOML v1.1.0 — exactly 2 hex digits
- All escape codes must decode to Unicode scalar values (< 0xD800 or > 0xDFFF, ≤ 0x10FFFF)
- Reserved/unrecognized escapes → error
- Control chars (U+0000..U+0008, U+000A..U+001F, U+007F) forbidden

### Multi-line Basic String (`"""..."""`)
- All basic string rules apply
- First newline after opening `"""` is trimmed
- Line-ending backslash: `\` at end of line + all whitespace + newline trimmed up to next non-whitespace or closing delimiter
- 1 or 2 adjacent `"` are literal; 3+ `"` must escape at least one
- CR allowed only as part of CRLF newline
- All control chars forbidden except tab, LF, CR (as part of CRLF)

### Literal String (`'...'`)
- No escapes whatsoever
- Cannot contain `'`
- Control chars (except tab) forbidden

### Multi-line Literal String (`'''...'''`)
- No escapes whatsoever
- First newline after opening `'''` is trimmed
- Newlines normalized (CRLF → LF or platform-native)
- 1 or 2 adjacent `'` are literal; 3+ `'` not permitted (must close delimiter)
- Control chars (except tab) forbidden

### Quoted Keys
- Only basic string and literal string forms (no multi-line)
- Empty quoted key is valid but discouraged: `"" = "blank"`

---

## Table State Rules (spec-verified)

### Implicit table creation via dotted keys

```
fruit.apple.color = "red"
```
Creates `fruit` (TomlTable, origin=Implicit) → `apple` (TomlTable, origin=Implicit) → sets `color` = "red".

```
[fruit]
apple.color = "red"
[fruit.apple]        # INVALID — apple was created implicitly via dotted key
```

But sub-tables CAN be added:

```
[fruit]
apple.color = "red"
[fruit.apple.texture]  # VALID — texture is a sub-table of implicit apple
smooth = true
```

### Explicit header after implicit

```
[x.y.z.w]     # Creates x, x.y, x.y.z implicitly; x.y.z.w explicitly
[x]           # VALID — defining a super-table afterward is ok
```

### Inline table sealing

```
product = { type = { name = "Nail" } }
# product.type.edible = false  # INVALID — inline tables are sealed
```

```
product.type = { name = "Nail" }
# type = { edible = false }  # INVALID — cannot redefine existing table with inline
```

### Array vs table vs array-of-tables conflicts

```
fruits = []
[[fruits]]        # INVALID — append to static array

[[fruits]]
[fruits]          # INVALID — array → table conflict

[fruits]
[[fruits]]        # INVALID — table → array conflict

[[fruits]]
[fruits.varieties]
name = "x"
[[fruits.varieties]]  # INVALID — table → array-of-tables conflict
```

### Array-of-tables element ordering

```
[fruit.physical]    # INVALID — which element of fruit array?
color = "red"
[[fruit]]
name = "apple"
```

The parent array element must exist before its children are defined.

---

## Serializer: Tagged JSON for toml-test

Each TOML value becomes a JSON object with `type` and `value` fields:

| TOML Type | JSON `type` | JSON `value` |
|-----------|------------|--------------|
| String | `"string"` | The string itself |
| Integer | `"integer"` | String representation (e.g., `"42"`) |
| Float | `"float"` | String representation (e.g., `"3.14"`, `"inf"`, `"nan"`) |
| Bool | `"bool"` | `"true"` or `"false"` |
| OffsetDateTime | `"datetime"` | RFC 3339 (e.g., `"1979-05-27T07:32:00Z"`) |
| LocalDateTime | `"datetime-local"` | RFC 3339 without offset (e.g., `"1979-05-27T07:32:00"`) |
| LocalDate | `"date-local"` | `"1979-05-27"` |
| LocalTime | `"time-local"` | `"07:32:00"` |

Tables → JSON objects with tagged values
Arrays → JSON arrays with tagged values
Array-of-tables → JSON arrays of JSON objects
Empty tables → `{}`
Empty arrays → `[]`

Uses BJSON's `JsonWriter` to produce the output.

---

## TomlTester Application

```bf
// TomlTester/src/Program.bf
class Program
{
    public static int Main(String[] args)
    {
        // Read all of stdin
        String input = scope .();
        Console.In.ReadToEnd(input);

        // Parse
        TomlParser parser = scope .();
        switch (parser.Parse(input))
        {
        case .Err(let err):
            Console.Error.WriteLine(scope $"Parse error at line {err.mLine}:{err.mColumn}: {err.mMessage}");
            return 1;
        case .Ok(let doc):
            defer delete doc;
            // Serialize to tagged JSON
            TomlSerializer serializer = scope .();
            String json = scope .();
            if (serializer.Serialize(doc, json) case .Err(let serr))
            {
                Console.Error.WriteLine(scope $"Serialization error: {serr.mMessage}");
                return 1;
            }
            Console.WriteLine(json);
            return 0;
        }
    }
}
```

Usage with toml-test:
```bash
BeefBuild -run -args test -decoder ./TomlTester
```

---

## Revised Implementation Order

1.  **`TomlParseError` + `TomlErrorKind`** — Error types with line/column/span
2.  **`TomlCursor`** — UTF-8 input cursor, newline normalization (LF/CRLF), line/col tracking
3.  **`TomlValue` + `TomlArray` + `TomlTable`** — Complete data model with ownership rules, `Dispose()`, and `Clone()`
4.  **Table metadata** — `TomlTableOrigin`, `mIsInlineSealed`, insertion-order tracking
5.  **Custom date/time types** — `TomlOffsetDateTime`, `TomlLocalDateTime`, `TomlLocalDate`, `TomlLocalTime`
6.  **`TomlScanner`** — Structural token classification for `[]`, `[[]]`, `{}`, `=`, `.`, `,`, newlines
7.  **Key parser** — Bare keys, quoted keys (basic/literal only, no multi-line), dotted keys
8.  **Bare value token classifier** — Classify bare text into bool/special-float/datetime/float/integer
9.  **Integer/Float/Bool parsing** — All number formats, special floats (±inf, ±nan), underscores
10. **Date/Time parsing** — All four variants, omitted-seconds support, millisecond precision, truncation
11. **String parsing** — All four string forms, escape sequences, `\xHH`/`\e` (v1.1), line-ending backslash, control char validation, Unicode scalar validation
12. **Array parsing** — Square brackets, mixed types, trailing commas, multi-line with comments
13. **Inline table parsing** — Curly braces, sealed-table rules, trailing commas
14. **`TomlPathResolver`** — Table tree navigation, implicit table creation, conflict detection (duplicate keys, type conflicts, sealed table violations, static array append violations)
15. **Table header parsing** — `[table]` headers, path resolution, explicit/implicit conflict rules
16. **Array-of-tables header parsing** — `[[array]]` headers, element ordering enforcement, last-element resolution
17. **Document parser** — Root table, expression dispatch, newline-after-keyval enforcement
18. **`TomlSerializer`** — Tagged JSON output using BJSON
19. **`TomlTester`** — stdin/stdout interface
20. **Integration testing** — Run against toml-test, fix failures incrementally

---

## Test Categories Beyond toml-test

These tests exercise spec edge cases that may not all be in toml-test:

```toml
# Dotted key that looks like a float
3.14159 = "pi"

# INVALID: explicit header redeclares implicit dotted-key table
[fruit]
apple.color = "red"
[fruit.apple]                # INVALID

# VALID: sub-table below dotted-key-created implicit table
[fruit]
apple.color = "red"
[fruit.apple.texture]        # VALID
smooth = true

# INVALID: add to sealed inline table
[product]
type = { name = "Nail" }
# product.type.edible = false  # INVALID

# INVALID: append array-of-tables to static array
fruits = []
[[fruits]]                   # INVALID

# VALID: nested array-of-tables under latest parent element
[[fruits]]
name = "apple"
[[fruits.varieties]]
name = "granny smith"
[[fruits]]
name = "banana"
[[fruits.varieties]]          # This goes into the banana element
name = "plantain"

# INVALID: table after array-of-tables with same name
[[fruits]]
[fruits]                     # INVALID

# INVALID: array-of-tables after table with same name
[fruits]
[[fruits]]                   # INVALID

# INVALID: child subtable before parent array-of-tables element exists
[fruit.physical]
color = "red"
[[fruit]]                    # INVALID — fruit array element doesn't exist yet
name = "apple"

# VALID: defining super-table after implicit child path
[x.y.z.w]
[x]                          # VALID
```

---

## Beef-Specific Conventions (from AGENTS.md)

- Use `StringView` for borrowed inputs (parser input)
- Use `String` for owned string data stored in values  
- Use `Result<T, TomlParseError>` for all fallible operations
- `///` doc comments with `@brief`, `@param`, `@return` on public API
- Explicit `public` on API surface; `m` prefix for private fields
- Struct methods that modify `this` must be marked `mut`
- Class fields with heap resources use `~ delete _` field destructors
- Structs with heap resources implement `Dispose()` for manual cleanup
- No exceptions — use `Try!` and `Result` for error propagation
- `defer delete` for cleanup of temporary heap allocations
- `scope` allocations for temporary strings/objects
