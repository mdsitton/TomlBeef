using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// Represents a TOML array, owning a list of TomlValue items.
public class TomlArray
{
	private List<TomlValue> mItems ~ DeleteContainerAndDisposeItems!(_);
	private bool mIsStatic; // true for arrays defined inline ([]), false for [[array]] created
	private TomlContainerMetadataContext mMetadataContext ~ delete _;
	internal bool mSuppressAutoDirty; // set by parser to suppress dirty marking during parse
	/// @brief Set by parser after detecting a trailing comma before the closing bracket.
	internal bool mHasTrailingComma;

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

	public this()
	{
		Init(0, false);
	}

	internal this(bool suppressAutoDirty)
	{
		Init(0, suppressAutoDirty);
	}

	public this(int capacity)
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

	public void Add(TomlValue value)
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

	public TomlValue this[int index]
	{
		get => mItems[index];
		set
		{
			mItems[index].Dispose();
			mItems[index] = value;
			MarkItemDirty(index);
			BindContainerMetadata(value);
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
