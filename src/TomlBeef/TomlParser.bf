using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// Recursive descent parser for TOML v1.1.0.
internal class TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	private TCursor mCursor;
	private TomlPathResolver mPathResolver;
	private TomlVersion mVersion;
	private TomlDocumentMetadata mMetadata;
	private TomlDocumentStore mStore;
	private int mDepth = 0;
	private TomlResourceLimitState mLimits;

	// Pending leading comments waiting to be attached to the next node.
	private List<String> mPendingComments ~ { if (_ != null) { for (var item in _) delete item; delete _; } };
	// Pending trailing comment text waiting to be attached to the current node.
	private String mTrailingCommentText ~ delete _;
	// Whether we've seen content (key/val or header) — used to detect file header comments.
	private bool mSeenContent;
	// Node ID of the last key/val for trailing comment attachment.
	private TomlNodeId mLastNodeId;
	// Whether a blank line was seen since the last comment. Used to classify detached vs leading.
	private bool mBlankLineSinceComment;
	// Count of consecutive blank lines (comment-free) before the next content node. Used for section spacing.
	private int mBlankLineCount;
	// Saved blank line count for the next header or key/val, consumed by AttachPendingComments.
	private int mSavedBlankLineCount;
	// Whether we've inferred the indentation style from the first key/header.
	private bool mInferredIndent;
	/// The document indent size was taken from an indented top-level line (not the default).
	private bool mInferredIndentFromContent;
	/// The indentation character (space or tab) has been recorded in the document style.
	private bool mIndentCharKnown;
	/// The indent size has been taken from an indented container line.
	private bool mIndentSizeKnown;
	// String style usage counts for detecting the dominant style.
	private int mStringStyleCount_Basic;
	private int mStringStyleCount_Literal;
	private int mStringStyleCount_MultilineBasic;
	private int mStringStyleCount_MultilineLiteral;
	private int mArrayStyleCount_Inline;
	private int mArrayStyleCount_Multiline;
	private int mCrlfCount;
	private int mLfOnlyCount;

	/// @param store The store that owns every value the parser creates. Required.
	/// @param metadata The PreserveStyle sidecar to capture into, or null when not capturing.
	public this(TomlReadConfig config, TomlDocumentStore store, TomlDocumentMetadata metadata, TomlResourceLimitState externalLimits = null)
	{
		Runtime.Assert(store != null, "TomlParserImpl requires a store");
		mVersion = config.Version;
		mLimits = externalLimits;
		mStore = store;
		mMetadata = metadata;
		mPendingComments = new List<String>();
		mTrailingCommentText = null;
		mSeenContent = false;
		mLastNodeId = .Invalid;
		mBlankLineSinceComment = false;
		mBlankLineCount = 0;
		mSavedBlankLineCount = 0;
		mInferredIndent = false;
		mInferredIndentFromContent = false;
		mIndentCharKnown = false;
		mIndentSizeKnown = false;
		mStringStyleCount_Basic = 0;
		mStringStyleCount_Literal = 0;
		mStringStyleCount_MultilineBasic = 0;
		mStringStyleCount_MultilineLiteral = 0;
		mArrayStyleCount_Inline = 0;
		mArrayStyleCount_Multiline = 0;
		mCrlfCount = 0;
		mLfOnlyCount = 0;
	}

	public Result<void, TomlParseError> Parse(TCursor cursor, TomlPathResolver resolver)
	{
		mCursor = cursor;
		mPathResolver = resolver;
		mPathResolver.Reset();
		mDepth = 0;

		if (ParseDocument() case .Err(let e))
			return .Err(e);

		return .Ok;
	}

	// ================================================================
	// Document level
	// ================================================================

	private Result<void, TomlParseError> ParseDocument()
	{
		while (!mCursor.IsEOF)
		{
			mCursor.SkipWhitespace();
			if (mCursor.IsEOF)
				break;

			char8 b = mCursor.PeekByte();

			// Reject BOM not at start of file
			if ((uint8)b == 0xEF && (uint8)mCursor.PeekByteAt(1) == 0xBB && (uint8)mCursor.PeekByteAt(2) == 0xBF)
				return .Err(Error(.ControlCharInDocument, "BOM must only appear at start of file"));

			// Reject bare CR (not part of CRLF) and other control chars at document level
			if (b == '\r' && mCursor.PeekByteAt(1) != '\n')
				return .Err(Error(.ControlCharInDocument, "Bare CR not allowed"));
			if ((uint8)b < 0x20 && b != '\t' && b != '\r' && b != '\n')
				return .Err(Error(.ControlCharInDocument, "Control character in document"));

			if (b == '#')
			{
				// If a blank line separated these comments from the next content,
				// and we haven't seen content yet, flush to root (file header comments)
				if (mBlankLineSinceComment && !mSeenContent && mMetadata != null && mPendingComments.Count > 0)
					AttachPendingCommentsToRoot();
				mBlankLineSinceComment = false;

				if (CapturePendingComment() case .Err(let e))
					return .Err(e);
				continue;
			}
			if (b == '\r' || b == '\n')
			{
				// Track blank lines: before any pending comment they separate the next node from what came
				// before (mSeparatedByBlankLine); after a comment they are kept inside the comment block as a
				// null entry (consecutive blank lines collapse to one)
				if (mMetadata != null)
				{
					if (mPendingComments.Count > 0)
					{
						mBlankLineSinceComment = true;
						if (mPendingComments.Back != null)
							mPendingComments.Add(null);
					}
					else
						mBlankLineCount++;
				}
				CountAndSkipNewline();
				continue;
			}

			if (b == '[')
			{
				// If a blank line separated pending comments from this header,
				// and we haven't seen content yet, flush to root (file header comments)
				if (mBlankLineSinceComment && !mSeenContent && mMetadata != null && mPendingComments.Count > 0)
					AttachPendingCommentsToRoot();
				mBlankLineSinceComment = false;

				// Save blank line count for header comment attachment, then reset
				if (mMetadata != null)
					mSavedBlankLineCount = mBlankLineCount;
				mBlankLineCount = 0;

				// Detect indentation from whitespace before first content
				if (!mInferredIndent && mMetadata != null)
				{
					// SkipWhitespace was already called at loop top.
					// Use cursor column as indent depth. Only update if indented.
					if (mCursor.Column > 1)
					{
						mMetadata.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
						mInferredIndentFromContent = true;
					}
					mInferredIndent = true;
				}

				if (ParseHeader() case .Err(let headerErr))
					return .Err(headerErr);
				continue;
			}

			// If a blank line separated pending comments from this key/val,
			// and we haven't seen content yet, flush to root (file header comments)
			if (mBlankLineSinceComment && !mSeenContent && mMetadata != null && mPendingComments.Count > 0)
				AttachPendingCommentsToRoot();
			mBlankLineSinceComment = false;
			if (mMetadata != null)
				mSavedBlankLineCount = mBlankLineCount;
			mBlankLineCount = 0;

			// Detect indentation from whitespace before first content
			if (!mInferredIndent && mMetadata != null)
			{
				if (mCursor.Column > 1)
				{
					mMetadata.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
					mInferredIndentFromContent = true;
				}
				mInferredIndent = true;
			}

			if (ParseKeyVal() case .Err(let kvErr))
				return .Err(kvErr);

			mCursor.SkipWhitespace();
			if (!mCursor.IsEOF)
			{
				char8 afterB = mCursor.PeekByte();
				if (afterB == '#')
				{
					if (CaptureTrailingComment() case .Err(let commentErr))
						return .Err(commentErr);
					// Attach trailing comment to the last key/val node
					if (mMetadata != null && mLastNodeId.IsValid)
						AttachTrailingComment(mLastNodeId);
				}
				else if (afterB != '\r' && afterB != '\n')
					return .Err(Error(.MissingNewlineAfterKeyVal, "Expected newline after key/value pair"));
				else
				{
					CountAndSkipNewline();
				}
			}
		}

		// Attach any remaining pending comments
		if (mMetadata != null && mPendingComments.Count > 0)
		{
			if (mSeenContent)
				AttachPendingCommentsToFooter();
			else
				AttachPendingCommentsToRoot();
		}

		// Infer document-level style from accumulated parsing state
		InferDocumentStyle();

		return .Ok;
	}

	private Result<void, TomlParseError> ParseHeader()
	{
		SyncPathResolver();

		bool isArray = false;
		mCursor.AdvanceByte();
		if (mCursor.PeekByte() == '[')
		{
			mCursor.AdvanceByte();
			isArray = true;
		}

		mCursor.SkipWhitespace();

		var path = scope List<String>();
		defer { ClearAndDeleteItems!(path); }
		if (ParseKeyPath(path) case .Err(let e))
			return .Err(e);

		mCursor.SkipWhitespace();

		if (isArray)
		{
			if (mCursor.PeekByte() != ']' || mCursor.PeekByteAt(1) != ']')
				return .Err(Error(.UnexpectedToken, "Expected ']]'"));
			mCursor.AdvanceByte();
			mCursor.AdvanceByte();
		}
		else
		{
			if (mCursor.PeekByte() != ']')
				return .Err(Error(.UnexpectedToken, "Expected ']'"));
			mCursor.AdvanceByte();
		}
		int headerEnd = mCursor.Offset;

		mCursor.SkipWhitespace();
		if (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '#')
			{
				if (CaptureTrailingComment() case .Err(let commentErr))
					return .Err(commentErr);
			}
			else if (b == '\r' || b == '\n')
				CountAndSkipNewline();
			else
				return .Err(Error(.UnexpectedToken, "Expected newline or comment after header"));
		}

		// The resolver reports errors at the header start, synced above
		TomlNodeId nodeId = .Invalid;
		if (isArray)
		{
			if (mPathResolver.EnterArrayOfTables(path, &nodeId) case .Err(let arrErr))
				return .Err(arrErr);
		}
		else
		{
			if (mPathResolver.EnterTable(path, &nodeId) case .Err(let tblErr))
				return .Err(tblErr);
		}
		// The header's position was synced to the resolver at the top of this method
		RecordSourceRange(nodeId, mPathResolver.mCurrentLine, mPathResolver.mCurrentColumn, mPathResolver.mCurrentOffset, headerEnd);

		// Attach pending leading comments and trailing comment to the table node
		if (mMetadata != null && nodeId.IsValid)
		{
			AttachPendingComments(nodeId);
			AttachTrailingComment(nodeId);
			mSeenContent = true;
		}

		return .Ok;
	}

	// ================================================================
	// Key/value pair
	// ================================================================

	private Result<void, TomlParseError> ParseKeyVal()
	{
		SyncPathResolver();

		// Mark key start for raw key text capture
		var keyStart = TomlCursorMark();
		if (mMetadata != null)
			keyStart = mCursor.Mark();

		var keyPath = scope List<String>();
		defer { ClearAndDeleteItems!(keyPath); }
		if (ParseKeyPath(keyPath) case .Err(let e))
			return .Err(e);

		// Detect dotted key usage for document style inference
		if (mMetadata != null && keyPath.Count > 1)
			mMetadata.mDocumentStyle.mPreferDottedKeys = true;

		// Capture raw key text for key format detection
		// Slice now before value parsing can invalidate the stream buffer
		StringView rawKeyText = StringView();
		String rawKeyScratch = scope String();
		TomlKeyStyle keyStyle = .Bare;
		if (mMetadata != null)
		{
			rawKeyText = mCursor.Slice(keyStart, rawKeyScratch);
			// Detect key style immediately while the view is valid
			if (!rawKeyText.IsEmpty)
			{
				char8 c = rawKeyText[0];
				if (c == '"')
					keyStyle = .QuotedBasic;
				else if (c == '\'')
					keyStyle = .QuotedLiteral;
			}
		}

		mCursor.SkipWhitespace();
		if (mCursor.PeekByte() != '=')
			return .Err(Error(.UnexpectedToken, "Expected '='"));
		mCursor.AdvanceByte();

		mCursor.SkipWhitespace();

		// Mark value start for raw token capture
		var valueStart = TomlCursorMark();
		bool capturingToken = mMetadata != null;
		if (capturingToken)
			valueStart = mCursor.Mark();

		TomlValue value = ?;
		switch (ParseValue())
		{
		case .Err(let valErr): return .Err(valErr);
		case .Ok(let val): value = val;
		}

		int valueEnd = mCursor.Offset;
		// The resolver reports errors at the key start, synced at the top of this method
		TomlNodeId nodeId = .Invalid;
		if (mPathResolver.SetKeyValue(keyPath, value, &nodeId) case .Err(let insertErr))
		{

			return .Err(insertErr);
		}
		RecordSourceRange(nodeId, mPathResolver.mCurrentLine, mPathResolver.mCurrentColumn, mPathResolver.mCurrentOffset, valueEnd);

		// Capture raw value token and format metadata. Slicing always releases the value mark.
		if (capturingToken)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			CaptureValueMetadata(nodeId, value, rawToken, keyStyle, keyPath.Count > 1);
		}

		// Attach pending leading comments and track this node for trailing comments
		if (mMetadata != null && nodeId.IsValid)
		{
			AttachPendingComments(nodeId);
			mLastNodeId = nodeId;
			mSeenContent = true;
		}

		return .Ok;
	}

	// ================================================================
	// Key path parsing
	// ================================================================

	private Result<void, TomlParseError> ParseKeyPath(List<String> parts)
	{
		switch (ParseSimpleKey())
		{
		case .Err(let err): return .Err(err);
		case .Ok(let firstKey): parts.Add(firstKey);
		}

		while (true)
		{
			mCursor.SkipWhitespace();
			if (mCursor.IsEOF || mCursor.PeekByte() != '.')
				break;

			mCursor.AdvanceByte();
			mCursor.SkipWhitespace();

			switch (ParseSimpleKey())
			{
			case .Err(let err): return .Err(err);
			case .Ok(let key): parts.Add(key);
			}
		}

		Try!(CheckPathSegments(parts.Count));
		return .Ok;
	}

	private Result<String, TomlParseError> ParseSimpleKey()
	{
		char8 b = mCursor.PeekByte();

		if (b == '"')
			return ParseBasicStringKey();
		if (b == '\'')
			return ParseLiteralStringKey();
		return ParseBareKey();
	}

	private Result<String, TomlParseError> ParseBareKey()
	{
		let mark = mCursor.Mark();

		if (!mCursor.IsEOF && TomlChar.IsBareKeyChar(mCursor.PeekByte()))
		{
			mCursor.AdvanceByte();
		}
		else
		{
			return .Err(Error(.InvalidKey, "Invalid bare key"));
		}

		while (!mCursor.IsEOF && TomlChar.IsBareKeyChar(mCursor.PeekByte()))
			mCursor.AdvanceByte();

		String scratch = scope String();
		StringView sv = mCursor.Slice(mark, scratch);
		return new String(sv);
	}

	private Result<String, TomlParseError> ParseBasicStringKey()
	{
		mCursor.AdvanceByte();

		String result = new String();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '"')
			{
				mCursor.AdvanceByte();
				return result;
			}
			if (b == '\\')
			{
				mCursor.AdvanceByte();
				switch (ParseEscapeSequence(result))
				{
				case .Err(let err):
					delete result;
					return .Err(err);
				default:
				}
				continue;
			}
			if (b == '\r' || b == '\n')
			{
				delete result;
				return .Err(Error(.UnterminatedString, "Unterminated string key"));
			}
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				delete result;
				return .Err(Error(.ControlCharInString, "Control character in string key"));
			}
			result.Append(mCursor.Advance());
		}

		delete result;
		return .Err(Error(.UnterminatedString, "Unterminated string key"));
	}

	private Result<String, TomlParseError> ParseLiteralStringKey()
	{
		mCursor.AdvanceByte(); // skip opening '
		let mark = mCursor.Mark();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\'')
			{
				String scratch = scope String();
				StringView sv = mCursor.Slice(mark, scratch);
				mCursor.AdvanceByte(); // skip closing '
				return new String(sv);
			}
			if (b == '\r' || b == '\n')
				return .Err(Error(.UnterminatedString, "Unterminated string key"));
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInString, "Control character in string key"));
			mCursor.AdvanceByte();
		}

		return .Err(Error(.UnterminatedString, "Unterminated string key"));
	}

	// ================================================================
	// Helpers
	// ================================================================

	/// Skips whitespace and comments. In arrays, newlines are allowed; in inline tables, they are not.
	private Result<void, TomlParseError> SkipWsAndComments(bool allowNewlines = true)
	{
		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == ' ' || b == '\t') { mCursor.AdvanceByte(); continue; }
			if (b == '#')
			{
				if (SkipCommentText() case .Err(let e))
					return .Err(e);
				continue;
			}
			if (allowNewlines && (b == '\r' || b == '\n')) { CountAndSkipNewline(); continue; }
			break;
		}
		return .Ok;
	}

	/// Skip whitespace and newlines (for arrays), capturing comments into the provided list.
	/// When outComments is null or mMetadata is null, behaves like SkipWsAndComments(true).
	/// @param outComments Optional list to collect captured comment text. Ownership remains with caller.
	/// @param outBlankLine Set to true if a blank line was encountered (consecutive newlines).
	private Result<void, TomlParseError> SkipWsAndCaptureComments(List<String> outComments, out bool outBlankLine)
	{
		outBlankLine = false;
		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == ' ' || b == '\t') { mCursor.AdvanceByte(); continue; }
			if (b == '#')
			{
				if (outComments != null && mMetadata != null)
				{
					String text = new String();
					if (CaptureCommentText(text) case .Err(let e))
					{
						delete text;
						return .Err(e);
					}
					outComments.Add(text);
				}
				else
				{
					if (SkipCommentText() case .Err(let e))
						return .Err(e);
				}
				continue;
			}
			if (b == '\r' || b == '\n')
			{
				// Track blank lines
				CountAndSkipNewline();
				if (outComments != null && mMetadata != null)
				{
					// Check for additional newlines = blank line
					mCursor.SkipWhitespace();
					while (!mCursor.IsEOF)
					{
						char8 nb = mCursor.PeekByte();
						if (nb == '\r' || nb == '\n')
						{
							outBlankLine = true;
							CountAndSkipNewline();
							mCursor.SkipWhitespace();
						}
						else
							break;
					}
				}
				continue;
			}
			break;
		}
		return .Ok;
	}

	private void SyncPathResolver()
	{
		mPathResolver.mCurrentLine = mCursor.Line;
		mPathResolver.mCurrentColumn = mCursor.Column;
		mPathResolver.mCurrentOffset = mCursor.Offset;
	}

	/// @brief Copy a scratch string into the document store.
	/// Always frees the scratch string, including when the string length limit is exceeded.
	private Result<TomlValue, TomlParseError> FinishStringValue(String result)
	{
		if (CheckStringLength(result.Length) case .Err(let limitErr))
		{
			delete result;
			return .Err(limitErr);
		}
		String owned = mStore.NewString(result);
		delete result;
		return .Ok(TomlValue.String(owned));
	}

	private TomlParseError Error(TomlErrorKind kind, StringView message)
	{
		return TomlParseError(kind, message, mCursor.Line, mCursor.Column, mCursor.Offset);
	}

	private Result<void, TomlParseError> CheckDepth()
	{
		if (mLimits != null)
			return mLimits.CheckDepth(mDepth, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	private Result<void, TomlParseError> CheckStringLength(int byteLength)
	{
		if (mLimits != null)
			return mLimits.CheckStringBytes(byteLength, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	private Result<void, TomlParseError> CheckNodeCount()
	{
		if (mLimits != null)
			return mLimits.CheckNodeCount(mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	private Result<void, TomlParseError> CheckArrayItem(TomlArray arr)
	{
		if (mLimits != null)
			return mLimits.CheckArrayItem(arr, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	private Result<void, TomlParseError> CheckTableEntry(TomlTable tbl)
	{
		if (mLimits != null)
			return mLimits.CheckTableEntry(tbl, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	private Result<void, TomlParseError> CheckPathSegments(int count)
	{
		if (mLimits != null)
			return mLimits.CheckPathSegments(count, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}
}
