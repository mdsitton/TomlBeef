using System;
using System.Collections;

namespace TomlBeef;

/// Represents a TOML array, owning a list of TomlValue items.
public class TomlArray
{
	private List<TomlValue> mItems ~ DeleteContainerAndDisposeItems!(_);
	private bool mIsStatic; // true for arrays defined inline ([]), false for [[array]] created
	private TomlContainerMetadataContext mMetadataContext ~ delete _;

	/// @brief Whether this array is a static inline array (true) or a dynamic array-of-tables (false).
	public bool IsStatic
	{
		get => mIsStatic;
		set => mIsStatic = value;
	}

	/// @brief Metadata context for style-preserving mode. Null in normal mode.
	public TomlContainerMetadataContext MetadataContext
	{
		get => mMetadataContext;
		set => mMetadataContext = value;
	}

	public this()
	{
		mItems = new List<TomlValue>();
		mIsStatic = false;
		mMetadataContext = null;
	}

	public this(int capacity)
	{
		mItems = new List<TomlValue>(capacity);
		mIsStatic = false;
		mMetadataContext = null;
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
			MarkItemDirty(index);
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

	/// Mark a specific array element as dirty in the metadata context.
	private void MarkItemDirty(int index)
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
}
