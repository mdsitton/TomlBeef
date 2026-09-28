using System;
using System.Collections;

namespace TomlBeef;

/// A reusable key path for the parser. The list and the Strings in it survive between keys, so parsing a
/// dotted key allocates nothing once the buffer has grown to the longest path seen.
internal class TomlKeyPathBuffer
{
	/// @brief The segments of the current key path (what the resolver reads).
	public List<String> mParts ~ DeleteContainerAndItems!(_);
	/// Strings from earlier paths, ready for reuse.
	List<String> mSpare ~ DeleteContainerAndItems!(_);

	public this()
	{
		mParts = new List<String>();
		mSpare = new List<String>();
	}

	/// @brief Start a new, empty key path (keeping the Strings for reuse).
	public void Reset()
	{
		for (let part in mParts)
			mSpare.Add(part);
		mParts.Clear();
	}

	/// @brief Append an empty segment and return it for the key parser to fill.
	/// @return The segment's String, owned by this buffer.
	public String Add()
	{
		String part = mSpare.IsEmpty ? new String() : mSpare.PopBack();
		part.Clear();
		mParts.Add(part);
		return part;
	}
}
