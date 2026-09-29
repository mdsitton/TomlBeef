// Typed serialization of typed.toml (../typed.sh): TomlynBench typed <reflection|sourcegen> <read|write> <file> <min-samples>
//   reflection - TomlSerializer.Deserialize<TypedRoot> / Serialize with a snake_case naming policy
//   sourcegen  - the same through the source-generated TypedContext (Tomlyn's NativeAOT path)
// read times text -> new TypedRoot (MB/s of input); write times the model read once -> text (MB/s of output).
using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using Tomlyn;
using Tomlyn.Serialization;

public sealed class TypedLimits
{
	public int MaxConnections { get; set; }
	public int TimeoutMs { get; set; }
}

public sealed class TypedServer
{
	public string Name { get; set; } = "";
	public string Host { get; set; } = "";
	public int Port { get; set; }
	public bool Enabled { get; set; }
	public double Weight { get; set; }
	public List<string> Tags { get; set; } = new();
	public TypedLimits Limits { get; set; } = new();
}

public sealed class TypedRoot
{
	public string Title { get; set; } = "";
	public int Version { get; set; }
	public bool Debug { get; set; }
	public List<TypedServer> Servers { get; set; } = new();

	// "servers ports max_connections tags enabled", the same line every typed harness prints
	public string Check() =>
		$"check: {Servers.Count} {Servers.Sum(s => (long)s.Port)} {Servers.Sum(s => (long)s.Limits.MaxConnections)} " +
		$"{Servers.Sum(s => s.Tags.Count)} {Servers.Count(s => s.Enabled)}";
}

[TomlSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.SnakeCaseLower)]
[TomlSerializable(typeof(TypedRoot))]
internal partial class TypedContext : TomlSerializerContext
{
}

static class TypedBench
{
	public static int Run(string[] args)
	{
		string path = args[1] == "reflection" || args[1] == "sourcegen" ? args[3] : "";
		bool sourceGen = args[1] == "sourcegen";
		string mode = args[2];
		string text = File.ReadAllText(path);
		int minSamples = int.Parse(args[4]);
		var options = new TomlSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

		TypedRoot Read(string toml) => sourceGen
			? TomlSerializer.Deserialize(toml, TypedContext.Default.TypedRoot)!
			: TomlSerializer.Deserialize<TypedRoot>(toml, options)!;
		string Write(TypedRoot root) => sourceGen
			? TomlSerializer.Serialize(root, TypedContext.Default.TypedRoot)
			: TomlSerializer.Serialize(root, options);

		var model = Read(text);
		Console.WriteLine(model.Check());

		long bytes = System.Text.Encoding.UTF8.GetByteCount(text);
		(double median, int samples, bool converged) result;
		if (mode == "read")
			result = Measure(minSamples, () => GC.KeepAlive(Read(text)));
		else
		{
			string output = "";
			result = Measure(minSamples, () => output = Write(model));
			bytes = System.Text.Encoding.UTF8.GetByteCount(output);
			Console.WriteLine($"re-read {Read(output).Check()}");
		}
		double ms = result.median / 1e6;
		Console.WriteLine($"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s (n={result.samples}, {(result.converged ? "converged" : "capped")})");
		return 0;
	}

	// The shared rule (see Program.cs Measure and ../run.sh)
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
}
