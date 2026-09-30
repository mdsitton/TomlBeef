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
	// Node IDs and source ranges go to mMetadata (Positions or PreserveStyle). Comments, original tokens,
	// formats and document style go to mStyle, which is the same sidecar in PreserveStyle and null otherwise.
	private TomlDocumentMetadata mMetadata;
	private TomlDocumentMetadata mStyle;
	// mMetadata's index for this input's SourceName (-1 if unnamed or without metadata)
	private int32 mSourceIndex;
	private TomlDocumentStore mStore;
	private int mDepth = 0;
	// Table levels above the keys being parsed that key paths built (the current header's segments,
	// and the parent segments of dotted keys whose values are being parsed); with mDepth, bounds the
	// depth of the table tree, which sealing, writing and merging walk recursively
	private int mKeyDepth = 0;
	private TomlResourceLimitState mLimits;
	// Offset just past the last key segment ParseKeyPath read (before any whitespace), for '=' spacing
	private int mLastKeyEnd;
	// Offset just past the last bare value's token, excluding the spaces its scan takes (see ValueEnd)
	private int mValueEnd;
	// Layout of the array or inline table ParseValue last finished (PreserveStyle; see FinishArrayLayout)
	private TomlArrayFormat mLastArrayFormat;
	private TomlTableFormat mLastTableFormat;

	// Pending leading comments waiting to be attached to the next node. Comment text is stored in the
	// sidecar's text arena as soon as it is read (see CaptureComment), so these are plain views.
	private List<StringView> mPendingComments ~ delete _;
	// Pending trailing comment text waiting to be attached to the current node (absent if none).
	private StringView mTrailingCommentText;
	// Reused buffer a comment is read into before it is copied to the arena
	private String mCommentScratch ~ delete _;
	// Reused buffer for string values while they are decoded; strings never nest, and the finished
	// value is copied into the store, so one buffer serves the whole parse without per-string allocations.
	private String mStringScratch ~ delete _;
	// Reused scratch for cursor slices of bare values (only filled when a stream read spills)
	private String mSliceScratch ~ delete _;
	// Key-path buffers by nesting level (see AcquireKeyPath), reused for every key of the parse.
	private List<TomlKeyPathBuffer> mKeyPathPool ~ DeleteContainerAndItems!(_);
	private int mKeyPathDepth;
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
	private int mArrayTrailingCommaCount;
	private int mArrayNoTrailingCommaCount;
	private int mCrlfCount;
	private int mLfOnlyCount;

	/// @param store The store that owns every value the parser creates. Required.
	/// @param metadata The sidecar to capture into, or null when not capturing. Its mode decides whether
	/// style is captured or only positions.
	public this(TomlReadConfig config, TomlDocumentStore store, TomlDocumentMetadata metadata, TomlResourceLimitState externalLimits = null)
	{
		Runtime.Assert(store != null, "TomlParserImpl requires a store");
		mVersion = config.Version;
		mLimits = externalLimits;
		mStore = store;
		mMetadata = metadata;
		mStyle = (metadata != null && metadata.CapturesStyle) ? metadata : null;
		mSourceIndex = (metadata != null) ? metadata.AddSource(config.SourceName) : -1;
		// Comment buffers only exist when style is captured (every use is behind mStyle != null). The
		// string scratch keeps its capacity: starting empty made every parse regrow it (-14% on strings).
		// The slice scratch is only filled when a stream read spills, so it starts without a buffer.
		if (mStyle != null)
		{
			mPendingComments = new List<StringView>();
			mCommentScratch = new String(128);
		}
		mTrailingCommentText = default;
		mStringScratch = new String(64);
		mSliceScratch = new String();
		mKeyPathPool = new List<TomlKeyPathBuffer>();
		mKeyPathDepth = 0;
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
		mArrayTrailingCommaCount = 0;
		mArrayNoTrailingCommaCount = 0;
		mCrlfCount = 0;
		mLfOnlyCount = 0;
	}

	public Result<void, TomlParseError> Parse(TCursor cursor, TomlPathResolver resolver)
	{
		mCursor = cursor;
		mPathResolver = resolver;
		mPathResolver.Reset();
		mDepth = 0;
		mKeyDepth = 0;

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
				if (mBlankLineSinceComment && !mSeenContent && mStyle != null && mPendingComments.Count > 0)
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
				// blank-line marker (consecutive blank lines collapse to one)
				if (mStyle != null)
				{
					if (mPendingComments.Count > 0)
					{
						mBlankLineSinceComment = true;
						if (!TomlCommentSet.IsAbsent(mPendingComments.Back))
							mPendingComments.Add(TomlCommentSet.BlankLine);
					}
					else
						mBlankLineCount++;
				}
				Try!(CountAndSkipNewline());
				continue;
			}

			if (b == '[')
			{
				// If a blank line separated pending comments from this header,
				// and we haven't seen content yet, flush to root (file header comments)
				if (mBlankLineSinceComment && !mSeenContent && mStyle != null && mPendingComments.Count > 0)
					AttachPendingCommentsToRoot();
				mBlankLineSinceComment = false;

				// Save blank line count for header comment attachment, then reset
				if (mStyle != null)
					mSavedBlankLineCount = mBlankLineCount;
				mBlankLineCount = 0;

				// Detect indentation from whitespace before first content
				if (!mInferredIndent && mStyle != null)
				{
					// SkipWhitespace was already called at loop top.
					// Use cursor column as indent depth. Only update if indented.
					if (mCursor.Column > 1)
					{
						mStyle.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
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
			if (mBlankLineSinceComment && !mSeenContent && mStyle != null && mPendingComments.Count > 0)
				AttachPendingCommentsToRoot();
			mBlankLineSinceComment = false;
			if (mStyle != null)
				mSavedBlankLineCount = mBlankLineCount;
			mBlankLineCount = 0;

			// Detect indentation from whitespace before first content
			if (!mInferredIndent && mStyle != null)
			{
				if (mCursor.Column > 1)
				{
					mStyle.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
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
					if (mStyle != null && mLastNodeId.IsValid)
						AttachTrailingComment(mLastNodeId);
				}
				else if (afterB != '\r' && afterB != '\n')
					return .Err(Error(.MissingNewlineAfterKeyVal, "Expected newline after key/value pair"));
				else
				{
					Try!(CountAndSkipNewline());
				}
			}
		}

		// Attach any remaining pending comments
		if (mStyle != null && mPendingComments.Count > 0)
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

		// A header path starts from the root
		mKeyDepth = 0;
		let pathBuffer = AcquireKeyPath();
		defer ReleaseKeyPath();
		let path = pathBuffer.mParts;
		if (ParseKeyPath(pathBuffer) case .Err(let e))
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
				Try!(CountAndSkipNewline());
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
		mKeyDepth = path.Count + (isArray ? 1 : 0);
		// The header's position was synced to the resolver at the top of this method
		RecordSourceRange(nodeId, mPathResolver.mCurrentLine, mPathResolver.mCurrentColumn, mPathResolver.mCurrentOffset, headerEnd);

		// Attach pending leading comments and trailing comment to the table node
		if (mStyle != null && nodeId.IsValid)
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
		if (mStyle != null)
			keyStart = mCursor.Mark();

		let keyPathBuffer = AcquireKeyPath();
		defer ReleaseKeyPath();
		let keyPath = keyPathBuffer.mParts;
		if (ParseKeyPath(keyPathBuffer) case .Err(let e))
			return .Err(e);

		// Detect dotted key usage for document style inference
		if (mStyle != null && keyPath.Count > 1)
			mStyle.mDocumentStyle.mPreferDottedKeys = true;

		// Capture raw key text for key format detection
		// Slice now before value parsing can invalidate the stream buffer
		StringView rawKeyText = StringView();
		String rawKeyScratch = scope String();
		TomlKeyStyle keyStyle = .Bare;
		if (mStyle != null)
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

		// A full table fails before its new value is parsed (dotted keys are checked as they insert)
		if (keyPath.Count == 1)
			Try!(mPathResolver.CheckCurrentTableRoom(keyPath[0]));

		// Mark value start for raw token capture. Containers record their layout while they are parsed,
		// so only scalars need (and retain) their text.
		var valueStart = TomlCursorMark();
		bool capturingToken = mStyle != null && !IsContainerStart(mCursor.PeekByte());
		if (capturingToken)
			valueStart = mCursor.Mark();

		TomlValue value = ?;
		mKeyDepth += keyPath.Count - 1;
		let parsed = ParseValue();
		mKeyDepth -= keyPath.Count - 1;
		switch (parsed)
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
		if (mStyle != null)
		{
			String scratch = scope String();
			StringView rawToken = capturingToken ? mCursor.Slice(valueStart, scratch) : default;
			CaptureValueMetadata(nodeId, value, rawToken, keyStyle, keyPath.Count > 1);
		}

		// Attach pending leading comments and track this node for trailing comments
		if (mStyle != null && nodeId.IsValid)
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

	/// Takes the key-path buffer for the current nesting level. Keys nest (an inline table inside a value
	/// parses its own keys while the enclosing key path is still in use), so there is one buffer per level;
	/// pair every call with ReleaseKeyPath, e.g. through `defer`.
	private TomlKeyPathBuffer AcquireKeyPath()
	{
		if (mKeyPathDepth == mKeyPathPool.Count)
			mKeyPathPool.Add(new TomlKeyPathBuffer());
		let buffer = mKeyPathPool[mKeyPathDepth++];
		buffer.Reset();
		return buffer;
	}

	private void ReleaseKeyPath()
	{
		mKeyPathDepth--;
	}

	private Result<void, TomlParseError> ParseKeyPath(TomlKeyPathBuffer parts)
	{
		while (true)
		{
			// Limits are checked before each segment, so a huge path stops where it crosses them. Each
			// segment is one more table level below the one receiving the key.
			int count = parts.mParts.Count + 1;
			Try!(CheckPathSegments(count));
			if (mLimits != null && mKeyDepth + mDepth + count > mLimits.mMaxDepth)
				return mLimits.CheckDepth(mLimits.mMaxDepth, mCursor.Line, mCursor.Column, mCursor.Offset);
			Try!(ParseSimpleKey(parts.Add()));
			mLastKeyEnd = mCursor.Offset;

			mCursor.SkipWhitespace();
			if (mCursor.IsEOF || mCursor.PeekByte() != '.')
				break;

			mCursor.AdvanceByte();
			mCursor.SkipWhitespace();
		}
		return .Ok;
	}

	/// Parses one key segment (bare, "basic" or 'literal') into `key`, which arrives empty.
	private Result<void, TomlParseError> ParseSimpleKey(String key)
	{
		char8 b = mCursor.PeekByte();

		if (b == '"')
			return ParseBasicStringKey(key);
		if (b == '\'')
			return ParseLiteralStringKey(key);
		return ParseBareKey(key);
	}

	private Result<void, TomlParseError> ParseBareKey(String key)
	{
		if (mCursor.ScanRun(TomlChar.StopBareKey, key) == 0)
			return .Err(Error(.InvalidKey, "Invalid bare key"));
		return .Ok;
	}

	private Result<void, TomlParseError> ParseBasicStringKey(String result)
	{
		mCursor.AdvanceByte();
		return DecodeBasicString(result, true);
	}

	private Result<void, TomlParseError> ParseLiteralStringKey(String key)
	{
		mCursor.AdvanceByte(); // skip opening '
		mCursor.ScanRun(TomlChar.StopLiteralString, key);
		bool eof = mCursor.IsEOF;
		char8 b = eof ? '\0' : mCursor.PeekByte();
		if (!eof && b == '\'')
		{
			mCursor.AdvanceByte(); // skip closing '
			return .Ok;
		}
		// The run stopped at EOF, a newline, or a control character
		if (eof || b == '\r' || b == '\n')
			return .Err(Error(.UnterminatedString, "Unterminated string key"));
		return .Err(Error(.ControlCharInString, "Control character in string key"));
	}

	// ================================================================
	// Helpers
	// ================================================================

	/// Skips whitespace and comments. In arrays, newlines are allowed; in inline tables, they are not.
	private Result<void, TomlParseError> SkipWsAndComments(bool allowNewlines = true)
	{
		while (true)
		{
			mCursor.SkipWhitespace();
			if (mCursor.IsEOF)
				break;
			char8 b = mCursor.PeekByte();
			if (b == '#')
			{
				// A comment runs to the end of the line, so it needs the newline this context forbids
				if (!allowNewlines)
					return .Err(Error(.UnexpectedToken, "Comments inside inline tables require TOML v1.1"));
				if (SkipCommentText() case .Err(let e))
					return .Err(e);
				continue;
			}
			if (allowNewlines && (b == '\r' || b == '\n')) { Try!(CountAndSkipNewline()); continue; }
			break;
		}
		return .Ok;
	}

	/// Skip whitespace and newlines (for arrays), capturing comments into the provided list.
	/// When outComments is null or style is not captured, behaves like SkipWsAndComments(true).
	/// @param outComments Optional list to collect captured comment text. Ownership remains with caller.
	/// @param outBlankLine Set to true if a blank line was encountered (consecutive newlines).
	private Result<void, TomlParseError> SkipWsAndCaptureComments(List<StringView> outComments, out bool outBlankLine)
	{
		outBlankLine = false;
		while (true)
		{
			mCursor.SkipWhitespace();
			if (mCursor.IsEOF)
				break;
			char8 b = mCursor.PeekByte();
			if (b == '#')
			{
				if (outComments != null && mStyle != null)
					outComments.Add(Try!(CaptureComment()));
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
				Try!(CountAndSkipNewline());
				// The first indented container line tells the document's indent character
				if (mStyle != null && !mIndentCharKnown && (mCursor.PeekByte() == ' ' || mCursor.PeekByte() == '\t'))
					NoteIndentChar(mCursor.PeekByte());
				if (outComments != null && mStyle != null)
				{
					// Check for additional newlines = blank line
					mCursor.SkipWhitespace();
					while (!mCursor.IsEOF)
					{
						char8 nb = mCursor.PeekByte();
						if (nb == '\r' || nb == '\n')
						{
							outBlankLine = true;
							Try!(CountAndSkipNewline());
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
	/// Copies a decoded string (the scratch buffer) into the store as a value.
	private Result<TomlValue, TomlParseError> FinishStringValue(String result)
	{
		Try!(CheckStringLength(result.Length));
		return .Ok(TomlValue.String(mStore.NewString(result)));
	}

	private TomlParseError Error(TomlErrorKind kind, StringView message)
	{
		return TomlParseError(kind, message, mCursor.Line, mCursor.Column, mCursor.Offset);
	}

	// Limit checks run for every value, key and container, so each compares inline and only calls into
	// the limit state (which builds the error) when a limit is set and exceeded.

	[Inline]
	private Result<void, TomlParseError> CheckDepth()
	{
		if (mLimits != null && mDepth >= mLimits.mMaxDepth)
			return mLimits.CheckDepth(mDepth, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	[Inline]
	private Result<void, TomlParseError> CheckStringLength(int byteLength)
	{
		if (mLimits != null && mLimits.mMaxStringBytes > 0 && byteLength > mLimits.mMaxStringBytes)
			return mLimits.CheckStringBytes(byteLength, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	/// The longest decoded string MaxStringBytes allows (int.MaxValue without that limit). String loops
	/// check against it as the string grows, so an oversized string stops where it crosses the limit.
	private int StringByteLimit => (mLimits != null && mLimits.mMaxStringBytes > 0) ? mLimits.mMaxStringBytes : int.MaxValue;

	[Inline]
	private Result<void, TomlParseError> CheckNodeCount()
	{
		// Counting nodes only matters with a node limit
		if (mLimits != null && mLimits.mMaxNodes > 0)
			return mLimits.CheckNodeCount(mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	[Inline]
	private Result<void, TomlParseError> CheckArrayItem(TomlArray arr)
	{
		if (mLimits != null && mLimits.mMaxArrayItems > 0 && arr.Count >= mLimits.mMaxArrayItems)
			return mLimits.CheckArrayItem(arr, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	[Inline]
	private Result<void, TomlParseError> CheckTableEntry(TomlTable tbl)
	{
		if (mLimits != null && mLimits.mMaxTableEntries > 0 && tbl.Count >= mLimits.mMaxTableEntries)
			return mLimits.CheckTableEntry(tbl, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}

	[Inline]
	private Result<void, TomlParseError> CheckPathSegments(int count)
	{
		if (mLimits != null && mLimits.mMaxPathSegments > 0 && count > mLimits.mMaxPathSegments)
			return mLimits.CheckPathSegments(count, mCursor.Line, mCursor.Column, mCursor.Offset);
		return .Ok;
	}
}
