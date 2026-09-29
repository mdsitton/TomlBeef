using System;
using System.Collections;
using System.IO;
using TomlBeef;

namespace BeefTomlBench;

// The typed.toml model (see gen-inputs.py `typed` and ../typed.sh); every typed harness declares the same.

[TomlObject(Naming = .SnakeCase)]
class TypedLimits
{
	public int32 MaxConnections;
	public int32 TimeoutMs;
}

[TomlObject(Naming = .SnakeCase)]
class TypedServer
{
	public String Name ~ delete _;
	public String Host ~ delete _;
	public int32 Port;
	public bool Enabled;
	public double Weight;
	public List<String> Tags ~ DeleteContainerAndItems!(_);
	public TypedLimits Limits ~ delete _;
}

[TomlObject(Naming = .SnakeCase)]
class TypedRoot
{
	public String Title ~ delete _;
	public int32 Version;
	public bool Debug;
	public List<TypedServer> Servers ~ DeleteContainerAndItems!(_);

	/// "servers ports max_connections tags enabled", the same line every typed harness prints
	public void Check(String line)
	{
		int64 ports = 0, connections = 0, tags = 0, enabled = 0;
		for (let server in Servers)
		{
			ports += server.Port;
			connections += server.Limits.MaxConnections;
			tags += server.Tags.Count;
			if (server.Enabled)
				enabled++;
		}
		line.AppendF("check: {} {} {} {} {}", Servers.Count, ports, connections, tags, enabled);
	}
}

extension Program
{
	/// BeefTomlBench typed <read|read-plain|write> <file> <min-samples>
	///   read       - TomlSerializer.Read into a new TypedRoot (parses with Positions, for located errors)
	///   read-plain - doc.Read without metadata, then doc.Deserialize
	///   write      - TomlSerializer.Write of the model read once; MB/s of output
	static int TypedBench(String[] args)
	{
		StringView mode = args[1];
		String text = scope String();
		if (File.ReadAllText(args[2], text) case .Err)
			return 2;
		int minSamples = MinSamples(args[3]);

		let model = scope TypedRoot();
		if (TomlSerializer.Read(text, model) case .Err(let err))
		{
			Console.Error.WriteLine(scope $"read failed: {err}");
			return 1;
		}
		Console.WriteLine(model.Check(.. scope .()));

		String output = scope String();
		Measurement m;
		int bytes = text.Length;
		switch (mode)
		{
		case "read":
			m = Measure(minSamples, scope () =>
			{
				let root = scope TypedRoot();
				TomlSerializer.Read(text, root).IgnoreError();
			});
		case "read-plain":
			m = Measure(minSamples, scope () =>
			{
				let doc = scope TomlDocument();
				let root = scope TypedRoot();
				if (doc.Read(text) case .Ok)
					doc.Deserialize(root).IgnoreError();
			});
		case "write":
			m = Measure(minSamples, scope () => { output.Clear(); TomlSerializer.Write(model, output).IgnoreError(); });
			bytes = output.Length;
			// The written text must read back to the same values
			let back = scope TypedRoot();
			if (TomlSerializer.Read(output, back) case .Err(let err))
			{
				Console.Error.WriteLine(scope $"re-read failed: {err}");
				return 1;
			}
			Console.WriteLine(scope $"re-read {back.Check(.. scope .())}");
		default:
			Console.Error.WriteLine("mode: read, read-plain or write");
			return 2;
		}
		double ms = m.mMedianNs / 1e6;
		Console.WriteLine(scope $"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s ({m})");
		return 0;
	}
}
