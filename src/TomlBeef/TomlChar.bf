using System;
using FormatCore;
using internal FormatCore;

namespace TomlBeef;

/// Character classification for the TOML parser. UTF-8 decoding, encoding and validation and hex
/// digits come from FormatCore (`Utf8`, `Hex`).
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
		// Fast pass without the line and column tracking that only an error needs (FormatCore's
		// validator: the same rules, ASCII skipped 32 and 8 bytes at a time). On any problem, including
		// a second BOM, LocateUtf8Error re-scans to report it, so errors are unchanged.
		bool hasBom = Utf8.StartsWithBom(input.Ptr, input.Length);
		start = hasBom ? 3 : 0;
		if (hasBom && Utf8.StartsWithBom(input.Ptr + 3, input.Length - 3))
			return LocateUtf8Error(input, out start);
		if (Utf8.FindInvalid<PlainUtf8Text>(input.Ptr, start, input.Length, scope String(), ?, ?) < 0)
			return .Ok;
		return LocateUtf8Error(input, out start);
	}

	/// The position-tracking validation: finds the first UTF-8 (or double BOM) error with its line,
	/// column and offset. Only run when FindInvalid has found a problem.
	static Result<void, TomlParseError> LocateUtf8Error(StringView input, out int start)
	{
		start = 0;

		int i = 0;
		int line = 1;
		int column = 1;

		// Skip a UTF-8 BOM so it does not count as a column
		if (Utf8.StartsWithBom(input.Ptr, input.Length))
		{
			start = 3;
			// Reject a second BOM immediately following the first
			if (Utf8.StartsWithBom(input.Ptr + 3, input.Length - 3))
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
			int seqLen = Utf8.SequenceLength((char8)b);
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

			uint32 ucp = (uint32)Utf8.Decode(input.Ptr, i, ?);

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
