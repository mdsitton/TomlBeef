using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// @brief Owns all heap-backed TOML payloads for a document using a BumpAllocator arena.
/// Strings, tables, and arrays are allocated in the arena and released together
/// when the store is reset or destroyed.
internal class TomlDocumentStore
{
	/// A BumpAllocator that takes its pools from, and returns them to, a cache the store keeps across
	/// resets. Reading into a document again then reuses the previous document's memory: freeing it
	/// instead lets glibc trim the heap, and the next parse page-faults every page back in (up to 40%
	/// of parse time on large inputs). The cache holds at most the pools of the largest document read.
	class PoolRecyclingAllocator : BumpAllocator
	{
		List<Span<uint8>> mCache;

		public this(List<Span<uint8>> cache) : base(.Allow)
		{
			mCache = cache;
		}

		protected override Span<uint8> AllocPool()
		{
			if (!mCache.IsEmpty)
				return mCache.PopBack();
			return base.AllocPool();
		}

		protected override void FreePool(Span<uint8> span)
		{
			mCache.Add(span);
		}
	}

	private List<Span<uint8>> mPoolCache = new .();
	private BumpAllocator mAlloc;
	private TomlTable mRootTable;
	/// @brief Set while the parser fills this store: containers and entries it creates start clean
	/// instead of being marked dirty. One flag for the whole store, so ending a parse needs no tree walk.
	internal bool mSuppressAutoDirty;

	public this()
	{
		mAlloc = new PoolRecyclingAllocator(mPoolCache);
		mRootTable = NewTable(.Root);
	}

	public ~this()
	{
		// The allocator returns its pools to the cache as it goes
		delete mAlloc;
		for (let pool in mPoolCache)
			delete pool.Ptr;
		delete mPoolCache;
	}

	/// @brief The store-owned root table. Borrowed reference — do not delete.
	internal TomlTable RootTable => mRootTable;

	/// @brief Copy a string value's text into the store arena as plain bytes, as NewKey does: no String
	/// object, and the value stays read-only.
	/// @param source The string data to copy.
	/// @return A view of the store-owned copy.
	internal StringView NewString(StringView source)
	{
		return NewKey(source);
	}

	/// @brief Copy a table key into the store arena as plain bytes (no String object or destructor).
	/// @param key The key to copy.
	/// @return A view of the store-owned copy.
	internal StringView NewKey(StringView key)
	{
		if (key.IsEmpty)
			return "";
		let bytes = (char8*)mAlloc.Alloc(key.Length, 1);
		Internal.MemCpy(bytes, key.Ptr, key.Length);
		return .(bytes, key.Length);
	}

	/// @brief Allocate a TomlTable in the store arena, bound to this store.
	/// @param origin The table origin for conflict detection.
	/// @return A store-owned TomlTable with mStore set to this store.
	internal TomlTable NewTable(TomlTableOrigin origin)
	{
		let tbl = new:mAlloc TomlTable(origin);
		tbl.mStore = this;
		return tbl;
	}

	/// @brief Allocate a TomlArray in the store arena, bound to this store.
	/// @return A store-owned TomlArray with mStore set to this store.
	internal TomlArray NewArray()
	{
		let arr = new:mAlloc TomlArray();
		arr.mStore = this;
		return arr;
	}

	/// @brief Allocate a TomlArray with capacity in the store arena, bound to this store.
	/// @param capacity Initial capacity hint.
	/// @return A store-owned TomlArray with mStore set to this store.
	internal TomlArray NewArray(int capacity)
	{
		let arr = new:mAlloc TomlArray(capacity);
		arr.mStore = this;
		return arr;
	}

	/// @brief Free the cached pools (memory of content already reset away). Pools in use stay, so
	/// current payloads and views into them are unaffected.
	internal void ReleasePoolCache()
	{
		for (let pool in mPoolCache)
			delete pool.Ptr;
		mPoolCache.Clear();
	}

	/// @brief Number of cached pools (for tests).
	internal int CachedPoolCount => mPoolCache.Count;

	/// @brief Reset the store, releasing all arena-allocated payloads and creating a new root table.
	internal void Reset()
	{
		delete mAlloc;
		mAlloc = new PoolRecyclingAllocator(mPoolCache);
		mRootTable = NewTable(.Root);
		// A parse that failed (and cleared the document) must not leave suppression on
		mSuppressAutoDirty = false;
	}
}
