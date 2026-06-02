# TomlValue Document-Owned Storage Refactor Plan - 2026-05-30

## Purpose

This plan replaces the current owner-carrying `TomlValue` model with a document-owned storage model.

Current problem:

- `TomlValue` is a value type but may contain owning class references (`String`, `TomlArray`, `TomlTable`). These are Beef reference types.
- Accessors return shallow `TomlValue` copies.
- A caller can accidentally call `Dispose()` on a borrowed value and free document-owned memory.
- The temporary `TomlValueView`/`TomlTableView`/`TomlArrayView` APIs reduce risk, but they add another parallel value API. (Since removed - `TomlValue` is now non-owning, views are unnecessary.)

New direction:

- `TomlDocument` owns all heap-backed TOML data.
- `TomlValue` is non-owning and safe to copy.
- Containers hold non-owning `TomlValue` handles containing Beef class references.
- Explicit copy APIs are provided for callers who need independent ownership or native data.

This plan should be worked before continuing the previous resource-limit / UTF-8 follow-up items.

---

## Target ownership model

### Invariants

1. A `TomlDocument` owns all heap-backed payloads in its tree:
   - TOML strings
   - TOML arrays
   - TOML tables
2. `TomlValue` does **not** own or dispose payloads.
3. `TomlTable` and `TomlArray` do **not** dispose child `TomlValue` payloads.
4. `TomlDocument.Clear()` and `delete TomlDocument` release document-owned payloads.
5. Removed/replaced payloads may remain alive until document clear/destruction.
   - This keeps previously returned non-owning values valid while the document is alive.
   - They may become stale snapshots and no longer reflect the current document tree.
6. A `TomlValue` sourced from a document is valid only while the owning document is alive and has not been cleared.
7. Public APIs should steer users toward native scalar copies (`int64`, `double`, `bool`, date structs), borrowed `StringView`, and document-owned table/array handles.
8. Deep copies must be explicit and must copy into a target `TomlDocument` or caller-provided native container.

### Non-goals for the first implementation

- Do not implement arena compaction.
- Do not implement per-value deallocation on remove/replace.
- Do not guarantee that stale values reflect the current tree after mutation.
- Do not make byte-for-byte roundtrip preservation part of this refactor.

---

## Proposed architecture

### New internal owner class backed by `BumpAllocator`

Use `System.BumpAllocator` as the document arena instead of keeping owner lists of references. This better matches the desired lifetime model: all document-owned heap objects are released together when the document store is reset or destroyed.

Candidate file: `src/TomlBeef/TomlDocumentStore.bf`.

```bf
internal class TomlDocumentStore
{
    private BumpAllocator mAlloc ~ delete _;
    private TomlTable mRootTable; // borrowed reference to arena-owned root table

    public this();

    internal TomlTable RootTable => mRootTable;

    internal String NewString(StringView value);
    internal TomlTable NewTable(TomlTableOrigin origin, bool suppressAutoDirty = false);
    internal TomlArray NewArray(bool suppressAutoDirty = false);
    internal TomlArray NewArray(int capacity, bool suppressAutoDirty = false);

    // CopyValue removed - CloneInto(store) is the single copy path.
    internal void Reset();
}
```

Notes:

- Allocate document-owned classes with `new:mAlloc Type(...)`.
- The allocator, not owner lists, owns destruction of arena-allocated objects.
- Do not individually `delete` arena-allocated `String`, `TomlTable`, or `TomlArray` references.
- `Reset()` should delete the old `BumpAllocator`, create a new one, and allocate a fresh root table.
- Use `BumpAllocator` with destructor handling enabled so arena-allocated classes with destructors are finalized when the allocator is deleted.
- If later optimizing string buffers into the same arena, consider `StringWithAlloc`; the first implementation can use normal `String` objects and rely on destructor handling.

### Document fields

`TomlDocument` should own the store. The root table becomes a borrowed reference to a store-owned object.

Candidate structure:

```bf
private TomlDocumentStore mStore ~ delete _;
private TomlTable mRootTable; // borrowed from mStore.RootTable; do not delete directly
private TomlDocumentMetadata mMetadata ~ delete _;
```

On document construction and after store reset, set `mRootTable = mStore.RootTable`.

### Table/array store reference

`TomlTable` and `TomlArray` should know their owning store for programmatic insertion/copy operations.

```bf
private TomlDocumentStore mStore; // borrowed, nullable only for legacy standalone mode if retained
```

Preferred constructors:

```bf
internal this(TomlDocumentStore store, TomlTableOrigin origin, bool suppressAutoDirty = false)
internal this(TomlDocumentStore store, int capacity, bool suppressAutoDirty = false)
```

Public direct constructors should be reviewed. Options:

1. Keep them temporarily in legacy standalone-owning mode.
2. Deprecate them and add document factory APIs.
3. Make them internal in a later breaking phase.

The safest migration is to keep them temporarily, but route all `TomlDocument` parsing/building through store-backed constructors.

---

## Public API target

### Public write APIs accept concrete TOML data, not `TomlValue`

External mutation APIs should not accept `TomlValue`. `TomlValue` remains the internal tagged storage representation used by the parser/resolver/serializer and possibly by read APIs, but users should not need to construct it to build TOML programmatically.

This closes the ownership hole where a caller can write `.String(new String(...))`, `.Array(new TomlArray())`, or `.Table(new TomlTable(...))` and accidentally create ambiguous ownership. Public APIs should accept borrowed scalar data or create child containers through the owning document/table/array.

Candidate APIs on `TomlDocument`:

```bf
public Result<void, TomlParseError> SetString(StringView path, StringView value);
public Result<void, TomlParseError> SetInteger(StringView path, int64 value);
public Result<void, TomlParseError> SetFloat(StringView path, double value);
public Result<void, TomlParseError> SetBool(StringView path, bool value);
public Result<void, TomlParseError> SetLocalDate(StringView path, TomlLocalDate value);
// etc.

public Result<TomlArray, TomlParseError> AddArray(StringView path);
public Result<TomlTable, TomlParseError> AddTable(StringView path, TomlTableOrigin origin = .ExplicitHeader);
```

Candidate APIs on `TomlTable`:

```bf
public void SetString(StringView key, StringView value);
public void SetInteger(StringView key, int64 value);
public void SetFloat(StringView key, double value);
public void SetBool(StringView key, bool value);
public void SetLocalDate(StringView key, TomlLocalDate value);
// etc.

public TomlArray AddArray(StringView key);
public TomlTable AddTable(StringView key, TomlTableOrigin origin = .ExplicitHeader);
```

Candidate APIs on `TomlArray`:

```bf
public void AddString(StringView value);
public void AddInteger(int64 value);
public void AddFloat(double value);
public void AddBool(bool value);
public void AddLocalDate(TomlLocalDate value);
// etc.

public TomlArray AddArray();
public TomlTable AddTable(TomlTableOrigin origin = .ArrayElement);
```

Internal APIs can keep accepting `TomlValue`:

```bf
internal void InsertValue(StringView key, TomlValue value);
internal void AddValue(TomlValue value);
internal bool ReplaceValue(StringView key, TomlValue value);
```

These internal APIs must route heap-backed payloads through the owning document store.

### Explicit copy APIs

Add APIs for callers who need independent copies.

```bf
public bool CopyString(StringView path, String outString);
public Result<TomlValue> CloneValueInto(StringView path, TomlDocument targetDocument);
public TomlDocument CloneDocument(); // optional later
```

For `TomlValue`:

```bf
public TomlValue CloneInto(TomlDocument targetDocument);
```

The existing parameterless `Clone()` should be deprecated or removed because a non-owning value needs a target owner for heap-backed payloads.

### Role of current view APIs

The recently added view APIs were removed in Phase 8 after `TomlValue` became non-owning and `Dispose()` was removed. Without the disposal footgun, the view layer was unnecessary API surface.

- `TomlValueView` - removed
- `TomlTableView` - removed
- `TomlArrayView` - removed

---

## Detailed implementation phases

## Phase 0 - Design freeze and allocation inventory

**Goal:** Identify every heap-backed TOML payload allocation and every disposal point before changing ownership.

### Tasks

- [ ] Inventory all `new String`, `new TomlTable`, and `new TomlArray` production-code call sites.
- [ ] Inventory all `TomlValue.Dispose()` call sites.
- [ ] Inventory table/array cleanup mixins:
  - `DeleteDictionaryAndKeysAndDisposeValues!`
  - `DeleteContainerAndDisposeItems!`
- [ ] Decide whether public `TomlTable()` / `TomlArray()` constructors stay temporarily or become internal later.
- [x] Decide whether public mutation APIs accept `TomlValue`: they should not; public writes use concrete typed APIs.
- [ ] Decide whether stale values remain valid until document `Clear()`.
  - Recommended: yes, because arena storage makes this natural.

### Acceptance criteria

- [ ] A checklist of allocation/disposal sites exists in the implementation notes or commit message.
- [ ] No code changes are mixed into this phase unless trivial comments/tests are added.

---

## Phase 1 - Add `TomlDocumentStore`

**Goal:** Introduce document-level payload ownership without changing parser behavior yet.

### Tasks

- [ ] Add `src/TomlBeef/TomlDocumentStore.bf`.
- [ ] Implement `BumpAllocator mAlloc` inside the store.
- [ ] Implement allocation helpers:
  - `NewString`
  - `NewTable`
  - `NewArray`
  - `CopyValue` (removed later - `CloneInto(store)` became the single copy path)
- [ ] Allocate the root table inside the store.
- [ ] Add `mStore` to `TomlDocument`.
- [ ] Initialize `mStore` and `mRootTable = mStore.RootTable` in `TomlDocument.this()`.
- [ ] Remove direct field destruction of `mRootTable`; it is arena-owned.
- [ ] Implement store `Reset()` by deleting/recreating the bump allocator and root table.

### Important Beef notes

- Use explicit constructors when fields have `~ delete _` destructors.
- Avoid storing `scope` values in the store.
- Do not individually delete objects allocated with `new:mAlloc`; the allocator owns them.
- Container destructors must not delete child/key/value objects that are arena-owned, or they may double-destroy objects when the allocator is deleted.

### Tests

- [ ] Add a small internal/unit test that creates a document, allocates values via store-backed APIs, clears the document, and can parse again.

### Verification

```bash
beefbuild -test
```

---

## Phase 2 - Make containers non-owning with respect to child values

**Goal:** `TomlTable` and `TomlArray` stop freeing child value payloads.

### Tasks

- [ ] Change `TomlArray.mItems` cleanup from value-disposing cleanup to plain list deletion.
  - Current: `DeleteContainerAndDisposeItems!(_)`.
  - Target: delete list buffer only.
- [ ] Change `TomlTable.mEntries` cleanup to delete the dictionary storage only.
  - Current: `DeleteDictionaryAndKeysAndDisposeValues!(_)`.
  - Target: delete the dictionary object/buffer only; do not delete keys or child values.
- [ ] Update `TomlTable.Clear()` to clear/delete dictionary/list storage only; do not delete keys, containers, or child payloads that are arena-owned.
- [ ] Update `TomlArray` clear behavior if a clear API exists or is added later.
- [ ] Remove value-dispose calls from:
  - `TomlTable.Insert`
  - `TomlTable.ReplaceValue`
  - `TomlTable.Remove`
  - `TomlArray` index setter
- [ ] Keep metadata cleanup unchanged.

### Temporary compatibility choice

During this phase, `TomlValue.Dispose()` may still exist but should become either:

1. a no-op with strong deprecation comments, or
2. internal-only after all internal calls are removed.

Recommended intermediate step: make it a no-op/deprecated first, then remove/restrict later.

### Risks

If parser allocations are not store-owned yet, this phase can leak. Therefore either:

- do this after parser allocations are moved to the store, or
- land it in the same implementation branch as Phase 3 before final verification.

### Verification

```bash
beefbuild -test
```

---

## Phase 3 - Route parser and resolver allocations through the store

**Goal:** Every heap-backed payload created during parse is registered with a document/temp store.

### Tasks

- [ ] Pass `TomlDocumentStore` to `TomlParserImpl` or through parse context.
- [ ] Pass `TomlDocumentStore` to `TomlPathResolver`.
- [ ] Replace parser `new String` success ownership with store adoption/copy.
  - Parser may still build temporary `String` values, but final TOML strings must be store-owned.
- [ ] Replace parser `new TomlArray` with `store.NewArray(...)`.
- [ ] Replace parser `new TomlTable` with `store.NewTable(...)`.
- [ ] Replace resolver-created implicit tables and arrays with store allocation.
- [ ] Audit parse error paths:
  - Do not `delete` store-owned tables/arrays.
  - Keep deleting temporary scratch strings that are not adopted into the store.
- [ ] Ensure parse failure clears the active store.

### Replace mode behavior

For `Read(..., Mode = .Replace)`:

1. Clear root table.
2. Clear document store.
3. Parse directly into the document root using the document store.
4. If parse fails, clear root table and store again.

### Merge mode behavior

For `Read(..., Mode = .Merge)`:

1. Create a temporary root table and temporary store.
2. Parse incoming data into the temporary root/store.
3. On parse failure, delete temp root/store and leave document unchanged.
4. On parse success, merge by copying values from temp store into the destination document store.
5. Delete temp root/store.

### Tests

- [ ] Existing parse tests pass.
- [ ] Replace parse failure leaves document empty.
- [ ] Merge parse failure leaves document unchanged.
- [ ] Merge success copies values into the destination document and does not retain temp references.

### Verification

```bash
beefbuild -test
./test-toml.sh
```

---

## Phase 4 - Refactor merge, clone, insert, and replace semantics

**Goal:** All mutation and copy paths respect document-owned storage.

### Tasks

- [ ] Change `TomlValue.Clone()` to `CloneInto(TomlDocumentStore store)` internally.
- [ ] Add public `CloneInto(TomlDocument targetDocument)` or equivalent.
- [ ] Update `TomlTable.Clone()` and `TomlArray.Clone()` to require a target owner/store.
- [ ] Update `TomlTable.MergeFrom(...)` to copy incoming values into the destination store.
- [x] Decide public `Insert` semantics: public APIs should not accept `TomlValue`.
- [ ] Rename/restrict generic mutation APIs that accept `TomlValue` to internal parser/resolver APIs, for example `InsertValue`, `AddValue`, and `ReplaceValue`.
- [ ] Implement typed public `Set*` / `Add*` APIs that allocate/copy heap-backed payloads through the owning store.
- [ ] Update internal `ReplaceValue` so replacement values become store-owned by the table's owner.
- [ ] Decide what to do with old payloads on replace/remove.
  - Recommended: leave old payloads in the store until clear.

### Tests

- [ ] Insert/replace string values without caller-owned `new String` usage.
- [ ] Replace a table value and verify old table does not double-free.
- [ ] Remove a key and parse/write document afterward.
- [ ] Merge from a temp document, delete temp document, verify destination remains valid.
- [ ] Clone value into another document, delete source document, verify clone remains valid.

### Verification

```bash
beefbuild -test
./test-toml.sh
```

---

## Phase 5 - Update public construction APIs and examples

**Goal:** External users should not need to allocate `String`, `TomlTable`, or `TomlArray` manually for normal use.

### Tasks

- [ ] Add typed document-level setters for common path-based writes.
- [ ] Add typed table-level setters.
- [ ] Add typed array appenders.
- [ ] Add table/array child creation APIs that allocate through the owning store.
- [ ] Restrict/deprecate public mutation APIs that accept `TomlValue` directly.
- [ ] Update README programmatic construction examples.
- [ ] Update API docs to state:
  - `TomlValue` is non-owning.
  - document owns payload lifetimes.
  - values are valid while the document is alive and not cleared.
  - use copy/clone APIs for independent ownership.
- [ ] Mark direct heap-payload enum construction examples as discouraged or remove them.

### Acceptance criteria

- [ ] A user can build a document without writing `new String`, `new TomlTable`, or `new TomlArray` directly.
- [ ] A user can build a document without constructing `TomlValue` directly.
- [ ] Examples show no manual payload disposal.
- [ ] Any remaining `TomlValue`-accepting mutation APIs are internal or explicitly unsafe/advanced.

### Verification

```bash
beefbuild -test
```

---

## Phase 6 - Retire or restrict `TomlValue.Dispose()`

**Goal:** Eliminate the accidental-dispose footgun.

### Tasks

- [ ] Remove all production calls to `TomlValue.Dispose()`.
- [ ] Decide final API:
  - remove `Dispose()` entirely, or
  - make it `internal`, or
  - keep it as a documented no-op for source compatibility.
- [ ] Update comments and README to remove instructions requiring external users to dispose `TomlValue` payloads.
- [ ] Remove obsolete `DeleteDictionaryAndKeysAndDisposeValues!` usage if no longer needed.
- [ ] Remove or rename ownership-hazard wording that no longer applies.

### Acceptance criteria

- [ ] Calling old shallow accessors cannot free document payloads via `TomlValue.Dispose()`.
- [ ] No internal logic relies on `TomlValue.Dispose()` for correctness.
- [ ] No leaks in ordinary parse/clear/delete lifecycles.

### Verification

```bash
beefbuild -test
./test-toml.sh
```

---

## Phase 7 - Eradicate no-store and standalone ownership paths

**Goal:** Remove all remaining legacy heap-owned `TomlValue` payload paths before 1.0. Parser-produced values must always be store-owned and `TomlValue` must never represent ownership.

### Non-negotiable invariants

1. `TomlParserImpl.ParseValue()` never returns heap-owned `String`, `TomlTable`, or `TomlArray` payloads.
2. Parser and resolver construction always has a `TomlDocumentStore`.
3. Merge parses into a temporary `TomlDocumentStore`, then copies into the destination store.
4. Public document construction goes through `TomlDocument`, `TomlTable`, and `TomlArray` typed/factory APIs, not direct heap ownership.
5. `TomlValue.Dispose()`, `TomlValue.FreeStandalone()`, and heap-owned `TomlValue.Clone()` do not remain as compatibility paths.

### Tasks

- [ ] Make `TomlParserImpl` require a non-null `TomlDocumentStore` at construction or parse setup.
- [ ] Remove parser fallback allocations:
  - `new TomlArray(...)` fallback in `ParseArray()`
  - `new TomlTable(...)` fallback in `ParseInlineTable()`
  - `new TomlTable(...)` fallback in `InsertDottedKeyIntoTable()`
  - no-store branch in `FinishStringValue()`
- [ ] Remove parser error cleanup branches that test `mStore == null`.
- [ ] Make `TomlPathResolver` require a non-null `TomlDocumentStore` and remove no-store constructors/fallback allocations.
- [ ] Refactor merge paths to use a temporary `TomlDocumentStore`:
  - `ReadMergeFromStreamCursor`
  - non-stream merge path in `ReadWithCursor`
- [ ] Remove standalone ownership helpers:
  - `TomlValue.FreeStandalone`
  - table/array `FreeValue` helpers
  - conditional `mStore == null` ownership cleanup branches
- [ ] Remove or internalize public direct constructors that create standalone owning containers:
  - `TomlTable(TomlTableOrigin)`
  - `TomlArray()`
  - `TomlArray(int capacity)`
- [ ] Remove or internalize public `TomlValue`-accepting mutation APIs:
  - `TomlTable.Insert(StringView, TomlValue)`
  - `TomlTable.ReplaceValue(StringView, TomlValue)`
  - `TomlArray.Add(TomlValue)`
  - `TomlArray.this[int] set`
- [ ] Remove heap-owned clone APIs or make them internal-only if still needed for implementation:
  - `TomlValue.Clone()`
  - `TomlValueView.Clone()` - removed
  - `TomlTable.Clone()` - removed
  - `TomlArray.Clone()` - removed
- [x] Remove `TomlValue.Dispose()` entirely.
- [ ] Update README to remove standalone table/array and heap-owned clone guidance.
- [ ] Update tests to use document-owned construction APIs exclusively.

### Acceptance criteria

- [ ] `rg "mStore == null|mStore != null" src/TomlBeef` finds no ownership-mode branches.
- [ ] `rg "new TomlTable|new TomlArray" src/TomlBeef` finds only store internals or tests intentionally checking constructor visibility.
- [ ] `rg "FreeStandalone|Dispose\(\)|DeleteDictionaryAndKeysAndDisposeValues" src/TomlBeef` finds no `TomlValue` payload cleanup path.
- [ ] Parser, resolver, merge, and public construction all allocate heap-backed TOML payloads through `TomlDocumentStore`.
- [ ] Public examples build documents without `TomlValue`, `new String`, `new TomlTable`, or `new TomlArray`.

### Verification

```bash
beefbuild -test
beefbuild
./test-toml.sh
./test-roundtrip.sh
```

---

## Phase 8 - Remove `TomlValueView` APIs (completed)

**Goal:** Remove view wrappers since `TomlValue` is now non-owning and `Dispose()` is gone.

### Decision

Option 2: views removed. `TomlValue` is the single read type. Typed getters (`TryGetString`, `TryGetInteger`, etc.) and table/array iteration APIs (`GetKeyAt`, `GetValueAt`) provide all the safety that views did.

### Status

- `TomlValueView`, `TomlTableView`, `TomlArrayView` - deleted.
- `GetView(path)`, `GetViewPath(...)`, `GetView(key)` - deleted from all types.
- `GetValueViewAt(index)`, `TryGetValueViewAt(...)` - deleted from `TomlTable`.
- `GetView(index)`, `TryGetView(...)` - deleted from `TomlArray`.
- Tests removed. README updated.

### Rationale

Views existed to prevent callers from calling `Dispose()` on borrowed values. With `Dispose()` removed from `TomlValue`, the primary safety reason disappeared. Keeping three parallel wrapper types would add API surface area without corresponding safety gain.

---

## Phase 9 - Full validation and cleanup

**Goal:** Prove the ownership refactor did not regress parser/writer behavior.

### Required verification

```bash
beefbuild -test
beefbuild
./test-toml.sh
./test-roundtrip.sh
```

Roundtrip mismatches that pre-existed this refactor are not blockers unless new crashes or parse failures appear.

### Additional manual checks

- [ ] Parse a document, capture values, remove/replace keys, verify no crash before clear.
- [ ] Parse a document, clone values into another document, delete the source, verify destination works.
- [ ] Repeated parse/clear cycles.
- [ ] Repeated merge cycles.
- [ ] Preserve-style parse/write after mutations.

---

## Phase 10 - Ergonomic safe array mutation API

**Goal:** Replace public raw-`TomlValue` array slot mutation with normal-feeling array syntax that still preserves the document-owned storage model. Users should not have to write Java-flavored sludge like `arr.SetString(0, ...)` or `arr.At(0).SetString(...)`, and they must not be able to smuggle heap-owned payloads into a document via `TomlValue` assignment.

### Design conclusion from language probes

The following was tested in a scratch Beef project:

1. A get-only `ref T` indexer allows assignment through the returned mutable reference.
2. A get-only `readonly ref T` indexer rejects assignment with `Property has no setter`.
3. `operator=` cannot be overloaded in Beef.
4. A `readonly ref` struct return plus implicit conversions does **not** make `arr[index] = value` work.
5. A property/indexer with a setter and a safe wrapper type can support assignment syntax through implicit conversions.

So `readonly ref TomlValue this[int]` is useful only for advanced/read-only access. It is not the mutation story. Do not keep poking it like the answer will fall out if annoyed hard enough.

### Target public API shape

Scalar append should prefer overloads where Beef conversion rules make this practical:

```bf
arr.Add("hello");
arr.Add(123);
arr.Add(1.5);
arr.Add(true);
arr.Add(TomlLocalDate(2025, 1, 1));
```

Scalar replacement should use assignment syntax:

```bf
arr[0] = "changed";
arr[1] = 456;
arr[2] = false;
arr[3] = TomlLocalDate(2025, 1, 1);
```

Container creation/replacement should still use factory-style APIs because the owning store must create the table/array:

```bf
TomlTable tbl = arr.SetTable(4);
tbl.SetString("name", "replacement");

TomlArray nested = arr.SetArray(5);
nested.Add(1);
nested.Add(2);
```

Deletion should use ordinary collection semantics:

```bf
arr.RemoveAt(2);
arr.Clear();
```

Optional later APIs:

```bf
arr.RemoveRange(2, 3);
arr.Pop(); // only if semantics are clear; avoid returning raw removed TomlValue publicly
```

### Proposed implementation

Add a public safe input/slot wrapper type, name TBD:

- `TomlArrayItem`
- `TomlArraySlot`
- `TomlInputValue`

Preferred direction if Beef permits the desired ergonomics:

```bf
public TomlArrayItem this[int index]
{
    get => TomlArrayItem(this, index);
    set => SetItem(index, value);
}
```

`TomlArrayItem` should be a small value type that either:

1. Represents an assignment input value, or
2. Represents a read handle for a specific array/index.

If combining read-handle and assignment-input roles becomes ugly, split them cleanly:

```bf
public TomlArrayItem this[int index]
{
    get => TomlArrayItem(this, index);
    set => SetItem(index, value);
}

view APIs were removed (Phase 8). Use typed accessors directly on TomlValue.

```bf
public bool TryGetString(int index, out StringView value);
```

The wrapper must provide implicit conversions from safe public scalar types only:

- `StringView` / string literal-compatible input
- `String` as borrowed string data, copied into the store
- `int64` / practical integer overloads if needed for literals
- `double` / `float` if needed
- `bool`
- `TomlOffsetDateTime`
- `TomlLocalDateTime`
- `TomlLocalDate`
- `TomlLocalTime`

The wrapper must **not** provide implicit conversion from raw `TomlValue`, `TomlTable`, or `TomlArray`. That would reopen the exact ownership hole this phase exists to close. Please do not put a welcome mat in front of the foot-gun.

Internal array methods should remain raw-value based and store-aware:

```bf
internal TomlValue GetValue(int index);
internal void SetValue(int index, TomlValue value);
internal void AddValue(TomlValue value);
```

Public methods route through safe wrapper conversion and allocate heap-backed data through `mStore`.

### Required public read APIs

If the public indexer no longer returns raw `TomlValue`, arrays need convenient typed readers:

```bf
public bool TryGetString(int index, out StringView value);
public bool TryGetInteger(int index, out int64 value);
public bool TryGetFloat(int index, out double value);
public bool TryGetBool(int index, out bool value);
public bool TryGetOffsetDateTime(int index, out TomlOffsetDateTime value);
public bool TryGetLocalDateTime(int index, out TomlLocalDateTime value);
public bool TryGetLocalDate(int index, out TomlLocalDate value);
public bool TryGetLocalTime(int index, out TomlLocalTime value);
public bool TryGetTable(int index, out TomlTable value);
public bool TryGetArray(int index, out TomlArray value);
```

`GetView(int)` / `TryGetView(int, out TomlValueView)` were removed in Phase 8. Use the indexer and typed accessors instead.

Optional advanced API, if explicitly wanted:

```bf
public readonly ref TomlValue GetValueRef(int index);
```

Document it as borrowed and invalid after array/document mutation. Do not use this as the main mutation API. `readonly ref` is a read tool, not a miracle assignment goblin.

### Metadata and lifetime rules

Array mutation must:

- Mark the replaced item dirty for scalar replacement.
- Mark children dirty for insertion/removal.
- Bind metadata contexts for newly-created table/array values.
- Update array item node IDs on `RemoveAt` / `RemoveRange` so metadata does not point at the wrong element.
- Never `delete` removed/replaced payloads. The document store owns them until clear/destruction.

### Tasks

- [x] Implement `TomlArraySlot` safe wrapper with implicit conversions.
- [x] Add safe implicit conversions for scalar input types.
- [x] Replace public `TomlArray.this[int]` raw `TomlValue` setter with safe wrapper assignment.
- [ ] Keep or add public generic read view APIs. (Deferred — typed TryGet* methods exist; `TomlValueView` was removed in Phase 8.)
- [x] Add typed `TryGetXxx(index, out value)` array readers.
- [x] Add overload-based `Add(...)` APIs if Beef resolves literals cleanly; otherwise keep explicit `AddString` etc. as fallback but document the nicer overloads first.
- [x] Add `SetTable(index)` and `SetArray(index)` for store-created container replacement.
- [x] Add `RemoveAt(index)` and `Clear()` for array deletion.
- [x] Update tests to cover assignment syntax, container replacement, deletion, and metadata dirty tracking.
- [x] Update README to show idiomatic array construction/mutation without raw `TomlValue`.

### Acceptance criteria

- [x] Library users can build arrays without `TomlValue`, `new String`, `new TomlArray`, or `new TomlTable`.
- [x] Library users can replace scalar array elements with `arr[index] = value`.
- [x] Public API does not allow `arr[index] = TomlValue.String(new String(...))`.
- [x] Public API does not allow direct assignment of caller-created `TomlTable` / `TomlArray` into a document-owned array.
- [x] Container replacement goes through store-backed factories.
- [x] Array deletion removes elements logically without freeing store-owned payloads.
- [x] Preserve-style scalar replacement and container replacement marks dirty and remains writable.
- [x] Preserve-style RemoveAt and Clear properly shift/remove metadata item node IDs.

### Verification

```bash
beefbuild -test
./test-toml.sh
./test-roundtrip.sh
```

`test-roundtrip.sh` reports 261 pass and 5 known JSON-order mismatches. The script now exits 0 (the 5 mismatches are accepted as a baseline).

---

## Phase 11 - Ergonomic safe table entry iteration and mutation API

**Goal:** Replace public table iteration that exposes separate key/value plumbing and raw `TomlValue` with a coherent table-entry proxy. Users should be able to iterate table entries, inspect typed values, assign safe scalar values, replace values with store-backed containers, rename keys, and remove entries without touching `TomlValue`, `Entries`, `KeyOrder`, or manual heap-backed payloads.

The current README-style pattern is not the desired final API:

```bf
for (int i = 0; i < table.Count; i++)
{
    StringView key = table.GetKeyAt(i);
    TomlValue value = table.GetValueAt(i);
    // ...
}
```

That is backing-store plumbing, not a humane public API. It splits key and value access, leaks raw `TomlValue`, and makes coherence the caller's problem.

### Target public API shape

Table iteration should use an indexer that returns a key/value entry proxy:

```bf
for (int i = 0; i < table.Count; i++)
{
    var entry = table[i];

    Console.WriteLine(entry.Key);

    if (entry.TryGetString(var s))
        Console.WriteLine(s);
    else if (entry.TryGetInteger(var n))
        Console.WriteLine($"{}", n);
}
```

Scalar replacement should feel like normal assignment while still using store-backed allocation for strings:

```bf
var entry = table[0];
entry.Value = "new string";
entry.Value = 123;
entry.Value = false;
entry.Value = TomlLocalDate(2025, 1, 1);
```

Container replacement must go through factory methods because the owning store must create the table/array:

```bf
TomlTable child = table[0].SetTable();
child.SetString("name", "replacement");

TomlArray arr = table[1].SetArray();
arr.Add("a");
arr.Add("b");
```

Key rename is fallible because duplicate keys are possible, so do **not** make it a plain `Key` setter:

```bf
if (table[0].Rename("new_key") case .Err(let e))
{
    defer e.Dispose();
    // duplicate key / invalid rename / etc.
}
```

Deletion should be entry-local:

```bf
table[0].Remove();
```

### Proposed types

Add a public value-type entry proxy:

```bf
public struct TomlTableEntry
{
    TomlTable mTable;
    int mIndex;

    public StringView Key { get; }

    public TomlInputValue Value
    {
        set; // StringView/int64/double/bool/date-time via implicit conversion
    }

    public bool TryGetString(out StringView value);
    public bool TryGetInteger(out int64 value);
    public bool TryGetFloat(out double value);
    public bool TryGetBool(out bool value);
    public bool TryGetOffsetDateTime(out TomlOffsetDateTime value);
    public bool TryGetLocalDateTime(out TomlLocalDateTime value);
    public bool TryGetLocalDate(out TomlLocalDate value);
    public bool TryGetLocalTime(out TomlLocalTime value);
    public bool TryGetTable(out TomlTable value);
    public bool TryGetArray(out TomlArray value);

    public TomlTable SetTable();
    public TomlArray SetArray();
    public Result<void, TomlParseError> Rename(StringView newKey);
    public bool Remove();
}
```

Add an indexer on `TomlTable`:

```bf
public TomlTableEntry this[int index]
{
    get => TomlTableEntry(this, index);
}
```

The safe scalar input wrapper should probably be shared between array and table APIs. Rename or generalize `TomlArraySlot` into something like:

- `TomlInputValue`
- `TomlScalarValue`
- `TomlValueInput`

The wrapper must continue to forbid implicit conversion from raw `TomlValue`, `TomlTable`, or `TomlArray`.

### Internal table helpers needed

The entry proxy should call internal `TomlTable` helpers rather than poking at fields directly:

```bf
internal TomlValue GetValueAtInternal(int index);
internal void SetValueAtInternal(int index, TomlInputValue value);
internal TomlTable SetTableAtInternal(int index);
internal TomlArray SetArrayAtInternal(int index);
internal Result<void, TomlParseError> RenameAtInternal(int index, StringView newKey);
internal bool RemoveAtInternal(int index);
```

Names are flexible. The point is that all key-order, dictionary, metadata, and dirty-tracking rules stay centralized in `TomlTable`.

### Metadata and lifetime rules

Table entry mutation must:

- Allocate replacement strings through the owning `TomlDocumentStore`.
- Never accept caller-owned `TomlValue`, `TomlTable`, or `TomlArray` as direct public assignment inputs.
- Mark value dirty on scalar/container replacement.
- Bind metadata contexts for newly-created table/array replacement values.
- Mark children dirty on removal.
- On rename, update:
  - dictionary key storage,
  - insertion-order key list,
  - metadata entry node-ID mapping,
  - key dirty/key-format state so preserve-style output does not reuse the old key token incorrectly.
- Never `delete` removed/replaced payloads; the document store owns them until clear/destruction.

### Public API cleanup

Once the entry proxy exists, decide what happens to the raw/scaffolding table APIs:

- `GetKeyAt(int)` may remain as a lightweight convenience.
- `GetValueAt(int)` should become internal or be clearly documented as advanced borrowed raw access.
- `TryGetValue(StringView, out TomlValue)` should become internal or advanced borrowed raw access.
- `table[StringView key] -> Result<TomlValue>` should be reconsidered for the same reason.
- README should stop presenting raw `TomlValue` table iteration as the normal path.

### Tasks

- [x] Add shared scalar input wrapper or rename `TomlArraySlot` to a table/array-neutral type (`TomlInputValue`).
- [x] Update `TomlArray` to use the shared wrapper without regressing Phase 10 assignment syntax.
- [x] Add `TomlTableEntry` proxy type.
- [x] Add `TomlTable.this[int index] -> TomlTableEntry`.
- [x] Add typed entry readers (`TryGetString`, `TryGetInteger`, etc.).
- [x] Add entry scalar assignment via safe input wrapper.
- [x] Add `SetTable()` and `SetArray()` on entries for store-backed container replacement.
- [x] Add `Rename(newKey)` with duplicate-key detection and metadata/key-order updates.
- [x] Add `Remove()` on entries and route it through table metadata cleanup.
- [x] Internalize or clearly mark raw `TomlValue` table read APIs as advanced borrowed access.
- [x] Update README table iteration examples to use entry proxy iteration.
- [x] Add tests for typed entry reads, scalar replacement, container replacement, rename, duplicate rename rejection, removal, and preserve-style dirty tracking.

### Acceptance criteria

- [x] Users can iterate table entries without calling `GetKeyAt()` + `GetValueAt()` as the primary documented path.
- [x] Users can inspect table entry values through typed `TryGet*` methods without touching raw `TomlValue`.
- [x] Users can assign scalar entry values with normal-feeling syntax.
- [x] Public API does not allow direct assignment of caller-created `TomlValue`, `TomlTable`, or `TomlArray` into a document-owned table entry.
- [x] Container replacement goes through store-backed entry factories.
- [x] Entry rename updates dictionary, key order, and metadata correctly.
- [x] Entry removal updates table contents and metadata correctly without freeing store-owned payloads.
- [x] README no longer advertises raw `TomlValue` table iteration as the normal API.

### Verification

```bash
beefbuild -test
./test-toml.sh
./test-roundtrip.sh
```

---

## Important implementation notes

### Parser error paths

Once tables/arrays are store-owned, do **not** manually `delete arr` or `delete tbl` on parser errors. The store owns them and will release them on parse failure cleanup.

Temporary strings that are not adopted into the store still need cleanup.

### Remove/replace tombstones

If removed/replaced payloads remain in the store until `Clear()`, memory usage can grow during heavy mutation. This is acceptable for the first version and should be documented.

Future optional improvement: compact/rebuild document storage.

### Metadata contexts

`TomlTable` and `TomlArray` should continue owning their metadata contexts. Store-level deletion of tables/arrays will trigger their destructors and delete metadata contexts.

### Cross-document values

Decide and document behavior for inserting a value from one document into another.

Recommended behavior:

- Typed setters always allocate in the destination document.
- Generic value insertion should copy into the destination document or be marked advanced/internal.

### Standalone tables/arrays

Current public constructors allow standalone `TomlTable` / `TomlArray`. The document-owned model works best if normal construction goes through `TomlDocument`.

Migration strategy:

1. Keep constructors temporarily if needed for compatibility.
2. Add document factory APIs.
3. Update docs/tests to use factories.
4. Later decide whether standalone containers remain supported.

---

## Success criteria for the whole refactor

- [ ] `TomlValue` no longer owns referenced heap objects.
- [ ] `TomlValue.Dispose()` is removed, internal, or harmless.
- [ ] `TomlDocument` is the clear owner of strings/tables/arrays.
- [ ] External users can build documents without manually owning `String`, `TomlTable`, or `TomlArray` references.
- [ ] Cross-document copying is explicit and safe.
- [ ] Existing parser and writer acceptance tests pass.
- [ ] Inline-table recursive sealing remains fixed.
- [ ] Public docs explain the new lifetime model clearly.
