using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// @brief Owns all heap-backed TOML payloads for a document using a BumpAllocator arena.
/// Strings, tables, and arrays are allocated in the arena and released together
/// when the store is reset or destroyed.
internal class TomlDocumentStore
{
	private BumpAllocator mAlloc ~ delete _;
	private TomlTable mRootTable;
	/// @brief Set while the parser fills this store: containers and entries it creates start clean
	/// instead of being marked dirty. One flag for the whole store, so ending a parse needs no tree walk.
	internal bool mSuppressAutoDirty;

	public this()
	{
		mAlloc = new BumpAllocator(.Allow);
		mRootTable = NewTable(.Root);
	}

	/// @brief The store-owned root table. Borrowed reference — do not delete.
	internal TomlTable RootTable => mRootTable;

	/// @brief Allocate a String in the store arena, copying from source.
	/// @param source The string data to copy.
	/// @return A store-owned String.
	internal String NewString(StringView source)
	{
		return new:mAlloc String(source);
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

	/// @brief Reset the store, releasing all arena-allocated payloads and creating a new root table.
	internal void Reset()
	{
		delete mAlloc;
		mAlloc = new BumpAllocator(.Allow);
		mRootTable = NewTable(.Root);
		// A parse that failed (and cleared the document) must not leave suppression on
		mSuppressAutoDirty = false;
	}
}
