using System;
using TomlBeef;
using internal TomlBeef;

namespace TomlBeef;

/// Document-owned storage lifetime: clearing, reuse, and values that outlive their table entry.
static class TomlLifetimeTests
{
	static void ReadOrFail(TomlDocument doc, StringView input, TomlReadConfig config = .())
	{
		if (doc.Read(input, config) case .Err(let e))
		{
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
		t.Set("k", "v");
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

		doc.RootTable.Set("a", "replacement");
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
	public static void RemovedTableStaysUsableAcrossMerge()
	{
		// A table the caller removed earlier (and still holds) stays alive in the arena and keeps its
		// metadata context, so a merge must never free the sidecar out from under it.
		var doc = scope TomlDocument();
		ReadOrFail(doc, "[t]\nx = 1\n[u]\ny = 2", .() { MetadataMode = .PreserveStyle });
		let metadata = doc.Metadata;
		Test.Assert(doc.TryGetTable("t", var removed));
		Test.Assert(doc.Remove("t"));

		ReadOrFail(doc, "z = 3", .() { Mode = .Merge });
		Test.Assert(doc.Metadata === metadata, "A merge keeps the destination sidecar");

		// Mutating the detached table exercises its metadata context
		removed.Set("x", "changed");
		removed.Set("new", 4);
		Test.Assert(removed.Remove("new"));
		removed.Clear();
		Test.Assert(removed.Count == 0);

		// Reachable tables were detached from the metadata and keep working
		Test.Assert(doc.TryGetTable("u", var u));
		u.Set("y", 5);
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("y = 5") && output.Contains("z = 3"), scope $"Unexpected output:\n{output}");
	}

	[Test]
	public static void MergeIntoEmptyDocumentReusesSidecar()
	{
		// An empty PreserveStyle document takes the direct-parse path on Merge; it must reuse its
		// sidecar rather than replacing (and leaking) it while the root still references it.
		var doc = scope TomlDocument();
		ReadOrFail(doc, "", .() { MetadataMode = .PreserveStyle });
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		ReadOrFail(doc, "a = 0x10", .() { Mode = .Merge, MetadataMode = .PreserveStyle });
		Test.Assert(doc.Metadata === metadata);
		Test.Assert(doc.RootTable.MetadataContext.mMetadata === metadata);
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("a = 0x10"), scope $"Merged value lost its format:\n{output}");
	}

	[Test]
	public static void MergeFromCopiesASubtableIntoAnotherDocument()
	{
		var source = new TomlDocument();
		ReadOrFail(source, "[server]\nhost = \"a\"\nports = [80, 443]\n[server.tls]\ncert = \"c\"");
		var dest = scope TomlDocument();
		ReadOrFail(dest, "other = 1");
		Test.Assert(source.TryGetTable("server", var server));
		if (dest.AddTable("backup").MergeFrom(server) case .Err(let e))
		{
			Test.Assert(false, scope $"MergeFrom failed: {e.mMessage}");
		}
		delete source;

		Test.Assert(dest.TryGetString("backup.host", var host) && host == "a");
		Test.Assert(dest.TryGetArray("backup.ports", var ports) && ports.Count == 2);
		Test.Assert(dest.TryGetString("backup.tls.cert", var cert) && cert == "c");
		String output = scope String();
		dest.Write(output);
		var reparsed = scope TomlDocument();
		ReadOrFail(reparsed, output);
		Test.Assert(reparsed.TryGetString("backup.tls.cert", var cert2) && cert2 == "c");
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

	[Test]
	public static void Layout_ValueAndTableSlotStayCompact()
	{
		// Every table entry stores a TomlTableSlot (value + metadata node ID) and every array element a
		// TomlValue, so their sizes decide the memory and speed of all documents, metadata or not. The
		// node ID has to fit where the value's own alignment would otherwise pad.
		Test.Assert(sizeof(TomlOffsetDateTime) <= 32, scope $"TomlOffsetDateTime is {sizeof(TomlOffsetDateTime)} bytes");
		Test.Assert(sizeof(TomlValue) <= 40, scope $"TomlValue is {sizeof(TomlValue)} bytes");
		Test.Assert(sizeof(TomlTableSlot) <= 48, scope $"TomlTableSlot is {sizeof(TomlTableSlot)} bytes");
	}
}
