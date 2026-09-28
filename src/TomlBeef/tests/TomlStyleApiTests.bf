using System;
using TomlBeef;
using internal TomlBeef;
using static TomlBeef.TomlTestSupport;

namespace TomlBeef;

/// Public comment and presentation-style editing API (documents read with PreserveStyle).
static class TomlStyleApiTests
{
	static TomlDocument ReadPreserving(TomlDocument doc, StringView input)
	{
		if (doc.Read(input, .() { MetadataMode = .PreserveStyle }) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}\n{input}");
		}
		return doc;
	}

	/// Writes the document and requires the output to re-read to the same content.
	static void WriteChecked(TomlDocument doc, String output)
	{
		doc.Write(output);
		var reparsed = scope TomlDocument();
		if (reparsed.Read(output) case .Err(let e))
		{
			Test.Assert(false, scope $"Output does not re-parse: {e.mMessage}\n{output}");
			return;
		}
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Output changed on re-read:\n{output}");
	}

	static void AssertContains(StringView output, StringView expected)
	{
		Test.Assert(output.Contains(expected), scope $"Expected to find:\n{expected}\nin output:\n{output}");
	}

	[Test]
	public static void Comments_SetReplaceAndRemoveOnKeys()
	{
		let doc = ReadPreserving(scope .(), "# old\nport = 80\nname = \"x\"");
		Test.Assert(doc.RootTable.SetComment("port", "The port\nto listen on"));
		Test.Assert(doc.RootTable.SetTrailingComment("name", "display name"));

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "# The port\n# to listen on\nport = 80\n");
		AssertContains(output, "name = \"x\" # display name\n");
		Test.Assert(!output.Contains("# old"), "SetComment replaces existing comment lines");

		String read = scope String();
		Test.Assert(doc.RootTable.TryGetComment("port", read) && read == "The port\nto listen on");
		read.Clear();
		Test.Assert(doc.RootTable.TryGetTrailingComment("name", read) && read == "display name");

		// Empty text removes
		Test.Assert(doc.RootTable.SetComment("port", ""));
		Test.Assert(doc.RootTable.SetTrailingComment("name", ""));
		String cleared = scope String();
		WriteChecked(doc, cleared);
		Test.Assert(!cleared.Contains("#"), scope $"Comments should be removed:\n{cleared}");
		Test.Assert(!doc.RootTable.TryGetComment("port", scope String()));
	}

	[Test]
	public static void Comments_ReadBackParsedComments()
	{
		let doc = ReadPreserving(scope .(), "# first\n#\n# third\na = 1 # tail");
		String read = scope String();
		Test.Assert(doc.RootTable.TryGetComment("a", read) && read == "first\n\nthird", scope $"Got '{read}'");
		read.Clear();
		Test.Assert(doc.RootTable.TryGetTrailingComment("a", read) && read == "tail");
	}

	[Test]
	public static void Comments_HeaderTablesAndArrayOfTablesElements()
	{
		let doc = ReadPreserving(scope .(), "[server]\nhost = \"a\"\n\n[[p]]\nn = 1\n\n[[p]]\nn = 2");
		Test.Assert(doc.RootTable.SetComment("server", "Server settings"));
		Test.Assert(doc.RootTable.SetTrailingComment("server", "main"));
		// An array of tables has one header per element, so the key-level call is rejected
		Test.Assert(!doc.RootTable.SetComment("p", "ambiguous"));
		Test.Assert(doc.TryGetArray("p", var p));
		Test.Assert(p.TryGetTable(1, var second));
		Test.Assert(second.SetHeaderComment("Second product"));
		Test.Assert(second.SetHeaderTrailingComment("n = 2"));

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "# Server settings\n[server] # main\n");
		AssertContains(output, "# Second product\n[[p]] # n = 2\nn = 2");
		Test.Assert(!output.Contains("ambiguous"));
	}

	[Test]
	public static void Comments_ProgrammaticKeysAndInlineTableFields()
	{
		let doc = ReadPreserving(scope .(), "t = { a = 1, b = 2 }");
		doc.RootTable.Set("added", 3);
		Test.Assert(doc.RootTable.SetComment("added", "added in code"));
		let sub = doc.AddTable("section");
		sub.Set("k", "v");
		Test.Assert(doc.RootTable.SetComment("section", "new section"));

		// A comment on a single-line inline table's field switches it to the multi-line (1.1) layout
		Test.Assert(doc.TryGetTable("t", var t));
		Test.Assert(t.SetComment("b", "about b"));

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "# added in code\nadded = 3\n");
		AssertContains(output, "# new section\n[section]\n");
		// Indented to the document's inferred indent (4 by default)
		AssertContains(output, "t = {\n    a = 1,\n    # about b\n    b = 2\n}");

		// TOML 1.0 cannot hold comments inside inline tables; the table stays on one line
		String v10 = scope String();
		doc.Write(v10, .() { Version = .V1_0 });
		AssertContains(v10, "t = {");
		Test.Assert(!v10.Contains("about b"), scope $"1.0 output cannot keep inline-table comments:\n{v10}");
	}

	[Test]
	public static void Comments_FileHeaderAndFooter()
	{
		let doc = ReadPreserving(scope .(), "a = 1");
		Test.Assert(doc.SetFileHeaderComment("Generated file\nDo not edit"));
		Test.Assert(doc.SetFileFooterComment("end"));
		String output = scope String();
		WriteChecked(doc, output);
		Test.Assert(output.StartsWith("# Generated file\n# Do not edit\n"), scope $"Unexpected output:\n{output}");
		AssertContains(output, "a = 1");
		Test.Assert(StringView(output)..TrimEnd().EndsWith("# end"), scope $"Footer should be last:\n{output}");
	}

	[Test]
	public static void Comments_PathVariantsAndRejectedInput()
	{
		let doc = ReadPreserving(scope .(), "[a.b]\nc = 1");
		Test.Assert(doc.SetComment("a.b.c", "deep"));
		Test.Assert(doc.SetTrailingComment("a.b.c", "tail"));
		Test.Assert(!doc.SetComment("a.missing", "x"), "Missing key");
		Test.Assert(!doc.SetComment("a..b", "x"), "Malformed path");
		Test.Assert(!doc.SetComment("a.b.c", "bad\rtext"), "Control characters are rejected");
		Test.Assert(!doc.SetTrailingComment("a.b.c", "two\nlines"), "Trailing comments are single-line");

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "# deep\nc = 1 # tail");

		// Without PreserveStyle metadata there is nowhere to keep comments or styles
		var plain = scope TomlDocument();
		if (plain.Read("a = 1") case .Err(let e))
		{
			Test.Assert(false);
		}
		Test.Assert(!plain.RootTable.SetComment("a", "x"));
		Test.Assert(!plain.SetFileHeaderComment("x"));
		Test.Assert(!plain.RootTable.SetIntegerBase("a", .Hex));
	}

	[Test]
	public static void Style_StringStyleChangesOutput()
	{
		let doc = ReadPreserving(scope .(), "a = \"plain\"\nb = \"it's\"\nc = 'lines'\nd = \"x\"");
		Test.Assert(doc.RootTable.SetStringStyle("a", .Literal));
		Test.Assert(doc.RootTable.SetStringStyle("b", .Literal), "Accepted; written as basic because of the quote");
		Test.Assert(doc.RootTable.SetStringStyle("c", .MultilineBasic));
		Test.Assert(doc.SetStringStyle("d", .MultilineLiteral));
		Test.Assert(!doc.RootTable.SetStringStyle("missing", .Literal));
		Test.Assert(StyleFor(doc, "a").mDirtyFlags.HasFlag(.Style));

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "a = 'plain'");
		AssertContains(output, "b = \"it's\"");
		AssertContains(output, "c = \"\"\"\nlines\"\"\"");
		AssertContains(output, "d = '''\nx'''");
	}

	/// Asserts `range` points at the `occurrence`-th match of `needle` in `input` (line/column/offset).
	static void AssertRangeAt(TomlSourceRange range, StringView input, StringView needle, int occurrence = 0)
	{
		int offset = -1;
		int from = 0;
		for (int i = 0; i <= occurrence; i++)
		{
			offset = input.IndexOf(needle, from);
			Test.Assert(offset >= 0, scope $"Test setup: '{needle}' not found");
			from = offset + 1;
		}
		int line = 1;
		int lineStart = 0;
		for (int i = 0; i < offset; i++)
		{
			if (input[i] == '\n')
			{
				line++;
				lineStart = i + 1;
			}
		}
		let column = offset - lineStart + 1;
		Test.Assert(range.mLine == line && range.mColumn == column && range.mOffset == offset,
			scope $"'{needle}': expected {line}:{column} @{offset}, got {range.mLine}:{range.mColumn} @{range.mOffset}");
	}

	[Test]
	public static void SourceRange_ReportsWhereValuesWereDefined()
	{
		let input = "title = \"x\"\n\n[server]\n  port = 8080\n  tags = [ \"a\",\n    \"b\" ]\n  inline = { k = 1, j = 2 }\n  a.b = true\n\n[[items]]\nn = 1\n\n[[items]]\nn = 2\n";
		let doc = ReadPreserving(scope .(), input);

		TomlSourceRange range;
		Test.Assert(doc.TryGetSourceRange("title", out range));
		AssertRangeAt(range, input, "title");
		Test.Assert(range.mLength == "title = \"x\"".Length, scope $"Length spans the key/value, got {range.mLength}");

		Test.Assert(doc.TryGetSourceRange("server", out range));
		AssertRangeAt(range, input, "[server]");
		Test.Assert(range.mLength == "[server]".Length);

		Test.Assert(doc.TryGetSourceRange("server.port", out range));
		AssertRangeAt(range, input, "port");
		Test.Assert(range.mLength == "port = 8080".Length);

		Test.Assert(doc.TryGetSourceRange("server.a.b", out range));
		AssertRangeAt(range, input, "a.b");

		Test.Assert(doc.TryGetTable("server.inline", var inlineTable) && inlineTable.TryGetSourceRange("j", out range));
		AssertRangeAt(range, input, "j = 2");

		Test.Assert(doc.TryGetArray("server.tags", var tags) && tags.TryGetSourceRange(1, out range));
		AssertRangeAt(range, input, "\"b\"");

		// An array of tables: the key reports its first header, each element its own
		Test.Assert(doc.TryGetSourceRange("items", out range));
		AssertRangeAt(range, input, "[[items]]", 0);
		Test.Assert(doc.TryGetArray("items", var items) && items.TryGetSourceRange(1, out range));
		AssertRangeAt(range, input, "[[items]]", 1);
		Test.Assert(items.TryGetTable(1, var second) && second.TryGetSourceRange("n", out range));
		AssertRangeAt(range, input, "n = 2");
	}

	[Test]
	public static void SourceRange_UnknownForNewValuesAndWithoutMetadata()
	{
		let doc = ReadPreserving(scope .(), "a = 1\n");
		doc.RootTable.Set("added", 2);
		TomlSourceRange range;
		Test.Assert(!doc.TryGetSourceRange("added", out range), "Values added in code have no source position");
		Test.Assert(!doc.TryGetSourceRange("missing", out range));
		Test.Assert(!doc.TryGetSourceRange("a..b", out range));

		var plain = scope TomlDocument();
		if (plain.Read("a = 1") case .Err(let e))
		{
			Test.Assert(false);
		}
		Test.Assert(!plain.TryGetSourceRange("a", out range), "Positions are recorded only with PreserveStyle");
	}

	[Test]
	public static void Style_IntegerBaseChangesOutput()
	{
		let doc = ReadPreserving(scope .(), "mode = 493\nneg = -5\ns = \"x\"");
		Test.Assert(doc.RootTable.SetIntegerBase("mode", .Octal));
		Test.Assert(doc.SetIntegerBase("neg", .Hex));
		Test.Assert(!doc.RootTable.SetIntegerBase("s", .Hex), "Not an integer");

		String output = scope String();
		WriteChecked(doc, output);
		AssertContains(output, "mode = 0o755");
		AssertContains(output, "neg = -5");

		// The chosen base sticks when the value changes
		doc.RootTable.Set("mode", 420);
		String edited = scope String();
		WriteChecked(doc, edited);
		AssertContains(edited, "mode = 0o644");
	}
}
