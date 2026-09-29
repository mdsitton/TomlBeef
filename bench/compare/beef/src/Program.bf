using System;
using System.Collections;
using System.Diagnostics;
using System.IO;
using Beefy.utils;
using TomlBeef;

namespace BeefTomlBench;

/// Compares TomlBeef with Beef's built-in TOML reader, Beefy.utils.StructuredData (what the IDE and
/// BeefBuild use for BeefProj.toml / BeefSpace.toml), built into one program by the same compiler.
///
///   BeefTomlBench check <files or dirs...>
///       Loads each file with both and compares the trees value by value.
///   BeefTomlBench parse <structured|tomlbeef|tomlbeef-preserve> <min-samples> <files or dirs...>
///       One sample parses every file once; prints MB/s over their total size.
///   BeefTomlBench lookup <structured|tomlbeef> <file> <lookups> <min-samples>
///       Parses once, then times passes over `table key` lookups of integers.
///   BeefTomlBench write <structured|tomlbeef> <min-samples> <file>
///       Parses once, then times serializing it back to TOML.
///   BeefTomlBench typed <read|read-plain|write> <file> <min-samples>
///       TomlBeef's [TomlObject] serialization of typed.toml (Typed.bf, ../typed.sh).
///
/// Timings follow the rule every harness in bench/compare uses (see ../run.sh and Measure).
class Program
{
	public static int Main(String[] args)
	{
		if (args.Count >= 2 && args[0] == "check")
			return Check(args);
		if (args.Count >= 4 && args[0] == "parse")
			return ParseBench(args);
		if (args.Count >= 5 && args[0] == "lookup")
			return LookupBench(args);
		if (args.Count >= 4 && args[0] == "write")
			return WriteBench(args);
		if (args.Count >= 4 && args[0] == "typed")
			return TypedBench(args);
		Console.Error.WriteLine("usage: BeefTomlBench check|parse|lookup|write ... (see Program.bf)");
		return 2;
	}

	// ---- Measurement (the shared rule) ----

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

	/// Warm up for at least 1 s (at least one run), then time single runs until at least `minSamples`
	/// were taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
	static Measurement Measure(int minSamples, delegate void() op)
	{
		let watch = scope Stopwatch(true);
		repeat
			op();
		while (watch.Elapsed.TotalSeconds < 1);

		let samples = scope List<double>();
		let sorted = scope List<double>();
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

	static int MinSamples(StringView arg)
	{
		if (int.Parse(arg) case .Ok(let value) && value > 0)
			return value;
		return 5;
	}

	// ---- Inputs ----

	/// Adds the *.toml files under `dir` (recursively, sorted) to `files`.
	static void FindTomlFiles(StringView dir, List<String> files)
	{
		let found = scope List<String>();
		for (let entry in Directory.EnumerateFiles(dir, "*.toml"))
			found.Add(entry.GetFilePath(.. new String()));
		found.Sort(scope (a, b) => a <=> b);
		files.AddRange(found);
		let subdirs = scope List<String>();
		defer { ClearAndDeleteItems!(subdirs); }
		for (let entry in Directory.EnumerateDirectories(dir))
			subdirs.Add(entry.GetFilePath(.. new String()));
		subdirs.Sort(scope (a, b) => a <=> b);
		for (let subdir in subdirs)
			FindTomlFiles(subdir, files);
	}

	/// Expands files and directories (their *.toml files, recursively and sorted) and reads each into
	/// `texts`.
	static void ReadInputs(Span<String> paths, List<String> names, List<String> texts)
	{
		let files = scope List<String>();
		for (let path in paths)
		{
			if (Directory.Exists(path))
				FindTomlFiles(path, files);
			else
				files.Add(new String(path));
		}
		for (let file in files)
		{
			let text = new String();
			if (File.ReadAllText(file, text) case .Err)
			{
				Console.Error.WriteLine(scope $"cannot read {file}");
				delete text;
				delete file;
				continue;
			}
			names.Add(file);
			texts.Add(text);
		}
	}

	// ---- check: value-by-value comparison ----

	/// What the comparison found beyond exact equality: representation limits of StructuredData that
	/// are not errors in themselves (it keeps date/times as text and parses floats as float32).
	struct Differences
	{
		public int mDatesAsText;
		public int mFloat32;
	}

	/// Compares StructuredData's current value with `expected`. On a mismatch sets `why`.
	static bool Same(StructuredData sd, TomlValue expected, String path, ref Differences diff, String why)
	{
		Object actual = sd.GetCurrent();
		switch (expected)
		{
		case .Table(let table):
			if (!(actual is StructuredData.NamedValues))
			{
				why.AppendF("{}: expected a table", path);
				return false;
			}
			int count = 0;
			bool ok = true;
			for (let key in sd.Enumerate())
			{
				count++;
				let childPath = scope String()..AppendF("{}.{}", path, key);
				if (!(table.Get(key) case .Ok(let child)))
				{
					why.AppendF("{}: unexpected key", childPath);
					ok = false;
					break;
				}
				if (!Same(sd, child, childPath, ref diff, why))
				{
					ok = false;
					break;
				}
			}
			if (ok && count != table.Count)
			{
				why.AppendF("{}: {} keys, expected {}", path, count, table.Count);
				ok = false;
			}
			return ok;
		case .Array(let array):
			if (!(actual is StructuredData.Values) || actual is StructuredData.NamedValues)
			{
				why.AppendF("{}: expected an array", path);
				return false;
			}
			int count = 0;
			bool ok = true;
			for (let element in sd.Enumerate())
			{
				let childPath = scope String()..AppendF("{}[{}]", path, count);
				if (count >= array.Count || !Same(sd, array.GetValueAt(count), childPath, ref diff, why))
				{
					if (count >= array.Count)
						why.AppendF("{}: extra element", childPath);
					ok = false;
					break;
				}
				count++;
			}
			if (ok && count != array.Count)
			{
				why.AppendF("{}: {} elements, expected {}", path, count, array.Count);
				ok = false;
			}
			return ok;
		case .String(let s):
			if (actual is String && (String)actual == s)
				return true;
		case .Integer(let v):
			if (actual is int64 && (int64)actual == v)
				return true;
		case .Bool(let v):
			if (actual is bool && (bool)actual == v)
				return true;
		case .Float(let v):
			if (actual is float && ((float)actual == (float)v || (v.IsNaN && ((float)actual).IsNaN)))
			{
				if ((double)(float)v != v)
					diff.mFloat32++;
				return true;
			}
		case .OffsetDateTime, .LocalDateTime, .LocalDate, .LocalTime:
			// StructuredData keeps any value containing '-' or ':' as its raw text
			if (actual is String)
			{
				diff.mDatesAsText++;
				return true;
			}
		}
		why.AppendF("{}: got {}, expected {}", path, Describe(actual, .. scope String()), expected.TypeName);
		return false;
	}

	static void Describe(Object value, String str)
	{
		if (value == null)
			str.Append("nothing");
		else if (value is String)
			str.AppendF("string \"{}\"", (String)value);
		else if (value is int64)
			str.AppendF("integer {}", (int64)value);
		else if (value is float)
			str.AppendF("float {}", (float)value);
		else if (value is bool)
			str.AppendF("bool {}", (bool)value);
		else
			str.Append(value.GetType().GetName(.. scope String()));
	}

	static int Check(String[] args)
	{
		let names = scope List<String>();
		let texts = scope List<String>();
		defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(texts); }
		ReadInputs(Span<String>(args.Ptr + 1, args.Count - 1), names, texts);

		int exact = 0, withLimits = 0, differ = 0, sdOnlyError = 0, tbOnlyError = 0, bothError = 0;
		int datesAsText = 0, float32 = 0;
		bool verbose = names.Count <= 20;
		for (int i < names.Count)
		{
			var doc = scope TomlDocument();
			bool tbOk = doc.Read(texts[i]) case .Ok;
			var sd = scope StructuredData();
			bool sdOk = sd.LoadFromString(texts[i]) case .Ok;
			String result = scope String();
			if (!tbOk && !sdOk)
			{
				bothError++;
				result.Append("both reject");
			}
			else if (!sdOk)
			{
				sdOnlyError++;
				result.Append("StructuredData error");
			}
			else if (!tbOk)
			{
				tbOnlyError++;
				result.Append("TomlBeef rejects, StructuredData accepts");
			}
			else
			{
				Differences diff = default;
				String why = scope String();
				if (!Same(sd, .Table(doc.RootTable), "", ref diff, why))
				{
					differ++;
					result.AppendF("values differ: {}", why);
				}
				else if (diff.mDatesAsText > 0 || diff.mFloat32 > 0)
				{
					withLimits++;
					datesAsText += diff.mDatesAsText;
					float32 += diff.mFloat32;
					result.AppendF("match except {} date/times kept as text, {} floats rounded to float32", diff.mDatesAsText, diff.mFloat32);
				}
				else
				{
					exact++;
					result.Append("exact match");
				}
			}
			if (verbose)
				Console.WriteLine(scope $"{Path.GetFileName(names[i], .. scope String())}: {result}");
		}
		Console.WriteLine(scope $"{names.Count} files: {exact} exact match, {withLimits} match except date/time text or float32 ({datesAsText} date/times, {float32} floats), {differ} values differ, {sdOnlyError} StructuredData error only, {tbOnlyError} TomlBeef error only, {bothError} both reject");
		return 0;
	}

	// ---- parse ----

	static int ParseBench(String[] args)
	{
		StringView lib = args[1];
		int minSamples = MinSamples(args[2]);
		let names = scope List<String>();
		let texts = scope List<String>();
		defer { ClearAndDeleteItems!(names); ClearAndDeleteItems!(texts); }
		ReadInputs(Span<String>(args.Ptr + 3, args.Count - 3), names, texts);

		// Both libraries time the same set: files either one rejects are skipped (and counted), since
		// timing a failure measures nothing comparable
		int skipped = 0;
		for (int i = texts.Count - 1; i >= 0; i--)
		{
			bool sdOk = scope StructuredData().LoadFromString(texts[i]) case .Ok;
			bool tbOk = scope TomlDocument().Read(texts[i]) case .Ok;
			if (!sdOk || !tbOk)
			{
				delete names[i];
				delete texts[i];
				names.RemoveAt(i);
				texts.RemoveAt(i);
				skipped++;
			}
		}
		if (texts.IsEmpty)
		{
			Console.Error.WriteLine("parse error: no file parses with both libraries");
			return 1;
		}
		int64 bytes = 0;
		for (let text in texts)
			bytes += text.Length;

		Measurement m;
		if (lib == "structured")
		{
			m = Measure(minSamples, scope () =>
			{
				for (let text in texts)
				{
					let sd = scope:: StructuredData();
					sd.LoadFromString(text).IgnoreError();
				}
			});
		}
		else
		{
			TomlReadConfig config = .() { MetadataMode = (lib == "tomlbeef-preserve") ? .PreserveStyle : .None };
			// One document per file, reused across samples like TomlTester's -bench (Read replaces it)
			let docs = scope List<TomlDocument>();
			defer { ClearAndDeleteItems!(docs); }
			for (int i < texts.Count)
				docs.Add(new TomlDocument());
			m = Measure(minSamples, scope () =>
			{
				for (int i < texts.Count)
					docs[i].Read(texts[i], config).IgnoreError();
			});
		}
		double ms = m.mMedianNs / 1e6;
		Console.WriteLine(scope $"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s ({texts.Count} files, {skipped} skipped, {m})");
		return 0;
	}

	// ---- lookup ----

	static int LookupBench(String[] args)
	{
		StringView lib = args[1];
		String text = scope String();
		String lookups = scope String();
		if (File.ReadAllText(args[2], text) case .Err || File.ReadAllText(args[3], lookups) case .Err)
			return 2;
		int minSamples = MinSamples(args[4]);
		let tables = scope List<StringView>();
		let keys = scope List<StringView>();
		for (let line in lookups.Split('\n', .RemoveEmptyEntries))
		{
			int space = line.IndexOf(' ');
			tables.Add(line.Substring(0, space));
			keys.Add(line.Substring(space + 1));
		}

		int64 sum = 0;
		int missing = 0;
		Measurement m;
		if (lib == "structured")
		{
			let sd = scope StructuredData();
			if (sd.LoadFromString(text) case .Err)
			{
				Console.Error.WriteLine("parse error");
				return 1;
			}
			// The IDE's access pattern: Open(section), then read a key in it
			m = Measure(minSamples, scope [&] () =>
			{
				sum = 0;
				missing = 0;
				for (int i < tables.Count)
				{
					using (sd.Open(tables[i]))
					{
						if (sd.TryGet(keys[i], var value) && value is int64)
							sum += (int64)value;
						else
							missing++;
					}
				}
			});
		}
		else
		{
			let doc = scope TomlDocument();
			if (doc.Read(text) case .Err)
			{
				Console.Error.WriteLine("parse error");
				return 1;
			}
			let root = doc.RootTable;
			m = Measure(minSamples, scope [&] () =>
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
		}
		Console.WriteLine(scope $"{m.mMedianNs / tables.Count:F1} ns/lookup, {tables.Count} lookups, sum {sum}, missing {missing} ({m})");
		return 0;
	}

	// ---- write ----

	static int WriteBench(String[] args)
	{
		StringView lib = args[1];
		int minSamples = MinSamples(args[2]);
		String text = scope String();
		if (File.ReadAllText(args[3], text) case .Err)
			return 2;
		String output = scope String();
		Measurement m;
		if (lib == "structured")
		{
			let sd = scope StructuredData();
			if (sd.LoadFromString(text) case .Err)
			{
				Console.Error.WriteLine("parse error");
				return 1;
			}
			m = Measure(minSamples, scope () => { output.Clear(); sd.ToTOML(output); });
		}
		else
		{
			let doc = scope TomlDocument();
			if (doc.Read(text) case .Err)
			{
				Console.Error.WriteLine("parse error");
				return 1;
			}
			m = Measure(minSamples, scope () => { output.Clear(); doc.Write(output); });
		}
		double ms = m.mMedianNs / 1e6;
		Console.WriteLine(scope $"{ms:F3} ms/op {output.Length / 1048576.0 / (ms / 1000.0):F1} MB/s of output ({m})");
		return 0;
	}
}
