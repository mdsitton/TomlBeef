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
}
