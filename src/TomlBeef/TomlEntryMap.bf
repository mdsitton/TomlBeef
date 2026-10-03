using System;
using FormatCore;
using internal FormatCore;
using internal TomlBeef;

namespace TomlBeef;

/// One table entry: its key (bytes owned by the document store), value and metadata node ID.
internal struct TomlTableSlot : IKeyedSlot
{
	public StringView mKey;
	public TomlValue mValue;
	public TomlNodeId mNodeId;

	public StringView Key
	{
		[Inline]
		get => mKey;
		[Inline]
		set mut => mKey = value;
	}
}

/// A table's entries in insertion order, with a hash index once the table outgrows a short scan of 8
/// entries: FormatCore's OrderedMap (this file's former TomlEntryMap, generalized there). Walking a
/// table never hashes; past the scan limit an open-addressing index maps keys to positions, seeded per
/// map (FormatCore ByteHash), so keys crafted to collide cannot be prepared in advance (the former map
/// hashed unseeded: hash flooding on untrusted input).
internal typealias TomlEntryMap = OrderedMap<TomlTableSlot, const 8>;
