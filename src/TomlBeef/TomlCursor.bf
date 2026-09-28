using System;
using internal TomlBeef;

namespace TomlBeef;

internal interface ITomlCursor
{
	int Offset { get; }
	int Line { get; }
	/// 1-based column in code points. May be computed on demand (TomlByteCursor), so reading it can
	/// update a cache.
	int Column { get mut; }
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
	/// (TomlByteCursor then only moves its offset; the column is computed when read). This is the parser's
	/// bulk path for keys, strings, comments and bare values, replacing a peek/advance call per byte.
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
	// The column is computed on demand: one plus the code points from the start of the line to the
	// current offset (the input is valid UTF-8, checked before parsing). Counting it per byte kept
	// every scan byte-at-a-time, while the parser reads it about once per statement. The cache holds
	// the last answer on this line, so repeated reads along one long line stay linear.
	private int mLineStart;
	private int mColumnCacheOffset;
	private int mColumnCacheValue;

	public this(StringView input)
	{
		this = default;
		mData = Span<uint8>((uint8*)input.Ptr, input.Length);
		mLine = 1;
		mColumnCacheValue = 1;
	}

	public this(Span<uint8> data)
	{
		this = default;
		mData = data;
		mLine = 1;
		mColumnCacheValue = 1;
	}

	/// Starts reading at `startOffset` (e.g. past a BOM) while keeping offsets relative to the start
	/// of `data`, so error offsets match the raw input on every read path.
	public this(Span<uint8> data, int startOffset)
	{
		this = default;
		mData = data;
		mOffset = startOffset;
		mLine = 1;
		mLineStart = startOffset;
		mColumnCacheOffset = startOffset;
		mColumnCacheValue = 1;
	}

	[Inline]
	public int Offset => mOffset;
	[Inline]
	public int Line => mLine;

	public int Column
	{
		[Inline]
		get mut
		{
			// Most reads are at the start of a key, usually at the start of its line
			if (mOffset == mLineStart)
				return 1;
			return CountColumn();
		}
	}

	/// Counts code points from the cached answer when it is on this line, else from the line start.
	/// The cursor only moves forward, and a new line starts past any earlier cached offset.
	private int CountColumn() mut
	{
		int from = mLineStart;
		int column = 1;
		if (mColumnCacheOffset >= mLineStart)
		{
			from = mColumnCacheOffset;
			column = mColumnCacheValue;
		}
		uint8* data = mData.Ptr;
		for (int i = from; i < mOffset; i++)
		{
			// Every byte but a UTF-8 continuation byte starts a code point
			if ((data[i] & 0xC0) != 0x80)
				column++;
		}
		mColumnCacheOffset = mOffset;
		mColumnCacheValue = column;
		return column;
	}

	/// Starts a new line at the current offset (just past its line break).
	[Inline]
	private void StartLine() mut
	{
		mLine++;
		mLineStart = mOffset;
	}
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
				StartLine();
			return (char32)b0;
		}

		int remaining = mData.Length - mOffset;
		int cpLen = TomlChar.Utf8SequenceLength(b0);
		if (cpLen == 0 || cpLen > remaining)
		{
			mOffset++;
			return (char32)0xFFFD;
		}

		StringView sv = StringView((char8*)mData.Ptr + mOffset, remaining);
		char32 cp = TomlChar.DecodeAt(sv, 0, cpLen);
		mOffset += cpLen;
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
		StartLine();
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
		mOffset = pos;
	}

	public int ScanRun(uint8 stopMask, String appendTo) mut
	{
		uint8* data = mData.Ptr;
		int start = mOffset;
		int pos = start;
		int end = mData.Length;
		while (pos < end && (TomlChar.ScanClass(data[pos]) & stopMask) == 0)
			pos++;
		int count = pos - start;
		if (appendTo != null && count > 0)
			appendTo.Append((char8*)data + start, count);
		mOffset = pos;
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
