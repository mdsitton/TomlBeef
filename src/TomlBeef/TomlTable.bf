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

	/// @brief Indexer that returns the value for a key, or an error result if not found.
	/// @param key The key to look up.
	/// @return The TomlValue on success, or an error result.
	public Result<TomlValue> this[StringView key]
	{
		get
		{
			return Get(key);
		}
	}

	/// @brief Remove all entries from this table, freeing owned values.
	public void Clear()
	{
		if (mEntries != null)
		{
			DeleteDictionaryAndKeysAndDisposeValues!(mEntries);
			mEntries = new Dictionary<String, TomlValue>();
		}
		if (mKeyOrder != null)
		{
			delete mKeyOrder;
			mKeyOrder = new List<String>();
		}
	}

	/// @brief Merge keys from another table into this one.
	/// @param source The table whose entries to merge. Unchanged on return.
	/// @param onConflict How to handle duplicate keys (default: error).
	/// @return .Ok on success, or .Err if a duplicate key was found with OnConflict == .Error.
	public Result<void, TomlParseError> MergeFrom(TomlTable source, MergeConflict onConflict = .Error)
	{
		// Pass 1: validate — check for conflicting keys before modifying anything
		if (onConflict == .Error)
		{
			for (int i = 0; i < source.mKeyOrder.Count; i++)
			{
				StringView key = source.mKeyOrder[i];
				if (ContainsKey(key))
					return .Err(TomlParseError(.DuplicateKey,
						scope $"Duplicate key '{key}' during merge", 0, 0, 0));
			}
		}

		// Pass 2: insert or replace
		for (int i = 0; i < source.mKeyOrder.Count; i++)
		{
			String key = source.mKeyOrder[i];
			TomlValue val = source.mEntries[key];

			if (ContainsKey(key))
			{
				if (onConflict == .Overwrite)
					ReplaceValue(key, val.Clone());
				// .Skip: do nothing, keep existing
			}
			else
			{
				Insert(key, val.Clone());
			}
		}
		return .Ok;
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
