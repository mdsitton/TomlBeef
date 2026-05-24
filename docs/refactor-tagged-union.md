# Refactor Plan: TomlValue struct → Tagged Union Enum

## Motivation

Replace the current manual struct-with-discriminator `TomlValue` (100+ bytes per value, manual switch with fallthrough risk) with Beef's native tagged union enum (~32 bytes, compiler-checked exhaustiveness, cleaner pattern matching).

## Files that change

| File | Scope of change |
|------|----------------|
| `src/TomlBeef/TomlValue.bf` | Complete rewrite |
| `src/TomlBeef/TomlSerializer.bf` | `SerializeValue()` switch only |
| `src/TomlBeef/TomlParser.bf` | All `TomlValue.FromXxx()` calls → `.Xxx()` |
| `src/TomlBeef/TomlPathResolver.bf` | Field accesses → pattern matches; factory calls |
| `src/TomlBeef/TomlTable.bf` | No changes required |
| `src/TomlBeef/TomlArray.bf` | No changes required |
| `src/TomlBeef/TomlDocument.bf` | No changes required |
| `src/TomlBeef/TomlScanner.bf` | No changes required |
| `src/TomlBeef/TomlCursor.bf` | No changes required |
| `src/TomlBeef/TomlError.bf` | No changes required |
| `src/TomlBeef/TomlDateTime.bf` | No changes required |
| `src/TomlBeef/Program.bf` | No changes required |
| `TomlTester/src/Program.bf` | No changes required |

## Step-by-step implementation

### Step 1: Rewrite `TomlValue.bf`

Replace the entire file. The new file contains:

**A. The tagged union enum**

```bf
using System;

namespace TomlBeef;

/// Origin of a TOML table, used for conflict detection during parsing.
/// (Moved here from old TomlValue.bf; unchanged.)
public enum TomlTableOrigin : uint8
{
    Root,
    Implicit,
    ExplicitHeader,
    InlineTable,
    ArrayElement
}

/// A TOML value — a tagged union supporting all TOML types.
public enum TomlValue
{
    case String(String s);
    case Integer(int64 v);
    case Float(double v);
    case Bool(bool v);
    case OffsetDateTime(TomlOffsetDateTime v);
    case LocalDateTime(TomlLocalDateTime v);
    case LocalDate(TomlLocalDate v);
    case LocalTime(TomlLocalTime v);
    case Array(TomlArray arr);
    case Table(TomlTable tbl);
```

**B. Convenience type-check properties**

Add inside the enum body, after the cases:

```bf
    public bool IsString         => this case .String;
    public bool IsInteger        => this case .Integer;
    public bool IsFloat          => this case .Float;
    public bool IsBool           => this case .Bool;
    public bool IsOffsetDateTime => this case .OffsetDateTime;
    public bool IsLocalDateTime  => this case .LocalDateTime;
    public bool IsLocalDate      => this case .LocalDate;
    public bool IsLocalTime      => this case .LocalTime;
    public bool IsArray          => this case .Array;
    public bool IsTable          => this case .Table;
```

**C. Dispose**

```bf
    /// Disposes any heap-allocated payload (String, TomlArray, TomlTable).
    public void Dispose()
    {
        switch (this)
        {
        case .String(let s):
            if (s != null) delete s;
        case .Array(let arr):
            if (arr != null) delete arr;
        case .Table(let tbl):
            if (tbl != null) delete tbl;
        default:
        }
    }
```

**D. Typed accessor properties** (for code that knows the variant at compile time)

```bf
    public StringView AsString
    {
        get
        {
            if (this case .String(let s))
                return StringView(s);
            Runtime.FatalError("TomlValue is not a String");
        }
    }

    public int64 AsInteger
    {
        get
        {
            if (this case .Integer(let v))
                return v;
            Runtime.FatalError("TomlValue is not an Integer");
        }
    }

    public double AsFloat
    {
        get
        {
            if (this case .Float(let v))
                return v;
            Runtime.FatalError("TomlValue is not a Float");
        }
    }

    public bool AsBool
    {
        get
        {
            if (this case .Bool(let v))
                return v;
            Runtime.FatalError("TomlValue is not a Bool");
        }
    }

    public TomlOffsetDateTime AsOffsetDateTime
    {
        get
        {
            if (this case .OffsetDateTime(let v))
                return v;
            Runtime.FatalError("TomlValue is not an OffsetDateTime");
        }
    }

    public TomlLocalDateTime AsLocalDateTime
    {
        get
        {
            if (this case .LocalDateTime(let v))
                return v;
            Runtime.FatalError("TomlValue is not a LocalDateTime");
        }
    }

    public TomlLocalDate AsLocalDate
    {
        get
        {
            if (this case .LocalDate(let v))
                return v;
            Runtime.FatalError("TomlValue is not a LocalDate");
        }
    }

    public TomlLocalTime AsLocalTime
    {
        get
        {
            if (this case .LocalTime(let v))
                return v;
            Runtime.FatalError("TomlValue is not a LocalTime");
        }
    }

    public TomlArray AsArray
    {
        get
        {
            if (this case .Array(let arr))
                return arr;
            Runtime.FatalError("TomlValue is not an Array");
        }
    }

    public TomlTable AsTable
    {
        get
        {
            if (this case .Table(let tbl))
                return tbl;
            Runtime.FatalError("TomlValue is not a Table");
        }
    }
}
```

**Remove entirely:**
- `TomlValueType` enum (the discriminants become the enum cases)
- All `FromXxx` static factory methods (enum case constructors replace them)
- The old struct definition with inline fields

---

### Step 2: Rewrite `TomlSerializer.bf` — `SerializeValue` method

Replace the `switch (val.mType)` block with a pattern-matching switch.

**Before:**
```bf
private void SerializeValue(TomlValue val, String outStr)
{
    switch (val.mType)
    {
    case .String: WriteTagged("string", val.AsString, outStr);
    case .Integer: WriteTagged("integer", val.AsInteger, outStr);
    case .Float: WriteTaggedFloat("float", val.AsFloat, outStr);
    case .Bool: WriteTagged("bool", val.AsBool ? "true" : "false", outStr);
    case .OffsetDateTime: WriteTaggedDateTime("datetime", val.AsOffsetDateTime, outStr);
    case .LocalDateTime: WriteTaggedLocalDateTime("datetime-local", val.AsLocalDateTime, outStr);
    case .LocalDate: WriteTaggedLocalDate("date-local", val.AsLocalDate, outStr);
    case .LocalTime: WriteTaggedLocalTime("time-local", val.AsLocalTime, outStr);
    case .Array: SerializeArray(val.AsArray, outStr);
    case .Table: SerializeTable(val.AsTable, outStr);
    default: outStr.Append("null");
    }
}
```

**After:**
```bf
private void SerializeValue(TomlValue val, String outStr)
{
    switch (val)
    {
    case .String(let s):           WriteTagged("string", s, outStr);
    case .Integer(let i):          WriteTagged("integer", i, outStr);
    case .Float(let f):            WriteTaggedFloat("float", f, outStr);
    case .Bool(let b):             WriteTagged("bool", b ? "true" : "false", outStr);
    case .OffsetDateTime(let dt):  WriteTaggedDateTime("datetime", dt, outStr);
    case .LocalDateTime(let dt):   WriteTaggedLocalDateTime("datetime-local", dt, outStr);
    case .LocalDate(let d):        WriteTaggedLocalDate("date-local", d, outStr);
    case .LocalTime(let t):        WriteTaggedLocalTime("time-local", t, outStr);
    case .Array(let arr):          SerializeArray(arr, outStr);
    case .Table(let tbl):          SerializeTable(tbl, outStr);
    }
}
```

Note: the `WriteTagged(StringView, int64, String)` overload already exists and takes `int64`. No changes to any helper methods.

---

### Step 3: Rewrite `TomlParser.bf` — All `TomlValue.FromXxx()` calls

Every `TomlValue.FromXxx(...)` becomes `.Xxx(...)`. Expected-type inference resolves the target type from the return type (`Result<TomlValue, ...>`).

**String returns** (6 occurrences):
```bf
// Before:
return TomlValue.FromString(result);
// After:
return .String(result);
```

**Integer returns** (7 occurrences):
```bf
// Before:
return TomlValue.FromInteger(-9223372036854775808);
return TomlValue.FromInteger(-(int64)uval);
return TomlValue.FromInteger((int64)val);
// After:
return .Integer(-9223372036854775808);
return .Integer(-(int64)uval);
return .Integer((int64)val);
```

**Float returns** (5 occurrences):
```bf
// Before:
return TomlValue.FromFloat(double.PositiveInfinity);
return TomlValue.FromFloat(val);
// After:
return .Float(double.PositiveInfinity);
return .Float(val);
```

**Bool returns** (4 occurrences):
```bf
// Before:
if (token == "true") return TomlValue.FromBool(true);
// After:
if (token == "true") return .Bool(true);
```

**DateTime/Date/Time returns** (4 occurrences):
```bf
// Before:
return TomlValue.FromOffsetDateTime(TomlOffsetDateTime(...));
// After:
return .OffsetDateTime(TomlOffsetDateTime(...));
```

**Array returns** (3 occurrences):
```bf
// Before:
return TomlValue.FromArray(arr);
// After:
return .Array(arr);
```

**Table returns** (3 occurrences):
```bf
// Before:
return TomlValue.FromTable(tbl);
// After:
return .Table(tbl);
```

**In `InsertDottedKeyIntoTable`** (3 occurrences):
```bf
// Before:
current.ReplaceValue(key, TomlValue.FromTable(newTbl));
current.Insert(key, TomlValue.FromTable(newTbl));
// After:
current.ReplaceValue(key, .Table(newTbl));
current.Insert(key, .Table(newTbl));
```

---

### Step 4: Rewrite `TomlPathResolver.bf`

**A. Field access → pattern match (6 call sites)**

All `existing.IsTable` / `existing.AsTable` / `existing.IsArray` / `existing.AsArray` pairs become single pattern matches.

In `NavigateSegment`:
```bf
// Before:
if (existing.IsTable)
{
    mCurrentTable = existing.AsTable;
    return .Ok;
}
else if (existing.IsArray)
{
    TomlArray arr = existing.AsArray;
    // ...
}

// After:
if (existing case .Table(let existingTable))
{
    mCurrentTable = existingTable;
    return .Ok;
}
else if (existing case .Array(let arr))
{
    // ...
}
```

Same pattern in `DefineTable` and `DefineArrayOfTables`.

**B. `ValueTypeName` method**

Change signature from `(TomlValueType type, String outStr)` to `(TomlValue value, String outStr)`:

```bf
// Before:
private void ValueTypeName(TomlValueType type, String outStr)
{
    switch (type)
    {
    case .String: outStr.Append("string");
    ...
    }
}

// After:
private void ValueTypeName(TomlValue value, String outStr)
{
    switch (value)
    {
    case .String:       outStr.Append("string");
    case .Integer:      outStr.Append("integer");
    case .Float:        outStr.Append("float");
    case .Bool:         outStr.Append("boolean");
    case .OffsetDateTime: outStr.Append("offset datetime");
    case .LocalDateTime:  outStr.Append("local datetime");
    case .LocalDate:      outStr.Append("local date");
    case .LocalTime:      outStr.Append("local time");
    case .Array:        outStr.Append("array");
    case .Table:        outStr.Append("table");
    }
}
```

Note: payload names are omitted (just `case .String:`, not `case .String(let s):`) since we only need the discriminant.

Update call sites — change `ValueTypeName(existing.mType, msg)` to `ValueTypeName(existing, msg)` (3 call sites).

**C. Factory calls → enum constructors**

```bf
// Before:
TomlValue tableVal = TomlValue.FromTable(newTable);
// After:
TomlValue tableVal = .Table(newTable);

// Before:
arr.Add(TomlValue.FromTable(newElement));
// After:
arr.Add(.Table(newElement));

// Before:
newArray.Add(TomlValue.FromTable(firstElement));
// After:
newArray.Add(.Table(firstElement));

// Before:
mCurrentTable.Insert(key, TomlValue.FromArray(newArray));
// After:
mCurrentTable.Insert(key, .Array(newArray));
```

---

### Step 5: Build and fix compilation errors

Run `BeefBuild` at the workspace root. Expected issues:

1. If `let` binding in `if (x case .Pattern(let y))` doesn't scope as expected in accessor properties, change to `ref` form:
   ```bf
   // Alternative for accessors:
   String s = null;
   if (this case .String(ref s))
       return StringView(s);
   ```

2. Expected-type inference may fail in some contexts. If `.Xxx(...)` doesn't resolve, fully qualify:
   ```bf
   return TomlValue.String(result);  // instead of .String(result)
   ```

---

### Step 6: Verify tests still pass

Run the smoke tests that worked before:
```bash
echo 'key = "hello world"' | ./build/Debug_Linux64/TomlTester/TomlTester
echo 'hex = 0xDEADBEEF' | ./build/Debug_Linux64/TomlTester/TomlTester
echo '3.14159 = "pi"' | ./build/Debug_Linux64/TomlTester/TomlTester
echo '[[fruits]]\nname = "apple"' | ./build/Debug_Linux64/TomlTester/TomlTester
echo 'point = {x = 1, y = 2}' | ./build/Debug_Linux64/TomlTester/TomlTester
```

All should produce identical output to the pre-refactor build.

---

## Important: Do NOT change these files

- `TomlTable.bf` — Uses `TomlValue` only through `Dispose()` and `Dictionary<K,V>` storage. No API surface change.
- `TomlArray.bf` — Uses `TomlValue` only through `Dispose()` and `List<T>` storage. No API surface change.
- `TomlDocument.bf` — No `TomlValue` API surface.
- `TomlCursor.bf`, `TomlScanner.bf`, `TomlError.bf`, `TomlDateTime.bf` — No dependency on `TomlValue` internals.
- `TomlTester/src/Program.bf` — Uses only the public `TomlParser.Parse()` and `TomlSerializer.Serialize()` API.
