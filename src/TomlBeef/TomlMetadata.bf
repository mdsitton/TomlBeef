using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// @brief Controls what metadata is captured during parsing. Each mode includes the ones before it.
public enum TomlMetadataMode : uint8
{
	/// @brief Normal parse mode. No extra style metadata, no comment preservation, no original-token copies.
	None,
	/// @brief Record only where each key/value, header and array element came from, for TryGetSourceRange.
	/// Much cheaper than PreserveStyle; the document is still written in canonical style.
	Positions,
	/// @brief Capture comments, selected original value tokens, and broad formatting metadata during parsing,
	/// in addition to positions. Does not guarantee byte-for-byte output.
	PreserveStyle
}

/// @brief Flags indicating which aspects of a node have been modified since parsing.
[AllowDuplicates]
internal enum TomlDirtyFlags : uint8
{
	None = 0,
	/// @brief The node's semantic scalar value changed. Do not reuse original token.
	Value = 1,
	/// @brief The container's membership changed. Regenerate container structure; clean children may still reuse tokens.
	Children = 2,
	/// @brief The user changed presentation metadata or comments. Regenerate even if semantic value is unchanged.
	Style = 4
}

/// @brief Identifies a style-preserved semantic slot in the metadata sidecar.
/// Used as an index into the metadata's node-style, comment, and token lists.
internal struct TomlNodeId
{
	// int32 keeps a table entry slot (TomlValue + node ID) at the size of the value's own padding
	public int32 mIndex;

	public this(int index)
	{
		Runtime.Assert(index <= int32.MaxValue);
		mIndex = (int32)index;
	}

	public bool IsValid
	{
		get { return mIndex >= 0; }
	}

	public static TomlNodeId Invalid
	{
		get { return .(-1); }
	}
}

/// @brief Reference to an owned original token copy stored in TomlDocumentMetadata.mOriginalTokens.
internal struct TomlOriginalTokenRef
{
	public int32 mIndex;

	public this(int index)
	{
		mIndex = (int32)index;
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

/// @brief Reference to a sparse style record stored in TomlDocumentMetadata style pools.
internal struct TomlStyleRef
{
	public int32 mIndex;

	public this(int index)
	{
		mIndex = (int32)index;
	}

	public bool IsValid
	{
		get { return mIndex >= 0; }
	}

	public static TomlStyleRef Invalid
	{
		get { return .(-1); }
	}
}

/// @brief Where something appeared in the source, for diagnostics. Does NOT recover source text.
public struct TomlSourceRange
{
	/// @brief Name of the source (TomlReadConfig.SourceName, or the path for ReadFile); empty if unnamed.
	/// Borrowed from the document: valid until it is cleared or deleted.
	public StringView mSource;
	/// @brief 1-based line.
	public int mLine;
	/// @brief 1-based column.
	public int mColumn;
	/// @brief Byte offset into the source.
	public int mOffset;
	/// @brief Length in bytes.
	public int mLength;

	public this(int line, int column, int offset, int length, StringView source = default)
	{
		mSource = source;
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;
	}

	/// @brief Formats the position as `source:line:column`, or `line:column` without a source name.
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		strBuffer.AppendF("{}:{}", mLine, mColumn);
	}
}

/// @brief A node's source range as stored in the sidecar: TomlSourceRange with 32-bit fields.
/// Recorded for every node in both Positions and PreserveStyle mode, so it is kept compact.
internal struct TomlPackedRange
{
	public int32 mLine;
	public int32 mColumn;
	public int32 mOffset;
	public int32 mLength;
	/// Index into TomlDocumentMetadata.mSourceNames, or -1 for an unnamed source.
	public int32 mSource;
}

/// @brief Style metadata for a single node in the document tree (PreserveStyle only).
/// Stored in TomlDocumentMetadata.mNodeStyles, indexed by TomlNodeId. The node's source range is kept
/// separately in mRanges, which Positions mode also fills.
internal struct TomlNodeStyle
{
	/// Index into mOriginalTokens for value reuse. Invalid if not captured.
	public TomlOriginalTokenRef mOriginalValueToken;

	public TomlDirtyFlags mDirtyFlags;

	/// Invalid means default/inferred style.
	public TomlStyleRef mKeyFormatRef;
	/// Invalid means default/inferred style.
	public TomlStyleRef mValueFormatRef;

	public this()
	{
		mOriginalValueToken = .Invalid;
		mDirtyFlags = .None;
		mKeyFormatRef = .Invalid;
		mValueFormatRef = .Invalid;
	}
}

/// @brief Owned set of comments associated with a node.
internal class TomlCommentSet
{
	/// Comments appearing on lines before the node, without the '#'. A null entry is a blank line
	/// inside or after the comment block (e.g. a comment separated from the node by a blank line).
	public List<String> mLeading ~ DeleteContainerAndItems!(_);
	/// Comment text on the same line as the node (after the value). Null if none.
	public String mTrailing ~ delete _;
	/// Whether there was a blank line separating this node's leading comments from the preceding content.
	public bool mSeparatedByBlankLine = false;

	public this()
	{
		mLeading = new List<String>();
		mTrailing = null;
	}
}

// ================================================================
// Document-level style
// ================================================================

/// @brief Newline style detected or configured for a document.
internal enum TomlNewlineStyle : uint8
{
	LF,
	CRLF
}

/// @brief Broad fallback style choices for newly generated content.
/// Inferred during parsing; used when a node has no more-specific style metadata.
internal struct TomlDocumentStyle
{
	public TomlNewlineStyle mNewlineStyle = .LF;
	public uint8 mIndentSize = 4;
	public bool mUseTabs = false;
	public bool mPreferDottedKeys = false;
	public TomlStringStyle mDefaultStringStyle = .Basic;
	public TomlContainerStyle mDefaultArrayStyle = .Inline;
	/// Whether the document's multi-line arrays mostly end with a trailing comma (new ones follow it).
	public bool mDefaultArrayTrailingComma = true;
}

// ================================================================
// String style
// ================================================================

/// @brief TOML string presentation style.
public enum TomlStringStyle : uint8
{
	Basic,
	Literal,
	MultilineBasic,
	MultilineLiteral
}

/// @brief Format metadata for a string value, used to regenerate changed strings.
internal struct TomlStringFormat
{
	public TomlStringStyle mStyle = .Basic;
	/// Hint: the original multiline string started with a newline after the opening quotes.
	public bool mStartsWithNewline = false;
	/// Hint: the original string contained escape sequences.
	public bool mHadEscapes = false;
	/// Hint: prefer escaped newlines (\n) over real newlines in multiline regeneration.
	public bool mPreferEscapedNewlines = false;
}

// ================================================================
// Numeric style
// ================================================================

/// @brief Integer base representation.
public enum TomlIntegerBase : uint8
{
	Decimal,
	Binary,
	Octal,
	Hex
}

/// @brief How a float is written (TomlTable.SetFloatNotation). inf and nan are written as such either way.
public enum TomlFloatNotation : uint8
{
	/// @brief `1500.0`, `0.25`.
	Decimal,
	/// @brief `1.5e3`, `2.5e-1`.
	Scientific
}

/// @brief How an array is laid out (TomlTable.SetArrayLayout). An array whose elements carry comments is
/// always written one element per line, since comments need their own lines.
public enum TomlArrayLayout : uint8
{
	/// @brief `[1, 2, 3]` on one line.
	Inline,
	/// @brief One element per line, indented.
	Multiline
}

/// @brief How an inline table is laid out (TomlTable.SetInlineTableLayout).
public enum TomlInlineTableLayout : uint8
{
	/// @brief `{a=1,b=2}`.
	Compact,
	/// @brief `{ a = 1, b = 2 }`.
	Spaced,
	/// @brief One field per line (TOML 1.1; a 1.0 write puts it on one line, spaced).
	Multiline
}

/// @brief How a key is quoted (TomlTable.SetKeyQuoting). A key that cannot be written as asked falls back:
/// Bare to basic quotes when the key has characters outside A-Z a-z 0-9 - _, Literal to basic quotes when
/// the key contains a single quote or control characters.
public enum TomlKeyQuoting : uint8
{
	/// @brief `port` (quoted only when needed).
	Bare,
	/// @brief `"port"`.
	Basic,
	/// @brief `'port'`.
	Literal
}

/// @brief How a date-time or time is written (TomlTable.SetDateTimeStyle).
public struct TomlDateTimeStyle
{
	/// @brief Between date and time: 'T' (default) or ' '.
	public char8 Separator = 'T';
	/// @brief Write a zero UTC offset as `Z` (default) rather than `+00:00`.
	public bool UseZ = true;
	/// @brief Write at least this many fraction-of-second digits (0-9), padding with zeros; more are
	/// written when the value needs them, so no precision is lost.
	public int MinFractionDigits = 0;
}

/// @brief Format metadata for an integer value.
internal struct TomlIntegerFormat
{
	public TomlIntegerBase mBase = .Decimal;
	/// Whether hex digits used uppercase (0xDEAD vs 0xdead).
	public bool mUppercaseDigits = false;
	/// Whether underscore grouping was present (1_000_000).
	public bool mUseUnderscores = false;
	/// Group size for underscore grouping (e.g., 3 for 1_000_000). 0 = no grouping.
	public uint8 mGroupSize = 0;
	/// Minimum number of digits to pad to (e.g., 4 for 0x00FF). 0 = no padding.
	public uint8 mMinDigits = 0;
}

/// @brief Float presentation style.
internal enum TomlFloatStyle : uint8
{
	/// Standard decimal notation (1.0, 3.14).
	Decimal,
	/// Scientific notation (1e6, 3.14e+02).
	Scientific,
	/// Special values (inf, nan).
	Special
}

/// @brief Sign style for special float values (inf, nan).
internal enum TomlFloatSpecialSign : uint8
{
	/// No sign prefix (inf, nan).
	None,
	/// Explicit plus sign prefix (+inf, +nan).
	ExplicitPlus,
	/// Explicit minus sign prefix (-inf, -nan).
	Minus
}

/// @brief Format metadata for a float value.
internal struct TomlFloatFormat
{
	public TomlFloatStyle mStyle = .Decimal;
	/// Whether exponent marker was uppercase (E vs e).
	public bool mUppercaseExponent = false;
	/// Whether exponent had explicit plus sign (1e+06 vs 1e6).
	public bool mExplicitPlusExponent = false;
	/// Precision hint (-1 = default/unset).
	public int16 mPrecision = -1;
	/// Whether underscore grouping was present.
	public bool mUseUnderscores = false;
	/// Digit width of the exponent value (e.g., 2 for 1e06, 3 for 1E+006). 0 = use default width.
	public uint8 mExponentDigits = 0;
	/// Sign style for special float values. Only meaningful when mStyle == Special.
	public TomlFloatSpecialSign mSpecialSign = .None;
	/// Group size for integer part underscores (e.g., 3 for 224_617.445). 0 = no grouping.
	public uint8 mIntGroupSize = 0;
	/// Group size for fractional part underscores (e.g., 3 for 445_991). 0 = no grouping.
	public uint8 mFracGroupSize = 0;
}

// ================================================================
// Date/time style
// ================================================================

/// @brief Format metadata for a date-time value.
internal struct TomlDateTimeFormat
{
	/// Whether seconds were present (some times omit seconds).
	public bool mHasSeconds = false;
	/// Number of fractional second digits (0 = none).
	public uint8 mFractionalDigits = 0;
	/// The date-time separator as written: 'T', 't', or ' '.
	public char8 mSeparator = 'T';
	/// Whether UTC offset used Z shorthand (vs +00:00).
	public bool mUsesZ = false;
	/// Whether the Z shorthand was written in lowercase ('z').
	public bool mLowercaseZ = false;
	/// Whether an offset was present at all (offset date-time vs local).
	public bool mHasOffset = false;
}

// ================================================================
// Key style
// ================================================================

/// @brief TOML key presentation style.
internal enum TomlKeyStyle : uint8
{
	/// Unquoted key (server, port).
	Bare,
	/// Basic quoted key ("server").
	QuotedBasic,
	/// Literal quoted key ('server').
	QuotedLiteral,
	/// Dotted key path (server.port).
	Dotted
}

/// @brief Format metadata for a key or key path.
internal struct TomlKeyFormat
{
	public TomlKeyStyle mStyle = .Bare;
	/// Whether to prefer dotted path syntax for new entries in this context.
	public bool mPreferDottedPath = false;
}

// ================================================================
// Container style
// ================================================================

/// @brief Container presentation style.
internal enum TomlContainerStyle : uint8
{
	/// Single-line container (["a", "b"]).
	Inline,
	/// Multi-line container with one element per line.
	Multiline
}

/// @brief Format metadata for an array value.
internal struct TomlArrayFormat
{
	public TomlContainerStyle mStyle = .Inline;
	/// Whether a trailing comma was present after the last element.
	public bool mTrailingComma = false;
	/// Indent size for multiline arrays (0 = use document default).
	public uint8 mIndentSize = 0;
}

/// @brief Format metadata for a table value.
internal struct TomlTableFormat
{
	/// Whether the table was written as an inline table ({ key = value }).
	public bool mInline = false;
	/// Whether to prefer dotted key syntax for child entries.
	public bool mPreferDottedKeys = false;
	/// Whether the inline table used multiline layout (v1.1).
	public bool mMultiline = false;
	/// Whether a trailing comma was present after the last entry (v1.1).
	public bool mTrailingComma = false;
	/// Number of spaces after opening brace (0 = none, 1 = "{ ", etc.).
	public uint8 mOpenBraceSpacing = 0;
	/// Number of spaces before closing brace (0 = none, 1 = " }", etc.).
	public uint8 mCloseBraceSpacing = 0;
	/// Number of spaces around equals sign (0 = "=", 1 = " = ").
	public uint8 mEqualsSpacing = 1;
	/// Number of spaces after comma (0 = ",", 1 = ", ").
	public uint8 mCommaSpacing = 1;
	/// Indentation size for multiline inline table entries. 0 = use document default.
	public uint8 mEntryIndent = 0;
}

// ================================================================
// Value format union
// ================================================================

/// @brief Union of all possible value format types. Stored in sparse style pools.
internal enum TomlValueFormat
{
	case None;
	case String(TomlStringFormat format);
	case Integer(TomlIntegerFormat format);
	case Float(TomlFloatFormat format);
	case DateTime(TomlDateTimeFormat format);
	case Array(TomlArrayFormat format);
	case Table(TomlTableFormat format);
}

// ================================================================
// Container metadata context
// ================================================================

/// @brief Per-container metadata context for style-preserving mode.
/// Provides a link between table entries / array elements and their node IDs.
/// Null in normal mode; allocated only when PreserveStyle is enabled.
internal class TomlContainerMetadataContext
{
	internal TomlDocumentMetadata mMetadata; // borrowed document-owned sidecar
	internal TomlNodeId mNodeId;

	// Array element node IDs, by index (arrays only). A table keeps its entries' node IDs in its own
	// entry slots (TomlTableSlot), so a table context holds just the sidecar and the table's own node.
	internal List<TomlNodeId> mItemNodeIds ~ delete _;

	internal this(TomlDocumentMetadata metadata, TomlNodeId nodeId, bool isArray)
	{
		mMetadata = metadata;
		mNodeId = nodeId;
		mItemNodeIds = isArray ? new List<TomlNodeId>() : null;
	}

	/// @brief Get the node ID for an array element by index.
	internal bool TryGetItemNodeId(int index, out TomlNodeId nodeId)
	{
		if (mItemNodeIds != null && index >= 0 && index < mItemNodeIds.Count)
		{
			nodeId = mItemNodeIds[index];
			return true;
		}
		nodeId = default;
		return false;
	}

	/// @brief Append a node ID for a new array element.
	internal void AddItemNodeId(TomlNodeId nodeId)
	{
		if (mItemNodeIds != null)
			mItemNodeIds.Add(nodeId);
	}

	/// @brief Remove the node ID at the given index, shifting later IDs down.
	/// Called after array element deletion at that index.
	internal void RemoveItemNodeId(int index)
	{
		if (mItemNodeIds != null && index >= 0 && index < mItemNodeIds.Count)
			mItemNodeIds.RemoveAt(index);
	}

	/// @brief Clear all array element node IDs.
	internal void ClearItemNodeIds()
	{
		if (mItemNodeIds != null)
			mItemNodeIds.Clear();
	}
}

// ================================================================
// Document metadata sidecar
// ================================================================

/// @brief Optional metadata sidecar attached to a TomlDocument read with Positions or PreserveStyle.
/// Owns all style records, comment strings, and original token copies.
internal class TomlDocumentMetadata
{
	internal TomlMetadataMode mMode;

	/// @brief Metadata capture mode for this sidecar.
	public TomlMetadataMode Mode => mMode;

	/// @brief True when comments, tokens and formats are captured and written back (PreserveStyle).
	/// With Positions only node IDs and source ranges are recorded.
	internal bool CapturesStyle => mMode == .PreserveStyle;

	/// @brief Raise the mode after reading with a more capable one. A sidecar never downgrades: nodes that
	/// already carry style keep it, and nodes read under a lesser mode simply have none.
	/// @param mode The mode of the read that is about to use (or has merged into) this sidecar.
	internal void Upgrade(TomlMetadataMode mode)
	{
		if (mode > mMode)
			mMode = mode;
	}

	/// @brief Root/document-level comments.
	internal TomlCommentSet mRootComments ~ delete _;
	/// @brief Footer/EOF comments.
	internal TomlCommentSet mFooterComments ~ delete _;

	/// @brief Dirty flags for the root table. The root is not an entry of any table, so like
	/// mRootComments it is tracked here instead of through a node ID.
	internal TomlDirtyFlags mRootDirtyFlags;

	/// @brief Document-level style defaults.
	internal TomlDocumentStyle mDocumentStyle;

	/// Per-node source ranges, indexed by TomlNodeId.mIndex. One per allocated node in every mode, so its
	/// count is the node count.
	internal List<TomlPackedRange> mRanges ~ delete _;
	/// Names of the sources ranges were recorded from (one per distinct name, e.g. base and override
	/// files merged into one document).
	internal List<String> mSourceNames ~ DeleteContainerAndItems!(_);
	/// Per-node style records, indexed by TomlNodeId.mIndex. Filled only while capturing style; a sidecar
	/// upgraded from Positions gets records for its earlier nodes on first access (GetNodeStyle).
	internal List<TomlNodeStyle> mNodeStyles ~ delete _;
	/// Per-node comment sets.
	internal List<TomlCommentSet> mComments ~ DeleteContainerAndItems!(_);

	/// Owns raw source fragments captured during parsing.
	internal List<String> mOriginalTokens ~ DeleteContainerAndItems!(_);

	/// Sparse key format pool.
	internal List<TomlKeyFormat> mKeyFormats ~ delete _;
	/// Sparse value format pool.
	internal List<TomlValueFormat> mValueFormats ~ delete _;

	internal this(TomlMetadataMode mode)
	{
		mMode = mode;
		mRootComments = null;
		mFooterComments = null;
		mDocumentStyle = .();
		mRanges = new List<TomlPackedRange>();
		mSourceNames = new List<String>();
		mNodeStyles = new List<TomlNodeStyle>();
		mComments = new List<TomlCommentSet>();
		mOriginalTokens = new List<String>();
		mKeyFormats = new List<TomlKeyFormat>();
		mValueFormats = new List<TomlValueFormat>();
	}

	/// @brief Allocate a new node ID and return it, with an unset range and (when capturing style) a
	/// default style record.
	internal TomlNodeId AllocateNodeId()
	{
		int index = mRanges.Count;
		mRanges.Add(default);
		if (CapturesStyle)
			mNodeStyles.Add(.());
		return TomlNodeId(index);
	}

	/// @brief Get the style record for a node: null if the ID is invalid or style is not captured.
	/// The pointer is invalidated by the next node allocation.
	internal TomlNodeStyle* GetNodeStyle(TomlNodeId nodeId)
	{
		if (!nodeId.IsValid || nodeId.mIndex >= mRanges.Count || !CapturesStyle)
			return null;
		// Nodes allocated before an upgrade from Positions have no record yet
		while (mNodeStyles.Count <= nodeId.mIndex)
			mNodeStyles.Add(.());
		return &mNodeStyles[nodeId.mIndex];
	}

	/// @brief Register a source name for ranges, reusing the index of an equal name.
	/// @param name The source name; empty means unnamed.
	/// @return The index to pass to SetSourceRange, or -1 for an unnamed source.
	internal int32 AddSource(StringView name)
	{
		if (name.IsEmpty)
			return -1;
		for (int i = 0; i < mSourceNames.Count; i++)
		{
			if (mSourceNames[i] == name)
				return (int32)i;
		}
		mSourceNames.Add(new String(name));
		return (int32)(mSourceNames.Count - 1);
	}

	/// @brief Record where a node appeared in the source.
	/// @param source Index from AddSource, or -1.
	internal void SetSourceRange(TomlNodeId nodeId, int line, int column, int offset, int length, int32 source)
	{
		if (!nodeId.IsValid || nodeId.mIndex >= mRanges.Count)
			return;
		// Inputs are far below 2 GB (and MaxInputBytes can enforce it), so 32 bits per field suffice
		mRanges[nodeId.mIndex] = .() { mLine = (int32)line, mColumn = (int32)column, mOffset = (int32)offset, mLength = (int32)length, mSource = source };
	}

	/// @brief Where a node appeared in the source.
	/// @return False if the ID is invalid or no range was recorded (values added in code).
	internal bool TryGetSourceRange(TomlNodeId nodeId, out TomlSourceRange range)
	{
		range = default;
		if (!nodeId.IsValid || nodeId.mIndex >= mRanges.Count)
			return false;
		let packed = mRanges[nodeId.mIndex];
		// Lines are 1-based, so an unset range has line 0
		if (packed.mLine <= 0)
			return false;
		StringView source = (packed.mSource >= 0) ? mSourceNames[packed.mSource] : default;
		range = .(packed.mLine, packed.mColumn, packed.mOffset, packed.mLength, source);
		return true;
	}

	/// @brief Copy a node's range from another sidecar (a merge), keeping which source it came from.
	internal void CopySourceRange(TomlDocumentMetadata srcMeta, TomlNodeId srcId, TomlNodeId dstId)
	{
		if (!srcMeta.TryGetSourceRange(srcId, let range))
			return;
		SetSourceRange(dstId, range.mLine, range.mColumn, range.mOffset, range.mLength, AddSource(range.mSource));
	}

	/// @brief Add an original token copy and return a reference to it.
	internal TomlOriginalTokenRef AddOriginalToken(StringView tokenText)
	{
		int index = mOriginalTokens.Count;
		mOriginalTokens.Add(new String(tokenText));
		return TomlOriginalTokenRef(index);
	}

	/// @brief Get the original token text for a reference, or null if invalid.
	internal StringView GetOriginalToken(TomlOriginalTokenRef tokenRef)
	{
		if (!tokenRef.IsValid || tokenRef.mIndex >= mOriginalTokens.Count)
			return StringView();
		return mOriginalTokens[tokenRef.mIndex];
	}

	/// @brief Add a key format to the sparse pool and return a reference.
	internal TomlStyleRef AddKeyFormat(TomlKeyFormat format)
	{
		int index = mKeyFormats.Count;
		mKeyFormats.Add(format);
		return TomlStyleRef(index);
	}

	/// @brief Add a value format to the sparse pool and return a reference.
	internal TomlStyleRef AddValueFormat(TomlValueFormat format)
	{
		int index = mValueFormats.Count;
		mValueFormats.Add(format);
		return TomlStyleRef(index);
	}

	/// @brief Get or create the comment set for a node. Allocates the comment list entry if needed.
	/// @param nodeId The node to get comments for.
	/// @return The comment set, or null if nodeId is invalid.
	internal TomlCommentSet GetOrCreateCommentSet(TomlNodeId nodeId)
	{
		if (!nodeId.IsValid)
			return null;

		// Ensure the comments list is large enough
		while (mComments.Count <= nodeId.mIndex)
			mComments.Add(null);

		if (mComments[nodeId.mIndex] == null)
			mComments[nodeId.mIndex] = new TomlCommentSet();

		return mComments[nodeId.mIndex];
	}

	/// @brief Get the comment set for a node, or null if none exists.
	/// @param nodeId The node to look up.
	/// @return The comment set, or null if the node has no comments or the ID is invalid.
	internal TomlCommentSet GetCommentSet(TomlNodeId nodeId)
	{
		if (!nodeId.IsValid || nodeId.mIndex >= mComments.Count)
			return null;
		return mComments[nodeId.mIndex];
	}

	/// Comment text becomes `# text` lines, so it must not contain control characters (tab allowed), nor
	/// newlines unless it is a multi-line leading comment.
	internal static bool IsValidCommentText(StringView text, bool allowNewlines)
	{
		for (let c in text)
		{
			if (c == '\n' && allowNewlines)
				continue;
			if (c == '\n' || c == '\r' || (uint8)c == 0x7F || ((uint8)c < 0x20 && c != '\t'))
				return false;
		}
		return true;
	}

	/// Replaces a node's leading comment lines (split on '\n'); empty text removes them. The public
	/// comment setters on tables and arrays check that the sidecar captures style before calling this.
	/// @return False for an invalid node or invalid text.
	internal bool SetLeadingCommentText(TomlNodeId nodeId, StringView comment)
	{
		if (!nodeId.IsValid || !IsValidCommentText(comment, true))
			return false;
		let commentSet = GetOrCreateCommentSet(nodeId);
		ClearAndDeleteItems!(commentSet.mLeading);
		if (!comment.IsEmpty)
		{
			for (let line in comment.Split('\n'))
				commentSet.mLeading.Add(new String(line));
		}
		return true;
	}

	/// Replaces a node's trailing (end of line) comment; empty text removes it.
	/// @return False for an invalid node or invalid text (including a newline).
	internal bool SetTrailingCommentText(TomlNodeId nodeId, StringView comment)
	{
		if (!nodeId.IsValid || !IsValidCommentText(comment, false))
			return false;
		let commentSet = GetOrCreateCommentSet(nodeId);
		delete commentSet.mTrailing;
		commentSet.mTrailing = comment.IsEmpty ? null : new String(comment);
		return true;
	}

	/// Appends a node's leading comment lines, joined with '\n'. Blank-line markers inside the block are
	/// layout, not text, and are skipped.
	/// @return True if the node has leading comment text.
	internal bool TryGetLeadingCommentText(TomlNodeId nodeId, String outComment)
	{
		let commentSet = GetCommentSet(nodeId);
		if (commentSet == null)
			return false;
		bool first = true;
		for (let line in commentSet.mLeading)
		{
			if (line == null)
				continue;
			if (!first)
				outComment.Append('\n');
			outComment.Append(line);
			first = false;
		}
		return !first;
	}

	/// Appends a node's trailing comment.
	/// @return True if the node has one.
	internal bool TryGetTrailingCommentText(TomlNodeId nodeId, String outComment)
	{
		let commentSet = GetCommentSet(nodeId);
		if (commentSet == null || commentSet.mTrailing == null)
			return false;
		outComment.Append(commentSet.mTrailing);
		return true;
	}

	/// @brief Get or create the root/document-level comment set.
	internal TomlCommentSet GetOrCreateRootComments()
	{
		if (mRootComments == null)
			mRootComments = new TomlCommentSet();
		return mRootComments;
	}

	/// @brief Get or create the footer/EOF comment set.
	internal TomlCommentSet GetOrCreateFooterComments()
	{
		if (mFooterComments == null)
			mFooterComments = new TomlCommentSet();
		return mFooterComments;
	}
}
