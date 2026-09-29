using System;
using internal TomlBeef;

namespace TomlBeef;

/// One table entry: its key (bytes owned by the document store), value and metadata node ID.
internal struct TomlTableSlot
{
	public StringView mKey;
	public TomlValue mValue;
	public TomlNodeId mNodeId;
}

/// A table's entries in insertion order, with a hash index once the table outgrows a short scan.
///
/// Entries live in one array in insertion order, so walking a table (the writer, GetValueAt) never
/// hashes. Up to LinearLimit entries a lookup compares keys directly: no hashing and no index to
/// allocate, which is most tables. Past that, an open-addressing index maps hashes to entry
/// positions: a power-of-two table probed linearly, at most half full, each slot holding the entry
/// position and its key's full hash so a probe only reads a key whose hash matches. Removing or
/// renaming an entry rebuilds the index (both are rare, and removal shifts positions anyway).
internal struct TomlEntryMap : IDisposable
{
	/// Largest table searched by comparing keys directly.
	const int32 LinearLimit = 8;

	struct IndexSlot
	{
		/// Entry position + 1; 0 marks an empty slot.
		public int32 mEntry;
		public uint32 mHash;
	}

	TomlTableSlot* mSlots;
	int32 mCount;
	int32 mCapacity;
	/// Null while the table is small enough to scan.
	IndexSlot* mIndex;
	int32 mIndexMask;

	public int Count => mCount;

	public ref TomlTableSlot this[int index]
	{
		[Inline]
		get
		{
			// Checked in Release too: public GetKeyAt/GetValueAt reach here with caller indices
			Runtime.Assert((uint)index < (uint)mCount);
			return ref mSlots[index];
		}
	}

	public void Dispose() mut
	{
		delete mSlots;
		delete mIndex;
		this = default;
	}

	/// @brief Remove every entry, keeping the allocated space.
	public void Clear() mut
	{
		mCount = 0;
		if (mIndex != null)
			Internal.MemSet(mIndex, 0, (mIndexMask + 1) * sizeof(IndexSlot));
	}

	/// @brief Find an entry by key.
	/// @param key The key.
	/// @return The entry's position, or -1 if the key is missing.
	public int IndexOf(StringView key)
	{
		if (mIndex == null)
			return ScanFor(key);
		uint32 hash = Hash(key);
		int32 pos = (int32)hash & mIndexMask;
		while (true)
		{
			let slot = mIndex[pos];
			if (slot.mEntry == 0)
				return -1;
			if (slot.mHash == hash && KeyEquals(mSlots[slot.mEntry - 1].mKey, key))
				return slot.mEntry - 1;
			pos = (pos + 1) & mIndexMask;
		}
	}

	/// @brief Find an entry by key, or append a new one with one lookup. A new entry's key refers to the
	/// caller's `key` until the caller stores its own copy in the slot.
	/// @param key The key.
	/// @param added Set to true if the entry is new.
	/// @return The entry's position.
	public int FindOrAdd(StringView key, out bool added) mut
	{
		added = false;
		if (mIndex == null)
		{
			let found = ScanFor(key);
			if (found >= 0)
				return found;
			added = true;
			let index = Append(key);
			if (mCount > LinearLimit)
				RebuildIndex();
			return index;
		}

		// Keep the index at most half full, so probes stay short and always reach an empty slot
		if ((mCount + 1) * 2 > mIndexMask + 1)
			GrowIndex();
		uint32 hash = Hash(key);
		int32 pos = (int32)hash & mIndexMask;
		while (true)
		{
			let slot = mIndex[pos];
			if (slot.mEntry == 0)
				break;
			if (slot.mHash == hash && KeyEquals(mSlots[slot.mEntry - 1].mKey, key))
				return slot.mEntry - 1;
			pos = (pos + 1) & mIndexMask;
		}
		added = true;
		let index = Append(key);
		mIndex[pos] = .() { mEntry = (int32)index + 1, mHash = hash };
		return index;
	}

	/// @brief Remove the entry at `index`, keeping the order of the rest.
	/// @param index The entry position.
	public void RemoveAt(int index) mut
	{
		Runtime.Assert((uint)index < (uint)mCount);
		let after = mCount - index - 1;
		if (after > 0)
			Internal.MemMove(&mSlots[index], &mSlots[index + 1], after * sizeof(TomlTableSlot));
		mCount--;
		if (mIndex != null)
			RebuildIndex();
	}

	/// @brief Change the key of the entry at `index`. The caller has checked that `key` is not in use.
	/// @param index The entry position.
	/// @param key The new key; the slot keeps this view, so it must be owned by the document.
	public void SetKeyAt(int index, StringView key) mut
	{
		this[index].mKey = key;
		if (mIndex != null)
			RebuildIndex();
	}

	int ScanFor(StringView key)
	{
		for (int i = 0; i < mCount; i++)
		{
			if (KeyEquals(mSlots[i].mKey, key))
				return i;
		}
		return -1;
	}

	int Append(StringView key) mut
	{
		if (mCount == mCapacity)
		{
			let capacity = Math.Max(mCapacity * 2, 4);
			let slots = new TomlTableSlot[capacity]*;
			if (mCount > 0)
				Internal.MemCpy(slots, mSlots, mCount * sizeof(TomlTableSlot));
			delete mSlots;
			mSlots = slots;
			mCapacity = capacity;
		}
		mSlots[mCount] = .() { mKey = key };
		return mCount++;
	}

	/// Doubles the index, moving each slot by its stored hash (no key is read or hashed again).
	void GrowIndex() mut
	{
		let old = mIndex;
		let oldSize = mIndexMask + 1;
		AllocateIndex(oldSize * 2);
		for (int i = 0; i < oldSize; i++)
		{
			if (old[i].mEntry != 0)
				Place(old[i]);
		}
		delete old;
	}

	/// Indexes every entry from scratch, sized for the current count.
	void RebuildIndex() mut
	{
		if (mCount <= LinearLimit)
		{
			// Small again (after removals): back to scanning
			delete mIndex;
			mIndex = null;
			mIndexMask = 0;
			return;
		}
		int32 size = 16;
		while (size < mCount * 2)
			size *= 2;
		if (mIndex == null || mIndexMask + 1 != size)
		{
			delete mIndex;
			AllocateIndex(size);
		}
		else
			Internal.MemSet(mIndex, 0, size * sizeof(IndexSlot));
		for (int32 i = 0; i < mCount; i++)
			Place(.() { mEntry = i + 1, mHash = Hash(mSlots[i].mKey) });
	}

	void AllocateIndex(int32 size) mut
	{
		mIndex = new IndexSlot[size]*;
		Internal.MemSet(mIndex, 0, size * sizeof(IndexSlot));
		mIndexMask = size - 1;
	}

	void Place(IndexSlot slot)
	{
		int32 pos = (int32)slot.mHash & mIndexMask;
		while (mIndex[pos].mEntry != 0)
			pos = (pos + 1) & mIndexMask;
		mIndex[pos] = slot;
	}

	[Inline]
	static bool KeyEquals(StringView a, StringView b)
	{
		return a.Length == b.Length && (a.Length == 0 || (a[0] == b[0] && Internal.MemCmp(a.Ptr, b.Ptr, a.Length) == 0));
	}

	/// Hashes a key a word at a time: short keys (most TOML keys) take one or two overlapping loads
	/// that stay inside the key, longer ones 8 bytes per step, and a splitmix64 finalizer spreads every
	/// input bit over the result so masking off low bits for the index is safe.
	static uint32 Hash(StringView key)
	{
		char8* ptr = key.Ptr;
		int length = key.Length;
		uint64 h = (uint64)length &* 0x9E3779B97F4A7C15;
		if (length >= 8)
		{
			for (int i = 0; i + 8 < length; i += 8)
			{
				h = (h ^ *(uint64*)(ptr + i)) &* 0xBF58476D1CE4E5B9;
				h = (h << 31) | (h >> 33);
			}
			// The last 8 bytes, overlapping the previous word when the length is not a multiple of 8
			h ^= *(uint64*)(ptr + length - 8);
		}
		else if (length >= 4)
			h ^= ((uint64)*(uint32*)ptr << 32) | *(uint32*)(ptr + length - 4);
		else if (length > 0)
			h ^= (uint64)(uint8)ptr[0] | ((uint64)(uint8)ptr[length / 2] << 8) | ((uint64)(uint8)ptr[length - 1] << 16);

		h ^= h >> 30;
		h &*= 0xBF58476D1CE4E5B9;
		h ^= h >> 27;
		h &*= 0x94D049BB133111EB;
		h ^= h >> 31;
		return (uint32)h;
	}
}
