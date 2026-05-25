using System;
using System.IO;
using System.Collections;
using TomlBeef;

namespace TomlBeef;

static class TomlTest
{
	private const String TestBaseDir = "tests";

	[Test]
	public static void VerifyTestFilesFound()
	{
		int count = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/valid", null, scope [&] (path) => { count++; });
		Test.Assert(count > 0, scope $"No .toml files found in {TestBaseDir}/valid");
		count = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/invalid", null, scope [&] (path) => { count++; });
		Test.Assert(count > 0, scope $"No .toml files found in {TestBaseDir}/invalid");
	}

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
	public static void RoundTripValid()
	{
		let validDir = scope $"{TestBaseDir}/valid";
		Test.Assert(Directory.Exists(validDir), scope $"Test directory not found: {validDir}");
		int passed = 0, failed = 0;
		WalkTomlFiles(validDir, null, scope [&] (path) =>
		{
			let name = GetRelativePath(path);
			switch (ParseFile(path, .V1_1))
			{
			case .Err(let e):
				Test.Assert(false, scope $"FAIL [{name}]: {e.mMessage}"); e.Dispose(); failed++;
			case .Ok(let doc1):
				defer delete doc1;
				String t1 = scope String();
				doc1.Write(t1);
				var doc2 = new TomlDocument();
				defer delete doc2;
				if (doc2.Read(t1) case .Err(let e2))
				{
					Test.Assert(false, scope $"FAIL [{name}]: re-parse - {e2.mMessage}\n{t1}"); e2.Dispose(); failed++;
				}
				else
				{
					if (!TomlDocumentEquals(doc1, doc2))
						{ Test.Assert(false, scope $"FAIL [{name}]: mismatch\n{t1}"); failed++; }
					else
					{
						String t2 = scope String();
						doc2.Write(t2);
						if (t1 != t2)
							{ Test.Assert(false, scope $"FAIL [{name}]: nondeterministic\n1:{t1}\n2:{t2}"); failed++; }
						else passed++;
					}
				}
			}
		});
		Test.Assert(passed > 0, "No valid tests passed");
		Test.Assert(failed == 0, scope $"Valid: {passed} passed, {failed} failed");
	}

	[Test]
	public static void InvalidV1_1()
	{
		let dir = scope $"{TestBaseDir}/invalid";
		Test.Assert(Directory.Exists(dir), scope $"Test directory not found: {dir}");
		int passed = 0, failed = 0;
		WalkTomlFiles(dir, "spec-1.0.0", scope [&] (path) =>
		{
			switch (ParseFile(path, .V1_1))
			{
			case .Err: passed++;
			case .Ok(let doc): delete doc; failed++;
			}
		});
		Test.Assert(passed > 0, scope $"v1.1: {passed} passed, {failed} failed");
		Test.Assert(failed == 0, scope $"v1.1: {passed} passed, {failed} failed");
	}

	[Test]
	public static void InvalidV1_0()
	{
		let dir = scope $"{TestBaseDir}/invalid";
		Test.Assert(Directory.Exists(dir), scope $"Test directory not found: {dir}");
		int passed = 0, failed = 0;
		WalkTomlFiles(dir, "spec-1.1.0", scope [&] (path) =>
		{
			switch (ParseFile(path, .V1_0))
			{
			case .Err: passed++;
			case .Ok(let doc): delete doc; failed++;
			}
		});
		Test.Assert(passed > 0, scope $"v1.0: {passed} passed, {failed} failed");
		Test.Assert(failed == 0, scope $"v1.0: {passed} passed, {failed} failed");
	}

	private static Result<TomlDocument, TomlParseError> ParseFile(StringView path, TomlVersion version = .V1_1)
	{
		var data = new List<uint8>();
		defer delete data;
		switch (File.ReadAll(path, data))
		{
		case .Err: return .Err(TomlParseError(.InvalidUtf8, scope $"Cannot read: {path}", 0, 0, 0));
		default:
		}
		String content = scope String();
		for (int i = 0; i < data.Count; i++)
			content.Append((char8)data[i]);
		var doc = new TomlDocument();
		if (doc.Read(content, .() { Version = version }) case .Err(let e))
		{
			delete doc;
			return .Err(e);
		}
		return doc;
	}

	private static void WalkTomlFiles(StringView dir, StringView excludeDir, delegate void(StringView path) onFile)
	{
		for (let entry in Directory.EnumerateFiles(dir))
		{
			let fp = entry.GetFilePath(.. scope .());
			if (fp.EndsWith(".toml")) onFile(fp);
		}
		for (let entry in Directory.EnumerateDirectories(dir))
		{
			let n = scope String(); entry.GetFileName(n);
			if (excludeDir.IsEmpty || n != excludeDir)
				WalkTomlFiles(entry.GetFilePath(.. scope .()), excludeDir, onFile);
		}
	}

	private static bool TomlDocumentEquals(TomlDocument a, TomlDocument b) => TomlTableEquals(a.RootTable, b.RootTable);

	private static bool TomlTableEquals(TomlTable a, TomlTable b)
	{
		if (a.Count != b.Count) return false;
		for (int i = 0; i < a.KeyOrder.Count; i++)
		{
			String key = a.KeyOrder[i];
			if (!b.ContainsKey(key)) return false;
			if (!TomlValueEquals(a.Entries[key], b.Entries[key])) return false;
		}
		return true;
	}

	private static bool TomlValueEquals(TomlValue a, TomlValue b)
	{
		switch (a)
		{
		case .String(let sa): return b case .String(let sb) && sa == sb;
		case .Integer(let ia): return b case .Integer(let ib) && ia == ib;
		case .Float(let fa): if (b case .Float(let fb)) { if (fa.IsNaN && fb.IsNaN) return true; return fa == fb; } return false;
		case .Bool(let ba): return b case .Bool(let bb) && ba == bb;
		case .OffsetDateTime(let da): return b case .OffsetDateTime(let db) && da == db;
		case .LocalDateTime(let da): return b case .LocalDateTime(let db) && da == db;
		case .LocalDate(let da): return b case .LocalDate(let db) && da == db;
		case .LocalTime(let da): return b case .LocalTime(let db) && da == db;
		case .Array(let aa): return b case .Array(let ab) && TomlArrayEquals(aa, ab);
		case .Table(let ta): return b case .Table(let tb) && TomlTableEquals(ta, tb);
		}
	}

	private static bool TomlArrayEquals(TomlArray a, TomlArray b)
	{
		if (a.Count != b.Count) return false;
		for (int i = 0; i < a.Count; i++)
			if (!TomlValueEquals(a[i], b[i])) return false;
		return true;
	}

	private static String GetRelativePath(StringView fullPath)
	{
		int prefixLen = TestBaseDir.Length + 1;
		if (fullPath.Length > prefixLen)
			return scope String(fullPath.Substring(prefixLen));
		return scope String(fullPath);
	}
}
