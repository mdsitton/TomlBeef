using System;
using System.Collections;

namespace TomlBeef;

/// @brief Controls whether style metadata is captured during parsing.
public enum TomlMetadataMode : uint8
{
	/// @brief Normal parse mode. No extra style metadata, no comment preservation, no original-token copies.
	None,
	/// @brief Capture comments, selected original value tokens, and broad formatting metadata during parsing.
	/// Does not guarantee byte-for-byte output.
	PreserveStyle
}

/// @brief Flags indicating which aspects of a node have been modified since parsing.
[AllowDuplicates]
public enum TomlDirtyFlags : uint8
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
public struct TomlNodeId
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

	public static TomlNodeId Invalid
	{
		get { return .(-1); }
	}
}

/// @brief Reference to an owned original token copy stored in TomlDocumentMetadata.mOriginalTokens.
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

/// @brief Reference to a sparse style record stored in TomlDocumentMetadata style pools.
public struct TomlStyleRef
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

	public static TomlStyleRef Invalid
	{
		get { return .(-1); }
	}
}

/// @brief Source coordinate range for diagnostics/debugging. Does NOT recover source text.
public struct TomlSourceRange
{
	public int mLine;
	public int mColumn;
	public int mOffset;
	public int mLength;

	public this(int line, int column, int offset, int length)
	{
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;
	}
}

/// @brief Style metadata for a single node in the document tree.
/// Stored in TomlDocumentMetadata.mNodeStyles, indexed by TomlNodeId.
public struct TomlNodeStyle
{
	public TomlNodeId mNodeId;

	/// Coordinate for diagnostics/debugging. Does NOT recover source text.
	public TomlSourceRange mRange;

	/// Index into mOriginalTokens for value reuse. Invalid if not captured.
	public TomlOriginalTokenRef mOriginalValueToken;

	public TomlDirtyFlags mDirtyFlags;

	/// Invalid means default/inferred style.
	public TomlStyleRef mKeyFormatRef;
	/// Invalid means default/inferred style.
	public TomlStyleRef mValueFormatRef;

	public this(TomlNodeId nodeId)
	{
		mNodeId = nodeId;
		mRange = TomlSourceRange(0, 0, 0, 0);
		mOriginalValueToken = .Invalid;
		mDirtyFlags = .None;
		mKeyFormatRef = .Invalid;
		mValueFormatRef = .Invalid;
	}
}

/// @brief Owned set of comments associated with a node.
public class TomlCommentSet
{
	/// Comments appearing on lines before the node.
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
public enum TomlNewlineStyle : uint8
{
	LF,
	CRLF
}

/// @brief Broad fallback style choices for newly generated content.
/// Inferred during parsing; used when a node has no more-specific style metadata.
public struct TomlDocumentStyle
{
	public TomlNewlineStyle mNewlineStyle = .LF;
	public uint8 mIndentSize = 4;
	public bool mUseTabs = false;
	public bool mPreferDottedKeys = false;
	public TomlStringStyle mDefaultStringStyle = .Basic;
	public TomlContainerStyle mDefaultArrayStyle = .Inline;
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
public struct TomlStringFormat
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

/// @brief Format metadata for an integer value.
public struct TomlIntegerFormat
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
public enum TomlFloatStyle : uint8
{
	/// Standard decimal notation (1.0, 3.14).
	Decimal,
	/// Scientific notation (1e6, 3.14e+02).
	Scientific,
	/// Special values (inf, nan).
	Special
}

/// @brief Sign style for special float values (inf, nan).
public enum TomlFloatSpecialSign : uint8
{
	/// No sign prefix (inf, nan).
	None,
	/// Explicit plus sign prefix (+inf, +nan).
	ExplicitPlus,
	/// Explicit minus sign prefix (-inf, -nan).
	Minus
}

/// @brief Format metadata for a float value.
public struct TomlFloatFormat
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
public struct TomlDateTimeFormat
{
	/// Whether seconds were present (some times omit seconds).
	public bool mHasSeconds = false;
	/// Number of fractional second digits (0 = none).
	public uint8 mFractionalDigits = 0;
	/// Whether the date-time separator was uppercase T (vs lowercase t or space).
	public bool mUsesUppercaseT = true;
	/// Whether UTC offset used Z shorthand (vs +00:00).
	public bool mUsesZ = false;
	/// Whether an offset was present at all (offset date-time vs local).
	public bool mHasOffset = false;
}

// ================================================================
// Key style
// ================================================================

/// @brief TOML key presentation style.
public enum TomlKeyStyle : uint8
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
public struct TomlKeyFormat
{
	public TomlKeyStyle mStyle = .Bare;
	/// Whether to prefer dotted path syntax for new entries in this context.
	public bool mPreferDottedPath = false;
}

// ================================================================
// Container style
// ================================================================

/// @brief Container presentation style.
public enum TomlContainerStyle : uint8
{
	/// Single-line container (["a", "b"]).
	Inline,
	/// Multi-line container with one element per line.
	Multiline
}

/// @brief Format metadata for an array value.
public struct TomlArrayFormat
{
	public TomlContainerStyle mStyle = .Inline;
	/// Whether a trailing comma was present after the last element.
	public bool mTrailingComma = false;
	/// Indent size for multiline arrays (0 = use document default).
	public uint8 mIndentSize = 0;
}

/// @brief Format metadata for a table value.
public struct TomlTableFormat
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

	// Exactly one is populated, depending on container kind.
	internal Dictionary<String, TomlNodeId> mEntryNodeIds ~ DeleteDictionaryAndKeys!(_);
	internal List<TomlNodeId> mItemNodeIds ~ delete _;

	internal this(TomlDocumentMetadata metadata, TomlNodeId nodeId, bool isArray)
	{
		mMetadata = metadata;
		mNodeId = nodeId;
		if (isArray)
		{
			mItemNodeIds = new List<TomlNodeId>();
			mEntryNodeIds = null;
		}
		else
		{
			mEntryNodeIds = new Dictionary<String, TomlNodeId>();
			mItemNodeIds = null;
		}
	}

	/// @brief Look up the node ID for a table entry key.
	internal bool TryGetEntryNodeId(StringView key, out TomlNodeId nodeId)
	{
		if (mEntryNodeIds != null && mEntryNodeIds.TryGetValueAlt(key, let id))
		{
			nodeId = id;
			return true;
		}
		nodeId = default;
		return false;
	}

	/// Remove a node ID mapping for a table entry key. Deletes the owned key.
	internal void RemoveEntryNodeId(StringView key)
	{
		if (mEntryNodeIds != null)
		{
			if (mEntryNodeIds.TryGetAlt(key, let existingKey, let _))
			{
				mEntryNodeIds.Remove(existingKey);
				delete existingKey;
			}
		}
	}

	/// @brief Register a node ID for a table entry key. Copies the key.
	internal void SetEntryNodeId(StringView key, TomlNodeId nodeId)
	{
		if (mEntryNodeIds != null)
			mEntryNodeIds[new String(key)] = nodeId;
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
}

// ================================================================
// Document metadata sidecar
// ================================================================

/// @brief Optional metadata sidecar attached to a TomlDocument when PreserveStyle mode is enabled.
/// Owns all style records, comment strings, and original token copies.
public class TomlDocumentMetadata
{
	internal TomlMetadataMode mMode;

	/// @brief Metadata capture mode for this sidecar.
	public TomlMetadataMode Mode => mMode;

	/// @brief Root/document-level comments.
	internal TomlCommentSet mRootComments ~ delete _;
	/// @brief Footer/EOF comments.
	internal TomlCommentSet mFooterComments ~ delete _;

	/// @brief Document-level style defaults.
	internal TomlDocumentStyle mDocumentStyle;

	/// Per-node style records, indexed by TomlNodeId.mIndex.
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
		mNodeStyles = new List<TomlNodeStyle>();
		mComments = new List<TomlCommentSet>();
		mOriginalTokens = new List<String>();
		mKeyFormats = new List<TomlKeyFormat>();
		mValueFormats = new List<TomlValueFormat>();
	}

	/// @brief Allocate a new node ID and return it. The node style record is initialized to defaults.
	internal TomlNodeId AllocateNodeId()
	{
		int index = mNodeStyles.Count;
		mNodeStyles.Add(TomlNodeStyle(TomlNodeId(index)));
		return TomlNodeId(index);
	}

	/// @brief Get the style record for a node, or null if the ID is invalid.
	internal TomlNodeStyle* GetNodeStyle(TomlNodeId nodeId)
	{
		if (!nodeId.IsValid || nodeId.mIndex >= mNodeStyles.Count)
			return null;
		return &mNodeStyles[nodeId.mIndex];
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

	/// @brief Mark a node dirty with the given flags.
	internal void MarkDirty(TomlNodeId nodeId, TomlDirtyFlags flags)
	{
		let style = GetNodeStyle(nodeId);
		if (style != null)
			style.mDirtyFlags |= flags;
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
