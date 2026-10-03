using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
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
		Try!(CheckNodeCount());

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

	/// Where the value ParseValue just read ended: a bare value's scan also takes the spaces after its
	/// token (see ParseBareValue), every other value ends at the cursor. `first` is the value's first byte.
	private int ValueEnd(char8 first)
	{
		switch (first)
		{
		case '"', '\'', '[', '{', 't', 'f': return mCursor.Offset;
		default: return mValueEnd;
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
		String result = mStringScratch..Clear();
		if (DecodeBasicString(result, false) case .Err(let err))
		{
			result.Clear();
			return .Err(err);
		}
		return FinishStringValue(result);
	}

	/// Decodes a single-line basic string, from after its opening quote through its closing quote, into
	/// `result`. Values and quoted keys share it, so both follow one set of rules; only values count
	/// toward MaxStringBytes (checked as the string grows).
	/// @param isKey Whether this is a key (no size limit; errors name a string key).
	[Inline]
	private Result<void, TomlParseError> DecodeBasicString(String result, bool isKey)
	{
		let limit = isKey ? int.MaxValue : StringByteLimit;
		while (true)
		{
			// Copy the plain text up to the next quote, backslash, newline or control character
			mCursor.ScanRun(TomlChar.StopBasicString, result, limit);
			if (result.Length > limit)
				Try!(CheckStringLength(result.Length));
			if (mCursor.IsEOF)
				break;
			char8 b = mCursor.PeekByte();
			if (b == '"')
			{
				mCursor.AdvanceByte();
				return .Ok;
			}
			if (b == '\\')
			{
				mCursor.AdvanceByte();
				Try!(ParseEscapeSequence(result));
				continue;
			}
			if (b == '\r' || b == '\n')
				break;
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInString, isKey ? "Control character in string key" : "Control character in basic string"));
			result.Append(mCursor.Advance());
		}
		return .Err(Error(.UnterminatedString, isKey ? "Unterminated string key" : "Unterminated basic string"));
	}

	private Result<TomlValue, TomlParseError> ParseMultiLineBasicString()
	{
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			Try!(SkipStringNewline());

		String result = mStringScratch..Clear();

		while (!mCursor.IsEOF)
		{
			Try!(CheckStringLength(result.Length));
			if (mCursor.PeekByte() == '"' &&mCursor.PeekByteAt(1) == '"' && mCursor.PeekByteAt(2) == '"')
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
					result.Clear();
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
						result.Clear();
						return .Err(TomlParseError(.ReservedEscape, scope $"Reserved escape '\\{next}'", escLine, escColumn, escOffset));
					}
					// Everything up to the next content goes: newlines and indentation, including
					// indented blank lines
					while (true)
					{
						char8 ws = mCursor.PeekByte();
						if (ws == ' ' || ws == '\t')
							mCursor.SkipWhitespace();
						else if (!mCursor.IsEOF && (ws == '\r' || ws == '\n'))
						{
							if (SkipStringNewline() case .Err(let nlErr))
							{
								result.Clear();
								return .Err(nlErr);
							}
						}
						else
							break;
					}
					continue;
				}

				switch (ParseEscapeSequence(result))
				{
				case .Err(let err):
					result.Clear();
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
					result.Clear();
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
				result.Clear();
				return .Err(Error(.ControlCharInString, "Control character in multi-line basic string"));
			}

			result.Append(mCursor.Advance());
		}

		result.Clear();
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
			uint8 v = Hex.DigitValue(c);
			if (v == 255)
				return .Err(Error(.InvalidEscape, "Invalid hex digit"));

			cp = (cp << 4) | v;
			mCursor.AdvanceByte();
		}

		if (cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF))
			return .Err(Error(.InvalidUnicodeScalar, "Invalid Unicode scalar value"));

		Utf8.Encode(result, cp);
		return .Ok;
	}

	private Result<TomlValue, TomlParseError> ParseSingleLineLiteralString()
	{
		mCursor.AdvanceByte();
		String result = mStringScratch..Clear();
		let limit = StringByteLimit;

		while (true)
		{
			// Copy the text up to the closing quote, a newline or a control character
			mCursor.ScanRun(TomlChar.StopLiteralString, result, limit);
			Try!(CheckStringLength(result.Length));
			if (mCursor.IsEOF)
				break;
			char8 b = mCursor.PeekByte();
			if (b == '\'')
			{
				mCursor.AdvanceByte();
				return Try!(FinishStringValue(result));
			}
			if (b == '\r' || b == '\n')
			{
				result.Clear();
				return .Err(Error(.UnterminatedString, "Unterminated literal string"));
			}
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
			{
				result.Clear();
				return .Err(Error(.ControlCharInString, "Control character in literal string"));
			}
			result.Append(mCursor.Advance());
		}

		result.Clear();
		return .Err(Error(.UnterminatedString, "Unterminated literal string"));
	}

	private Result<TomlValue, TomlParseError> ParseMultiLineLiteralString()
	{
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();
		mCursor.AdvanceByte();

		if (mCursor.PeekByte() == '\r' || mCursor.PeekByte() == '\n')
			Try!(SkipStringNewline());

		String result = mStringScratch..Clear();

		while (!mCursor.IsEOF)
		{
			Try!(CheckStringLength(result.Length));
			if (mCursor.PeekByte() == '\'' &&mCursor.PeekByteAt(1) == '\'' && mCursor.PeekByteAt(2) == '\'')
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
					result.Clear();
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
					result.Clear();
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
				result.Clear();
				return .Err(Error(.ControlCharInString, "Control character in multi-line literal string"));
			}

			result.Append(mCursor.Advance());
		}

		result.Clear();
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
		// Up to a delimiter: '\r', '\n', '=', '[', ']', '{', '}', ',' or '#'
		mCursor.ScanRun(TomlChar.StopBareValue, null);

		int length = mCursor.Offset - mark.mOffset;
		if (length == 0)
		{
			mCursor.ReleaseMark(mark);
			return .Err(Error(.UnexpectedToken, "Expected value"));
		}

		// The scratch is only filled when a stream read spills; the token is used before the next value
		StringView token = mCursor.Slice(mark, mSliceScratch);
		// Leading whitespace was skipped before the value; only spaces and tabs can trail it (a newline
		// or other delimiter ends the scan). Other characters stay and make the value invalid.
		while (token.Length > 0 && (token[token.Length - 1] == ' ' || token[token.Length - 1] == '\t'))
			token.Length--;
		mValueEnd = mark.mOffset + token.Length;
		return ParseBareToken(token);
	}

	private Result<TomlValue, TomlParseError> ParseBareToken(StringView token)
	{
		if (token.IsEmpty)
			return .Err(Error(.UnexpectedToken, "Empty value"));

		// The most common bare value, a plain decimal integer, skips the keyword, date and number
		// checks below
		if (TryParsePlainInteger(token, var plain))
			return TomlValue.Integer(plain);
		// The same idea for the common forms of floats
		if (TryParsePlainFloat(token, var plainFloat))
			return TomlValue.Float(plainFloat);
		// Kept out of line so the paths above stay small
		return ParseOtherBareToken(token);
	}

	private Result<TomlValue, TomlParseError> ParseOtherBareToken(StringView token)
	{
		// And for date/times
		if (TryParsePlainDateTime(token, var plainDateTime))
			return plainDateTime;

		// Keywords never start with a digit, while dates and most numbers do
		if (!TomlChar.IsDigit(token[0]))
		{
			if (token == "true") return TomlValue.Bool(true);
			if (token == "false") return TomlValue.Bool(false);

			if (token == "inf" || token == "+inf")
				return TomlValue.Float(double.PositiveInfinity);
			if (token == "-inf")
				return TomlValue.Float(double.NegativeInfinity);
			if (token == "nan" || token == "+nan" || token == "-nan")
				return TomlValue.Float(double.NaN);
		}

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

	/// One-pass parse of an optional sign and 1–18 decimal digits with no leading zero (other than a
	/// lone "0"): valid as written and unable to overflow int64. Anything else, including every
	/// invalid token, returns false and takes the full path, so errors are unchanged.
	[Inline]
	private static bool TryParsePlainInteger(StringView token, out int64 value)
	{
		value = 0;
		char8* ptr = token.Ptr;
		int length = token.Length;
		int pos = (ptr[0] == '-' || ptr[0] == '+') ? 1 : 0;
		int digits = length - pos;
		if (digits < 1 || digits > 18 || (ptr[pos] == '0' && digits > 1))
			return false;
		int64 result = 0;
		for (int i = pos; i < length; i++)
		{
			uint8 digit = (uint8)ptr[i] - (uint8)'0';
			if (digit > 9)
				return false;
			result = result * 10 + digit;
		}
		value = (ptr[0] == '-') ? -result : result;
		return true;
	}

	/// Powers of ten that a double holds exactly (5^22 < 2^53).
	const double[23] cExactPowersOf10 = .(1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11, 1e12,
		1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22);

	/// One-pass parse of a float without underscores, `[sign]digits[.digits][(e|E)[sign]digits]`, whose
	/// digits fit an exact double mantissa (at most 2^53, 19 digits) and whose decimal exponent is within
	/// ±22. Then mantissa and power of ten are both exact, and one IEEE multiply or divide rounds
	/// correctly (Clinger's fast path). Anything else returns false and takes the full path, so errors
	/// are unchanged.
	private static bool TryParsePlainFloat(StringView token, out double value)
	{
		value = 0;
		char8* ptr = token.Ptr;
		int length = token.Length;
		int pos = (ptr[0] == '-' || ptr[0] == '+') ? 1 : 0;

		uint64 mantissa = 0;
		int intStart = pos;
		while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9)
			mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
		int intDigits = pos - intStart;
		if (intDigits == 0 || intDigits > 19 || (ptr[intStart] == '0' && intDigits > 1))
			return false;

		int exponent = 0;
		bool isFloat = false;
		if (pos < length && ptr[pos] == '.')
		{
			pos++;
			int fracStart = pos;
			while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9 && pos - fracStart + intDigits < 19)
				mantissa = mantissa * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == fracStart)
				return false;
			exponent = -(pos - fracStart);
			isFloat = true;
		}
		if (pos < length && (ptr[pos] == 'e' || ptr[pos] == 'E'))
		{
			pos++;
			bool negativeExponent = false;
			if (pos < length && (ptr[pos] == '-' || ptr[pos] == '+'))
				negativeExponent = ptr[pos++] == '-';
			int expStart = pos;
			int expValue = 0;
			while (pos < length && (uint8)ptr[pos] - (uint8)'0' <= 9 && pos - expStart < 4)
				expValue = expValue * 10 + ((uint8)ptr[pos++] - (uint8)'0');
			if (pos == expStart)
				return false;
			exponent += negativeExponent ? -expValue : expValue;
			isFloat = true;
		}
		// A leftover character (an underscore, a 20th digit, a 5-digit exponent, anything invalid) or a
		// plain integer goes to the full path
		if (pos != length || !isFloat || mantissa > (1UL << 53) || exponent < -22 || exponent > 22)
			return false;

		double result = (double)mantissa;
		if (exponent < 0)
			result /= cExactPowersOf10[-exponent];
		else
			result *= cExactPowersOf10[exponent];
		value = (ptr[0] == '-') ? -result : result;
		return true;
	}

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
			uint8 hv = Hex.DigitValue(c);
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
		// ParseNumber has validated the token; FormatCore skips its underscores and parses with `.` as the
		// decimal point whatever the current culture (corlib's Double.Parse follows the user's locale)
		if (!DecimalParse.ParseDouble(token, let val))
			return .Err(Error(.InvalidFloat, "Invalid float value"));
		return TomlValue.Float(val);
	}
}
