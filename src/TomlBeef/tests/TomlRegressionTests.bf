using System;
using System.Collections;
using System.Globalization;
using System.IO;
using TomlBeef;

namespace TomlBeef;

/// Regressions for the failures found by the 2026-09-30 parser review (docs/review.md, B1–B11). Each
/// input is checked in memory and, where reading differs, through a stream with a small buffer.
static class TomlRegressionTests
{
	const TomlMetadataMode[3] cMetadataModes = .(.None, .Positions, .PreserveStyle);

	/// Reads `input` from memory and through a 16-byte stream buffer; both must agree: the same error
	/// at the same place, or equal documents (and with PreserveStyle the same written text).
	static Result<void, TomlParseError> ReadBoth(TomlDocument doc, StringView input, TomlReadConfig config)
	{
		let fromMemory = doc.Read(input, config);
		// An error's message lives in a per-thread buffer the next read reuses
		let memoryMessage = scope String();
		if (fromMemory case .Err(let memoryErr))
			memoryMessage.Append(memoryErr.mMessage);
		var streamConfig = config;
		streamConfig.StreamBufferBytes = 16;
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>((uint8*)input.Ptr, input.Length));
		ms.Position = 0;
		let streamed = scope TomlDocument();
		let fromStream = streamed.Read(ms, streamConfig);
		switch ((fromMemory, fromStream))
		{
		case (.Ok, .Ok):
			Test.Assert(TomlTestSupport.TomlDocumentEquals(doc, streamed), scope $"Memory and stream reads decode differently: {input}");
			if (config.MetadataMode == .PreserveStyle)
			{
				let memoryText = doc.Write(.. scope String());
				let streamText = streamed.Write(.. scope String());
				Test.Assert(memoryText == streamText, scope $"Memory and stream reads write differently: {memoryText} vs {streamText}");
			}
			return .Ok;
		case (.Err(let a), .Err(let b)):
			Test.Assert(a.mKind == b.mKind && a.mLine == b.mLine && a.mColumn == b.mColumn && a.mOffset == b.mOffset,
				scope $"Memory {a.mLine}:{a.mColumn}@{a.mOffset} ({memoryMessage}) vs stream {b.mLine}:{b.mColumn}@{b.mOffset} ({b.mMessage})");
			return .Err(a);
		default:
			Test.Assert(false, scope $"Memory and stream reads disagree on: {input}");
			return fromMemory;
		}
	}

	static void AssertRejected(StringView input, TomlReadConfig config = .())
	{
		for (let mode in cMetadataModes)
		{
			var modeConfig = config;
			modeConfig.MetadataMode = mode;
			let doc = scope TomlDocument();
			Test.Assert(ReadBoth(doc, input, modeConfig) case .Err, scope $"Accepted in {mode}: {input}");
		}
	}

	static void AssertString(StringView input, StringView expected)
	{
		for (let mode in cMetadataModes)
		{
			let doc = scope TomlDocument();
			if (ReadBoth(doc, input, .() { MetadataMode = mode }) case .Err(let err))
				Test.Assert(false, scope $"{err.mMessage}: {input}");
			Test.Assert(doc.TryGetString("v", var value) && value == expected, scope $"Read {value} for {input}");
		}
	}

	// B1: scientific floats keep every digit through PreserveStyle and the style API

	[Test]
	public static void B1_ScientificFloatsKeepTheirValue()
	{
		const String input = "a = 3.141592653589793e0\nb = 1.2345678901234567e10\nc = 5e-324\nd = 1.7976931348623157e308\ne = 1E+05\nf = -2.5e-3\n";
		let doc = scope TomlDocument();
		Test.Assert(doc.Read(input, .() { MetadataMode = .PreserveStyle }) case .Ok);
		let output = doc.Write(.. scope String());
		// Every value reads back the same (the text may be a shorter spelling of the same double)
		let unchanged = scope TomlDocument();
		Test.Assert(unchanged.Read(output) case .Ok, output);
		Test.Assert(TomlTestSupport.TomlDocumentEquals(doc, unchanged), output);
		Test.Assert(output.Contains("a = 3.141592653589793e0\n") && output.Contains("e = 1E+05\n") && output.Contains("f = -2.5e-3\n"), output);

		// Values chosen by the style API, and values changed after reading, are exact too
		Test.Assert(doc.SetFloatNotation("a", .Scientific));
		doc.Set("b", 0.1 + 0.2);
		doc.Set("x", 123.456);
		Test.Assert(doc.SetFloatNotation("x", .Scientific));
		output.Clear();
		doc.Write(output);
		let copy = scope TomlDocument();
		Test.Assert(copy.Read(output) case .Ok, output);
		for (let key in StringView[]("a", "b", "c", "d", "e", "f", "x"))
		{
			double expected = 0, actual = 0;
			Test.Assert(doc.TryGetFloat(key, out expected) && copy.TryGetFloat(key, out actual), scope String(key));
			Test.Assert(expected == actual,scope $"{key}: {expected} became {actual} in {output}");
		}
		// b keeps its captured exponent width (e10)
		Test.Assert(output.Contains("b = 3.0000000000000004e-01") &&output.Contains("x = 1.23456e2"), output);
	}

	// B2: key paths count toward MaxDepth, so no table tree outgrows the recursive walks

	[Test]
	public static void B2_DeepKeyPathsHitMaxDepth()
	{
		let dotted = scope String("v = {");
		for (int i < 100000)
			dotted.Append("a.");
		dotted.Append("z = 1}\n");
		let doc = scope TomlDocument();
		switch (doc.Read(dotted, .() { MaxDepth = 2 }))
		{
		case .Ok: Test.Assert(false);
		case .Err(let err): Test.Assert(err.mKind == .MaxDepthExceeded && err.mOffset < 16, scope $"{err.mOffset}");
		}

		// The default limit (256) covers headers and dotted keys too
		let header = scope String("[");
		for (int i < 300)
			header.Append(i == 0 ? "k" : ".k");
		header.Append("]\n");
		Test.Assert(doc.Read(header) case .Err(let headerErr) && headerErr.mKind == .MaxDepthExceeded);
		// Containers only: a, b, c, d (the inline table), e; f is a scalar
		Test.Assert(doc.Read("[a.b]\nc.d = { e.f = 1 }\n", .() { MaxDepth = 5 }) case .Ok);
		Test.Assert(doc.Read("[a.b]\nc.d = { e.f = 1 }\n", .() { MaxDepth = 4 }) case .Err);
	}

	// B12: MaxDepth counts every container from the root, whichever syntax built it: header segments,
	// the array and element of each array of tables, dotted-key tables, arrays and inline tables

	[Test]
	public static void B12_MaxDepthCountsEveryContainer()
	{
		// (input, deepest container) pairs: accepted at that depth, rejected one below
		let cases = StringView[](
			"[a]\nv=[[]]\n", "3",
			"a.b=[[]]\n", "3",
			"[[a]]\n", "2",
			"[[a]]\n[[a.b]]\n", "4",
			"[[a]]\n[a.b]\n", "3",
			"[[a]]\nb.c = [{ d = [] }]\n", "6",
			"v = [1, 2]\n", "1",
			"a.b.c = 1\n", "2",
			"v = [[{ a.b = {} }]]\n", "5");
		for (int i = 0; i < cases.Count; i += 2)
		{
			let input = cases[i];
			let depth = int.Parse(cases[i + 1]).Value;
			for (let mode in cMetadataModes)
			{
				Test.Assert(ReadBoth(scope TomlDocument(), input, .() { MaxDepth = depth, MetadataMode = mode }) case .Ok, scope $"Rejected at {depth}: {input}");
				if (depth == 1)
					continue; // MaxDepth = 0 means unlimited
				switch (ReadBoth(scope TomlDocument(), input, .() { MaxDepth = depth - 1, MetadataMode = mode }))
				{
				case .Ok: Test.Assert(false, scope $"Accepted at {depth - 1}: {input}");
				case .Err(let err): Test.Assert(err.mKind == .MaxDepthExceeded, scope $"{err.mKind} for {input}");
				}
			}
		}
	}

	// B13: a dotted key checks the table it would add an entry to before its value is parsed

	[Test]
	public static void B13_DottedKeysCheckTableRoomFirst()
	{
		// The invalid escape shows whether the value was parsed: a full table must fail first
		let inputs = StringView[](
			"a=1\nb.c=\"\\q\"\n",
			"a.b=1\na.c=\"\\q\"\n",
			"v={a=1,b.c=\"\\q\"}\n",
			"v={a.b=1,a.c=\"\\q\"}\n",
			"[t]\na=1\nb.c.d=\"\\q\"\n");
		for (let input in inputs)
		{
			for (let mode in cMetadataModes)
			{
				switch (ReadBoth(scope TomlDocument(), input, .() { MaxTableEntries = 1, MetadataMode = mode }))
				{
				case .Ok: Test.Assert(false, scope String(input));
				case .Err(let err): Test.Assert(err.mKind == .ResourceLimitExceeded, scope $"{err.mKind} for {input}");
				}
			}
		}

		// Room below an existing full table's child is fine: `a` is full, but `a.b` has space
		Test.Assert(scope TomlDocument().Read("a.b.x=1\na.b.y=2\n", .() { MaxTableEntries = 2 }) case .Ok);
		// Existing keys need no room: a merge overwrite through a dotted path
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("a.b=1\n") case .Ok);
		Test.Assert(doc.Read("a.b=2\n", .() { Mode = .Merge, OnConflict = .Overwrite, MaxTableEntries = 1 }) case .Ok);
	}

	// B3: an array-of-tables header cannot extend an inline table or a static array

	[Test]
	public static void B3_HeadersCannotExtendSealedTables()
	{
		AssertRejected("a = {}\n[[a.b]]\nx = 1\n");
		AssertRejected("a = [{}]\n[[a.b]]\nx = 1\n");
		AssertRejected("a = [{}]\n[a.b]\nx = 1\n");
		AssertRejected("a = [{b = {}}]\n[a.b.c]\n");
		AssertRejected("a = {}\n[[a.b]]\nx = 1\n", .() { Version = .V1_0 });
	}

	// B4: a line-ending backslash trims all whitespace up to the next content, blank lines included

	[Test]
	public static void B4_ContinuationsTrimIndentedBlankLines()
	{
		AssertString("v = \"\"\"a\\\n  \n  b\"\"\"\n", "ab");
		AssertString("v = \"\"\"a\\ \t\r\n\t\r\n \r\n\n  b\"\"\"\n", "ab");
		AssertString("v = \"\"\"a\\\n\n\n\"\"\"\n", "a");
		AssertString("v = \"\"\"a \\\n   b \\\n\tc\"\"\"\n", "a b c");
	}

	// B5: TOML newlines are LF or CRLF; a bare CR is never one

	[Test]
	public static void B5_MultilineStringsRejectBareCr()
	{
		AssertRejected("v = \"\"\"\rabc\"\"\"\n");
		AssertRejected("v = '''\rabc'''\n");
		AssertRejected("v = \"\"\"a\\\rb\"\"\"\n");
		AssertRejected("v = \"\"\"a\\\n\rb\"\"\"\n");
		AssertString("v = \"\"\"\r\nabc\"\"\"\n", "abc");
		AssertString("v = '''\r\nabc'''\n", "abc");
	}

	// B6: TOML 1.0 inline tables have no room for comments (a comment needs a newline)

	[Test]
	public static void B6_Toml10RejectsCommentsInInlineTables()
	{
		let inputs = StringView[](
			"v = { # c\na = 1 }\n",
			"v = { a = 1 # c\n}\n",
			"v = { a = 1, # c\nb = 2 }\n",
			"v = { a = 1, b = 2 # c\n}\n");
		for (let input in inputs)
		{
			AssertRejected(input, .() { Version = .V1_0 });
			for (let mode in cMetadataModes)
				Test.Assert(ReadBoth(scope TomlDocument(), input, .() { MetadataMode = mode }) case .Ok, scope String(input));
		}
	}

	// B7: limits stop reading where they are crossed, not after building the oversized part

	[Test]
	public static void B7_LimitsStopEarly()
	{
		let bigString = scope String("v = \"");
		bigString.Append('x', 1 << 20);
		bigString.Append("\"\n");
		let bigLiteral = scope String("v = '''");
		bigLiteral.Append('x', 1 << 20);
		bigLiteral.Append("'''\n");
		let bigItem = scope String("v = [1, \"");
		bigItem.Append('x', 1 << 20);
		bigItem.Append("\"]\n");
		let manySegments = scope String("k");
		for (int i < 100000)
			manySegments.Append(".k");
		manySegments.Append(" = 1\n");
		let fullTable = scope String("a = 1\nb = \"");
		fullTable.Append('x', 1 << 20);
		fullTable.Append("\"\n");

		void Check(StringView input, TomlReadConfig config, int maxOffset)
		{
			let doc = scope TomlDocument();
			switch (ReadBoth(doc, input, config))
			{
			case .Ok: Test.Assert(false, "Expected a limit error");
			case .Err(let err): Test.Assert(err.mKind == .ResourceLimitExceeded && err.mOffset <= maxOffset, scope $"Stopped at {err.mOffset}: {err.mMessage}");
			}
		}
		Check(bigString, .() { MaxStringBytes = 8 }, 32);
		Check(bigLiteral, .() { MaxStringBytes = 8 }, 32);
		Check(bigItem, .() { MaxArrayItems = 1 }, 8);
		Check(manySegments, .() { MaxPathSegments = 4 }, 16);
		Check(fullTable, .() { MaxTableEntries = 1 }, 6);

		// A merge that overwrites an existing key needs no room
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("a = 1\n") case .Ok);
		Test.Assert(doc.Read("a = 2\n", .() { Mode = .Merge, OnConflict = .Overwrite, MaxTableEntries = 1 }) case .Ok);
	}

	// B8: a BOM shifts nothing but offsets, in memory and streamed, before and after refills

	[Test]
	public static void B8_BomStreamsReportUtf8ErrorsWhereTheyAre()
	{
		void Check(List<uint8> bytes, int line, int column, int offset)
		{
			for (int bufferBytes in int[](16, 0))
			{
				let ms = scope MemoryStream(bytes, false);
				switch (scope TomlDocument().Read(ms, .() { StreamBufferBytes = bufferBytes }))
				{
				case .Ok: Test.Assert(false);
				case .Err(let err): Test.Assert(err.mLine == line && err.mColumn == column && err.mOffset == offset, scope $"Streamed ({bufferBytes}): {err.mLine}:{err.mColumn}@{err.mOffset}");
				}
			}
			switch (scope TomlDocument().ReadBytes(Span<uint8>(bytes.Ptr, bytes.Count)))
			{
			case .Ok: Test.Assert(false);
			case .Err(let err): Test.Assert(err.mLine == line && err.mColumn == column && err.mOffset == offset, scope $"In memory: {err.mLine}:{err.mColumn}@{err.mOffset}");
			}
		}

		let bytes = scope List<uint8>();
		void Add(StringView text) { for (let c in text.RawChars) bytes.Add((uint8)c); }

		bytes.Add(0xEF); bytes.Add(0xBB); bytes.Add(0xBF);
		Add("v = \"");
		bytes.Add(0xFF);
		Add("\"\n");
		Check(bytes, 1, 6, 8);

		bytes.Clear();
		bytes.Add(0xEF); bytes.Add(0xBB); bytes.Add(0xBF);
		Add("#prefix\n");
		for (int i < 9000)
			bytes.Add((uint8)' ');
		Add("v = \"");
		bytes.Add(0xFF);
		Add("\"\n");
		Check(bytes, 2, 9006, 3 + 8 + 9005);

		// A sequence split across refills and broken by a byte that does not continue it: reported at
		// its lead byte (FormatCore's validator, the same in memory and streamed), after a BOM and across
		// buffer boundaries
		bytes.Clear();
		bytes.Add(0xEF); bytes.Add(0xBB); bytes.Add(0xBF);
		Add("v = \"abcdefgh");
		bytes.Add(0xE2); bytes.Add(0x82);
		Add("\"\n");
		Check(bytes, 1, 14, 16);
	}

	// B9: an inline table inside an array keeps its layout

	[Test]
	public static void B9_InlineTablesInArraysKeepTheirLayout()
	{
		// (A single-line layout drops a trailing comma, as it does for a key's inline table)
		let cases = StringView[](
			"v = [{x=1,y=2,}]\n", "v = [{x=1,y=2}]\n",
			"v = [{ x = 1 }, {y=2}]\n", "v = [{ x = 1 }, {y=2}]\n",
			"v = [[{a=1}]]\n", "v = [[{a=1}]]\n",
			// A multi-line element does not make its array multi-line
			"v = [{\n  a=1,\n}]\n", "v = [{\n  a=1,\n}]\n");
		for (int i = 0; i < cases.Count; i += 2)
		{
			let input = cases[i];
			let expected = cases[i + 1];
			let doc = scope TomlDocument();
			Test.Assert(doc.Read(input, .() { MetadataMode = .PreserveStyle }) case .Ok);
			let output = doc.Write(.. scope String());
			Test.Assert(output == expected, output);
		}

		// Written as TOML 1.0, the table goes on one line without its trailing comma
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("v = [{\n  x=1,\n  y=2,\n}]\n", .() { MetadataMode = .PreserveStyle }) case .Ok);
		let output = doc.Write(.. scope String(), .() { Version = .V1_0 });
		let reread = scope TomlDocument();
		Test.Assert(reread.Read(output, .() { Version = .V1_0 }) case .Ok, output);
	}

	// Nested multi-line layouts (status.md O15): read from the container's own separators, written with
	// every level indented under the line it opens on

	[Test]
	public static void NestedMultilineContainersKeepTheirIndentation()
	{
		const String nested = """
			w = [
			  1,
			  [
			    2,
			  ],
			  { a = "x, y = z", b = [
			    3,
			  ] },
			]
			t = {
			  a = [
			    1,
			  ],
			  b = { c = 1 },
			}

			""";
		let doc = scope TomlDocument();
		Test.Assert(doc.Read(nested, .() { MetadataMode = .PreserveStyle }) case .Ok);
		let output = doc.Write(.. scope String());
		Test.Assert(output == nested, output);

		// Punctuation inside strings and nested values does not change the table's own layout
		let formats = scope TomlDocument();
		Test.Assert(formats.Read("t = {a=\"x = y, z\",b=[1, 2]}\n", .() { MetadataMode = .PreserveStyle }) case .Ok);
		output.Clear();
		formats.Write(output);
		Test.Assert(output == "t = {a=\"x = y, z\",b=[1, 2]}\n", output);

		// A new array nested in one read from the source is written like its siblings, and reads back
		Test.Assert(doc.TryGetArray("w", var w));
		let added = w.AddArray();
		added.Add(4);
		added.Add(5);
		output.Clear();
		doc.Write(output);
		let reread = scope TomlDocument();
		Test.Assert(reread.Read(output) case .Ok, output);
		Test.Assert(reread.TryGetArray("w", var rw) && rw.Count == 4, output);
		Test.Assert(output.Contains("\n  [\n    4,\n    5,\n  ],\n"), output);
	}

	// B10: changing the sign of zero is a change

	[Test]
	public static void B10_SignedZeroChangesAreWritten()
	{
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("z = 0.0\na = [0.0]\n", .() { MetadataMode = .PreserveStyle }) case .Ok);
		doc.Set("z", -0.0);
		Test.Assert(doc.TryGetArray("a", var arr));
		arr[0] = -0.0;
		let output = doc.Write(.. scope String());
		Test.Assert(output == "z = -0.0\na = [-0.0]\n", output);
		doc.Set("z", 0.0);
		output.Clear();
		doc.Write(output);
		Test.Assert(output.StartsWith("z = 0.0\n"), output);

		// A merge overwrite too
		Test.Assert(doc.Read("z = -0.0\n", .() { Mode = .Merge, OnConflict = .Overwrite }) case .Ok);
		output.Clear();
		doc.Write(output);
		Test.Assert(output.StartsWith("z = -0.0\n"), output);
	}

	// B11: exact paths reach the empty key

	[Test]
	public static void B11_GetPathReachesEmptyKeys()
	{
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("[a]\n\"\" = 2\n[\"\".b]\nc = 3\n") case .Ok);
		Test.Assert(doc.GetPath("") case .Ok(let root) && root.IsTable);
		Test.Assert(doc.GetPath("a", "") case .Ok(let nested) && nested.AsInteger == 2);
		let segments = scope List<StringView>() { "", "b", "c" };
		Test.Assert(doc.GetPath(segments) case .Ok(let deep) && deep.AsInteger == 3);
		Test.Assert(doc.GetPath("a", "missing") case .Err);
		Test.Assert(doc.GetPath() case .Err);
	}

	// UTF-16 input is named as such (FormatCore's input start), not reported as invalid UTF-8 at offset 0,
	// in memory and streamed

	[Test]
	public static void Utf16InputIsNamed()
	{
		uint8[?] utf16 = .(0xFF, 0xFE, (uint8)'a', 0, (uint8)'=', 0, (uint8)'1', 0);
		let doc = scope TomlDocument();
		Test.Assert(doc.ReadBytes(Span<uint8>(&utf16, utf16.Count)) case .Err(let memoryErr));
		Test.Assert(memoryErr.mKind == .UnsupportedEncoding && memoryErr.mMessage.Contains("UTF-16LE"), scope $"{memoryErr}");
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(&utf16, utf16.Count));
		ms.Position = 0;
		Test.Assert(doc.Read(ms) case .Err(let streamErr));
		Test.Assert(streamErr.mKind == .UnsupportedEncoding, scope $"{streamErr}");
	}

	// FormatCore B3: a table's hash index (past 8 keys) was unseeded, so keys crafted to collide could
	// be prepared in advance (hash flooding). It is FormatCore's OrderedMap now, seeded per table.

	[Test]
	public static void TableIndexesAreSeededPerTable()
	{
		let input = scope String();
		for (int t < 2)
		{
			input.AppendF("[t{}]\n", t);
			for (int k < 20)
				input.AppendF("key_{} = {}\n", k, k);
		}
		let doc = scope TomlDocument();
		Test.Assert(doc.Read(input) case .Ok);
		Test.Assert(doc.RootTable.TryGetTable("t0", let first));
		Test.Assert(doc.RootTable.TryGetTable("t1", let second));
		uint64 seed0 = first.[Friend]mEntries.IndexSeed;
		uint64 seed1 = second.[Friend]mEntries.IndexSeed;
		Test.Assert(first.[Friend]mEntries.IsIndexed && seed0 != 0 && seed1 != 0 && seed0 != seed1);
		// Every key is still found through the index
		// (One key string per round: two `scope $"..."` in one `&&` failed under the Windows Debug runtime)
		for (int k < 20)
		{
			let key = scope String()..AppendF("key_{}", k);
			Test.Assert(first.GetInteger(key, -1) == k);
			Test.Assert(second.GetInteger(key, -1) == k);
		}
	}

	// FormatCore B2: floats off the fast path (underscores, more digits than an exact mantissa) were
	// parsed by corlib's Double.Parse, which follows the current culture's decimal separator

	[Test]
	public static void FloatsIgnoreTheCurrentCulture()
	{
		let culture = scope CultureInfo("de-DE");
		let format = new NumberFormatInfo();
		format.NumberDecimalSeparator = ",";
		culture.[Friend]mNumInfo = format;
		let saved = CultureInfo.CurrentCulture;
		CultureInfo.CurrentCulture = culture;
		defer { CultureInfo.CurrentCulture = saved; }
		Test.Assert(!(double.Parse("1.5") case .Ok(1.5)));

		let doc = scope TomlDocument();
		Test.Assert(doc.Read("a = 1_000.5\nb = 1.50000000000000000000001\nc = 6.02e+2_3\nd = +1.5\n") case .Ok);
		Test.Assert(doc.RootTable.GetFloat("a", 0) == 1000.5);
		Test.Assert(doc.RootTable.GetFloat("b", 0) == 1.5);
		Test.Assert(doc.RootTable.GetFloat("c", 0) == 6.02e23);
		Test.Assert(doc.RootTable.GetFloat("d", 0) == 1.5);
	}
}
