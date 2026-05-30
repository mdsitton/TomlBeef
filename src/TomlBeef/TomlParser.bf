using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// Recursive descent parser for TOML v1.1.0.
class TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	private TCursor mCursor;
	private TomlPathResolver mPathResolver;
	private TomlVersion mVersion;
	private TomlDocumentMetadata mMetadata;
	private int mDepth = 0;
	private const int mMaxDepth = 256;

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
	// String style usage counts for detecting the dominant style.
	private int mStringStyleCount_Basic;
	private int mStringStyleCount_Literal;
	private int mStringStyleCount_MultilineBasic;
	private int mStringStyleCount_MultilineLiteral;
	private int mArrayStyleCount_Inline;
	private int mArrayStyleCount_Multiline;
	private int mCrlfCount;
	private int mLfOnlyCount;

	public this(TomlVersion version = .V1_1)
	{
		mVersion = version;
		mMetadata = null;
		mPendingComments = new List<String>();
		mTrailingCommentText = null;
		mSeenContent = false;
		mLastNodeId = .Invalid;
		mBlankLineSinceComment = false;
		mBlankLineCount = 0;
		mSavedBlankLineCount = 0;
		mInferredIndent = false;
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

	public void SetMetadata(TomlDocumentMetadata metadata)
	{
		mMetadata = metadata;
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
				// Track blank lines for comment classification and section spacing
				if (mMetadata != null && mPendingComments.Count > 0)
					mBlankLineSinceComment = true;
				if (mMetadata != null)
					mBlankLineCount++;
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
						mMetadata.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
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
					mMetadata.mDocumentStyle.mIndentSize = (uint8)(mCursor.Column - 1);
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

		SyncPathResolver();
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

		SyncPathResolver();
		TomlNodeId nodeId = .Invalid;
		if (mPathResolver.SetKeyValue(keyPath, value, &nodeId) case .Err(let insertErr))
		{
			value.Dispose();
			return .Err(insertErr);
		}

		// Capture raw value token if metadata is enabled and value is a string
		if (capturingToken && nodeId.IsValid && value.IsString)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			let tokenRef = mMetadata.AddOriginalToken(rawToken);
			let style = mMetadata.GetNodeStyle(nodeId);
			if (style != null)
				style.mOriginalValueToken = tokenRef;
			CaptureStringFormat(nodeId, rawToken);
		}
		else if (capturingToken && nodeId.IsValid && (value.IsInteger || value.IsFloat))
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			CaptureNumericFormat(nodeId, rawToken);
		}
		else if (capturingToken && nodeId.IsValid && value.IsArray)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			CaptureArrayFormat(nodeId, rawToken, value.AsArray?.mHasTrailingComma ?? false);
		}
		else if (capturingToken && nodeId.IsValid && value.IsTable)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			CaptureTableFormat(nodeId, rawToken, value.AsTable?.mHasTrailingComma ?? false);
		}

		// Capture key format metadata
		if (capturingToken && nodeId.IsValid)
			CaptureKeyFormat(nodeId, keyStyle, keyPath.Count > 1);

		// Capture date-time format metadata
		if (capturingToken && nodeId.IsValid && (value.IsOffsetDateTime || value.IsLocalDateTime || value.IsLocalDate || value.IsLocalTime))
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(valueStart, scratch);
			CaptureDateTimeFormat(nodeId, rawToken);
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
	// Value parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseValue()
	{
		if (mDepth >= mMaxDepth)
			return .Err(Error(.MaxDepthExceeded, "Maximum nesting depth exceeded"));
		mDepth++;
		defer { mDepth--; }

		char8 b = mCursor.PeekByte();

		switch (b)
		{
		case '"':
			return ParseString();
		case '\'':
			return ParseLiteralString();
		case '[':
			return ParseArray();
		case '{':
			return ParseInlineTable();
		case 't','f':
			return ParseBool();
		default:
			return ParseBareValue();
		}
	}

	// ================================================================
	// String parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseString()
	{
		if (mCursor.PeekByte() == '"' && mCursor.PeekByteAt(1) == '"' && mCursor.PeekByteAt(2) == '"')
		{
			CountStringStyle(.MultilineBasic);
			return ParseMultiLineBasicString();
		}
		CountStringStyle(.Basic);
		return ParseBasicString();
	}

	private Result<TomlValue, TomlParseError> ParseLiteralString()
	{
		if (mCursor.PeekByte() == '\'' && mCursor.PeekByteAt(1) == '\'' && mCursor.PeekByteAt(2) == '\'')
		{
			CountStringStyle(.MultilineLiteral);
			return ParseMultiLineLiteralString();
		}
		CountStringStyle(.Literal);
		return ParseSingleLineLiteralString();
	}

	private Result<TomlValue, TomlParseError> ParseBasicString()
	{
		mCursor.AdvanceByte();
		String result = new String();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '"')
			{
				mCursor.AdvanceByte();
				return TomlValue.String(result);
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
				return .Err(Error(.UnterminatedString, "Unterminated basic string"));
			}
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				delete result;
				return .Err(Error(.ControlCharInString, "Control character in basic string"));
			}
			result.Append(mCursor.Advance());
		}

		delete result;
		return .Err(Error(.UnterminatedString, "Unterminated basic string"));
	}

	private Result<TomlValue, TomlParseError> ParseMultiLineBasicString()
	{
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			mCursor.SkipNewline();

		String result = new String();

		while (!mCursor.IsEOF)
		{
			if (mCursor.PeekByte() == '"' && mCursor.PeekByteAt(1) == '"' && mCursor.PeekByteAt(2) == '"')
			{
				// Count consecutive quotes
				int quoteCount = 3;
				while (mCursor.PeekByteAt(quoteCount) == '"')
					quoteCount++;

				if (quoteCount == 3)
				{
					// Exactly 3 quotes: closing delimiter
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					return TomlValue.String(result);
				}
				else if (quoteCount == 4)
				{
					// 4 quotes: 1 literal quote, then 3 closing quotes
					result.Append('"');
					mCursor.AdvanceByte(); // consume the 1 literal
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte(); // consuming closing
					return TomlValue.String(result);
				}
				else if (quoteCount == 5)
				{
					// 5 quotes: 2 literal quotes, then 3 closing quotes
					result.Append('"');
					result.Append('"');
					mCursor.AdvanceByte();
					mCursor.AdvanceByte(); // consume 2 literal
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte(); // consuming closing
					return TomlValue.String(result);
				}
				else
				{
					// 6+ consecutive unescaped quotes not allowed
					delete result;
					return .Err(Error(.InvalidEscape, "Six or more consecutive quotes in multi-line basic string must be escaped"));
				}
			}

			char8 b = mCursor.PeekByte();

			if (b == '\\')
			{
				mCursor.AdvanceByte();

				int peekPos = 0;
				while (true)
				{
					char8 pb = mCursor.PeekByteAt(peekPos);
					if (pb == ' ' || pb == '\t') { peekPos++; continue; }
					break;
				}
				char8 nextNonWs = mCursor.PeekByteAt(peekPos);
				if (nextNonWs == '\r' || nextNonWs == '\n')
				{
					mCursor.SkipWhitespace();
					while (!mCursor.IsEOF && (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n'))
						mCursor.SkipNewline();
					mCursor.SkipWhitespace();
					continue;
				}

				switch (ParseEscapeSequence(result))
				{
				case .Err(let err):
					delete result;
					return .Err(err);
				default:
				}
				continue;
			}

			if (b == '\r')
			{
				// CR must be part of CRLF in multiline basic string
				if (mCursor.PeekByteAt(1) == '\n')
				{
					mCursor.AdvanceByte(); // consumes \r\n together (CRLF merging)
					result.Append('\n');
				}
				else
				{
					delete result;
					return .Err(Error(.ControlCharInString, "Bare CR not allowed in multiline basic string"));
				}
				continue;
			}
			if (b == '\n')
			{
				mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}

			// Control chars (except tab, LF, CR)
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				delete result;
				return .Err(Error(.ControlCharInString, "Control character in multi-line basic string"));
			}

			result.Append(mCursor.Advance());
		}

		delete result;
		return .Err(Error(.UnterminatedString, "Unterminated multi-line basic string"));
	}

	private Result<void, TomlParseError> ParseEscapeSequence(String result)
	{
		if (mCursor.IsEOF)
			return .Err(Error(.InvalidEscape, "Unexpected end after '\\'"));

		char8 esc = mCursor.PeekByte();
		mCursor.AdvanceByte();

		switch (esc)
		{
		case 'b': result.Append('\b'); return .Ok;
		case 't': result.Append('\t'); return .Ok;
		case 'n': result.Append('\n'); return .Ok;
		case 'f': result.Append('\f'); return .Ok;
		case 'r': result.Append('\r'); return .Ok;
		case 'e':
			if (mVersion == .V1_0)
				return .Err(Error(.ReservedEscape, "\\e escape requires TOML v1.1"));
			result.Append((char8)0x1B); return .Ok;
		case '"': result.Append('"'); return .Ok;
		case '\\': result.Append('\\'); return .Ok;
		case 'x':
			if (mVersion == .V1_0)
				return .Err(Error(.ReservedEscape, "\\x escape requires TOML v1.1"));
			return ParseHexEscape(result, 2);
		case 'u': return ParseHexEscape(result, 4);
		case 'U': return ParseHexEscape(result, 8);
		default:
			return .Err(Error(.ReservedEscape, scope $"Reserved escape '\\{esc}'"));
		}
	}

	private Result<void, TomlParseError> ParseHexEscape(String result, int digits)
	{
		uint32 cp = 0;

		for (int i = 0; i < digits; i++)
		{
			if (mCursor.IsEOF)
				return .Err(Error(.InvalidEscape, "Incomplete escape sequence"));

			char8 c = mCursor.PeekByte();
			uint8 v = TomlChar.HexDigitValue(c);
			if (v == 255)
				return .Err(Error(.InvalidEscape, "Invalid hex digit"));

			cp = (cp << 4) | v;
			mCursor.AdvanceByte();
		}

		if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
			return .Err(Error(.InvalidUnicodeScalar, "Invalid Unicode scalar value"));

		TomlChar.EncodeUtf8(result, cp);
		return .Ok;
	}

	private Result<TomlValue, TomlParseError> ParseSingleLineLiteralString()
	{
		mCursor.AdvanceByte();
		String result = new String();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\'')
			{
				mCursor.AdvanceByte();
				return TomlValue.String(result);
			}
			if (b == '\r' || b == '\n')
			{
				delete result;
				return .Err(Error(.UnterminatedString, "Unterminated literal string"));
			}
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				delete result;
				return .Err(Error(.ControlCharInString, "Control character in literal string"));
			}
			result.Append(mCursor.Advance());
		}

		delete result;
		return .Err(Error(.UnterminatedString, "Unterminated literal string"));
	}

	private Result<TomlValue, TomlParseError> ParseMultiLineLiteralString()
	{
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			mCursor.SkipNewline();

		String result = new String();

		while (!mCursor.IsEOF)
		{
			if (mCursor.PeekByte() == '\'' && mCursor.PeekByteAt(1) == '\'' && mCursor.PeekByteAt(2) == '\'')
			{
				int quoteCount = 3;
				while (mCursor.PeekByteAt(quoteCount) == '\'')
					quoteCount++;

				if (quoteCount == 3)
				{
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					return TomlValue.String(result);
				}
				else if (quoteCount == 4)
				{
					result.Append('\'');
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					return TomlValue.String(result);
				}
				else if (quoteCount == 5)
				{
					result.Append('\'');
					result.Append('\'');
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					return TomlValue.String(result);
				}
				else
				{
					delete result;
					return .Err(Error(.InvalidEscape, "Six or more consecutive apostrophes in multi-line literal string"));
				}
			}

			char8 b = mCursor.PeekByte();

			if (b == '\r')
			{
				// CR must be part of CRLF in multiline literal string
				if (mCursor.PeekByteAt(1) == '\n')
				{
					mCursor.AdvanceByte(); // consumes \r\n together (CRLF merging)
					result.Append('\n');
				}
				else
				{
					delete result;
					return .Err(Error(.ControlCharInString, "Bare CR not allowed in multiline literal string"));
				}
				continue;
			}
			if (b == '\n')
			{
				mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}

			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				delete result;
				return .Err(Error(.ControlCharInString, "Control character in multi-line literal string"));
			}

			result.Append(mCursor.Advance());
		}

		delete result;
		return .Err(Error(.UnterminatedString, "Unterminated multi-line literal string"));
	}

	// ================================================================
	// Boolean parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseBool()
	{
		let mark = mCursor.Mark();
		while (!mCursor.IsEOF && TomlChar.IsBareValueChar(mCursor.PeekByte()))
			mCursor.AdvanceByte();

		String scratch = scope String();
		StringView token = mCursor.Slice(mark, scratch);

		if (token == "true") return TomlValue.Bool(true);
		if (token == "false") return TomlValue.Bool(false);
		return ParseBareToken(token);
	}

	// ================================================================
	// Bare value parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseBareValue()
	{
		let mark = mCursor.Mark();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\r' || b == '\n' ||
				b == '=' || b == '[' || b == ']' || b == '{' || b == '}' ||
				b == ',' || b == '#')
				break;
			mCursor.AdvanceByte();
		}

		int length = mCursor.Offset - mark.mOffset;
		if (length == 0)
			return .Err(Error(.UnexpectedToken, "Expected value"));

		String scratch = scope String();
		StringView token = mCursor.Slice(mark, scratch);
		token.Trim();
		return ParseBareToken(token);
	}

	private Result<TomlValue, TomlParseError> ParseBareToken(StringView token)
	{
		if (token.IsEmpty)
			return .Err(Error(.UnexpectedToken, "Empty value"));

		if (token == "true") return TomlValue.Bool(true);
		if (token == "false") return TomlValue.Bool(false);

		if (token == "inf" || token == "+inf")
			return TomlValue.Float(double.PositiveInfinity);
		if (token == "-inf")
			return TomlValue.Float(double.NegativeInfinity);
		if (token == "nan" || token == "+nan" || token == "-nan")
			return TomlValue.Float(double.NaN);

		if (LooksLikeDateTime(token))
		{
			switch (TryParseDateTime(token))
			{
			case .Ok(let val): return val;
			case .Err(let dtErr): return .Err(dtErr);
			}
		}

		return ParseNumber(token);
	}

	// ================================================================
	// Number parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseNumber(StringView token)
	{
		if (token.IsEmpty)
			return .Err(Error(.InvalidInteger, "Empty number"));

		bool hasSign = false;
		int pos = 0;

		if (token[pos] == '-') { hasSign = true; pos++; }
		else if (token[pos] == '+') { hasSign = true; pos++; }

		if (pos >= token.Length)
			return .Err(Error(.InvalidInteger, "Expected digits after sign"));

		if (token[pos] == '0' && pos + 1 < token.Length)
		{
			char8 next = token[pos + 1];
			if (next == 'x')
			{
				if (hasSign) return .Err(Error(.InvalidInteger, "Hex integers cannot have a sign"));
				return ParseHexInt(token, pos + 2);
			}
			if (next == 'o')
			{
				if (hasSign) return .Err(Error(.InvalidInteger, "Octal integers cannot have a sign"));
				return ParseOctInt(token, pos + 2);
			}
			if (next == 'b')
			{
				if (hasSign) return .Err(Error(.InvalidInteger, "Binary integers cannot have a sign"));
				return ParseBinInt(token, pos + 2);
			}
		}

		// Leading dot not allowed (e.g., .5, +.7)
		if (token[pos] == '.')
			return .Err(Error(.InvalidFloat, "Leading decimal point not allowed"));

		bool hasDot = false;
		bool hasExp = false;
		int lastDotPos = -1;

		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '.')
			{
				if (hasDot) return .Err(Error(.InvalidFloat, "Multiple decimal points"));
				hasDot = true;
				lastDotPos = i;
			}
			else if (c == 'e' || c == 'E')
			{
				if (hasExp) return .Err(Error(.InvalidFloat, "Multiple exponents"));
				hasExp = true;
				if (i + 1 < token.Length && (token[i + 1] == '+' || token[i + 1] == '-'))
					i++;
			}
			else if (c == '_')
			{
				if (i == pos || i == token.Length - 1)
					return .Err(Error(.InvalidUnderscore, "Leading or trailing underscore"));
				char8 prev = token[i - 1];
				char8 nextC = (i + 1 < token.Length) ? token[i + 1] : (char8)0;
				if (!TomlChar.IsDigit(prev) || !TomlChar.IsDigit(nextC))
					return .Err(Error(.InvalidUnderscore, "Underscore must be between digits"));
			}
			else if (!TomlChar.IsDigit(c))
			{
				return .Err(Error(.InvalidFloat, scope $"Invalid character '{c}' in number"));
			}
		}

		// Trailing dot not allowed (e.g., 7., 1.e2)
		if (hasDot)
		{
			int afterDot = lastDotPos + 1;
			// Skip underscores
			while (afterDot < token.Length && token[afterDot] == '_')
				afterDot++;
			// Must have at least one digit after the decimal point
			if (afterDot >= token.Length || !TomlChar.IsDigit(token[afterDot]))
				return .Err(Error(.InvalidFloat, "Decimal point must be followed by at least one digit"));
		}

		// Leading zero not allowed for decimal integers AND floats
		// Check from the start of digits (pos) that no leading zero followed by more digits
		if (token.Length > pos && token[pos] == '0')
		{
			// Look past underscores to find the first non-underscore character after the leading zero
			int lookPos = pos + 1;
			while (lookPos < token.Length && token[lookPos] == '_')
				lookPos++;
			if (lookPos < token.Length)
			{
				char8 afterZero = token[lookPos];
				if (afterZero >= '0' && afterZero <= '9')
					return .Err(Error(.LeadingZero, "Leading zeros not allowed"));
			}
		}

		if (!hasDot && !hasExp)
		{
			// Additional check: the integer part must not have leading zero followed by another digit
			// Already covered above
		}

		if (hasDot || hasExp)
			return ParseFloatToken(token);

		return ParseDecimalInt(token);
	}

	private Result<TomlValue, TomlParseError> ParseDecimalInt(StringView token)
	{
		bool negative = false;
		int pos = 0;
		if (token[pos] == '-') { negative = true; pos++; }
		else if (token[pos] == '+') { pos++; }

		uint64 uval = 0;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_') continue;
			uint64 digit = (uint64)(c - '0');
			if (uval > (0xFFFFFFFFFFFFFFFF - digit) / 10)
				return .Err(Error(.IntegerOverflow, "Integer overflow"));
			uval = uval * 10 + digit;
		}

		if (negative)
		{
			if (uval > 0x8000000000000000)
				return .Err(Error(.IntegerOverflow, "Integer overflow"));
			if (uval == 0x8000000000000000)
				return TomlValue.Integer(-9223372036854775808);
			return TomlValue.Integer(-(int64)uval);
		}
		else
		{
			if (uval > 0x7FFFFFFFFFFFFFFF)
				return .Err(Error(.IntegerOverflow, "Integer overflow"));
			return TomlValue.Integer((int64)uval);
		}
	}

	private Result<TomlValue, TomlParseError> ParseHexInt(StringView token, int pos)
	{
		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_')
			{
				if (i == pos || i == token.Length - 1)
					return .Err(Error(.InvalidUnderscore, "Leading or trailing underscore in hex integer"));
				char8 prev = token[i - 1];
				char8 nextC = token[i + 1];
				if (!TomlChar.IsHexDigit(prev) || !TomlChar.IsHexDigit(nextC))
					return .Err(Error(.InvalidUnderscore, "Underscore must be between hex digits"));
				continue;
			}
			uint8 hv = TomlChar.HexDigitValue(c);
			if (hv == 255)
				return .Err(Error(.InvalidInteger, scope $"Invalid hex digit '{c}'"));
			uint64 digit = (uint64)hv;

			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 16)
				return .Err(Error(.IntegerOverflow, "Hex integer overflow"));
			val = val * 16 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in hex integer"));
		if (val > 0x7FFFFFFFFFFFFFFF)
			return .Err(Error(.IntegerOverflow, "Hex integer exceeds signed 64-bit range"));
		return TomlValue.Integer((int64)val);
	}

	private Result<TomlValue, TomlParseError> ParseOctInt(StringView token, int pos)
	{
		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_')
			{
				if (i == pos || i == token.Length - 1)
					return .Err(Error(.InvalidUnderscore, "Leading or trailing underscore in octal integer"));
				char8 prev = token[i - 1];
				char8 nextC = token[i + 1];
				if (!TomlChar.IsOctalDigit(prev) || !TomlChar.IsOctalDigit(nextC))
					return .Err(Error(.InvalidUnderscore, "Underscore must be between octal digits"));
				continue;
			}
			if (c < '0' || c > '7') return .Err(Error(.InvalidInteger, scope $"Invalid octal digit '{c}'"));
			uint64 digit = (uint64)(c - '0');
			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 8)
				return .Err(Error(.IntegerOverflow, "Octal integer overflow"));
			val = val * 8 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in octal integer"));
		if (val > 0x7FFFFFFFFFFFFFFF)
			return .Err(Error(.IntegerOverflow, "Octal integer exceeds signed 64-bit range"));
		return TomlValue.Integer((int64)val);
	}

	private Result<TomlValue, TomlParseError> ParseBinInt(StringView token, int pos)
	{
		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_')
			{
				if (i == pos || i == token.Length - 1)
					return .Err(Error(.InvalidUnderscore, "Leading or trailing underscore in binary integer"));
				char8 prev = token[i - 1];
				char8 nextC = token[i + 1];
				if (!TomlChar.IsBinaryDigit(prev) || !TomlChar.IsBinaryDigit(nextC))
					return .Err(Error(.InvalidUnderscore, "Underscore must be between binary digits"));
				continue;
			}
			if (c != '0' && c != '1') return .Err(Error(.InvalidInteger, scope $"Invalid binary digit '{c}'"));
			uint64 digit = (uint64)(c - '0');
			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 2)
				return .Err(Error(.IntegerOverflow, "Binary integer overflow"));
			val = val * 2 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in binary integer"));
		if (val > 0x7FFFFFFFFFFFFFFF)
			return .Err(Error(.IntegerOverflow, "Binary integer exceeds signed 64-bit range"));
		return TomlValue.Integer((int64)val);
	}

	private Result<TomlValue, TomlParseError> ParseFloatToken(StringView token)
	{
		String cleanStr = scope String();
		for (int i = 0; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c != '_') cleanStr.Append(c);
		}

		switch (Double.Parse(cleanStr))
		{
		case .Err: return .Err(Error(.InvalidFloat, "Invalid float value"));
		case .Ok(let val): return TomlValue.Float(val);
		}
	}

	// ================================================================
	// Date/Time parsing
	// ================================================================

	private static bool LooksLikeDateTime(StringView token)
	{
		// Date pattern: starts with YYYY-
		if (token.Length >= 5 &&
			TomlChar.IsDigit(token[0]) && TomlChar.IsDigit(token[1]) &&
			TomlChar.IsDigit(token[2]) && TomlChar.IsDigit(token[3]) &&
			token[4] == '-')
			return true;

		for (int i = 0; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == 'T' || c == 't' || c == ':' || c == 'Z' || c == 'z')
				return true;
		}
		return false;
	}

	private Result<TomlValue, TomlParseError> TryParseDateTime(StringView token)
	{
		bool hasT = false;
		bool hasColon = false;
		bool hasZ = false;
		bool hasDash = false;

		for (int i = 0; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == 'T' || c == 't' || c == ' ') hasT = true;
			if (c == ':') hasColon = true;
			if (c == 'Z' || c == 'z') hasZ = true;
			if (c == '-') hasDash = true;
		}

		// If token has Z or ends with offset pattern, it must be offset datetime
		bool hasOffsetIndicator = hasZ;
		if (!hasOffsetIndicator)
		{
			// Check for +/- timezone offset (look after the last time digit for + or -)
			for (int i = token.Length - 1; i >= 0; i--)
			{
				if (token[i] == '+' || token[i] == '-')
				{
					if (i > 10) { hasOffsetIndicator = true; break; }
				}
			}
		}

		if (hasT || hasZ)
		{
			if (hasOffsetIndicator)
				return TryParseOffsetDateTime(token);
			return TryParseLocalDateTime(token);
		}
		if (!hasColon && !hasT && hasDash)
			return TryParseLocalDate(token);
		if (hasColon && !hasT && !hasDash)
			return TryParseLocalTime(token);

		// Should not reach here — LooksLikeDateTime already filtered non-dates
		return .Err(Error(.UnexpectedToken, "Cannot parse date/time"));
	}

	private Result<TomlValue, TomlParseError> TryParseOffsetDateTime(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDateTime, "Invalid date in datetime"));

		if (pos >= token.Length) return .Err(Error(.InvalidDateTime, "Missing time part"));
		char8 sep = token[pos];
		if (sep == 'T' || sep == 't' || sep == ' ') pos++;
		else return .Err(Error(.InvalidDateTime, "Expected date-time separator"));

		int32 hour = ?; int32 minute = ?; int32 second = 0; int64 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time in datetime"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));

		int32 offsetMinutes = 0;
		if (pos >= token.Length)
			return .Err(Error(.InvalidDateTime, "Expected timezone offset"));
		{
			char8 tz = token[pos];
			if (tz == 'Z' || tz == 'z') { pos++; offsetMinutes = 0; }
			else if (tz == '+' || tz == '-')
			{
				pos++;
				int32 tzh = 0, tzm = 0;
				if (!TryReadNDigits(token, ref pos, 2, out tzh))
					return .Err(Error(.InvalidDateTime, "Invalid timezone offset hours"));
				if (tzh > 23)
					return .Err(Error(.InvalidDateTime, "Timezone offset hour overflow"));
				// The ':' separator is required for timezone offset
				if (pos >= token.Length || token[pos] != ':')
					return .Err(Error(.InvalidDateTime, "Expected ':' in timezone offset"));
				pos++;
				if (!TryReadNDigits(token, ref pos, 2, out tzm))
					return .Err(Error(.InvalidDateTime, "Invalid timezone offset minutes"));
				if (tzm > 59)
					return .Err(Error(.InvalidDateTime, "Timezone offset minute overflow"));
				offsetMinutes = tzh * 60 + tzm;
				if (tz == '-') offsetMinutes = -offsetMinutes;
			}
			else { return .Err(Error(.InvalidDateTime, "Expected timezone offset")); }
		}

		if (pos != token.Length)
			return .Err(Error(.InvalidDateTime, "Trailing characters after offset date-time"));
		return TomlValue.OffsetDateTime(TomlOffsetDateTime(year, month, day, hour, minute, second, ns, offsetMinutes));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalDateTime(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDateTime, "Invalid date"));

		if (pos >= token.Length) return .Err(Error(.InvalidDateTime, "Missing time part"));
		char8 sep = token[pos];
		if (sep == 'T' || sep == 't' || sep == ' ') pos++;
		else return .Err(Error(.InvalidDateTime, "Expected date-time separator"));

		int32 hour = ?; int32 minute = ?; int32 second = 0; int64 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));

		if (pos != token.Length)
			return .Err(Error(.InvalidDateTime, "Trailing characters after local date-time"));
		return TomlValue.LocalDateTime(TomlLocalDateTime(year, month, day, hour, minute, second, ns));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalDate(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDate, "Invalid date"));
		if (pos != token.Length) return .Err(Error(.InvalidDate, "Trailing characters in date"));
		return TomlValue.LocalDate(TomlLocalDate(year, month, day));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalTime(StringView token)
	{
		int pos = 0;
		int32 hour = ?; int32 minute = ?; int32 second = 0; int64 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));
		if (pos != token.Length) return .Err(Error(.InvalidTime, "Trailing characters in time"));
		return TomlValue.LocalTime(TomlLocalTime(hour, minute, second, ns));
	}

	private bool ParseDatePart(StringView token, ref int pos, out int32 year, out int32 month, out int32 day)
	{
		year = 0; month = 0; day = 0;
		if (!TryReadNDigits(token, ref pos, 4, out year)) return false;
		if (pos >= token.Length || token[pos] != '-') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out month)) return false;
		if (month < 1 || month > 12) return false;
		if (pos >= token.Length || token[pos] != '-') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out day)) return false;
		if (day < 1 || day > 31) return false;
		// Basic month/day validation
		if (month == 2)
		{
			bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
			int32 maxDay = leap ? 29 : 28;
			if (day > maxDay) return false;
		}
		else if (month == 4 || month == 6 || month == 9 || month == 11)
		{
			if (day > 30) return false;
		}
		return true;
	}

	private bool ParseTimePart(StringView token, ref int pos,
		out int32 hour, out int32 minute, out int32 second, out int64 nanosecond,
		out bool secondsOmitted)
	{
		hour = 0; minute = 0; second = 0; nanosecond = 0;
		secondsOmitted = true;
		if (!TryReadNDigits(token, ref pos, 2, out hour)) return false;
		if (hour > 23) return false;
		if (pos >= token.Length || token[pos] != ':') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out minute)) return false;
		if (minute > 59) return false;

		if (pos < token.Length && token[pos] == ':')
		{
			secondsOmitted = false;
			pos++;
			if (!TryReadNDigits(token, ref pos, 2, out second)) return false;
			if (second > 60) return false; // 60 for leap seconds

			if (pos < token.Length && token[pos] == '.')
			{
				pos++;
				int fracStart = pos;
				while (pos < token.Length && TomlChar.IsDigit(token[pos]))
					pos++;
				int fracLen = pos - fracStart;
				if (fracLen == 0)
				{
					return false; // trailing dot with no fractional digits
				}
				else
				{
					String fracStr = scope String(token.Substring(fracStart, fracLen));
					while (fracStr.Length < 9) fracStr.Append('0');
					if (fracStr.Length > 9) fracStr.Remove(9, fracStr.Length - 9);
					nanosecond = 0;
					for (int i = 0; i < fracStr.Length; i++)
						nanosecond = nanosecond * 10 + (fracStr[i] - '0');
				}
			}
		}
		return true;
	}

	private bool TryReadNDigits(StringView token, ref int pos, int n, out int32 value)
	{
		value = 0;
		if (pos + n > token.Length) return false;
		for (int i = 0; i < n; i++)
		{
			char8 c = token[pos + i];
			if (c < '0' || c > '9') return false;
			value = value * 10 + (c - '0');
		}
		pos += n;
		return true;
	}

	// ================================================================
	// Array parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseArray()
	{
		mCursor.AdvanceByte();
		int startLine = mCursor.Line;
		TomlArray arr = new TomlArray(true);
		arr.IsStatic = true;

		// Array-local pending comment list for PreserveStyle mode
		List<String> arrayPendingComments = (mMetadata != null) ? new List<String>() : null;
		// Tracks whether the preceding comma was followed by a blank line
		bool arraySawBlankLine = false;
		defer
		{
			if (arrayPendingComments != null)
			{
				for (var item in arrayPendingComments)
					delete item;
				delete arrayPendingComments;
			}
		}

		// Capture comments after opening bracket
		bool unusedBlank = false;
		if (SkipWsAndCaptureComments(arrayPendingComments, out unusedBlank) case .Err(let e))
		{
			delete arr;
			return .Err(e);
		}
		if (mCursor.PeekByte() == ']')
		{
			mCursor.AdvanceByte();
			CountArrayStyle(startLine, mCursor.Line);
			// Empty array: flush comments to the array node itself
			if (arrayPendingComments != null && arrayPendingComments.Count > 0)
			{
				EnsureArrayContext(arr);
				let commentSet = mMetadata.GetOrCreateCommentSet(arr.MetadataContext.mNodeId);
				if (commentSet != null)
				{
					for (int ci = 0; ci < arrayPendingComments.Count; ci++)
						commentSet.mLeading.Add(arrayPendingComments[ci]);
					arrayPendingComments.Clear();
				}
			}
			return TomlValue.Array(arr);
		}

		while (true)
		{
			// Capture comments before element (potential leading comments)
			bool unusedBlank2 = false;
			if (SkipWsAndCaptureComments(arrayPendingComments, out unusedBlank2) case .Err(let wsErr))
			{
				delete arr;
				return .Err(wsErr);
			}

			if (mCursor.PeekByte() == ']')
			{
				mCursor.AdvanceByte();
				// Flush any pending comments to the last element (e.g., trailing comment without comma)
				if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
				{
					TomlNodeId lastId = .Invalid;
					if (arr.MetadataContext != null)
						arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
					if (lastId.IsValid)
					{
						let commentSet = mMetadata.GetOrCreateCommentSet(lastId);
						if (commentSet != null)
						{
							for (int ci = 0; ci < arrayPendingComments.Count; ci++)
								commentSet.mLeading.Add(arrayPendingComments[ci]);
							arrayPendingComments.Clear();
						}
					}
				}
				CountArrayStyle(startLine, mCursor.Line);
				return TomlValue.Array(arr);
			}

			// Mark value start for raw token capture
			var elemStart = TomlCursorMark();
			if (mMetadata != null)
				elemStart = mCursor.Mark();

			switch (ParseValue())
			{
			case .Err(let valErr):
				delete arr;
				return .Err(valErr);
			case .Ok(let val):
				arr.Add(val);
				// Capture metadata for this element
				if (mMetadata != null)
					CaptureArrayElement(arr, val, elemStart);
			}

			// Get node ID for this element for comment attachment
			TomlNodeId elemNodeId = .Invalid;
			if (arr.MetadataContext != null)
				arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out elemNodeId);

			// Flush pending comments as leading comments for this element
			if (arrayPendingComments != null && arrayPendingComments.Count > 0 && elemNodeId.IsValid)
			{
				let commentSet = mMetadata.GetOrCreateCommentSet(elemNodeId);
				if (commentSet != null)
				{
					for (int ci = 0; ci < arrayPendingComments.Count; ci++)
						commentSet.mLeading.Add(arrayPendingComments[ci]);
					arrayPendingComments.Clear();
				}
			}
			// Set blank line flag from array-level tracking (e.g., blank line before this element)
			if (arraySawBlankLine && elemNodeId.IsValid)
			{
				let commentSet = mMetadata.GetOrCreateCommentSet(elemNodeId);
				if (commentSet != null)
					commentSet.mSeparatedByBlankLine = true;
				arraySawBlankLine = false;
			}

			// Skip whitespace/newlines after value and capture trailing content
			bool afterValBlank = false;
			if (SkipWsAndCaptureComments(arrayPendingComments, out afterValBlank) case .Err(let trailErr))
			{
				delete arr;
				return .Err(trailErr);
			}

			char8 afterValB = mCursor.PeekByte();
			if (afterValB == ',')
			{
				mCursor.AdvanceByte();
				// After comma, capture any trailing comment on same line
				mCursor.SkipWhitespace();
				if (!mCursor.IsEOF && mCursor.PeekByte() == '#')
				{
					String trailingText = new String();
					if (CaptureCommentText(trailingText) case .Err(let tcErr))
					{
						delete trailingText;
						delete arr;
						return .Err(tcErr);
					}
					if (elemNodeId.IsValid && mMetadata != null)
					{
						let commentSet = mMetadata.GetOrCreateCommentSet(elemNodeId);
						if (commentSet != null)
						{
							if (commentSet.mTrailing != null)
								delete commentSet.mTrailing;
							commentSet.mTrailing = trailingText;
						}
						else
							delete trailingText;
					}
					else
						delete trailingText;
				}

				// Capture ws/comments between elements (leading for next element)
				bool afterCommaBlank = false;
				if (SkipWsAndCaptureComments(arrayPendingComments, out afterCommaBlank) case .Err(let commaWsErr))
				{
					delete arr;
					return .Err(commaWsErr);
				}
				// Track blank line for the next element
				if (afterCommaBlank)
					arraySawBlankLine = true;
				if (mCursor.PeekByte() == ']')
				{
					arr.mHasTrailingComma = true;
					mCursor.AdvanceByte();
					// Flush pending comments to the last element
					if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
					{
						TomlNodeId lastId = .Invalid;
						if (arr.MetadataContext != null)
							arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
						if (lastId.IsValid)
						{
							let commentSet = mMetadata.GetOrCreateCommentSet(lastId);
							if (commentSet != null)
							{
								for (int ci = 0; ci < arrayPendingComments.Count; ci++)
									commentSet.mLeading.Add(arrayPendingComments[ci]);
								arrayPendingComments.Clear();
							}
						}
					}
					CountArrayStyle(startLine, mCursor.Line);
					return TomlValue.Array(arr);
				}
				continue;
			}
			else if (afterValB == ']')
			{
				mCursor.AdvanceByte();
				// Flush pending comments to the last element (e.g., trailing comment without comma)
				if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
				{
					TomlNodeId lastId = .Invalid;
					if (arr.MetadataContext != null)
						arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
					if (lastId.IsValid)
					{
						let commentSet = mMetadata.GetOrCreateCommentSet(lastId);
						if (commentSet != null)
						{
							for (int ci = 0; ci < arrayPendingComments.Count; ci++)
								commentSet.mLeading.Add(arrayPendingComments[ci]);
							arrayPendingComments.Clear();
						}
					}
				}
				CountArrayStyle(startLine, mCursor.Line);
				return TomlValue.Array(arr);
			}
			else
			{
				delete arr;
				return .Err(Error(.UnexpectedToken, "Expected ',' or ']' in array"));
			}
		}
	}

	/// Ensure the array has a metadata context allocated.
	private void EnsureArrayContext(TomlArray arr)
	{
		if (mMetadata != null && arr.MetadataContext == null)
		{
			let ctxNodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext = new TomlContainerMetadataContext(mMetadata, ctxNodeId, true);
		}
	}

	// ================================================================
	// Inline table parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseInlineTable()
	{
		mCursor.AdvanceByte();
		TomlTable tbl = new TomlTable(.InlineTable, true);

		if (SkipWsAndComments(mVersion != .V1_0) case .Err(let e))
		{
			delete tbl;
			return .Err(e);
		}
		if (mCursor.PeekByte() == '}')
		{
			mCursor.AdvanceByte();
			tbl.IsInlineSealed = true;
			return TomlValue.Table(tbl);
		}

		while (true)
		{
			if (SkipWsAndComments(mVersion != .V1_0) case .Err(let wsErr))
			{
				delete tbl;
				return .Err(wsErr);
			}

			var keyPath = scope List<String>();
			defer { ClearAndDeleteItems!(keyPath); }
			if (ParseKeyPath(keyPath) case .Err(let keyErr))
			{
				delete tbl;
				return .Err(keyErr);
			}

			mCursor.SkipWhitespace();
			if (mCursor.PeekByte() != '=')
			{
				delete tbl;
				return .Err(Error(.UnexpectedToken, "Expected '=' in inline table"));
			}
			mCursor.AdvanceByte();

			mCursor.SkipWhitespace();
			switch (ParseValue())
			{
			case .Err(let valErr):
				delete tbl;
				return .Err(valErr);
			case .Ok(let val):
				if (keyPath.Count == 1)
				{
					if (tbl.ContainsKey(keyPath[0]))
					{
						val.Dispose();
						delete tbl;
						return .Err(Error(.DuplicateKey, "Duplicate key in inline table"));
					}
					tbl.Insert(keyPath[0], val);
				}
				else
				{
					if (InsertDottedKeyIntoTable(tbl, keyPath, val) case .Err(let insertErr))
					{
						val.Dispose();
						delete tbl;
						return .Err(insertErr);
					}
				}
			}

			if (SkipWsAndComments(mVersion != .V1_0) case .Err(let trailWsErr))
			{
				delete tbl;
				return .Err(trailWsErr);
			}

			char8 b = mCursor.PeekByte();
			if (b == ',')
			{
				mCursor.AdvanceByte();
				mCursor.SkipWhitespace();
				// Trailing comma: reject in v1.0
				if (mVersion == .V1_0 && mCursor.PeekByte() == '}')
				{
					delete tbl;
					return .Err(Error(.UnexpectedToken,
						"Trailing comma in inline table requires TOML v1.1"));
				}
				if (SkipWsAndComments(mVersion != .V1_0) case .Err(let commaWsErr))
				{
					delete tbl;
					return .Err(commaWsErr);
				}
				if (mCursor.PeekByte() == '}')
				{
					tbl.mHasTrailingComma = true;
					mCursor.AdvanceByte();
					tbl.IsInlineSealed = true;
					return TomlValue.Table(tbl);
				}
				continue;
			}
			else if (b == '}')
			{
				mCursor.AdvanceByte();
				break;
			}
			else
			{
				delete tbl;
				return .Err(Error(.UnexpectedToken, "Expected ',' or '}' in inline table"));
			}
		}

		tbl.IsInlineSealed = true;
		return TomlValue.Table(tbl);
	}

	private Result<void, TomlParseError> InsertDottedKeyIntoTable(TomlTable tbl, List<String> keyPath, TomlValue value)
	{
		TomlTable current = tbl;
		for (int i = 0; i < keyPath.Count - 1; i++)
		{
			StringView key = keyPath[i];
			if (current.TryGetValue(key, let existing))
			{
				if (existing case .Table(let existingTable))
				{
					// Cannot navigate into sealed inline tables
					if (existingTable.IsInlineSealed)
						return .Err(Error(.InlineTableSealed, scope $"Cannot add keys to sealed inline table via dotted key '{key}'"));
					current = existingTable;
				}
				else
				{
					// Type conflict: dotted key segment is not a table
					String msg = scope String();
					msg.AppendF("Key '{}' is not a table — cannot use dotted key path through it", key);
					return .Err(Error(.TypeConflict, msg));
				}
			}
			else
			{
				TomlTable newTbl = new TomlTable(.InlineTable, true);
				current.Insert(key, TomlValue.Table(newTbl));
				current = newTbl;
			}
		}

		StringView finalKey = keyPath[keyPath.Count - 1];
		if (current.ContainsKey(finalKey))
			return .Err(Error(.DuplicateKey, scope $"Duplicate key '{finalKey}' in inline table"));
		current.Insert(finalKey, value);
		return .Ok;
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

	/// Capture string format metadata for a parsed string value.
	private void CaptureStringFormat(TomlNodeId nodeId, StringView rawToken)
	{
		if (mMetadata == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		var fmt = TomlStringFormat();

		char8 first = rawToken[0];
		if (first == '"' && rawToken.Length >= 3 && rawToken[1] == '"' && rawToken[2] == '"')
		{
			fmt.mStyle = .MultilineBasic;
			// Check for newline after opening quotes
			if (rawToken.Length >= 4 && (rawToken[3] == '\n' || rawToken[3] == '\r'))
				fmt.mStartsWithNewline = true;
		}
		else if (first == '"')
		{
			fmt.mStyle = .Basic;
		}
		else if (first == '\'' && rawToken.Length >= 3 && rawToken[1] == '\'' && rawToken[2] == '\'')
		{
			fmt.mStyle = .MultilineLiteral;
			if (rawToken.Length >= 4 && (rawToken[3] == '\n' || rawToken[3] == '\r'))
				fmt.mStartsWithNewline = true;
		}
		else if (first == '\'')
		{
			fmt.mStyle = .Literal;
		}

		// Detect escapes in basic strings
		if (fmt.mStyle == .Basic || fmt.mStyle == .MultilineBasic)
		{
			for (int i = 1; i < rawToken.Length - 1; i++)
			{
				if (rawToken[i] == '\\') { fmt.mHadEscapes = true; break; }
			}
		}

		let valueFormat = mMetadata.AddValueFormat(.String(fmt));
		let style = mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = valueFormat;
	}

	/// Detect numeric format metadata from a raw token string.
	private void CaptureNumericFormat(TomlNodeId nodeId, StringView rawToken)
	{
		if (mMetadata == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		// Detect special float sign style
		TomlFloatSpecialSign specialSign = .None;
		int pos = 0;
		if (pos < rawToken.Length && rawToken[pos] == '+')
		{
			specialSign = .ExplicitPlus;
			pos++;
		}
		else if (pos < rawToken.Length && rawToken[pos] == '-')
		{
			specialSign = .Minus;
			pos++;
		}

		// Check for special floats (inf, nan) before checking for 0x/0o/0b prefix
		if (pos < rawToken.Length)
		{
			let body = rawToken.Substring(pos);
			if (body == "inf" || body == "nan")
			{
				var fmt = TomlFloatFormat();
				fmt.mStyle = .Special;
				fmt.mSpecialSign = specialSign;
				let fmtRef = mMetadata.AddValueFormat(.Float(fmt));
				let style = mMetadata.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
		}
		// Reset pos for normal number detection. For non-special floats
		// we need to re-parse including sign because the sign is part of the
		// semantic value.
		pos = 0;
		if (pos < rawToken.Length && (rawToken[pos] == '+' || rawToken[pos] == '-'))
			pos++;


		if (pos + 1 < rawToken.Length && rawToken[pos] == '0')
		{
			char8 next = rawToken[pos + 1];
			if (next == 'x' || next == 'X')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Hex;
				fmt.mUppercaseDigits = (next == 'X');
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				// Check for uppercase hex digits
				if (!fmt.mUppercaseDigits)
				{
					for (int i = pos + 2; i < rawToken.Length; i++)
					{
						char8 c = rawToken[i];
						if (c >= 'A' && c <= 'F') { fmt.mUppercaseDigits = true; break; }
					}
				}
				let fmtRef = mMetadata.AddValueFormat(.Integer(fmt));
				let style = mMetadata.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
			if (next == 'o' || next == 'O')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Octal;
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				let fmtRef = mMetadata.AddValueFormat(.Integer(fmt));
				let style = mMetadata.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
			if (next == 'b' || next == 'B')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Binary;
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				let fmtRef = mMetadata.AddValueFormat(.Integer(fmt));
				let style = mMetadata.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
		}

		// Check for float indicators
		bool hasDot = false;
		bool hasExp = false;
		for (int i = pos; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == '.') hasDot = true;
			if (c == 'e' || c == 'E') { hasExp = true; break; }
		}

		if (hasDot || hasExp)
		{
			var fmt = TomlFloatFormat();
			DetectFloatPrecision(rawToken, pos, ref fmt);
			if (hasExp)
			{
				fmt.mStyle = .Scientific;
				for (int i = pos; i < rawToken.Length; i++)
				{
					if (rawToken[i] == 'E') { fmt.mUppercaseExponent = true; break; }
					if (rawToken[i] == 'e') { fmt.mUppercaseExponent = false; break; }
				}
				// Check for explicit + in exponent and count exponent digits
				for (int i = pos; i < rawToken.Length - 1; i++)
				{
					if (rawToken[i] == 'e' || rawToken[i] == 'E')
					{
						int expStart = i + 1;
						if (expStart < rawToken.Length && (rawToken[expStart] == '+' || rawToken[expStart] == '-'))
						{
							if (rawToken[expStart] == '+')
								fmt.mExplicitPlusExponent = true;
							expStart++;
						}
						// Count exponent digits
						int digitCount = 0;
						for (int j = expStart; j < rawToken.Length; j++)
						{
							if (TomlChar.IsDigit(rawToken[j]))
								digitCount++;
							else
								break;
						}
						if (digitCount > 0)
							fmt.mExponentDigits = (uint8)digitCount;
						break;
					}
				}
			}
			else
			{
				fmt.mStyle = .Decimal;
			}
			// Detect underscore grouping in integer and fractional parts
			DetectFloatUnderscoreGrouping(rawToken, pos, ref fmt);
			let fmtRef = mMetadata.AddValueFormat(.Float(fmt));
			let style = mMetadata.GetNodeStyle(nodeId);
			if (style != null) style.mValueFormatRef = fmtRef;
			return;
		}

		// Plain decimal integer
		{
			var fmt = TomlIntegerFormat();
			fmt.mBase = .Decimal;
			DetectUnderscoreGrouping(rawToken, pos, ref fmt);
			let fmtRef = mMetadata.AddValueFormat(.Integer(fmt));
			let style = mMetadata.GetNodeStyle(nodeId);
			if (style != null) style.mValueFormatRef = fmtRef;
		}
	}

	/// Detect fractional precision in a float token, ignoring underscores.
	private void DetectFloatPrecision(StringView rawToken, int start, ref TomlFloatFormat fmt)
	{
		fmt.mPrecision = -1;
		for (int i = start; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '.')
			{
				int digits = 0;
				for (int j = i + 1; j < rawToken.Length; j++)
				{
					char8 c = rawToken[j];
					if (c == 'e' || c == 'E') break;
					if (c != '_') digits++;
				}
				fmt.mPrecision = (int16)digits;
				return;
			}
			if (rawToken[i] == 'e' || rawToken[i] == 'E')
			{
				fmt.mPrecision = 0;
				return;
			}
		}
	}

	/// Detect underscore grouping in an integer token starting at digitStart.
	private void DetectUnderscoreGrouping(StringView rawToken, int digitStart, ref TomlIntegerFormat fmt)
	{
		for (int i = digitStart; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '_')
			{
				fmt.mUseUnderscores = true;
				// Detect group size: count digits after this underscore until next underscore or end
				int groupSize = 0;
				for (int j = i + 1; j < rawToken.Length && rawToken[j] != '_'; j++)
					groupSize++;
				if (groupSize > 0)
					fmt.mGroupSize = (uint8)groupSize;
				break;
			}
		}
	}

	/// Detect minimum digit width for prefixed integer tokens, ignoring underscores.
	private void DetectMinimumDigits(StringView rawToken, int digitStart, ref TomlIntegerFormat fmt)
	{
		int digitCount = 0;
		for (int i = digitStart; i < rawToken.Length; i++)
		{
			if (rawToken[i] != '_')
				digitCount++;
		}
		if (digitCount > 0 && digitCount <= 255)
			fmt.mMinDigits = (uint8)digitCount;
	}

	/// Detect underscore grouping in the integer and fractional parts of a float token.
	private void DetectFloatUnderscoreGrouping(StringView rawToken, int start, ref TomlFloatFormat fmt)
	{
		// Find the decimal point
		int dotPos = -1;
		int ePos = -1;
		for (int i = start; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '.') { dotPos = i; }
			if (rawToken[i] == 'e' || rawToken[i] == 'E') { ePos = i; break; }
		}

		// Integer part: from start to dotPos or ePos
		int intEnd = (dotPos >= 0) ? dotPos : ((ePos >= 0) ? ePos : rawToken.Length);
		bool foundIntUnderscore = false;
		for (int i = start; i < intEnd; i++)
		{
			if (rawToken[i] == '_') { foundIntUnderscore = true; break; }
		}

		// Detect integer group size (last underscore before dot or exponent)
		if (foundIntUnderscore)
		{
			fmt.mUseUnderscores = true;
			// Find the last underscore in the integer part
			int lastUnderscore = -1;
			for (int i = start; i < intEnd; i++)
			{
				if (rawToken[i] == '_') lastUnderscore = i;
			}
			if (lastUnderscore >= 0)
			{
				int groupSize = 0;
				for (int j = lastUnderscore + 1; j < intEnd; j++)
					groupSize++;
				if (groupSize > 0)
					fmt.mIntGroupSize = (uint8)groupSize;
			}
		}

		// Fractional part: after dot, before exponent
		if (dotPos >= 0)
		{
			int fracEnd = (ePos >= 0) ? ePos : rawToken.Length;
			bool foundFracUnderscore = false;
			for (int i = dotPos + 1; i < fracEnd; i++)
			{
				if (rawToken[i] == '_') { foundFracUnderscore = true; break; }
			}
			if (foundFracUnderscore)
			{
				fmt.mUseUnderscores = true;
				int firstUnderscore = -1;
				for (int i = dotPos + 1; i < fracEnd; i++)
				{
					if (rawToken[i] == '_') { firstUnderscore = i; break; }
				}
				if (firstUnderscore >= 0)
				{
					int groupSize = firstUnderscore - (dotPos + 1);
					if (groupSize > 0)
						fmt.mFracGroupSize = (uint8)groupSize;
				}
			}
		}
	}

	// ================================================================
	// Comment capture helpers
	// ================================================================

	/// @brief Skip a TOML comment using parser-level TOML semantics.
	/// Requires/consumes #, validates comment control chars, and consumes newline if present.
	private Result<void, TomlParseError> SkipCommentText()
	{
		if (mCursor.PeekByte() != '#') return .Ok;
		mCursor.AdvanceByte(); // skip #

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			// Handle stream EOF where PeekByte() returns 0 before IsEOF is true
			if (b == 0 && mCursor.IsEOF)
				break;
			if (b == '\r')
			{
				if (mCursor.PeekByteAt(1) == '\n')
					break;
				return .Err(Error(.ControlCharInDocument, "Bare CR in comment"));
			}
			if (b == '\n') break;

			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInDocument, "Control character in comment"));

			mCursor.AdvanceByte();
		}
		CountAndSkipNewline();
		return .Ok;
	}

	/// @brief Capture comment text from the cursor into outText.
	/// Requires/consumes #, copies bytes until newline/CRLF/EOF,
	/// validates comment control chars, consumes newline if present,
	/// and normalizes only the single leading space after #.
	private Result<void, TomlParseError> CaptureCommentText(String outText)
	{
		if (mCursor.PeekByte() != '#') return .Ok;
		mCursor.AdvanceByte(); // skip #

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			// Handle stream EOF where PeekByte() returns 0 before IsEOF is true
			if (b == 0 && mCursor.IsEOF)
				break;
			if (b == '\r')
			{
				if (mCursor.PeekByteAt(1) == '\n')
					break;
				return .Err(Error(.ControlCharInDocument, "Bare CR in comment"));
			}
			if (b == '\n') break;

			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInDocument, "Control character in comment"));

			outText.Append(b);
			mCursor.AdvanceByte();
		}
		CountAndSkipNewline();
		// Trim only leading space (the conventional space after #)
		if (outText.Length > 0 && outText[0] == ' ')
			outText.Remove(0, 1);
		return .Ok;
	}

	/// @brief Capture a comment line and add it to the pending leading comments list.
	private Result<void, TomlParseError> CapturePendingComment()
	{
		if (mMetadata == null)
		{
			// No metadata — just skip the comment
			return SkipCommentText();
		}

		String commentText = new String();
		if (CaptureCommentText(commentText) case .Err(let e))
		{
			delete commentText;
			return .Err(e);
		}
		mPendingComments.Add(commentText);
		return .Ok;
	}

	/// @brief Capture a trailing comment on the same line as a key/val or header.
	/// Stores it in mTrailingCommentText for later attachment.
	private Result<void, TomlParseError> CaptureTrailingComment()
	{
		if (mMetadata == null)
		{
			return SkipCommentText();
		}

		// Clear any previous trailing comment
		if (mTrailingCommentText != null)
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
		}

		mTrailingCommentText = new String();
		if (CaptureCommentText(mTrailingCommentText) case .Err(let e))
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
			return .Err(e);
		}
		return .Ok;
	}

	/// @brief Attach pending leading comments to a node.
	private void AttachPendingComments(TomlNodeId nodeId)
	{
		if (mMetadata == null)
			return;

		// If there are comments or a blank line preceded this node, create a comment set
		if (mPendingComments.Count == 0 && mSavedBlankLineCount == 0)
			return;

		let commentSet = mMetadata.GetOrCreateCommentSet(nodeId);
		if (commentSet != null)
		{
			if (mPendingComments.Count > 0)
			{
				for (int i = 0; i < mPendingComments.Count; i++)
					commentSet.mLeading.Add(mPendingComments[i]);
				mPendingComments.Clear();
			}
			// If a blank line preceded this content, mark it on the comment set
			if (mSavedBlankLineCount > 0)
				commentSet.mSeparatedByBlankLine = true;
			mSavedBlankLineCount = 0;
		}
	}

	/// @brief Attach the stored trailing comment to a node.
	private void AttachTrailingComment(TomlNodeId nodeId)
	{
		if (mMetadata == null || mTrailingCommentText == null)
			return;

		let commentSet = mMetadata.GetOrCreateCommentSet(nodeId);
		if (commentSet != null)
		{
			if (commentSet.mTrailing != null)
				delete commentSet.mTrailing;
			commentSet.mTrailing = mTrailingCommentText;
			mTrailingCommentText = null; // Ownership transferred
		}
		else
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
		}
	}

	/// @brief Attach any remaining pending comments as file header comments on the root node.
	private void AttachPendingCommentsToRoot()
	{
		if (mMetadata == null || mPendingComments.Count == 0)
			return;

		let commentSet = mMetadata.GetOrCreateRootComments();
		for (int i = 0; i < mPendingComments.Count; i++)
			commentSet.mLeading.Add(mPendingComments[i]);
		mPendingComments.Clear();
	}

	/// @brief Attach any remaining pending comments as footer/EOF comments.
	private void AttachPendingCommentsToFooter()
	{
		if (mMetadata == null || mPendingComments.Count == 0)
			return;

		let commentSet = mMetadata.GetOrCreateFooterComments();
		for (int i = 0; i < mPendingComments.Count; i++)
			commentSet.mLeading.Add(mPendingComments[i]);
		mPendingComments.Clear();
	}

	/// Count and skip a newline for document-level style inference.
	/// Use for document-structure newlines; string parsing should use plain SkipNewline().
	private void CountAndSkipNewline()
	{
		if (mMetadata != null)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\r' && mCursor.PeekByteAt(1) == '\n')
				mCrlfCount++;
			else if (b == '\n')
				mLfOnlyCount++;
		}
		mCursor.SkipNewline();
	}

	// ================================================================
	// Key and container format capture
	// ================================================================

	/// Store key format metadata from pre-detected style and dotted path preference.
	private void CaptureKeyFormat(TomlNodeId nodeId, TomlKeyStyle keyStyle, bool isDotted)
	{
		if (mMetadata == null || !nodeId.IsValid)
			return;

		var fmt = TomlKeyFormat();
		fmt.mStyle = keyStyle;
		if (isDotted)
			fmt.mPreferDottedPath = true;

		let fmtRef = mMetadata.AddKeyFormat(fmt);
		let style = mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mKeyFormatRef = fmtRef;
	}

	/// Detect date-time format metadata from a raw token.
	private void CaptureDateTimeFormat(TomlNodeId nodeId, StringView rawToken)
	{
		if (mMetadata == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		var fmt = TomlDateTimeFormat();

		// Detect separator style (T vs t vs space)
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T') { fmt.mUsesUppercaseT = true; break; }
			if (c == 't') { fmt.mUsesUppercaseT = false; break; }
			if (c == ' ') { fmt.mUsesUppercaseT = false; break; }
		}

		// Detect offset style (Z vs +00:00)
		// Only scan after the time separator to avoid matching date dashes
		int timeSepPos = -1;
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T' || c == 't' || c == ' ') { timeSepPos = i; break; }
		}
		if (timeSepPos >= 0 && timeSepPos < rawToken.Length - 1)
		{
			for (int i = rawToken.Length - 1; i > timeSepPos; i--)
			{
				char8 c = rawToken[i];
				if (c == 'Z' || c == 'z') { fmt.mUsesZ = true; fmt.mHasOffset = true; break; }
				if (c == '+' || c == '-') { fmt.mUsesZ = false; fmt.mHasOffset = true; break; }
			}
		}

		// Detect seconds and fractional digits
		// Find the time separator first, then count colons only in the time component
		int timeStart = 0;
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T' || c == 't' || c == ' ') { timeStart = i + 1; break; }
		}
		int colonCount = 0;
		int fracDigits = 0;
		for (int i = timeStart; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			// Stop at timezone offset indicators
			if (c == 'Z' || c == 'z' || (i > timeStart && (c == '+' || c == '-'))) break;
			if (c == ':') colonCount++;
			if (c == '.')
			{
				// Count fractional digits
				for (int j = i + 1; j < rawToken.Length && TomlChar.IsDigit(rawToken[j]); j++)
					fracDigits++;
				break;
			}
		}
		fmt.mHasSeconds = colonCount >= 2;
		fmt.mFractionalDigits = (uint8)fracDigits;

		let fmtRef = mMetadata.AddValueFormat(.DateTime(fmt));
		let style = mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = fmtRef;
	}

	/// Detect array format metadata from a raw token.
	/// Scan backward from a closing bracket (`]` or `}`) to determine if a trailing comma exists,
	/// accounting for any trailing comment text between the comma and the bracket.
	private void CaptureArrayFormat(TomlNodeId nodeId, StringView rawToken, bool hasTrailingComma)
	{
		if (mMetadata == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		var fmt = TomlArrayFormat();
		fmt.mStyle = .Inline;
		for (int i = 0; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '\n' || rawToken[i] == '\r')
			{
				fmt.mStyle = .Multiline;
				break;
			}
		}

		// Trailing comma state captured during forward parsing (not from raw token scanning).
		fmt.mTrailingComma = hasTrailingComma;

		// Detect indentation from the first element after opening bracket
		fmt.mIndentSize = 0;
		if (fmt.mStyle == .Multiline)
		{
			int indentCount = 0;
			bool foundNewline = false;
			for (int i = 1; i < rawToken.Length; i++)
			{
				char8 c = rawToken[i];
				if (c == '\n' || c == '\r')
				{
					foundNewline = true;
					indentCount = 0;
				}
				else if (foundNewline && (c == ' ' || c == '\t'))
				{
					indentCount++;
				}
				else if (foundNewline && c != ' ' && c != '\t')
				{
					// Found first non-whitespace after newline
					if (indentCount > 0 && indentCount <= 255)
						fmt.mIndentSize = (uint8)indentCount;
					break;
				}
			}
		}
		if (fmt.mIndentSize == 0)
			fmt.mIndentSize = mMetadata.mDocumentStyle.mIndentSize;

		let fmtRef = mMetadata.AddValueFormat(.Array(fmt));
		let style = mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = fmtRef;
	}

	/// Detect inline table format metadata from a raw token.
	private void CaptureTableFormat(TomlNodeId nodeId, StringView rawToken, bool hasTrailingComma)
	{
		if (mMetadata == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		if (rawToken[0] != '{')
			return;

		var fmt = TomlTableFormat();
		fmt.mInline = true;

		// Detect multiline inline table
		for (int i = 0; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '\n' || rawToken[i] == '\r')
			{
				fmt.mMultiline = true;
				break;
			}
		}

		// Trailing comma state captured during forward parsing.
		fmt.mTrailingComma = hasTrailingComma;

		// Detect spacing after opening brace
		if (rawToken.Length >= 2)
		{
			if (rawToken[1] == ' ') fmt.mOpenBraceSpacing = 1;
			else if (rawToken[1] == '\n' || rawToken[1] == '\r') fmt.mOpenBraceSpacing = 1;
		}

		// Detect spacing before closing brace
		if (rawToken.Length >= 2 && rawToken[rawToken.Length - 2] == ' ')
			fmt.mCloseBraceSpacing = 1;

		// Detect equals spacing and comma spacing by scanning forward
		// through the raw token. Track entry indentation for multiline.
		fmt.mEqualsSpacing = 0; // default to no-space style
		fmt.mCommaSpacing = 0;
		int maxIndent = 0;
		bool inValue = false;
		int lastEqualsEnd = -1;
		int lastCommaEnd = -1;
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == '=' && !inValue)
			{
				// Check for spaces before =
				int beforeEquals = 0;
				if (i > 0 && rawToken[i - 1] == ' ') beforeEquals = 1;
				// Check for spaces after =
				int afterEquals = 0;
				if (i + 1 < rawToken.Length && rawToken[i + 1] == ' ') afterEquals = 1;
				// Use min of before/after to determine style
				if (beforeEquals > 0 || afterEquals > 0)
					fmt.mEqualsSpacing = 1;
				lastEqualsEnd = i + afterEquals;
				inValue = true;
			}
			else if (c == ',')
			{
				inValue = false;
				// Check for space after comma
				if (i + 1 < rawToken.Length && rawToken[i + 1] == ' ')
					fmt.mCommaSpacing = 1;
				lastCommaEnd = i;
			}
			else if (c == '\n' || c == '\r')
			{
				// Count indent on next line for multiline detection
				int indentCount = 0;
				for (int j = i + 1; j < rawToken.Length; j++)
				{
					char8 nc = rawToken[j];
					if (nc == ' ' || nc == '\t') indentCount++;
					else if (nc == '#' || nc == '}' || TomlChar.IsBareKeyChar(nc)) break;
					else break;
				}
				if (indentCount > maxIndent) maxIndent = indentCount;
			}
		}
		if (maxIndent > 0 && maxIndent <= 255)
			fmt.mEntryIndent = (uint8)maxIndent;

		let fmtRef = mMetadata.AddValueFormat(.Table(fmt));
		let style = mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = fmtRef;
	}

	private static bool IsTokenWhitespace(char8 c)
	{
		return c == ' ' || c == '\t' || c == '\n' || c == '\r';
	}

	/// Capture metadata for a single array element value.
	private void CaptureArrayElement(TomlArray arr, TomlValue val, TomlCursorMark elemStart)
	{
		if (mMetadata == null)
			return;

		// Ensure the array has a metadata context
		if (arr.MetadataContext == null)
		{
			let ctxNodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext = new TomlContainerMetadataContext(mMetadata, ctxNodeId, true);
		}

		// Reuse node ID if Add() already allocated one, otherwise allocate new
		TomlNodeId nodeId;
		if (arr.MetadataContext.mItemNodeIds != null && arr.MetadataContext.mItemNodeIds.Count >= arr.Count)
		{
			// Add() already allocated a node ID for this element
			nodeId = arr.MetadataContext.mItemNodeIds[arr.Count - 1];
		}
		else
		{
			nodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext.AddItemNodeId(nodeId);
		}

		// Capture string token and format
		if (val.IsString)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(elemStart, scratch);
			let tokenRef = mMetadata.AddOriginalToken(rawToken);
			let style = mMetadata.GetNodeStyle(nodeId);
			if (style != null)
				style.mOriginalValueToken = tokenRef;
			CaptureStringFormat(nodeId, rawToken);
		}
		else if (val.IsInteger || val.IsFloat)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(elemStart, scratch);
			CaptureNumericFormat(nodeId, rawToken);
		}
		else if (val.IsOffsetDateTime || val.IsLocalDateTime || val.IsLocalDate || val.IsLocalTime)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(elemStart, scratch);
			CaptureDateTimeFormat(nodeId, rawToken);
		}
		else if (val.IsArray)
		{
			String scratch = scope String();
			StringView rawToken = mCursor.Slice(elemStart, scratch);
			CaptureArrayFormat(nodeId, rawToken, val.AsArray?.mHasTrailingComma ?? false);
		}
		else
		{
			// Bool and table: no token to capture, but must release the mark
			String scratch = scope String();
			mCursor.Slice(elemStart, scratch);
		}
	}

	/// Count a string style occurrence for document-level inference.
	/// Called from all string parse methods, not just key/val paths.
	private void CountStringStyle(TomlStringStyle style)
	{
		if (mMetadata == null)
			return;
		switch (style)
		{
		case .Basic: mStringStyleCount_Basic++;
		case .Literal: mStringStyleCount_Literal++;
		case .MultilineBasic: mStringStyleCount_MultilineBasic++;
		case .MultilineLiteral: mStringStyleCount_MultilineLiteral++;
		}
	}

	/// Count array style (inline vs multiline) for document-level inference.
	private void CountArrayStyle(int startLine, int endLine)
	{
		if (mMetadata == null)
			return;
		if (endLine > startLine)
			mArrayStyleCount_Multiline++;
		else
			mArrayStyleCount_Inline++;
	}

	private TomlParseError Error(TomlErrorKind kind, StringView message)
	{
		return TomlParseError(kind, message, mCursor.Line, mCursor.Column, mCursor.Offset);
	}

	// ================================================================
	// Document style inference
	// ================================================================

	/// Infer document-level style from accumulated parsing state.
	/// Called once at the end of ParseDocument.
	private void InferDocumentStyle()
	{
		if (mMetadata == null)
			return;

		// Determine dominant string style
		int maxCount = mStringStyleCount_Basic;
		var dominant = TomlStringStyle.Basic;

		if (mStringStyleCount_Literal > maxCount)
		{
			maxCount = mStringStyleCount_Literal;
			dominant = .Literal;
		}
		if (mStringStyleCount_MultilineBasic > maxCount)
		{
			maxCount = mStringStyleCount_MultilineBasic;
			dominant = .MultilineBasic;
		}
		if (mStringStyleCount_MultilineLiteral > maxCount)
		{
			maxCount = mStringStyleCount_MultilineLiteral;
			dominant = .MultilineLiteral;
		}

		mMetadata.mDocumentStyle.mDefaultStringStyle = dominant;

		// Determine dominant array style
		if (mArrayStyleCount_Multiline > mArrayStyleCount_Inline)
			mMetadata.mDocumentStyle.mDefaultArrayStyle = .Multiline;
		else
			mMetadata.mDocumentStyle.mDefaultArrayStyle = .Inline;

		// Detect CRLF from cursor
		if (mCrlfCount > 0 && mCrlfCount >= mLfOnlyCount)
			mMetadata.mDocumentStyle.mNewlineStyle = .CRLF;
		else
			mMetadata.mDocumentStyle.mNewlineStyle = .LF;
	}
}
