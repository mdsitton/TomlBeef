using System;
using System.Collections;
using System.IO;
using TomlBeef;
using internal TomlBeef;

namespace TomlBeef;

public static class TomlTestSupport
{
	public const String TestBaseDir = "tests";

	public static Result<TomlDocument, TomlParseError> ParseFile(StringView path, TomlVersion version = .V1_1)
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

	public static void WalkTomlFiles(StringView dir, StringView excludeDir, delegate void(StringView path) onFile)
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

	public static bool TomlDocumentEquals(TomlDocument a, TomlDocument b)
	{
		return TomlTableEquals(a.RootTable, b.RootTable);
	}

	public static bool TomlTableEquals(TomlTable a, TomlTable b)
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

	public static bool TomlValueEquals(TomlValue a, TomlValue b)
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

	public static bool TomlArrayEquals(TomlArray a, TomlArray b)
	{
		if (a.Count != b.Count) return false;
		for (int i = 0; i < a.Count; i++)
			if (!TomlValueEquals(a.GetValue(i), b.GetValue(i))) return false;
		return true;
	}

	public static String GetRelativePath(StringView fullPath)
	{
		int prefixLen = TestBaseDir.Length + 1;
		if (fullPath.Length > prefixLen)
			return scope String(fullPath.Substring(prefixLen));
		return scope String(fullPath);
	}

	public static void AddAscii(List<uint8> bytes, StringView text)
	{
		for (int i = 0; i < text.Length; i++)
			bytes.Add((uint8)text[i]);
	}

	public static void AddByte(List<uint8> bytes, uint8 b)
	{
		bytes.Add(b);
	}

	public static void AddBytes(List<uint8> bytes, params uint8[] raw)
	{
		for (let b in raw)
			bytes.Add(b);
	}

	public static void AddRepeat(List<uint8> bytes, char8 c, int count)
	{
		for (int i = 0; i < count; i++)
			bytes.Add((uint8)c);
	}

	public static Result<void, TomlParseError> ReadFromByteStream(List<uint8> bytes)
	{
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		return doc.Read(ms);
	}

	public static void AssertReadErr(TomlErrorKind kind, Result<void, TomlParseError> result)
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
