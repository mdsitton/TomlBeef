using System;
using System.IO;
using System.Collections;
using TomlBeef;

namespace TomlTester;

class Program
{
	public static int Main(String[] args)
	{
		if (args.Count > 0 && args[0] == "-test")
		{
			if (args.Count > 1 && args[1] == "-hardcoded")
				return TestHardcoded();
			if (args.Count > 1)
				return TestSingle(args[1]);
			return RunTests();
		}

		bool encode = false;
		for (int i = 0; i < args.Count; i++)
		{
			if (args[i] == "-encode")
				encode = true;
		}

		String input = scope String();
		Console.In.ReadToEnd(input);

		var parser = scope TomlParser();
		switch (parser.Parse(input))
		{
		case .Err(let err):
			defer err.Dispose();
			Console.Error.Write(scope $"Parse error at line {err.mLine}:{err.mColumn}: ");
			Console.Error.WriteLine(err.mMessage);
			return 1;
		case .Ok(let doc):
			defer delete doc;

			if (encode)
			{
				var writer = scope TomlWriter();
				String tomlOut = scope String();
				writer.Write(doc, tomlOut);
				Console.WriteLine(tomlOut);
			}
			else
			{
				var serializer = scope TomlSerializer();
				String json = scope String();
				serializer.Serialize(doc, json);
				Console.WriteLine(json);
			}
			return 0;
		}
	}

	private static int TestHardcoded()
	{
		var input = new String("x = 42");
		defer delete input;
		System.IO.File.WriteAllText("/tmp/beef_test1.log", "Starting");
		var parser = scope TomlParser();
		System.IO.File.WriteAllText("/tmp/beef_test2.log", "Parser created");
		var result = parser.Parse(input);
		System.IO.File.WriteAllText("/tmp/beef_test3.log", "Parse returned");
		return 0;
	}

	private static int TestSingle(StringView path)
	{
		Console.WriteLine(scope $"Parsing: {path}");

		String content = scope String();
		switch (File.ReadAllText(path, content))
		{
		case .Err:
			Console.WriteLine("ReadAllText FAILED");
			return 1;
		case .Ok:
		}
		Console.WriteLine(scope $"Read OK, {content.Length} bytes");
		Console.Out.Flush();

		var parser = new TomlParser();
		defer delete parser;
		Console.WriteLine("Calling Parse...");
		Console.Out.Flush();
		var result = parser.Parse(content);
		Console.WriteLine("Parse returned");
		Console.Out.Flush();

		switch (result)
		{
		case .Err(let e):
			Console.WriteLine(scope $"Parse FAILED: {e.mMessage}");
			e.Dispose();
			return 1;
		case .Ok(let doc):
			defer delete doc;
			Console.WriteLine(scope $"Parse OK, {doc.mRootTable.Count} root keys");
		}
		return 0;
	}

	private static int RunTests()
	{
		const String baseDir = "toml-test/tests";
		int validPassed = 0, validFailed = 0;
		int invalidPassed = 0, invalidFailed = 0;

		Console.WriteLine("=== Round-Trip Tests ===");
		int passed = 0, failed = 0;
		WalkTomlFiles(scope $"{baseDir}/valid" , scope [&] (path) =>
			{
				Console.Write(scope $"\n  [{path}] ");
				Console.Out.Flush();
				let result = ParseFile(path);
				Console.Write("OK");
				Console.Out.Flush();
			});
		Console.WriteLine();
		Console.WriteLine("Walk complete");
		return 0;
		Console.WriteLine();
		Console.WriteLine("Walk complete");
		return 0;
		Console.WriteLine(scope $"Valid parse: {passed} passed, {failed} failed");
		return (failed == 0) ? 0 : 1;

		Console.WriteLine("\n=== Invalid Tests ===");
		WalkTomlFiles(scope $"{baseDir}/invalid" , scope [&] (path) =>
			{
				let name = GetRelName(path);
				switch (ParseFile(path))
				{
				case .Err:
					invalidPassed++;
				case .Ok(let doc):
					delete doc;
					Console.WriteLine(scope $"  FAIL [{name}]: should have failed");
					invalidFailed++;
				}
			});
		Console.WriteLine(scope $"Invalid: {invalidPassed} passed, {invalidFailed} failed");

		int totalFailed = validFailed + invalidFailed;
		Console.WriteLine(scope $"\nTotal: {validPassed + validFailed} valid, {invalidPassed + invalidFailed} invalid, {totalFailed} failures");
		return (totalFailed == 0) ? 0 : 1;
	}

	private static Result<TomlDocument, TomlParseError> ParseFile(StringView path)
	{
		String content = scope String();
		switch (File.ReadAllText(path, content))
		{
		case .Err:
			return .Err(TomlParseError(.InvalidUtf8, scope $"Cannot read: {path}" , 0, 0, 0));
		default:
		}
		var parser = new TomlParser();
		defer delete parser;
		return parser.Parse(content);
	}

	private static void WalkTomlFiles(StringView dir, delegate void(StringView path) onFile)
	{
		for (let entry in Directory.EnumerateFiles(dir))
		{
			let p = entry.GetFilePath(.. scope .());
			if (p.EndsWith(".toml"))
				onFile(p);
		}
		for (let entry in Directory.EnumerateDirectories(dir))
		{
			WalkTomlFiles(entry.GetFilePath(.. scope .()), onFile);
		}
	}

	private static String GetRelName(StringView fullPath)
	{
		int p = "toml-test/tests/".Length;
		if (fullPath.Length > p)
			return scope String(fullPath.Substring(p));
		return scope String(fullPath);
	}
}
