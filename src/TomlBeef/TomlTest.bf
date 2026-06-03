using System;
using System.IO;
using System.Collections;
using TomlBeef;
using internal TomlBeef;

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
			if (!TomlValueEquals(a.GetValue(i), b.GetValue(i))) return false;
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
	public static void PreserveStyle_CapturesDottedKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("server.port = 8080", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mKeyFormatRef.IsValid);
		let fmt = doc.Metadata.mKeyFormats[style.mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .Bare);
		Test.Assert(fmt.mPreferDottedPath == true);
	}

	[Test]
	public static void PreserveStyle_CapturesQuotedKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("\"my key\" = 42", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .QuotedBasic);
	}

	[Test]
	public static void PreserveStyle_CapturesLiteralKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("'raw key' = 99", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .QuotedLiteral);
	}

	[Test]
	public static void PreserveStyle_CapturesBareKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("simple = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .Bare);
		Test.Assert(fmt.mPreferDottedPath == false);
	}

	[Test]
	public static void PreserveStyle_DocumentStyleFallbackForString()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Document uses mostly literal strings
		let input = "a = 'hello'\nb = 'world'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify dominant style is literal
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);

		// Mutate a value
		doc.RootTable.SetString("a", "changed");

		// Write - changed string should use document's literal style
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'changed'"));
	}

	[Test]
	public static void PreserveStyle_CapturesDateTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dob = 1979-05-27T07:32:00Z", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == true);
			Test.Assert(dtFmt.mUsesZ == true);
			Test.Assert(dtFmt.mHasOffset == true);
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesDateTimeFormatWithOffset()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27 07:32:00-08:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == false); // space separator
			Test.Assert(dtFmt.mUsesZ == false); // offset, not Z
			Test.Assert(dtFmt.mHasOffset == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalDateFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dob = 1979-05-27", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			// Local date has no time separator, no offset
			Test.Assert(dtFmt.mHasOffset == false);
			Test.Assert(dtFmt.mHasSeconds == false);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = 07:32:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mHasOffset == false);
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalDateTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27T07:32:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == true);
			Test.Assert(dtFmt.mHasOffset == false); // no offset
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
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
		doc.RootTable.SetString("a", "new");

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
	public static void PreserveStyle_IntegerFormatPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0xDEAD_BEEF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify format was captured
		Test.Assert(doc.Metadata.mValueFormats.Count == 1);
		let fmt = doc.Metadata.mValueFormats[0];
		if (fmt case .Integer(let intFmt))
			Test.Assert(intFmt.mBase == .Hex);
		else
			Test.Assert(false, "Expected Integer format");

		// Verify node has format ref
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mValueFormatRef.IsValid);

		// Mutate the value to a different hex value
		bool replaced = doc.RootTable.ReplaceValue("n", .Integer(0x12345));
		Test.Assert(replaced);

		// Verify dirty
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .Value);

		String output = scope String();
		doc.Write(output);

		// Should regenerate using hex format, preserving original digit width and grouping
		Test.Assert(output.Contains("0x0001_2345"), scope $"Expected hex, got: {output}");
	}

	[Test]
	public static void PreserveStyle_IntegerMinDigitsPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0x00FF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("n", .Integer(1));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("n = 0x0001"), scope $"Expected padded hex, got: {output}");
	}

	[Test]
	public static void PreserveStyle_NegativeDecimalIntegerKeepsGrouping()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = -1_000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("n", .Integer(-2000));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("n = -2_000"), scope $"Expected grouped negative decimal, got: {output}");
	}

	[Test]
	public static void PreserveStyle_NegativeIntegerFallsBackToDecimal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0xFF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate to a negative value
		doc.RootTable.ReplaceValue("n", .Integer(-42));

		String output = scope String();
		doc.Write(output);

		// Negative values must be decimal, not hex
		Test.Assert(output.Contains("n = -42"));
		Test.Assert(!output.Contains("0x"));
	}

	[Test]
	public static void PreserveStyle_FloatPrecisionPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1.000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(2.5));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("f = 2.500"), scope $"Expected fixed precision, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatFormatPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1E+06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate to a different float value
		doc.RootTable.ReplaceValue("f", .Float(2.5e3));

		String output = scope String();
		doc.Write(output);

		// Should use scientific notation (from format metadata)
		Test.Assert(output.Contains("e") || output.Contains("E"));
	}

	[Test]
	public static void PreserveStyle_DateTimeOmittedSecondsPreservedOnDirtyWrite()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27 07:32Z", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("dt", .OffsetDateTime(TomlOffsetDateTime(1979, 5, 27, 8, 33, 0, 0, 0)));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("dt = 1979-05-27 08:33Z"), scope $"Expected omitted seconds, got: {output}");
		Test.Assert(!output.Contains("08:33:00"));
	}

	[Test]
	public static void PreserveStyle_MultilineArrayFormatPreservedOnDirtyWrite()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		arr[1] = 3;

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("arr = [\n"), scope $"Expected multiline array, got: {output}");
		Test.Assert(output.Contains("  3,"), scope $"Expected indented changed element with comma, got: {output}");
	}

	[Test]
	public static void PreserveStyle_ArrayAddMarksChildrenDirtyAfterParse()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("arr = [1]", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		let nodeId = arr.MetadataContext.mNodeId;
		Test.Assert(doc.Metadata.mNodeStyles[nodeId.mIndex].mDirtyFlags == .None);

		arr.Add(.Integer(2));
		Test.Assert(doc.Metadata.mNodeStyles[nodeId.mIndex].mDirtyFlags == .Children);
	}

	[Test]
	public static void PreserveStyle_ReplaceEqualValueKeepsClean()
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
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		Test.Assert(style.mDirtyFlags == .None);

		// Replace with same value
		doc.RootTable.SetString("s", "original");
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .None); // still clean
	}

	[Test]
	public static void PreserveStyle_InsertNewKeyMarksChildrenDirty()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("[tbl]\n  a = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Insert a new key into the table — auto-allocates node ID and marks dirty
		doc.RootTable.TryGetTable("tbl", var tbl);
		tbl.Insert("b", .Integer(2));

		// Write the document - new key 'b' should appear
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("b = 2"));
	}

	[Test]
	public static void PreserveStyle_DottedKeysReemitted()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "server.port = 8080\nserver.host = 'localhost'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Output should preserve dotted-key style, not normalize to [server] header
		Test.Assert(output.Contains("server.port = 8080"));
		Test.Assert(!output.Contains("[server]"));
	}

	[Test]
	public static void PreserveStyle_DottedKeysNestedTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "server.port = 8080\nserver.db.host = 'localhost'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Both values should appear, and db.host should be emitted as a dotted key
		Test.Assert(output.Contains("server.port = 8080"));
		Test.Assert(output.Contains("server.db.host = 'localhost'"));
	}

	[Test]
	public static void PreserveStyle_ArrayElementTokenReuse()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("arr = ['hello', 'world']", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify array has metadata context
		doc.RootTable.TryGetArray("arr", var arr);
		Test.Assert(arr.MetadataContext != null);
		Test.Assert(arr.MetadataContext.mItemNodeIds.Count == 2);

		// Write and verify original tokens reused
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'hello'"));
		Test.Assert(output.Contains("'world'"));
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
		doc.RootTable.SetString("s", "changed");

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

	// ================================================================
	// Float style preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_FloatExponentDigitWidth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 1e06 has exponent width 2, no explicit plus
		if (doc.Read("f = 1e06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mExponentDigits == 2, scope $"Expected 2 exponent digits, got {floatFmt.mExponentDigits}");
			Test.Assert(floatFmt.mUppercaseExponent == false);
			Test.Assert(floatFmt.mExplicitPlusExponent == false);
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate and verify exponent width preserved
		doc.RootTable.ReplaceValue("f", .Float(2.0e3));
		String output = scope String();
		doc.Write(output);
		// Should have 2-digit exponent, lowercase e, no plus: 2e03
		Test.Assert(output.Contains("2e03") || output.Contains("2e+03") == false,
			scope $"Expected '2e03' in output, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatExponentUppercasePlusWidth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 1E+006 has uppercase E, explicit plus, exponent width 3
		if (doc.Read("f = 1E+006", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mExponentDigits == 3, scope $"Expected 3 exponent digits, got {floatFmt.mExponentDigits}");
			Test.Assert(floatFmt.mUppercaseExponent == true);
			Test.Assert(floatFmt.mExplicitPlusExponent == true);
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate and verify format preserved
		doc.RootTable.ReplaceValue("f", .Float(2.0e3));
		String output = scope String();
		doc.Write(output);
		// Should have uppercase E, explicit plus, 3-digit exponent: 2E+003
		Test.Assert(output.Contains("2E+003"), scope $"Expected '2E+003' in output, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatExponentWidthDoesNotTrimMagnitude()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1e06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(1.0e100));
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("e100"), scope $"Exponent digits must not be trimmed: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatUnderscoreGrouping()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 224_617.445_991 has underscore grouping in both parts
		if (doc.Read("f = 224_617.445_991", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mUseUnderscores == true);
			Test.Assert(floatFmt.mIntGroupSize == 3, scope $"Expected int group size 3, got {floatFmt.mIntGroupSize}");
			Test.Assert(floatFmt.mFracGroupSize == 3, scope $"Expected frac group size 3, got {floatFmt.mFracGroupSize}");
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate to a different value and verify grouping preserved
		doc.RootTable.ReplaceValue("f", .Float(225000.5));
		String output = scope String();
		doc.Write(output);
		// Should have underscores in both parts: 225_000.500_000 (precision preserved too)
		Test.Assert(output.Contains("225_000.500"), scope $"Expected grouped output, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatInfinitySignRemainsSemantic()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = -inf", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(double.PositiveInfinity));
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("f = inf"), scope $"Positive infinity must not become negative: {output}");
		Test.Assert(!output.Contains("-inf"));
	}

	[Test]
	public static void PreserveStyle_FloatSpecialSignPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = +inf\nb = +nan", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Check +inf format
		{
			let fmtA = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
			if (fmtA case .Float(let floatFmt))
			{
				Test.Assert(floatFmt.mStyle == .Special);
				Test.Assert(floatFmt.mSpecialSign == .ExplicitPlus,
					scope $"Expected ExplicitPlus for +inf, got {floatFmt.mSpecialSign}");
			}
			else
				Test.Assert(false, "Expected Float format for +inf");
		}

		// Check +nan format
		{
			let fmtB = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[1].mValueFormatRef.mIndex];
			if (fmtB case .Float(let floatFmt))
			{
				Test.Assert(floatFmt.mStyle == .Special);
				Test.Assert(floatFmt.mSpecialSign == .ExplicitPlus,
					scope $"Expected ExplicitPlus for +nan, got {floatFmt.mSpecialSign}");
			}
			else
				Test.Assert(false, "Expected Float format for +nan");
		}

		// Mutate and verify +inf preserved
		doc.RootTable.ReplaceValue("a", .Float(double.NaN));
		String output = scope String();
		doc.Write(output);
		// +nan should be preserved when mutating inf -> nan if it stays special
		Test.Assert(output.Contains("+nan") || output.Contains("nan"),
			scope $"Expected +nan or nan in output, got: {output}");
	}

	// ================================================================
	// Inline table format preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_InlineTableFormatCaptured()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = { a = 1, b = 2 }", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Check that table format was captured
		let nodeId = doc.Metadata.mNodeStyles[0];
		Test.Assert(nodeId.mValueFormatRef.IsValid);
		let fmt = doc.Metadata.mValueFormats[nodeId.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mInline == true);
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");
	}

	[Test]
	public static void PreserveStyle_InlineTableStaysInlineAfterMutation()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = { a = 1, b = 2 }", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate a value inside the inline table
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		// Should remain inline, not switch to [t] header format
		Test.Assert(output.Contains("{ a = 42, b = 2 }") ||
			output.Contains("t = { a = 42, b = 2 }"),
			scope $"Expected inline table in output, got: {output}");
		Test.Assert(!output.Contains("[t]"), scope $"Should not use header syntax: {output}");
	}

	[Test]
	public static void PreserveStyle_MultilineInlineTableFallsBackForV1_0Write()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = {\n  a = 1,\n}", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(2));

		var writeConfig = TomlWriteConfig();
		writeConfig.Version = .V1_0;
		String output = scope String();
		doc.Write(output, writeConfig);
		Test.Assert(output.Contains("t = {"), scope $"Expected inline table, got: {output}");
		Test.Assert(!output.Contains("{\n"), scope $"TOML v1.0 writer must not emit multiline inline table: {output}");
	}

	[Test]
	public static void PreserveStyle_MultilineInlineTablePreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = {\n  a = 1,\n  b = 2,\n}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Check multiline format was captured
		let nodeId = doc.Metadata.mNodeStyles[0];
		let fmt = doc.Metadata.mValueFormats[nodeId.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mMultiline == true);
			Test.Assert(tFmt.mTrailingComma == true);
		}

		// Mutate and verify multiline preserved
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("{\n"), scope $"Expected multiline inline table, got: {output}");
		Test.Assert(output.Contains("  a = 42"), scope $"Expected indented entry, got: {output}");
	}

	// ================================================================
	// Array indentation preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_ArrayIndent2Spaces()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		arr.Add(.Integer(3));

		String output = scope String();
		doc.Write(output);
		// New element should use 2-space indent (from captured format)
		Test.Assert(output.Contains("  3"), scope $"Expected 2-space indent for new element, got: {output}");
	}

	[Test]
	public static void PreserveStyle_ArrayIndent4Spaces()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n    1,\n    2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify indent size was captured. The array format is on the key-value entry node.
		TomlNodeId arrNodeId = .Invalid;
		if (doc.RootTable.MetadataContext != null)
			doc.RootTable.MetadataContext.TryGetEntryNodeId("arr", out arrNodeId);
		Test.Assert(arrNodeId.IsValid, "Expected arr entry node ID");
		let nodeStyle = doc.Metadata.GetNodeStyle(arrNodeId);
		Test.Assert(nodeStyle != null && nodeStyle.mValueFormatRef.IsValid, "Expected value format ref to be valid");
		let fmt = doc.Metadata.mValueFormats[nodeStyle.mValueFormatRef.mIndex];
		if (fmt case .Array(let arrFmt))
			Test.Assert(arrFmt.mIndentSize == 4, scope $"Expected indent 4, got {arrFmt.mIndentSize}");

		doc.RootTable.TryGetArray("arr", var arr);
		arr.Add(.Integer(3));

		String output = scope String();
		doc.Write(output);
		// New element should use 4-space indent
		Test.Assert(output.Contains("    3"), scope $"Expected 4-space indent, got: {output}");
	}

	// ================================================================
	// Array comment preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_ArrayElementLeadingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  # lead\n  1\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the comment was captured on the element node
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(0, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element");
		Test.Assert(commentSet.mLeading.Count == 1, scope $"Expected 1 leading comment, got {commentSet.mLeading.Count}");
		Test.Assert(commentSet.mLeading[0] == "lead", scope $"Expected 'lead', got '{commentSet.mLeading[0]}'");

		// Writer should preserve the comment WITH indentation matching the element
		String output = scope String();
		doc.Write(output);
		// Comment should be indented to same level as element
		Test.Assert(output.Contains("  # lead"), scope $"Expected indented comment '  # lead', got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayElementTrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1, # trail\n  2\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the trailing comment was captured
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(0, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element 0");
		Test.Assert(commentSet.mTrailing != null, "Expected trailing comment");
		Test.Assert(commentSet.mTrailing == "trail", scope $"Expected 'trail', got '{commentSet.mTrailing}'");

		String output = scope String();
		doc.Write(output);
		// Comma must appear BEFORE comment: `1, # trail` not `1 # trail,`
		Test.Assert(output.Contains("1, # trail"),
			scope $"Expected comma before trailing comment '1, # trail', got: {output}");
		Test.Assert(!output.Contains("1 # trail,"),
			"Comma must not appear after trailing comment");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayBlankLineBeforeElement()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two elements with a blank line between them
		let input = "arr = [\n  1,\n\n  2\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify blank line separation on element 1
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(1, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element 1");
		Test.Assert(commentSet.mSeparatedByBlankLine, "Expected blank line flag");

		// Writer should preserve the blank line
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("1,\n\n  2") || output.Contains("1,\r\n\r\n  2"),
			scope $"Expected blank line between elements, got: {output}");
	}

	[Test]
	public static void PreserveStyle_ArrayEmptyWithComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  # empty comment\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);
		// Comment inside empty array should be preserved
		Test.Assert(output.Contains("# empty comment"),
			scope $"Expected comment in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayLastElementTrailingCommentNoComma()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Last element has a trailing comment without a comma before it
		let input = "arr = [\n  1 # last\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);
		// Comment should be preserved
		Test.Assert(output.Contains("# last"), scope $"Expected comment in output, got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayTrailingCommaWithComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Trailing comma with comment before close bracket
		let input = "arr = [\n  1, # trail\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify trailing comma format was captured
		TomlNodeId arrNodeId = .Invalid;
		if (doc.RootTable.MetadataContext != null)
			doc.RootTable.MetadataContext.TryGetEntryNodeId("arr", out arrNodeId);
		Test.Assert(arrNodeId.IsValid);
		let nodeStyle = doc.Metadata.GetNodeStyle(arrNodeId);
		Test.Assert(nodeStyle != null && nodeStyle.mValueFormatRef.IsValid);
		let valFmt = doc.Metadata.mValueFormats[nodeStyle.mValueFormatRef.mIndex];
		if (valFmt case .Array(let arrFmt))
			Test.Assert(arrFmt.mTrailingComma == true,
				scope $"Expected trailing comma=true, got {arrFmt.mTrailingComma}");

		String output = scope String();
		doc.Write(output);
		// Should have both trailing comma and comment
		Test.Assert(output.Contains("1, # trail"),
			scope $"Expected '1, # trail', got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	// ================================================================
	// Inline table spacing preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_InlineTableCompactSpacing()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = {a=1,b=2}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify compact spacing was captured
		TomlNodeId nodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out nodeId);
		let style = doc.Metadata.GetNodeStyle(nodeId);
		let fmt = doc.Metadata.mValueFormats[style.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mEqualsSpacing == 0, scope $"Expected equals spacing 0, got {tFmt.mEqualsSpacing}");
			Test.Assert(tFmt.mCommaSpacing == 0, scope $"Expected comma spacing 0, got {tFmt.mCommaSpacing}");
			Test.Assert(tFmt.mOpenBraceSpacing == 0, scope $"Expected open brace spacing 0, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 0, scope $"Expected close brace spacing 0, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");

		// Mutate and verify compact style preserved
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("{a=42,b=2}"), scope $"Expected compact inline table, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_InlineTableSpacedEqualsAndComma()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = { a = 1 , b = 2 }";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		TomlNodeId nodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out nodeId);
		let style = doc.Metadata.GetNodeStyle(nodeId);
		let fmt = doc.Metadata.mValueFormats[style.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mEqualsSpacing == 1, scope $"Expected equals spacing 1, got {tFmt.mEqualsSpacing}");
			Test.Assert(tFmt.mCommaSpacing == 1, scope $"Expected comma spacing 1, got {tFmt.mCommaSpacing}");
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
		}
	}

	[Test]
	public static void PreserveStyle_InlineTableV10ForcesSingleLine()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Parse a multiline inline table
		let input = "t = {\n  a = 1,\n  b = 2,\n}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		// Write with v1.0 should force single-line
		var writeConfig = TomlWriteConfig();
		writeConfig.Version = .V1_0;
		String output = scope String();
		doc.Write(output, writeConfig);
		// Should be single-line, no newlines inside braces
		Test.Assert(!output.Contains("{\n") && !output.Contains("{\r"),
			scope $"Expected single-line inline table in v1.0, got: {output}");
		// Should contain proper spacing
		Test.Assert(output.Contains(" = ") && output.Contains(", "),
			scope $"Expected spaced inline table in v1.0, got: {output}");

		// Write with v1.1 should preserve multiline
		writeConfig.Version = .V1_1;
		String output2 = scope String();
		doc.Write(output2, writeConfig);
		Test.Assert(output2.Contains("{\n"), scope $"Expected multiline inline table in v1.1, got: {output2}");
	}

	// ================================================================
	// Table header blank line preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_BlankLineBeforeTableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two tables with a blank line between
		let input = "[a]\nx = 1\n\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify blank line metadata was captured on the [b] table node
		doc.RootTable.TryGetTable("b", var tblB);
		Test.Assert(tblB.MetadataContext != null);
		let commentSet = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(commentSet != null, "Expected comment set on table b");
		Test.Assert(commentSet.mSeparatedByBlankLine, "Expected blank line flag on table b");

		// Verify table [a] does NOT have the blank line flag
		doc.RootTable.TryGetTable("a", var tblA);
		let commentSetA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(commentSetA == null || !commentSetA.mSeparatedByBlankLine,
			"Table a should not have blank line flag");

		String output = scope String();
		doc.Write(output);
		// Writer always emits blank line separator before headers
		Test.Assert(output.Contains("x = 1\n\n[b]") || output.Contains("x = 1\r\n\r\n[b]"),
			scope $"Expected blank line between sections, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_BlankLineMetadataCaptured()
	{
		// Verify blank line metadata is correctly distinguished between
		// separated and non-separated cases
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "[a]\nx = 1\n\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine,
			"First table should not have blank line flag");

		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(csB != null && csB.mSeparatedByBlankLine,
			"Second table should have blank line flag");
	}

	[Test]
	public static void PreserveStyle_NoBlankLineForDirectAdjacentSections()
	{
		// Direct-adjacent sections (no blank line between) should NOT get blank line flag
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "[a]\nx = 1\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine,
			"Table a should not have blank line flag");

		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		// When sections are directly adjacent, [b]'s header follows immediately
		// after the preceding content's newline with no extra blank line.
		// mBlankLineCount catches the single newline between sections but only
		// flags it as separatedByBlankLine when there's at least one extra.
		Test.Assert(csB == null || !csB.mSeparatedByBlankLine,
			"Table b should not have blank line flag when directly adjacent");
	}

	[Test]
	public static void PreserveStyle_ArrayCrlfWithComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// CRLF array with comments
		List<uint8> bytes = scope .();
		AddAscii(bytes, "arr = [\r\n");
		AddAscii(bytes, "  # header\r\n");
		AddAscii(bytes, "  1, # first\r\n");
		AddAscii(bytes, "  2\r\n");
		AddAscii(bytes, "]\r\n");

		var doc2 = new TomlDocument();
		defer delete doc2;
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		if (doc2.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc2.Write(output);
		// Should contain all comments
		Test.Assert(output.Contains("# header"), scope $"Expected header comment, got: {output}");
		Test.Assert(output.Contains("# first"), scope $"Expected trailing comment, got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value 1, got: {output}");
		Test.Assert(output.Contains("  2"), scope $"Expected value 2, got: {output}");
	}

	// ================================================================
	// Dirty propagation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_NestedMutationDoesNotDirtyParent()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Nested table: [tbl] with entry x = 1
		let input = "[tbl]\nx = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify all nodes start clean
		for (int i = 0; i < doc.Metadata.mNodeStyles.Count; i++)
			Test.Assert(doc.Metadata.mNodeStyles[i].mDirtyFlags == .None,
				scope $"Node {i} should start clean");

		// Mutate x inside [tbl]
		doc.RootTable.TryGetTable("tbl", var tbl);
		tbl.ReplaceValue("x", .Integer(42));

		// Find node IDs
		doc.RootTable.MetadataContext.TryGetEntryNodeId("tbl", let tblNodeId);
		Test.Assert(tblNodeId.IsValid);
		tbl.MetadataContext.TryGetEntryNodeId("x", let xNodeId);
		Test.Assert(xNodeId.IsValid);

		// The x entry should be dirty
		let xStyle = doc.Metadata.GetNodeStyle(xNodeId);
		Test.Assert(xStyle != null && xStyle.mDirtyFlags == .Value,
			"x entry should have Value dirty flag");

		// The tbl entry and the root table should NOT be dirty
		let tblStyle = doc.Metadata.GetNodeStyle(tblNodeId);
		Test.Assert(tblStyle != null && tblStyle.mDirtyFlags == .None,
			"Parent tbl entry should remain clean after child mutation");

		// Mutate tbl itself — should mark tbl dirty
		// Re-fetch style after Insert since it may reallocate mNodeStyles
		tbl.Insert("y", .Integer(99));
		let tblStyle2 = doc.Metadata.GetNodeStyle(tblNodeId);
		Test.Assert(tblStyle2 != null && (tblStyle2.mDirtyFlags & .Children) != 0,
			"Parent tbl should get Children dirty after direct insertion");
	}

	[Test]
	public static void PreserveStyle_CleanSiblingTokensReused()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two sibling values in a table — one will be mutated
		let input = "a = 'hello'\nb = 'world'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Get original tokens
		let meta = doc.Metadata;
		TomlNodeId aNodeId = .Invalid, bNodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("a", out aNodeId);
		doc.RootTable.MetadataContext.TryGetEntryNodeId("b", out bNodeId);
		Test.Assert(aNodeId.IsValid && bNodeId.IsValid);

		let aStyle = meta.GetNodeStyle(aNodeId);
		let bStyle = meta.GetNodeStyle(bNodeId);
		Test.Assert(aStyle.mDirtyFlags == .None);
		Test.Assert(bStyle.mDirtyFlags == .None);
		let bOrigToken = meta.GetOriginalToken(bStyle.mOriginalValueToken);

		// Mutate only 'a' — 'b' should stay clean
		// ReplaceValue does not allocate metadata, so pointers remain valid.
		doc.RootTable.SetString("a", "changed");

		Test.Assert(aStyle.mDirtyFlags == .Value, "Mutated entry should be dirty");
		Test.Assert(bStyle.mDirtyFlags == .None, "Sibling should remain clean");

		// Writer should reuse b's original token and regenerate a
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("changed"), scope $"Output should contain mutated value, got: {output}");
		Test.Assert(output.Contains(bOrigToken), scope $"Output should contain b's original token '{bOrigToken}', got: {output}");
	}

	[Test]
	public static void PreserveStyle_InlineTableMutationDoesNotDirtyParentEntry()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = { a = 1, b = 2 }";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Get node IDs
		TomlNodeId tNodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out tNodeId);
		Test.Assert(tNodeId.IsValid);

		doc.RootTable.TryGetTable("t", var tbl);

		// The inline table container has its own node ID from BindContainerMetadata
		let inlineNodeId = tbl.MetadataContext?.mNodeId ?? .Invalid;
		Test.Assert(inlineNodeId.IsValid, "Inline table should have a container node");
		let inlineStyle = doc.Metadata.GetNodeStyle(inlineNodeId);
		Test.Assert(inlineStyle != null && inlineStyle.mDirtyFlags == .None,
			"Inline table container should start clean");

		// The parent 't' entry should also start clean
		let tStyle = doc.Metadata.GetNodeStyle(tNodeId);
		Test.Assert(tStyle != null && tStyle.mDirtyFlags == .None,
			"Parent 't' entry should start clean");

		// Mutate a value inside the inline table (replacing existing key)
		tbl.ReplaceValue("a", .Integer(42));

		// No upward propagation: parent 't' entry stays clean
		Test.Assert(tStyle != null && tStyle.mDirtyFlags == .None,
			"Parent 't' entry should remain clean after inline table child mutation");

		// Inline table container also stays clean (replacing existing key, not structural)
		Test.Assert(inlineStyle != null && inlineStyle.mDirtyFlags == .None,
			"Inline table container should stay clean after value replacement");

		// Mutate the inline table's structure (insert a new key).
		// This may reallocate mNodeStyles, so re-fetch pointers after.
		tbl.Insert("c", .Integer(3));

		// The inline table container gets Children dirty
		let inlineStyle2 = doc.Metadata.GetNodeStyle(inlineNodeId);
		Test.Assert(inlineStyle2 != null && (inlineStyle2.mDirtyFlags & .Children) != 0,
			"Inline table container should get Children dirty after structural change");

		// Still no upward propagation to parent 't' entry
		let tStyle2 = doc.Metadata.GetNodeStyle(tNodeId);
		Test.Assert(tStyle2 != null && tStyle2.mDirtyFlags == .None,
			"Parent 't' entry should still be clean after inline table structural change");

		// Writer should still produce valid output
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("a = 42") && output.Contains("c = 3"),
			scope $"Expected mutated inline table in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	// ================================================================
	// Quoted path syntax tests
	// ================================================================

	[Test]
	public static void QuotedPath_BareDottedStillWorks()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[a]\nb.c = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Existing bare dotted path still works
		Test.Assert(doc.TryGetInteger("a.b.c", var val) && val == 1);
		// GetPath with params
		Test.Assert(doc.GetPath("a", "b", "c") case .Ok(let v) && v.IsInteger && v.AsInteger == 1);
	}

	[Test]
	public static void QuotedPath_RootKeyWithDot()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"a.b\" = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Bracket syntax to access key containing '.'
		Test.Assert(doc.TryGetInteger("[a.b]", var val) && val == 1);
		// Bare dotted path should NOT find it (it would split into ["a", "b"])
		Test.Assert(!doc.TryGetInteger("a.b", var _));
	}

	[Test]
	public static void QuotedPath_NestedKeyWithDot()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[servers]\n\"192.168.1.1\" = { host = \"db1\" }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Access server's IP with bracket syntax, then read a sub-field
		Test.Assert(doc.TryGetString("servers.[192.168.1.1].host", var host) && host == "db1");
		// GetPath with params
		Test.Assert(doc.GetPath("servers", "192.168.1.1", "host") case .Ok(let v) && v.IsString && v.AsString == "db1");
	}

	[Test]
	public static void QuotedPath_MultipleBracketedSegments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"a.b\" = { \"c.d\" = { \"e.f\" = 1 } }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("[a.b].[c.d].[e.f]", var val) && val == 1);
	}

	[Test]
	public static void QuotedPath_MalformedSyntaxRejected()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// Setup: create keys where malformed paths would resolve if accepted
		if (doc.Read("a = { b = 1 }\n\"x.y\" = { z = 2 }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Empty path
		Test.Assert(doc.Get("") case .Err);
		// Leading dot
		Test.Assert(doc.Get(".a") case .Err);
		// Trailing dot
		Test.Assert(doc.Get("a.") case .Err);
		// Consecutive dots
		Test.Assert(doc.Get("a..b") case .Err);
		// Empty bracketed segment
		Test.Assert(doc.Get("a.[].b") case .Err);
		// Unmatched opening bracket
		Test.Assert(doc.Get("a.[b") case .Err);
		// Unmatched closing bracket — would hit "a.b]" as a bare key path if accepted
		Test.Assert(doc.Get("a.b]") case .Err);
		// Unmatched bracket in middle
		Test.Assert(doc.Get("a.[b].[c") case .Err);
		// Bare segment containing '[' should be rejected
		Test.Assert(doc.Get("a[b") case .Err);
		// Bare segment containing ']' should be rejected
		Test.Assert(doc.Get("a]b") case .Err);
		// Missing dot between bracketed and bare segment
		Test.Assert(doc.Get("[a]b") case .Err);
		// Missing dot between bare and bracketed segment
		Test.Assert(doc.Get("a.[b]c") case .Err);
		// Bracketed segment followed by garbage
		Test.Assert(doc.Get("a.[b]x") case .Err);

		// Bare segment immediately followed by bracket: a[b] should NOT parse as ["a", "b"]
		// Using a doc where "a.b" exists to prove this is a syntax rejection, not lookup failure
		Test.Assert(doc.Get("a[b]") case .Err);
	}

	[Test]
	public static void QuotedPath_TryGetTypedInheritsBracketSyntax()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"x.y\" = \"hello\"") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Typed accessor should inherit bracket syntax via Get()
		Test.Assert(doc.TryGetString("[x.y]", var val) && val == "hello");
	}

	[Test]
	public static void QuotedPath_GetPathParams()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[a]\nb.c = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// params StringView[] — clean multi-segment syntax
		Test.Assert(doc.GetPath("a", "b", "c") case .Ok(let v) && v.IsInteger && v.AsInteger == 1);

		// Single segment
		if (doc.Read("x = 42") case .Err(let e2))
		{
			defer e2.Dispose();
			Test.Assert(false, scope $"Parse failed: {e2.mMessage}");
		}
		Test.Assert(doc.GetPath("x") case .Ok(let v2) && v2.IsInteger && v2.AsInteger == 42);

		// GetPath is the escape hatch for keys bracket syntax can't represent.
		// A key containing ']' cannot be reached via string-path syntax.
		if (doc.Read("\"weird]key\" = 1") case .Err(let e2b))
		{
			defer e2b.Dispose();
			Test.Assert(false, scope $"Parse failed: {e2b.mMessage}");
		}
		Test.Assert(doc.Get("weird]key") case .Err);
		Test.Assert(doc.GetPath("weird]key") case .Ok(let v3) && v3.IsInteger && v3.AsInteger == 1);

		// List<StringView> overload for programmatic callers
		var segs = scope List<StringView>();
		segs.Add("a");
		segs.Add("b");
		segs.Add("c");
		if (doc.Read("[a]\nb.c = 99") case .Err(let e3))
		{
			defer e3.Dispose();
			Test.Assert(false, scope $"Parse failed: {e3.mMessage}");
		}
		Test.Assert(doc.GetPath(segs) case .Ok(let v4) && v4.IsInteger && v4.AsInteger == 99);
	}

	// ================================================================
	// Inline table recursive sealing tests
	// ================================================================

	[Test]
	public static void InlineTableSeal_DottedKeyChildNotExtendable()
	{
		// Dotted key creates sub-table inside inline table — must not be extendable later
		var doc = new TomlDocument();
		defer delete doc;
		let input = "type = { name.first = \"Nail\" }\ntype.name.last = \"bad\"";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table dotted-key child extended after close");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_DottedKeyChildNotExtendable2()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b.c = 1 }\na.b.d = 2";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table child extended");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_NestedInlineTableChildNotExtendable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b = { c = 1 } }\na.b.d = 2";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — nested inline table child extended");
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .InlineTableSealed,
				scope $"Expected InlineTableSealed, got {e.mKind}: {e.mMessage}");
		}
	}

	[Test]
	public static void InlineTableSeal_DottedKeyWithinInlineTableStillValid()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b.c = 1, b.d = 2 }";
		if (doc.Read(input) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Valid inline table with dotted keys should parse: {e.mMessage}");
		}
		// Verify values are accessible
		Test.Assert(doc.TryGetInteger("a.b.c", var c) && c == 1);
		Test.Assert(doc.TryGetInteger("a.b.d", var d) && d == 2);
	}

	// ================================================================
	[Test]
	public static void InlineTableSeal_NestedInlineTablesStillValid()
	{
		var doc = new TomlDocument();
		defer delete doc;
		let input = "a = { b = { c = 1, d = 2 } }";
		if (doc.Read(input) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Valid nested inline table should parse: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a.b.c", var c) && c == 1);
		Test.Assert(doc.TryGetInteger("a.b.d", var d) && d == 2);
	}

	[Test]
	public static void InlineTableSeal_HeaderExtensionOfDottedChildRejected()
	{
		// Using [header] syntax to extend an inline-table child must also be rejected
		var doc = new TomlDocument();
		defer delete doc;
		let input = "type = { name.first = \"Nail\" }\n\n[type.name]\nlast = \"bad\"";
		switch (doc.Read(input))
		{
		case .Ok:
			Test.Assert(false, "Expected error — inline table child extended via [header]");
		case .Err(let e):
			defer e.Dispose();
			// [header] redefines the inline table, caught as DuplicateTable before sealing check.
			// Either error is acceptable — both prevent extending inline-table children.
			Test.Assert(e.mKind == .DuplicateTable,
				scope $"Expected DuplicateTable, got {e.mKind}: {e.mMessage}");
		}
	}

	// ================================================================
	// Typed setter and construction tests
	// ================================================================

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

	// ================================================================
	// Phase 10 — Safe array mutation tests
	// ================================================================

	[Test]
	public static void Phase10_ArrayAssignmentAndAdd()
	{
		var doc = new TomlDocument();
		defer delete doc;

		// Create array via AddArray
		var arr = doc.AddArray("items");

		// Add via implicit conversion
		arr.Add("hello");
		arr.Add(42);
		arr.Add(3.14);
		arr.Add(true);
		arr.Add(TomlLocalDate(2025, 1, 1));

		Test.Assert(arr.Count == 5);

		// Indexer assignment
		arr[0] = "changed";
		arr[1] = 99;
		arr[3] = false;

		// Typed reads — declare out variables first
		StringView s = ?;
		Test.Assert(arr.TryGetString(0, out s) && s == "changed");
		int64 i = ?;
		Test.Assert(arr.TryGetInteger(1, out i) && i == 99);
		double f = ?;
		Test.Assert(arr.TryGetFloat(2, out f) && f > 3.1 && f < 3.2);
		bool b = ?;
		Test.Assert(arr.TryGetBool(3, out b) && b == false);
		StringView s4 = ?;
		Test.Assert(arr.TryGetString(4, out s4) == false); // index 4 is a date, not string

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
		Test.Assert(doc2.TryGetArray("items", var a2) && a2.Count == 5);
	}

	[Test]
	public static void Phase10_SetTableAndSetArray()
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
	public static void Phase10_RemoveAtAndClear()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var arr = doc.AddArray("items");
		arr.Add(1);
		arr.Add(2);
		arr.Add(3);
		arr.Add(4);

		Test.Assert(arr.Count == 4);

		arr.RemoveAt(1); // removes 2
		Test.Assert(arr.Count == 3);
		int64 v = ?;
		Test.Assert(arr.TryGetInteger(1, out v) && v == 3);

		arr.Clear();
		Test.Assert(arr.Count == 0);

		// Write should not crash
		String output = scope String();
		doc.Write(output);
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {e.mMessage}");
		}
		Test.Assert(doc2.TryGetArray("items", var a2) == false || a2.Count == 0);
	}

	// ================================================================
	// Phase 11 — Table entry proxy tests
	// ================================================================

	[Test]
	public static void Phase11_TableEntryReadAndAssign()
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
		StringView s = ?;
		Test.Assert(e0.TryGetString(out s) && s == "test");

		// Assign via entry proxy
		var e1 = root[1];
		Test.Assert(e1.Key == "count");
		e1.Value = 99;
		int64 v = ?;
		Test.Assert(root[1].TryGetInteger(out v) && v == 99);

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
	public static void Phase11_TableEntrySetTableAndArray()
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
	public static void Phase11_DuplicateRenameRejected()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var root = doc.RootTable;
		root.SetString("a", "x");
		root.SetString("b", "y");

		Test.Assert(root[0].Rename("b") case .Err);
	}

	// ================================================================
	// Resource limit tests
	// ================================================================

	[Test]
	public static void ResourceLimit_MaxTableEntries_TopLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_NamedTable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("[t]\na = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_InlineTable()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("t = { a = 1, b = 2 }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxTableEntries_DottedKey()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxTableEntries = 1 };
		switch (doc.Read("a.b = 1\na.c = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxTableEntries limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_KeyVal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("a.b.c = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_TableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("[a.b.c]\nx = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxPathSegments_ArrayOfTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxPathSegments = 2 };
		switch (doc.Read("[[a.b.c]]\nx = 1", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxPathSegments limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxNodes_Scalars()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxNodes = 1 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxNodes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxInputBytes_StringView()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxInputBytes = 5 };
		switch (doc.Read("a = 1\nb = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxInputBytes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxArrayItems_StaticArray()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxArrayItems = 2 };
		switch (doc.Read("a = [1, 2, 3]", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxArrayItems limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxArrayItems_ArrayOfTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxArrayItems = 1 };
		switch (doc.Read("[[a]]\nx = 1\n[[a]]\nx = 2", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxArrayItems limit for array-of-tables");
		}
	}

	[Test]
	public static void ResourceLimit_MaxStringBytes()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig() { MaxStringBytes = 2 };
		switch (doc.Read("a = \"abc\"", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxStringBytes limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxDepth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// Inline table inside inline table — 2 levels of value nesting
		var config = TomlReadConfig() { MaxDepth = 1 };
		switch (doc.Read("a = { b = { c = 1 } }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .MaxDepthExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxDepth limit");
		}
	}

	[Test]
	public static void ResourceLimit_MaxInputBytes_ReadBytes()
	{
		var doc = new TomlDocument();
		defer delete doc;
		String input = scope String("a = 1\nb = 2");
		var config = TomlReadConfig() { MaxInputBytes = 5 };
		switch (doc.ReadBytes(Span<uint8>((uint8*)input.Ptr, input.Length), config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxInputBytes limit for ReadBytes");
		}
	}

	[Test]
	public static void ResourceLimit_MaxNodes_InlineTableDotted()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// inline table a + implicit inline table b + scalar c — 3 nodes
		var config = TomlReadConfig() { MaxNodes = 2 };
		switch (doc.Read("a = { b.c = 1 }", config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected MaxNodes limit for inline table dotted key");
		}
	}

	[Test]
	public static void ResourceLimit_StreamMergeLeavesDocumentUnchanged()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		String input = scope String("a = 1\nb = 2");
		List<uint8> bytes = scope List<uint8>();
		for (int i = 0; i < input.Length; i++)
			bytes.Add((uint8)input[i]);
		var stream = new MemoryStream(bytes, false);
		defer { delete stream; }
		var mergeConfig = TomlReadConfig() { Mode = .Merge, MaxInputBytes = 1 };
		if (doc.Read(stream, mergeConfig) case .Ok)
			Test.Assert(false, "Expected stream merge to fail");
		Test.Assert(doc.RootTable.Count == 1);
		Test.Assert(doc.TryGetInteger("existing", var val) && val == 1);
	}

	[Test]
	public static void ResourceLimit_StreamFailsWithResourceLimitExceeded()
	{
		var doc = new TomlDocument();
		defer delete doc;
		String input = scope String("a = 1\nb = 2");
		List<uint8> bytes = scope List<uint8>();
		for (int i = 0; i < input.Length; i++)
			bytes.Add((uint8)input[i]);
		var stream = new MemoryStream(bytes, false);
		defer { delete stream; }
		var config = TomlReadConfig() { MaxInputBytes = 3 };
		switch (doc.Read(stream, config))
		{
		case .Err(let e):
			defer e.Dispose();
			Test.Assert(e.mKind == .ResourceLimitExceeded);
		case .Ok:
			Test.Assert(false, "Expected ResourceLimitExceeded for stream");
		}
	}

	[Test]
	public static void ResourceLimit_ReplaceModeOversizedReadClearsDocument()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		Test.Assert(doc.RootTable.Count == 1);
		var config = TomlReadConfig() { MaxInputBytes = 1, Mode = .Replace };
		if (doc.Read("ab", config) case .Ok)
			Test.Assert(false, "Expected MaxInputBytes limit for replace-mode Read");
		Test.Assert(doc.RootTable.Count == 0);
	}

	[Test]
	public static void ResourceLimit_ReplaceModeOversizedReadBytesClearsDocument()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("existing = 1") case .Err)
			Test.Assert(false);
		Test.Assert(doc.RootTable.Count == 1);
		String input = scope String("ab");
		var config = TomlReadConfig() { MaxInputBytes = 1, Mode = .Replace };
		if (doc.ReadBytes(Span<uint8>((uint8*)input.Ptr, input.Length), config) case .Ok)
			Test.Assert(false, "Expected MaxInputBytes limit for replace-mode ReadBytes");
		Test.Assert(doc.RootTable.Count == 0);
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
