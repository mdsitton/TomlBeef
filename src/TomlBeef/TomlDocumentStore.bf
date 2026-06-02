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
	/// @param suppressAutoDirty Whether to suppress dirty marking during parse.
	/// @return A store-owned TomlTable with mStore set to this store.
	internal TomlTable NewTable(TomlTableOrigin origin, bool suppressAutoDirty = false)
	{
		let tbl = new:mAlloc TomlTable(origin, suppressAutoDirty);
		tbl.mStore = this;
		return tbl;
	}

	/// @brief Allocate a TomlArray in the store arena, bound to this store.
	/// @param suppressAutoDirty Whether to suppress dirty marking during parse.
	/// @return A store-owned TomlArray with mStore set to this store.
	internal TomlArray NewArray(bool suppressAutoDirty = false)
	{
		let arr = new:mAlloc TomlArray(suppressAutoDirty);
		arr.mStore = this;
		return arr;
	}

	/// @brief Allocate a TomlArray with capacity in the store arena, bound to this store.
	/// @param capacity Initial capacity hint.
	/// @param suppressAutoDirty Whether to suppress dirty marking during parse.
	/// @return A store-owned TomlArray with mStore set to this store.
	internal TomlArray NewArray(int capacity, bool suppressAutoDirty = false)
	{
		let arr = new:mAlloc TomlArray(capacity, suppressAutoDirty);
		arr.mStore = this;
		return arr;
	}

	/// @brief Reset the store, releasing all arena-allocated payloads and creating a new root table.
	internal void Reset()
	{
		delete mAlloc;
		mAlloc = new BumpAllocator(.Allow);
		mRootTable = NewTable(.Root);
	}
}
