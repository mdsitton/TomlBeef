using System;

namespace TomlBeef;

class TomlCursor
{
	private StringView mInput;
	private int mOffset;
	private int mLine;
	private int mColumn;

	public this(StringView input)
	{
		mInput = input;
		mOffset = 0;
		mLine = 1;
		mColumn = 1;
	}

	public int Offset => mOffset;
	public int Line => mLine;
	public int Column => mColumn;
	public bool IsEOF => mOffset >= mInput.Length;

	public StringView Remaining => mInput.Substring(mOffset);

	public char8 PeekByte()
	{
		if (mOffset >= mInput.Length) return 0;
		return mInput[mOffset];
	}

	public char8 PeekByteAt(int offset)
	{
		int pos = mOffset + offset;
		if (pos >= mInput.Length || pos < 0) return 0;
		return mInput[pos];
	}

	public char32 Advance()
	{
		if (mOffset >= mInput.Length) return 0;
		char8 b0 = mInput[mOffset];
		if ((uint8)b0 < 0x80)
		{
			mOffset++;
			if (b0 == '\n')
			{
				mLine++;
				mColumn = 1;
			}
			else
			{
				mColumn++;
			}
			return (char32)b0;
		}

		int remaining = mInput.Length - mOffset;
		int cpLen = Utf8SequenceLength(b0);
		if (cpLen == 0 || cpLen > remaining)
		{
			mOffset++;
			mColumn++;
			return (char32)0xFFFD;
		}

		char32 cp = DecodeAt(mInput, mOffset, cpLen);
		mOffset += cpLen;
		mColumn++;
		return cp;
	}

	public char8 AdvanceByte()
	{
		if (mOffset >= mInput.Length) return 0;
		char8 b = mInput[mOffset];
		mOffset++;
		if (b == '\r')
		{
			// CRLF: consume LF as part of this newline
			if (mOffset < mInput.Length && mInput[mOffset] == '\n')
				mOffset++;
			mLine++;
			mColumn = 1;
		}
		else if (b == '\n')
		{
			mLine++;
			mColumn = 1;
		}
		else
		{
			mColumn++;
		}
		return b;
	}

	public bool Match(StringView s)
	{
		if (mOffset + s.Length > mInput.Length) return false;
		for (int i = 0; i < s.Length; i++)
			if (mInput[mOffset + i] != s[i]) return false;
		for (int i = 0; i < s.Length; i++)
			AdvanceByte();
		return true;
	}

	public void SkipWhitespace()
	{
		while (mOffset < mInput.Length)
		{
			char8 b = mInput[mOffset];
			if (b == ' ' || b == '\t') AdvanceByte();
			else break;
		}
	}

	public void SkipNewline()
	{
		if (mOffset < mInput.Length && mInput[mOffset] == '\r') AdvanceByte();
		if (mOffset < mInput.Length && mInput[mOffset] == '\n') AdvanceByte();
	}

	public Result<void, TomlParseError> SkipComment()
	{
		if (mOffset >= mInput.Length || mInput[mOffset] != '#') return .Ok;
		AdvanceByte(); // skip '#'

		while (mOffset < mInput.Length)
		{
			char8 b = mInput[mOffset];
			if (b == '\r')
			{
				// CR is only valid as part of CRLF; bare CR is a control char error
				if (mOffset + 1 < mInput.Length && mInput[mOffset + 1] == '\n')
					break;
				return .Err(TomlParseError(.ControlCharInDocument, "Bare CR in comment", mLine, mColumn, mOffset));
			}
			if (b == '\n') break;

			// Validate: control characters other than tab are forbidden in comments
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(TomlParseError(.ControlCharInDocument, "Control character in comment", mLine, mColumn, mOffset));

			AdvanceByte();
		}
		SkipNewline();
		return .Ok;
	}

	public StringView Slice(int offset, int length)
	{
		if (offset < 0 || offset + length > mInput.Length) return StringView();
		return mInput.Substring(offset, length);
	}

	private static int Utf8SequenceLength(char8 lead)
	{
		if ((uint8)lead < 0x80) return 1;
		if (((uint8)lead & 0xE0) == 0xC0) return 2;
		if (((uint8)lead & 0xF0) == 0xE0) return 3;
		if (((uint8)lead & 0xF8) == 0xF0) return 4;
		return 0;
	}

	private static char32 DecodeAt(StringView input, int offset, int cpLen)
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
}
