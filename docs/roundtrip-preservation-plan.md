# PreserveStyle Metadata Plan

## Core objective

TomlBeef should keep the core parser lean by default, while optionally supporting a style-preserving parse mode.

The goal is **not** full source round-tripping.

The goal is:

```text
Parse TOML into the normal semantic model,
optionally retain comments and useful presentation metadata,
then serialize with similar human-authored style.
```

This means preserving things like:

```text
comments
string style
raw string spelling for unchanged strings
numeric base/grouping/casing
dotted key style
inline vs multiline containers
date/time presentation
```

But not preserving:

```text
every whitespace token
exact blank-line layout
exact spaces around =
full token tree
full CST
byte-for-byte identity
minimal source diff
```

The design target is:

```text
style-preserving serialization
```

not:

```text
lossless source preservation
```

---

## Public metadata mode

The public API should stay simple.

Use two modes:

```bf
public enum TomlMetadataMode : uint8
{
    None,
    PreserveStyle
}
```

### `None`

Normal parse mode.

```text
No extra style metadata.
No comment preservation.
No original-token copies.
Fastest and lowest memory path.
```

### `PreserveStyle`

Optional mode.

```text
Capture comments, selected original value tokens, and broad formatting metadata
during parsing so serialization can preserve human-facing style.
```

Important promise:

```text
PreserveStyle does not guarantee byte-for-byte output.
```

Suggested documentation:

```text
PreserveStyle retains comments and presentation metadata such as dotted-key usage,
string style, numeric style, date-time style, and container layout. It does not
attempt lossless source round-tripping or arbitrary whitespace preservation.
```

---

## Existing parser error pipeline remains unchanged

TomlBeef already has a core parser error type:

```bf
public struct TomlParseError
{
    public TomlErrorKind mKind;
    public String mMessage;
    public int mLine;
    public int mColumn;
    public int mOffset;
    public int mLength;
}
```

This should remain the standard parser failure path.

Do **not** add labels, notes, multi-span diagnostics, or metadata-heavy structures into the normal parse error pipeline right now.

The current division should be:

```text
Invalid TOML:
  parser returns TomlParseError

Valid TOML but wrong for user type/schema:
  future binder/validator may produce richer user-facing errors
```

The metadata system should be general-purpose and should not be named around diagnostics.

Avoid mode names like:

```text
Diagnostics
```

because validation/type errors are only one possible consumer of the metadata.

---

## Metadata should be a sidecar, not embedded into every value

By default, the semantic TOML model should remain lightweight.

In `PreserveStyle` mode, attach optional document metadata to the existing `TomlDocument` class:

```bf
public class TomlDocument
{
    private TomlTable mRootTable ~ delete _;
    private TomlDocumentMetadata mMetadata ~ delete _;
}
```

`mMetadata` should remain `null` in normal mode. `TomlDocument` is currently a class, not a struct, and `mRootTable` is already private with a `RootTable` read-only property.

The important idea:

```text
semantic model:
  stores TOML values

metadata sidecar:
  stores comments, style metadata, owned original tokens, dirty state
```

This avoids forcing all users to pay memory overhead for style preservation.

Recommended public-ish name:

```text
TomlDocumentMetadata
```

Avoid exposing it as:

```text
TomlMetadataCache
```

unless it is purely internal, because "cache" sounds disposable/implementation-only while this metadata has semantic value for serialization.

---

## Document-level style metadata

`TomlDocumentStyle` stores broad fallback style choices for newly generated content. TOML has no document-level style directives; these values are inferred while parsing and used only when a node has no more-specific style metadata.

Suggested shape:

```bf
public enum TomlNewlineStyle : uint8
{
    LF,
    CRLF
}

public struct TomlDocumentStyle
{
    public TomlNewlineStyle mNewlineStyle;
    public uint8 mIndentSize;
    public bool mUseTabs;
    public TomlStringStyle mDefaultStringStyle;
    public TomlContainerStyle mDefaultArrayStyle;
    public bool mPreferDottedKeys;
}
```

`TomlStringStyle` and `TomlContainerStyle` are defined in later sections; they are referenced here only as document-level defaults.

Initial implementation can keep this minimal:

```text
newline style
indent style
fallback string/container preferences for new values
root/file header comments are comment metadata attached to the root node, not fields on TomlDocumentStyle
```

---

## Critical input lifetime constraint

This is a major design constraint.

TomlBeef input may come from:

```text
stream
StringView
Span<uint8>
```

and that source data may be freed or unavailable after parsing.

Therefore:

```text
Persistent metadata cannot rely on source spans pointing into the original input.
```

A span like:

```bf
TomlSourceSpan { offset, length }
```

is useful as a location coordinate, but it is **not** enough to preserve raw tokens after parsing unless the full original source is retained.

Since TomlBeef does not retain the full source buffer, the revised rule is:

```text
Anything needed after parse must be copied into owned metadata during parse.
```

This includes:

```text
raw string tokens
raw numeric tokens, if exact reuse is desired
comment text
possibly raw key-part spellings, if exact key style preservation is desired
```

Spans/ranges may still be retained for:

```text
line/column location
future binder/type errors
debugging
source coordinates
```

But not for recovering source text.

---

## Owned token storage replaces persistent spans

Instead of storing only:

```bf
public TomlSourceSpan mOriginalValueSpan;
```

store a reference to an owned token copy:

```bf
public struct TomlOriginalTokenRef
{
    public int mIndex;

    public this(int index)
    {
        mIndex = index;
    }

    public bool IsValid
    {
        get { return mIndex >= 0; }
    }

    public static TomlOriginalTokenRef Invalid
    {
        get { return .(-1); }
    }
}
```

Conceptually, metadata owns copied token text and sparse style pools (the full skeleton later includes Beef field destructors and an explicit constructor):

```bf
public struct TomlStyleRef
{
    public int mIndex;

    public this(int index)
    {
        mIndex = index;
    }

    public bool IsValid => mIndex >= 0;

    public static TomlStyleRef Invalid
    {
        get { return .(-1); }
    }
}

public class TomlDocumentMetadata
{
    public TomlMetadataMode mMode;
    public TomlDocumentStyle mDocumentStyle;

    public List<TomlNodeStyle> mNodeStyles;
    public List<TomlCommentSet> mComments;

    // Owns raw token text captured during parsing.
    public List<String> mOriginalTokens;

    // Sparse style pools referenced by TomlNodeStyle.
    public List<TomlKeyFormat> mKeyFormats;
    public List<TomlValueFormat> mValueFormats;
}
```

Node style references the copied token and sparse style pools:

```bf
public struct TomlNodeStyle
{
    public TomlNodeId mNodeId;

    // Coordinate for diagnostics/debugging. Does NOT recover source text.
    public TomlSourceRange mRange;

    // Index into mOriginalTokens for value reuse. Invalid if not captured.
    public TomlOriginalTokenRef mOriginalValueToken;

    public TomlDirtyFlags mDirtyFlags;

    // Invalid means default/inferred style.
    public TomlStyleRef mKeyFormatRef;
    public TomlStyleRef mValueFormatRef;
}
```

This keeps `TomlNodeStyle` compact. Most nodes should use invalid style refs and avoid storing key/value format payloads inline.

Serialization becomes:

```bf
if (style.mDirtyFlags == .None && style.mOriginalValueToken.IsValid)
{
    let token = metadata.mOriginalTokens[style.mOriginalValueToken.mIndex];
    writer.Write(token);
}
else
{
    let valueFormat = metadata.GetValueFormat(style.mValueFormatRef);
    WriteFormattedValue(value, valueFormat);
}
```

---

## Copy only useful source fragments

Because `PreserveStyle` is not full round-tripping, do not copy the whole source and do not copy every trivia token.

Only copy fragments needed after parse.

Strong candidates to copy:

```text
string value tokens
comments
non-default numeric tokens
date/time tokens if exact spelling is useful
raw key-part text if quoted key escaping needs preservation
maybe inline container tokens later, but not initially
```

Weak candidates:

```text
booleans
plain decimal integers like 42
standard generated floats
standard date/time if broad metadata is enough
punctuation
spaces
newlines
=
commas
table brackets
```

Chosen initial policy:

```text
Always copy string tokens.
Always copy comment text.
Copy numeric tokens only when they contain meaningful style:
  non-decimal base
  underscores
  uppercase hex digits
  special float spelling
  exponent style
Optionally copy date/time tokens if preserving exact timestamp spelling matters.
Do not copy booleans.
```

Booleans require no format metadata because TOML spelling is canonical: `true` or `false`.

Alternative retained for reference:

```text
Copy every scalar value token in PreserveStyle mode.
```

This is easier and more preserving, but costs more memory. It is not the chosen initial policy unless implementation simplicity outweighs memory concerns for the first prototype.

---

## Stable node identity is required

The metadata sidecar needs stable IDs.

Do not key metadata by object address unless objects are guaranteed not to move or be cloned.

Use something like:

```bf
public struct TomlNodeId
{
    public int mIndex;
}
```

Every style-preserved semantic slot should have a node ID:

```text
table entry value
array element
inline table field
scalar value
container value
```

The metadata maps:

```text
NodeId -> TomlNodeStyle
NodeId -> comments
NodeId -> dirty flags
NodeId -> original token reference
```

This is especially important for arrays.

Current-code implications:

```text
TomlValue is currently a value enum with no identity.
TomlTable stores Dictionary<String, TomlValue> plus mKeyOrder.
TomlArray stores List<TomlValue>.
```

Therefore a preserve-style implementation should add identity beside slots, not inside copied `TomlValue` instances. Practical options:

```text
TomlTable: optional key -> NodeId side map, allocated only in PreserveStyle mode
TomlArray: optional parallel List<TomlNodeId>, allocated only in PreserveStyle mode
TomlTable/TomlArray themselves: NodeId for the container node
```

Avoid adding a node ID to every `TomlValue` if that would bloat normal mode.

Example:

```toml
arr = [
  """a\n""",
  """b\n""",
]
```

If only the second element changes, the first element's raw token should remain reusable.

So internally:

```text
Array NodeId
  element NodeId
  element NodeId
```

not just:

```text
Array of primitive values with no identity
```

---

## Style follows the slot/path, not the value object

Style should normally belong to the document slot/path, not the value object.

Example:

```toml
a = """weird\n"""
b = "normal"
```

If the user swaps values, there are two possible policies:

```text
style follows value
style follows slot/path
```

For config editing, choose:

```text
style follows slot/path
```

Meaning:

```text
a keeps the style originally associated with key a
b keeps the style originally associated with key b
```

The original raw token for `a` is only reusable if the semantic value at `a` is unchanged.

This prevents surprising style migration.

Chosen resolution: containers carry one optional metadata context pointer.

`TomlTable` and `TomlArray` should remain the normal mutation surface, but each container gets a single nullable internal metadata-context field:

```bf
class TomlTable
{
    private TomlContainerMetadataContext mMetadataContext ~ delete _; // nullable; null in normal mode
}

class TomlArray
{
    private TomlContainerMetadataContext mMetadataContext ~ delete _; // nullable; null in normal mode
}

class TomlContainerMetadataContext
{
    public TomlDocumentMetadata mMetadata; // borrowed document-owned sidecar
    public TomlNodeId mNodeId;

    // Exactly one is populated, depending on container kind.
    public Dictionary<String, TomlNodeId> mEntryNodeIds ~ DeleteDictionaryAndKeys!(_);
    public List<TomlNodeId> mItemNodeIds ~ delete _;

    public this(TomlDocumentMetadata metadata, TomlNodeId nodeId, bool isArray)
    {
        mMetadata = metadata;
        mNodeId = nodeId;
        if (isArray)
            mItemNodeIds = new List<TomlNodeId>();
        else
            mEntryNodeIds = new Dictionary<String, TomlNodeId>();
    }
}
```

This is a deliberate memory tradeoff: normal mode pays one null reference field per table/array container, but avoids per-entry metadata allocations, node-ID maps, token copies, and comment storage. If even that one field becomes unacceptable, the alternative is to route all style-preserving mutations through document-level APIs instead.

Lifetime invariant: `mMetadata` is borrowed from the owning `TomlDocument` and is valid only while the container remains document-owned. This matches the current API's ownership model: tables/arrays returned from a document are borrowed and must not outlive the document. `Clone()` and detached programmatic containers must clear metadata context unless they are explicitly rebound while being inserted into a style-preserving document.

Mutation rules:

```text
TomlTable.Insert(new key):
  allocate a node ID for the new slot
  bind metadata context to any container value being inserted
  mark parent table Children dirty

TomlTable.Insert/ReplaceValue(existing key):
  keep the existing slot node ID so style follows the key/slot
  replace the semantic value
  bind metadata context to any container value being inserted
  mark that slot Value dirty

TomlTable.Remove(key):
  remove the key's node-ID mapping
  mark parent table Children dirty
  tombstone/orphan the removed node metadata; do not reuse the ID

TomlTable.Clear():
  clear all key -> node-ID mappings
  mark parent table Children dirty
  tombstone/orphan all removed child node metadata

TomlArray.Add(value):
  allocate a node ID for the new element
  append it to mItemNodeIds
  bind metadata context to any container value being inserted
  mark array Children dirty

TomlArray[index] = value:
  keep the existing element node ID so style follows the array slot
  bind metadata context to any container value being inserted
  mark that element Value dirty
```

This keeps normal mode cheap because only the nullable context field exists; all heavyweight metadata structures are absent unless `PreserveStyle` is enabled.

Direct raw collection mutation must not remain part of the style-preserving API. Before shipping `PreserveStyle`, replace public `Entries` and `KeyOrder` exposure with safe read-only enumeration/accessor APIs used by the writer. If raw mutable access remains public, dirty tracking cannot be guaranteed.

---

## Semantic dirty tracking is mandatory

Raw token reuse is only correct if TomlBeef knows the semantic value has not changed.

Core invariant:

```text
A copied original token may only be reused when the current semantic value is
equivalent to the value parsed from that token.
```

Therefore every style-preserved node needs dirty state.

```bf
[AllowDuplicates]
public enum TomlDirtyFlags : uint8
{
    None = 0,
    Value = 1,
    Children = 2,
    Style = 4
}
```

### `Value`

The node's semantic scalar value changed.

```text
Do not reuse original token.
Regenerate from semantic value.
```

### `Children`

The container's membership changed.

```text
Container structure must be regenerated.
Clean child values may still reuse their own original tokens.
```

### `Style`

The user changed presentation metadata or comments.

```text
Regenerate using the current format metadata even if the semantic value is the same.
Do not reuse the original value token, because the requested presentation changed.
Comments may be emitted from updated comment metadata without changing the semantic value.
```

---

## Setter APIs should preserve clean state when value is equal

Dirty state should be semantic.

If the user assigns the same value, keep the node clean:

```bf
public void SetStringAt(TomlPath path, StringView newValue)
{
    let node = GetNode(path);
    let oldValue = node.AsString();

    if (oldValue == newValue)
        return; // keep clean; original token remains reusable

    node.SetStringPayload(newValue);
    metadata.MarkDirty(node.mId, .Value);
}
```

This allows:

```bf
doc["s"] = doc["s"].AsString();
```

to preserve the original token if the value is semantically unchanged.

But this should become dirty if the resulting string differs:

```bf
doc["s"] = NormalizeLineEndings(doc["s"].AsString());
```

---

## Serializer rule

For scalar values:

```text
if PreserveStyle enabled
and node is clean
and an owned original token exists:
    emit copied original token
else:
    emit generated value using format metadata
```

For containers:

```text
if container children changed:
    regenerate container structure using the container's current format metadata
    (TomlArrayFormat or TomlTableFormat)
    do not reuse any original whole-container token/delimiters
    allow clean child scalar tokens to be reused inside the regenerated structure
```

Examples:

```text
multiline array stays multiline if TomlArrayFormat.mStyle == Multiline
inline table stays inline if TomlTableFormat.mInline == true
table/dotted-key regeneration follows TomlTableFormat/TomlKeyFormat preferences
```

For example:

```toml
[server]
name = """weird\n"""
port = 8080
```

If the user adds:

```toml
host = "localhost"
```

then the table is structurally dirty, but existing values are clean.

Output can still preserve:

```toml
name = """weird\n"""
port = 8080
```

while adding a generated `host`.

---

## String preservation strategy

Strings are the strongest reason for owned original tokens.

TOML strings can encode the same semantic value many ways:

```toml
s = "a\nb"
s = """a
b"""
s = 'a\nb'
```

And multiline basic strings can mix escaped newlines and real newlines:

```toml
s = """a\n\n

\n\n Apples
b"""
```

This contains multiple presentation choices:

```text
multiline basic string
escaped newline sequences
actual blank lines
literal spaces
raw newlines
```

Trying to preserve this by modeling every string segment would require too much micro-state.

So the policy is:

```text
unchanged string:
  emit copied original token exactly

changed string:
  regenerate using broad string style metadata
```

Suggested style metadata:

```bf
public enum TomlStringStyle : uint8
{
    Basic,
    Literal,
    MultilineBasic,
    MultilineLiteral
}

public struct TomlStringFormat
{
    public TomlStringStyle mStyle;

    // Fallback hints for regeneration.
    public bool mStartsWithNewline;
    public bool mHadEscapes;
    public bool mPreferEscapedNewlines;
}
```

The actual raw token lives in `mOriginalTokens`.

Minimum viable string preservation:

```text
copy original string token
store string style enum
track dirty state
```

---

## Numeric style strategy

For numbers, broad format metadata may often be enough.

Integers:

```bf
public enum TomlIntegerBase : uint8
{
    Decimal,
    Binary,
    Octal,
    Hex
}

public struct TomlIntegerFormat
{
    public TomlIntegerBase mBase;
    public bool mUppercaseDigits;
    public bool mUseUnderscores;
    public uint8 mGroupSize;
    public uint8 mMinDigits;
}
```

Examples:

```toml
x = 1_000_000
y = 0xDEAD_BEEF
z = 0b1101_0010
```

If unchanged and original token is copied, emit the original token.

If changed, regenerate using metadata:

```toml
y = 0xBEEF_CAFE
```

Floats:

```bf
public enum TomlFloatStyle : uint8
{
    Decimal,
    Scientific,
    Special
}

public struct TomlFloatFormat
{
    public TomlFloatStyle mStyle;
    public bool mUppercaseExponent;
    public bool mExplicitPlusExponent;
    public int16 mPrecision; // -1 = default
    public bool mUseUnderscores;
}
```

Examples:

```toml
a = 1.0
b = 1e6
c = 1E+06
d = inf
e = nan
```

Initial choice:

```text
Do not necessarily copy every numeric token.
Store enough format metadata to regenerate close style.
Copy non-default numeric tokens if exact unchanged spelling is desired.
```

---

## Key style strategy

You want to preserve dotted syntax.

Example input:

```toml
server.port = 8080
server.host = "localhost"
```

should not automatically normalize into:

```toml
[server]
port = 8080
host = "localhost"
```

unless the serializer is explicitly configured to do so.

Useful metadata:

```bf
public enum TomlKeyStyle : uint8
{
    Bare,
    QuotedBasic,
    QuotedLiteral,
    Dotted
}

public struct TomlKeyFormat
{
    public TomlKeyStyle mStyle;
    public bool mPreferDottedPath;
}
```

For quoted dotted parts:

```toml
physical."color code" = "orange"
```

eventually support per-part metadata:

```bf
public struct TomlKeyPartFormat
{
    public TomlKeyStyle mStyle;

    // Optional owned token ref if exact key-part spelling matters.
    public TomlOriginalTokenRef mOriginalPartToken;
}
```

Key tokens may need copying if exact escaping of quoted key parts should survive after parse. If not, broad key style metadata is enough.

---

## Date/time style strategy

Date/time values have meaningful presentation choices:

```toml
dob = 1979-05-27T07:32:00Z
dob = 1979-05-27 07:32:00-08:00
```

Broad metadata:

```bf
public struct TomlDateTimeFormat
{
    public bool mHasSeconds;
    public uint8 mFractionalDigits;
    public bool mUsesUppercaseT;
    public bool mUsesZ;
    public bool mHasOffset;
}
```

If exact timestamp spelling matters, copy the original date/time token. Otherwise regenerate from metadata.

---

## Container style strategy

Preserve broad container layout.

Arrays:

```toml
features = ["a", "b", "c"]
```

versus:

```toml
features = [
  "a",
  "b",
  "c",
]
```

Metadata:

```bf
public enum TomlContainerStyle : uint8
{
    Inline,
    Multiline
}

public struct TomlArrayFormat
{
    public TomlContainerStyle mStyle;
    public bool mTrailingComma;
    public uint8 mIndentSize;
}
```

Inline tables:

```toml
server = { host = "localhost", port = 8080 }
```

versus:

```toml
[server]
host = "localhost"
port = 8080
```

Metadata:

```bf
public struct TomlTableFormat
{
    public bool mInline;
    public bool mPreferDottedKeys;
}
```

For containers, original token copying is optional and can be deferred.

Initial behavior can be:

```text
preserve broad layout style
regenerate container structure when changed
reuse clean scalar child tokens where possible
```

---

## Comment preservation

Comments must be copied during parse because the input is not retained.

Current-code note: comments are currently skipped inside cursor methods (`SkipComment`) and discarded before the parser sees their text. Preservation will require replacing or extending that path so the parser can capture comment text and placement. For the generic cursor design, this likely means a helper that marks the comment start, advances through the comment, slices/copies the text, then consumes the newline.

Do not store comment spans as the only data.

Use owned comment strings:

```bf
public enum TomlCommentPlacement : uint8
{
    Leading,
    Trailing,
    Detached
}

public class TomlComment
{
    public TomlCommentPlacement mPlacement;
    public String mText ~ delete _;

    public this(TomlCommentPlacement placement, StringView text)
    {
        mPlacement = placement;
        mText = new String(text);
    }
}
```

Or per-node:

```bf
public class TomlCommentSet
{
    public List<String> mLeading ~ ClearAndDeleteItems!(_);
    public String mTrailing ~ delete _;

    public this()
    {
        mLeading = new List<String>();
        mTrailing = null;
    }
}
```

Association policy:

```text
leading comments attach to the next key/table/array element
trailing comments attach to the same-line key/table/array element
file header comments attach to root/document
comments between entries attach to the following entry
```

Example:

```toml
# server port
port = 8080 # default port
```

Metadata:

```text
port.leading = ["server port"]
port.trailing = "default port"
```

Serializer:

```toml
# server port
port = 8080 # default port
```

Not preserved:

```text
exact comment indentation quirks
arbitrary blank line layout
all trivia
```

---

## Source locations are still useful

Even though source text is not retained, source coordinates can still be stored.

Possible structure:

```bf
public struct TomlSourceRange
{
    public int mLine;
    public int mColumn;
    public int mOffset;
    public int mLength;
}
```

These are useful for:

```text
future binder/type errors
debug output
editor navigation
mapping metadata back to source locations
```

But they cannot be used to recover raw token text.

So distinguish:

```text
source range:
  coordinate only

original token:
  owned copied text
```

---

## Functional equivalence invariant

The most important safety rule:

```text
serialize(parse(input, PreserveStyle)) should produce TOML that parses to the
same semantic document as the original input, unless the user mutated the
document.
```

For each node:

```text
clean node with original token:
  emit copied token
  safe because token was parsed into the current value

dirty node:
  regenerate from semantic value
  safe because serializer uses current value
```

Never reuse an original token if the semantic value has changed.

This is why dirty tracking is non-negotiable.

---

## Duplicate keys and representation conflicts

By TOML rules, the same key cannot be defined more than once, even if represented using different syntax.

Invalid:

```toml
name = "one"
name = "two"
```

Invalid:

```toml
a.b = 1

[a]
b = 2
```

But implicit parent tables can later be explicitly opened:

```toml
[a.b]
c = 1

[a]
d = 2
```

This matters because:

```text
style metadata should attach to concrete assignments/nodes
not assume an entire semantic table has exactly one source representation
```

Since ordering is not a core requirement, this mainly affects how table/key style should be recorded.

Metadata rule: the strict parser still rejects duplicates, so no duplicate representation metadata is retained for invalid TOML. For `Read(..., Merge)` with `MergeConflict.Overwrite`, the winning destination slot keeps its node ID but is marked `Value` dirty; incoming duplicate metadata is discarded unless a future lenient mode explicitly defines different behavior.

---

## Ordering is not a primary goal

Key ordering is not necessarily important.

Therefore:

```text
PreserveStyle does not need to promise original ordering.
```

However, some style information should still survive:

```text
dotted key usage
inline table style
array layout
string/numeric style
comments attached to entries
```

The current table representation is already ordered (`TomlTable.mKeyOrder`), so the semantic model does retain insertion order. However, the current writer emits in phases: scalar/static values first, sub-tables second, and array-of-tables last. That means output can still reorder relative to the original source even though each table has key order.

That is acceptable if documented, but metadata-aware serialization should consciously decide whether to keep the current phased writer or move toward a single-pass writer for better comment/order preservation.

Be careful with comments:

```text
comment association is semantic, so reordered output may move comments with nodes.
```

That is likely acceptable under the scoped design.

---

## Relationship to known parser designs

The chosen design is closest to:

```text
toml11-style annotated semantic model
```

Not:

```text
Taplo/Rowan full lossless CST
toml_edit/tomlkit full decorated document model
```

Why not a Taplo/Rowan-style CST: it preserves every token and trivia node, but costs substantially more memory and implementation complexity than TomlBeef needs for config editing.

Why not a toml_edit/tomlkit-style decorated document model: it requires making the mutable syntax/decorated tree the primary representation. That conflicts with TomlBeef's current semantic model, increases ownership complexity under Beef's manual memory model, and adds maintenance burden for full trivia fidelity that is outside the goal.

TomlBeef's chosen point on the spectrum:

```text
semantic values
+ optional sidecar style metadata
+ owned original tokens for values that need exact preservation
+ comments
+ dirty tracking
```

This is lighter than a full CST but stronger than plain parse/serialize.

---

## Metadata skeleton

This is a consolidated rough shape.

```bf
public enum TomlMetadataMode : uint8
{
    None,
    PreserveStyle
}
```

The existing read config should grow this field rather than introducing a separate parse-options type:

```bf
public struct TomlReadConfig
{
    public TomlReadMode Mode = .Replace;
    public MergeConflict OnConflict = .Error;
    public TomlVersion Version = .V1_1;
    public TomlMetadataMode MetadataMode = .None;
}
```

```bf
public struct TomlOriginalTokenRef
{
    public int mIndex;

    public this(int index)
    {
        mIndex = index;
    }

    public bool IsValid
    {
        get { return mIndex >= 0; }
    }

    public static TomlOriginalTokenRef Invalid
    {
        get { return .(-1); }
    }
}
```

```bf
public struct TomlSourceRange
{
    public int mLine;
    public int mColumn;
    public int mOffset;
    public int mLength;
}
```

```bf
public struct TomlStyleRef
{
    public int mIndex;

    public this(int index)
    {
        mIndex = index;
    }

    public bool IsValid => mIndex >= 0;

    public static TomlStyleRef Invalid
    {
        get { return .(-1); }
    }
}
```

```bf
[AllowDuplicates]
public enum TomlDirtyFlags : uint8
{
    None = 0,
    Value = 1,
    Children = 2,
    Style = 4
}
```

```bf
public class TomlDocumentMetadata
{
    public TomlMetadataMode mMode;
    public TomlDocumentStyle mDocumentStyle;

    public List<TomlNodeStyle> mNodeStyles ~ delete _;
    public List<TomlCommentSet> mComments ~ DeleteContainerAndItems!(_);

    // Owns raw source fragments captured during parse.
    public List<String> mOriginalTokens ~ DeleteContainerAndItems!(_);

    // Sparse style pools. Most nodes should not need entries here.
    public List<TomlKeyFormat> mKeyFormats ~ delete _;
    public List<TomlValueFormat> mValueFormats ~ delete _;

    public this(TomlMetadataMode mode)
    {
        mMode = mode;
        mDocumentStyle = .();
        mNodeStyles = new List<TomlNodeStyle>();
        mComments = new List<TomlCommentSet>();
        mOriginalTokens = new List<String>();
        mKeyFormats = new List<TomlKeyFormat>();
        mValueFormats = new List<TomlValueFormat>();
    }
}
```

```bf
public struct TomlNodeStyle
{
    public TomlNodeId mNodeId;

    // Coordinate for diagnostics/debugging. Does NOT recover source text.
    public TomlSourceRange mRange;

    // Index into mOriginalTokens for value reuse. Invalid if not captured.
    public TomlOriginalTokenRef mOriginalValueToken;

    public TomlDirtyFlags mDirtyFlags;

    // Invalid means default/inferred style.
    public TomlStyleRef mKeyFormatRef;
    public TomlStyleRef mValueFormatRef;
}
```

Deferred per-key-part style support uses this shape when exact quoted key spelling matters:

```bf
public struct TomlKeyPartFormat
{
    public TomlKeyStyle mStyle;
    public TomlOriginalTokenRef mOriginalPartToken;
}
```

Avoid storing all possible format structs in every node. A document with thousands of values should not pay for full key/value format payloads on every `TomlNodeStyle`. The chosen skeleton keeps node records compact and stores style payloads in sparse pools referenced by `TomlStyleRef`:

```bf
public enum TomlValueFormat
{
    case None;
    case String(TomlStringFormat format);
    case Integer(TomlIntegerFormat format);
    case Float(TomlFloatFormat format);
    case DateTime(TomlDateTimeFormat format);
    case Array(TomlArrayFormat format);
    case Table(TomlTableFormat format);
}
```

If this still proves large in practice, store only a compact kind byte plus indices into sparse format lists.

Beef implementation note: metadata-owning classes with `List<T>`, `Dictionary<K, V>`, or `String` fields should use explicit constructors and field destructors. Do not rely on generated constructors for fields using `~ delete _`.

---

## Current-code integration risks

### Read/merge semantics

`TomlDocument.Read` currently supports `Replace` and `Merge`. PreserveStyle must define metadata behavior for both:

```text
Replace success: replace semantic tree and metadata together
Replace failure: clear semantic tree and metadata together
Merge success: merge incoming semantic tree and incoming metadata transactionally
Merge failure: leave existing semantic tree and metadata unchanged
```

The current merge path parses into a temporary `TomlTable`, then clones values into the existing root. A metadata-aware merge will need a temporary metadata sidecar as well, plus remapping of incoming node IDs when values are cloned into the destination document.

### Writer lookup

`TomlWriterImpl.WriteValue` currently receives only `TomlValue`, with no path or node ID. Token reuse and style formatting require the writer traversal to pass node IDs or a style context alongside each value.

Dotted-key preservation also requires more than final key-part formatting. An input like:

```toml
server.port = 8080
server.host = "localhost"
```

is stored semantically as a `server` table with child keys. To re-emit dotted assignments, metadata must remember that those child entries were originally written from an ancestor as dotted key/value lines, and the writer must be able to emit leaf values from that ancestor context.

### Cursor/token capture

The current byte and stream cursors already support `Mark()`/`Slice()`. This is enough for scalar token copying, including long stream tokens via the stream cursor spill buffer.

Captures must be sequential, not concurrent:

```text
mark comment start -> advance through comment -> Slice/copy -> mark released
advance to value
mark value start -> parse/advance through value -> Slice/copy -> mark released
```

This supports preserving both comments and value tokens for one entry because only one mark is active at a time.

Avoid trying to copy whole array/table tokens initially because nested values create nested marks, while the current cursor design supports only one active mark.

## Performance and memory guidance

### Normal mode

`MetadataMode.None` should remain the fast path:

```text
no metadata object
no original token copies
no comment objects
no per-node style lists
only one null metadata-context field per table/array container
minimal additional branches in parser hot paths
```

A nullable metadata/context check at token boundaries is acceptable. Avoid per-byte metadata work in whitespace/comment scanning when metadata is disabled.

### PreserveStyle mode

Expected overhead is real and should be documented:

```text
semantic string value + raw string token copy
comment text copies
compact node style records
node-id side maps/lists
optional sparse comment/style records/style pools
```

Use sparse allocation wherever possible:

```text
only allocate comment records for nodes that have comments
only allocate original-token records for copied tokens
only allocate numeric format records when style differs from default, if practical
```

`List<String> mOriginalTokens` is simple but creates one heap `String` per copied token. If memory becomes a problem, replace it with a contiguous text arena:

```text
String mOriginalTokenText;
List<TomlTextRange> mOriginalTokenRanges;
```

where `TomlTextRange` is simply `(offset: int, length: int)` into the contiguous arena string.

The same arena strategy can also store comments.

### Format metadata size

Do not store every possible format struct on every node. Use an enum/union-shaped format value or sparse format pools. For many documents, most nodes will have no comments and no special numeric/date formatting, so the sidecar should optimize for absent metadata.

## Implementation plan

### Stage 1: add read option

Add:

```bf
TomlMetadataMode.None
TomlMetadataMode.PreserveStyle
```

Then add `MetadataMode` to the existing `TomlReadConfig`; do not add a parallel `TomlParseOptions` type.

Default should be:

```text
None
```

### Stage 2: introduce stable node IDs

Ensure values that can carry metadata have stable `TomlNodeId`s.

Minimum:

```text
table values
array elements
inline table fields
scalar values
```

### Stage 3: create metadata sidecar

Add `TomlDocumentMetadata`.

In `None` mode:

```text
do not allocate it
```

In `PreserveStyle` mode:

```text
allocate metadata and populate style records during parse
```

### Stage 4: copy string tokens during parse

When lexer/parser recognizes a string token and `PreserveStyle` is enabled:

```text
copy the raw token text into mOriginalTokens
store TomlOriginalTokenRef on the node style
store broad TomlStringFormat
```

This is the first big win.

### Stage 5: dirty tracking

Add dirty flags to node metadata.

Mutation APIs should mark:

```text
Value dirty when semantic value changes
Children dirty when container membership changes
Style dirty when comments/style metadata changes
```

Setters should avoid dirtying nodes when the assigned semantic value is equal.

### Stage 6: serializer token reuse

Teach serializer:

```text
if clean and original token exists:
  write original token
else:
  generate value from semantic value and format metadata
```

Start with strings.

### Stage 7: metadata-aware writer traversal

Refactor `TomlWriterImpl` so traversal carries node IDs or a style context alongside each `TomlValue`.

For `PreserveStyle`, add a metadata-aware path that can:

```text
look up node style by NodeId
reuse clean scalar tokens
regenerate dirty containers from TomlArrayFormat/TomlTableFormat
emit comments attached to nodes
```

This is also the right stage to decide whether preserved-style output keeps the current phased writer or introduces a single-pass preserved-order writer. The canonical writer can remain phased.

### Stage 8: numeric format metadata

Parse and store:

```text
integer base
underscore grouping
hex digit casing
float notation
exponent style
precision-ish hints
```

Optionally copy non-default numeric tokens.

### Stage 9: comments

Copy comments into owned strings during parse.

Attach to nodes as:

```text
leading
trailing
detached/root
```

Emit them during serialization.

### Stage 10: key/container/date-time styles

Add metadata for:

```text
dotted key preference
quoted key style
array inline/multiline layout
inline table vs table style
date/time formatting
```

### Stage 11: document-level style inference

Add broad defaults for new values:

```text
indent size
tabs/spaces
newline style if relevant
default string style
default array style
prefer dotted keys
```

Use fallback order:

```text
node style -> nearby style -> document style -> library default
```

### Stage 12: optional higher-level bind/type errors

Later, the same metadata can power type/binding errors.

But do not retrofit the core parser error type.

---

## Final concise design statement

TomlBeef should implement `PreserveStyle` as an optional sidecar metadata mode.

Because input buffers are not retained after parsing, any source text needed later must be copied during parse. The metadata should therefore own selected raw value tokens and comment strings, while source ranges remain coordinate-only.

The serializer may reuse copied original tokens only for semantically clean nodes. If a node is mutated, it must be regenerated from the semantic value using broad style metadata.

This gives TomlBeef practical style preservation — comments, strings, numeric presentation, dotted keys, and container layout — without committing to full source round-tripping or CST-level trivia preservation.
