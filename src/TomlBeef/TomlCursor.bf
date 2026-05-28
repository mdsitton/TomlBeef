using System;

namespace TomlBeef;

interface ITomlCursor
{
	int Offset { get; }
	int Line { get; }
	int Column { get; }
	bool IsEOF { get; }

	char8 PeekByte() mut;
	char8 PeekByte(int lookahead) mut;
	char8 PeekByteAt(int offset) mut;
	char8 AdvanceByte() mut;
	char32 Advance() mut;

	void SkipWhitespace() mut;
	void SkipNewline() mut;

	TomlCursorMark Mark() mut;
	StringView Slice(TomlCursorMark mark, String scratch) mut;
}

struct TomlCursorMark
{
	public int mOffset;
}

struct TomlByteCursor : ITomlCursor
{
	private Span<uint8> mData;
	private int mOffset;
	private int mLine;
	private int mColumn;

	public this(StringView input)
	{
		mData = Span<uint8>((uint8*)input.Ptr, input.Length);
		mOffset = 0;
		mLine = 1;
		mColumn = 1;
	}

	public this(Span<uint8> data)
	{
		mData = data;
		mOffset = 0;
		mLine = 1;
		mColumn = 1;
	}

	[Inline]
	public int Offset => mOffset;
	[Inline]
	public int Line => mLine;
	[Inline]
	public int Column => mColumn;
	[Inline]
	public bool IsEOF => mOffset >= mData.Length;

	[Inline]
	public char8 PeekByte() mut
	{
		if (mOffset >= mData.Length) return 0;
		return (char8)mData[mOffset];
	}

	[Inline]
	public char8 PeekByte(int lookahead) mut
	{
		int pos = mOffset + lookahead;
		if (pos >= mData.Length || pos < 0) return 0;
		return (char8)mData[pos];
	}

	[Inline]
	public char8 PeekByteAt(int offset) mut
	{
		int pos = mOffset + offset;
		if (pos >= mData.Length || pos < 0) return 0;
		return (char8)mData[pos];
	}

	public char32 Advance() mut
	{
		if (mOffset >= mData.Length) return 0;
		char8 b0 = (char8)mData[mOffset];
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

		int remaining = mData.Length - mOffset;
		int cpLen = TomlChar.Utf8SequenceLength(b0);
		if (cpLen == 0 || cpLen > remaining)
		{
			mOffset++;
			mColumn++;
			return (char32)0xFFFD;
		}

		StringView sv = StringView((char8*)mData.Ptr + mOffset, remaining);
		char32 cp = TomlChar.DecodeAt(sv, 0, cpLen);
		mOffset += cpLen;
		mColumn++;
		return cp;
	}

	public char8 AdvanceByte() mut
	{
		if (mOffset >= mData.Length) return 0;
		char8 b = (char8)mData[mOffset];
		mOffset++;
		if (b == '\r')
		{
			if (mOffset < mData.Length && mData[mOffset] == '\n')
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

	public void SkipWhitespace() mut
	{
		while (mOffset < mData.Length)
		{
			uint8 b = mData[mOffset];
			if (b == ' ' || b == '\t') AdvanceByte();
			else break;
		}
	}

	public void SkipNewline() mut
	{
		if (mOffset < mData.Length && mData[mOffset] == '\r') AdvanceByte();
		if (mOffset < mData.Length && mData[mOffset] == '\n') AdvanceByte();
	}


	[Inline]
	public TomlCursorMark Mark() mut
	{
		return TomlCursorMark() { mOffset = mOffset };
	}

	public StringView Slice(TomlCursorMark mark, String scratch)
	{
		int length = mOffset - mark.mOffset;
		if (length < 0 || mark.mOffset + length > mData.Length) return StringView();
		return StringView((char8*)mData.Ptr + mark.mOffset, length);
	}
}
