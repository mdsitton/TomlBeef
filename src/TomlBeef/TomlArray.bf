using System;
using System.Collections;

namespace TomlBeef;

/// Represents a TOML array, owning a list of TomlValue items.
public class TomlArray
{
	private List<TomlValue> mItems ~ DeleteContainerAndDisposeItems!(_);
	private bool mIsStatic; // true for arrays defined inline ([]), false for [[array]] created

	/// @brief Whether this array is a static inline array (true) or a dynamic array-of-tables (false).
	public bool IsStatic
	{
		get => mIsStatic;
		set => mIsStatic = value;
	}

	public this()
	{
		mItems = new List<TomlValue>();
		mIsStatic = false;
	}

	public this(int capacity)
	{
		mItems = new List<TomlValue>(capacity);
		mIsStatic = false;
	}

	public void Add(TomlValue value)
	{
		mItems.Add(value);
	}

	public int Count => mItems.Count;

	public TomlValue this[int index]
	{
		get => mItems[index];
		set
		{
			mItems[index].Dispose();
			mItems[index] = value;
		}
	}

	public TomlArray Clone()
	{
		TomlArray result = new TomlArray(mItems.Count);
		result.mIsStatic = mIsStatic;
		for (int i = 0; i < mItems.Count; i++)
			result.Add(mItems[i].Clone());
		return result;
	}
}
