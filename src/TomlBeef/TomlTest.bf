using System;
using System.IO;
using System.Collections;
using TomlBeef;

namespace TomlBeef;

static class TomlTest
{
	private const String TestBaseDir = "toml-test/tests";

	[Test]
	public static void VerifyTestFilesFound()
	{
		int count = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/valid" , scope [&] (path) => { count++; });
		Test.Assert(count > 0, scope $"No .toml files found in {TestBaseDir}/valid");

		count = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/invalid" , scope [&] (path) => { count++; });
		Test.Assert(count > 0, scope $"No .toml files found in {TestBaseDir}/invalid");
	}

	[Test]
	public static void SmokeTest()
	{
		let input = "x = 42";
		let parser = scope TomlParser();
		switch (parser.Parse(input))
		{
		case .Err(let e):
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		case .Ok(let doc):
			defer delete doc;
			Test.Assert(doc.mRootTable.Count == 1, scope $"Got {doc.mRootTable.Count}");
		}
	}

	[Test]
	public static void RoundTripValid()
	{
		let validDir = scope $"{TestBaseDir}/valid";
		Test.Assert(Directory.Exists(validDir), scope $"Test directory not found: {validDir}");

		int passed = 0;
		int failed = 0;

		WalkTomlFiles(validDir, scope [&] (path) =>
			{
				let baseTestName = GetRelativePath(path);

				switch (ParseFile(path))
				{
				case .Err(let e):
					Test.Assert(false, scope $"FAIL [{baseTestName}]: {e.mMessage}");
					e.Dispose();
					failed++;
				case .Ok(let doc1):
					defer delete doc1;

					let writer1 = scope TomlWriter();
					String toml1 = scope String();
					writer1.Write(doc1, toml1);

					let parser2 = scope TomlParser();
					switch (parser2.Parse(toml1))
					{
					case .Err(let e2):
						Test.Assert(false, scope $"FAIL [{baseTestName}]: re-parse — {e2.mMessage}\n{toml1}");
						e2.Dispose();
						failed++;
					case .Ok(let doc2):
						defer delete doc2;

						if (!TomlDocumentEquals(doc1, doc2))
						{
							Test.Assert(false, scope $"FAIL [{baseTestName}]: mismatch\n{toml1}");
							failed++;
						}
						else
						{
							// Determinism: second write must match first
							let writer2 = scope TomlWriter();
							String toml2 = scope String();
							writer2.Write(doc2, toml2);
							if (toml1 != toml2)
							{
								Test.Assert(false, scope $"FAIL [{baseTestName}]: nondeterministic\n1:{toml1}\n2:{toml2}");
								failed++;
							}
							else
							{
								passed++;
							}
						}
					}
				}
			});

		Test.Assert(passed > 0, "No valid tests passed");
		Test.Assert(failed == 0, scope $"Valid: {passed} passed, {failed} failed");
	}

	[Test]
	public static void InvalidTests()
	{
		let invalidDir = scope $"{TestBaseDir}/invalid";
		Test.Assert(Directory.Exists(invalidDir), scope $"Test directory not found: {invalidDir}");

		int passed = 0;
		int failed = 0;

		WalkTomlFiles(invalidDir, scope [&] (path) =>
			{
				let baseTestName = GetRelativePath(path);

				switch (ParseFile(path))
				{
				case .Err:
					passed++;
				case .Ok(let doc):
					delete doc;
					Test.Assert(false, scope $"FAIL [{baseTestName}]: should have failed");
					failed++;
				}
			});

		Test.Assert(passed > 0, "No invalid tests passed");
		Test.Assert(failed == 0, scope $"Invalid: {passed} passed, {failed} failed");
	}

	// ---- helpers ----

	private static Result<TomlDocument, TomlParseError> ParseFile(StringView path)
	{
		String content = scope String();
		switch (File.ReadAllText(path, content))
		{
		case .Err:
			return .Err(TomlParseError(.InvalidUtf8, scope $"Cannot read: {path}" , 0, 0, 0));
		default:
		}

		let parser = scope TomlParser();
		return parser.Parse(content);
	}

	private static void WalkTomlFiles(StringView dir, delegate void(StringView path) onFile)
	{
		for (let entry in Directory.EnumerateFiles(dir))
		{
			let filePath = entry.GetFilePath(.. scope .());
			if (filePath.EndsWith(".toml"))
				onFile(filePath);
		}

		for (let entry in Directory.EnumerateDirectories(dir))
		{
			WalkTomlFiles(entry.GetFilePath(.. scope .()), onFile);
		}
	}

	private static bool TomlDocumentEquals(TomlDocument a, TomlDocument b)
	{
		return TomlTableEquals(a.mRootTable, b.mRootTable);
	}

	private static bool TomlTableEquals(TomlTable a, TomlTable b)
	{
		if (a.Count != b.Count)
			return false;

		for (int i = 0; i < a.KeyOrder.Count; i++)
		{
			String key = a.KeyOrder[i];
			if (!b.ContainsKey(key))
				return false;

			if (!TomlValueEquals(a.Entries[key], b.Entries[key]))
				return false;
		}

		return true;
	}

	private static bool TomlValueEquals(TomlValue a, TomlValue b)
	{
		switch (a)
		{
		case .String(let sa):
			return b case .String(let sb) && sa == sb;
		case .Integer(let ia):
			return b case .Integer(let ib) && ia == ib;
		case .Float(let fa):
			if (b case .Float(let fb))
			{
				if (fa.IsNaN && fb.IsNaN) return true;
				return fa == fb;
			}
			return false;
		case .Bool(let ba):
			return b case .Bool(let bb) && ba == bb;
		case .OffsetDateTime(let da):
			return b case .OffsetDateTime(let db) && da == db;
		case .LocalDateTime(let da):
			return b case .LocalDateTime(let db) && da == db;
		case .LocalDate(let da):
			return b case .LocalDate(let db) && da == db;
		case .LocalTime(let da):
			return b case .LocalTime(let db) && da == db;
		case .Array(let aa):
			if (b case .Array(let ab))
				return TomlArrayEquals(aa, ab);
			return false;
		case .Table(let ta):
			if (b case .Table(let tb))
				return TomlTableEquals(ta, tb);
			return false;
		}
	}

	private static bool TomlArrayEquals(TomlArray a, TomlArray b)
	{
		if (a.Count != b.Count)
			return false;

		for (int i = 0; i < a.Count; i++)
		{
			if (!TomlValueEquals(a[i], b[i]))
				return false;
		}

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
