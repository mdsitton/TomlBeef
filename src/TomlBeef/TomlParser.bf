using System;
using System.Collections;

namespace TomlBeef;

/// Recursive descent parser for TOML v1.1.0.
public class TomlParser
{
	private TomlCursor mCursor;
	private TomlDocument mDocument;
	private TomlPathResolver mPathResolver;
	private int mDepth = 0;
	private const int mMaxDepth = 256;

	public this()
	{
	}

	public ~this()
	{
	}

	public Result<TomlDocument, TomlParseError> Parse(StringView input)
	{
		mCursor = new TomlCursor(input);
		mDocument = new TomlDocument();
		mPathResolver = new TomlPathResolver(mDocument);
		mPathResolver.Reset();
		mDepth = 0;

		switch (ParseDocument())
		{
		case .Err(let err):
			delete mDocument;
			mDocument = null;
			return .Err(err);
		default:
		}

		TomlDocument result = mDocument;
		mDocument = null;
		return result;
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

			if (b == '#')
			{
				mCursor.SkipComment();
				continue;
			}
			if (b == '\r' || b == '\n')
			{
				mCursor.SkipNewline();
				continue;
			}

			if (b == '[')
			{
				switch (ParseHeader())
				{
				case .Err(let err): return .Err(err);
				default:
				}
				continue;
			}

			switch (ParseKeyVal())
			{
			case .Err(let err): return .Err(err);
			default:
			}

			mCursor.SkipWhitespace();
			if (!mCursor.IsEOF)
			{
				char8 afterB = mCursor.PeekByte();
				if (afterB == '#')
					mCursor.SkipComment();
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

		List<String> path = new List<String>();
		defer
		{
			for (int i = 0; i < path.Count; i++)
				delete path[i];
			delete path;
		}
		switch (ParseKeyPath(path))
		{
		case .Err(let err): return .Err(err);
		default:
		}

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
				mCursor.SkipComment();
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

		List<String> keyPath = new List<String>();
		defer
		{
			for (int i = 0; i < keyPath.Count; i++)
				delete keyPath[i];
			delete keyPath;
		}
		switch (ParseKeyPath(keyPath))
		{
		case .Err(let err): return .Err(err);
		default:
		}

		mCursor.SkipWhitespace();
		if (mCursor.PeekByte() != '=')
			return .Err(Error(.UnexpectedToken, "Expected '='"));
		mCursor.AdvanceByte();

		mCursor.SkipWhitespace();

		TomlValue value = ?;
		switch (ParseValue())
		{
		case .Err(let err): return .Err(err);
		case .Ok(let val): value = val;
		}

		SyncPathResolver();
		return mPathResolver.SetKeyValue(keyPath, value);
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

		if (!mCursor.IsEOF && TomlScanner.IsBareKeyChar(mCursor.PeekByte()))
		{
			mCursor.AdvanceByte();
		}
		else
		{
			return .Err(Error(.InvalidKey, "Invalid bare key"));
		}

		while (!mCursor.IsEOF && TomlScanner.IsBareKeyChar(mCursor.PeekByte()))
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
		case 't', 'f':
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
			if ((uint8)b < 0x20 && b != '\t')
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
		mCursor.AdvanceByte(); mCursor.AdvanceByte(); mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			mCursor.SkipNewline();

		String result = new String();

		while (!mCursor.IsEOF)
		{
			if (mCursor.PeekByte() == '"' && mCursor.PeekByteAt(1) == '"' && mCursor.PeekByteAt(2) == '"')
			{
				if (mCursor.PeekByteAt(3) != '"')
				{
					mCursor.AdvanceByte(); mCursor.AdvanceByte(); mCursor.AdvanceByte();
					return TomlValue.String(result);
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
				mCursor.AdvanceByte();
				if (mCursor.PeekByte() == '\n') mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}
			if (b == '\n')
			{
				mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}

			if ((uint8)b < 0x20 && b != '\t')
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
		case 'e': result.Append((char8)0x1B); return .Ok;
		case '"': result.Append('"'); return .Ok;
		case '\\': result.Append('\\'); return .Ok;
		case 'x': return ParseHexEscape(result, 2);
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
			uint32 v;
			if (c >= '0' && c <= '9')
				v = (uint32)(c - '0');
			else if (c >= 'A' && c <= 'F')
				v = (uint32)(c - 'A' + 10);
			else if (c >= 'a' && c <= 'f')
				v = (uint32)(c - 'a' + 10);
			else
				return .Err(Error(.InvalidEscape, "Invalid hex digit"));

			cp = (cp << 4) | v;
			mCursor.AdvanceByte();
		}

		if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
			return .Err(Error(.InvalidUnicodeScalar, "Invalid Unicode scalar value"));

		EncodeUtf8(result, cp);
		return .Ok;
	}

	private void EncodeUtf8(String result, uint32 cp)
	{
		if (cp < 0x80)
		{
			result.Append((char8)cp);
		}
		else if (cp < 0x800)
		{
			result.Append((char8)(0xC0 | (cp >> 6)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else if (cp < 0x10000)
		{
			result.Append((char8)(0xE0 | (cp >> 12)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
		else
		{
			result.Append((char8)(0xF0 | (cp >> 18)));
			result.Append((char8)(0x80 | ((cp >> 12) & 0x3F)));
			result.Append((char8)(0x80 | ((cp >> 6) & 0x3F)));
			result.Append((char8)(0x80 | (cp & 0x3F)));
		}
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
			if ((uint8)b < 0x20 && b != '\t')
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
		mCursor.AdvanceByte(); mCursor.AdvanceByte(); mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			mCursor.SkipNewline();

		String result = new String();

		while (!mCursor.IsEOF)
		{
			if (mCursor.PeekByte() == '\'' && mCursor.PeekByteAt(1) == '\'' && mCursor.PeekByteAt(2) == '\'')
			{
				if (mCursor.PeekByteAt(3) != '\'')
				{
					mCursor.AdvanceByte(); mCursor.AdvanceByte(); mCursor.AdvanceByte();
					return TomlValue.String(result);
				}
			}

			char8 b = mCursor.PeekByte();

			if (b == '\r')
			{
				mCursor.AdvanceByte();
				if (mCursor.PeekByte() == '\n') mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}
			if (b == '\n')
			{
				mCursor.AdvanceByte();
				result.Append('\n');
				continue;
			}

			if ((uint8)b < 0x20 && b != '\t')
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
		while (!mCursor.IsEOF && TomlScanner.IsBareValueChar(mCursor.PeekByte()))
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

		switch (TryParseDateTime(token))
		{
		case .Ok(let val): return val;
		default:
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

		bool negative = false;
		int pos = 0;

		if (token[pos] == '-') { negative = true; pos++; }
		else if (token[pos] == '+') { pos++; }

		if (pos >= token.Length)
			return .Err(Error(.InvalidInteger, "Expected digits after sign"));

		if (token[pos] == '0' && pos + 1 < token.Length)
		{
			char8 next = token[pos + 1];
			if (next == 'x' || next == 'X') return ParseHexInt(token, negative, pos + 2);
			if (next == 'o' || next == 'O') return ParseOctInt(token, negative, pos + 2);
			if (next == 'b' || next == 'B') return ParseBinInt(token, negative, pos + 2);
		}

		bool hasDot = false;
		bool hasExp = false;

		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '.')
			{
				if (hasDot) return .Err(Error(.InvalidFloat, "Multiple decimal points"));
				hasDot = true;
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
				if (!TomlScanner.IsDigit(prev) || !TomlScanner.IsDigit(nextC))
					return .Err(Error(.InvalidUnderscore, "Underscore must be between digits"));
			}
			else if (!TomlScanner.IsDigit(c))
			{
				return .Err(Error(.InvalidFloat, scope $"Invalid character '{c}' in number"));
			}
		}

		if (!hasDot && !hasExp)
		{
			StringView digitsPart = token.Substring(pos);
			if (digitsPart.Length > 1 && digitsPart[0] == '0')
				return .Err(Error(.LeadingZero, "Leading zeros not allowed in decimal integers"));
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

	private Result<TomlValue, TomlParseError> ParseHexInt(StringView token, bool negative, int pos)
	{
		if (negative) return .Err(Error(.InvalidInteger, "Hex integers cannot be negative"));

		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_') continue;
			uint64 digit;
			if (c >= '0' && c <= '9') digit = (uint64)(c - '0');
			else if (c >= 'A' && c <= 'F') digit = (uint64)(c - 'A' + 10);
			else if (c >= 'a' && c <= 'f') digit = (uint64)(c - 'a' + 10);
			else return .Err(Error(.InvalidInteger, scope $"Invalid hex digit '{c}'"));

			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 16)
				return .Err(Error(.IntegerOverflow, "Hex integer overflow"));
			val = val * 16 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in hex integer"));
		return TomlValue.Integer((int64)val);
	}

	private Result<TomlValue, TomlParseError> ParseOctInt(StringView token, bool negative, int pos)
	{
		if (negative) return .Err(Error(.InvalidInteger, "Octal integers cannot be negative"));

		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_') continue;
			if (c < '0' || c > '7') return .Err(Error(.InvalidInteger, scope $"Invalid octal digit '{c}'"));
			uint64 digit = (uint64)(c - '0');
			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 8)
				return .Err(Error(.IntegerOverflow, "Octal integer overflow"));
			val = val * 8 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in octal integer"));
		return TomlValue.Integer((int64)val);
	}

	private Result<TomlValue, TomlParseError> ParseBinInt(StringView token, bool negative, int pos)
	{
		if (negative) return .Err(Error(.InvalidInteger, "Binary integers cannot be negative"));

		uint64 val = 0;
		bool hasDigit = false;
		for (int i = pos; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == '_') continue;
			if (c != '0' && c != '1') return .Err(Error(.InvalidInteger, scope $"Invalid binary digit '{c}'"));
			uint64 digit = (uint64)(c - '0');
			if (val > (0xFFFFFFFFFFFFFFFF - digit) / 2)
				return .Err(Error(.IntegerOverflow, "Binary integer overflow"));
			val = val * 2 + digit;
			hasDigit = true;
		}
		if (!hasDigit) return .Err(Error(.InvalidInteger, "No digits in binary integer"));
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

		if (!hasT && !hasColon && !hasZ && !hasDash)
			return .Err(Error(.UnexpectedToken, "Not a date/time"));

		if ((hasT || hasZ) && token.Length >= 19)
		{
			switch (TryParseOffsetDateTime(token))
			{
			case .Ok(let val): return val;
			default:
			}
		}
		if (hasT)
			return TryParseLocalDateTime(token);
		if (!hasColon && !hasT && hasDash)
			return TryParseLocalDate(token);
		if (hasColon && !hasT && !hasDash)
			return TryParseLocalTime(token);

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
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns))
			return .Err(Error(.InvalidTime, "Invalid time in datetime"));

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
				if (pos < token.Length && token[pos] == ':') pos++;
				if (!TryReadNDigits(token, ref pos, 2, out tzm))
					return .Err(Error(.InvalidDateTime, "Invalid timezone offset minutes"));
				offsetMinutes = tzh * 60 + tzm;
				if (tz == '-') offsetMinutes = -offsetMinutes;
			}
			else { return .Err(Error(.InvalidDateTime, "Expected timezone offset")); }
		}

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
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns))
			return .Err(Error(.InvalidTime, "Invalid time"));

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
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns))
			return .Err(Error(.InvalidTime, "Invalid time"));
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

	private bool ParseTimePart(StringView token, ref int pos, out int32 hour, out int32 minute, out int32 second, out int64 nanosecond)
	{
		hour = 0; minute = 0; second = 0; nanosecond = 0;
		if (!TryReadNDigits(token, ref pos, 2, out hour)) return false;
		if (hour > 23) return false;
		if (pos >= token.Length || token[pos] != ':') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out minute)) return false;
		if (minute > 59) return false;

		if (pos < token.Length && token[pos] == ':')
		{
			pos++;
			if (!TryReadNDigits(token, ref pos, 2, out second)) return false;
			if (second > 60) return false; // 60 for leap seconds

			if (pos < token.Length && token[pos] == '.')
			{
				pos++;
				int fracStart = pos;
				while (pos < token.Length && TomlScanner.IsDigit(token[pos]))
					pos++;
				int fracLen = pos - fracStart;
				if (fracLen > 0)
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
		arr.mIsStatic = true; // inline [a, b, c] arrays are static

		SkipWsAndComments();
		if (mCursor.PeekByte() == ']')
		{
			mCursor.AdvanceByte();
			return TomlValue.Array(arr);
		}

		while (true)
		{
			SkipWsAndComments();

			switch (ParseValue())
			{
			case .Err(let err):
				delete arr;
				return .Err(err);
			case .Ok(let val):
				arr.Add(val);
			}

			SkipWsAndComments();

			char8 b = mCursor.PeekByte();
			if (b == ',')
			{
				mCursor.AdvanceByte();
				SkipWsAndComments();
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

		SkipWsAndComments();
		if (mCursor.PeekByte() == '}')
		{
			mCursor.AdvanceByte();
			tbl.IsInlineSealed = true;
			return TomlValue.Table(tbl);
		}

		while (true)
		{
			SkipWsAndComments();

			List<String> keyPath = new List<String>();
			defer
			{
				for (int i = 0; i < keyPath.Count; i++)
					delete keyPath[i];
				delete keyPath;
			}
			switch (ParseKeyPath(keyPath))
			{
			case .Err(let err):
				delete tbl;
				return .Err(err);
			default:
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
			case .Err(let err):
				delete tbl;
				return .Err(err);
			case .Ok(let val):
				if (keyPath.Count == 1)
				{
					if (tbl.ContainsKey(keyPath[0]))
						{ delete tbl; return .Err(Error(.DuplicateKey, "Duplicate key in inline table")); }
					tbl.Insert(keyPath[0], val);
				}
				else
				{
					InsertDottedKeyIntoTable(tbl, keyPath, val);
				}
			}

			SkipWsAndComments();

			char8 b = mCursor.PeekByte();
			if (b == ',')
			{
				mCursor.AdvanceByte();
				SkipWsAndComments();
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

	private void InsertDottedKeyIntoTable(TomlTable tbl, List<String> keyPath, TomlValue value)
	{
		TomlTable current = tbl;
		for (int i = 0; i < keyPath.Count - 1; i++)
		{
			StringView key = keyPath[i];
			if (current.TryGetValue(key, let existing))
			{
				if (existing case .Table(let existingTable))
				{
					current = existingTable;
				}
				else
				{
					return; // Type conflict: non-table at dotted key path — error is caught at final key
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
			current.ReplaceValue(finalKey, value);
		else
			current.Insert(finalKey, value);
	}

	// ================================================================
	// Helpers
	// ================================================================

	private void SkipWsAndComments()
	{
		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			if (b == ' ' || b == '\t') { mCursor.AdvanceByte(); continue; }
			if (b == '#') { mCursor.SkipComment(); continue; }
			if (b == '\r' || b == '\n') { mCursor.SkipNewline(); continue; }
			break;
		}
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
