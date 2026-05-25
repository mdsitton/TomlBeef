# AGENTS.md

## Notes for coding agents

- This repository is a Beef language project, not a C# project.
- Beef `String` stores UTF-8 data and is mutable. Prefer `StringView` for borrowed string inputs.
- Beef uses manual and scope-based memory management. There is no tracing garbage collector.
- This project currently targets Linux64 first. Treat Windows/macOS support as deferred unless project files or CI say otherwise.
- Preferred CLI tool: `beefbuild` on Linux, `BeefBuild` on Windows. Use from `PATH`.

## Critical rules

- **Do not use scripts or bash commands to edit code.** Use the provided `edit` or `write` tools directly. Violating this will result in a work stoppage.
- **Always use `edit` for changes to existing files**, never `write` unless creating a new file or doing a complete rewrite.
- **When using `edit` with multiple changes** in the same file, merge nearby changes into a single edit call with multiple entries in the `edits` array.
- **Do not include large unchanged regions** in `edits[].oldText`. Keep it as small as possible while still being unique.
- **NEVER REVERT CODE USING GIT OR ANY VERSION CONTROL.** Do not use `git checkout`, `git revert`, `git reset`, or any similar command that discards or rolls back code changes. This destroys work and context. If you think a revert is needed, **end your turn and ask for explicit permission first.**

## Beef Language Gotchas

These are non-obvious Beef behaviors discovered through debugging. Violating these will cause crashes, leaks, or silent failures.

### Memory & lifetime

- **`scope` works for class types** — `scope TomlParser()`, `scope List<T>()` all work fine. The object lives for the enclosing scope.
- **`scope List<String>()` does NOT delete String elements.** The list's internal buffer is freed but contained `String`/class instances leak. Use `defer { ClearAndDeleteItems!(list); }` for scope-allocated lists of owned items.
- **Field initializers with `~ delete _` require an explicit constructor.** Beef's generated default constructor does NOT run field initializers when `~ delete _` is present. Always write `public this() { mField = new Type(); }` explicitly.
- **`~ delete _` is preferred** over manual `~this()` methods for field-level cleanup.
- **`DeleteContainerAndDisposeItems!`, `ClearAndDeleteItems!`, `DeleteDictionaryAndKeys!`** are built-in mixins for container cleanup. Use them instead of manual loops.
- **`defer` on a mixin requires a block wrapper**: `defer { ClearAndDeleteItems!(x); }` — NOT `defer ClearAndDeleteItems!(x);`
- **`delete` on value types (enums, structs) is a no-op.** Types without `~this()` (which structs can't have) need explicit `.Dispose()`.

### String formatting

- **`$\"...{var}...\"` interpolation** is for string literals (`scope $\"key={key}\"`). Variable names are captured from scope.
- **`AppendF(\"...{0}...\" , arg)`** uses `{0}` positional placeholders. Do NOT use `{variable}` syntax in `AppendF` — it compiles but crashes at runtime.
- **`StringView.Substring(pos)` and `Substring(pos, length)`** exist. Prefer them over raw `StringView(&ptr[offset], length)`.

### Switch & pattern matching

- **`switch` does NOT fall through in Beef.** Each case breaks automatically. `fallthrough;` needed to continue into the next case.
- **`switch` on `Result<T, E>`**: `case .Ok(let val):` and `case .Err(let e):`
- **`if (X case .Err(let e))`** is preferred over `switch` for simple error checks. But it does NOT bind the success value — for `.Ok(let val)` extraction, use `switch` or a temporary variable.
- **Enum switches without `default:` warn on non-exhaustiveness** — useful for catching new enum variants.

### Test framework

- **`[Test]` methods must be static.**
- **`beefbuild -test`** auto-discovers `[Test]` methods. No configuration needed.
- **Test assertions produce virtually no console output.** Debug test failures in a console app first, then port to `[Test]` once proven.
- **`[Test(ShouldFail=true)]`** marks an expected failure. If the test passes, the framework reports "Test should have failed but didn't" as an error.
- **A segfault in a test is never acceptable.** `ShouldFail` is for assertion failures, not crashes.

### File I/O

- **`File.ReadAllText` strips exactly one BOM** via StreamReader. Use `File.ReadAll` with `List<uint8>` for raw bytes when BOM-preservation matters.
- **`File.ReadAll` requires `using System.Collections;`** for `List<uint8>`.
- **`entry.GetFilePath(.. scope .())`** — the `.. scope .()` syntax creates a scope-allocated out parameter.

### Type system

- **`StringView` cannot be null.** Passing `null` where `StringView` is expected creates a default/empty StringView. A `Test.Assert(path != null)` on a `StringView` always passes.
- **`char8` vs `int` comparisons** need explicit `(uint8)` casts when comparing with hex literals like `0xEF`.
- **Shadowed variable warnings (BF4200)** — reusing a name like `e` in nested `case .Err(let e)` produces warnings. Use unique names.

### Console & debugging

- **`Console.Out.Flush()`** is often needed to see output before a crash. Console output is buffered.
- **`beefbuild -run`** runs the startup project. Use `-args` to pass arguments.
- **The CLI tool is `beefbuild` (all lowercase).**

## Debugging with lldb/gdb

Beef compiles to native code via LLVM and emits DWARF debug info on Linux. Both lldb (LLVM-native) and gdb work. lldb is preferred since it shares the same toolchain.

### Getting a backtrace on segfault

```bash
# Pipe input via a temp file (lldb doesn't support stdin redirection in batch mode)
echo 'input data' > /tmp/test.toml

# lldb
lldb --batch -o "settings set target.input-path /tmp/test.toml" \
     -o run -o bt ./build/Debug_Linux64/TomlTester/TomlTester

# gdb
echo 'input data' | gdb -batch -ex run -ex bt ./build/Debug_Linux64/TomlTester/TomlTester
```

### Finding the exact crash line

The backtrace shows mangled C++ function names. Key patterns to recognize:

| Mangled name | Beef source |
|---|---|
| `bf::TomlBeef::TomlParser::ParseKeyVal` | `TomlParser.bf` → `ParseKeyVal` |
| `bf::TomlBeef::TomlPathResolver::InsertKeyValue` | `TomlPathResolver.bf` → `InsertKeyValue` |
| `bf::TomlBeef::TomlValue::Dispose` | `TomlValue.bf` → `Dispose` |

Frame #0 is the crash point. The line number appears in the source path suffix (e.g., `TomlPathResolver.bf:265`).

### Diagnosing "Unhandled error in result"

This fatal error means a `Result<T, E>` containing `.Err` was discarded without handling. Beef's `ReturnValueDiscarded()` triggers it. Common causes:

- **Calling a function that returns `Result` without capturing it** — e.g., `AppendF(...)` returns `Result<void>`.
- **`{name}` placeholder in `AppendF` with positional argument** — compiles but crashes at runtime. Use `{}` positional or `$"...{name}..."` interpolation instead.

### Debug build required

Release builds strip debug info. Always debug against the Debug configuration (`build/Debug_Linux64/...`).

### Error patterns

- **Use `Result<T, E>` for fallible operations.** Propagate with `if (X case .Err(let e)) return .Err(e);`
- **`scope String()` for temporary strings** in error messages is fine as long as the message is consumed immediately (e.g., copied into a `TomlParseError`).
- **Don't mix `{key}` interpolation with `AppendF`** — it silently compiles wrong. Use `scope $\"...\"` for interpolation, `AppendF(\"{}\", arg)` for positional.

## Doc Comment Style

For this repository, public API surface should use `///` documentation comments with Doxygen-style tags.

Beef also recognizes `/** */`, but this repository standardizes on `///` for consistency.

**Documentation comments must be placed directly above the declaration, including above any attributes.**

Prefer Doxygen tags over C# XML tags in this repository.

### Required tags in this repository

- `@brief` — Use as the first tag when you want a one-line summary shown prominently.
- `@param` — Required by this repository for every parameter. Use `@param name Description`.
- `@return` — Required by this repository for every non-void method/function.

### Correct

```bf
/// @brief Compute a diff between two UTF-8 buffers.
/// @param oldPointer Pointer to the old text bytes. May be NULL only if oldLength is 0.
/// @param oldLength Number of bytes in the old text.
/// @param newPointer Pointer to the new text bytes. May be NULL only if newLength is 0.
/// @param newLength Number of bytes in the new text.
/// @param options Optional diff options. Pass NULL for defaults.
/// @param outDiffHandle Receives an opaque handle on success.
/// @return MINCE_STATUS_OK on success, or an error code on failure.
[Export, CLink]
public static MinceStatus mince_diff_compute(
    uint8* oldPointer, int oldLength,
    uint8* newPointer, int newLength,
    MinceDiffOptions* options,
    void** outDiffHandle)
```

### Repository-preferred incorrect style

```bf
/// <summary>
/// Compute a diff between two UTF-8 buffers.
/// </summary>
/// <param name="oldPointer">Pointer to old text.</param>
/// <returns>Status code.</returns>
```

### Brief-only for trivial members

For constants, fields, and trivial getters where there are no parameters or meaningful return-value semantics to explain, `@brief` alone is sufficient.

```bf
/// @brief Maximum input size in bytes before Compute returns ResourceLimitExceeded.
public const int DefaultMaxInputBytes = 16 * 1024 * 1024;
```

## Beef Language Conventions

### Visibility

- By default, **struct and class members** are `private`.
- Be explicit with `public` on API surface.
- Members intended for external use should always have an explicit access modifier.
- Internal implementation details may omit `private` when that improves readability.

```bf
// CORRECT — explicit public on API surface
public struct Utf8Slice
{
    public uint8* Ptr { get { return mPointer; } }

    uint8* mPointer; // private by default
}

// WRONG — missing public, defaults to private
struct Utf8Slice
{
    uint8* Ptr { get { return mPointer; } }
}
```

### Expected-type shorthand

Use expected-type shorthand when the target type is obvious and doing so improves readability.

```bf
// VERBOSE
return Result<void, MinceError>.Err(MinceError.InvalidArgument);
MinceDiffOptions options = MinceDiffOptions();

// PREFERRED
return .Err(.InvalidArgument);
MinceDiffOptions options = .();
```

### Struct mutability

Methods on a `struct` that modify the struct must be marked `mut` **after the signature**.

```bf
public struct LineIndex
{
    private int mCount;

    // WRONG — fails to compile
    public void Increment() { mCount++; }

    // CORRECT
    public void Increment() mut { mCount++; }
}
```

### Memory management

- Use `new` for heap allocation.
- Use `delete` or `defer delete` for cleanup.
- Classes can define destructors with `~this()`.
- Structs cannot define destructors. Use `Dispose` for RAII-style cleanup with `using` or `defer`.
- Field destructors such as `~ delete _` are preferred for class fields that own heap values.
- `scope` allocates for a scope target and does not require manual `delete`.

```bf
// CORRECT — field with automatic cleanup
private List<DiffEdit> mEdits = new List<DiffEdit>() ~ delete _;

// CORRECT — local allocation with deferred cleanup
int[] temp = new int[1024];
defer delete temp;

// CORRECT — scope allocation
var builder = scope String();
```

Avoid dead post-allocation null checks after ordinary `new` expressions unless you are using an API that explicitly documents nullable allocation results.

### String interpolation

Interpolation can either construct a `String` or expand directly into a formatting call.

- Prefer `scope $"..."` for temporary strings.
- Prefer direct interpolation at the call site when you do not need to keep the string.
- Prefer appending into an existing buffer when you are already building output incrementally.

```bf
// AVOID — unnecessary owned temporary if only needed briefly
String s = $"Error: {code}";

// PREFERRED — scoped temporary
String s = scope $"Error: {code}";

// PREFERRED — direct expansion at call site
Console.WriteLine($"Error: {code}");

// PREFERRED — append to an existing buffer
var builder = scope String();
builder.AppendF("Error: {}", code);
```

### Result<T, E> for fallible operations

Project rule:

- Use `Result<T, MinceError>` for recoverable Beef-side errors.
- Use `MinceStatus` only at the C ABI boundary.
- If the C ABI depends on direct casting between `MinceError` and `MinceStatus`, keep their explicit values aligned.

```bf
// CORRECT — Beef API returns Result
public static Result<void, MinceError> Append(StringView text)

// CORRECT — C ABI returns status enum
[Export, CLink]
public static MinceStatus mince_diff_compute(...)
```

### No exceptions

Beef does not support `try`/`catch` or `throw`.

In this repository, use `Result` and `Try!` for recoverable errors.

```bf
// WRONG — C#-style exceptions do not exist
try { DoSomething(); } catch { return .Err; }

// CORRECT — Beef error propagation
var result = Try!(DoSomethingFallible());
```

### String types — know which one to use

| Type | Ownership | Use case |
|------|-----------|----------|
| `String` | Owned, mutable | Internal buffers, owned copies |
| `StringView` | Borrowed | Function parameters, temporary views |
| `Utf8Slice` | Borrowed | This repository's raw byte-view type in the text subsystem |
| `char8*` | Raw pointer | FFI boundaries, low-level byte access |

- Prefer `StringView` over `String` for borrowed input parameters.
- Never store a `StringView` in a long-lived object unless you also own the backing storage.
- Use `String` output buffers when you want the caller to control allocation.

## C ABI Export Conventions

### Use both attributes for exported C ABI symbols with exact C names

```bf
[Export, CLink]
public static MinceStatus mince_diff_compute(...)
```

- `[Export]` exports the symbol.
- `[CLink]` uses a C link name instead of C++-style mangling.

For this repository's C ABI, use both together unless you have a documented reason not to.

### References vs pointers

- Prefer `ref` and `out` for internal Beef APIs.
- Prefer raw pointers (`uint8*`, `void*`, etc.) at the C ABI boundary and in other low-level code where pointer semantics are intentional.
- `out` parameters must be assigned before the method returns.

```bf
// CORRECT — internal Beef API
public static void GetStats(StringView text, out int words, out int lines)

// CORRECT — C ABI FFI
[Export, CLink]
public static void mince_get_stats(uint8* text_ptr, int text_len, int* out_words, int* out_lines)
```

### [CRepr] structs for C-visible data

```bf
[CRepr]
public struct MinceDiffOptions
{
    public uint32 size;
    public uint32 max_input_bytes;
    ...
}
```

- Use `[CRepr]` for C-visible structs.
- Project rule: versioned C ABI structs should place `uint32 size` first for forward compatibility.
- Keep the Beef `[CRepr]` struct and the C header declaration exactly aligned.
- After changing either, update an offset/layout verification test.

### Opaque handles

- Use `void*` for opaque handles in the C ABI.
- Inside Beef, recover the concrete object with `Internal.UnsafeCastToObject` or other appropriate unsafe cast helpers.
- Document the concrete backing type in the Beef doc comment.

```bf
/// @brief Destroy a diff handle previously returned by mince_diff_compute.
/// @param diffHandle The opaque handle. Safe to pass NULL (no-op).
[Export, CLink]
public static void mince_diff_destroy(void* diffHandle)
{
    if (diffHandle == null)
        return;

    var result = (DiffResult)Internal.UnsafeCastToObject(diffHandle);
    delete result;
}
```

### Null rules for this repository's C ABI

- `ptr == NULL` is valid only when the corresponding length is 0.
- Required output pointers must be non-null.
- Options pointers may be null to request defaults.
- Validate required pointers early and return `.InvalidArgument` on contract violations.

## Naming Conventions

### General

| Kind | Convention | Example |
|------|-----------|---------|
| Types | PascalCase | `DiffResult`, `MinceStatus` |
| Methods/functions | PascalCase | `Compute`, `RenderUnified` |
| Fields (public) | camelCase | `maxInputBytes` |
| Fields (private) | `m` + PascalCase | `mEdits`, `mOldText` |
| Constants / enum values | PascalCase | `DefaultMaxInputBytes`, `Ok` |
| C ABI functions | `snake_case` with `mince_` prefix | `mince_diff_compute` |
| C ABI types | PascalCase with `Mince` prefix | `MinceDiffOptions` |
| C ABI struct fields | `snake_case` | `max_input_bytes` |

### Consistency across layers

Use consistent semantic names across the Beef API, the C ABI export layer, and the C header.

```bf
// Beef internal
public static Result<void, MinceError> Compute(StringView oldText, StringView newText, ...)

// C ABI export
public static MinceStatus mince_diff_compute(uint8* oldPointer, int oldLength, ...)

// C header
MinceStatus mince_diff_compute(const uint8_t* old_pointer, size_t old_len, ...);
```

Prefer:

- `oldText` / `newText` for `StringView`
- `oldPointer` / `newPointer` for raw `uint8*`
- `oldBytes` / `newBytes` when emphasizing byte-level contracts

## Code Organization

### Intended project layout

- Each public type should normally get its own file.
- Small helper types may share a file when that genuinely improves cohesion.

### Project structure

Official Beef sample projects do not enumerate `src/` explicitly in `BeefProj.toml`. In this repository, avoid redundant source-directory declarations unless you have verified a specific need.

## Build and Test Conventions

### Running tests

- `[Test]` methods must be static.
- Keep repository tests under `src/tests/` unless the existing workspace already uses a different layout.
- Run tests with: `BeefBuild -test`

### Running programs with arguments

`-run` compiles and executes the startup project. `-args` passes arguments to the compiled program.
- `-args` **must** come after `-run`. Everything following `-args` on the command line is passed through as program arguments.
- No quoting needed — each shell token becomes a separate `String[]` entry. Use shell quoting only when an argument itself contains spaces.
- Not yet shown in `-help` output.

```bash
BeefBuild -run -args hello world             # args = ["hello", "world"]
BeefBuild -run -args "arg with spaces" more  # args = ["arg with spaces", "more"]
```

## References

- Official Beef documentation: `https://www.beeflang.org/docs/`
- Official docs source repository: `beefytech/Beef_website`
  - available within the ~/development folder
- Official language/tool source repository: `beefytech/Beef`
  - available within the ~/development folder
