using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// A TOML table: an ordered map from key to TomlValue, with metadata for conflict detection.
public class TomlTable
{
	private TomlTableOrigin mOrigin;
	private bool mIsInlineSealed;
	/// @brief Set by parser after detecting a trailing comma before the closing brace.
	internal bool mHasTrailingComma;
	private Dictionary<String, TomlValue> mEntries ~ DeleteDictionaryAndKeysAndDisposeValues!(_);
	private List<String> mKeyOrder ~ delete _;
	private TomlContainerMetadataContext mMetadataContext ~ delete _;
	internal bool mSuppressAutoDirty; // set by parser to suppress dirty marking during parse

	public this(TomlTableOrigin origin)
	{
		Init(origin, false);
	}

	internal this(TomlTableOrigin origin, bool suppressAutoDirty)
	{
		Init(origin, suppressAutoDirty);
	}

	private void Init(TomlTableOrigin origin, bool suppressAutoDirty)
	{
		mOrigin = origin;
		mIsInlineSealed = false;
		mEntries = new Dictionary<String, TomlValue>();
		mKeyOrder = new List<String>();
		mMetadataContext = null;
		mSuppressAutoDirty = suppressAutoDirty;
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

	/// @brief Metadata context for style-preserving mode. Null in normal mode.
	internal TomlContainerMetadataContext MetadataContext
	{
		get => mMetadataContext;
		set => mMetadataContext = value;
	}

	public int Count => mEntries.Count;

	/// @brief Read-only access to entries. Modifying this directly desyncs ordering and dirty tracking.
	internal Dictionary<String, TomlValue> Entries => mEntries;

	/// @brief Read-only access to key ordering. Modifying this directly desyncs the table state.
	internal List<String> KeyOrder => mKeyOrder;

	/// @brief Get the key at the given index in insertion order.
	public StringView GetKeyAt(int index)
	{
		return mKeyOrder[index];
	}

	/// @brief Get the value for the key at the given index in insertion order.
	public TomlValue GetValueAt(int index)
	{
		return mEntries[mKeyOrder[index]];
	}

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
			MarkEntryDirty(key);
			BindContainerMetadata(value);
			return;
		}

		String ownedKey = new String(key);
		mEntries[ownedKey] = value;
		mKeyOrder.Add(ownedKey);

		// Auto node-ID allocation for new entries when metadata context exists.
		// The parser pre-registers node IDs, so skip allocation if one already exists.
		// Only mark dirty for genuinely new entries (not parser-inserted ones).
		if (mMetadataContext != null && mMetadataContext.mMetadata != null)
		{
			if (!mMetadataContext.TryGetEntryNodeId(key, let _))
			{
				let nodeId = mMetadataContext.mMetadata.AllocateNodeId();
				mMetadataContext.SetEntryNodeId(key, nodeId);
				if (!mSuppressAutoDirty)
					MarkChildrenDirty();
			}
			BindContainerMetadata(value);
		}
	}

	/// Bind metadata context to inserted container values (tables/arrays).
	private void BindContainerMetadata(TomlValue val)
	{
		if (mMetadataContext == null || mMetadataContext.mMetadata == null)
			return;
		switch (val)
		{
		case .Table(let tbl):
			if (tbl != null && tbl.MetadataContext == null)
			{
				let nid = mMetadataContext.mMetadata.AllocateNodeId();
				tbl.MetadataContext = new TomlContainerMetadataContext(mMetadataContext.mMetadata, nid, false);
			}
		case .Array(let arr):
			if (arr != null && arr.MetadataContext == null)
			{
				let nid = mMetadataContext.mMetadata.AllocateNodeId();
				arr.MetadataContext = new TomlContainerMetadataContext(mMetadataContext.mMetadata, nid, true);
			}
		default:
		}
	}

	/// @brief Replace the value for an existing key. Does nothing if the key is not found.
	/// @param key The key to replace.
	/// @param value The new value. Consumed (disposed) if the key is not found.
	/// @return True if the key was found and replaced.
	public bool ReplaceValue(StringView key, TomlValue value)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			// If the new value is semantically equal, keep clean and discard new value
			if (existingVal.IsSemanticallyEqualTo(value))
			{
				value.Dispose();
				return true;
			}
			existingVal.Dispose();
			mEntries[existingKey] = value;
			MarkEntryDirty(key);
			BindContainerMetadata(value);
			return true;
		}
		value.Dispose();
		return false;
	}

	/// @brief Check if entries in this table prefer dotted-key emission.
	public bool HasDottedPreference(TomlDocumentMetadata metadata)
	{
		if (mMetadataContext == null || metadata == null)
			return false;
		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			String key = mKeyOrder[i];
			if (mMetadataContext.TryGetEntryNodeId(key, let nodeId) && nodeId.IsValid)
			{
				let style = metadata.GetNodeStyle(nodeId);
				if (style != null && style.mKeyFormatRef.IsValid)
				{
					let fmt = metadata.mKeyFormats[style.mKeyFormatRef.mIndex];
					if (fmt.mPreferDottedPath)
						return true;
				}
			}
		}
		return false;
	}

	/// @brief Remove a key and its value from this table.
	/// @param key The key to remove.
	/// @return True if the key was found and removed.
	public bool Remove(StringView key)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			// Remove node-ID mapping before disposing the value
			if (mMetadataContext != null)
				mMetadataContext.RemoveEntryNodeId(key);

			existingVal.Dispose();
			mEntries.Remove(existingKey);
			for (int i = 0; i < mKeyOrder.Count; i++)
			{
				if (mKeyOrder[i] == existingKey)
				{
					mKeyOrder.RemoveAt(i);
					delete existingKey;
					MarkChildrenDirty();
					return true;
				}
			}
		}
		return false;
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

	/// @brief Try to get a String value for a key.
	/// @param key The key to look up.
	/// @param value On success, the string value.
	/// @return True if the key exists and holds a String.
	public bool TryGetString(StringView key, out StringView value)
	{
		if (TryGetValue(key, let val) && val.TryGetString(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get an Integer value for a key.
	/// @param key The key to look up.
	/// @param value On success, the integer value.
	/// @return True if the key exists and holds an Integer.
	public bool TryGetInteger(StringView key, out int64 value)
	{
		if (TryGetValue(key, let val) && val.TryGetInteger(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a Float value for a key.
	/// @param key The key to look up.
	/// @param value On success, the float value.
	/// @return True if the key exists and holds a Float.
	public bool TryGetFloat(StringView key, out double value)
	{
		if (TryGetValue(key, let val) && val.TryGetFloat(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a Bool value for a key.
	/// @param key The key to look up.
	/// @param value On success, the boolean value.
	/// @return True if the key exists and holds a Bool.
	public bool TryGetBool(StringView key, out bool value)
	{
		if (TryGetValue(key, let val) && val.TryGetBool(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a Table value for a key.
	/// @param key The key to look up.
	/// @param value On success, the table value.
	/// @return True if the key exists and holds a Table.
	public bool TryGetTable(StringView key, out TomlTable value)
	{
		if (TryGetValue(key, let val) && val.TryGetTable(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get an Array value for a key.
	/// @param key The key to look up.
	/// @param value On success, the array value.
	/// @return True if the key exists and holds an Array.
	public bool TryGetArray(StringView key, out TomlArray value)
	{
		if (TryGetValue(key, let val) && val.TryGetArray(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get an OffsetDateTime value for a key.
	/// @param key The key to look up.
	/// @param value On success, the offset date-time value.
	/// @return True if the key exists and holds an OffsetDateTime.
	public bool TryGetOffsetDateTime(StringView key, out TomlOffsetDateTime value)
	{
		if (TryGetValue(key, let val) && val.TryGetOffsetDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a LocalDateTime value for a key.
	/// @param key The key to look up.
	/// @param value On success, the local date-time value.
	/// @return True if the key exists and holds a LocalDateTime.
	public bool TryGetLocalDateTime(StringView key, out TomlLocalDateTime value)
	{
		if (TryGetValue(key, let val) && val.TryGetLocalDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a LocalDate value for a key.
	/// @param key The key to look up.
	/// @param value On success, the local date value.
	/// @return True if the key exists and holds a LocalDate.
	public bool TryGetLocalDate(StringView key, out TomlLocalDate value)
	{
		if (TryGetValue(key, let val) && val.TryGetLocalDate(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Try to get a LocalTime value for a key.
	/// @param key The key to look up.
	/// @param value On success, the local time value.
	/// @return True if the key exists and holds a LocalTime.
	public bool TryGetLocalTime(StringView key, out TomlLocalTime value)
	{
		if (TryGetValue(key, let val) && val.TryGetLocalTime(out value))
			return true;
		value = default;
		return false;
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
		if (mMetadataContext != null)
		{
			delete mMetadataContext;
			mMetadataContext = null;
		}
		mSuppressAutoDirty = false;
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

	// ================================================================
	// Dirty tracking helpers
	// ================================================================

	/// Recursively clear metadata contexts from this table and all descendant tables/arrays.
	public void ClearMetadataContexts()
	{
		if (mMetadataContext != null)
		{
			delete mMetadataContext;
			mMetadataContext = null;
		}
		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			String key = mKeyOrder[i];
			TomlValue val = mEntries[key];
			ClearMetadataContextsFromValue(val);
		}
	}

	private static void ClearMetadataContextsFromValue(TomlValue val)
	{
		switch (val)
		{
		case .Array(let arr):
			if (arr != null) arr.ClearMetadataContexts();
		case .Table(let tbl):
			if (tbl != null) tbl.ClearMetadataContexts();
		default:
		}
	}

	/// Recursively re-enable automatic dirty tracking after parser construction completes.
	internal void ClearAutoDirtySuppression()
	{
		mSuppressAutoDirty = false;
		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			String key = mKeyOrder[i];
			switch (mEntries[key])
			{
			case .Array(let arr):
				if (arr != null) arr.ClearAutoDirtySuppression();
			case .Table(let tbl):
				if (tbl != null) tbl.ClearAutoDirtySuppression();
			default:
			}
		}
	}

	/// Mark a specific entry as dirty. Call after programmatic value changes.
	internal void MarkEntryDirty(StringView key)
	{
		if (mMetadataContext != null && mMetadataContext.mMetadata != null)
		{
			if (mMetadataContext.TryGetEntryNodeId(key, let nodeId) && nodeId.IsValid)
			{
				let style = mMetadataContext.mMetadata.GetNodeStyle(nodeId);
				if (style != null)
					style.mDirtyFlags |= .Value;
			}
		}
	}

	/// Mark the container as having changed children. Call after programmatic insert/remove.
	internal void MarkChildrenDirty()
	{
		if (mMetadataContext != null && mMetadataContext.mMetadata != null && mMetadataContext.mNodeId.IsValid)
		{
			let style = mMetadataContext.mMetadata.GetNodeStyle(mMetadataContext.mNodeId);
			if (style != null)
				style.mDirtyFlags |= .Children;
		}
	}
}
