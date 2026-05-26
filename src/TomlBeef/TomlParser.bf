using System;
using System.Collections;

namespace TomlBeef;

/// Recursive descent parser for TOML v1.1.0.
class TomlParserImpl
{
	private TomlCursor mCursor ~ delete _;
	private TomlPathResolver mPathResolver;
	private TomlVersion mVersion;
	private int mDepth = 0;
	private const int mMaxDepth = 256;

	public this(TomlVersion version = .V1_1)
	{
		mVersion = version;
	}

	public Result<void, TomlParseError> Parse(StringView input, TomlPathResolver resolver)
	{
		// Validate UTF-8
		int i = 0;
		while (i < input.Length)
		{
			uint8 b = (uint8)input[i];
			if (b < 0x80) { i++; continue; }
			int seqLen;
			uint32 minCp;
			if ((b & 0xE0) == 0xC0)      { seqLen = 2; minCp = 0x80; }
			else if ((b & 0xF0) == 0xE0) { seqLen = 3; minCp = 0x800; }
			else if ((b & 0xF8) == 0xF0) { seqLen = 4; minCp = 0x10000; }
			else { return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 lead byte", 1, 1, i)); }

			if (i + seqLen > input.Length)
				return .Err(TomlParseError(.InvalidUtf8, "Truncated UTF-8 sequence", 1, 1, i));

			uint32 cp = (uint32)(b & (seqLen == 2 ? 0x1F : seqLen == 3 ? 0x0F : 0x07));
			for (int j = 1; j < seqLen; j++)
			{
				uint8 cb = (uint8)input[i + j];
				if ((cb & 0xC0) != 0x80)
					return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 continuation byte", 1, 1, i + j));
				cp = (cp << 6) | (uint32)(cb & 0x3F);
			}

			// Validate overlong sequences and surrogate range
			if (cp < minCp)
				return .Err(TomlParseError(.InvalidUtf8, "Overlong UTF-8 sequence", 1, 1, i));
			if (cp >= 0xD800 && cp <= 0xDFFF)
				return .Err(TomlParseError(.InvalidUtf8, "UTF-8 surrogate pair not allowed", 1, 1, i));
			if (cp > 0x10FFFF)
				return .Err(TomlParseError(.InvalidUtf8, "Codepoint beyond U+10FFFF", 1, 1, i));

			i += seqLen;
		}

		// Skip UTF-8 BOM if present
		int start = 0;
		if (input.Length >= 3 && (uint8)input[0] == 0xEF && (uint8)input[1] == 0xBB && (uint8)input[2] == 0xBF)
		{
			start = 3;
			// Reject a second BOM immediately following the first
			if (input.Length >= 6 && (uint8)input[3] == 0xEF && (uint8)input[4] == 0xBB && (uint8)input[5] == 0xBF)
				return .Err(TomlParseError(.ControlCharInDocument, "BOM must only appear at start of file", 1, 1, 3));
		}

		if (mCursor != null) delete mCursor;

		mCursor = new TomlCursor(StringView(&input.Ptr[start], input.Length - start));
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
				if (mCursor.SkipComment() case .Err(let e))
					return .Err(e);
				continue;
			}
			if (b == '\r' || b == '\n')
			{
				mCursor.SkipNewline();
				continue;
			}

			if (b == '[')
			{
				if (ParseHeader() case .Err(let headerErr))
					return .Err(headerErr);
				continue;
			}

			if (ParseKeyVal() case .Err(let kvErr))
				return .Err(kvErr);

			mCursor.SkipWhitespace();
			if (!mCursor.IsEOF)
			{
				char8 afterB = mCursor.PeekByte();
				if (afterB == '#')
				{
					if (mCursor.SkipComment() case .Err(let commentErr))
						return .Err(commentErr);
				}
				else if (afterB != '\r' && afterB != '\n')
					return .Err(Error(.MissingNewlineAfterKeyVal, "Expected newline after key/value pair"));
				else
					mCursor.SkipNewline();
			}
		}

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
				if (mCursor.SkipComment() case .Err(let commentErr))
					return .Err(commentErr);
			}
			else if (b == '\r' || b == '\n')
				mCursor.SkipNewline();
			else
				return .Err(Error(.UnexpectedToken, "Expected newline or comment after header"));
		}

		SyncPathResolver();
		if (isArray)
			return mPathResolver.EnterArrayOfTables(path);
		else
			return mPathResolver.EnterTable(path);
	}

	// ================================================================
	// Key/value pair
	// ================================================================

	private Result<void, TomlParseError> ParseKeyVal()
	{
		SyncPathResolver();

		var keyPath = scope List<String>();
		defer { ClearAndDeleteItems!(keyPath); }
		if (ParseKeyPath(keyPath) case .Err(let e))
			return .Err(e);

		mCursor.SkipWhitespace();
		if (mCursor.PeekByte() != '=')
			return .Err(Error(.UnexpectedToken, "Expected '='"));
		mCursor.AdvanceByte();

		mCursor.SkipWhitespace();

		TomlValue value = ?;
		switch (ParseValue())
		{
		case .Err(let valErr): return .Err(valErr);
		case .Ok(let val): value = val;
		}

		SyncPathResolver();
		if (mPathResolver.SetKeyValue(keyPath, value) case .Err(let insertErr))
		{
			value.Dispose();
			return .Err(insertErr);
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
		int start = mCursor.Offset;

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

		StringView sv = mCursor.Slice(start, mCursor.Offset - start);
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
		int start = mCursor.Offset;
		mCursor.AdvanceByte();

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\'')
			{
				mCursor.AdvanceByte();
				StringView sv = mCursor.Slice(start + 1, mCursor.Offset - start - 2);
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
			return ParseMultiLineBasicString();
		return ParseBasicString();
	}

	private Result<TomlValue, TomlParseError> ParseLiteralString()
	{
		if (mCursor.PeekByte() == '\'' && mCursor.PeekByteAt(1) == '\'' && mCursor.PeekByteAt(2) == '\'')
			return ParseMultiLineLiteralString();
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
		int start = mCursor.Offset;
		while (!mCursor.IsEOF && TomlChar.IsBareValueChar(mCursor.PeekByte()))
			mCursor.AdvanceByte();

		StringView token = mCursor.Slice(start, mCursor.Offset - start);

		if (token == "true") return TomlValue.Bool(true);
		if (token == "false") return TomlValue.Bool(false);
		return ParseBareToken(token);
	}

	// ================================================================
	// Bare value parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseBareValue()
	{
		int start = mCursor.Offset;

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\r' || b == '\n' ||
				b == '=' || b == '[' || b == ']' || b == '{' || b == '}' ||
				b == ',' || b == '#')
				break;
			mCursor.AdvanceByte();
		}

		int length = mCursor.Offset - start;
		if (length == 0)
			return .Err(Error(.UnexpectedToken, "Expected value"));

		StringView token = mCursor.Slice(start, length);
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
		TomlArray arr = new TomlArray();
		arr.IsStatic = true;

		if (SkipWsAndComments() case .Err(let e))
		{
			delete arr;
			return .Err(e);
		}
		if (mCursor.PeekByte() == ']')
		{
			mCursor.AdvanceByte();
			return TomlValue.Array(arr);
		}

		while (true)
		{
			if (SkipWsAndComments() case .Err(let wsErr))
			{
				delete arr;
				return .Err(wsErr);
			}

			switch (ParseValue())
			{
			case .Err(let valErr):
				delete arr;
				return .Err(valErr);
			case .Ok(let val): arr.Add(val);
			}

			if (SkipWsAndComments() case .Err(let trailWsErr))
			{
				delete arr;
				return .Err(trailWsErr);
			}

			char8 b = mCursor.PeekByte();
			if (b == ',')
			{
				mCursor.AdvanceByte();
				if (SkipWsAndComments() case .Err(let commaWsErr))
				{
					delete arr;
					return .Err(commaWsErr);
				}
				if (mCursor.PeekByte() == ']')
				{
					mCursor.AdvanceByte();
					return TomlValue.Array(arr);
				}
				continue;
			}
			else if (b == ']')
			{
				mCursor.AdvanceByte();
				return TomlValue.Array(arr);
			}
			else
			{
				delete arr;
				return .Err(Error(.UnexpectedToken, "Expected ',' or ']' in array"));
			}
		}
	}

	// ================================================================
	// Inline table parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseInlineTable()
	{
		mCursor.AdvanceByte();
		TomlTable tbl = new TomlTable(.InlineTable);

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
				TomlTable newTbl = new TomlTable(.InlineTable);
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
				if (mCursor.SkipComment() case .Err(let e))
					return .Err(e);
				continue;
			}
			if (allowNewlines && (b == '\r' || b == '\n')) { mCursor.SkipNewline(); continue; }
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

	private TomlParseError Error(TomlErrorKind kind, StringView message)
	{
		return TomlParseError(kind, message, mCursor.Line, mCursor.Column, mCursor.Offset);
	}
}
