using System;
using System.Collections;

namespace TomlBeef;

/// Represents a TOML array, owning a list of TomlValue items.
public class TomlArray
{
	public List<TomlValue> mItems;
	public bool mIsStatic; // true for arrays defined inline ([]), false for [[array]] created

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

	public ~this()
	{
		if (mItems != null)
		{
			for (int i = 0; i < mItems.Count; i++)
				mItems[i].Dispose();
			delete mItems;
		}
	}

	public void Add(TomlValue value)
	{
		mItems.Add(value);
	}

	public int Count
	{
		get { return mItems.Count; }
	}

	public TomlValue this[int index]
	{
		get { return mItems[index]; }
		set { mItems[index].Dispose(); mItems[index] = value; }
	}
}
