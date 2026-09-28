using System;
using System.Collections;

namespace TomlBeef;

/// Append-only text storage for the metadata sidecar (comment lines and original tokens). Text is
/// copied into large blocks that never move, so the returned views stay valid for the arena's
/// lifetime and a comment costs no allocation of its own. Replaced text (comment setters) stays
/// behind until the arena is freed, bounded by what callers set.
internal class TomlTextArena
{
	const int BlockBytes = 16 * 1024;

	/// Each block is a String created with its full capacity and only appended within it, so its
	/// buffer is never reallocated.
	List<String> mBlocks = new .() ~ DeleteContainerAndItems!(_);
	String mCurrent;

	public this()
	{
	}

	/// @brief Copy `text` into the arena.
	/// @param text The text to store.
	/// @return A view of the stored copy. Its pointer is never null, even for empty text, so callers
	/// can use a null pointer to mean "absent".
	public StringView Add(StringView text)
	{
		if (text.Length > BlockBytes / 4)
		{
			// Large text gets a block of its own, leaving the current block's free space for the next
			let block = new String(text.Length);
			block.Append(text);
			mBlocks.Add(block);
			return block;
		}
		if (mCurrent == null || mCurrent.Length + text.Length > BlockBytes)
		{
			mCurrent = new String(BlockBytes);
			mBlocks.Add(mCurrent);
		}
		int start = mCurrent.Length;
		mCurrent.Append(text);
		return StringView(mCurrent.Ptr + start, text.Length);
	}
}
