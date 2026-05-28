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


	// ================================================================
	// Test helpers
	// ================================================================

	private static void AddAscii(List<uint8> bytes, StringView text)
	{
		for (int i = 0; i < text.Length; i++)
			bytes.Add((uint8)text[i]);
	}

	private static void AddByte(List<uint8> bytes, uint8 b)
	{
		bytes.Add(b);
	}

	private static void AddBytes(List<uint8> bytes, params uint8[] raw)
	{
		for (let b in raw)
			bytes.Add(b);
	}

	private static void AddRepeat(List<uint8> bytes, char8 c, int count)
	{
		for (int i = 0; i < count; i++)
			bytes.Add((uint8)c);
	}

	private static Result<void, TomlParseError> ReadFromByteStream(List<uint8> bytes)
	{
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		return doc.Read(ms);
	}

	private static void AssertReadErr(TomlErrorKind kind, Result<void, TomlParseError> result)
	{
		switch (result)
		{
		case .Ok: Test.Assert(false, "Expected error");
		case .Err(let e):
			defer e.Dispose();
			if (e.mKind != kind)
				Test.Assert(false, scope $"Expected {kind}, got {e.mKind}: {e.mMessage}");
		}
	}

	// ================================================================
	// Stream buffer boundary tests
	// ================================================================

	[Test]
	public static void Stream_CrlfCrossesBufferBoundary()
	{
		List<uint8> bytes = scope .();
		AddRepeat(bytes, '#', 8191);
		AddAscii(bytes, "\r\na = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Stream_LongCommentCrossesBufferBoundary()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# ");
		AddRepeat(bytes, 'x', 8192);
		AddAscii(bytes, "\na = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Stream_LongLiteralStringCrossesBufferBoundary()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "a = '");
		AddRepeat(bytes, 'x', 8192);
		AddAscii(bytes, "'\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetString("a", var val));
		Test.Assert(val.Length == 8192);
	}

	[Test]
	public static void Stream_LongBareKeyCrossesBufferBoundary()
	{
		List<uint8> bytes = scope .();
		AddRepeat(bytes, 'k', 8192);
		AddAscii(bytes, " = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	// ================================================================
	// UTF-8 validation tests
	// ================================================================

	[Test]
	public static void Utf8_StreamRejectsInvalidLeadByte()
	{
		List<uint8> bytes = scope .();
		AddByte(bytes, 0xFF);
		AddAscii(bytes, "\n");

		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsInvalidBytesInComment()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# ");
		AddByte(bytes, 0xFF);
		AddAscii(bytes, "\na = 1\n");

		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsTruncatedSequenceAtEof()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# ");
		AddByte(bytes, 0xC3);

		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsOverlongSequence()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "\"");
		AddByte(bytes, 0xC0);
		AddByte(bytes, 0xAF);
		AddAscii(bytes, "\"");

		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamAcceptsValidUtf8AcrossBuffer()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "a = \"");
		AddRepeat(bytes, 'x', 8185);
		AddByte(bytes, 0xC2);
		AddByte(bytes, 0xA9);
		AddAscii(bytes, "\"\n");

		var doc = new TomlDocument();
		defer delete doc;
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetString("a", var val));
		Test.Assert(val.Length == 8187);
	}

	// ================================================================
	// BOM tests
	// ================================================================

	[Test]
	public static void Bom_StreamPreservesContentAfterBom()
	{
		List<uint8> bytes = scope .();
		AddBytes(bytes, 0xEF, 0xBB, 0xBF);
		AddAscii(bytes, "a = 1\n");

		var doc = new TomlDocument();
		defer delete doc;
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		if (doc.Read(ms) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a", var val));
		Test.Assert(val == 1);
	}

	[Test]
	public static void Bom_DoubleBomRejected()
	{
		List<uint8> bytes = scope .();
		AddBytes(bytes, 0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF);

		AssertReadErr(.ControlCharInDocument, ReadFromByteStream(bytes));
	}

	// ================================================================
	// Stream I/O error tests
	// ================================================================

	[Test]
	public static void Stream_ErrorBeforeFirstByteReturnsIoError()
	{
		var stream = new FailingAfterBytesStream(0, "");
		defer delete stream;
		var doc = new TomlDocument();
		defer delete doc;
		AssertReadErr(.IoError, doc.Read(stream));
	}

	[Test]
	public static void Stream_ErrorMidStringReturnsIoError()
	{
		var stream = new FailingAfterBytesStream(4, "a = \"");
		defer delete stream;
		var doc = new TomlDocument();
		defer delete doc;
		AssertReadErr(.IoError, doc.Read(stream));
	}

	[Test]
	public static void PreserveStyle_DetectsDottedKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("server.port = 8080\nserver.host = 'localhost'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mPreferDottedKeys == true);
	}

	[Test]
	public static void PreserveStyle_DetectsNoDottedKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("port = 8080\nhost = 'localhost'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mPreferDottedKeys == false);
	}

	[Test]
	public static void PreserveStyle_DetectsDominantStringStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 3 literal strings, 1 basic string
		let input = "a = 'one'\nb = 'two'\nc = 'three'\nd = \"four\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);
	}

	[Test]
	public static void PreserveStyle_DetectsIndentation()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// TOML allows leading whitespace before keys.
		// First key at column 3 means 2-space indent.
		let input = "  a = 1\n  b = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mIndentSize == 2);
	}

	[Test]
	public static void PreserveStyle_IndentDefaultForTopLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Top-level keys at column 1 → indent stays at default
		let input = "a = 1\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mIndentSize == 4); // default
	}

	[Test]
	public static void PreserveStyle_DetectsCrlfNewlines()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\r\nb = 2\r\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .CRLF);
	}

	[Test]
	public static void PreserveStyle_DetectsLfNewlines()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\nb = 2\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .LF);
	}

	[Test]
	public static void PreserveStyle_DetectsMultilineArrayStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n  3,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultArrayStyle == .Multiline);
	}

	[Test]
	public static void PreserveStyle_DetectsInlineArrayStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [1, 2, 3]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultArrayStyle == .Inline);
	}

	[Test]
	public static void PreserveStyle_MixedNewlinesFavorsDominant()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 2 CRLF, 1 LF → CRLF dominant
		let input = "a = 1\r\nb = 2\r\nc = 3\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .CRLF);
	}

	[Test]
	public static void PreserveStyle_LfDominantOverCrlf()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 1 CRLF, 2 LF → LF dominant
		let input = "a = 1\r\nb = 2\nc = 3\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .LF);
	}

	[Test]
	public static void PreserveStyle_ArrayStringsCountForDominantStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 3 literals in array, 1 basic scalar
		let input = "arr = ['a', 'b', 'c']\nname = \"x\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);
	}

	[Test]
	public static void PreserveStyle_DefaultStringStyleBasic()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 2 basic strings, 1 literal
		let input = "a = \"one\"\nb = \"two\"\nc = 'three'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Basic);
	}

	[Test]
	public static void PreserveStyle_CapturesSpecialFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = inf\nb = +inf\nc = -inf\nd = nan\ne = +nan\nf = -nan", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 6);
		Test.Assert(metadata.mValueFormats.Count == 6);

		// All should be Special float format
		for (int i = 0; i < 6; i++)
		{
			let fmt = metadata.mValueFormats[i];
			if (fmt case .Float(let floatFmt))
				Test.Assert(floatFmt.mStyle == .Special);
			else
				Test.Assert(false, scope $"Expected Float format for node {i}");
		}
	}

	[Test]
	public static void PreserveStyle_EofCommentEmittedAfterContent()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\n\n# eof comment";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the comment was captured as footer
		Test.Assert(doc.Metadata.mFooterComments != null);
		Test.Assert(doc.Metadata.mFooterComments.mLeading.Count == 1);

		// Write and verify output order
		String output = scope String();
		doc.Write(output);

		// The comment should appear AFTER the content, not before
		int aPos = output.IndexOf("a = 1");
		int commentPos = output.IndexOf("# eof comment");
		Test.Assert(aPos >= 0);
		Test.Assert(commentPos >= 0);
		Test.Assert(commentPos > aPos, "EOF comment should appear after content, not before");
	}

	// ================================================================
	// PreserveStyle metadata tests
	// ================================================================

	[Test]
	public static void PreserveStyle_CapturesHexIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 0xDEAD_BEEF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let fmtRef = metadata.mNodeStyles[0].mValueFormatRef;
		Test.Assert(fmtRef.IsValid);
		let fmt = metadata.mValueFormats[fmtRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Hex);
			Test.Assert(intFmt.mUseUnderscores == true);
			Test.Assert(intFmt.mGroupSize == 4);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesOctalIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("mode = 0o755", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
			Test.Assert(intFmt.mBase == .Octal);
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesBinaryIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("flags = 0b1101_0010", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Binary);
			Test.Assert(intFmt.mUseUnderscores == true);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesUnderscoreDecimal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("pop = 1_000_000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Decimal);
			Test.Assert(intFmt.mUseUnderscores == true);
			Test.Assert(intFmt.mGroupSize == 3);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesScientificFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("val = 1E+06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mUppercaseExponent == true);
			Test.Assert(floatFmt.mExplicitPlusExponent == true);
		}
		else
			Test.Assert(false, "Expected Float format");
	}

	[Test]
	public static void PreserveStyle_CapturesDecimalFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("pi = 3.14", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
			Test.Assert(floatFmt.mStyle == .Decimal);
		else
			Test.Assert(false, "Expected Float format");
	}

	[Test]
	public static void PreserveStyle_RemoveThenReinsertDoesNotReuseOldToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 'old'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify original token is captured
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles[0].mOriginalValueToken.IsValid);

		// Remove and reinsert with a new value
		doc.RootTable.Remove("a");
		doc.RootTable.Insert("a", .String(new String("new")));

		// Writer should emit 'new', not 'old'
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("new"));
		Test.Assert(!output.Contains("old"));
	}

	[Test]
	public static void PreserveStyle_StreamLongStringCrossesBuffer()
	{
		// Build a string value that crosses the 8192-byte stream buffer
		List<uint8> bytes = scope .();
		AddAscii(bytes, "s = '");
		AddRepeat(bytes, 'x', 8190); // 8190 chars of 'x'
		AddAscii(bytes, "'");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);

		// Verify the captured token is correct
		let token = doc.Metadata.GetOriginalToken(style.mOriginalValueToken);
		Test.Assert(token.Length == 8192, scope $"Expected 8192, got {token.Length}"); // ' + 8190 x's + '
		Test.Assert(token[0] == '\'');
		Test.Assert(token[token.Length - 1] == '\'');

		// Verify the writer reuses the token
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Length > 8190);
		Test.Assert(output.Contains("'xxxxxxxxxx"));
	}

	[Test]
	public static void PreserveStyle_NoneModeHasNoMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("a = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata == null);
	}

	[Test]
	public static void PreserveStyle_AllocatesMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
	}

	[Test]
	public static void PreserveStyle_CapturesStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "s = \"hello world\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		let token = metadata.GetOriginalToken(style.mOriginalValueToken);
		Test.Assert(token == "\"hello world\"");
	}

	[Test]
	public static void PreserveStyle_CapturesMultilineStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "s = \"\"\"line1\nline2\"\"\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		let token = metadata.GetOriginalToken(style.mOriginalValueToken);
		// Raw token should include the triple-quote delimiters
		Test.Assert(token.StartsWith("\"\"\""));
		Test.Assert(token.EndsWith("\"\"\""));
	}

	[Test]
	public static void PreserveStyle_NoTokenForInteger()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 42", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		// Integers should not have original tokens captured (Stage 4: strings only)
		Test.Assert(!style.mOriginalValueToken.IsValid);
	}

	[Test]
	public static void PreserveStyle_MultipleKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = \"hello\"\nb = \"world\"\nc = 42";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		// 3 keys: a, b, c
		Test.Assert(metadata.mNodeStyles.Count == 3);
		// a and b are strings, should have tokens
		Test.Assert(metadata.mNodeStyles[0].mOriginalValueToken.IsValid);
		Test.Assert(metadata.mNodeStyles[1].mOriginalValueToken.IsValid);
		// c is integer, should not have token
		Test.Assert(!metadata.mNodeStyles[2].mOriginalValueToken.IsValid);
		// Verify token content
		Test.Assert(metadata.GetOriginalToken(metadata.mNodeStyles[0].mOriginalValueToken) == "\"hello\"");
		Test.Assert(metadata.GetOriginalToken(metadata.mNodeStyles[1].mOriginalValueToken) == "\"world\"");
	}

	[Test]
	public static void PreserveStyle_ReplaceClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = \"hello\"", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Re-read without PreserveStyle
		if (doc.Read("b = 1") case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-read failed: {reErr.mMessage}");
		}
		Test.Assert(doc.Metadata == null);
	}

	[Test]
	public static void PreserveStyle_CapturesStringFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = \"basic\"\nb = 'literal'\nc = \"\"\"multi\nline\"\"\"\nd = '''ml\nlit'''";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 4);

		// Check value formats
		Test.Assert(metadata.mValueFormats.Count == 4);

		// a = "basic" -> Basic
		let fmtA = metadata.mValueFormats[0];
		if (fmtA case .String(let fmtStr))
			Test.Assert(fmtStr.mStyle == .Basic);
		else
			Test.Assert(false, "Expected String format for a");

		// b = 'literal' -> Literal
		let fmtB = metadata.mValueFormats[1];
		if (fmtB case .String(let fmtStrB))
			Test.Assert(fmtStrB.mStyle == .Literal);
		else
			Test.Assert(false, "Expected String format for b");

		// c = """multi\nline""" -> MultilineBasic
		let fmtC = metadata.mValueFormats[2];
		if (fmtC case .String(let fmtStrC))
			Test.Assert(fmtStrC.mStyle == .MultilineBasic);
		else
			Test.Assert(false, "Expected String format for c");

		// d = '''ml\nlit''' -> MultilineLiteral
		let fmtD = metadata.mValueFormats[3];
		if (fmtD case .String(let fmtStrD))
			Test.Assert(fmtStrD.mStyle == .MultilineLiteral);
		else
			Test.Assert(false, "Expected String format for d");
	}

	[Test]
	public static void PreserveStyle_WriterReusesStringTokens()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Use a string with escape that the canonical writer would regenerate differently
		let input = "s = \"hello\\nworld\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify semantic value is correct
		Test.Assert(doc.TryGetString("s", var val));
		// The parsed value should have a literal newline
		Test.Assert(val == "hello\nworld");

		// Write with preserving mode
		String output = scope String();
		doc.Write(output);

		// The output should contain the original token, not a regenerated one
		// Original: "hello\nworld" (with backslash-n)
		// Canonical would produce: "hello\nworld" (same in this case, but let's verify exact match)
		Test.Assert(output.Contains("s = \"hello\\nworld\""));
	}

	[Test]
	public static void PreserveStyle_WriterReusesLiteralStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Literal string: backslash is literal
		let input = "path = 'C:\\Users\\test'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify semantic value
		Test.Assert(doc.TryGetString("path", var val));
		Test.Assert(val == "C:\\Users\\test");

		// Write
		String output = scope String();
		doc.Write(output);

		// Should preserve the literal string style with original token
		Test.Assert(output.Contains("path = 'C:\\Users\\test'"));
	}

	[Test]
	public static void PreserveStyle_WriterReusesMultilineToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "msg = \"\"\"Hello,\\nWorld!\"\"\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Should preserve the multiline basic string token exactly
		Test.Assert(output.Contains("msg = \"\"\"Hello,\\nWorld!\"\"\""));
	}

	[Test]
	public static void PreserveStyle_MutationMarksDirty()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("s = 'original'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify metadata exists and node is clean
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .None);

		// Mutate the value
		doc.RootTable.ReplaceValue("s", .String(new String("changed")));

		// Node should now be marked dirty
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .Value);

		// Writer should emit the new value, not the original token
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("changed"));
		Test.Assert(!output.Contains("original"));
	}

	[Test]
	public static void PreserveStyle_ReplaceReadTwice()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;

		// First read with PreserveStyle
		if (doc.Read("a = 'first'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"First read failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Second read with PreserveStyle (Replace mode)
		if (doc.Read("b = 'second'\nc = 'third'", config) case .Err(let read2Err))
		{
			defer read2Err.Dispose();
			Test.Assert(false, scope $"Second read failed: {read2Err.mMessage}");
		}
		// Metadata should be replaced with new document's metadata
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);
		Test.Assert(doc.RootTable.Count == 2);

		// Verify tokens are captured for new content
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'second'"));
		Test.Assert(output.Contains("'third'"));
	}

	[Test]
	public static void PreserveStyle_MergeClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;

		if (doc.Read("a = 'hello'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Setup failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// Merge — metadata should be cleared since merge-aware metadata is not yet implemented
		var mergeConfig = TomlReadConfig();
		mergeConfig.MetadataMode = .PreserveStyle;
		mergeConfig.Mode = .Merge;
		if (doc.Read("b = 'world'", mergeConfig) case .Err(let mergeErr))
		{
			defer mergeErr.Dispose();
			Test.Assert(false, scope $"Merge failed: {mergeErr.mMessage}");
		}
		// Metadata should be cleared after merge
		Test.Assert(doc.Metadata == null);
		// Semantic content should be merged
		Test.Assert(doc.RootTable.Count == 2);
	}

	[Test]
	public static void PreserveStyle_ErrorClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = ???invalid", config) case .Err(let e))
		{
			defer e.Dispose();
		}
		else
		{
			Test.Assert(false, "Expected parse error");
		}
		// Metadata should be cleaned up on error
		Test.Assert(doc.Metadata == null);
	}

	// ================================================================
	// Comment preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_LeadingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Check that the node has a leading comment
		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading comment");
	}

	[Test]
	public static void PreserveStyle_TrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 # trailing comment";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing == "trailing comment");
	}

	[Test]
	public static void PreserveStyle_LeadingAndTrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading\na = 1 # trailing";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading");
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing == "trailing");
	}

	[Test]
	public static void PreserveStyle_MultipleLeadingComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# comment 1\n# comment 2\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 2);
		Test.Assert(commentSet.mLeading[0] == "comment 1");
		Test.Assert(commentSet.mLeading[1] == "comment 2");
	}

	[Test]
	public static void PreserveStyle_CommentBeforeTableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# table comment\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// The server table should have the comment
		let serverTable = doc.RootTable.Entries["server"].AsTable;
		Test.Assert(serverTable.MetadataContext != null);
		let nodeId = serverTable.MetadataContext.mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "table comment");
	}

	[Test]
	public static void PreserveStyle_FileHeaderComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Blank line separates the comment from [server], making it a root comment
		let input = "# file header\n\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// The file header comment should be on the dedicated root comment set
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "file header");
	}

	[Test]
	public static void PreserveStyle_CommentEmission()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading\na = 1 # trailing";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Verify exact comment placement
		Test.Assert(output.Contains("# leading\na = 1 # trailing"));
	}

	[Test]
	public static void PreserveStyle_CommentOnMultpleKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# first comment\na = 1\n# second comment\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);

		// Check first key
		let nodeIdA = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSetA = doc.Metadata.GetCommentSet(nodeIdA);
		Test.Assert(commentSetA != null);
		Test.Assert(commentSetA.mLeading.Count == 1);
		Test.Assert(commentSetA.mLeading[0] == "first comment");

		// Check second key
		let nodeIdB = doc.Metadata.mNodeStyles[1].mNodeId;
		let commentSetB = doc.Metadata.GetCommentSet(nodeIdB);
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "second comment");
	}

	[Test]
	public static void PreserveStyle_EmptyTrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 #";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		// Trailing comment should exist (empty string, not null)
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing.IsEmpty);

		// Writer should emit the # marker
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("a = 1 #"));
	}

	[Test]
	public static void PreserveStyle_RootCommentDoesNotCollideWithFirstNode()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Blank line separates root comment from the leading comment for 'a'
		let input = "# root comment\n\n# first node comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Root comment should be on dedicated root comment set
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "root comment");

		// First node comment should be on first node (node ID 0)
		let firstNodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let firstComments = doc.Metadata.GetCommentSet(firstNodeId);
		Test.Assert(firstComments != null);
		Test.Assert(firstComments.mLeading.Count == 1);
		Test.Assert(firstComments.mLeading[0] == "first node comment");
	}

	[Test]
	public static void PreserveStyle_DetachedCommentSeparatedByBlankLine()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# detached comment\n\n# leading comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// Detached comment should be on root comment set (separated by blank line)
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "detached comment");

		// Leading comment should be on the key node
		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let nodeComments = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(nodeComments != null);
		Test.Assert(nodeComments.mLeading.Count == 1);
		Test.Assert(nodeComments.mLeading[0] == "leading comment");
	}

	[Test]
	public static void PreserveStyle_CommentEmissionExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading\na = 1 # trailing";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output assertion
		let expected = "# leading\na = 1 # trailing\n";
		Test.Assert(output == expected, scope $"Expected:\n{expected}\nGot:\n{output}");
	}

	[Test]
	public static void PreserveStyle_DetachedAfterContentStaysWithNextNode()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\n\n# note for b\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);

		// 'a' should have no comments
		let nodeIdA = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSetA = doc.Metadata.GetCommentSet(nodeIdA);
		Test.Assert(commentSetA == null || commentSetA.mLeading.Count == 0);

		// 'b' should have the comment (detached after content stays with next node)
		let nodeIdB = doc.Metadata.mNodeStyles[1].mNodeId;
		let commentSetB = doc.Metadata.GetCommentSet(nodeIdB);
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "note for b");

		// Root comments should be empty (no pre-content detached comments)
		Test.Assert(doc.Metadata.mRootComments == null || doc.Metadata.mRootComments.mLeading.Count == 0);
	}

	[Test]
	public static void PreserveStyle_EmptyTrailingCommentExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 #";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output: should be 'a = 1 #' with no trailing space
		let expected = "a = 1 #\n";
		Test.Assert(output == expected, scope $"Expected: '{expected}' Got: '{output}'");
	}

	[Test]
	public static void PreserveStyle_CommentedTableHeaderExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# server config\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output: no leading blank line, comment directly before [server]
		let expected = "# server config\n[server]\nport = 8080\n";
		Test.Assert(output == expected, scope $"Expected:\n{expected}\nGot:\n{output}");
	}

	[Test]
	public static void PreserveStyle_StreamCommentAtEof()
	{
		// Build a comment at EOF (no trailing newline)
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# eof comment");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;

		// First parse without metadata to establish a value
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 1", config) case .Err(let setupErr))
		{
			defer setupErr.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {setupErr.mMessage}");
		}

		// Parse the stream comment (EOF without newline)
		if (doc.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// The comment should be captured correctly (trimmed leading space)
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mRootComments != null);
		Test.Assert(doc.Metadata.mRootComments.mLeading.Count == 1);
		Test.Assert(doc.Metadata.mRootComments.mLeading[0] == "eof comment");
	}
}

class FailingAfterBytesStream : Stream
{
	private int mFailAfter;
	private String mData;
	private int mPos;

	public this(int failAfter, StringView initialData)
	{
		mFailAfter = failAfter;
		mData = new String(initialData);
		mPos = 0;
	}

	public ~this()
	{
		delete mData;
	}

	public override int64 Position
	{
		get => mPos;
		set => mPos = (int)value;
	}

	public override int64 Length => mData.Length;
	public override bool CanRead => true;
	public override bool CanWrite => false;

	public override Result<int> TryRead(Span<uint8> data)
	{
		if (mPos >= mFailAfter)
			return .Err;

		int remaining = mData.Length - mPos;
		if (remaining <= 0)
			return .Err;

		int allowed = mFailAfter - mPos;
		int toCopy = Math.Min(data.Length, Math.Min(remaining, allowed));
		for (int i = 0; i < toCopy; i++)
			data[i] = (uint8)mData[mPos + i];
		mPos += toCopy;
		return toCopy;
	}

	public override Result<int> TryWrite(Span<uint8> data)
	{
		return .Err;
	}

	public override Result<void> Close()
	{
		return .Ok;
	}
}
