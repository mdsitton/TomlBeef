// Tomlyn benchmark: TomlynBench <model|syntax> <file> <iterations>
// Reads the file once, parses it once to warm up, then times up to <iterations> parses within a
// 3 s budget.
//   model  - TomlSerializer.Deserialize<TomlTable> (the runtime data model)
//   syntax - SyntaxParser.Parse (the lossless, trivia-preserving syntax tree)
using System.Diagnostics;
using Tomlyn;
using Tomlyn.Model;
using Tomlyn.Parsing;

if (args.Length < 3)
{
	Console.Error.WriteLine("usage: TomlynBench <model|syntax> <file> <iterations>");
	return 2;
}

string mode = args[0];
string text = File.ReadAllText(args[1]);
int iterations = int.Parse(args[2]);
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

ParseOnce();
// Stop after <iterations> parses or 3 s, whichever comes first (at least one)
var sw = Stopwatch.StartNew();
int done = 0;
while (done < iterations && (done == 0 || sw.Elapsed.TotalSeconds < 3))
{
	ParseOnce();
	done++;
}
double ms = sw.Elapsed.TotalMilliseconds / done;
Console.WriteLine($"{ms:F3} ms/op {bytes / 1048576.0 / (ms / 1000.0):F1} MB/s");
return 0;
