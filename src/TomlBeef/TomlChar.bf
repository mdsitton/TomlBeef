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

}
