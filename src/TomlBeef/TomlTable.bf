using System;
using System.Collections;

namespace TomlBeef;

/// A TOML table: an ordered map from key to TomlValue, with metadata for conflict detection.
public class TomlTable
{
	private TomlTableOrigin mOrigin;
	private bool mIsInlineSealed;
	private Dictionary<String, TomlValue> mEntries;
	private List<String> mKeyOrder;

	public this(TomlTableOrigin origin)
	{
		mOrigin = origin;
		mIsInlineSealed = false;
		mEntries = new Dictionary<String, TomlValue>();
		mKeyOrder = new List<String>();
	}

	public ~this()
	{
		if (mEntries != null)
		{
			for (var val in mEntries.Values)
				val.Dispose();
			for (var key in mEntries.Keys)
				delete key;
			delete mEntries;
		}

		if (mKeyOrder != null)
		{
			for (int i = 0; i < mKeyOrder.Count; i++)
				mKeyOrder[i] = null;
			delete mKeyOrder;
		}
	}

	public TomlTableOrigin Origin
	{
		get { return mOrigin; }
		set { mOrigin = value; }
	}

	public bool IsInlineSealed
	{
		get { return mIsInlineSealed; }
		set { mIsInlineSealed = value; }
	}

	public int Count => mEntries.Count;

	public Dictionary<String, TomlValue> Entries => mEntries;

	public List<String> KeyOrder => mKeyOrder;

	public bool ContainsKey(StringView key)
	{
		if (mEntries != null)
			return mEntries.ContainsKeyAlt(key);
		return false;
	}

	public bool TryGetValue(StringView key, out TomlValue value)
	{
		if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
		{
			value = val;
			return true;
		}
		value = default;
		return false;
	}

	public void Insert(StringView key, TomlValue value)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			existingVal.Dispose();
			mEntries[existingKey] = value;
			return;
		}

		String ownedKey = new String(key);
		mEntries[ownedKey] = value;
		mKeyOrder.Add(ownedKey);
	}

	public void ReplaceValue(StringView key, TomlValue value)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			existingVal.Dispose();
			mEntries[existingKey] = value;
		}
	}

	/// Sets the origin of the table stored at the given key (if it's a table).
	public void SetTableOrigin(StringView key, TomlTableOrigin origin)
	{
		if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
		{
			if (val.IsTable)
				val.AsTable.Origin = origin;
		}
	}

	public Result<TomlValue> Get(StringView key)
	{
		if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
			return val;
		return .Err;
	}
}
