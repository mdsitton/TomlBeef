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
			defer e.Dispose();
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
			defer e.Dispose();
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
			defer e.Dispose();
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
			defer e.Dispose();
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
			defer e.Dispose();
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
			defer e.Dispose();
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
			defer e.Dispose();
			Test.Assert(false, scope $"Expected clean EOF, got {e.mKind}: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("a", var a) && a == 1);
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
			defer e.Dispose();
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
			defer e.Dispose();
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
	public static void Utf8_InvalidContinuationByteReportsContinuationPosition()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\n# ");
		AddBytes(bytes, 0xC3, 0x28);
		AssertUtf8ErrorAtBothPaths(bytes, 2, 4, 9);
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

	[Test]
	public static void Utf8_OverlongSequenceOnLine2()
	{
		List<uint8> bytes = scope List<uint8>();
		AddAscii(bytes, "a = 1\n# ");
		AddBytes(bytes, 0xC0, 0xAF);
		AssertUtf8ErrorAtBothPaths(bytes, 2, 3, 8);
	}
}
