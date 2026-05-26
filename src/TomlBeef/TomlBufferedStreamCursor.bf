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

	private bool mHasMark;
	private int mMarkLocal;

	private String mSpill;
	private bool mUsingSpill;
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
		mHasMark = false;
		mMarkLocal = 0;
		mSpill = spill;
		mUsingSpill = false;
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
		if (mUsingSpill)
			mSpill.Append(b);

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

	public Result<void, TomlParseError> SkipComment() mut
	{
		EnsureAvailable(1);
		if (mPos >= mEnd) return .Ok;
		if (mBuffer[mPos] != '#') return .Ok;
		AdvanceByte();

		while (true)
		{
			EnsureAvailable(2);
			if (mPos >= mEnd) return .Ok;
			char8 b = (char8)mBuffer[mPos];
			if (b == '\r')
			{
				if (mPos + 1 < mEnd && mBuffer[mPos + 1] == '\n')
					break;
				return .Err(TomlParseError(.ControlCharInDocument, "Bare CR in comment", mLine, mColumn, (int)(mBaseOffset + mPos)));
			}
			if (b == '\n') break;
			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(TomlParseError(.ControlCharInDocument, "Control character in comment", mLine, mColumn, (int)(mBaseOffset + mPos)));
			AdvanceByte();
		}
		SkipNewline();
		return .Ok;
	}

	[Inline]
	public TomlCursorMark Mark() mut
	{
		if (mHasMark && mUsingSpill)
		{
			mSpill.Clear();
			mUsingSpill = false;
		}
		mHasMark = true;
		mMarkLocal = mPos;
		return TomlCursorMark() { mOffset = (int)(mBaseOffset + mPos) };
	}

	public StringView Slice(TomlCursorMark mark, String scratch) mut
	{
		mHasMark = false;

		if (mUsingSpill)
		{
			mUsingSpill = false;
			scratch.Clear();
			scratch.Append(mSpill);
			mSpill.Clear();
			return StringView(scratch);
		}

		int startOffset = (int)(mark.mOffset - mBaseOffset);
		int length = mPos - startOffset;
		if (length < 0) return StringView();

		if (startOffset >= 0 && startOffset + length <= mEnd)
			return StringView((char8*)&mBuffer[startOffset], length);

		return StringView();
	}

	public void Dispose() mut
	{
		mStream = null;
	}

	private void EnsureAvailable(int needed) mut
	{
		if (mEnd - mPos >= needed) return;
		if (mStream == null) return;

		if (mHasMark)
		{
			int markLen = mPos - mMarkLocal;
			if (markLen + needed > mBuffer.Count)
			{
				if (!mUsingSpill)
				{
					mSpill.Clear();
					mUsingSpill = true;
					for (int i = mMarkLocal; i < mPos; i++)
						mSpill.Append((char8)mBuffer[i]);
				}
				mHasMark = false;
			}
		}

		CompactForRefill();
		while (mEnd - mPos < needed && mStream != null && mEnd < mBuffer.Count)
			Refill();
	}

	private void CompactForRefill() mut
	{
		int keepStart = mHasMark ? mMarkLocal : mPos;
		int keepLen = mEnd - keepStart;
		if (keepLen <= 0)
		{
			mBaseOffset += mPos;
			mPos = 0;
			mEnd = 0;
			if (mHasMark) mMarkLocal = 0;
			return;
		}

		if (keepStart > 0)
		{
			for (int i = 0; i < keepLen; i++)
				mBuffer[i] = mBuffer[keepStart + i];
			mBaseOffset += keepStart;
			mPos -= keepStart;
			mEnd = keepLen;
			if (mHasMark)
				mMarkLocal = 0;
		}
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
