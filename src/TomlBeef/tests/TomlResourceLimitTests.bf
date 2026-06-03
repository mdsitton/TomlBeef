using System;
using System.Collections;
using System.IO;
using TomlBeef;

namespace TomlBeef;

static class TomlResourceLimitTests
{
	[Test]
	public static void ResourceLimit_MaxTableEntries_TopLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_NamedTable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("[t]\na = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_InlineTable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("t = { a = 1, b = 2 }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_DottedKey()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("a.b = 1\na.c = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_KeyVal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("a.b.c = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_TableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("[a.b.c]\nx = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_ArrayOfTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("[[a.b.c]]\nx = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxNodes_Scalars()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxNodes = 1 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxNodes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxInputBytes_StringView()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxInputBytes = 5 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxInputBytes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxArrayItems_StaticArray()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxArrayItems = 2 };
		switch (doc.Read("a = [1, 2, 3]", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxArrayItems limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxArrayItems_ArrayOfTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxArrayItems = 1 };
		switch (doc.Read("[[a]]\nx = 1\n[[a]]\nx = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxArrayItems limit for array-of-tables");
		}
	}

	[Test]
	public static void ResourceLimit_MaxStringBytes()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxStringBytes = 2 };
		switch (doc.Read("a = \"abc\"", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxStringBytes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxDepth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// Inline table inside inline table — 2 levels of value nesting
		var config = TomlReadConfig() { MaxDepth = 1 };
		switch (doc.Read("a = { b = { c = 1 } }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .MaxDepthExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxDepth limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxInputBytes_ReadBytes()
	{
		var doc = new TomlDocument();
		defer delete doc;
		String input = scope String("a = 1\nb = 2");
		var config = TomlReadConfig() { MaxInputBytes = 5 };
		switch (doc.ReadBytes(Span<uint8>((uint8*)input.Ptr, input.Length), config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxInputBytes limit for ReadBytes");
		}
	}

	[Test]
	public static void ResourceLimit_MaxNodes_InlineTableDotted()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// inline table a + implicit inline table b + scalar c — 3 nodes
		var config = TomlReadConfig() { MaxNodes = 2 };
		switch (doc.Read("a = { b.c = 1 }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxNodes limit for inline table dotted key");
		}
	}

	[Test]
	public static void ResourceLimit_StreamMergeLeavesDocumentUnchanged()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		String input = scope String("a = 1\nb = 2");
		List<uint8> bytes = scope List<uint8>();
		for (int i = 0; i < input.Length; i++)
			bytes.Add((uint8)input[i]);
		var stream = new MemoryStream(bytes, false);
		defer { delete stream; }
		var mergeConfig = TomlReadConfig() { Mode = .Merge, MaxInputBytes = 1 };
		if (doc.Read(stream, mergeConfig) case .Ok)
			Test.Assert(false, "Expected stream merge to fail");
		Test.Assert(doc.RootTable.Count == 1);
		Test.Assert(doc.TryGetInteger("existing", var val) && val == 1);
	}

	[Test]
	public static void ResourceLimit_StreamFailsWithResourceLimitExceeded()
	{
		var doc = new TomlDocument();
		defer delete doc;
		String input = scope String("a = 1\nb = 2");
		List<uint8> bytes = scope List<uint8>();
		for (int i = 0; i < input.Length; i++)
			bytes.Add((uint8)input[i]);
		var stream = new MemoryStream(bytes, false);
		defer { delete stream; }
		var config = TomlReadConfig() { MaxInputBytes = 3 };
		switch (doc.Read(stream, config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected ResourceLimitExceeded for stream");
		}
	}

	[Test]
	public static void ResourceLimit_ReplaceModeOversizedReadClearsDocument()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		Test.Assert(doc.RootTable.Count == 1);
		var config = TomlReadConfig() { MaxInputBytes = 1, Mode = .Replace };
		if (doc.Read("ab", config) case .Ok)
			Test.Assert(false, "Expected MaxInputBytes limit for replace-mode Read");
		Test.Assert(doc.RootTable.Count == 0);
	}

	[Test]
	public static void ResourceLimit_ReplaceModeOversizedReadBytesClearsDocument()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		Test.Assert(doc.RootTable.Count == 1);
		String input = scope String("ab");
		var config = TomlReadConfig() { MaxInputBytes = 1, Mode = .Replace };
		if (doc.ReadBytes(Span<uint8>((uint8*)input.Ptr, input.Length), config) case .Ok)
			Test.Assert(false, "Expected MaxInputBytes limit for replace-mode ReadBytes");
		Test.Assert(doc.RootTable.Count == 0);
	}
}

