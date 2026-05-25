# TOML 1.0 Compatibility Mode — Implementation Plan

## Overview

Add a `TomlVersion` parameter to `TomlParser` that gates 6 syntax features that differ between TOML v1.0 and v1.1. Default remains v1.1. The `TomlTester` gains a `-toml 1.0` flag so `toml-test` can validate against the v1.0 suite.

## Files Changed

| File | Change |
|------|--------|
| `src/TomlBeef/TomlVersion.bf` | **New** — 4-line enum |
| `src/TomlBeef/TomlParser.bf` | +1 field, +1 constructor param, +7 version-gated conditionals |
| `TomlTester/src/Program.bf` | +~10 lines flag parsing |

## Step 1: New file — `src/TomlBeef/TomlVersion.bf`

```bf
namespace TomlBeef;

/// TOML specification version. Controls which syntax features the parser accepts.
public enum TomlVersion
{
    V1_0,
    V1_1
}
```

## Step 2: Modify `TomlParser.bf`

### 2a. Add field and constructor parameter

```bf
public class TomlParser
{
    private TomlCursor mCursor ~ delete _;
    private TomlDocument mDocument ~ delete _;
    private TomlPathResolver mPathResolver ~ delete _;
    private TomlVersion mVersion;              // ← new
    private int mDepth = 0;
    private const int mMaxDepth = 256;

    public this(TomlVersion version = .V1_1)   // ← parameter
    {
        mVersion = version;
    }
```

### 2b. Gate `\e` escape (line ~592)

```bf
case 'e':
    if (mVersion == .V1_0)
        return .Err(Error(.ReservedEscape, "\\e escape requires TOML v1.1"));
    result.Append((char8)0x1B); return .Ok;
```

### 2c. Gate `\xHH` escape (line ~595)

```bf
case 'x':
    if (mVersion == .V1_0)
        return .Err(Error(.ReservedEscape, "\\x escape requires TOML v1.1"));
    return ParseHexEscape(result, 2);
```

### 2d. Gate omitted seconds

`ParseTimePart` already returns `true` with `second = 0` when seconds are omitted. Track whether seconds were present via a new `out bool` parameter:

**Change `ParseTimePart` signature:**
```bf
private bool ParseTimePart(StringView token, ref int pos,
    out int32 hour, out int32 minute, out int32 second, out int64 nanosecond,
    out bool secondsOmitted)  // ← new parameter
{
    hour = 0; minute = 0; second = 0; nanosecond = 0;
    secondsOmitted = true;    // assume omitted until proven present
    // ... existing parsing ...
    if (pos < token.Length && token[pos] == ':')
    {
        secondsOmitted = false;  // seconds explicitly present
        // ... parse seconds ...
    }
    return true;
}
```

**Check in `TryParseOffsetDateTime` (line ~1170):**
```bf
bool secondsOmitted = false;
if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
    return .Err(Error(.InvalidTime, "Invalid time in datetime"));
if (mVersion == .V1_0 && secondsOmitted)
    return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));
```

**Same check in `TryParseLocalDateTime` (line ~1205) and `TryParseLocalTime` (line ~1235).**

### 2e. Gate newlines in inline tables

In `ParseInlineTable`, the calls to `SkipWsAndComments()` currently default to `allowNewlines = true`. Pass `false` for v1.0:

```bf
// In ParseInlineTable, change every:
SkipWsAndComments()
// To:
SkipWsAndComments(mVersion != .V1_0)
```

There are 5 call sites in `ParseInlineTable` (before `{`, between pairs, before `,`, before `}`/end).

### 2f. Gate trailing comma in inline tables

In `ParseInlineTable`, after a `,` is consumed, check if `}` follows:

```bf
if (b == ',')
{
    mCursor.AdvanceByte();
    // Trailing comma: reject in v1.0
    if (mVersion == .V1_0 && mCursor.PeekByte() == '}')
        return .Err(Error(.UnexpectedToken,
            "Trailing comma in inline table requires TOML v1.1"));
    // ... rest of comma handling ...
}
```

### 2g. Gate space as datetime separator (optional, no test coverage)

```bf
// In TryParseOffsetDateTime / TryParseLocalDateTime:
char8 sep = token[pos];
if (sep == 'T' || sep == 't') pos++;
else if (sep == ' ' && mVersion != .V1_0) pos++;  // space only in v1.1
else return .Err(Error(.InvalidDateTime, "Expected date-time separator"));
```

This has no toml-test coverage for v1.0 but is correct per the ABNF. Can be deferred.

## Step 3: Modify `TomlTester/src/Program.bf`

```bf
public static int Main(String[] args)
{
    bool encode = false;
    TomlVersion version = .V1_1;

    for (int i = 0; i < args.Count; i++)
    {
        if (args[i] == "-encode")
            encode = true;
        else if (args[i] == "-toml" && i + 1 < args.Count)
        {
            if (args[i + 1] == "1.0") version = .V1_0;
            else if (args[i + 1] == "1.1") version = .V1_1;
            i++;
        }
    }

    String input = scope String();
    Console.In.ReadToEnd(input);

    TomlParser parser = scope TomlParser(version);
    // ... rest unchanged ...
}
```

## Step 4: Testing

```bash
# Build
BeefBuild

# v1.1 tests (baseline, must not regress)
toml-test test -decoder './TomlTester -toml 1.1' -toml 1.1

# v1.0 tests (new, should pass all 9 previously-failing v1.0 tests)
toml-test test -decoder './TomlTester -toml 1.0' -toml 1.0

# Roundtrip (unchanged — writer always produces v1.1-compatible output)
./test-roundtrip.sh
```

## Expected Outcome

| Suite | Before | After |
|-------|--------|-------|
| v1.1 valid | 214/214 (100%) | 214/214 (100%) |
| v1.1 invalid | 467/467 (100%) | 467/467 (100%) |
| v1.0 valid | 205/205 (100%) | 205/205 (100%) |
| v1.0 invalid | 456/465 (98.1%) | **465/465 (100%)** |

The 9 previously-accepted v1.0 invalid tests (`no-secs` × 3, `linebreak` × 4, `trailing-comma`, `basic-byte-escapes`) will now be correctly rejected when running with `-toml 1.0`.

## Total Changes

~35 lines of new/modified code across 3 files. All changes are additive gated behind `mVersion == .V1_0` checks with no effect on v1.1 behavior.
