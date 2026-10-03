using System;
using System.Collections;
using System.IO;
using TomlBeef;
using static TomlBeef.TomlTestSupport;

namespace TomlBeef;

static class TomlStreamTests
{
	[Test]
	public static void Stream_CrlfCrossesBufferBoundary()
	{
		List<uint8> bytes = scope List<uint8>();
		AddRepeat(bytes, '#', 8191);
		AddAscii(bytes, "\r\na = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Stream_LongCommentCrossesBufferBoundary()
	{
		List<uint8> bytes = scope List<uint8>();
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
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Stream_LongLiteralStringCrossesBufferBoundary()
	{
		List<uint8> bytes = scope List<uint8>();
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
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetString("a", var s));
		Test.Assert(s.Length == 8192);
	}

	[Test]
	public static void Stream_LongBareKeyCrossesBufferBoundary()
	{
		List<uint8> bytes = scope List<uint8>();
		AddRepeat(bytes, 'k', 8192);
		AddAscii(bytes, " = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Utf8_StreamRejectsInvalidLeadByte()
	{
		List<uint8> bytes = scope List<uint8>();
		AddByte(bytes, 0xFF);
		AddAscii(bytes, "\n");
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsInvalidBytesInComment()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "# ");
		AddByte(bytes, 0xFF);
		AddAscii(bytes, "\na = 1\n");
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsTruncatedSequenceAtEof()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "# ");
		AddByte(bytes, 0xC3);
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamRejectsOverlongSequence()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "\"");
		AddByte(bytes, 0xC0);
		AddByte(bytes, 0xAF);
		AddAscii(bytes, "\"");
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StreamAcceptsValidUtf8AcrossBuffer()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = \"");
		AddRepeat(bytes, 'x', 8185);
		AddByte(bytes, 0xC2);
		AddByte(bytes, 0xA9);
		AddAscii(bytes, "\"\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.RootTable.Count == 1);
	}

	[Test]
	public static void Bom_StreamPreservesContentAfterBom()
	{
		List<uint8> bytes = scope List<uint8>();
		AddBytes(bytes, 0xEF, 0xBB, 0xBF);
		AddAscii(bytes, "a = 1\n");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read(ms) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a", var val) && val == 1);
	}

	[Test]
	public static void Bom_DoubleBomRejected()
	{
		List<uint8> bytes = scope List<uint8>();
		AddBytes(bytes, 0xEF, 0xBB, 0xBF, 0xEF, 0xBB, 0xBF);
		AddAscii(bytes, "\n");
		AssertReadErr(.ControlCharInDocument, ReadFromByteStream(bytes));
	}

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
	public static void Stream_ErrorMidCommentReturnsIoError()
	{
		var stream = scope FailingAfterBytesStream(8, "a = 1\n# comment\n");
		var doc = scope TomlDocument();
		AssertReadErr(.IoError, doc.Read(stream));
	}

	[Test]
	public static void Stream_ErrorInsidePendingUtf8SequenceReturnsIoError()
	{
		// Fail after the first byte of the 2-byte sequence for U+00E9
		var stream = scope FailingAfterBytesStream(7, "a = \"x\u{E9}\"\n");
		var doc = scope TomlDocument();
		AssertReadErr(.IoError, doc.Read(stream));
	}

	[Test]
	public static void Stream_ErrorAfterCompleteStatementsReturnsIoError()
	{
		var stream = scope FailingAfterBytesStream(12, "a = 1\nb = 2\nc = 3\n");
		var doc = scope TomlDocument();
		AssertReadErr(.IoError, doc.Read(stream));
		Test.Assert(doc.RootTable.Count == 0, "A failed Replace read must leave the document empty");
	}

	[Test]
	public static void Stream_CleanEofBeforeFailurePointSucceeds()
	{
		// The failure point is beyond the data, so the reader sees a normal EOF
		var stream = scope FailingAfterBytesStream(100, "a = 1\n");
		var doc = scope TomlDocument();
		if (doc.Read(stream) case .Err(let e))
		{
			Test.Assert(false, scope $"Expected clean EOF, got {e.mKind}: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a", var a) && a == 1);
	}

	[Test]
	public static void Stream_LineEndingBackslashWithWhitespaceLongerThanBuffer()
	{
		// After a line-ending backslash the parser looks ahead over whitespace to find the newline;
		// a run longer than the stream buffer must still be handled like the string path.
		for (let trailing in int[](10, 9000))
		{
			List<uint8> bytes = scope List<uint8>();
			AddAscii(bytes, "s = \"\"\"a \\");
			AddRepeat(bytes, ' ', trailing);
			AddAscii(bytes, "\n   b\"\"\"\n");

			var fromString = scope TomlDocument();
			if (fromString.Read(StringView((char8*)bytes.Ptr, bytes.Count)) case .Err(let e1))
			{
				Test.Assert(false, scope $"String parse failed ({trailing}): {e1.mMessage}");
				continue;
			}
			Test.Assert(fromString.TryGetString("s", var s1) && s1 == "a b", scope $"Unexpected string value ({trailing})");

			let ms = scope MemoryStream();
			ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
			ms.Position = 0;
			var fromStream = scope TomlDocument();
			if (fromStream.Read(ms) case .Err(let e2))
			{
				Test.Assert(false, scope $"Stream parse failed ({trailing}): {e2.mMessage}");
				continue;
			}
			Test.Assert(fromStream.TryGetString("s", var s2) && s2 == "a b", scope $"Stream decoded differently ({trailing}): '{s2}'");
		}
	}

	[Test]
	public static void Stream_TinyConfiguredBufferIsRaisedToMinimum()
	{
		// A 1-byte buffer would break the parser's lookahead; it is raised to the minimum
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "s = \"\"\"long enough to need many refills\"\"\"\nd = 1979-05-27T07:32:00Z\n");
		let ms = scope MemoryStream(bytes, false);
		var doc = scope TomlDocument();
		if (doc.Read(ms, .() { StreamBufferBytes = 1 }) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetString("s", var s) && s == "long enough to need many refills");
		Test.Assert(doc.TryGetOffsetDateTime("d", var d) && d.mYear == 1979);
	}

	[Test]
	public static void Stream_LongBareValueCrossesBufferBoundary()
	{
		List<uint8> bytes = scope List<uint8>();
		AddRepeat(bytes, '#', 8185);
		AddAscii(bytes, "\na = 1234567890123\nb = 1979-05-27T07:32:00Z\n");
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = scope TomlDocument();
		if (doc.Read(ms) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a", var a) && a == 1234567890123);
		Test.Assert(doc.TryGetOffsetDateTime("b", var b) && b.mYear == 1979 && b.mSecond == 0);
	}

	// ================================================================
	// UTF-8 error positions for string and byte-span input
	// ================================================================

	static void AssertUtf8ErrorAt(Result<void, TomlParseError> result, int line, int column, int offset)
	{
		switch (result)
		{
		case .Ok:
			Test.Assert(false, "Expected InvalidUtf8 error");
		case .Err(let e):
			Test.Assert(e.mKind == .InvalidUtf8, scope $"Expected InvalidUtf8, got {e.mKind}: {e.mMessage}");
			Test.Assert(e.mLine == line && e.mColumn == column && e.mOffset == offset,
				scope $"Expected {line}:{column} @{offset}, got {e.mLine}:{e.mColumn} @{e.mOffset}");
		}
	}

	/// Checks the error position through both Read(StringView) and ReadBytes().
	static void AssertUtf8ErrorAtBothPaths(List<uint8> bytes, int line, int column, int offset)
	{
		var doc = new TomlDocument();
		defer delete doc;
		AssertUtf8ErrorAt(doc.Read(StringView((char8*)bytes.Ptr, bytes.Count)), line, column, offset);
		AssertUtf8ErrorAt(doc.ReadBytes(Span<uint8>(bytes.Ptr, bytes.Count)), line, column, offset);
	}

	[Test]
	public static void Utf8_ErrorsAroundTheAsciiFastPath()
	{
		// The validator skips ASCII 8 bytes at a time: put bad bytes before, on and after those
		// boundaries, and valid multi-byte text between ASCII runs, and check the reported position
		for (int prefix = 0; prefix <= 17; prefix++)
		{
			List<uint8> bytes = scope List<uint8>();
			AddAscii(bytes, "# ");
			AddRepeat(bytes, 'x', prefix);
			AddBytes(bytes, 0xC3, 0xA9); // é, valid
			AddAscii(bytes, "yyyyyyyyy");
			AddByte(bytes, 0xFF);
			AddAscii(bytes, "\n");
			// '#', ' ', the x's, é (one column), nine y's, then the bad byte
			AssertUtf8ErrorAtBothPaths(bytes, 1, 2 + prefix + 1 + 9 + 1, 2 + prefix + 2 + 9);
		}

		// Valid input of every length around the boundaries still parses
		for (int length = 0; length <= 17; length++)
		{
			let input = scope String("# ");
			input.Append('z', length);
			input.Append("é\na = 1\n");
			var doc = scope TomlDocument();
			Test.Assert(doc.Read(input) case .Ok, input);
		}
	}

	[Test]
	public static void Utf8_InvalidLeadByteAfterLfReportsLine2()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\n# ");
		AddByte(bytes, 0xFF);
		AddAscii(bytes, "\n");
		AssertUtf8ErrorAtBothPaths(bytes, 2, 3, 8);
	}

	[Test]
	public static void Utf8_InvalidLeadByteAfterCrlfReportsLine2()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\r\n# ");
		AddByte(bytes, 0xFF);
		AssertUtf8ErrorAtBothPaths(bytes, 2, 3, 9);
	}

	[Test]
	public static void Utf8_InvalidContinuationByteReportsLeadBytePosition()
	{
		// FormatCore's validator reports a sequence at its lead byte, with the length of the bad bytes
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\n# ");
		AddBytes(bytes, 0xC3, 0x28);
		AssertUtf8ErrorAtBothPaths(bytes, 2, 3, 8);
	}

	[Test]
	public static void Utf8_TruncatedSequenceAfterMultipleLinesReportsLeadByte()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\nb = 2\n# ");
		AddBytes(bytes, 0xE2, 0x82);
		AssertUtf8ErrorAtBothPaths(bytes, 3, 3, 14);
	}

	[Test]
	public static void Utf8_LeadingBomDoesNotShiftColumn()
	{
		List<uint8> bytes = scope List<uint8>();
		AddBytes(bytes, 0xEF, 0xBB, 0xBF);
		AddAscii(bytes, "a = ");
		AddByte(bytes, 0xFF);
		AssertUtf8ErrorAtBothPaths(bytes, 1, 5, 7);
	}

	[Test]
	public static void Utf8_SurrogateRejected()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "# ");
		AddBytes(bytes, 0xED, 0xA0, 0x80); // U+D800
		AssertUtf8ErrorAtBothPaths(bytes, 1, 3, 2);
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_CodepointAbove10FFFFRejected()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "# ");
		AddBytes(bytes, 0xF4, 0x90, 0x80, 0x80); // U+110000
		AssertUtf8ErrorAtBothPaths(bytes, 1, 3, 2);
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	[Test]
	public static void Utf8_StrayContinuationByteRejected()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = \"x");
		AddByte(bytes, 0x80);
		AddAscii(bytes, "\"");
		AssertUtf8ErrorAtBothPaths(bytes, 1, 7, 6);
		AssertReadErr(.InvalidUtf8, ReadFromByteStream(bytes));
	}

	static Result<void, TomlParseError> ReadStreamed(TomlDocument doc, StringView input, int bufferBytes)
	{
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>((uint8*)input.Ptr, input.Length));
		ms.Position = 0;
		return doc.Read(ms, .() { StreamBufferBytes = bufferBytes });
	}

	[Test]
	public static void ScanRuns_CrossStreamBuffersAndCountCharacterColumns()
	{
		// Long keys, strings, comments and bare values, with multi-byte UTF-8, read through a 16-byte stream
		// buffer: every run crosses refills (some inside a multi-byte character) and must match a string read
		let input = "# comment héllo wörld — a long comment line that crosses many small buffers\n" +
			"a_rather_long_bare_key_name_that_spans_buffers = \"basic string with ünïcödé and \\t escapes 日本語 text\"\n" +
			"'literal key ☃ with spaces' = 'literal ☃ string that is also long enough to cross buffers'\n" +
			"\"quoted key é\" = 1979-05-27T07:32:00.999999-07:00 # trailing ünïcode comment\n" +
			"n = 123_456_789\n";
		var fromString = scope TomlDocument();
		Test.Assert(fromString.Read(input) case .Ok);
		for (int bufferBytes in scope int[](16, 17, 31, 64))
		{
			var streamed = scope TomlDocument();
			if (ReadStreamed(streamed, input, bufferBytes) case .Err(let e))
			{
				Test.Assert(false, scope $"buffer {bufferBytes}: {e}");
			}
			Test.Assert(TomlTableEquals(fromString.RootTable, streamed.RootTable), scope $"buffer {bufferBytes}: stream read differs");
		}
		Test.Assert(fromString.TryGetString("a_rather_long_bare_key_name_that_spans_buffers", let basic) && basic == "basic string with ünïcödé and \t escapes 日本語 text");
		Test.Assert(fromString.TryGetString("[literal key ☃ with spaces]", let literal) && literal == "literal ☃ string that is also long enough to cross buffers");

		// Columns count characters, not bytes: the error after a non-ASCII string is at column 15
		// (`s = "héllo日本" x`: '"'=5, 'h'=6 ... '本'=12, '"'=13, space=14, 'x'=15; counting bytes would give 20)
		let bad = "s = \"héllo日本\" x\n";
		var byString = scope TomlDocument();
		Test.Assert(byString.Read(bad) case .Err(let stringErr));
		Test.Assert(stringErr.mLine == 1 && stringErr.mColumn == 15, scope $"string read: {stringErr}");
		var byStream = scope TomlDocument();
		Test.Assert(ReadStreamed(byStream, bad, 16) case .Err(let streamErr));
		Test.Assert(streamErr.mLine == 1 && streamErr.mColumn == 15, scope $"stream read: {streamErr}");
	}

	[Test]
	public static void Utf8_OverlongSequenceOnLine2()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\n# ");
		AddBytes(bytes, 0xC0, 0xAF);
		AssertUtf8ErrorAtBothPaths(bytes, 2, 3, 8);
	}

	static Result<void, TomlParseError> ReadStreamedWith(TomlDocument doc, StringView input, TomlReadConfig config)
	{
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>((uint8*)input.Ptr, input.Length));
		ms.Position = 0;
		return doc.Read(ms, config);
	}

	[Test]
	public static void Stream_MaxTokenBytesBoundsRetainedSpans()
	{
		// A 62-byte float: longer than the 16-byte buffer, so without a limit the window grows for it.
		// MaxTokenBytes bounds a token plus the lookahead the parser needs to see it end (FormatCore's
		// window cursor: a hard limit on the construct, no longer the retained span alone)
		let input = scope String("n = 1\nf = 1.");
		input.Append('0', 60);
		input.Append("\nafter = 2\n");
		let limited = TomlReadConfig() { StreamBufferBytes = 16, MaxTokenBytes = 32 };

		var unlimited = scope TomlDocument();
		Test.Assert(ReadStreamed(unlimited, input, 16) case .Ok);
		Test.Assert(unlimited.TryGetFloat("f", var f) && f == 1.0);

		var doc = scope TomlDocument();
		Test.Assert(ReadStreamedWith(doc, input, limited) case .Err(let err));
		Test.Assert(err.mKind == .ResourceLimitExceeded && err.mLine == 2, scope $"{err}");
		Test.Assert(err.mMessage.Contains("A token is longer than MaxTokenBytes (32)"), scope $"{err}");
		Test.Assert(doc.RootTable.Count == 0, "A failed Replace read leaves the document empty");

		// A token shorter than the buffer is caught too
		var small = scope TomlDocument();
		Test.Assert(ReadStreamedWith(small, "f = 1.000000000\n", .() { MaxTokenBytes = 8 }) case .Err(let smallErr));
		Test.Assert(smallErr.mKind == .ResourceLimitExceeded, scope $"{smallErr}");
		// ...and one within the limit (62 bytes and the line break after it) is fine, even across
		// several refills; one byte less is not
		Test.Assert(ReadStreamedWith(small, input, .() { StreamBufferBytes = 16, MaxTokenBytes = 63 }) case .Ok);
		Test.Assert(ReadStreamedWith(small, input, .() { StreamBufferBytes = 16, MaxTokenBytes = 62 }) case .Err);

		// In-memory input keeps no copy, so the limit does not apply
		var fromString = scope TomlDocument();
		Test.Assert(fromString.Read(input, limited) case .Ok);

		// A failed merge leaves existing content unchanged
		var merged = scope TomlDocument();
		Test.Assert(merged.Read("keep = true\n") case .Ok);
		var mergeConfig = limited;
		mergeConfig.Mode = .Merge;
		Test.Assert(ReadStreamedWith(merged, input, mergeConfig) case .Err(let mergeErr));
		Test.Assert(mergeErr.mKind == .ResourceLimitExceeded && merged.RootTable.Count == 1);
	}

	[Test]
	public static void Stream_MaxTokenBytesCoversPreserveStyleValues()
	{
		// PreserveStyle keeps a scalar's source text (its token), so a long string is one span...
		let longString = scope String("s = \"");
		longString.Append('x', 60);
		longString.Append("\"\n");
		var plain = scope TomlDocument();
		Test.Assert(ReadStreamedWith(plain, longString, .() { StreamBufferBytes = 16, MaxTokenBytes = 32 }) case .Ok);
		var styled = scope TomlDocument();
		let result = ReadStreamedWith(styled, longString, .() { StreamBufferBytes = 16, MaxTokenBytes = 32, MetadataMode = .PreserveStyle });
		Test.Assert(result case .Err(let err) && err.mKind == .ResourceLimitExceeded);
		Test.Assert(ReadStreamedWith(styled, longString, .() { StreamBufferBytes = 16, MaxTokenBytes = 128, MetadataMode = .PreserveStyle }) case .Ok);

		// ...but not a container's: arrays and inline tables record their layout as they are parsed, so
		// a long one is never held whole
		let longArray = scope String("a = [");
		for (int i = 0; i < 20; i++)
			longArray.AppendF("{}, ", i);
		longArray.Append("{ x = 1, y = [2, 3] }]\n");
		Test.Assert(ReadStreamedWith(styled, longArray, .() { StreamBufferBytes = 16, MaxTokenBytes = 32, MetadataMode = .PreserveStyle }) case .Ok);
		let output = styled.Write(.. scope String());
		Test.Assert(output == longArray, output);
	}
}
