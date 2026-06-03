using System;
using TomlBeef;

namespace TomlBeef;

static class TomlInlineTableSealTests
{
	[Test]
	public static void InlineTableSeal_DottedKeyChildNotExtendable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "type = { name.first = \"Nail\" }\ntype.name.last = \"bad\"";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table dotted-key child extended after close");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_DottedKeyChildNotExtendable2()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b.c = 1 }\na.b.d = 2";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table child extended");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_NestedInlineTableChildNotExtendable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b = { c = 1 } }\na.b.d = 2";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — nested inline table child extended");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_DottedKeyWithinInlineTableStillValid()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b.c = 1, b.d = 2 }";
		if (doc.Read(input) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Valid inline table with dotted keys should parse: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a.b.c", var c) && c == 1);
		Test.Assert(doc.TryGetInteger("a.b.d", var d) && d == 2);
	}

	[Test]
	public static void InlineTableSeal_NestedInlineTablesStillValid()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b = { c = 1, d = 2 } }";
		if (doc.Read(input) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Valid nested inline table should parse: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a.b.c", var c) && c == 1);
		Test.Assert(doc.TryGetInteger("a.b.d", var d) && d == 2);
	}

	[Test]
	public static void InlineTableSeal_HeaderExtensionOfDottedChildRejected()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "type = { name.first = \"Nail\" }\n\n[type.name]\nlast = \"bad\"";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table child extended via [header]");
		case .Err(let e):
			defer e.Dispose();
			// [header] redefines the inline table; caught as DuplicateTable before sealing check.
			Test.Assert(e.mKind == .DuplicateTable,
				scope $"Expected DuplicateTable, got {e.mKind}: {e.mMessage}");
		}
	}
}
