using System;
using System.Collections;

namespace TomlBeef;

/// A TOML table: an ordered map from key to TomlValue, with metadata for conflict detection.
public class TomlTable
{
	private TomlTableOrigin mOrigin;
	private bool mIsInlineSealed;
	private Dictionary<String, TomlValue> mEntries ~ DeleteDictionaryAndKeysAndDisposeValues!(_);
	private List<String> mKeyOrder ~ delete _;

	public this(TomlTableOrigin origin)
	{
		mOrigin = origin;
		mIsInlineSealed = false;
		mEntries = new Dictionary<String, TomlValue>();
		mKeyOrder = new List<String>();
	}

	public TomlTableOrigin Origin
	{
		get => mOrigin;
		set => mOrigin = value;
	}

	public bool IsInlineSealed
	{
		get => mIsInlineSealed;
		set => mIsInlineSealed = value;
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

	public Result<TomlValue> Get(StringView key)
	{
		if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
			return val;
		return .Err;
	}

	public TomlTable Clone()
	{
		TomlTable result = new TomlTable(mOrigin);
		result.mIsInlineSealed = mIsInlineSealed;
		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			String key = mKeyOrder[i];
			TomlValue val = mEntries[key];
			result.Insert(key, val.Clone());
		}
		return result;
	}
}
