using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// @brief Safe wrapper for assigning scalar values to array elements and table entries.
/// Implicit conversions from scalar types allow natural syntax:
/// `arr[0] = "hello"`, `entry.Value = 42`.
/// Does not expose `TomlValue`, `TomlArray`, or `TomlTable` — closing the ownership hole.
public struct TomlInputValue
{
	internal enum SlotKind : uint8
	{
		Invalid,
		String,
		Integer,
		Float,
		Bool,
		OffsetDateTime,
		LocalDateTime,
		LocalDate,
		LocalTime
	}

	internal SlotKind mKind;
	internal StringView mStringValue;
	internal int64 mIntValue;
	internal double mFloatValue;
	internal bool mBoolValue;
	internal TomlOffsetDateTime mOffsetDateTimeValue;
	internal TomlLocalDateTime mLocalDateTimeValue;
	internal TomlLocalDate mLocalDateValue;
	internal TomlLocalTime mLocalTimeValue;

	internal bool IsValid => mKind != .Invalid;

	/// @brief Materialize the value into a TomlValue, allocating through the store if available.
	internal TomlValue Materialize(TomlDocumentStore store) mut
	{
		switch (mKind)
		{
		case .String:    return .String(store.NewString(mStringValue));
		case .Integer:   return .Integer(mIntValue);
		case .Float:     return .Float(mFloatValue);
		case .Bool:      return .Bool(mBoolValue);
		case .OffsetDateTime: return .OffsetDateTime(mOffsetDateTimeValue);
		case .LocalDateTime:  return .LocalDateTime(mLocalDateTimeValue);
		case .LocalDate:      return .LocalDate(mLocalDateValue);
		case .LocalTime:      return .LocalTime(mLocalTimeValue);
		default:
			Runtime.FatalError("Invalid TomlInputValue");
		}
	}

	public static implicit operator TomlInputValue(StringView value)
	{
		return TomlInputValue() { mKind = .String, mStringValue = value };
	}

	public static implicit operator TomlInputValue(int64 value)
	{
		return TomlInputValue() { mKind = .Integer, mIntValue = value };
	}

	public static implicit operator TomlInputValue(double value)
	{
		return TomlInputValue() { mKind = .Float, mFloatValue = value };
	}

	public static implicit operator TomlInputValue(bool value)
	{
		return TomlInputValue() { mKind = .Bool, mBoolValue = value };
	}

	public static implicit operator TomlInputValue(TomlOffsetDateTime value)
	{
		return TomlInputValue() { mKind = .OffsetDateTime, mOffsetDateTimeValue = value };
	}

	public static implicit operator TomlInputValue(TomlLocalDateTime value)
	{
		return TomlInputValue() { mKind = .LocalDateTime, mLocalDateTimeValue = value };
	}

	public static implicit operator TomlInputValue(TomlLocalDate value)
	{
		return TomlInputValue() { mKind = .LocalDate, mLocalDateValue = value };
	}

	public static implicit operator TomlInputValue(TomlLocalTime value)
	{
		return TomlInputValue() { mKind = .LocalTime, mLocalTimeValue = value };
	}
}

/// Represents a TOML array, owning a list of TomlValue items.
public class TomlArray
{
	private List<TomlValue> mItems;
	private bool mIsStatic; // true for arrays defined inline ([]), false for [[array]] created
	private TomlContainerMetadataContext mMetadataContext ~ delete _;
	internal bool mSuppressAutoDirty; // set by parser to suppress dirty marking during parse
	/// @brief The owning document store.
	internal TomlDocumentStore mStore;
	/// @brief Set by parser after detecting a trailing comma before the closing bracket.
	internal bool mHasTrailingComma;

	public ~this()
	{
		if (mItems != null)
			delete mItems;
	}

	/// @brief Whether this array is a static inline array (true) or a dynamic array-of-tables (false).
	public bool IsStatic
	{
		get => mIsStatic;
		set => mIsStatic = value;
	}

	/// @brief Metadata context for style-preserving mode. Null in normal mode.
	internal TomlContainerMetadataContext MetadataContext
	{
		get => mMetadataContext;
		set => mMetadataContext = value;
	}

	internal this()
	{
		Init(0, false);
	}

	internal this(bool suppressAutoDirty)
	{
		Init(0, suppressAutoDirty);
	}

	internal this(int capacity)
	{
		Init(capacity, false);
	}

	internal this(int capacity, bool suppressAutoDirty)
	{
		Init(capacity, suppressAutoDirty);
	}

	private void Init(int capacity, bool suppressAutoDirty)
	{
		mItems = capacity > 0 ? new List<TomlValue>(capacity) : new List<TomlValue>();
		mIsStatic = false;
		mMetadataContext = null;
		mSuppressAutoDirty = suppressAutoDirty;
	}

	internal void Add(TomlValue value)
	{
		mItems.Add(value);

		// Auto node-ID allocation when metadata context exists.
		// During parsing, mSuppressAutoDirty is set to keep entries clean.
		if (mMetadataContext != null && mMetadataContext.mMetadata != null)
		{
			let nodeId = mMetadataContext.mMetadata.AllocateNodeId();
			mMetadataContext.AddItemNodeId(nodeId);
			if (!mSuppressAutoDirty)
				MarkChildrenDirty();
			BindContainerMetadata(value);
		}
	}

	/// @brief Append a string value to the array. Uses the store if store-backed.
	/// @param value The string value.
	public void AddString(StringView value)
	{
		Add(.String(mStore.NewString(value)));
	}

	/// @brief Append an integer value to the array.
	/// @param value The integer value.
	public void AddInteger(int64 value)
	{
		Add(.Integer(value));
	}

	/// @brief Append a float value to the array.
	/// @param value The float value.
	public void AddFloat(double value)
	{
		Add(.Float(value));
	}

	/// @brief Append a boolean value to the array.
	/// @param value The boolean value.
	public void AddBool(bool value)
	{
		Add(.Bool(value));
	}

	/// @brief Append an offset date-time value to the array.
	/// @param value The offset date-time value.
	public void AddOffsetDateTime(TomlOffsetDateTime value)
	{
		Add(.OffsetDateTime(value));
	}

	/// @brief Append a local date-time value to the array.
	/// @param value The local date-time value.
	public void AddLocalDateTime(TomlLocalDateTime value)
	{
		Add(.LocalDateTime(value));
	}

	/// @brief Append a local date value to the array.
	/// @param value The local date value.
	public void AddLocalDate(TomlLocalDate value)
	{
		Add(.LocalDate(value));
	}

	/// @brief Append a local time value to the array.
	/// @param value The local time value.
	public void AddLocalTime(TomlLocalTime value)
	{
		Add(.LocalTime(value));
	}

	/// @brief Append a new store-backed sub-table to the array and return it.
	/// @return The new sub-table.
	public TomlTable AddTable()
	{
		TomlTable tbl = mStore.NewTable(.ArrayElement);
		Add(.Table(tbl));
		return tbl;
	}

	/// @brief Append a new store-backed sub-array to the array and return it.
	/// @return The new sub-array.
	public TomlArray AddArray()
	{
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		Add(.Array(arr));
		return arr;
	}

	/// @brief Append a scalar value via implicit conversion (e.g., `arr.Add("hello")`, `arr.Add(42)`).
	/// @param value The value to append.
	public void Add(TomlInputValue value)
	{
		var slot = value;
		if (!slot.IsValid)
			Runtime.FatalError("Invalid TomlInputValue — use a valid scalar");
		TomlValue stored = (mStore != null)
			? slot.Materialize(mStore)
			: slot.Materialize(null);
		Add(stored);
	}

	/// @brief Replace the element at `index` with a new store-backed table and return it.
	/// @param index The element index.
	/// @return The new table.
	public TomlTable SetTable(int index)
	{
		TomlTable tbl = mStore.NewTable(.ArrayElement);
		TomlValue val = .Table(tbl);
		mItems[index] = val;
		MarkItemDirty(index);
		BindContainerMetadata(val);
		return tbl;
	}

	/// @brief Replace the element at `index` with a new store-backed array and return it.
	/// @param index The element index.
	/// @return The new array.
	public TomlArray SetArray(int index)
	{
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		TomlValue val = .Array(arr);
		mItems[index] = val;
		MarkItemDirty(index);
		BindContainerMetadata(val);
		return arr;
	}

	/// @brief Remove the element at the given index.
	/// @param index The element index to remove.
	public void RemoveAt(int index)
	{
		mItems.RemoveAt(index);
		if (mMetadataContext != null)
			mMetadataContext.RemoveItemNodeId(index);
		MarkChildrenDirty();
	}

	/// @brief Remove all elements from the array.
	public void Clear()
	{
		mItems.Clear();
		if (mMetadataContext != null)
			mMetadataContext.ClearItemNodeIds();
		MarkChildrenDirty();
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

	public int Count => mItems.Count;

	/// @brief Get the value at the given index. Internal — use typed TryGet* methods for safe reading.
	internal TomlValue GetValue(int index)
	{
		return mItems[index];
	}

	/// @brief Read a String value at the given index.
	/// @param index The element index.
	/// @param value On success, the string value.
	/// @return True if the element is a String.
	public bool TryGetString(int index, out StringView value)
	{
		if (mItems[index].TryGetString(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read an Integer value at the given index.
	/// @param index The element index.
	/// @param value On success, the integer value.
	/// @return True if the element is an Integer.
	public bool TryGetInteger(int index, out int64 value)
	{
		if (mItems[index].TryGetInteger(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a Float value at the given index.
	/// @param index The element index.
	/// @param value On success, the float value.
	/// @return True if the element is a Float.
	public bool TryGetFloat(int index, out double value)
	{
		if (mItems[index].TryGetFloat(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a Bool value at the given index.
	/// @param index The element index.
	/// @param value On success, the boolean value.
	/// @return True if the element is a Bool.
	public bool TryGetBool(int index, out bool value)
	{
		if (mItems[index].TryGetBool(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read an OffsetDateTime value at the given index.
	/// @param index The element index.
	/// @param value On success, the offset date-time value.
	/// @return True if the element is an OffsetDateTime.
	public bool TryGetOffsetDateTime(int index, out TomlOffsetDateTime value)
	{
		if (mItems[index].TryGetOffsetDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a LocalDateTime value at the given index.
	/// @param index The element index.
	/// @param value On success, the local date-time value.
	/// @return True if the element is a LocalDateTime.
	public bool TryGetLocalDateTime(int index, out TomlLocalDateTime value)
	{
		if (mItems[index].TryGetLocalDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a LocalDate value at the given index.
	/// @param index The element index.
	/// @param value On success, the local date value.
	/// @return True if the element is a LocalDate.
	public bool TryGetLocalDate(int index, out TomlLocalDate value)
	{
		if (mItems[index].TryGetLocalDate(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a LocalTime value at the given index.
	/// @param index The element index.
	/// @param value On success, the local time value.
	/// @return True if the element is a LocalTime.
	public bool TryGetLocalTime(int index, out TomlLocalTime value)
	{
		if (mItems[index].TryGetLocalTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read a Table reference at the given index.
	/// @param index The element index.
	/// @param value On success, the table reference.
	/// @return True if the element is a Table.
	public bool TryGetTable(int index, out TomlTable value)
	{
		if (mItems[index].TryGetTable(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Read an Array reference at the given index.
	/// @param index The element index.
	/// @param value On success, the array reference.
	/// @return True if the element is an Array.
	public bool TryGetArray(int index, out TomlArray value)
	{
		if (mItems[index].TryGetArray(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Assign a scalar value at the given index. Accepts strings, integers, floats, bools,
	/// and date/time types via implicit conversion.
	/// @param index The element index.
	/// @param value The value to assign.
	public TomlInputValue this[int index]
	{
		internal get
		{
			Runtime.FatalError("Internal: use GetValue(int) or typed TryGet* methods for reading");
		}
		set
		{
			var slot = value;
			if (!slot.IsValid)
				Runtime.FatalError("Invalid TomlInputValue — use a valid scalar");
			TomlValue stored = (mStore != null)
				? slot.Materialize(mStore)
				: slot.Materialize(null);
			mItems[index] = stored;
			MarkItemDirty(index);
			BindContainerMetadata(stored);
		}
	}

	/// @brief Deep-copy this array and its elements into the given store.
	/// @param store The store to allocate into.
	/// @return A store-owned copy.
	internal TomlArray CloneInto(TomlDocumentStore store)
	{
		TomlArray result = store.NewArray(mItems.Count);
		result.mIsStatic = mIsStatic;
		for (int i = 0; i < mItems.Count; i++)
			result.Add(mItems[i].CloneInto(store));
		return result;
	}



	// ================================================================
	// Dirty tracking helpers
	// ================================================================

	/// Recursively clear metadata contexts from this array and all descendant tables/arrays.
	public void ClearMetadataContexts()
	{
		if (mMetadataContext != null)
		{
			delete mMetadataContext;
			mMetadataContext = null;
		}
		for (int i = 0; i < mItems.Count; i++)
		{
			switch (mItems[i])
			{
			case .Array(let arr):
				if (arr != null) arr.ClearMetadataContexts();
			case .Table(let tbl):
				if (tbl != null) tbl.ClearMetadataContexts();
			default:
			}
		}
	}

	/// Recursively re-enable automatic dirty tracking after parser construction completes.
	internal void ClearAutoDirtySuppression()
	{
		mSuppressAutoDirty = false;
		for (int i = 0; i < mItems.Count; i++)
		{
			switch (mItems[i])
			{
			case .Array(let arr):
				if (arr != null) arr.ClearAutoDirtySuppression();
			case .Table(let tbl):
				if (tbl != null) tbl.ClearAutoDirtySuppression();
			default:
			}
		}
	}

	/// Mark a specific array element as dirty in the metadata context.
	internal void MarkItemDirty(int index)
	{
		if (mMetadataContext != null && mMetadataContext.mMetadata != null)
		{
			if (mMetadataContext.TryGetItemNodeId(index, let nodeId) && nodeId.IsValid)
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
