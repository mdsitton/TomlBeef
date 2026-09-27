using System;
using System.Collections;
using System.IO;
using TomlBeef;
using internal TomlBeef;
using static TomlBeef.TomlTestSupport;

namespace TomlBeef;

static class TomlCorpusTests
{
	/// Every valid fixture must decode to the same document through all four input paths.
	[Test]
	public static void InputPathsDecodeIdentically()
	{
		let validDir = scope $"{TestBaseDir}/valid";
		Test.Assert(Directory.Exists(validDir), scope $"Test directory not found: {validDir}");
		int compared = 0;
		WalkTomlFiles(validDir, null, scope [&] (path) =>
		{
			let name = GetRelativePath(path);
			let fromFile = scope TomlDocument();
			if (fromFile.ReadFile(path) case .Err(let fileErr))
			{
				defer fileErr.Dispose();
				Test.Assert(false, scope $"ReadFile failed [{name}]: {fileErr.mMessage}");
				return;
			}

			let data = scope List<uint8>();
			if (File.ReadAll(path, data) case .Err)
			{
				Test.Assert(false, scope $"Cannot read [{name}]");
				return;
			}
			let text = StringView((char8*)data.Ptr, data.Count);

			let fromString = scope TomlDocument();
			let fromBytes = scope TomlDocument();
			let fromStream = scope TomlDocument();
			let ms = scope MemoryStream(data, false);
			let results = scope Result<void, TomlParseError>[](
				fromString.Read(text),
				fromBytes.ReadBytes(Span<uint8>(data.Ptr, data.Count)),
				fromStream.Read(ms));
			let pathNames = scope String[]("Read(string)", "ReadBytes", "Read(Stream)");
			let docs = scope TomlDocument[](fromString, fromBytes, fromStream);
			for (int i < results.Count)
			{
				if (results[i] case .Err(let e))
				{
					defer e.Dispose();
					Test.Assert(false, scope $"{pathNames[i]} failed [{name}]: {e.mMessage}");
				}
				else if (!TomlDocumentEquals(fromFile, docs[i]))
					Test.Assert(false, scope $"{pathNames[i]} decoded differently from ReadFile [{name}]");
			}
			compared++;
		});
		Test.Assert(compared >= 266, scope $"Expected >= 266 fixtures compared, got {compared}");
	}

	/// Every valid fixture must produce identical PreserveStyle output whether read from bytes or from a
	/// stream with a tiny buffer, which forces refills and spills inside nested marked tokens.
	[Test]
	public static void StreamPreserveStyleMatchesBytes()
	{
		let validDir = scope $"{TestBaseDir}/valid";
		Test.Assert(Directory.Exists(validDir), scope $"Test directory not found: {validDir}");
		let savedBufferBytes = TomlDocument.sStreamBufferBytes;
		TomlDocument.sStreamBufferBytes = 64;
		defer { TomlDocument.sStreamBufferBytes = savedBufferBytes; }

		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		int compared = 0;
		WalkTomlFiles(validDir, null, scope [&] (path) =>
		{
			let name = GetRelativePath(path);
			let data = scope List<uint8>();
			if (File.ReadAll(path, data) case .Err)
			{
				Test.Assert(false, scope $"Cannot read [{name}]");
				return;
			}

			let fromBytes = scope TomlDocument();
			if (fromBytes.ReadBytes(Span<uint8>(data.Ptr, data.Count), config) case .Err(let e1))
			{
				defer e1.Dispose();
				Test.Assert(false, scope $"ReadBytes failed [{name}]: {e1.mMessage}");
				return;
			}
			let ms = scope MemoryStream(data, false);
			let fromStream = scope TomlDocument();
			if (fromStream.Read(ms, config) case .Err(let e2))
			{
				defer e2.Dispose();
				Test.Assert(false, scope $"Stream read failed [{name}]: {e2.mMessage}");
				return;
			}

			String outBytes = scope String();
			fromBytes.Write(outBytes);
			String outStream = scope String();
			fromStream.Write(outStream);
			Test.Assert(outBytes == outStream, scope $"Stream/bytes PreserveStyle output differs [{name}]\nbytes:\n{outBytes}\nstream:\n{outStream}");
			compared++;
		});
		Test.Assert(compared >= 266, scope $"Expected >= 266 fixtures compared, got {compared}");
	}

	[Test]
	public static void VerifyTestFilesFound()
	{
		int validCount = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/valid", null, scope [&] (path) => { validCount++; });
		Test.Assert(validCount > 0, scope $"No .toml files found in {TestBaseDir}/valid");

		int invalidCount = 0;
		WalkTomlFiles(scope $"{TestBaseDir}/invalid", null, scope [&] (path) => { invalidCount++; });
		Test.Assert(invalidCount > 0, scope $"No .toml files found in {TestBaseDir}/invalid");
		Test.Assert(validCount >= 266, scope $"Expected >= 266 valid fixtures, found {validCount}");
		Test.Assert(invalidCount >= 503, scope $"Expected >= 503 invalid fixtures, found {invalidCount}");
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
			case .Ok(let doc): delete doc;
				Test.Assert(false, scope $"Unexpectedly accepted (v1.1): {path}"); failed++;
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
			case .Ok(let doc): delete doc;
				Test.Assert(false, scope $"Unexpectedly accepted (v1.0): {path}"); failed++;
			}
		});
		Test.Assert(passed > 0, scope $"v1.0: {passed} passed, {failed} failed");
		Test.Assert(failed == 0, scope $"v1.0: {passed} passed, {failed} failed");
	}
}
