using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// A table entry: its value and, with Positions/PreserveStyle metadata, its node ID. Keeping the ID with
/// the value means one hash lookup finds both, and removal, renaming and clearing carry it along.
/// A TOML table: an ordered map from key to TomlValue, with metadata for conflict detection.
public class TomlTable
{
	private TomlTableOrigin mOrigin;
	private bool mIsInlineSealed;
	/// @brief Set by parser after detecting a trailing comma before the closing brace.
	internal bool mHasTrailingComma;
	/// Entries in insertion order; keys are owned by the store (see TomlEntryMap).
	private TomlEntryMap mEntries;
	private TomlContainerMetadataContext mMetadataContext ~ delete _;
	/// @brief The owning document store. Its mSuppressAutoDirty is set while the parser fills it.
	internal TomlDocumentStore mStore;

	public ~this()
	{
		mEntries.Dispose();
	}

	internal this(TomlTableOrigin origin)
	{
		mOrigin = origin;
		mIsInlineSealed = false;
		mMetadataContext = null;
	}

	/// How the table came to exist; drives the parser's conflict rules and how the table is written.
	internal TomlTableOrigin Origin
	{
		get => mOrigin;
		set => mOrigin = value;
	}

	/// An inline table (or a table inside one) that can no longer be extended.
	internal bool IsInlineSealed
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

	/// @brief Get the key at the given index in insertion order.
	public StringView GetKeyAt(int index)
	{
		return mEntries[index].mKey;
	}

	/// @brief Get the value for the key at the given index in insertion order, for reading values of any
	/// type (e.g. when walking a document). Prefer the typed TryGet* methods when the type is known.
	/// The returned TomlValue borrows document-owned storage: valid until the document is cleared.
	/// @param index The entry index (0 to Count - 1).
	/// @return The entry value.
	public TomlValue GetValueAt(int index)
	{
		return mEntries[index].mValue;
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
		return mEntries.IndexOf(key) >= 0;
	}

	/// @brief Get the value for a key regardless of its type. Prefer the typed TryGet* methods when the
	/// type is known. The value borrows document-owned storage: valid until the document is cleared.
	/// @param key The key to look up.
	/// @param value Receives the value, or default if the key is missing.
	/// @return True if the key exists.
	public bool TryGetValue(StringView key, out TomlValue value)
	{
		let index = mEntries.IndexOf(key);
		if (index >= 0)
		{
			value = mEntries[index].mValue;
			return true;
		}
		value = default;
		return false;
	}

	/// The metadata node ID of the entry for `key`.
	/// @return False if the key is missing or the entry has no node ID.
	internal bool TryGetEntryNodeId(StringView key, out TomlNodeId nodeId)
	{
		let index = mEntries.IndexOf(key);
		if (index >= 0 && mEntries[index].mNodeId.IsValid)
		{
			nodeId = mEntries[index].mNodeId;
			return true;
		}
		nodeId = .Invalid;
		return false;
	}

	/// The metadata node ID of the entry at `index` (Invalid if it has none).
	internal TomlNodeId GetEntryNodeIdAt(int index)
	{
		return mEntries[index].mNodeId;
	}

	/// Sets the metadata node ID of the existing entry for `key`.
	internal void SetEntryNodeId(StringView key, TomlNodeId nodeId)
	{
		let index = mEntries.IndexOf(key);
		if (index >= 0)
			mEntries[index].mNodeId = nodeId;
	}

	/// Insert or replace an entry. A new entry gets `presetNodeId` as its metadata node ID when valid (the
	/// parser allocates IDs up front); otherwise one is allocated and the table is marked Children-dirty.
	internal void Insert(StringView key, TomlValue value, TomlNodeId presetNodeId = .Invalid)
	{
		if (TryInsertNew(key, value, presetNodeId))
			return;

		ref TomlTableSlot existing = ref mEntries[mEntries.IndexOf(key)];
		if (existing.mValue.IsSemanticallyEqualTo(value))
			return;
		existing.mValue = value;
		MarkEntryDirty(key);
		BindContainerMetadata(value);
	}

	/// Adds a new entry with a single hash lookup (the parser's path for every key).
	/// @return False, changing nothing, if `key` already exists.
	internal bool TryInsertNew(StringView key, TomlValue value, TomlNodeId presetNodeId = .Invalid)
	{
		let index = mEntries.FindOrAdd(key, let added);
		if (!added)
			return false;

		// Node-ID registration for new entries when a metadata context exists. Parser-inserted entries
		// arrive with their ID; only genuinely new entries allocate one and mark the table dirty.
		bool hasMetadata = mMetadataContext != null && mMetadataContext.mMetadata != null;
		TomlNodeId nodeId = .Invalid;
		if (hasMetadata)
			nodeId = presetNodeId.IsValid ? presetNodeId : mMetadataContext.mMetadata.AllocateNodeId();

		ref TomlTableSlot slot = ref mEntries[index];
		slot.mKey = mStore.NewKey(key);
		slot.mValue = value;
		slot.mNodeId = nodeId;

		if (hasMetadata)
		{
			if (!presetNodeId.IsValid && !mStore.mSuppressAutoDirty)
			{
				MarkChildrenDirty();
				AdoptNeighborFormat(nodeId, value);
			}
			BindContainerMetadata(value);
		}
		return true;
	}

	/// Nearby style: an entry added in code takes the value format of the nearest earlier entry of the
	/// same kind that has one (a new integer among hex integers is written in hex; see
	/// TomlValue.HasSameStyleKind for which kinds take part). Formats are never
	/// edited in place (style setters add new ones), so sharing the neighbor's is safe. Only with
	/// PreserveStyle metadata; a later merge still copies the source's own style over it.
	private void AdoptNeighborFormat(TomlNodeId nodeId, TomlValue value)
	{
		let metadata = SidecarFor(nodeId);
		if (metadata == null)
			return;
		for (int i = mEntries.Count - 2; i >= 0; i--)
		{
			let sibling = mEntries[i];
			if (!sibling.mNodeId.IsValid || !sibling.mValue.HasSameStyleKind(value))
				continue;
			let formatRef = metadata.GetNodeStyle(sibling.mNodeId).mValueFormatRef;
			if (!formatRef.IsValid)
				continue;
			metadata.GetNodeStyle(nodeId).mValueFormatRef = formatRef;
			return;
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
		let index = mEntries.IndexOf(key);
		if (index >= 0)
		{
			ref TomlTableSlot existing = ref mEntries[index];
			// If semantically equal, keep clean and discard the incoming value
			if (existing.mValue.IsSemanticallyEqualTo(value))
				return true;
			existing.mValue = value;
			MarkEntryDirty(key);
			BindContainerMetadata(value);
			return true;
		}
		return false;
	}

	/// @brief Set a scalar value for `key`, inserting or replacing it: `table.Set("port", 8080)`.
	/// Accepts strings, integers, floats, bools and the four date/time types (they convert implicitly to
	/// TomlInputValue). Strings are copied into the document. Assigning a value equal to the current one
	/// changes nothing (no allocation; a PreserveStyle node stays clean). Use AddTable/AddArray for
	/// containers.
	/// @param key The key.
	/// @param value The value.
	public void Set(StringView key, TomlInputValue value)
	{
		var input = value;
		if (!input.IsValid)
			Runtime.FatalError("Invalid TomlInputValue");
		if (TryGetValue(key, let existing) && input.Matches(existing))
			return;
		TomlValue stored = input.Materialize(mStore);
		if (!ReplaceValue(key, stored))
			Insert(key, stored);
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

	/// @brief Create an array of tables for the given key, written as `[[key]]` sections, and return it.
	/// Add its elements with TomlArray.AddTable.
	/// @param key The key.
	/// @return The new array, or null if the key already exists.
	public TomlArray AddArrayOfTables(StringView key)
	{
		if (ContainsKey(key))
			return null;
		TomlArray arr = mStore.NewArray();
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
		for (int i = 0; i < mEntries.Count; i++)
		{
			let nodeId = GetEntryNodeIdAt(i);
			if (nodeId.IsValid)
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
		let index = mEntries.IndexOf(key);
		if (index < 0)
			return false;
		RemoveAt(index);
		return true;
	}

	/// @brief Get the value for a key regardless of its type. The value borrows document-owned storage:
	/// valid until the document is cleared. Prefer the typed TryGet* methods when the type is known.
	/// @param key The key to look up.
	/// @return The value, or .Err if the key is missing.
	public Result<TomlValue> Get(StringView key)
	{
		if (TryGetValue(key, let value))
			return value;
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

	/// @brief Get a String value for a key, or a fallback when it is missing or not a String.
	/// @param key The key to look up.
	/// @param defaultValue Returned when the key is missing or holds another type.
	/// @return The stored string (borrowed from the document) or defaultValue.
	public StringView GetString(StringView key, StringView defaultValue)
	{
		return TryGetString(key, let value) ? value : defaultValue;
	}

	/// @brief Get an Integer value for a key, or a fallback when it is missing or not an Integer.
	/// @param key The key to look up.
	/// @param defaultValue Returned when the key is missing or holds another type.
	/// @return The stored integer or defaultValue.
	public int64 GetInteger(StringView key, int64 defaultValue)
	{
		return TryGetInteger(key, let value) ? value : defaultValue;
	}

	/// @brief Get a Float value for a key, or a fallback when it is missing or not a Float.
	/// @param key The key to look up.
	/// @param defaultValue Returned when the key is missing or holds another type.
	/// @return The stored float or defaultValue.
	public double GetFloat(StringView key, double defaultValue)
	{
		return TryGetFloat(key, let value) ? value : defaultValue;
	}

	/// @brief Get a Bool value for a key, or a fallback when it is missing or not a Bool.
	/// @param key The key to look up.
	/// @param defaultValue Returned when the key is missing or holds another type.
	/// @return The stored bool or defaultValue.
	public bool GetBool(StringView key, bool defaultValue)
	{
		return TryGetBool(key, let value) ? value : defaultValue;
	}

	/// @brief Remove all entries from this table. Removed payloads stay allocated in the document store until the document is cleared or destroyed.
	public void Clear()
	{
		bool hadEntries = mEntries.Count > 0;
		mEntries.Clear();
		// Keep the table's own metadata (node ID, header comments) so it is still written with its style
		// and later insertions get node IDs; the entries' IDs went with the entries.
		if (mMetadataContext != null && hadEntries)
			MarkChildrenDirty();
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
		for (int i = 0; i < source.mEntries.Count; i++)
		{
			StringView key = source.mEntries[i].mKey;
			if (!TryGetValue(key, let existing))
				continue;

			int pathLen = path.Length;
			AppendMergePathSegment(path, key);
			let incoming = source.mEntries[i].mValue;
			if (existing.IsTable && incoming.IsTable)
				Try!(existing.AsTable.ValidateMerge(incoming.AsTable, path));
			else
			{
				// With positions on the incoming side (a merge read with metadata), point at its key
				source.TryGetNodeRange(source.mEntries[i].mNodeId, var range);
				return .Err(TomlParseError.Located(.DuplicateKey, scope $"Duplicate key '{path}' during merge", range));
			}
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
		for (int i = 0; i < source.mEntries.Count; i++)
		{
			StringView key = source.mEntries[i].mKey;
			TomlValue incoming = source.mEntries[i].mValue;
			if (!TryGetValue(key, let existing))
			{
				TomlValue copy = incoming.CloneInto(mStore);
				Insert(key, copy);
				if (dstMeta != null)
				{
					// Merged values keep their source's formatting, so drop any nearby style Insert
					// adopted; with srcMeta the source's own format is copied below
					if (srcMeta == null && TryGetEntryNodeId(key, let newId))
						dstMeta.GetNodeStyle(newId).mValueFormatRef = .Invalid;
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
		if (source.TryGetEntryNodeId(key, let srcId) && TryGetEntryNodeId(key, let dstId))
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

		for (int i = 0; i < mEntries.Count; i++)
		{
			switch (mEntries[i].mValue)
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
		for (int i = 0; i < mEntries.Count; i++)
			result.Insert(mEntries[i].mKey, mEntries[i].mValue.CloneInto(store));
		return result;
	}

	// ================================================================
	// Dirty tracking helpers
	// ================================================================

	/// Mark a specific entry as dirty. Call after programmatic value changes.
	internal void MarkEntryDirty(StringView key)
	{
		let index = mEntries.IndexOf(key);
		if (index >= 0)
			MarkEntryDirtyAt(index);
	}

	/// Mark the entry at `index` as dirty.
	private void MarkEntryDirtyAt(int index)
	{
		if (mMetadataContext == null || mMetadataContext.mMetadata == null)
			return;
		let nodeId = mEntries[index].mNodeId;
		if (!nodeId.IsValid)
			return;
		let style = mMetadataContext.mMetadata.GetNodeStyle(nodeId);
		if (style != null)
			style.mDirtyFlags |= .Value;
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
		let metadata = SidecarFor(nodeId);
		if (metadata == null)
			return false;
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
		let metadata = SidecarFor(nodeId);
		if (metadata == null)
			return false;
		var fmt = TomlIntegerFormat();
		let current = metadata.GetNodeStyle(nodeId).mValueFormatRef;
		if (current.IsValid && metadata.mValueFormats[current.mIndex] case .Integer(let existing))
			fmt = existing;
		fmt.mBase = integerBase;
		return ApplyStyle(nodeId, .Integer(fmt));
	}

	/// @brief Choose whether the float at `key` is written in decimal (`1500.0`) or scientific (`1.5e3`)
	/// notation. The value is always written exactly; inf and nan are unaffected.
	/// @param key The key of a float value.
	/// @param notation The notation to write.
	/// @return False if the document has no PreserveStyle metadata or the value is not a float.
	public bool SetFloatNotation(StringView key, TomlFloatNotation notation)
	{
		if (!TryGetValue(key, let val) || !val.IsFloat)
			return false;
		let metadata = StyleTarget(key, let nodeId);
		if (metadata == null)
			return false;
		var fmt = TomlFloatFormat();
		if (TryGetValueFormat(metadata, nodeId, let current) && current case .Float(let existing))
			fmt = existing;
		let style = (notation == .Scientific) ? TomlFloatStyle.Scientific : TomlFloatStyle.Decimal;
		// Captured digit counts and grouping describe the old notation, so a change starts fresh
		if (fmt.mStyle != style)
			fmt = TomlFloatFormat() { mStyle = style, mUppercaseExponent = fmt.mUppercaseExponent };
		return ApplyStyle(nodeId, .Float(fmt));
	}

	/// @brief Choose how the offset date-time, local date-time or local time at `key` is written: the
	/// date/time separator, `Z` or `+00:00` for a zero offset, and a minimum number of fraction digits.
	/// @param key The key of a date-time or time value.
	/// @param style The style to write; Separator must be 'T' or ' ' and MinFractionDigits 0-9.
	/// @return False if the document has no PreserveStyle metadata, the value is not a date-time or time
	/// (a local date has nothing to style), or the style is out of range.
	public bool SetDateTimeStyle(StringView key, TomlDateTimeStyle style)
	{
		if (!TryGetValue(key, let val) || !(val.IsOffsetDateTime || val.IsLocalDateTime || val.IsLocalTime))
			return false;
		if ((style.Separator != 'T' && style.Separator != ' ') || style.MinFractionDigits < 0 || style.MinFractionDigits > 9)
			return false;
		let metadata = StyleTarget(key, let nodeId);
		if (metadata == null)
			return false;
		var fmt = TomlDateTimeFormat() { mHasSeconds = true, mHasOffset = val.IsOffsetDateTime };
		if (TryGetValueFormat(metadata, nodeId, let current) && current case .DateTime(let existing))
			fmt = existing;
		fmt.mSeparator = style.Separator;
		fmt.mUsesZ = style.UseZ;
		fmt.mLowercaseZ = false;
		fmt.mFractionalDigits = (uint8)style.MinFractionDigits;
		return ApplyStyle(nodeId, .DateTime(fmt));
	}

	/// @brief Choose whether the array at `key` is written on one line or one element per line. An array
	/// whose elements carry comments is written one element per line regardless.
	/// @param key The key of an array (not an array of tables).
	/// @param layout The layout to write.
	/// @param trailingComma For the multi-line layout, whether the last element gets a comma.
	/// @return False if the document has no PreserveStyle metadata or the value is not an array.
	public bool SetArrayLayout(StringView key, TomlArrayLayout layout, bool trailingComma = true)
	{
		if (!TryGetValue(key, let val) || !val.IsArray || !val.AsArray.IsStatic)
			return false;
		let metadata = StyleTarget(key, let nodeId);
		if (metadata == null)
			return false;
		var fmt = TomlArrayFormat();
		if (TryGetValueFormat(metadata, nodeId, let current) && current case .Array(let existing))
			fmt = existing;
		// A one-line array's indent is only the document default at capture time; newly multi-line, it
		// follows the document's indentation (0 = the document's) when written
		if (fmt.mStyle != .Multiline)
			fmt.mIndentSize = 0;
		fmt.mStyle = (layout == .Multiline) ? .Multiline : .Inline;
		fmt.mTrailingComma = layout == .Multiline && trailingComma;
		return ApplyStyle(nodeId, .Array(fmt));
	}

	/// @brief Choose how the inline table at `key` is laid out: `{a=1,b=2}`, `{ a = 1, b = 2 }`, or one
	/// field per line (TOML 1.1; a 1.0 write keeps it on one line). Fields with comments need the
	/// multi-line layout and get it on a 1.1 write regardless.
	/// @param key The key of an inline table.
	/// @param layout The layout to write.
	/// @return False if the document has no PreserveStyle metadata or the value is not an inline table.
	public bool SetInlineTableLayout(StringView key, TomlInlineTableLayout layout)
	{
		if (!TryGetValue(key, let val) || !val.IsTable || val.AsTable.mOrigin != .InlineTable)
			return false;
		let metadata = StyleTarget(key, let nodeId);
		if (metadata == null)
			return false;
		var fmt = TomlTableFormat() { mInline = true };
		if (TryGetValueFormat(metadata, nodeId, let current) && current case .Table(let existing))
			fmt = existing;
		uint8 spacing = (layout == .Compact) ? 0 : 1;
		fmt.mInline = true;
		fmt.mMultiline = layout == .Multiline;
		fmt.mOpenBraceSpacing = spacing;
		fmt.mCloseBraceSpacing = spacing;
		fmt.mEqualsSpacing = spacing;
		fmt.mCommaSpacing = spacing;
		return ApplyStyle(nodeId, .Table(fmt));
	}

	/// @brief Choose how `key` itself is quoted on its `key = value` line (or as an inline-table field):
	/// bare, "basic" or 'literal'. A key that cannot be written that way falls back to basic quotes (see
	/// TomlKeyQuoting). Keys written as part of a dotted path or a `[header]` keep automatic quoting.
	/// @param key The key.
	/// @param quoting The quoting to write.
	/// @return False if the document has no PreserveStyle metadata, the key is missing, or it names a
	/// `[header]` table or an array of tables.
	public bool SetKeyQuoting(StringView key, TomlKeyQuoting quoting)
	{
		if (!TryGetValue(key, let val))
			return false;
		// Header tables and arrays of tables are written as [path] headers, not key = value lines
		if ((val.IsTable && val.AsTable.mOrigin != .InlineTable) || (val.IsArray && !val.AsArray.IsStatic))
			return false;
		let metadata = StyleTarget(key, let nodeId);
		if (metadata == null)
			return false;
		let style = metadata.GetNodeStyle(nodeId);
		var fmt = TomlKeyFormat();
		if (style.mKeyFormatRef.IsValid)
			fmt = metadata.mKeyFormats[style.mKeyFormatRef.mIndex];
		switch (quoting)
		{
		case .Bare:    fmt.mStyle = .Bare;
		case .Basic:   fmt.mStyle = .QuotedBasic;
		case .Literal: fmt.mStyle = .QuotedLiteral;
		}
		// Keys are always regenerated from their format, so no dirty flag is needed
		style.mKeyFormatRef = metadata.AddKeyFormat(fmt);
		return true;
	}

	/// @brief Get the comment lines above this table's own `[header]` or `[[header]]` line, joined with '\n'
	/// (for example an array-of-tables element's).
	/// @param outComment Receives the comment text (appended).
	/// @return True if the header has a leading comment.
	public bool TryGetHeaderComment(String outComment)
	{
		return TryGetLeading(mMetadataContext?.mNodeId ?? .Invalid, outComment);
	}

	/// @brief Get the comment at the end of this table's own header line.
	/// @param outComment Receives the comment text (appended).
	/// @return True if the header line has a trailing comment.
	public bool TryGetHeaderTrailingComment(String outComment)
	{
		return TryGetTrailing(mMetadataContext?.mNodeId ?? .Invalid, outComment);
	}

	/// @brief Where the value at `key` appeared in the source: the start of its key (or of its `[header]`
	/// for a header table, or of the first `[[header]]` for an array of tables), and the length through
	/// the end of the value or header. Useful for reporting validation errors against the file.
	/// Requires a document read with Positions or PreserveStyle; values added in code have no position.
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
	/// array-of-tables element). Requires a document read with Positions or PreserveStyle.
	/// @param range Receives the 1-based line and column, byte offset, and length of the header.
	/// @return True if a source position is known.
	public bool TryGetHeaderSourceRange(out TomlSourceRange range)
	{
		return TryGetNodeRange(mMetadataContext?.mNodeId ?? .Invalid, out range);
	}

	internal bool TryGetNodeRange(TomlNodeId nodeId, out TomlSourceRange range)
	{
		range = default;
		// Positions are recorded in both Positions and PreserveStyle mode, so any sidecar will do
		let metadata = mMetadataContext?.mMetadata;
		return metadata != null && metadata.TryGetSourceRange(nodeId, out range);
	}

	// ================================================================
	// Validation: errors located in the source
	// ================================================================

	/// @brief Build an error about the value at `key` for your own validation, located where the value
	/// appeared in the source: `return .Err(server.MakeError("port", "must be positive"));` prints (via
	/// ToString) as `config.toml:12:3: port: must be positive`. A missing key is located at this table's
	/// header. Needs a document read with Positions or PreserveStyle for a position; without one the
	/// message still names the key.
	/// @param key The key the problem is about (it need not exist).
	/// @param message What is wrong with it.
	/// @return An error of kind InvalidValue.
	public TomlParseError MakeError(StringView key, StringView message)
	{
		return TomlParseError.Located(.InvalidValue, scope $"{key}: {message}", ProblemLocation(key));
	}

	/// @brief Get a required String: a missing key or a value of another type is a located error
	/// (MissingKey, at this table's header, or WrongType, at the value).
	/// @param key The key.
	/// @return The string (borrowed from the document), or the error.
	public Result<StringView, TomlParseError> RequireString(StringView key)
	{
		return Try!(RequireValue(key, key, "string")).AsString;
	}

	/// @brief Get a required Integer; see RequireString for the errors.
	/// @param key The key.
	/// @return The integer, or the error.
	public Result<int64, TomlParseError> RequireInteger(StringView key)
	{
		return Try!(RequireValue(key, key, "integer")).AsInteger;
	}

	/// @brief Get a required Float (an integer is not accepted); see RequireString for the errors.
	/// @param key The key.
	/// @return The float, or the error.
	public Result<double, TomlParseError> RequireFloat(StringView key)
	{
		return Try!(RequireValue(key, key, "float")).AsFloat;
	}

	/// @brief Get a required Bool; see RequireString for the errors.
	/// @param key The key.
	/// @return The bool, or the error.
	public Result<bool, TomlParseError> RequireBool(StringView key)
	{
		return Try!(RequireValue(key, key, "boolean")).AsBool;
	}

	/// @brief Get a required Table; see RequireString for the errors.
	/// @param key The key.
	/// @return The table, or the error.
	public Result<TomlTable, TomlParseError> RequireTable(StringView key)
	{
		return Try!(RequireValue(key, key, "table")).AsTable;
	}

	/// @brief Get a required Array; see RequireString for the errors.
	/// @param key The key.
	/// @return The array, or the error.
	public Result<TomlArray, TomlParseError> RequireArray(StringView key)
	{
		return Try!(RequireValue(key, key, "array")).AsArray;
	}

	/// The value at `key` if it has type `typeName` (as TomlValue.TypeName spells it); otherwise a located
	/// MissingKey or WrongType error naming `path` (the key, or the full dotted path for document calls).
	internal Result<TomlValue, TomlParseError> RequireValue(StringView key, StringView path, StringView typeName)
	{
		if (!TryGetValue(key, let value))
			return .Err(TomlParseError.Located(.MissingKey, scope $"{path}: missing required {typeName}", ProblemLocation()));
		if (value.TypeName != typeName)
			return .Err(TomlParseError.Located(.WrongType, scope $"{path}: expected {typeName}, found {value.TypeName}", ProblemLocation(key)));
		return value;
	}

	/// Where to report a problem with this table as a whole (such as a missing key): its header, or for a
	/// table without one (the root) just the document's source name when it was read from one source.
	internal TomlSourceRange ProblemLocation()
	{
		if (TryGetHeaderSourceRange(let range))
			return range;
		let metadata = mMetadataContext?.mMetadata;
		if (metadata != null && metadata.mSourceNames.Count == 1)
			return .(0, 0, 0, 0, metadata.mSourceNames[0]);
		return default;
	}

	/// Where to report a problem with the value at `key`, falling back to the table's own location.
	internal TomlSourceRange ProblemLocation(StringView key)
	{
		if (TryGetSourceRange(key, let range))
			return range;
		return ProblemLocation();
	}

	/// The node that holds `key`'s entry style (value format, key format).
	private TomlNodeId EntryNodeFor(StringView key)
	{
		if (mMetadataContext == null || mMetadataContext.mMetadata == null)
			return .Invalid;
		TryGetEntryNodeId(key, let nodeId);
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

	/// The sidecar for comment and style edits: null unless it captures style (PreserveStyle).
	private TomlDocumentMetadata SidecarFor(TomlNodeId nodeId)
	{
		let metadata = nodeId.IsValid ? mMetadataContext?.mMetadata : null;
		return (metadata != null && metadata.CapturesStyle) ? metadata : null;
	}

	/// The sidecar and node for a style edit of the value at `key`; null without PreserveStyle metadata.
	private TomlDocumentMetadata StyleTarget(StringView key, out TomlNodeId nodeId)
	{
		nodeId = EntryNodeFor(key);
		return SidecarFor(nodeId);
	}

	/// The value format recorded for a node (captured from the source or set earlier), if any.
	private static bool TryGetValueFormat(TomlDocumentMetadata metadata, TomlNodeId nodeId, out TomlValueFormat format)
	{
		let formatRef = metadata.GetNodeStyle(nodeId).mValueFormatRef;
		if (formatRef.IsValid)
		{
			format = metadata.mValueFormats[formatRef.mIndex];
			return true;
		}
		format = default;
		return false;
	}

	private bool SetLeadingComment(TomlNodeId nodeId, StringView comment)
	{
		let metadata = SidecarFor(nodeId);
		return metadata != null && metadata.SetLeadingCommentText(nodeId, comment);
	}

	private bool SetTrailing(TomlNodeId nodeId, StringView comment)
	{
		let metadata = SidecarFor(nodeId);
		return metadata != null && metadata.SetTrailingCommentText(nodeId, comment);
	}

	private bool TryGetLeading(TomlNodeId nodeId, String outComment)
	{
		let metadata = SidecarFor(nodeId);
		return metadata != null && metadata.TryGetLeadingCommentText(nodeId, outComment);
	}

	private bool TryGetTrailing(TomlNodeId nodeId, String outComment)
	{
		let metadata = SidecarFor(nodeId);
		return metadata != null && metadata.TryGetTrailingCommentText(nodeId, outComment);
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
		mEntries.RemoveAt(index);
		MarkChildrenDirty();
	}

	/// @brief Set a scalar value at the given index via safe input wrapper.
	internal void SetValueAt(int index, TomlInputValue value)
	{
		var slot = value;
		if (!slot.IsValid)
			Runtime.FatalError("Invalid TomlInputValue");
		// Assigning an equal value keeps the entry clean (and its original token reusable)
		if (slot.Matches(mEntries[index].mValue))
			return;
		TomlValue stored = slot.Materialize(mStore);
		MarkEntryDirtyAt(index);
		mEntries[index].mValue = stored;
		BindContainerMetadata(stored);
	}

	/// @brief Replace the entry at the given index with a new store-backed table.
	internal TomlTable SetTableAt(int index)
	{
		TomlTable tbl = mStore.NewTable(.InlineTable);
		TomlValue val = .Table(tbl);
		mEntries[index].mValue = val;
		MarkEntryDirtyAt(index);
		BindContainerMetadata(val);
		return tbl;
	}

	/// @brief Replace the entry at the given index with a new store-backed array.
	internal TomlArray SetArrayAt(int index)
	{
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		TomlValue val = .Array(arr);
		mEntries[index].mValue = val;
		MarkEntryDirtyAt(index);
		BindContainerMetadata(val);
		return arr;
	}

	/// @brief Rename the entry at the given index.
	/// @return .Ok on success, or .Err if the new key already exists.
	internal Result<void, TomlParseError> RenameAt(int index, StringView newKey)
	{
		if (ContainsKey(newKey))
			return .Err(TomlParseError(.DuplicateKey, scope $"Key '{newKey}' already exists", 0, 0, 0));
		// The entry keeps its value, metadata node ID and position
		mEntries.SetKeyAt(index, mStore.NewKey(newKey));
		MarkEntryDirtyAt(index);
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
