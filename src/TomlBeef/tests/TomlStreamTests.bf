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
}
