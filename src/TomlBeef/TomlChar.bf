using System;

namespace TomlBeef;

/// Character classification and UTF-8 encoding/decoding helpers for the TOML parser.
public static class TomlChar
{
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
}
