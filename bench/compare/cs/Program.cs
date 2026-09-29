// Tomlyn benchmark: TomlynBench <model|syntax> <file> <min-samples>
// Parse mode times single parses under the shared rule (see Measure and run.sh); the 1 s warm-up
// also lets the JIT compile the parser.
//   model  - TomlSerializer.Deserialize<TomlTable> (the runtime data model)
//   syntax - SyntaxParser.Parse (the lossless, trivia-preserving syntax tree)
// Key lookups (lookup.sh): TomlynBench lookup <model|syntax> <file> <lookups> <min-samples>
using System.Diagnostics;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Parsing;
using Tomlyn.Syntax;

if (args.Length >= 5 && args[0] == "lookup")
	return LookupBench(args);

if (args.Length < 3)
{
	Console.Error.WriteLine("usage: TomlynBench <model|syntax> <file> <min-samples>");
	return 2;
}

string mode = args[0];
string text = File.ReadAllText(args[1]);
int minSamples = int.Parse(args[2]);
long bytes = new FileInfo(args[1]).Length;

void ParseOnce()
{
	if (mode == "model")
	{
		var table = TomlSerializer.Deserialize<TomlTable>(text, (TomlSerializerOptions?)null);
		GC.KeepAlive(table);
	}
	else
	{
		var doc = SyntaxParser.Parse(text, "bench.toml", true);
		if (doc.HasErrors)
			throw new InvalidOperationException(doc.Diagnostics.ToString());
		GC.KeepAlive(doc);
	}
}

var (median, samples, converged) = Measure(minSamples, ParseOnce);
double ms = median / 1e6;
Console.WriteLine($"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s (n={samples}, {(converged ? "converged" : "capped")})");
return 0;

// Warm up for at least 1 s (at least one run), then time single runs until at least minSamples were
// taken and at least 60% lie within ±10% of their median, or 10 s / 1000 samples have passed.
static (double MedianNs, int Samples, bool Converged) Measure(int minSamples, Action op)
{
	var warm = Stopwatch.StartNew();
	do
		op();
	while (warm.Elapsed.TotalSeconds < 1);
	var start = Stopwatch.StartNew();
	var samples = new List<double>();
	while (true)
	{
		long t0 = Stopwatch.GetTimestamp();
		op();
		samples.Add(Stopwatch.GetElapsedTime(t0).TotalMilliseconds * 1e6);
		var sorted = samples.Order().ToList();
		int n = sorted.Count;
		double median = n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
		if (n >= minSamples && samples.Count(s => s >= median * 0.9 && s <= median * 1.1) >= 0.6 * n)
			return (median, n, true);
		if (n >= 1000 || start.Elapsed.TotalSeconds >= 10)
			return (median, n, false);
	}
}

// Key lookups after parsing: parses once, then measures passes, each reading the integer at
// root[table][key]. The syntax tree has no lookup API, so there a lookup scans the document's
// [table] headers and then that table's key/value lines, comparing bare-key text.
static int LookupBench(string[] args)
{
	string lib = args[1];
	string text = File.ReadAllText(args[2]);
	string[] lines = File.ReadAllLines(args[3]);
	int minSamples = int.Parse(args[4]);
	var tables = new string[lines.Length];
	var keys = new string[lines.Length];
	for (int i = 0; i < lines.Length; i++)
	{
		int space = lines[i].IndexOf(' ');
		tables[i] = lines[i][..space];
		keys[i] = lines[i][(space + 1)..];
	}

	Func<string, string, long?> lookup;
	if (lib == "model")
	{
		var root = TomlSerializer.Deserialize<TomlTable>(text, (TomlSerializerOptions?)null)!;
		lookup = (t, k) => root.TryGetValue(t, out var table) && table is TomlTable tt
			&& tt.TryGetValue(k, out var value) && value is long l ? l : null;
	}
	else
	{
		var doc = SyntaxParser.Parse(text, "bench.toml", true);
		if (doc.HasErrors)
		{
			Console.Error.WriteLine($"parse error: {doc.Diagnostics}");
			return 1;
		}
		lookup = (t, k) =>
		{
			foreach (var table in doc.Tables)
			{
				if (table.Name?.Key is not BareKeySyntax name || name.Key?.Text != t)
					continue;
				foreach (var item in table.Items)
				{
					if (item.Key?.Key is BareKeySyntax key && key.Key?.Text == k)
						return item.Value is IntegerValueSyntax number ? number.Value : null;
				}
				return null;
			}
			return null;
		};
	}

	long sum = 0;
	int missing = 0;
	var (median, samples, converged) = Measure(minSamples, () =>
	{
		sum = 0;
		missing = 0;
		for (int i = 0; i < tables.Length; i++)
		{
			if (lookup(tables[i], keys[i]) is long v)
				sum += v;
			else
				missing++;
		}
	});
	Console.WriteLine($"{median / tables.Length:F1} ns/lookup, {tables.Length} lookups, sum {sum}, missing {missing} " +
		$"(n={samples}, {(converged ? "converged" : "capped")})");
	return 0;
}
