using System;

namespace TomlBeef;

/// Structural token classification helpers for the TOML parser.
/// The parser drives the cursor directly; the scanner provides recognition
/// and scanning utility.
public static class TomlScanner
{
	/// Checks if the given byte can appear in a bare key.
	/// Allowed: A-Z, a-z, 0-9, -, _
	[Inline]
	public static bool IsBareKeyChar(char8 c)
	{
		return (c >= 'A' && c <= 'Z') ||
		       (c >= 'a' && c <= 'z') ||
		       (c >= '0' && c <= '9') ||
		       c == '-' || c == '_';
	}

	/// Checks if the given byte can appear in a bare value token.
	/// This is broader than bare key chars since it includes +, ., :, T, Z, etc.
	[Inline]
	public static bool IsBareValueChar(char8 c)
	{
		if (IsBareKeyChar(c))
			return true;
		// Additionally allow chars found in numbers, dates, booleans
		return c == '+' || c == '-' || c == '.' || c == ':' || c == 'T' || c == 't' ||
		       c == 'Z' || c == 'z' || c == '_' || (c >= '0' && c <= '9');
	}

	/// Checks if a byte is horizontal whitespace (space or tab).
	[Inline]
	public static bool IsWhitespace(char8 c)
	{
		return c == ' ' || c == '\t';
	}

	/// Checks if a byte is a newline character (LF or CR).
	[Inline]
	public static bool IsNewline(char8 c)
	{
		return c == '\r' || c == '\n';
	}

	/// Checks if a byte is a digit (0-9).
	[Inline]
	public static bool IsDigit(char8 c)
	{
		return c >= '0' && c <= '9';
	}

	/// Checks if a byte is a hex digit (0-9, A-F, a-f).
	[Inline]
	public static bool IsHexDigit(char8 c)
	{
		return (c >= '0' && c <= '9') ||
		       (c >= 'A' && c <= 'F') ||
		       (c >= 'a' && c <= 'f');
	}

	/// Checks if a byte is a binary digit (0 or 1).
	[Inline]
	public static bool IsBinaryDigit(char8 c)
	{
		return c == '0' || c == '1';
	}

	/// Checks if a byte is an octal digit (0-7).
	[Inline]
	public static bool IsOctalDigit(char8 c)
	{
		return c >= '0' && c <= '7';
	}

	/// Returns the length of a string token in bytes, given a cursor at the start
	/// of a basic string. Advances cursor to end of token.
	/// @param cursor The cursor (advanced to end of token).
	/// @param length Output: length of the token in bytes.
	/// @returns Ok on success, Err if unterminated.
	public static Result<void> ScanBasicString(TomlCursor cursor, out int length)
	{
		int start = cursor.Offset;

		// Single-line basic string
		cursor.AdvanceByte(); // skip opening "

		while (!cursor.IsEOF)
		{
			char8 b = cursor.PeekByte();
			if (b == '"')
			{
				cursor.AdvanceByte(); // skip closing "
				length = cursor.Offset - start;
				return .Ok;
			}
			if (b == '\\')
			{
				cursor.AdvanceByte(); // skip backslash
				if (!cursor.IsEOF)
					cursor.AdvanceByte(); // skip escaped char
				continue;
			}
			if (b == '\r' || b == '\n')
				break; // Unterminated
			cursor.AdvanceByte();
		}

		length = cursor.Offset - start;
		return .Err;
	}

	/// Returns the length of a multi-line basic string token in bytes.
	/// @param cursor The cursor (advanced to end of token).
	/// @param length Output: length of the token in bytes.
	/// @returns Ok on success, Err if unterminated.
	public static Result<void> ScanMultiLineBasicString(TomlCursor cursor, out int length)
	{
		int start = cursor.Offset;

		// Skip opening """
		cursor.AdvanceByte();
		cursor.AdvanceByte();
		cursor.AdvanceByte();

		while (!cursor.IsEOF)
		{
			if (cursor.PeekByte() == '"' &&
			    cursor.PeekByteAt(1) == '"' &&
			    cursor.PeekByteAt(2) == '"')
			{
				// Check it's not 4+ quotes
				if (cursor.PeekByteAt(3) != '"')
				{
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					length = cursor.Offset - start;
					return .Ok;
				}
			}
			cursor.AdvanceByte();
		}

		length = cursor.Offset - start;
		return .Err;
	}

	/// Returns the length of a literal string token in bytes.
	/// @param cursor The cursor (advanced to end of token).
	/// @param length Output: length of the token in bytes.
	/// @returns Ok on success, Err if unterminated.
	public static Result<void> ScanLiteralString(TomlCursor cursor, out int length)
	{
		int start = cursor.Offset;

		// Single-line literal string
		cursor.AdvanceByte(); // skip opening '

		while (!cursor.IsEOF)
		{
			char8 b = cursor.PeekByte();
			if (b == '\'')
			{
				cursor.AdvanceByte(); // skip closing '
				length = cursor.Offset - start;
				return .Ok;
			}
			if (b == '\r' || b == '\n')
				break; // Unterminated
			cursor.AdvanceByte();
		}

		length = cursor.Offset - start;
		return .Err;
	}

	/// Returns the length of a multi-line literal string token in bytes.
	/// @param cursor The cursor (advanced to end of token).
	/// @param length Output: length of the token in bytes.
	/// @returns Ok on success, Err if unterminated.
	public static Result<void> ScanMultiLineLiteralString(TomlCursor cursor, out int length)
	{
		int start = cursor.Offset;

		// Skip opening '''
		cursor.AdvanceByte();
		cursor.AdvanceByte();
		cursor.AdvanceByte();

		while (!cursor.IsEOF)
		{
			if (cursor.PeekByte() == '\'' &&
			    cursor.PeekByteAt(1) == '\'' &&
			    cursor.PeekByteAt(2) == '\'')
			{
				// Check it's not 4+ quotes
				if (cursor.PeekByteAt(3) != '\'')
				{
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					length = cursor.Offset - start;
					return .Ok;
				}
			}
			cursor.AdvanceByte();
		}

		length = cursor.Offset - start;
		return .Err;
	}

	/// Scans a bare text token (unquoted) until a structural char or whitespace.
	/// @param cursor The cursor (advanced to end of token).
	/// @param length Output: length of the token in bytes.
	public static void ScanBareText(TomlCursor cursor, out int length)
	{
		int start = cursor.Offset;

		while (!cursor.IsEOF)
		{
			char8 b = cursor.PeekByte();
			if (b == ' ' || b == '\t' || b == '\r' || b == '\n' ||
				b == '=' || b == '[' || b == ']' || b == '{' || b == '}' ||
				b == ',' || b == '#')
			{
				break;
			}
			cursor.AdvanceByte();
		}

		length = cursor.Offset - start;
	}
}
