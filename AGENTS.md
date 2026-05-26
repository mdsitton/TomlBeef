# AGENTS.md

## Notes for coding agents

- This repository is a Beef language project, not a C# project.
- Beef `String` stores UTF-8 data and is mutable. Prefer `StringView` for borrowed string inputs.
- Beef uses manual and scope-based memory management. There is no tracing garbage collector.
- This project currently targets Linux64 first. Treat Windows/macOS support as deferred unless project files or CI say otherwise.
- Preferred CLI tool: `beefbuild` on Linux, `BeefBuild` on Windows. Use from `PATH`.
- Treat `BJSON/` and `toml-test/` as external upstream/reference material; do not edit them unless the task explicitly targets those dependencies.
- Treat `recovery/` as forensic/generated reference material; consult it only for historical context and do not edit it unless explicitly requested.

## Critical rules

- **Do not use scripts or bash commands to edit code.** Use the provided `edit` or `write` tools directly. Violating this will result in a work stoppage.
- **Always use `edit` for changes to existing files**, never `write` unless creating a new file or doing a complete rewrite.
- **When using `edit` with multiple changes** in the same file, merge nearby changes into a single edit call with multiple entries in the `edits` array.
- **Do not include large unchanged regions** in `edits[].oldText`. Keep it as small as possible while still being unique.
- **NEVER REVERT CODE USING GIT OR ANY VERSION CONTROL.** Do not use `git checkout`, `git revert`, `git reset`, or any similar command that discards or rolls back code changes. This destroys work and context. If you think a revert is needed, **end your turn and ask for explicit permission first.**
- **Verify Beef source/project changes.** After modifying `.bf`, `BeefProj.toml`, or workspace files, run the most relevant `beefbuild` check (`beefbuild -test`, `beefbuild -run`, or `beefbuild -config=Release -run`) and report results. For docs-only edits (including `AGENTS.md`), no build is required. If verification cannot be run, say why.

## Beef Language Gotchas

These are non-obvious Beef behaviors discovered through debugging. Violating these will cause crashes, leaks, or silent failures.

### Memory & lifetime

- **`scope` works for class types** — `scope TomlParser()`, `scope List<T>()` all work fine. The object lives for the enclosing scope.
- **`scope List<String>()` does NOT delete String elements.** The list's internal buffer is freed but contained `String`/class instances leak. Use `defer { ClearAndDeleteItems!(list); }` for scope-allocated lists of owned items.
- **Field initializers with `~ delete _` require an explicit constructor.** Beef's generated default constructor does NOT run field initializers when `~ delete _` is present. Always write `public this() { mField = new Type(); }` explicitly.
- **`~ delete _` is preferred** over manual `~this()` methods for field-level cleanup.
- **`DeleteContainerAndDisposeItems!`, `ClearAndDeleteItems!`, `DeleteDictionaryAndKeys!`** are built-in mixins for container cleanup. Use them instead of manual loops.
- **`defer` on a mixin requires a block wrapper**: `defer { ClearAndDeleteItems!(x); }` — NOT `defer ClearAndDeleteItems!(x);`
- **`defer` runs in LIFO order.** For `defer SomeCall(arg)`, `arg` and `this` are evaluated immediately; for `defer { ... }`, captured variables are read when the scope exits.
- **`delete` on value types (enums, structs) is a no-op.** Types without `~this()` (which structs can't have) need explicit `.Dispose()`.

### String formatting

- **`$"...{var}..."` interpolation** is for string literals (`scope $"key={key}"`). Variable names are captured from scope.
- **`AppendF("...{}...", arg)` / `AppendF("...{0}...", arg)`** use positional placeholders. Do NOT use `{variable}` syntax in `AppendF` — it compiles but crashes at runtime.
- **Do not mutate string literals.** `String s = "literal"; s.Append(...)` attempts to mutate read-only literal storage. Use `scope String()..Append(...)` or `scope $"..."`.
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
- **`out` and `var` are mutually exclusive in parameter position.** You write `out existingVar` to assign to a pre-existing variable, or `var newVar` to declare inline. Writing `out var x` does **not** compile in Beef. The `out` keyword always pairs with a declared variable in an outer scope. Use `var` for inline declaration with type inference.
- **Reserved identifiers include `box`.** Do not use `box` as a local/parameter/field name. For generated identifiers that may collide with keywords, prefix with `@` or use `Compiler.Identifier.GetSourceName`.
- **Prefer Beef primitive aliases** (`int32`, `uint8`, `float`, `bool`) over wrapper type names such as `System.Int32`. Wrapper types are primarily for boxing/reflection and can create conversion friction.

#### Special type references

- **`Self`** — The defining type. Within an interface, it refers to the implementing type.
- **`SelfBase`** — The base class of the defining type.
- **`SelfOuter`** — The outer type of the defining type (for nested types).
- **`var`** — Mutable variable with type inference. `var x = 42;` infers `int32 x`.
- **`let`** — Immutable variable with type inference. `let x = scope String();` infers the type but disallows reassignment.
- **`.` (dot type)** — Refers to "the expected type". Used to turn implicit conversions into explicit ones without naming the type. E.g., `intVal = (.)floatVal` when the compiler expects `int`. Most common in `return .Err(...)` and `return .Ok(...)`. See "Expected-type shorthand" under Language Conventions for more examples.

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
- **Don't mix `{key}` interpolation with `AppendF`** — it silently compiles wrong. Use `scope $"..."` for interpolation, `AppendF("{}", arg)` for positional.

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
/// @brief Parse a TOML string into a document tree.
/// @param input The TOML text to parse. Must be valid UTF-8.
/// @return A TomlDocument on success, or a TomlParseError with line/column info on failure.
public Result<TomlDocument, TomlParseError> Parse(StringView input)
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

### Imports (`using`)

- Keep all `using` directives at the top of the file.
- Prefer ordering: `System*` namespaces first, then external/dependency namespaces, then project/app namespaces. Remove unused imports.
- Common imports: `System.Collections` for `List<T>`, `Dictionary<TKey, TValue>`, `HashSet<T>`; `System.IO` for `File`, `Directory`, `Path`, streams; `System.Diagnostics` for `Debug` and `Stopwatch`; `System.Threading` for `Thread`, `Monitor`, `Interlocked`.

### Member access

By default, struct and class members are `private`.

| Modifier | Accessible from |
|----------|----------------|
| `private` (default) | Only within the defining type |
| `protected` | Defining type and derived types |
| `internal` | Files specifying `using internal <namespace>;` |
| `protected internal` | Combination of `protected` and `internal` |
| `public` | Anywhere |

Key detail: even types within the same namespace must explicitly write `using internal <namespace>;` to access `internal` members of each other. This is different from C# where `internal` is assembly-wide by default.

- Be explicit with `public` on API surface.
- Members intended for external use should always have an explicit access modifier.
- Internal implementation details may omit `private` when that improves readability.

```bf
// CORRECT — explicit public on API surface
public struct TomlCursor
{
    public int Line { get; }

    int mOffset; // private by default
}

// WRONG — missing public, defaults to private
struct TomlCursor
{
    public int Line { get; }
}
```

### Expected-type shorthand

Use expected-type shorthand when the target type is obvious and doing so improves readability.

```bf
// VERBOSE
return Result<void, TomlParseError>.Err(TomlParseError(.InvalidUtf8, "message", 0, 0, 0));
TomlParser parser = TomlParser(.V1_1);

// PREFERRED
return .Err(TomlParseError(.InvalidUtf8, "message", 0, 0, 0));
TomlParser parser = scope .(.V1_1);
```

The `.` shorthand also resolves enum cases in pattern matching:

```bf
// PREFERRED — .Err and .Ok auto-resolve to the return type's enum cases
switch (parser.Parse(input))
{
case .Err(let e): ...
case .Ok(let doc): ...
}
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

### Properties and fields

- Beef properties are methods. Use properties for validation, computed values, ref returns, or API compatibility; simple data structs may use fields when no logic is needed.
- A property setter on a struct that mutates fields must be marked `set mut`.
- Ref-return properties (`ref T Prop => ref mValue`) expose mutation through assignment and by-reference calls; use them deliberately.

### Memory management

- Use `new` for heap allocation.
- Use `delete` or `defer delete` for cleanup.
- Classes can define destructors with `~this()`.
- Structs cannot define destructors. Use `Dispose` for RAII-style cleanup with `using` or `defer`.
- Field destructors such as `~ delete _` are preferred for class fields that own heap values.
- `scope` allocates for a scope target and does not require manual `delete`.

```bf
// CORRECT — field with automatic cleanup
private List<TomlValue> mItems = new List<TomlValue>() ~ DeleteContainerAndDisposeItems!(_);

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

- Use `Result<T, TomlParseError>` for fallible operations.
- Propagate errors with `if (X case .Err(let e)) return .Err(e);`.

```bf
// CORRECT — parser returns Result
public Result<TomlDocument, TomlParseError> Parse(StringView input)

// CORRECT — path resolver returns Result
private Result<void, TomlParseError> InsertKeyValue(StringView key, TomlValue value)
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
| `char8*` | Raw pointer | Low-level byte access |

- Prefer `StringView` over `String` for borrowed input parameters.
- Never store a `StringView` in a long-lived object unless you also own the backing storage.
- Use `String` output buffers when you want the caller to control allocation.
- Prefer APIs that append into caller-provided `String` buffers for produced strings. Do not return `new String` unless ownership is explicit, and never return a `scope String`.

## Naming Conventions

### General

| Kind | Convention | Example |
|------|-----------|---------|
| Types | PascalCase | `TomlParser`, `TomlDocument` |
| Methods/functions | PascalCase | `Parse`, `TryGetString` |
| Fields (public) | camelCase | `maxInputBytes` |
| Fields (private) | `m` + PascalCase | `mEntries`, `mRootTable` |
| Fields (static/private) | `s` + PascalCase | `sScratchBuffer` |
| Constants / enum values | PascalCase | `DefaultMaxInputBytes`, `Ok` |

## Code Organization

### Intended project layout

- Each public type should normally get its own file.
- Small helper types may share a file when that genuinely improves cohesion.

### Project structure

Official Beef sample projects do not enumerate `src/` explicitly in `BeefProj.toml`. In this repository, avoid redundant source-directory declarations unless you have verified a specific need.

## Build and Test Conventions

### General

- Use `beefbuild -help` as the source of truth for supported CLI flags; on Linux, prefer the lowercase `beefbuild` executable.
- For parser/serializer behavior changes, run the relevant repository acceptance scripts as well as Beef tests (for example `./test-toml.sh` and/or `./test-roundtrip.sh`).

### Running tests

- `[Test]` methods must be static.
- Keep repository tests under `src/tests/` unless the existing workspace already uses a different layout.
- Run tests with: `beefbuild -test`

### Running programs with arguments

`-run` compiles and executes the startup project. `-args` passes arguments to the compiled program.
- `-args` **must** come after `-run`. Everything following `-args` on the command line is passed through as program arguments.
- No quoting needed — each shell token becomes a separate `String[]` entry. Use shell quoting only when an argument itself contains spaces.
- Not yet shown in `-help` output.

```bash
beefbuild -run -args hello world             # args = ["hello", "world"]
beefbuild -run -args "arg with spaces" more  # args = ["arg with spaces", "more"]
```

## References

- Official Beef documentation: `https://www.beeflang.org/docs/`
- Official docs source repository: `beefytech/Beef_website`
  - available within the ~/development folder
- Official language/tool source repository: `beefytech/Beef`
  - available within the ~/development folder
