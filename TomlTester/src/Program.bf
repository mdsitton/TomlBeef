using System;
using TomlBeef;

namespace TomlTester;

class Program
{
	public static int Main(String[] args)
	{
		bool encode = false;
		TomlVersion version = .V1_1;
		for (int i = 0; i < args.Count; i++)
		{
			if (args[i] == "-encode")
				encode = true;
			else if (args[i] == "-toml" && i + 1 < args.Count)
			{
				if (args[i + 1] == "1.0") version = .V1_0;
				else if (args[i + 1] == "1.1") version = .V1_1;
				i++;
			}
		}

		String input = scope String();
		Console.In.ReadToEnd(input);

		var doc = new TomlDocument();
		defer delete doc;

		if (doc.Read(input, .() { Version = version }) case .Err(let err))
		{
			defer err.Dispose();
			Console.Error.Write(scope $"Parse error at line {err.mLine}:{err.mColumn}: ");
			Console.Error.WriteLine(err.mMessage);
			return 1;
		}

		if (encode)
		{
			String tomlOut = scope String();
			doc.Write(tomlOut, .() { Version = version });
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
