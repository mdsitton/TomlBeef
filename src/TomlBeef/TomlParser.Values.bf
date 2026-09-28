using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlParserImpl: value dispatch, strings and escapes, booleans, bare tokens, numbers.
extension TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	// ================================================================
	// Value parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseValue()
	{
		Try!(CheckDepth());
		Try!(CheckNodeCount());
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
				return Try!(FinishStringValue(result));
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
					return Try!(FinishStringValue(result));
				}
				else if (quoteCount == 4)
				{
					// 4 quotes: 1 literal quote, then 3 closing quotes
					result.Append('"');
					mCursor.AdvanceByte(); // consume the 1 literal
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte(); // consuming closing
					return Try!(FinishStringValue(result));
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
					return Try!(FinishStringValue(result));
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

				// Line-ending backslash: optional spaces/tabs, then a newline. `\ ` and `\<tab>` are never
				// valid escapes, so the whitespace is consumed as it is read rather than peeked ahead;
				// an unbounded lookahead would exceed the stream buffer on long runs.
				char8 next = mCursor.PeekByte();
				if (next == ' ' || next == '\t' || next == '\r' || next == '\n')
				{
					let escLine = mCursor.Line;
					let escColumn = mCursor.Column;
					let escOffset = mCursor.Offset;
					mCursor.SkipWhitespace();
					char8 afterWs = mCursor.PeekByte();
					if (afterWs != '\r' && afterWs != '\n')
					{
						delete result;
						return .Err(TomlParseError(.ReservedEscape, scope $"Reserved escape '\\{next}'", escLine, escColumn, escOffset));
					}
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
				return Try!(FinishStringValue(result));
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
					return Try!(FinishStringValue(result));
				}
				else if (quoteCount == 4)
				{
					result.Append('\'');
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					mCursor.AdvanceByte();
					return Try!(FinishStringValue(result));
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
					return Try!(FinishStringValue(result));
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
}
