using System;
using internal TomlBeef;

namespace TomlBeef;

internal interface ITomlCursor
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

	/// Advances over a run of bytes whose TomlChar.ScanClass has none of `stopMask`'s bits, appending them
	/// to `appendTo` unless it is null. Every stop class includes '\r' and '\n', so a run stays on one line
	/// and only the column moves (by one per code point). This is the parser's bulk path for keys, strings,
	/// comments and bare values, replacing a peek/advance call per byte.
	/// @return The number of bytes consumed. The run ends at a stop byte or at EOF.
	int ScanRun(uint8 stopMask, String appendTo) mut;

	/// Marks nest: every Mark() must be released by exactly one Slice() or ReleaseMark(), innermost first.
	/// Streaming cursors retain input from the outermost active mark until it is released.
	TomlCursorMark Mark() mut;
	/// Returns the text from the mark to the current position and releases the mark.
	/// The view is only valid until the cursor next advances or peeks.
	StringView Slice(TomlCursorMark mark, String scratch) mut;
	/// Releases a mark without reading its text.
	void ReleaseMark(TomlCursorMark mark) mut;
}

internal struct TomlCursorMark
{
	public int mOffset;
}

internal struct TomlByteCursor : ITomlCursor
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

	/// Starts reading at `startOffset` (e.g. past a BOM) while keeping offsets relative to the start
	/// of `data`, so error offsets match the raw input on every read path.
	public this(Span<uint8> data, int startOffset)
	{
		mData = data;
		mOffset = startOffset;
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

	[Inline]
	public char8 AdvanceByte() mut
	{
		if (mOffset >= mData.Length) return 0;
		char8 b = (char8)mData[mOffset];
		// Common case inline; newline bookkeeping (and CRLF lookahead) out of line
		if (b != '\n' && b != '\r')
		{
			mOffset++;
			mColumn++;
			return b;
		}
		return AdvanceNewline(b);
	}

	/// Consumes a '\n', or a '\r' plus a following '\n', and starts a new line.
	private char8 AdvanceNewline(char8 b) mut
	{
		mOffset++;
		if (b == '\r' && mOffset < mData.Length && mData[mOffset] == '\n')
			mOffset++;
		mLine++;
		mColumn = 1;
		return b;
	}

	public void SkipWhitespace() mut
	{
		// Spaces and tabs never start a new line, so step past them directly
		int pos = mOffset;
		while (pos < mData.Length)
		{
			uint8 b = mData[pos];
			if (b != ' ' && b != '\t')
				break;
			pos++;
		}
		mColumn += pos - mOffset;
		mOffset = pos;
	}

	public int ScanRun(uint8 stopMask, String appendTo) mut
	{
		uint8* data = mData.Ptr;
		int start = mOffset;
		int pos = start;
		int end = mData.Length;
		int columns = 0;
		while (pos < end)
		{
			uint8 b = data[pos];
			if ((TomlChar.ScanClass(b) & stopMask) != 0)
				break;
			// Columns count code points: every byte except UTF-8 continuation bytes
			if ((b & 0xC0) != 0x80)
				columns++;
			pos++;
		}
		int count = pos - start;
		if (appendTo != null && count > 0)
			appendTo.Append((char8*)data + start, count);
		mOffset = pos;
		mColumn += columns;
		return count;
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

	public void ReleaseMark(TomlCursorMark mark)
	{
	}
}
