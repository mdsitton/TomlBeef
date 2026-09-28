using System;
using System.Collections;

namespace TomlBeef;

/// A reusable key path for the parser. The list and the Strings in it survive between keys, so parsing a
/// dotted key allocates nothing once the buffer has grown to the longest path seen.
internal class TomlKeyPathBuffer
{
	/// @brief The segments of the current key path (what the resolver reads). Always the first
	/// mParts.Count Strings of mAll, in order.
	public List<String> mParts ~ delete _;
	/// Every segment String ever used, owned here and reused in order.
	List<String> mAll ~ DeleteContainerAndItems!(_);

	public this()
	{
		mParts = new List<String>();
		mAll = new List<String>();
	}

	/// @brief Start a new, empty key path (keeping the Strings for reuse).
	public void Reset()
	{
		mParts.Clear();
	}

	/// @brief Append an empty segment and return it for the key parser to fill.
	/// @return The segment's String, owned by this buffer.
	public String Add()
	{
		int index = mParts.Count;
		String part;
		if (index < mAll.Count)
		{
			part = mAll[index];
			part.Clear();
		}
		else
		{
			part = new String();
			mAll.Add(part);
		}
		mParts.Add(part);
		return part;
	}
}
