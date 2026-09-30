using System;

namespace TomlBeef;

/// Character classification and UTF-8 encoding/decoding helpers for the TOML parser.
internal static class TomlChar
{
	// Byte classes for ITomlCursor.ScanRun: a scan of kind X advances over bytes whose class has no X bit.
	// Every class stops at '\r' and '\n', so a run never crosses a line and cursors track no line breaks
	// in it. TomlByteCursor.ScanTextRun tests the comment and string classes eight bytes at a time and
	// must stay in step with them.
	/// @brief Stops a basic-string run: '"', '\\', and control characters other than tab (incl. DEL).
	public const uint8 StopBasicString = 1;
	/// @brief Stops a literal-string run: '\'' and control characters other than tab (incl. DEL).
	public const uint8 StopLiteralString = 2;
	/// @brief Stops a comment run: control characters other than tab (incl. DEL).
	public const uint8 StopComment = 4;
	/// @brief Stops a bare-key run: anything that is not A-Z, a-z, 0-9, '-' or '_'.
	public const uint8 StopBareKey = 8;
	/// @brief Stops a bare-value run: '\r', '\n', '=', '[', ']', '{', '}', ',' and '#'.
	public const uint8 StopBareValue = 16;

	static uint8[256] sScanClass = BuildScanClasses();

	static uint8[256] BuildScanClasses()
	{
		uint8[256] classes = default;
		for (int i < 256)
		{
			char8 c = (char8)i;
			bool control = (i < 0x20 && c != '\t') || i == 0x7F;
			uint8 stop = 0;
			if (control || c == '"' || c == '\\')
				stop |= StopBasicString;
			if (control || c == '\'')
				stop |= StopLiteralString;
			if (control)
				stop |= StopComment;
			if (!IsBareKeyChar(c))
				stop |= StopBareKey;
			if (c == '\r' || c == '\n' || c == '=' || c == '[' || c == ']' || c == '{' || c == '}' || c == ',' || c == '#')
				stop |= StopBareValue;
			classes[i] = stop;
		}
		return classes;
	}

	/// @brief The scan-stop bits of byte `b` (see StopBasicString etc.).
	[Inline]
	public static uint8 ScanClass(uint8 b)
	{
		return sScanClass[b];
	}
	[Inline]
	public static bool IsBareKeyChar(char8 c)
	{
		return (c >= 'A' && c <= 'Z') ||
			(c >= 'a' && c <= 'z') ||
			(c >= '0' && c <= '9') ||
			c == '-' || c == '_';
	}

	[Inline]
	public static bool IsBareValueChar(char8 c)
	{
		if (IsBareKeyChar(c))
			return true;
		return c == '+' || c == '-' || c == '.' || c == ':' || c == 'T' || c == 't' ||
			c == 'Z' || c == 'z' || c == '_' || (c >= '0' && c <= '9');
	}

	[Inline]
	public static bool IsDigit(char8 c)
	{
		return c >= '0' && c <= '9';
	}

	[Inline]
	public static bool IsHexDigit(char8 c)
	{
		return (c >= '0' && c <= '9') ||
			(c >= 'A' && c <= 'F') ||
			(c >= 'a' && c <= 'f');
	}

	[Inline]
	public static bool IsBinaryDigit(char8 c)
	{
		return c == '0' || c == '1';
	}

	[Inline]
	public static bool IsOctalDigit(char8 c)
	{
		return c >= '0' && c <= '7';
	}

	/// @brief Return the byte length of a UTF-8 sequence starting with the given lead byte.
	/// @param lead The lead byte of the sequence.
	/// @return 1-4 for valid lead bytes, 0 for continuation/invalid bytes.
	public static int Utf8SequenceLength(char8 lead)
	{
		if ((uint8)lead < 0x80) return 1;
		if (((uint8)lead & 0xE0) == 0xC0) return 2;
		if (((uint8)lead & 0xF0) == 0xE0) return 3;
		if (((uint8)lead & 0xF8) == 0xF0) return 4;
		return 0;
	}

	/// @brief Decode a single UTF-8 code point from a known-length sequence.
	/// @param input The UTF-8 string.
	/// @param offset Byte offset of the lead byte.
	/// @param cpLen Sequence length in bytes (1-4).
	/// @return The decoded code point, or U+FFFD if cpLen is invalid.
	public static char32 DecodeAt(StringView input, int offset, int cpLen)
	{
		char8 b0 = input[offset];
		char32 cp;
		switch (cpLen)
		{
		case 1: return (char32)b0;
		case 2:
			cp = (char32)((uint8)b0 & 0x1F) << 6;
			cp |= (char32)((uint8)input[offset + 1] & 0x3F);
			return cp;
		case 3:
			cp = (char32)((uint8)b0 & 0x0F) << 12;
			cp |= (char32)((uint8)input[offset + 1] & 0x3F) << 6;
			cp |= (char32)((uint8)input[offset + 2] & 0x3F);
			return cp;
		case 4:
			cp = (char32)((uint8)b0 & 0x07) << 18;
			cp |= (char32)((uint8)input[offset + 1] & 0x3F) << 12;
			cp |= (char32)((uint8)input[offset + 2] & 0x3F) << 6;
			cp |= (char32)((uint8)input[offset + 3] & 0x3F);
			return cp;
		default: return (char32)0xFFFD;
		}
	}

	/// @brief Encode a Unicode code point as UTF-8 and append to a String.
	/// @param result The destination string.
	/// @param cp The code point to encode (must be 0–0x10FFFF, excluding surrogates).
	public static void EncodeUtf8(String result, uint32 cp)
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

	/// @brief Convert a hex digit character to its numeric value.
	/// Uses branch-minimized bitmask logic: lowercase via c|0x20, then range check.
	/// @param c The hex digit character.
	/// @return 0–15 on success, or 255 if not a hex digit.
	[Inline]
	public static uint8 HexDigitValue(char8 c)
	{
		uint32 ci = (uint8)c;
		uint32 result = ci - (uint32)'0';
		if (result <= 9)
			return (uint8)result;
		// Convert uppercase to lowercase: 'A'|0x20 == 'a'
		result = (ci | 0x20) - (uint32)'a';
		if (result <= 5)
			return (uint8)(result + 10);
		return 255;
	}

	/// @brief Convert a value 0–15 to an uppercase hex character.
	/// @param v The value (must be 0–15).
	/// @return '0'–'9' or 'A'–'F'.
	[Inline]
	public static char8 HexDigitChar(int v)
	{
		return v < 10 ? (char8)(v + '0') : (char8)(v - 10 + 'A');
	}

	/// @brief Validate a string as UTF-8 and return the start offset after an optional BOM.
	/// @param input The string to validate.
	/// @param start On success, the byte offset of the first content byte (0 or 3 if BOM was skipped).
	/// @return .Ok on success, or .Err with line/column info on invalid UTF-8 or double BOM.
	public static Result<void, TomlParseError> ValidateUtf8(StringView input, out int start)
	{
		// Fast pass without the line and column tracking that only an error needs. On any problem,
		// including a second BOM, LocateUtf8Error re-scans to report it, so errors are unchanged.
		bool hasBom = input.Length >= 3 && (uint8)input[0] == 0xEF && (uint8)input[1] == 0xBB && (uint8)input[2] == 0xBF;
		start = hasBom ? 3 : 0;
		if (hasBom && input.Length >= 6 && (uint8)input[3] == 0xEF && (uint8)input[4] == 0xBB && (uint8)input[5] == 0xBF)
			return LocateUtf8Error(input, out start);
		if (IsValidUtf8(input, start))
			return .Ok;
		return LocateUtf8Error(input, out start);
	}

	/// Whether `input` from `from` on is valid UTF-8: the same rules as LocateUtf8Error (lead and
	/// continuation bytes, truncation, overlongs, surrogates, the U+10FFFF limit). Runs of ASCII are
	/// skipped 8 bytes at a time, which makes comment- and key-heavy input nearly free to check.
	static bool IsValidUtf8(StringView input, int from)
	{
		char8* ptr = input.Ptr;
		int length = input.Length;
		int i = from;
		while (i < length)
		{
			while (i + 8 <= length)
			{
				uint64 word = ?;
				Internal.MemCpy(&word, ptr + i, 8);
				if ((word & 0x8080808080808080UL) != 0)
					break;
				i += 8;
			}
			if (i >= length)
				break;
			uint8 b = (uint8)ptr[i];
			if (b < 0x80)
			{
				i++;
				continue;
			}
			int seqLen = Utf8SequenceLength((char8)b);
			if (seqLen == 0 || i + seqLen > length)
				return false;
			for (int j = 1; j < seqLen; j++)
			{
				if (((uint8)ptr[i + j] & 0xC0) != 0x80)
					return false;
			}
			uint32 ucp = (uint32)DecodeAt(input, i, seqLen);
			if (seqLen == 2 ? ucp < 0x80 : seqLen == 3 ? ucp < 0x800 : ucp < 0x10000)
				return false;
			if ((ucp >= 0xD800 && ucp <= 0xDFFF) || ucp > 0x10FFFF)
				return false;
			i += seqLen;
		}
		return true;
	}

	/// The position-tracking validation: finds the first UTF-8 (or double BOM) error with its line,
	/// column and offset. Only run when IsValidUtf8 has found a problem.
	static Result<void, TomlParseError> LocateUtf8Error(StringView input, out int start)
	{
		start = 0;

		int i = 0;
		int line = 1;
		int column = 1;

		// Skip a UTF-8 BOM so it does not count as a column
		if (input.Length >= 3 && (uint8)input[0] == 0xEF && (uint8)input[1] == 0xBB && (uint8)input[2] == 0xBF)
		{
			start = 3;
			// Reject a second BOM immediately following the first
			if (input.Length >= 6 && (uint8)input[3] == 0xEF && (uint8)input[4] == 0xBB && (uint8)input[5] == 0xBF)
				return .Err(TomlParseError(.ControlCharInDocument, "BOM must only appear at start of file", 1, 1, 3));
			i = 3;
		}

		while (i < input.Length)
		{
			uint8 b = (uint8)input[i];
			if (b < 0x80)
			{
				if (b == (uint8)'\n')
				{
					line++;
					column = 1;
				}
				else if (b == (uint8)'\r')
				{
					line++;
					column = 1;
					// Treat \r\n as a single newline
					if (i + 1 < input.Length && (uint8)input[i + 1] == (uint8)'\n')
						i++;
				}
				else
				{
					column++;
				}
				i++;
				continue;
			}
			int seqLen = Utf8SequenceLength((char8)b);
			if (seqLen == 0)
				return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 lead byte", line, column, i));

			if (i + seqLen > input.Length)
				return .Err(TomlParseError(.InvalidUtf8, "Truncated UTF-8 sequence", line, column, i));

			// Validate continuation bytes (a bad one is reported at itself; TomlBufferedStreamCursor matches)
			for (int j = 1; j < seqLen; j++)
			{
				if (((uint8)input[i + j] & 0xC0) != 0x80)
					return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 continuation byte", line, column + j, i + j));
			}

			char32 cp = DecodeAt(input, i, seqLen);
			uint32 ucp = (uint32)cp;

			// Validate overlong sequences and surrogate range
			if (seqLen == 2 ? ucp < 0x80 : seqLen == 3 ? ucp < 0x800 : ucp < 0x10000)
				return .Err(TomlParseError(.InvalidUtf8, "Overlong UTF-8 sequence", line, column, i));
			if (ucp >= 0xD800 && ucp <= 0xDFFF)
				return .Err(TomlParseError(.InvalidUtf8, "UTF-8 surrogate pair not allowed", line, column, i));
			if (ucp > 0x10FFFF)
				return .Err(TomlParseError(.InvalidUtf8, "Codepoint beyond U+10FFFF", line, column, i));

			i += seqLen;
			column++;
		}
		return .Ok;
	}
}
