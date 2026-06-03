using System;
using System.Collections;
using TomlBeef;
using internal TomlBeef;

namespace TomlBeef;

static class TomlMutationApiTests
{
	[Test]
	public static void TypedSetters_DocumentLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;

		// Build a document without new String, new TomlTable, etc.
		doc.SetString("title", "Hello");
		doc.SetInteger("count", 42);
		doc.SetFloat("pi", 3.14);
		doc.SetBool("enabled", true);

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
			defer e.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetString("title", var title2) && title2 == "Hello");
	}

	[Test]
	public static void TypedSetters_TableAndArrayLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;

		doc.RootTable.SetString("name", "test");
		doc.RootTable.SetInteger("value", 99);

		Test.Assert(doc.TryGetString("name", var n) && n == "test");
		Test.Assert(doc.TryGetInteger("value", var v) && v == 99);

		// Container creation through the store
		let arr = doc.RootTable.AddArray("items");
		Test.Assert(arr != null);
		arr.AddString("a");
		arr.AddInteger(1);
		arr.AddBool(true);

		Test.Assert(doc.TryGetArray("items", var a1) && a1.Count == 3);

		// Nested container: table inside table
		let sub = doc.RootTable.AddTable("cfg");
		Test.Assert(sub != null);
		sub.SetString("host", "localhost");
		sub.SetInteger("port", 8080);
		Test.Assert(doc.TryGetString("cfg.host", var h) && h == "localhost");
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
			defer e.Dispose();
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
		tbl.SetString("name", "replacement");
		StringView n = ?;
		Test.Assert(arr.TryGetTable(0, var t) && t.TryGetString("name", out n) && n == "replacement");

		// Replace with array at index 1
		var nested = arr.SetArray(1);
		nested.AddString("x");
		nested.AddInteger(1);
		Test.Assert(arr.TryGetArray(1, var a) && a.Count == 2);

		// Write and re-parse
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			defer e.Dispose();
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
			defer e.Dispose();
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

		root.SetString("name", "test");
		root.SetInteger("count", 42);
		root.SetBool("flag", true);

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
			defer re.Dispose();
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

		root.SetInteger("a", 0);
		root.SetInteger("b", 0);

		// Replace with table
		var tbl = root[0].SetTable();
		tbl.SetString("inner", "value");
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
			defer e.Dispose();
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
		root.SetString("a", "x");
		root.SetString("b", "y");

		Test.Assert(root[0].Rename("b") case .Err);
	}
}
