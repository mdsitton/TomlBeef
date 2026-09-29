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
		StringView lookupsPath = default;
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
			else if (arg == "-lookup" && i + 1 < args.Count)
				lookupsPath = args[++i];
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

		if (!lookupsPath.IsEmpty)
			return LookupBench(lookupsPath, Math.Max(benchIterations, 1), config);
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
			scope TomlTestJson().Serialize(doc, output);
			output.Append('\n');
		}
		Console.Write(output);
		return 0;
	}

	/// Times `iterations` parses of stdin through each input path, and writes of the parsed document.
	/// Build with -config=Release for meaningful numbers.
	/// Times each read path and the writer (see Measure). `-bench N` sets the minimum sample count.
	static int Bench(int minSamples, TomlReadConfig config)
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

		Console.WriteLine(scope $"input: {input.Length} bytes, min {minSamples} samples, metadata: {config.MetadataMode}");
		BenchCase("Read(string)", minSamples, input.Length, scope () => { doc.Read(input, config).IgnoreError(); });
		BenchCase("ReadBytes", minSamples, input.Length, scope () => { doc.ReadBytes(bytes, config).IgnoreError(); });
		BenchCase("Read(Stream)", minSamples, input.Length, scope () =>
		{
			let ms = scope MemoryStream();
			ms.TryWrite(bytes);
			ms.Position = 0;
			doc.Read(ms, config).IgnoreError();
		});
		String output = scope String();
		BenchCase("Write", minSamples, input.Length, scope () => { output.Clear(); doc.Write(output); });
		return 0;
	}

	/// Key lookups after parsing (bench/compare/lookup.sh): parses stdin once, then measures passes over
	/// the `table key` pairs in `lookupsPath` (see Measure), each reading the integer at root[table][key].
	/// Prints ns per lookup and the sum of the values found, which must match across libraries.
	static int LookupBench(StringView lookupsPath, int minSamples, TomlReadConfig config)
	{
		String input = scope String();
		Console.In.ReadToEnd(input);
		var doc = scope TomlDocument();
		if (doc.Read(input, config) case .Err(let err))
		{
			Console.Error.WriteLine(scope $"Parse error at line {err.mLine}:{err.mColumn}: {err.mMessage}");
			return 1;
		}
		String lookups = scope String();
		if (File.ReadAllText(lookupsPath, lookups) case .Err)
		{
			Console.Error.WriteLine(scope $"Cannot read {lookupsPath}");
			return 2;
		}
		var tables = scope System.Collections.List<StringView>();
		var keys = scope System.Collections.List<StringView>();
		for (let line in lookups.Split('\n', .RemoveEmptyEntries))
		{
			int space = line.IndexOf(' ');
			tables.Add(line.Substring(0, space));
			keys.Add(line.Substring(space + 1));
		}

		let root = doc.RootTable;
		int64 sum = 0;
		int missing = 0;
		let m = Measure(minSamples, scope [&] () =>
		{
			sum = 0;
			missing = 0;
			for (int i < tables.Count)
			{
				if (root.TryGetTable(tables[i], var table) && table.TryGetInteger(keys[i], var value))
					sum += value;
				else
					missing++;
			}
		});
		Console.WriteLine(scope $"{m.mMedianNs / tables.Count:F1} ns/lookup, {tables.Count} lookups, sum {sum}, missing {missing} ({m})");
		return 0;
	}

	struct Measurement
	{
		public double mMedianNs;
		public int mSamples;
		public bool mConverged;

		public override void ToString(String str)
		{
			str.AppendF("n={}, {}", mSamples, mConverged ? "converged" : "capped");
		}
	}

	/// The rule shared by every harness in bench/compare (see run.sh): warm up for at least 1 s (at least
	/// one run), then time single runs until at least `minSamples` were taken and at least 60% of them lie
	/// within ±10% of their median ("converged"), or 10 s of measuring or 1000 samples have passed. The
	/// median sample is reported.
	static Measurement Measure(int minSamples, delegate void() op)
	{
		let watch = scope System.Diagnostics.Stopwatch(true);
		repeat
			op();
		while (watch.Elapsed.TotalSeconds < 1);

		let samples = scope System.Collections.List<double>();
		let sorted = scope System.Collections.List<double>();
		watch.Restart();
		while (true)
		{
			let t0 = watch.Elapsed.Ticks;
			op();
			samples.Add((watch.Elapsed.Ticks - t0) * 100.0); // TimeSpan ticks are 100 ns
			sorted.Clear();
			sorted.AddRange(samples);
			sorted.Sort(scope (a, b) => a <=> b);
			int n = sorted.Count;
			double median = (n % 2 == 1) ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
			if (n >= minSamples)
			{
				int within = 0;
				for (let s in samples)
				{
					if (s >= median * 0.9 && s <= median * 1.1)
						within++;
				}
				if (within >= 0.6 * n)
					return .() { mMedianNs = median, mSamples = n, mConverged = true };
			}
			if (n >= 1000 || watch.Elapsed.TotalSeconds >= 10)
				return .() { mMedianNs = median, mSamples = n, mConverged = false };
		}
	}

	static void BenchCase(StringView name, int minSamples, int bytesPerIteration, delegate void() action)
	{
		let m = Measure(minSamples, action);
		double ms = m.mMedianNs / 1e6;
		double mbPerSecond = (double)bytesPerIteration / (1024.0 * 1024.0) / (ms / 1000.0);
		Console.WriteLine(scope $"  {name,-14} {ms,10:F3} ms/op  {mbPerSecond,8:F1} MB/s  ({m})");
	}

	static int UsageError(StringView message)
	{
		Console.Error.WriteLine(message);
		Console.Error.WriteLine("Usage: TomlTester [-encode | -from-json] [-toml 1.0|1.1] [-preserve | -positions] [-max-<limit> N ...] < input");
		return 2;
	}
}
