using System;
using FormatCore;
using internal FormatCore;
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
	/// Skips one line break: "\n", or "\r\n" as a unit. (A lone '\r' is consumed as one too; the
	/// parser rejects it first, see CountAndSkipNewline.)
	void SkipNewline() mut;

	/// Advances over a run of bytes whose TomlChar.ScanClass has none of `stopMask`'s bits, appending them
	/// to `appendTo` unless it is null. Every stop class includes '\r' and '\n', so a run stays on one line
	/// (TomlByteCursor then only moves its offset; the column is computed when read). This is the parser's
	/// bulk path for keys, strings, comments and bare values, replacing a peek/advance call per byte.
	/// Once `appendTo` holds more than `maxAppend` bytes the run may stop early (the caller then reports
	/// its size limit), so an oversized string is not copied whole first.
	/// @return The number of bytes consumed. The run ends at a stop byte, at EOF, or past `maxAppend`.
	int ScanRun(uint8 stopMask, String appendTo, int maxAppend = int.MaxValue) mut;

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
		int cpLen = Utf8.SequenceLength(b0);
		if (cpLen == 0 || cpLen > remaining)
		{
			mOffset++;
			return (char32)0xFFFD;
		}

		char32 cp = Utf8.Decode((char8*)mData.Ptr, mOffset, ?);
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

	// Inlined: the compiler stopped doing so on its own once the maxAppend cap was added, and a call per
	// comment line cost a third of the speed of skipping comments
	[Inline]
	public int ScanRun(uint8 stopMask, String appendTo, int maxAppend = int.MaxValue) mut
	{
		uint8* data = mData.Ptr;
		int start = mOffset;
		int pos = start;
		int end = mData.Length;
		// Scan no further than one byte past the caller's limit
		if (appendTo != null && maxAppend - appendTo.Length < end - start)
			end = start + Math.Max(maxAppend - appendTo.Length + 1, 0);
		if (stopMask == TomlChar.StopComment || stopMask == TomlChar.StopBasicString || stopMask == TomlChar.StopLiteralString)
			pos = ScanTextRun(data, pos, end, stopMask);
		else
		{
			while (pos < end && (TomlChar.ScanClass(data[pos]) & stopMask) == 0)
				pos++;
		}
		int count = pos - start;
		if (appendTo != null && count > 0)
			appendTo.Append((char8*)data + start, count);
		mOffset = pos;
		return count;
	}

	/// Word-at-a-time scan for comment and string text, whose runs stop only at control characters
	/// other than tab, DEL, and for strings their quote and backslash. Eight bytes are tested at once
	/// (as go-toml does): the word test flags any byte below 0x20 (so a tab too), DEL, or the extra
	/// stop bytes. Only a flagged word is walked byte by byte, which either stops at a real stop byte
	/// or steps past a tab and resumes. Bytes 0x80 and up are never stops: the input was checked as
	/// UTF-8 before parsing.
	/// @return The offset of the first stop byte, or `end`.
	static int ScanTextRun(uint8* data, int start, int end, uint8 stopMask)
	{
		const uint64 ones = 0x0101010101010101UL;
		const uint64 high = 0x8080808080808080UL;
		// Up to two extra stop bytes; DEL stands in for "none" (it is tested anyway)
		uint64 extra1 = ones * (stopMask == TomlChar.StopBasicString ? (uint64)'"' : stopMask == TomlChar.StopLiteralString ? (uint64)'\'' : 0x7F);
		uint64 extra2 = ones * (stopMask == TomlChar.StopBasicString ? (uint64)'\\' : 0x7F);
		int pos = start;
		while (true)
		{
			while (pos + 8 <= end)
			{
				uint64 word = ?;
				Internal.MemCpy(&word, data + pos, 8);
				// (w - n*ones) & ~w has a byte's high bit set if the byte is below n (exact for n <= 128);
				// with w ^ c it finds bytes equal to c
				uint64 below = (word - 0x20 * ones) & ~word;
				uint64 x1 = word ^ extra1;
				uint64 x2 = word ^ extra2;
				uint64 del = word ^ (0x7F * ones);
				uint64 equal = ((x1 - ones) & ~x1) | ((x2 - ones) & ~x2) | ((del - ones) & ~del);
				if (((below | equal) & high) != 0)
					break;
				pos += 8;
			}
			int limit = Math.Min(pos + 8, end);
			while (pos < limit && (TomlChar.ScanClass(data[pos]) & stopMask) == 0)
				pos++;
			// Stopped at a stop byte, or reached the end; otherwise the word only held a tab
			if (pos < limit || pos >= end)
				return pos;
		}
	}

	public void SkipNewline() mut
	{
		// One line break: AdvanceByte consumes "\r\n" as a unit
		if (mOffset < mData.Length && (mData[mOffset] == '\r' || mData[mOffset] == '\n')) AdvanceByte();
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
