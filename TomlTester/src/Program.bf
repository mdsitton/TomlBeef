using System;
using TomlBeef;

namespace TomlTester;

class Program
{
	public static int Main(String[] args)
	{
		bool encode = false;
		for (int i = 0; i < args.Count; i++)
		{
			if (args[i] == "-encode")
				encode = true;
		}

		String input = scope String();
		Console.In.ReadToEnd(input);

		TomlParser parser = scope TomlParser();
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
				TomlWriter writer = scope TomlWriter();
				String tomlOut = scope String();
				writer.Write(doc, tomlOut);
				Console.WriteLine(tomlOut);
			}
			else
			{
				TomlSerializer serializer = scope TomlSerializer();
				String json = scope String();
				serializer.Serialize(doc, json);
				Console.WriteLine(json);
			}
			return 0;
		}
	}
}
