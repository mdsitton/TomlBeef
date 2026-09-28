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

	/// @brief Get the value for the key at the given index in insertion order, for reading values of any
	/// type (e.g. when walking a document). Prefer the typed TryGet* methods when the type is known.
	/// The returned TomlValue borrows document-owned storage: valid until the document is cleared.
	/// @param index The entry index (0 to Count - 1).
	/// @return The entry value.
	public TomlValue GetValueAt(int index)
	{
		return mEntries[mKeyOrder[index]];
	}

	/// @brief Get an entry proxy at the given index for typed access, safe assignment, and mutations.
	public TomlTableEntry this[int index]
	{
		get => TomlTableEntry(this, index);
	}

	/// @brief Iterate the entries in insertion order: `for (let entry in table) { entry.Key ... }`.
	/// Assigning values and renaming keys while iterating is fine; adding or removing keys is not
	/// (it is a fatal error, as it would skip or repeat entries).
	/// @return An enumerator of TomlTableEntry.
	public TomlTableEnumerator GetEnumerator()
	{
		return .(this);
	}

	public bool ContainsKey(StringView key)
	{
		if (mEntries != null)
			return mEntries.ContainsKeyAlt(key);
		return false;
	}

	/// @brief Get the value for a key regardless of its type. Prefer the typed TryGet* methods when the
	/// type is known. The value borrows document-owned storage: valid until the document is cleared.
	/// @param key The key to look up.
	/// @param value Receives the value, or default if the key is missing.
	/// @return True if the key exists.
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
			if (existingVal.IsSemanticallyEqualTo(value))
				return;
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
	/// @param value The new value. Its payload must already be owned by this table's document store.
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

	/// @brief Set a string value for the given key. The string is copied into the document store.
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

	/// @brief Check if this table should be written as dotted keys rather than a [header] (PreserveStyle writer).
	internal bool HasDottedPreference(TomlDocumentMetadata metadata)
	{
		// A table created by a dotted key (`a.b.c = 1` creates `a` and `b`) had no header in the source.
		// Checked first: intermediate tables created during the parse may have no metadata context.
		if (mOrigin == .Implicit)
			return true;
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

	/// @brief Get the value for a key regardless of its type. The value borrows document-owned storage:
	/// valid until the document is cleared. Prefer the typed TryGet* methods when the type is known.
	/// @param key The key to look up.
	/// @return The value, or .Err if the key is missing.
	public Result<TomlValue> Get(StringView key)
	{
		if (mEntries != null && mEntries.TryGetValueAlt(key, let val))
			return val;
		return .Err;
	}

	/// @brief Indexer that returns the value for a key, or an error result if not found. Same as Get:
	/// the value borrows document-owned storage and is valid until the document is cleared.
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

	/// @brief Remove all entries from this table. Removed payloads stay allocated in the document store until the document is cleared or destroyed.
	public void Clear()
	{
		bool hadEntries = mKeyOrder != null && mKeyOrder.Count > 0;
		if (mEntries != null)
			mEntries.Clear();
		if (mKeyOrder != null)
			mKeyOrder.Clear();
		// Keep the table's own metadata (node ID, header comments) so it is still written with its style
		// and later insertions get node IDs; only the per-entry mappings go.
		if (mMetadataContext != null)
		{
			mMetadataContext.ClearEntryNodeIds();
			if (hadEntries)
				MarkChildrenDirty();
		}
		mSuppressAutoDirty = false;
	}

	/// @brief Deep-merge another table into this one.
	/// Tables present on both sides are merged recursively. Everything else is a leaf: scalars, whole
	/// arrays, whole arrays of tables, and type mismatches (e.g. a table on one side and a value on the
	/// other). Only leaves present on both sides conflict. Existing tables keep their origin.
	/// @param source The table whose entries to merge. Unchanged on return; values are deep-copied.
	/// @param onConflict How to resolve a conflicting leaf (default: error).
	/// @return .Ok on success, or .Err (DuplicateKey, naming the dotted path) if a leaf conflicts and
	/// onConflict == .Error. The whole tree is checked first, so on error this table is unchanged.
	public Result<void, TomlParseError> MergeFrom(TomlTable source, MergeConflict onConflict = .Error)
	{
		if (onConflict == .Error)
			Try!(ValidateMerge(source, scope String()));
		// Carry the source's PreserveStyle metadata when both sides have a sidecar
		let srcMeta = source.mMetadataContext?.mMetadata;
		ApplyMerge(source, onConflict, srcMeta);
		return .Ok;
	}

	/// Pass 1 for MergeConflict.Error: find the first conflicting leaf without modifying anything.
	private Result<void, TomlParseError> ValidateMerge(TomlTable source, String path)
	{
		for (int i = 0; i < source.mKeyOrder.Count; i++)
		{
			String key = source.mKeyOrder[i];
			if (!TryGetValue(key, let existing))
				continue;

			int pathLen = path.Length;
			AppendMergePathSegment(path, key);
			if (existing.IsTable && source.mEntries[key].IsTable)
				Try!(existing.AsTable.ValidateMerge(source.mEntries[key].AsTable, path));
			else
				return .Err(TomlParseError(.DuplicateKey, scope $"Duplicate key '{path}' during merge", 0, 0, 0));
			path.Length = pathLen;
		}
		return .Ok;
	}

	/// Pass 2: insert new keys, recurse into shared tables, and resolve conflicting leaves.
	/// When this table has PreserveStyle metadata, merged values get node IDs; with `srcMeta` they also
	/// take the source's tokens, formats, and comments (see TomlMetadataTransfer).
	private void ApplyMerge(TomlTable source, MergeConflict onConflict, TomlDocumentMetadata srcMeta)
	{
		let dstMeta = mMetadataContext?.mMetadata;
		for (int i = 0; i < source.mKeyOrder.Count; i++)
		{
			String key = source.mKeyOrder[i];
			TomlValue incoming = source.mEntries[key];
			if (!TryGetValue(key, let existing))
			{
				TomlValue copy = incoming.CloneInto(mStore);
				Insert(key, copy);
				if (dstMeta != null)
				{
					// A new slot takes the source's key format and comments along with its value style
					CopySourceEntryStyle(source, key, srcMeta, dstMeta, true);
					TomlMetadataTransfer.AdoptValue(copy, incoming, dstMeta, srcMeta);
				}
				continue;
			}

			if (existing.IsTable && incoming.IsTable)
			{
				existing.AsTable.ApplyMerge(incoming.AsTable, onConflict, srcMeta);
			}
			else if (onConflict == .Overwrite && !existing.IsSemanticallyEqualTo(incoming))
			{
				TomlValue copy = incoming.CloneInto(mStore);
				ReplaceValue(key, copy);
				if (dstMeta != null)
				{
					// The slot keeps its key and comments; the value is written as the source had it
					CopySourceEntryStyle(source, key, srcMeta, dstMeta, false);
					TomlMetadataTransfer.AdoptValue(copy, incoming, dstMeta, srcMeta);
				}
			}
			// .Skip keeps the existing value; .Error conflicts were rejected by ValidateMerge
		}
	}

	/// Copies the style of `source`'s entry `key` onto this table's entry `key`, if both have node IDs.
	private void CopySourceEntryStyle(TomlTable source, StringView key, TomlDocumentMetadata srcMeta, TomlDocumentMetadata dstMeta, bool includeSlotStyle)
	{
		if (srcMeta == null || source.mMetadataContext == null)
			return;
		if (source.mMetadataContext.TryGetEntryNodeId(key, let srcId) && mMetadataContext.TryGetEntryNodeId(key, let dstId))
			TomlMetadataTransfer.CopyNodeStyle(srcMeta, srcId, dstMeta, dstId, includeSlotStyle);
	}

	/// Appends a key to a merge error path using the document path syntax (bracketed if it contains '.').
	private static void AppendMergePathSegment(String path, StringView key)
	{
		if (!path.IsEmpty)
			path.Append('.');
		if (key.Contains('.'))
			path.AppendF("[{}]", key);
		else
			path.Append(key);
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
						if (arr.GetValueAt(j) case .Table(let elemTbl) && elemTbl != null && elemTbl.mOrigin == .InlineTable)
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
	// ================================================================
	// Comments and presentation style (documents read with PreserveStyle)
	// ================================================================

	/// @brief Set the comment lines written above `key`. Separate lines with '\n'; each is written as
	/// `# line`, so omit the leading '#'. An empty comment removes them. For a key holding a `[header]`
	/// table this is the header's comment. An array of tables has one header per element: use
	/// SetHeaderComment on the element table instead.
	/// @param key The key to comment.
	/// @param comment The comment text without '#' markers.
	/// @return False if the document has no PreserveStyle metadata, the key is missing or is a non-empty
	/// array of tables, or the text contains control characters other than tab and '\n'.
	public bool SetComment(StringView key, StringView comment)
	{
		return SetLeadingComment(CommentNodeFor(key), comment);
	}

	/// @brief Set the comment written at the end of `key`'s line (for a `[header]` table, the header line).
	/// An empty comment removes it.
	/// @param key The key to comment.
	/// @param comment The comment text without the '#' marker. Must be a single line.
	/// @return False under the same conditions as SetComment, or if the comment contains a newline.
	public bool SetTrailingComment(StringView key, StringView comment)
	{
		return SetTrailing(CommentNodeFor(key), comment);
	}

	/// @brief Get the comment lines above `key`, joined with '\n'.
	/// @param key The key.
	/// @param outComment Receives the comment text (appended).
	/// @return True if the key has a leading comment.
	public bool TryGetComment(StringView key, String outComment)
	{
		return TryGetLeading(CommentNodeFor(key), outComment);
	}

	/// @brief Get the comment at the end of `key`'s line.
	/// @param key The key.
	/// @param outComment Receives the comment text (appended).
	/// @return True if the key has a trailing comment.
	public bool TryGetTrailingComment(StringView key, String outComment)
	{
		return TryGetTrailing(CommentNodeFor(key), outComment);
	}

	/// @brief Set the comment lines above this table's own `[header]` or `[[header]]` line. Use this for
	/// array-of-tables elements; for other tables it is the same as parent.SetComment(key).
	/// @param comment The comment text without '#' markers; lines separated by '\n'. Empty removes it.
	/// @return False if the document has no PreserveStyle metadata or the text is invalid.
	public bool SetHeaderComment(StringView comment)
	{
		return SetLeadingComment(mMetadataContext?.mNodeId ?? .Invalid, comment);
	}

	/// @brief Set the comment at the end of this table's own header line. Empty removes it.
	/// @param comment The comment text without the '#' marker. Must be a single line.
	/// @return False if the document has no PreserveStyle metadata or the text is invalid.
	public bool SetHeaderTrailingComment(StringView comment)
	{
		return SetTrailing(mMetadataContext?.mNodeId ?? .Invalid, comment);
	}

	/// @brief Choose how the string at `key` is written (basic, literal, or their multi-line forms).
	/// Literal forms fall back to basic when the value cannot be represented literally.
	/// @param key The key of a string value.
	/// @param style The string style to write.
	/// @return False if the document has no PreserveStyle metadata or the value is not a string.
	public bool SetStringStyle(StringView key, TomlStringStyle style)
	{
		if (!TryGetValue(key, let val) || !val.IsString)
			return false;
		let nodeId = EntryNodeFor(key);
		if (!nodeId.IsValid)
			return false;
		let metadata = mMetadataContext.mMetadata;
		var fmt = TomlStringFormat();
		fmt.mStartsWithNewline = true;
		let current = metadata.GetNodeStyle(nodeId).mValueFormatRef;
		if (current.IsValid && metadata.mValueFormats[current.mIndex] case .String(let existing))
			fmt = existing;
		// Keep a multi-line string's own opening-newline shape; one newly made multi-line starts on a new line
		bool wasMultiline = fmt.mStyle == .MultilineBasic || fmt.mStyle == .MultilineLiteral;
		if (!wasMultiline)
			fmt.mStartsWithNewline = true;
		fmt.mStyle = style;
		return ApplyStyle(nodeId, .String(fmt));
	}

	/// @brief Choose the base the integer at `key` is written in. Negative values are always written in
	/// decimal, since TOML only allows hex/octal/binary for non-negative integers.
	/// @param key The key of an integer value.
	/// @param integerBase The base to write.
	/// @return False if the document has no PreserveStyle metadata or the value is not an integer.
	public bool SetIntegerBase(StringView key, TomlIntegerBase integerBase)
	{
		if (!TryGetValue(key, let val) || !val.IsInteger)
			return false;
		let nodeId = EntryNodeFor(key);
		if (!nodeId.IsValid)
			return false;
		let metadata = mMetadataContext.mMetadata;
		var fmt = TomlIntegerFormat();
		let current = metadata.GetNodeStyle(nodeId).mValueFormatRef;
		if (current.IsValid && metadata.mValueFormats[current.mIndex] case .Integer(let existing))
			fmt = existing;
		fmt.mBase = integerBase;
		return ApplyStyle(nodeId, .Integer(fmt));
	}

	/// @brief Where the value at `key` appeared in the source: the start of its key (or of its `[header]`
	/// for a header table, or of the first `[[header]]` for an array of tables), and the length through
	/// the end of the value or header. Useful for reporting validation errors against the file.
	/// Requires a document read with PreserveStyle; values added or merged in code have no position.
	/// @param key The key.
	/// @param range Receives the 1-based line and column, byte offset, and length.
	/// @return True if a source position is known.
	public bool TryGetSourceRange(StringView key, out TomlSourceRange range)
	{
		range = default;
		if (!TryGetValue(key, let val))
			return false;
		if (val case .Array(let arr) && !arr.IsStatic && arr.Count > 0 && arr.GetValueAt(0) case .Table(let first))
			return first.TryGetHeaderSourceRange(out range);
		return TryGetNodeRange(CommentNodeFor(key), out range);
	}

	/// @brief Where this table's own `[header]` or `[[header]]` line appeared in the source (for example an
	/// array-of-tables element). Requires a document read with PreserveStyle.
	/// @param range Receives the 1-based line and column, byte offset, and length of the header.
	/// @return True if a source position is known.
	public bool TryGetHeaderSourceRange(out TomlSourceRange range)
	{
		return TryGetNodeRange(mMetadataContext?.mNodeId ?? .Invalid, out range);
	}

	internal bool TryGetNodeRange(TomlNodeId nodeId, out TomlSourceRange range)
	{
		range = default;
		let style = SidecarFor(nodeId)?.GetNodeStyle(nodeId);
		// Lines are 1-based, so an unset range has line 0
		if (style == null || style.mRange.mLine <= 0)
			return false;
		range = style.mRange;
		return true;
	}

	/// The node that holds `key`'s entry style (value format, key format).
	private TomlNodeId EntryNodeFor(StringView key)
	{
		if (mMetadataContext == null || mMetadataContext.mMetadata == null)
			return .Invalid;
		mMetadataContext.TryGetEntryNodeId(key, let nodeId);
		return nodeId;
	}

	/// The node whose comments are written around `key`: a `[header]` table's own node, otherwise the
	/// entry's node. Invalid for a non-empty array of tables (each element has its own header).
	private TomlNodeId CommentNodeFor(StringView key)
	{
		if (!TryGetValue(key, let val))
			return .Invalid;
		if (val case .Table(let sub) && sub.mOrigin != .InlineTable)
			return (sub.mMetadataContext?.mMetadata != null) ? sub.mMetadataContext.mNodeId : .Invalid;
		if (val case .Array(let arr) && !arr.IsStatic && arr.Count > 0)
			return .Invalid;
		return EntryNodeFor(key);
	}

	private TomlDocumentMetadata SidecarFor(TomlNodeId nodeId)
	{
		return nodeId.IsValid ? mMetadataContext?.mMetadata : null;
	}

	/// Comment text becomes `# text` lines, so it must not contain control characters (tab allowed).
	private static bool IsValidCommentText(StringView text, bool allowNewlines)
	{
		for (let c in text)
		{
			if (c == '\n' && allowNewlines)
				continue;
			if (c == '\n' || c == '\r' || (uint8)c == 0x7F || ((uint8)c < 0x20 && c != '\t'))
				return false;
		}
		return true;
	}

	private bool SetLeadingComment(TomlNodeId nodeId, StringView comment)
	{
		let metadata = SidecarFor(nodeId);
		if (metadata == null || !IsValidCommentText(comment, true))
			return false;
		let commentSet = metadata.GetOrCreateCommentSet(nodeId);
		ClearAndDeleteItems!(commentSet.mLeading);
		if (!comment.IsEmpty)
		{
			for (let line in comment.Split('\n'))
				commentSet.mLeading.Add(new String(line));
		}
		return true;
	}

	private bool SetTrailing(TomlNodeId nodeId, StringView comment)
	{
		let metadata = SidecarFor(nodeId);
		if (metadata == null || !IsValidCommentText(comment, false))
			return false;
		let commentSet = metadata.GetOrCreateCommentSet(nodeId);
		delete commentSet.mTrailing;
		commentSet.mTrailing = comment.IsEmpty ? null : new String(comment);
		return true;
	}

	private bool TryGetLeading(TomlNodeId nodeId, String outComment)
	{
		let metadata = SidecarFor(nodeId);
		let commentSet = metadata?.GetCommentSet(nodeId);
		if (commentSet == null || commentSet.mLeading.IsEmpty)
			return false;
		// Null entries are blank lines inside the comment block; they are layout, not comment text
		bool first = true;
		for (let line in commentSet.mLeading)
		{
			if (line == null)
				continue;
			if (!first)
				outComment.Append('\n');
			outComment.Append(line);
			first = false;
		}
		return !first;
	}

	private bool TryGetTrailing(TomlNodeId nodeId, String outComment)
	{
		let metadata = SidecarFor(nodeId);
		let commentSet = metadata?.GetCommentSet(nodeId);
		if (commentSet == null || commentSet.mTrailing == null)
			return false;
		outComment.Append(commentSet.mTrailing);
		return true;
	}

	/// Replaces the node's value format and marks it Style-dirty, so the writer regenerates the value
	/// in the new style instead of reusing its original token.
	private bool ApplyStyle(TomlNodeId nodeId, TomlValueFormat format)
	{
		let metadata = mMetadataContext.mMetadata;
		let formatRef = metadata.AddValueFormat(format);
		let style = metadata.GetNodeStyle(nodeId);
		style.mValueFormatRef = formatRef;
		style.mDirtyFlags |= .Style;
		return true;
	}

	internal void MarkChildrenDirty()
	{
		if (mMetadataContext == null || mMetadataContext.mMetadata == null)
			return;
		if (mMetadataContext.mNodeId.IsValid)
		{
			let style = mMetadataContext.mMetadata.GetNodeStyle(mMetadataContext.mNodeId);
			if (style != null)
				style.mDirtyFlags |= .Children;
		}
		else if (mOrigin == .Root)
		{
			mMetadataContext.mMetadata.mRootDirtyFlags |= .Children;
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
		// Assigning an equal value keeps the entry clean (and its original token reusable)
		if (slot.Matches(mEntries[mKeyOrder[index]]))
			return;
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

	/// @brief The entry's value, of any type (check it with IsString, IsTable, ...). The value borrows
	/// document-owned storage: valid until the document is cleared. Prefer the typed TryGet* readers.
	/// @return The entry value.
	public TomlValue GetValue()
	{
		return mTable.GetValueAt(mIndex);
	}

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

/// @brief Enumerates a TomlTable's entries in insertion order (see TomlTable.GetEnumerator).
public struct TomlTableEnumerator : IEnumerator<TomlTableEntry>
{
	private TomlTable mTable;
	private int mIndex;
	private int mCount;

	internal this(TomlTable table)
	{
		mTable = table;
		mIndex = 0;
		mCount = table.Count;
	}

	/// @brief Advance to the next entry.
	/// @return The next entry, or .Err when the iteration is finished.
	public Result<TomlTableEntry> GetNext() mut
	{
		if (mTable.Count != mCount)
			Runtime.FatalError("TomlTable modified (keys added or removed) during iteration");
		if (mIndex >= mCount)
			return .Err;
		return TomlTableEntry(mTable, mIndex++);
	}
}
