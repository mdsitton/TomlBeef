using System;
using TomlBeef;

namespace TomlBeef;

static class TomlReadTests
{
	[Test]
	public static void SmokeTest()
	{
		let input = "x = 42";
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(input) case .Err(let e))
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		else
			Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void ReadError_ReplaceLeavesDocumentBlank()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("old = 1") case .Err(let setupErr))
		{
			defer setupErr.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {setupErr.mMessage}");
		}

		if (doc.Read("a = 1\n?") case .Err(let err))
		{
			defer err.Dispose();
		}
		else
		{
			Test.Assert(false, "Expected parse error");
		}
		Test.Assert(doc.RootTable.Count == 0);
	}

	[Test]
	public static void ReadError_MergeLeavesDocumentUnchanged()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("a = 1") case .Err(let setupErr))
		{
			defer setupErr.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {setupErr.mMessage}");
		}

		if (doc.Read("a = 2", .() { Mode = .Merge }) case .Err(let err))
		{
			defer err.Dispose();
		}
		else
		{
			Test.Assert(false, "Expected merge conflict");
		}
		Test.Assert(doc.RootTable.Count == 1);
		Test.Assert(doc.TryGetInteger("a", var val));
		Test.Assert(val == 1);
	}
}
