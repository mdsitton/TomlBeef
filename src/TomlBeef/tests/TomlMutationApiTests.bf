using System;
using System.Collections;
using TomlBeef;
using internal TomlBeef;

namespace TomlBeef;

static class TomlMutationApiTests
{
	[Test]
	public static void Set_DocumentLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;

		// One Set for every scalar type (implicit conversion to TomlInputValue)
		Test.Assert(doc.Set("title", "Hello"));
		Test.Assert(doc.Set("count", 42));
		Test.Assert(doc.Set("pi", 3.14));
		Test.Assert(doc.Set("enabled", true));
		Test.Assert(doc.Set("day", TomlLocalDate(2024, 7, 15)));
		Test.Assert(doc.TryGetLocalDate("day", var day) && day.mDay == 15);

		// Verify via typed getters
		Test.Assert(doc.TryGetString("title", var title) && title == "Hello");
		Test.Assert(doc.TryGetInteger("count", var count) && count == 42);
		Test.Assert(doc.TryGetFloat("pi", var pi) && pi > 3.1 && pi < 3.2);
		Test.Assert(doc.TryGetBool("enabled", var enabled) && enabled == true);

		// Write and re-parse
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetString("title", var title2) && title2 == "Hello");
	}

	[Test]
	public static void Set_TableAndArrayLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;

		doc.RootTable.Set("name", "test");
		doc.RootTable.Set("value", 99);

		Test.Assert(doc.TryGetString("name", var n) && n == "test");
		Test.Assert(doc.TryGetInteger("value", var v) && v == 99);

		// Container creation through the store
		let arr = doc.RootTable.AddArray("items");
		Test.Assert(arr != null);
		arr.Add("a");
		arr.Add(1);
		arr.Add(true);

		Test.Assert(doc.TryGetArray("items", var a1) && a1.Count == 3);

		// Nested container: table inside table
		let sub = doc.RootTable.AddTable("cfg");
		Test.Assert(sub != null);
		sub.Set("host", "localhost");
		sub.Set("port", 8080);
		Test.Assert(doc.TryGetString("cfg.host", var h) && h == "localhost");
	}

	[Test]
	public static void PathMutators_CreateParentsAndRejectBadPaths()
	{
		var doc = scope TomlDocument();
		// Missing parents are created as [header] tables
		Test.Assert(doc.Set("server.http.port", 8080));
		Test.Assert(doc.TryGetInteger("server.http.port", var port) && port == 8080);
		Test.Assert(doc.AddTable("server.tls") != null);
		Test.Assert(doc.AddArray("server.hosts") != null);
		Test.Assert(doc.AddTable("server.tls") == null, "AddTable on an existing key returns null");

		// A parent that exists but is not a table, or a malformed path, is rejected without side effects
		Test.Assert(doc.Set("name", "x"));
		Test.Assert(!doc.Set("name.first", "y"));
		Test.Assert(!doc.Set("a..b", 1));
		Test.Assert(!doc.Set("", 1));
		Test.Assert(doc.AddTable("name.sub") == null);

		// Remove takes a path too
		Test.Assert(doc.Remove("server.http.port"));
		Test.Assert(!doc.TryGetInteger("server.http.port", ?));
		Test.Assert(!doc.Remove("server.http.port"));
		Test.Assert(!doc.Remove("missing.parent.key"), "Remove does not create parents");
		Test.Assert(!doc.TryGetTable("missing", ?));

		String output = scope String();
		doc.Write(output);
		var reparsed = scope TomlDocument();
		if (reparsed.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}\n{output}");
		}
		Test.Assert(reparsed.TryGetTable("server.tls", ?) && reparsed.TryGetArray("server.hosts", ?));
	}

	[Test]
	public static void Array_AddAndIndexAssignment_RoundTrips()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var root = doc.RootTable;

		var arr = root.AddArray("values");
		arr.Add("hello");
		arr.Add(42);
		arr.Add(3.14);
		arr.Add(true);

		Test.Assert(arr.Count == 4);
		arr[0] = "updated";
		Test.Assert(arr.TryGetString(0, var s) && s == "updated");

		// Write and re-parse roundtrip
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetArray("values", var a2) && a2.Count == 4);
	}

	[Test]
	public static void Array_SetTableAndSetArray_RoundTrips()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var arr = doc.AddArray("data");

		// Placeholder elements
		arr.Add(0);
		arr.Add(0);

		// Replace with table at index 0
		var tbl = arr.SetTable(0);
		tbl.Set("name", "replacement");
		StringView n = ?;
		Test.Assert(arr.TryGetTable(0, var t) && t.TryGetString("name", out n) && n == "replacement");

		// Replace with array at index 1
		var nested = arr.SetArray(1);
		nested.Add("x");
		nested.Add(1);
		Test.Assert(arr.TryGetArray(1, var a) && a.Count == 2);

		// Write and re-parse
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetArray("data", var a2) && a2.Count == 2);
	}

	[Test]
	public static void Array_RemoveAtAndClear_ProducesEmptyArray()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var arr = doc.AddArray("x");
		arr.Add(1);
		arr.Add(2);
		arr.Add(3);
		arr.RemoveAt(1);
		Test.Assert(arr.Count == 2);
		arr.Clear();
		Test.Assert(arr.Count == 0);

		Test.Assert(doc.TryGetArray("x", var a1) && a1.Count == 0);

		// Write and re-parse
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetArray("x", var a2) && a2.Count == 0);
	}

	[Test]
	public static void TableEntry_ReadAssignRemoveRename_Works()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var root = doc.RootTable;

		root.Set("name", "test");
		root.Set("count", 42);
		root.Set("flag", true);

		// Read via entry proxy
		var e0 = root[0];
		Test.Assert(e0.Key == "name");
		Test.Assert(e0.TryGetString(var s) && s == "test");

		// Assign via entry proxy
		var e1 = root[1];
		Test.Assert(e1.Key == "count");
		e1.Value = 99;
		Test.Assert(root[1].TryGetInteger(var v) && v == 99);

		// Remove via entry proxy
		int countBefore = root.Count;
		root[2].Remove();
		Test.Assert(root.Count == countBefore - 1);

		// Rename
		switch (root[0].Rename("title"))
		{
		case .Err(let re):
			Test.Assert(false, "Rename failed");
		case .Ok:
		}
		Test.Assert(root[0].Key == "title");
		Test.Assert(root.TryGetString("title", var t) && t == "test");
		Test.Assert(!root.ContainsKey("name"));
	}

	[Test]
	public static void TableEntry_SetTableAndSetArray_RoundTrips()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var root = doc.RootTable;

		root.Set("a", 0);
		root.Set("b", 0);

		// Replace with table
		var tbl = root[0].SetTable();
		tbl.Set("inner", "value");
		StringView s = ?;
		Test.Assert(root.TryGetTable("a", var t) && t.TryGetString("inner", out s) && s == "value");

		// Replace with array
		var arr = root[1].SetArray();
		arr.Add(1);
		arr.Add(2);
		Test.Assert(root.TryGetArray("b", var a) && a.Count == 2);

		// Write and re-parse
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetTable("a", var t2) && t2.Count == 1);
		Test.Assert(doc2.TryGetArray("b", var a2) && a2.Count == 2);
	}

	[Test]
	public static void TableEntry_RenameToDuplicateKeyRejected()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var root = doc.RootTable;
		root.Set("a", "x");
		root.Set("b", "y");

		Test.Assert(root[0].Rename("b") case .Err);
	}

	[Test]
	public static void Iteration_TablesAndArraysWithForeach()
	{
		var doc = scope TomlDocument();
		if (doc.Read("b = 1\na = \"x\"\n[t]\nk = 2\n[[p]]\nn = 1\n[[p]]\nn = 2\n") case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Entries come in insertion order, with typed readers and the raw value
		String keys = scope String();
		int tables = 0;
		for (let entry in doc.RootTable)
		{
			keys.Append(entry.Key);
			keys.Append(' ');
			if (entry.GetValue().IsTable)
				tables++;
		}
		Test.Assert(keys == "b a t p ", scope $"Got '{keys}'");
		Test.Assert(tables == 1);

		// Assigning values while iterating is allowed
		for (var entry in doc.RootTable)
		{
			if (entry.TryGetInteger(let n))
				entry.Value = n * 10;
		}
		Test.Assert(doc.TryGetInteger("b", var b) && b == 10);

		// Arrays yield their elements; array-of-tables elements are tables
		Test.Assert(doc.TryGetArray("p", var p));
		int64 sum = 0;
		for (let element in p)
		{
			if (element case .Table(let tbl) && tbl.TryGetInteger("n", let n))
				sum += n;
		}
		Test.Assert(sum == 3);

		// An empty table or array iterates zero times
		int count = 0;
		for (let entry in doc.AddTable("empty"))
			count++;
		for (let element in doc.AddArray("none"))
			count++;
		Test.Assert(count == 0);
	}

	[Test]
	public static void Array_EmptiedArrayOfTablesWrittenAsEmptyArray()
	{
		for (let mode in TomlMetadataMode[](.None, .PreserveStyle))
		{
			var doc = scope TomlDocument();
			if (doc.Read("before = 1\n[[p]]\nx = 1\n[[p]]\nx = 2\n[t]\ny = 3", .() { MetadataMode = mode }) case .Err(let e))
			{
				Test.Assert(false, scope $"Parse failed: {e.mMessage}");
			}
			Test.Assert(doc.TryGetArray("p", var p));
			p.Clear();

			String output = scope String();
			doc.Write(output);
			var reparsed = scope TomlDocument();
			if (reparsed.Read(output) case .Err(let e2))
			{
				Test.Assert(false, scope $"Re-parse failed ({mode}): {e2.mMessage}\n{output}");
			}
			Test.Assert(reparsed.TryGetArray("p", var p2) && p2.Count == 0, scope $"Emptied array of tables lost ({mode}):\n{output}");
			Test.Assert(reparsed.TryGetInteger("t.y", var y) && y == 3);
		}
	}

	[Test]
	public static void Write_BackslashHeavyStringsUseLiteralQuotes()
	{
		var doc = scope TomlDocument();
		doc.RootTable.Set("path", "C:\\Users\\x");
		doc.RootTable.Set("quote", "say \"hi\"");
		doc.RootTable.Set("plain", "hello");
		doc.RootTable.Set("apostrophe", "it's C:\\x");
		doc.RootTable.Set("tabbed", "a\\b\tc");
		let list = doc.AddArray("regexes");
		list.Add("\\d+");

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("path = 'C:\\Users\\x'\n"), output);
		Test.Assert(output.Contains("quote = 'say \"hi\"'\n"), output);
		Test.Assert(output.Contains("plain = \"hello\"\n"), output);
		// A literal string cannot hold a single quote or a control character
		Test.Assert(output.Contains("apostrophe = \"it's C:\\\\x\"\n"), output);
		Test.Assert(output.Contains("tabbed = \"a\\\\b\\tc\"\n"), output);
		Test.Assert(output.Contains("regexes = ['\\d+']\n"), output);

		var reparsed = scope TomlDocument();
		Test.Assert(reparsed.Read(output) case .Ok);
		Test.Assert(TomlTestSupport.TomlDocumentEquals(doc, reparsed), output);
	}

	static void AssertWritesAs(TomlDocument doc, StringView expected)
	{
		String output = scope String();
		doc.Write(output);
		Test.Assert(output == expected, scope $"Expected:\n{expected}\nGot:\n{output}");
		var reparsed = scope TomlDocument();
		Test.Assert(reparsed.Read(output) case .Ok, output);
		Test.Assert(TomlTestSupport.TomlDocumentEquals(doc, reparsed), output);
	}

	[Test]
	public static void Write_DottedKeysAndImpliedHeaders()
	{
		// Dotted-key tables stay dotted; header-only descendants get full-path headers
		var fruit = scope TomlDocument();
		Test.Assert(fruit.Read("[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n[fruit.apple.texture]\nsmooth = true\n[[fruit.apple.seeds]]\nn = 1\n") case .Ok);
		AssertWritesAs(fruit, "\n[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n\n[fruit.apple.texture]\nsmooth = true\n\n[[fruit.apple.seeds]]\nn = 1\n");

		// Parents that only hold sub-table headers get no header of their own; an empty table keeps one
		var headers = scope TomlDocument();
		Test.Assert(headers.Read("[a]\n[a.b]\n[a.b.c]\nx = 1\n[empty]\n[d]\n[[d.t]]\n") case .Ok);
		AssertWritesAs(headers, "\n[a.b.c]\nx = 1\n\n[empty]\n\n[[d.t]]\n");

		// A dotted-key table emptied in code is kept as an empty inline table
		var emptied = scope TomlDocument();
		Test.Assert(emptied.Read("a.b.c = 1\na.d = 2\n") case .Ok);
		Test.Assert(emptied.Remove("a.b.c"));
		AssertWritesAs(emptied, "a.b = {}\na.d = 2\n");

		// Tables made in code are written with headers as before
		var built = scope TomlDocument();
		built.Set("server.port", 8080);
		AssertWritesAs(built, "\n[server]\nport = 8080\n");
	}

	[Test]
	public static void Write_OutputStaysLinearForDeepPaths()
	{
		// Each of these wrote output quadratic in its input (cumulative [k], [k.k], ... headers, or the
		// long header repeated once per dotted sub-table)
		let deep = scope String();
		for (int i = 0; i < 2000; i++)
			deep.Append(i == 0 ? "k" : ".k");
		deep.Append(" = 1\n");
		let wide = scope String();
		wide.Append('[');
		wide.Append('k', 2000);
		wide.Append("]\n");
		for (int i = 0; i < 2000; i++)
			wide.AppendF("x{}.v = 1\n", i);

		for (let input in StringView[](deep, wide))
		{
			var doc = scope:: TomlDocument();
			Test.Assert(doc.Read(input) case .Ok);
			String output = scope:: String();
			doc.Write(output);
			Test.Assert(output.Length <= input.Length + 2, scope $"{input.Length} bytes wrote {output.Length}");
		}
	}
}
