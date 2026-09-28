using System;
using System.IO;
using TomlBeef;

namespace TomlTester;

/// Command-line driver used by the acceptance scripts and toml-test.
///
///   TomlTester [options] < input
///
/// Modes (default: decode TOML to toml-test tagged JSON):
///   -encode       Read TOML, write TOML (normal writer; with -preserve, the PreserveStyle writer)
///   -from-json    Read toml-test tagged JSON, write TOML (toml-test encoder)
/// Options:
///   -toml 1.0|1.1                 TOML version to read and write (default 1.1)
///   -preserve                     Read with MetadataMode = PreserveStyle
///   -positions                    Read with MetadataMode = Positions (source ranges only)
///   -max-input-bytes N, -max-depth N, -max-string-bytes N, -max-array-items N,
///   -max-table-entries N, -max-path-segments N, -max-nodes N
///                                 Resource limits (TomlReadConfig; 0 = unlimited)
/// Exit codes: 0 success, 1 invalid input (parse or limit error), 2 bad command line.
class Program
{
	public static int Main(String[] args)
	{
		bool encode = false;
		bool fromJson = false;
		int benchIterations = 0;
		var config = TomlReadConfig();
		for (int i = 0; i < args.Count; i++)
		{
			let arg = args[i];
			if (arg == "-encode")
				encode = true;
			else if (arg == "-from-json")
				fromJson = true;
			else if (arg == "-preserve")
				config.MetadataMode = .PreserveStyle;
			else if (arg == "-positions")
				config.MetadataMode = .Positions;
			else if (arg == "-bench" && i + 1 < args.Count)
			{
				switch (int.Parse(args[++i]))
				{
				case .Ok(let parsed) when parsed > 0: benchIterations = parsed;
				default: return UsageError("-bench needs a positive iteration count");
				}
			}
			else if (arg == "-toml" && i + 1 < args.Count)
			{
				let value = args[++i];
				if (value == "1.0")
					config.Version = .V1_0;
				else if (value == "1.1")
					config.Version = .V1_1;
				else
					return UsageError(scope $"Unknown TOML version '{value}'");
			}
			else if (arg.StartsWith("-max-") && i + 1 < args.Count)
			{
				int limit;
				switch (int.Parse(args[++i]))
				{
				case .Ok(let parsed) when parsed >= 0: limit = parsed;
				default: return UsageError(scope $"{arg} needs a non-negative integer");
				}
				switch (arg)
				{
				case "-max-input-bytes":   config.MaxInputBytes = limit;
				case "-max-depth":         config.MaxDepth = limit;
				case "-max-string-bytes":  config.MaxStringBytes = limit;
				case "-max-array-items":   config.MaxArrayItems = limit;
				case "-max-table-entries": config.MaxTableEntries = limit;
				case "-max-path-segments": config.MaxPathSegments = limit;
				case "-max-nodes":         config.MaxNodes = limit;
				default: return UsageError(scope $"Unknown option '{arg}'");
				}
			}
			else
				return UsageError(scope $"Unknown option '{arg}'");
		}

		if (benchIterations > 0)
			return Bench(benchIterations, config);

		var doc = new TomlDocument();
		defer delete doc;
		let writeConfig = TomlWriteConfig() { Version = config.Version };

		// Encoder mode for toml-test: tagged JSON on stdin, TOML on stdout
		if (fromJson)
		{
			String input = scope String();
			Console.In.ReadToEnd(input);
			String error = scope String();
			if (scope JsonToToml().Convert(input, doc, error) case .Err)
			{
				Console.Error.WriteLine(error);
				return 1;
			}
			String tomlOut = scope String();
			doc.Write(tomlOut, writeConfig);
			Console.Write(tomlOut);
			return 0;
		}

		// Parse straight from the stdin stream: memory stays bounded by MaxInputBytes and the
		// stream buffer rather than the whole input being read into a string first
		if (doc.Read(Console.In.BaseStream, config) case .Err(let err))
		{
			Console.Error.Write(scope $"Parse error at line {err.mLine}:{err.mColumn}: ");
			Console.Error.WriteLine(err.mMessage);
			return 1;
		}

		String output = scope String();
		if (encode)
			doc.Write(output, writeConfig);
		else
		{
			scope TomlSerializer().Serialize(doc, output);
			output.Append('\n');
		}
		Console.Write(output);
		return 0;
	}

	/// Times `iterations` parses of stdin through each input path, and writes of the parsed document.
	/// Build with -config=Release for meaningful numbers.
	static int Bench(int iterations, TomlReadConfig config)
	{
		String input = scope String();
		Console.In.ReadToEnd(input);
		let bytes = Span<uint8>((uint8*)input.Ptr, input.Length);

		var doc = scope TomlDocument();
		if (doc.Read(input, config) case .Err(let err))
		{
			Console.Error.WriteLine(scope $"Parse error at line {err.mLine}:{err.mColumn}: {err.mMessage}");
			return 1;
		}

		Console.WriteLine(scope $"input: {input.Length} bytes, {iterations} iterations, metadata: {config.MetadataMode}");
		BenchCase("Read(string)", iterations, input.Length, scope () => { doc.Read(input, config).IgnoreError(); });
		BenchCase("ReadBytes", iterations, input.Length, scope () => { doc.ReadBytes(bytes, config).IgnoreError(); });
		BenchCase("Read(Stream)", iterations, input.Length, scope () =>
		{
			let ms = scope MemoryStream();
			ms.TryWrite(bytes);
			ms.Position = 0;
			doc.Read(ms, config).IgnoreError();
		});
		String output = scope String();
		BenchCase("Write", iterations, input.Length, scope () => { output.Clear(); doc.Write(output); });
		return 0;
	}

	static void BenchCase(StringView name, int iterations, int bytesPerIteration, delegate void() action)
	{
		action(); // warm-up
		let watch = scope System.Diagnostics.Stopwatch(true);
		for (int i < iterations)
			action();
		watch.Stop();
		double seconds = watch.Elapsed.TotalSeconds;
		double mbPerSecond = seconds > 0 ? (double)bytesPerIteration * iterations / (1024.0 * 1024.0) / seconds : 0;
		Console.WriteLine(scope $"  {name,-14} {seconds * 1000.0 / iterations,10:F3} ms/op  {mbPerSecond,8:F1} MB/s");
	}

	static int UsageError(StringView message)
	{
		Console.Error.WriteLine(message);
		Console.Error.WriteLine("Usage: TomlTester [-encode | -from-json] [-toml 1.0|1.1] [-preserve | -positions] [-max-<limit> N ...] < input");
		return 2;
	}
}
