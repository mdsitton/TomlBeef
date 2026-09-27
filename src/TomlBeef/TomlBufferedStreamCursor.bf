using System;
using System.IO;

namespace TomlBeef;

class TomlStreamState
{
	public bool mError;
	public bool mUtf8Error;
	public int mUtf8ErrorLine;
	public int mUtf8ErrorColumn;
	public int mUtf8ErrorOffset;

	// Incremental UTF-8 validator state
	public int mValidateLine = 1;
	public int mValidateColumn = 1;
	public int mValidateOffset = 0;

	public int mUtf8Needed;
	public int mUtf8Seen;
	public uint32 mUtf8Codepoint;
	public uint32 mUtf8MinCodepoint;
	public int mUtf8StartOffset;
	public int mUtf8StartLine;
	public int mUtf8StartColumn;

	// Resource limit tracking
	public int mMaxInputBytes = 0;
	public int mBytesRead = 0;
	public bool mBytesExceeded = false;
}

struct TomlBufferedStreamCursor : ITomlCursor
{
	private Stream mStream;
	private uint8[] mBuffer;
	private int mPos;
	private int mEnd;
	private int64 mBaseOffset;
	private int mLine;
	private int mColumn;

	// Number of active (unreleased) marks. Marks nest, so the outermost mark has the lowest offset.
	private int mMarkDepth;
	// Absolute offset of the outermost active mark; bytes from here on are retained while mMarkDepth > 0.
	private int64 mRetainStart;

	// Retained bytes evicted from the buffer to make room for refills.
	// When non-empty it holds [mRetainStart, mBaseOffset), contiguous with the buffer.
	private String mSpill;
	private TomlStreamState mState;

	public this(Stream stream, uint8[] buffer, String spill, TomlStreamState state = null)
	{
		mStream = stream;
		mBuffer = buffer;
		mPos = 0;
		mEnd = 0;
		mBaseOffset = 0;
		mLine = 1;
		mColumn = 1;
		mMarkDepth = 0;
		mRetainStart = 0;
		mSpill = spill;
		mState = state;
	}

	[Inline] public int Offset => (int)(mBaseOffset + mPos);
	[Inline] public int Line => mLine;
	[Inline] public int Column => mColumn;
	[Inline] public bool IsEOF => (mStream == null && mPos >= mEnd) || (mState != null && mState.mError);

	public bool HasError => mState != null && mState.mError;
	public bool HasUtf8Error => mState != null && mState.mUtf8Error;
	public int Utf8ErrorLine => mState != null ? mState.mUtf8ErrorLine : 0;
	public int Utf8ErrorColumn => mState != null ? mState.mUtf8ErrorColumn : 0;
	public int Utf8ErrorOffset => mState != null ? mState.mUtf8ErrorOffset : 0;

	public void ResetPosition() mut
	{
		int remaining = mEnd - mPos;
		if (remaining > 0)
		{
			for (int i = 0; i < remaining; i++)
				mBuffer[i] = mBuffer[mPos + i];
		}
		mBaseOffset += mPos;
		mPos = 0;
		mEnd = remaining;
		mLine = 1;
		mColumn = 1;
		// Reset validator after BOM
		if (mState != null)
		{
			mState.mValidateLine = 1;
			mState.mValidateColumn = 1;
			mState.mValidateOffset = 0;
			mState.mUtf8Needed = 0;
		}
	}

	[Inline]
	public char8 PeekByte() mut
	{
		EnsureAvailable(1);
		if (mPos >= mEnd) return 0;
		return (char8)mBuffer[mPos];
	}

	[Inline]
	public char8 PeekByte(int lookahead) mut
	{
		EnsureAvailable(lookahead + 1);
		int pos = mPos + lookahead;
		if (pos >= mEnd) return 0;
		return (char8)mBuffer[pos];
	}

	[Inline]
	public char8 PeekByteAt(int offset) mut
	{
		EnsureAvailable(offset + 1);
		int pos = mPos + offset;
		if (pos >= mEnd) return 0;
		return (char8)mBuffer[pos];
	}

	public char8 AdvanceByte() mut
	{
		EnsureAvailable(1);
		if (mPos >= mEnd) return 0;

		char8 b = (char8)mBuffer[mPos];
		mPos++;
		if (b == '\r')
		{
			EnsureAvailable(1);
			if (mPos < mEnd && mBuffer[mPos] == '\n')
				mPos++;
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

	public char32 Advance() mut
	{
		EnsureAvailable(4);
		if (mPos >= mEnd) return 0;

		char8 b0 = (char8)mBuffer[mPos];
		if ((uint8)b0 < 0x80)
		{
			mPos++;
			if (b0 == '\n') { mLine++; mColumn = 1; }
			else mColumn++;
			return (char32)b0;
		}

		int remaining = mEnd - mPos;
		int cpLen = TomlChar.Utf8SequenceLength(b0);
		if (cpLen == 0 || cpLen > remaining)
		{
			mPos++;
			mColumn++;
			return (char32)0xFFFD;
		}

		StringView sv = StringView((char8*)&mBuffer[mPos], remaining);
		char32 cp = TomlChar.DecodeAt(sv, 0, cpLen);
		mPos += cpLen;
		mColumn++;
		return cp;
	}

	public void SkipWhitespace() mut
	{
		while (true)
		{
			EnsureAvailable(1);
			if (mPos >= mEnd) break;
			uint8 b = mBuffer[mPos];
			if (b == ' ' || b == '\t') AdvanceByte();
			else break;
		}
	}

	public void SkipNewline() mut
	{
		EnsureAvailable(1);
		if (mPos >= mEnd) return;
		if (mBuffer[mPos] == '\r') AdvanceByte();
		if (mPos < mEnd && mBuffer[mPos] == '\n') AdvanceByte();
	}


	[Inline]
	public TomlCursorMark Mark() mut
	{
		int64 offset = mBaseOffset + mPos;
		if (mMarkDepth == 0)
		{
			mRetainStart = offset;
			mSpill.Clear();
		}
		mMarkDepth++;
		return TomlCursorMark() { mOffset = (int)offset };
	}

	public StringView Slice(TomlCursorMark mark, String scratch) mut
	{
		StringView result = StringView();
		int64 start = mark.mOffset;
		if (start < mBaseOffset)
		{
			// The start was evicted from the buffer: join the spilled prefix with the buffered tail.
			int spillIndex = (int)(start - mRetainStart);
			if (mMarkDepth > 0 && spillIndex >= 0 && spillIndex <= mSpill.Length)
			{
				scratch.Clear();
				scratch.Append(StringView(mSpill, spillIndex));
				scratch.Append((char8*)mBuffer.Ptr, mPos);
				result = scratch;
			}
		}
		else if (start - mBaseOffset <= mPos)
		{
			int local = (int)(start - mBaseOffset);
			result = StringView((char8*)mBuffer.Ptr + local, mPos - local);
		}

		ReleaseMark(mark);
		return result;
	}

	public void ReleaseMark(TomlCursorMark mark) mut
	{
		if (mMarkDepth == 0)
			return;
		mMarkDepth--;
		if (mMarkDepth == 0)
			mSpill.Clear();
	}

	public void Dispose() mut
	{
		mStream = null;
	}

	private void EnsureAvailable(int needed) mut
	{
		if (mEnd - mPos >= needed) return;
		if (mStream == null) return;

		CompactForRefill(needed);
		while (mEnd - mPos < needed && mStream != null && mEnd < mBuffer.Count)
			Refill();
	}

	/// Shifts retained bytes to the front of the buffer. While a mark is active, bytes from the
	/// outermost mark are kept; if they no longer fit, the consumed part moves to the spill.
	private void CompactForRefill(int needed) mut
	{
		int keepStart = mPos;
		if (mMarkDepth > 0)
		{
			keepStart = (int)Math.Max(mRetainStart - mBaseOffset, 0);
			if (mEnd - keepStart + needed > mBuffer.Count)
			{
				mSpill.Append((char8*)mBuffer.Ptr + keepStart, mPos - keepStart);
				keepStart = mPos;
			}
		}

		if (keepStart == 0)
			return;

		int keepLen = mEnd - keepStart;
		for (int i = 0; i < keepLen; i++)
			mBuffer[i] = mBuffer[keepStart + i];
		mBaseOffset += keepStart;
		mPos -= keepStart;
		mEnd = keepLen;
	}

	private void Refill() mut
	{
		if (mStream == null) return;
		if (mEnd >= mBuffer.Count) return;

		int oldEnd = mEnd;
		switch (mStream.TryRead(Span<uint8>(&mBuffer[mEnd], mBuffer.Count - mEnd)))
		{
		case .Ok(let read):
			if (read <= 0)
			{
				if (mState != null && mState.mUtf8Needed > 0)
					SetValidateError(mEnd - 1);
				mStream = null;
			}
			else
			{
				mEnd += read;
				if (mState != null)
				{
					mState.mBytesRead += read;
					if (mState.mMaxInputBytes > 0 && mState.mBytesRead > mState.mMaxInputBytes)
					{
						mState.mBytesExceeded = true;
						mState.mError = true;
						mStream = null;
						return;
					}
				}
				ValidateUtf8Bytes(oldEnd, mEnd);
			}
		case .Err:
			if (mState != null) mState.mError = true;
			mStream = null;
		}
	}

	private void ValidateUtf8Bytes(int start, int end) mut
	{
		if (mState == null || mState.mUtf8Error) return;

		for (int i = start; i < end; i++)
		{
			uint8 b = mBuffer[i];

			if (mState.mUtf8Needed == 0)
			{
				// Expecting a new sequence
				if (b < 0x80)
				{
					mState.mValidateOffset++;
					if (b == '\n') { mState.mValidateLine++; mState.mValidateColumn = 1; }
					else mState.mValidateColumn++;
					continue;
				}

				// Determine sequence length
				int cpLen;
				uint32 minCp;
				if ((b & 0xE0) == 0xC0)      { cpLen = 2; minCp = 0x80; }
				else if ((b & 0xF0) == 0xE0) { cpLen = 3; minCp = 0x800; }
				else if ((b & 0xF8) == 0xF0) { cpLen = 4; minCp = 0x10000; }
				else
				{
					SetValidateError(i);
					return;
				}

				mState.mUtf8Needed = cpLen - 1;
				mState.mUtf8Seen = 1;
				mState.mUtf8Codepoint = (uint32)(b & (cpLen == 2 ? 0x1F : cpLen == 3 ? 0x0F : 0x07));
				mState.mUtf8MinCodepoint = minCp;
				mState.mUtf8StartOffset = mState.mValidateOffset;
				mState.mUtf8StartLine = mState.mValidateLine;
				mState.mUtf8StartColumn = mState.mValidateColumn;
			}
			else
			{
				// Expecting continuation byte
				if ((b & 0xC0) != 0x80)
				{
					SetValidateError(i);
					return;
				}

				mState.mUtf8Codepoint = (mState.mUtf8Codepoint << 6) | (uint32)(b & 0x3F);
				mState.mUtf8Seen++;
				mState.mUtf8Needed--;

				if (mState.mUtf8Needed == 0)
				{
					uint32 cp = mState.mUtf8Codepoint;
					if (cp < mState.mUtf8MinCodepoint ||
						(cp >= 0xD800 && cp <= 0xDFFF) ||
						cp > 0x10FFFF)
					{
						SetValidateError(i);
						return;
					}
					mState.mValidateOffset += mState.mUtf8Seen;
					mState.mValidateColumn++;
				}
			}
		}
	}

	private void SetValidateError(int bufferIndex) mut
	{
		if (mState.mUtf8Error) return;
		mState.mUtf8Error = true;
		// Use the start of the sequence if we're mid-sequence, otherwise this byte
		if (mState.mUtf8Needed > 0)
		{
			mState.mUtf8ErrorLine = mState.mUtf8StartLine;
			mState.mUtf8ErrorColumn = mState.mUtf8StartColumn;
			mState.mUtf8ErrorOffset = mState.mUtf8StartOffset;
		}
		else
		{
			mState.mUtf8ErrorLine = mState.mValidateLine;
			mState.mUtf8ErrorColumn = mState.mValidateColumn;
			mState.mUtf8ErrorOffset = mState.mValidateOffset;
		}
	}
}
