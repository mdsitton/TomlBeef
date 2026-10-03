using System;
using FormatCore;
using internal FormatCore;
using internal TomlBeef;

namespace TomlBeef;

/// TOML's character rules for FormatCore's cursors: UTF-8 checked before the parser sees it (every
/// code point may appear in strings and comments; control characters are the grammar's errors), lines
/// ending at LF, CR or CRLF.
internal typealias TomlText = PlainUtf8Text;

internal interface ITomlCursor
{
	int Offset { get; }
	int Line { get; }
	/// 1-based column in code points. Computed on demand, so reading it can update a cache.
	int Column { get mut; }
	/// Whether the input has no more bytes (a stream reads ahead to find out).
	bool IsEOF { get mut; }

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
	/// (the cursor then only moves its offset; the column is computed when read). This is the parser's
	/// bulk path for keys, strings, comments and bare values, replacing a peek/advance call per byte.
	/// Once `appendTo` holds more than `maxAppend` bytes the run may stop early (the caller then reports
	/// its size limit), so an oversized string is not copied whole first.
	/// @return The number of bytes consumed. The run ends at a stop byte, at EOF, or past `maxAppend`.
	int ScanRun(uint8 stopMask, String appendTo, int maxAppend = int.MaxValue) mut;

	/// Marks nest: every Mark() must be released by exactly one Slice() or ReleaseMark(), innermost first.
	/// The input from the outermost active mark on stays in the window until it is released.
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

/// The parser's cursor over a window of FormatCore's input (survey-input.md §1.3, "TOML migration"):
/// `data[offset]` for `mBase <= offset < mEnd`, absolute offsets, refilled through the input cursor
/// (ByteCursor for memory, whose Fill folds to `false`; BufferedStreamCursor for streams). The input is
/// UTF-8 checked by the input cursor before the parser sees it (all of a memory input, each refill of a
/// stream, the same validator and messages either way). Marks keep their span in the window, which grows
/// for a long one (no spill copy), and MaxTokenBytes bounds a marked span plus the lookahead.
///
/// Lines are counted as the parser crosses line breaks (LF, CRLF, and a lone CR through AdvanceByte);
/// a column is counted on request (FormatCore's SWAR code-point count) from the line start or from the
/// last column asked on the line, a base that a stream refill moves forward before it drops the line's
/// start.
internal struct TomlWindowCursor<TInput> : ITomlCursor where TInput : IInputCursor
{
	char8* mData;
	int mPos;
	int mEnd;
	int mLine;
	int mLineStart;
	int mBase;
	int mColumnCacheOffset;
	int mColumnCacheValue;
	/// Active (unreleased) marks, and the outermost one's offset (kept in the window while any is).
	int mMarkDepth;
	int mRetainStart;
	// Last: the hot window fields above come first
	TInput mInput;

	/// @brief A cursor over `input` (call Begin before anything else).
	/// @param input The input cursor.
	public this(TInput input)
	{
		this = default;
		mInput = input;
		mLine = 1;
		mColumnCacheValue = 1;
	}

	/// @brief Sets up the window: the input's own checks (size, encoding, a BOM, UTF-8), then TOML's
	/// one about the BOM (a second one right after the first is not allowed).
	/// @return .Ok, or the input's error.
	public Result<void, InputError> Begin() mut
	{
		int start = Try!(mInput.Begin(ref mData, ref mBase, ref mEnd));
		mPos = start;
		mLineStart = start;
		mColumnCacheOffset = start;
		mColumnCacheValue = 1;
		if (start == 3 && Avail(3) && Utf8.StartsWithBom(mData + 3, 3))
			return .Err(InputError(.ByteOrderMark, "BOM must only appear at start of file", 1, 1, 3, 1));
		return .Ok;
	}


	/// Whether `count` bytes from the position are in the window, refilling it if they are not.
	[Inline]
	bool Avail(int count) mut
	{
		return mPos + count <= mEnd || Grow(count);
	}

	/// Asks the input for more (memory: never; this folds away).
	[Inline]
	bool Grow(int count) mut
	{
		if (mInput.IsWhole)
			return false;
		return GrowStream(count);
	}

	/// A stream's refill: keeps the window from the outermost mark (or the position) on, after moving
	/// the column base past the bytes it may drop.
	[NoInline]
	bool GrowStream(int count) mut
	{
		int keep = mMarkDepth > 0 ? Math.Min(mRetainStart, mPos) : mPos;
		if (mLineStart < keep && mColumnCacheOffset < keep)
			CacheColumnAt(keep);
		mInput.Fill(ref mData, ref mBase, ref mEnd, keep, mPos, count);
		return mPos + count <= mEnd;
	}

	[Inline]
	public int Offset => mPos;
	[Inline]
	public int Line => mLine;

	public int Column
	{
		[Inline]
		get mut
		{
			// Most reads are at the start of a key, usually at the start of its line
			if (mPos == mLineStart)
				return 1;
			return CacheColumnAt(mPos);
		}
	}

	/// The column of `offset` (on the current line, at or after the last cached answer), cached. The
	/// cursor only moves forward, and a new line starts past any earlier cached offset.
	int CacheColumnAt(int offset) mut
	{
		int from = mLineStart;
		int column = 1;
		if (mColumnCacheOffset >= mLineStart)
		{
			from = mColumnCacheOffset;
			column = mColumnCacheValue;
		}
		// Columns are read per statement and per array element, mostly a few bytes from the last answer:
		// short spans byte by byte here, long ones 8 bytes at a time (FormatCore's CountCodePoints)
		if (offset - from < 32)
		{
			for (int i = from; i < offset; i++)
			{
				// Every byte but a UTF-8 continuation byte starts a code point
				if (((uint8)mData[i] & 0xC0) != 0x80)
					column++;
			}
		}
		else
			column += Utf8.CountCodePoints(mData, from, offset);
		mColumnCacheOffset = offset;
		mColumnCacheValue = column;
		return column;
	}

	/// Starts a new line at the current offset (just past its line break).
	[Inline]
	void StartLine() mut
	{
		mLine++;
		mLineStart = mPos;
	}

	public bool IsEOF
	{
		[Inline]
		get mut => !Avail(1);
	}

	[Inline]
	public char8 PeekByte() mut
	{
		if (!Avail(1)) return 0;
		return mData[mPos];
	}

	[Inline]
	public char8 PeekByte(int lookahead) mut
	{
		if (lookahead < 0 || !Avail(lookahead + 1)) return 0;
		return mData[mPos + lookahead];
	}

	[Inline]
	public char8 PeekByteAt(int offset) mut
	{
		return PeekByte(offset);
	}

	public char32 Advance() mut
	{
		if (!Avail(1)) return 0;
		char8 b0 = mData[mPos];
		if ((uint8)b0 < 0x80)
		{
			mPos++;
			if (b0 == '\n')
				StartLine();
			return (char32)b0;
		}
		int cpLen = Utf8.SequenceLength(b0);
		if (cpLen == 0 || !Avail(cpLen))
		{
			mPos++;
			return (char32)0xFFFD;
		}
		char32 cp = Utf8.Decode(mData, mPos, ?);
		mPos += cpLen;
		return cp;
	}

	[Inline]
	public char8 AdvanceByte() mut
	{
		if (!Avail(1)) return 0;
		char8 b = mData[mPos];
		// Common case inline; newline bookkeeping (and CRLF lookahead) out of line
		if (b != '\n' && b != '\r')
		{
			mPos++;
			return b;
		}
		return AdvanceNewline(b);
	}

	/// Consumes a '\n', or a '\r' plus a following '\n', and starts a new line.
	char8 AdvanceNewline(char8 b) mut
	{
		mPos++;
		if (b == '\r' && Avail(1) && mData[mPos] == '\n')
			mPos++;
		StartLine();
		return b;
	}

	public void SkipWhitespace() mut
	{
		// Spaces and tabs never start a new line, so step past them directly
		while (true)
		{
			int pos = mPos;
			while (pos < mEnd)
			{
				char8 b = mData[pos];
				if (b != ' ' && b != '\t')
					break;
				pos++;
			}
			mPos = pos;
			if (pos < mEnd || !Grow(1))
				return;
		}
	}

	// Inlined: a call per comment line cost a third of the speed of skipping comments (memory input)
	[Inline]
	public int ScanRun(uint8 stopMask, String appendTo, int maxAppend = int.MaxValue) mut
	{
		int total = 0;
		while (true)
		{
			int start = mPos;
			int end = mEnd;
			// Scan no further than one byte past the caller's limit
			if (appendTo != null && maxAppend - appendTo.Length < end - start)
				end = start + Math.Max(maxAppend - appendTo.Length + 1, 0);
			int pos;
			if (stopMask == TomlChar.StopComment || stopMask == TomlChar.StopBasicString || stopMask == TomlChar.StopLiteralString)
				pos = ScanTextRun((uint8*)mData, start, end, stopMask);
			else
			{
				pos = start;
				while (pos < end && (TomlChar.ScanClass((uint8)mData[pos]) & stopMask) == 0)
					pos++;
			}
			int count = pos - start;
			if (appendTo != null && count > 0)
				appendTo.Append(mData + start, count);
			mPos = pos;
			total += count;
			// A stop byte, the caller's limit, or the end of the input: the run is over; the end of the
			// window: it goes on after a refill
			if (pos < mEnd || end < mEnd || !Grow(1))
				return total;
		}
	}

	/// Word-at-a-time scan for comment and string text, whose runs stop only at control characters
	/// other than tab, DEL, and for strings their quote and backslash. Eight bytes are tested at once
	/// (as go-toml does): the word test flags any byte below 0x20 (so a tab too), DEL, or the extra
	/// stop bytes. Only a flagged word is walked byte by byte, which either stops at a real stop byte
	/// or steps past a tab and resumes. Bytes 0x80 and up are never stops: the input was checked as
	/// UTF-8 before parsing.
	/// @return The offset of the first stop byte, or `end`.
	internal static int ScanTextRun(uint8* data, int start, int end, uint8 stopMask)
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
		if (Avail(1) && (mData[mPos] == '\r' || mData[mPos] == '\n'))
			AdvanceByte();
	}

	[Inline]
	public TomlCursorMark Mark() mut
	{
		if (mMarkDepth == 0)
			mRetainStart = mPos;
		mMarkDepth++;
		return TomlCursorMark() { mOffset = mPos };
	}

	public StringView Slice(TomlCursorMark mark, String scratch) mut
	{
		StringView result = default;
		if (mark.mOffset >= mBase && mark.mOffset <= mPos)
			result = StringView(mData + mark.mOffset, mPos - mark.mOffset);
		ReleaseMark(mark);
		return result;
	}

	[Inline]
	public void ReleaseMark(TomlCursorMark mark) mut
	{
		if (mMarkDepth > 0)
			mMarkDepth--;
	}
}

/// The parser's cursor over a whole in-memory input, which FormatCore's ByteCursor has checked first
/// (size, encoding, BOM, UTF-8: the same checks and messages as a stream's). TomlWindowCursor over the
/// ByteCursor itself measured 2-8% more instructions on document reads (spread over the parser, not
/// one cause), so memory input keeps this cursor, tuned for it: a span, lines counted as they are
/// crossed, columns on request from the line start or the last answer.
internal struct TomlMemoryCursor : ITomlCursor
{
	private Span<uint8> mData;
	private int mOffset;
	private int mLine;
	private int mLineStart;
	private int mColumnCacheOffset;
	private int mColumnCacheValue;

	/// @brief A cursor over `data` from `startOffset` (past a BOM), offsets relative to `data`'s start.
	/// @param data The checked input.
	/// @param startOffset The first content byte.
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
	int CountColumn() mut
	{
		int from = mLineStart;
		int column = 1;
		if (mColumnCacheOffset >= mLineStart)
		{
			from = mColumnCacheOffset;
			column = mColumnCacheValue;
		}
		uint8* data = mData.Ptr;
		if (mOffset - from < 32)
		{
			for (int i = from; i < mOffset; i++)
			{
				// Every byte but a UTF-8 continuation byte starts a code point
				if ((data[i] & 0xC0) != 0x80)
					column++;
			}
		}
		else
			column += Utf8.CountCodePoints((char8*)data, from, mOffset);
		mColumnCacheOffset = mOffset;
		mColumnCacheValue = column;
		return column;
	}

	[Inline]
	void StartLine() mut
	{
		mLine++;
		mLineStart = mOffset;
	}

	public bool IsEOF
	{
		[Inline]
		get mut => mOffset >= mData.Length;
	}

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
		int cpLen = Utf8.SequenceLength(b0);
		if (cpLen == 0 || cpLen > mData.Length - mOffset)
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
	char8 AdvanceNewline(char8 b) mut
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

	// Inlined: a call per comment line cost a third of the speed of skipping comments
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
			pos = TomlStreamCursor.ScanTextRun(data, pos, end, stopMask);
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

	public void SkipNewline() mut
	{
		// One line break: AdvanceByte consumes "\r\n" as a unit
		if (mOffset < mData.Length && (mData[mOffset] == '\r' || mData[mOffset] == '\n'))
			AdvanceByte();
	}

	[Inline]
	public TomlCursorMark Mark() mut
	{
		return TomlCursorMark() { mOffset = mOffset };
	}

	public StringView Slice(TomlCursorMark mark, String scratch) mut
	{
		int length = mOffset - mark.mOffset;
		if (length < 0 || mark.mOffset + length > mData.Length) return StringView();
		return StringView((char8*)mData.Ptr + mark.mOffset, length);
	}

	[Inline]
	public void ReleaseMark(TomlCursorMark mark) mut
	{
	}
}

/// The memory cursor.
internal typealias TomlByteCursor = TomlMemoryCursor;

/// The stream cursor.
internal typealias TomlStreamCursor = TomlWindowCursor<BufferedStreamCursor<TomlText>>;
