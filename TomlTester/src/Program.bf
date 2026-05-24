using System;
using TomlBeef;

namespace TomlTester;

class Program
{
	public static int Main(String[] args)
	{
		String input = scope String();
		Console.In.ReadToEnd(input);

		if (input.IsEmpty)
		{
			Console.Error.WriteLine("No input on stdin");
			return 1;
		}

		TomlParser parser = scope TomlParser();
		switch (parser.Parse(input))
		{
		case .Err(let err):
			Console.Error.Write(scope $"Parse error at line {err.mLine}:{err.mColumn}: ");
			Console.Error.WriteLine(err.mMessage);
			return 1;
		case .Ok(let doc):
			defer delete doc;

			TomlSerializer serializer = scope TomlSerializer();
			String json = scope String();
			serializer.Serialize(doc, json);
			Console.WriteLine(json);
			return 0;
		}
	}
}
