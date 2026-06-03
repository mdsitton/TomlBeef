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
	private Dictionary<String, TomlValue> mEntries;
	private List<String> mKeyOrder;
	private TomlContainerMetadataContext mMetadataContext ~ delete _;
	internal bool mSuppressAutoDirty; // set by parser to suppress dirty marking during parse
	/// @brief The owning document store.
	internal TomlDocumentStore mStore;

	public ~this()
	{
		delete mEntries;
		delete mKeyOrder;
	}

	internal this(TomlTableOrigin origin)
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
		internal set => mOrigin = value;
	}

	public bool IsInlineSealed
	{
		get => mIsInlineSealed;
		internal set => mIsInlineSealed = value;
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

	/// @brief Get an entry proxy at the given index for typed access, safe assignment, and mutations.
	public TomlTableEntry this[int index]
	{
		get => TomlTableEntry(this, index);
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

	internal void Insert(StringView key, TomlValue value)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			mEntries[existingKey] = value;
			MarkEntryDirty(key);
			BindContainerMetadata(value);
			return;
		}

		String ownedKey = mStore.NewString(key);
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
	internal bool ReplaceValue(StringView key, TomlValue value)
	{
		if (mEntries.TryGetAlt(key, let existingKey, let existingVal))
		{
			// If semantically equal, keep clean and discard the incoming value
			if (existingVal.IsSemanticallyEqualTo(value))
				return true;
			mEntries[existingKey] = value;
			MarkEntryDirty(key);
			BindContainerMetadata(value);
			return true;
		}
		return false;
	}

	/// @brief Set a string value for the given key. Uses the store if store-backed.
	/// @param key The key.
	/// @param value The string value.
	public void SetString(StringView key, StringView value)
	{
		// Avoid arena churn: if the existing value is already an equal string, do nothing.
		StringView existingStr = ?;
		if (TryGetValue(key, let existing) && existing.TryGetString(out existingStr) && existingStr == value)
			return;

		TomlValue owned = .String(mStore.NewString(value));
		if (!ReplaceValue(key, owned))
			Insert(key, owned);
	}

	/// @brief Set an integer value for the given key.
	/// @param key The key.
	/// @param value The integer value.
	public void SetInteger(StringView key, int64 value)
	{
		TomlValue v = .Integer(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set a float value for the given key.
	/// @param key The key.
	/// @param value The float value.
	public void SetFloat(StringView key, double value)
	{
		TomlValue v = .Float(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set a boolean value for the given key.
	/// @param key The key.
	/// @param value The boolean value.
	public void SetBool(StringView key, bool value)
	{
		TomlValue v = .Bool(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set an offset date-time value for the given key.
	/// @param key The key.
	/// @param value The offset date-time value.
	public void SetOffsetDateTime(StringView key, TomlOffsetDateTime value)
	{
		TomlValue v = .OffsetDateTime(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set a local date-time value for the given key.
	/// @param key The key.
	/// @param value The local date-time value.
	public void SetLocalDateTime(StringView key, TomlLocalDateTime value)
	{
		TomlValue v = .LocalDateTime(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set a local date value for the given key.
	/// @param key The key.
	/// @param value The local date value.
	public void SetLocalDate(StringView key, TomlLocalDate value)
	{
		TomlValue v = .LocalDate(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Set a local time value for the given key.
	/// @param key The key.
	/// @param value The local time value.
	public void SetLocalTime(StringView key, TomlLocalTime value)
	{
		TomlValue v = .LocalTime(value);
		if (!ReplaceValue(key, v))
			Insert(key, v);
	}

	/// @brief Create a new store-backed sub-table for the given key and return it.
	/// @param key The key.
	/// @return The new sub-table, or null if the key already exists.
	public TomlTable AddTable(StringView key)
	{
		if (ContainsKey(key))
			return null;
		TomlTable tbl = mStore.NewTable(.ExplicitHeader);
		Insert(key, .Table(tbl));
		return tbl;
	}

	/// @brief Create a new store-backed sub-array for the given key and return it.
	/// @param key The key.
	/// @return The new array, or null if the key already exists.
	public TomlArray AddArray(StringView key)
	{
		if (ContainsKey(key))
			return null;
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		Insert(key, .Array(arr));
		return arr;
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
			// Remove node-ID mapping
			if (mMetadataContext != null)
				mMetadataContext.RemoveEntryNodeId(key);

			mEntries.Remove(existingKey);
			for (int i = 0; i < mKeyOrder.Count; i++)
			{
				if (mKeyOrder[i] == existingKey)
				{
					mKeyOrder.RemoveAt(i);
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

	/// @brief Remove all entries from this table. The storage is cleared; the arena handle payload lifetime.
	public void Clear()
	{
		if (mEntries != null)
			mEntries.Clear();
		if (mKeyOrder != null)
			mKeyOrder.Clear();
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

		// Pass 2: insert or replace — copy values into the destination store if store-backed
		for (int i = 0; i < source.mKeyOrder.Count; i++)
		{
			StringView key = source.mKeyOrder[i];
			if (!source.TryGetValue(key, let val))
				continue;

			if (ContainsKey(key))
			{
				if (onConflict == .Overwrite)
				{
					TomlValue copy = val.CloneInto(mStore);
					ReplaceValue(key, copy);
				}
				// .Skip: do nothing, keep existing value
			}
			else
			{
				TomlValue copy = val.CloneInto(mStore);
				Insert(key, copy);
			}
		}
		return .Ok;
	}

	/// Recursively seal this inline table and all inline-table descendants created inside it.
	/// Needed because dotted keys inside inline tables create sub-tables (with .InlineTable origin)
	/// that are not automatically sealed when the outer inline table closes.
	internal void SealInlineRecursively()
	{
		if (!mIsInlineSealed)
			mIsInlineSealed = true;

		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			String key = mKeyOrder[i];
			switch (mEntries[key])
			{
			case .Table(let tbl):
				if (tbl != null && tbl.mOrigin == .InlineTable)
					tbl.SealInlineRecursively();
			case .Array(let arr):
				if (arr != null)
				{
					for (int j = 0; j < arr.Count; j++)
					{
						if (arr.GetValue(j) case .Table(let elemTbl) && elemTbl != null && elemTbl.mOrigin == .InlineTable)
							elemTbl.SealInlineRecursively();
					}
				}
			default:
			}
		}
	}

	/// @brief Deep-copy this table and its contents into the given store.
	/// @param store The store to allocate into.
	/// @return A store-owned copy.
	internal TomlTable CloneInto(TomlDocumentStore store)
	{
		TomlTable result = store.NewTable(mOrigin);
		result.mIsInlineSealed = mIsInlineSealed;
		for (int i = 0; i < mKeyOrder.Count; i++)
		{
			StringView key = mKeyOrder[i];
			if (TryGetValue(key, let val))
				result.Insert(key, val.CloneInto(store));
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

	// ================================================================
	// Entry proxy helpers
	// ================================================================

	/// @brief Remove the entry at the given insertion index.
	internal void RemoveAt(int index)
	{
		StringView key = mKeyOrder[index];
		if (mMetadataContext != null)
			mMetadataContext.RemoveEntryNodeId(key);
		mEntries.Remove(mKeyOrder[index]);
		mKeyOrder.RemoveAt(index);
		MarkChildrenDirty();
	}

	/// @brief Set a scalar value at the given index via safe input wrapper.
	internal void SetValueAt(int index, TomlInputValue value)
	{
		var slot = value;
		if (!slot.IsValid)
			Runtime.FatalError("Invalid TomlInputValue");
		TomlValue stored = slot.Materialize(mStore);
		StringView key = mKeyOrder[index];
		MarkEntryDirty(key);
		mEntries[mKeyOrder[index]] = stored;
		BindContainerMetadata(stored);
	}

	/// @brief Replace the entry at the given index with a new store-backed table.
	internal TomlTable SetTableAt(int index)
	{
		TomlTable tbl = mStore.NewTable(.InlineTable);
		TomlValue val = .Table(tbl);
		mEntries[mKeyOrder[index]] = val;
		MarkEntryDirty(mKeyOrder[index]);
		BindContainerMetadata(val);
		return tbl;
	}

	/// @brief Replace the entry at the given index with a new store-backed array.
	internal TomlArray SetArrayAt(int index)
	{
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		TomlValue val = .Array(arr);
		mEntries[mKeyOrder[index]] = val;
		MarkEntryDirty(mKeyOrder[index]);
		BindContainerMetadata(val);
		return arr;
	}

	/// @brief Rename the entry at the given index.
	/// @return .Ok on success, or .Err if the new key already exists.
	internal Result<void, TomlParseError> RenameAt(int index, StringView newKey)
	{
		if (ContainsKey(newKey))
			return .Err(TomlParseError(.DuplicateKey, scope $"Key '{newKey}' already exists", 0, 0, 0));
		StringView oldKey = mKeyOrder[index];
		TomlValue val = mEntries[mKeyOrder[index]];
		if (mEntries.TryGetAlt(oldKey, let existingKey, let _))
		{
			// Preserve metadata node ID: move it from oldKey to newKey
			TomlNodeId nodeId = .Invalid;
			if (mMetadataContext != null)
				mMetadataContext.TryGetEntryNodeId(oldKey, out nodeId);

			mEntries.Remove(existingKey);

			// Re-register node ID under new key
			if (mMetadataContext != null)
			{
				mMetadataContext.RemoveEntryNodeId(oldKey);
				if (nodeId.IsValid)
					mMetadataContext.SetEntryNodeId(newKey, nodeId);
			}
		}
		// Insert the value with the new key, preserving position
		String ownedKey = mStore.NewString(newKey);
		mEntries[ownedKey] = val;
		mKeyOrder[index] = ownedKey;
		MarkEntryDirty(ownedKey);
		return .Ok;
	}
}

/// @brief A key/value entry proxy returned by the table indexer.
/// Provides typed read access, safe scalar assignment, table/array replacement,
/// key rename, and removal without exposing raw `TomlValue`.
public struct TomlTableEntry
{
	private TomlTable mTable;
	private int mIndex;

	internal this(TomlTable table, int index)
	{
		mTable = table;
		mIndex = index;
	}

	/// @brief The entry's key.
	public StringView Key => mTable.GetKeyAt(mIndex);

	// ---- Typed readers ----

	/// @brief Read the entry value as a string.
	/// @param value On success, the string value.
	/// @return True if the entry holds a String.
	public bool TryGetString(out StringView value)
	{
		return mTable.GetValueAt(mIndex).TryGetString(out value);
	}

	/// @brief Read the entry value as an integer.
	/// @param value On success, the integer value.
	/// @return True if the entry holds an Integer.
	public bool TryGetInteger(out int64 value)
	{
		return mTable.GetValueAt(mIndex).TryGetInteger(out value);
	}

	/// @brief Read the entry value as a float.
	/// @param value On success, the float value.
	/// @return True if the entry holds a Float.
	public bool TryGetFloat(out double value)
	{
		return mTable.GetValueAt(mIndex).TryGetFloat(out value);
	}

	/// @brief Read the entry value as a boolean.
	/// @param value On success, the boolean value.
	/// @return True if the entry holds a Bool.
	public bool TryGetBool(out bool value)
	{
		return mTable.GetValueAt(mIndex).TryGetBool(out value);
	}

	/// @brief Read the entry value as an offset date-time.
	/// @param value On success, the offset date-time value.
	/// @return True if the entry holds an OffsetDateTime.
	public bool TryGetOffsetDateTime(out TomlOffsetDateTime value)
	{
		return mTable.GetValueAt(mIndex).TryGetOffsetDateTime(out value);
	}

	/// @brief Read the entry value as a local date-time.
	/// @param value On success, the local date-time value.
	/// @return True if the entry holds a LocalDateTime.
	public bool TryGetLocalDateTime(out TomlLocalDateTime value)
	{
		return mTable.GetValueAt(mIndex).TryGetLocalDateTime(out value);
	}

	/// @brief Read the entry value as a local date.
	/// @param value On success, the local date value.
	/// @return True if the entry holds a LocalDate.
	public bool TryGetLocalDate(out TomlLocalDate value)
	{
		return mTable.GetValueAt(mIndex).TryGetLocalDate(out value);
	}

	/// @brief Read the entry value as a local time.
	/// @param value On success, the local time value.
	/// @return True if the entry holds a LocalTime.
	public bool TryGetLocalTime(out TomlLocalTime value)
	{
		return mTable.GetValueAt(mIndex).TryGetLocalTime(out value);
	}

	/// @brief Read the entry value as a table reference.
	/// @param value On success, the table reference.
	/// @return True if the entry holds a Table.
	public bool TryGetTable(out TomlTable value)
	{
		return mTable.GetValueAt(mIndex).TryGetTable(out value);
	}

	/// @brief Read the entry value as an array reference.
	/// @param value On success, the array reference.
	/// @return True if the entry holds an Array.
	public bool TryGetArray(out TomlArray value)
	{
		return mTable.GetValueAt(mIndex).TryGetArray(out value);
	}

	// ---- Safe scalar assignment ----

	/// @brief Assign a scalar value to this entry via implicit conversion.
	public TomlInputValue Value
	{
		set
		{
			mTable.SetValueAt(mIndex, value);
		}
	}

	// ---- Container replacement ----

	/// @brief Replace this entry with a new store-backed table and return it.
	/// @return The new table.
	public TomlTable SetTable()
	{
		return mTable.SetTableAt(mIndex);
	}

	/// @brief Replace this entry with a new store-backed array and return it.
	/// @return The new array.
	public TomlArray SetArray()
	{
		return mTable.SetArrayAt(mIndex);
	}

	// ---- Key rename ----

	/// @brief Rename this entry's key.
	/// @return .Ok on success, or .Err if the new key already exists.
	public Result<void, TomlParseError> Rename(StringView newKey)
	{
		return mTable.RenameAt(mIndex, newKey);
	}

	// ---- Deletion ----

	/// @brief Remove this entry from the table.
	public void Remove()
	{
		mTable.RemoveAt(mIndex);
	}
}
