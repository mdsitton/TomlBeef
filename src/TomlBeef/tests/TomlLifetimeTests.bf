using System;
using TomlBeef;

namespace TomlBeef;

/// Document-owned storage lifetime: clearing, reuse, and values that outlive their table entry.
static class TomlLifetimeTests
{
	static void ReadOrFail(TomlDocument doc, StringView input, TomlReadConfig config = .())
	{
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed for '{input}': {e.mMessage}");
		}
	}

	[Test]
	public static void Clear_ThenReparse()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = \"one\"\n[t]\nx = [1, 2]");
		doc.Clear();
		Test.Assert(doc.RootTable.Count == 0);
		Test.Assert(!doc.TryGetString("a", ?));

		ReadOrFail(doc, "b = \"two\"\n[[p]]\nn = 1");
		Test.Assert(doc.RootTable.Count == 2);
		Test.Assert(doc.TryGetString("b", var b) && b == "two");
		Test.Assert(doc.TryGetArray("p", var p) && p.Count == 1);
	}

	[Test]
	public static void Clear_ThenBuildProgrammatically()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = 1");
		doc.Clear();
		let t = doc.AddTable("t");
		t.SetString("k", "v");
		doc.AddArray("arr").Add(5);
		String output = scope String();
		doc.Write(output);

		var reparsed = scope TomlDocument();
		ReadOrFail(reparsed, output);
		Test.Assert(reparsed.TryGetString("t.k", var k) && k == "v");
		Test.Assert(reparsed.TryGetArray("arr", var arr) && arr.Count == 1);
		Test.Assert(!reparsed.TryGetInteger("a", ?));
	}

	[Test]
	public static void RepeatedParseAndClearCycles()
	{
		var doc = scope TomlDocument();
		for (int i < 200)
		{
			let input = scope $"i = {i}\ns = \"value {i}\"\n[t]\narr = [{i}, {i + 1}]";
			ReadOrFail(doc, input);
			Test.Assert(doc.TryGetInteger("i", var n) && n == i);
			Test.Assert(doc.TryGetString("s", var s) && s == scope $"value {i}");
			if (i % 2 == 0)
				doc.Clear();
		}
		Test.Assert(doc.RootTable.Count == 3);
	}

	[Test]
	public static void RepeatedMergeCycles()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "base = true");
		for (int i < 100)
		{
			let input = scope $"counter = {i}\nlabel = \"iteration {i}\"\nkey{i} = {i}";
			ReadOrFail(doc, input, .() { Mode = .Merge, OnConflict = .Overwrite });
		}
		Test.Assert(doc.TryGetBool("base", var b) && b);
		Test.Assert(doc.TryGetInteger("counter", var c) && c == 99);
		Test.Assert(doc.TryGetString("label", var label) && label == "iteration 99");
		Test.Assert(doc.TryGetInteger("key0", var k0) && k0 == 0);
		Test.Assert(doc.RootTable.Count == 103);
	}

	[Test]
	public static void ReplacedAndRemovedStringsStayReadableUntilClear()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = \"original\"\nb = \"removed\"");
		Test.Assert(doc.TryGetString("a", var oldA));
		Test.Assert(doc.TryGetString("b", var oldB));

		doc.RootTable.SetString("a", "replacement");
		Test.Assert(doc.RootTable.Remove("b"));

		// Payloads stay in the document arena, so earlier borrowed views remain valid
		Test.Assert(oldA == "original");
		Test.Assert(oldB == "removed");
		Test.Assert(doc.TryGetString("a", var newA) && newA == "replacement");
		Test.Assert(!doc.TryGetString("b", ?));
	}

	[Test]
	public static void RemovedTableStaysReadableUntilClear()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "[t]\nname = \"inner\"\nlist = [1, 2, 3]");
		Test.Assert(doc.TryGetTable("t", var t));
		Test.Assert(doc.Remove("t"));
		Test.Assert(!doc.TryGetTable("t", ?));
		Test.Assert(t.TryGetString("name", var name) && name == "inner");
		Test.Assert(t.TryGetArray("list", var list) && list.Count == 3);
	}

	[Test]
	public static void MergeFromCopiesSoSourceCanBeDeleted()
	{
		var dest = scope TomlDocument();
		ReadOrFail(dest, "existing = 1");

		var source = new TomlDocument();
		ReadOrFail(source, "s = \"copied\"\narr = [\"x\", \"y\"]\n[t]\nnested = { k = \"deep\" }\n[[aot]]\nn = 1");
		if (dest.RootTable.MergeFrom(source.RootTable) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"MergeFrom failed: {e.mMessage}");
		}
		delete source;

		Test.Assert(dest.TryGetInteger("existing", var existing) && existing == 1);
		Test.Assert(dest.TryGetString("s", var s) && s == "copied");
		Test.Assert(dest.TryGetArray("arr", var arr) && arr.Count == 2);
		Test.Assert(arr.TryGetString(1, var y) && y == "y");
		Test.Assert(dest.TryGetString("t.nested.k", var deep) && deep == "deep");
		Test.Assert(dest.TryGetArray("aot", var aot) && aot.Count == 1);

		// The merged copy must also serialize and reparse
		String output = scope String();
		dest.Write(output);
		var reparsed = scope TomlDocument();
		ReadOrFail(reparsed, output);
		Test.Assert(reparsed.TryGetString("t.nested.k", var deep2) && deep2 == "deep");
	}
}
