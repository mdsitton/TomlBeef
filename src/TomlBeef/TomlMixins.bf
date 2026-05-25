using System;
using System.Collections;

namespace TomlBeef;

static
{
	/// Disposes each value in a dictionary via .Dispose(), deletes each key,
	/// and deletes the dictionary itself.
	public static mixin DeleteDictionaryAndKeysAndDisposeValues(var dict)
	{
		if (dict != null)
		{
			for (var entry in dict)
			{
				entry.value.Dispose();
				delete entry.key;
			}
			delete dict;
		}
	}
}
