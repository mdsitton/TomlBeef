using System;

namespace TomlBeef;

/// The root of a parsed TOML document.
/// Owns the complete value tree; disposal of the document cleans up everything.
public class TomlDocument
{
	public TomlTable mRootTable;

	public this()
	{
		mRootTable = new TomlTable(.Root);
	}

	public ~this()
	{
		if (mRootTable != null)
			delete mRootTable;
	}

	public Result<TomlValue> Get(StringView dottedPath)
	{
		TomlTable current = mRootTable;
		int start = 0;
		for (int i = 0; i <= dottedPath.Length; i++)
		{
			if (i == dottedPath.Length || dottedPath[i] == '.')
			{
				StringView segment = dottedPath.Substring(start, i - start);
				if (segment.IsEmpty)
					return .Err;
				if (i == dottedPath.Length)
				{
					// Final segment — return the value
					if (current.TryGetValue(segment, let val))
						return val;
					return .Err;
				}
				// Intermediate segment — must be a table
				if (!current.TryGetValue(segment, let val) || !val.IsTable)
					return .Err;
				current = val.AsTable;
				start = i + 1;
			}
		}
		return .Err;
	}
}
