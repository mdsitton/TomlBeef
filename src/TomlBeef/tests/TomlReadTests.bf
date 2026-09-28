using System;
using TomlBeef;
using static TomlBeef.TomlTestSupport;

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

	// ================================================================
	// Read modes and merge conflicts
	// ================================================================

	static void ReadOrFail(TomlDocument doc, StringView input, TomlReadConfig config = .())
	{
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed for '{input}': {e.mMessage}");
		}
	}

	[Test]
	public static void ReadMode_ReplaceClearsPreviousContent()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "old = 1\n[t]\nx = 1");
		ReadOrFail(doc, "new = \"v\"");
		Test.Assert(doc.RootTable.Count == 1);
		Test.Assert(!doc.TryGetInteger("old", ?));
		Test.Assert(!doc.TryGetTable("t", ?));
		Test.Assert(doc.TryGetString("new", var s) && s == "v");
	}

	[Test]
	public static void ReadMode_MergeKeepsExistingValues()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "name = \"base\"\nlist = [1, 2]\n[server]\nhost = \"localhost\"");
		ReadOrFail(doc, "extra = \"added\"\n[client]\nretries = 3", .() { Mode = .Merge });

		Test.Assert(doc.TryGetString("name", var name) && name == "base");
		Test.Assert(doc.TryGetArray("list", var list) && list.Count == 2);
		Test.Assert(doc.TryGetString("server.host", var host) && host == "localhost");
		Test.Assert(doc.TryGetString("extra", var extra) && extra == "added");
		Test.Assert(doc.TryGetInteger("client.retries", var retries) && retries == 3);
	}

	[Test]
	public static void MergeConflict_ErrorRejectsWithoutChanges()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = \"old\"\nb = 1");
		switch (doc.Read("c = 3\na = \"new\"", .() { Mode = .Merge, OnConflict = .Error }))
		{
		case .Ok:
			Test.Assert(false, "Expected merge conflict");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .DuplicateKey, scope $"Expected DuplicateKey, got {e.mKind}");
		}
		// Validation happens before any insert, so the non-conflicting key must not be added either
		Test.Assert(doc.RootTable.Count == 2);
		Test.Assert(!doc.TryGetInteger("c", ?));
		Test.Assert(doc.TryGetString("a", var a) && a == "old");
	}

	[Test]
	public static void MergeConflict_SkipKeepsExistingValue()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = \"old\"");
		ReadOrFail(doc, "a = \"new\"\nb = 2", .() { Mode = .Merge, OnConflict = .Skip });
		Test.Assert(doc.TryGetString("a", var a) && a == "old");
		Test.Assert(doc.TryGetInteger("b", var b) && b == 2);
	}

	[Test]
	public static void MergeConflict_OverwriteReplacesValue()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = \"old\"\nkeep = true");
		ReadOrFail(doc, "a = \"new\"\nb = 2", .() { Mode = .Merge, OnConflict = .Overwrite });
		Test.Assert(doc.TryGetString("a", var a) && a == "new");
		Test.Assert(doc.TryGetBool("keep", var keep) && keep);
		Test.Assert(doc.TryGetInteger("b", var b) && b == 2);
	}

	// ================================================================
	// Deep merge
	// ================================================================

	static Result<void, TomlParseError> Merge(TomlDocument doc, StringView input, MergeConflict onConflict)
	{
		return doc.Read(input, .() { Mode = .Merge, OnConflict = onConflict });
	}

	static void MergeOrFail(TomlDocument doc, StringView input, MergeConflict onConflict)
	{
		if (Merge(doc, input, onConflict) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Merge failed: {e.mMessage}");
		}
	}

	/// The merged document must also write out and re-read to the same content.
	static void AssertWritesAndRereads(TomlDocument doc)
	{
		String output = scope String();
		doc.Write(output);
		var reparsed = scope TomlDocument();
		if (reparsed.Read(output) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Merged output does not re-parse: {e.mMessage}\n{output}");
			return;
		}
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Merged output changed on re-read:\n{output}");
	}

	[Test]
	public static void DeepMerge_SharedTablesCombineWithoutConflict()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "[server]\nhost = \"localhost\"\n[a.b]\nx = 1");
		MergeOrFail(doc, "[server]\nport = 8080\n[a.b]\ny = 2\n[a.c]\nz = 3", .Error);
		Test.Assert(doc.TryGetString("server.host", var host) && host == "localhost");
		Test.Assert(doc.TryGetInteger("server.port", var port) && port == 8080);
		Test.Assert(doc.TryGetInteger("a.b.x", var x) && x == 1);
		Test.Assert(doc.TryGetInteger("a.b.y", var y) && y == 2);
		Test.Assert(doc.TryGetInteger("a.c.z", var z) && z == 3);
		AssertWritesAndRereads(doc);
	}

	[Test]
	public static void DeepMerge_NestedLeafConflictNamesPathAndChangesNothing()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "[server]\nport = 1\nhost = \"a\"");
		switch (Merge(doc, "extra = true\n[server]\nnew = 1\nport = 2", .Error))
		{
		case .Ok:
			Test.Assert(false, "Expected a nested leaf conflict");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .DuplicateKey, scope $"Expected DuplicateKey, got {e.mKind}");
			Test.Assert(e.mMessage.Contains("'server.port'"), scope $"Error should name the path: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("server.port", var port) && port == 1);
		Test.Assert(!doc.TryGetBool("extra", ?), "Nothing may be applied when validation fails");
		Test.Assert(!doc.TryGetInteger("server.new", ?), "Nothing may be applied when validation fails");
	}

	[Test]
	public static void DeepMerge_ConflictPathBracketsDottedKeys()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "[a.\"b.c\"]\nx = 1");
		switch (Merge(doc, "[a.\"b.c\"]\nx = 2", .Error))
		{
		case .Ok:
			Test.Assert(false, "Expected conflict");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mMessage.Contains("'a.[b.c].x'"), scope $"Expected bracketed path, got: {e.mMessage}");
		}
	}

	[Test]
	public static void DeepMerge_SkipAndOverwriteApplyToNestedLeaves()
	{
		var skip = scope TomlDocument();
		ReadOrFail(skip, "[server]\nport = 1\nhost = \"a\"");
		MergeOrFail(skip, "[server]\nport = 2\ntimeout = 30", .Skip);
		Test.Assert(skip.TryGetInteger("server.port", var p1) && p1 == 1);
		Test.Assert(skip.TryGetString("server.host", var h1) && h1 == "a");
		Test.Assert(skip.TryGetInteger("server.timeout", var t1) && t1 == 30);

		var overwrite = scope TomlDocument();
		ReadOrFail(overwrite, "[server]\nport = 1\nhost = \"a\"");
		MergeOrFail(overwrite, "[server]\nport = 2\ntimeout = 30", .Overwrite);
		Test.Assert(overwrite.TryGetInteger("server.port", var p2) && p2 == 2);
		Test.Assert(overwrite.TryGetString("server.host", var h2) && h2 == "a", "Overwrite must not drop sibling keys");
		Test.Assert(overwrite.TryGetInteger("server.timeout", var t2) && t2 == 30);
		AssertWritesAndRereads(overwrite);
	}

	[Test]
	public static void DeepMerge_ArraysAreReplacedWhole()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "a = [1, 2]\n[[s]]\nn = 1\n[[s]]\nn = 2");
		Test.Assert(Merge(doc, "a = [3]", .Error) case .Err(let e), "A shared array is a conflicting leaf");
		e.Dispose();

		MergeOrFail(doc, "a = [3]\n[[s]]\nn = 3", .Overwrite);
		Test.Assert(doc.TryGetArray("a", var a) && a.Count == 1);
		Test.Assert(a.TryGetInteger(0, var a0) && a0 == 3);
		Test.Assert(doc.TryGetArray("s", var s) && s.Count == 1, "Arrays of tables are replaced, not appended");
		Test.Assert(s.TryGetTable(0, var s0));
		Test.Assert(s0.TryGetInteger("n", var n) && n == 3);
		AssertWritesAndRereads(doc);
	}

	[Test]
	public static void DeepMerge_TypeMismatchIsALeafConflict()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "t = 1\n[u]\nx = 1");
		switch (Merge(doc, "[t]\nx = 1", .Error))
		{
		case .Ok:
			Test.Assert(false, "Expected conflict for value vs table");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mMessage.Contains("'t'"), scope $"Error should name the path: {e.mMessage}");
		}

		MergeOrFail(doc, "[t]\nx = 2\n[[u]]\ny = 3", .Overwrite);
		Test.Assert(doc.TryGetInteger("t.x", var tx) && tx == 2, "Overwrite replaces a value with a table");
		Test.Assert(doc.TryGetArray("u", var u) && u.Count == 1, "Overwrite replaces a table with an array of tables");
		AssertWritesAndRereads(doc);
	}

	[Test]
	public static void DeepMerge_InlineTableKeepsOriginAndAcceptsKeys()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "t = { a = 1 }");
		MergeOrFail(doc, "[t]\nb = 2", .Error);
		Test.Assert(doc.TryGetTable("t", var t) && t.Origin == .InlineTable);
		Test.Assert(t.TryGetInteger("a", var a) && a == 1);
		Test.Assert(t.TryGetInteger("b", var b) && b == 2);
		AssertWritesAndRereads(doc);
	}

	[Test]
	public static void DocumentConfig_UsedByOverloadsWithoutConfig()
	{
		var doc = scope TomlDocument();
		doc.ReadConfig.MetadataMode = .PreserveStyle;
		doc.ReadConfig.Version = .V1_0;
		doc.WriteConfig.Version = .V1_0;
		if (doc.Read("a = 0x10") case .Err(let readErr))
		{
			defer readErr.Dispose();
			Test.Assert(false, scope $"Parse failed: {readErr.mMessage}");
		}
		Test.Assert(doc.Metadata != null, "ReadConfig applies to Read(input)");

		// A 1.1-only escape is rejected under the document's 1.0 read config
		var strict = scope TomlDocument();
		strict.ReadConfig.Version = .V1_0;
		if (strict.Read("s = \"\\e\"") case .Err(let e))
			e.Dispose();
		else
			Test.Assert(false, "Expected the document's V1_0 read config to reject \\e");

		// WriteConfig applies to Write(output): a 1.1 escape is downgraded for 1.0
		var writer = scope TomlDocument();
		writer.RootTable.SetString("s", "\x1B");
		writer.WriteConfig.Version = .V1_0;
		String output = scope String();
		writer.Write(output);
		Test.Assert(output.Contains("\\u001B") || output.Contains("\\u001b"), scope $"Expected a 1.0 escape:\n{output}");

		// Each document has its own config
		Test.Assert(scope TomlDocument().ReadConfig.Version == .V1_1);
	}

	[Test]
	public static void ReadFile_MissingFileIsIoErrorAndFollowsReadMode()
	{
		var replace = scope TomlDocument();
		ReadOrFail(replace, "old = 1");
		switch (replace.ReadFile("tests/does-not-exist.toml"))
		{
		case .Ok:
			Test.Assert(false, "Expected IoError for a missing file");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .IoError, scope $"Expected IoError, got {e.mKind}");
		}
		Test.Assert(replace.RootTable.Count == 0, "A failed Replace read leaves the document empty");

		var merge = scope TomlDocument();
		ReadOrFail(merge, "old = 1");
		if (merge.ReadFile("tests/does-not-exist.toml", .() { Mode = .Merge }) case .Err(let e2))
			e2.Dispose();
		Test.Assert(merge.TryGetInteger("old", var old) && old == 1, "A failed Merge read leaves the document unchanged");
	}

	// ================================================================
	// Accessors
	// ================================================================

	[Test]
	public static void Accessor_WrongTypeReturnsFalse()
	{
		var doc = scope TomlDocument();
		ReadOrFail(doc, "s = \"text\"\ni = 1\nf = 1.5\nb = true\nd = 1979-05-27\narr = [1]\n[t]\nk = 1");
		Test.Assert(!doc.TryGetInteger("s", ?));
		Test.Assert(!doc.TryGetString("i", ?));
		Test.Assert(!doc.TryGetFloat("i", ?), "Integer must not read as float");
		Test.Assert(!doc.TryGetInteger("f", ?), "Float must not read as integer");
		Test.Assert(!doc.TryGetBool("s", ?));
		Test.Assert(!doc.TryGetLocalDateTime("d", ?));
		Test.Assert(!doc.TryGetTable("arr", ?));
		Test.Assert(!doc.TryGetArray("t", ?));
		Test.Assert(!doc.TryGetString("t", ?));
		Test.Assert(!doc.TryGetInteger("t.missing", ?));
		Test.Assert(!doc.TryGetInteger("s.child", ?), "Scalar must not be traversed as a table");
	}

	// ================================================================
	// BOM through string and byte input
	// ================================================================

	[Test]
	public static void Bom_SingleBomAcceptedByStringAndBytes()
	{
		String input = scope String();
		input.Append((char8)0xEF, 1);
		input.Append((char8)0xBB, 1);
		input.Append((char8)0xBF, 1);
		input.Append("a = 1\nb = \"x\"");

		var fromString = scope TomlDocument();
		ReadOrFail(fromString, input);
		Test.Assert(fromString.TryGetInteger("a", var a1) && a1 == 1);
		Test.Assert(fromString.TryGetString("b", var b1) && b1 == "x");

		var fromBytes = scope TomlDocument();
		if (fromBytes.ReadBytes(Span<uint8>((uint8*)input.Ptr, input.Length)) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"ReadBytes failed: {e.mMessage}");
		}
		Test.Assert(fromBytes.TryGetInteger("a", var a2) && a2 == 1);
		Test.Assert(fromBytes.TryGetString("b", var b2) && b2 == "x");
	}

	// ================================================================
	// Error locations
	// ================================================================

	static void AssertErrorAt(StringView input, TomlErrorKind kind, int line, int column, int offset)
	{
		var doc = scope TomlDocument();
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, scope $"Expected {kind} for '{input}'");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == kind, scope $"Expected {kind}, got {e.mKind}: {e.mMessage}");
			Test.Assert(e.mLine == line && e.mColumn == column && e.mOffset == offset,
				scope $"Expected {line}:{column} @{offset}, got {e.mLine}:{e.mColumn} @{e.mOffset} ({e.mMessage})");
		}
	}

	[Test]
	public static void ErrorLocation_LexicalErrorsPointAtOffendingByte()
	{
		AssertErrorAt("a = 1\nb = \n", .UnexpectedToken, 2, 5, 10);
		AssertErrorAt("a = 1\n  b = [1,\n 2,, 3]", .UnexpectedToken, 3, 4, 19);
		AssertErrorAt("x = \"abc\n", .UnterminatedString, 1, 9, 8);
		AssertErrorAt("s = 'x\x01'", .ControlCharInString, 1, 7, 6);
	}

	[Test]
	public static void ErrorLocation_OffsetsAfterBomAreRawOnEveryPath()
	{
		String input = scope String();
		input.Append((char8)0xEF, 1);
		input.Append((char8)0xBB, 1);
		input.Append((char8)0xBF, 1);
		input.Append("a = 1\na = 2");
		let span = Span<uint8>((uint8*)input.Ptr, input.Length);
		let ms = scope System.IO.MemoryStream();
		ms.TryWrite(span);
		ms.Position = 0;

		let results = scope Result<void, TomlParseError>[](
			scope TomlDocument().Read(input),
			scope TomlDocument().ReadBytes(span),
			scope TomlDocument().Read(ms));
		let pathNames = scope String[]("Read(string)", "ReadBytes", "Read(Stream)");
		for (int i < results.Count)
		{
			switch (results[i])
			{
			case .Ok:
				Test.Assert(false, scope $"{pathNames[i]}: expected DuplicateKey");
			case .Err(let e):
				defer e.Dispose();
				// Line/column restart after the BOM; the byte offset counts it (3 + 6)
				Test.Assert(e.mKind == .DuplicateKey && e.mLine == 2 && e.mColumn == 1 && e.mOffset == 9,
					scope $"{pathNames[i]}: got {e.mKind} {e.mLine}:{e.mColumn} @{e.mOffset}");
			}
		}
	}

	[Test]
	public static void ErrorLocation_SemanticErrorsPointAtStatementStart()
	{
		AssertErrorAt("a = 1\nb = 2\na = 3", .DuplicateKey, 3, 1, 12);
		AssertErrorAt("[t]\nk = 1\n[t]\n", .DuplicateTable, 3, 1, 10);
		AssertErrorAt("a = { b = 1 }\na.c = 2", .InlineTableSealed, 2, 1, 14);
		AssertErrorAt("x.y = 1\n  x = 2", .DuplicateKey, 2, 3, 10);
	}
}
