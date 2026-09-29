using System;
using System.Collections;
using TomlBeef;

namespace TomlBeef;

enum SerLogLevel
{
	Debug,
	Info,
	Warn
}

[TomlObject(Naming = .SnakeCase)]
struct SerEndpoint
{
	public String Host;
	public uint16 Port;
}

[TomlObject(Naming = .SnakeCase)]
class SerDatabase
{
	public String Url = new .() ~ delete _;
	public int32 PoolSize = 4;
	public double Timeout = 1.5;
}

[TomlObject(Naming = .SnakeCase)]
class SerPlugin
{
	public String Name ~ delete _;
	public bool Enabled;
}

[TomlObject(Naming = .SnakeCase)]
class SerServerConfig
{
	[TomlRequired] public String Name = new .() ~ delete _;
	public int32 Port = 8080;
	public uint8 Retries = 3;
	public float Ratio;
	public bool Debug;
	[TomlName("log-level")] public SerLogLevel Level = .Info;
	public TomlLocalDate Released;
	public TomlOffsetDateTime Started;
	public SerDatabase Db = new .() ~ delete _;
	public SerEndpoint Admin;
	public List<String> Tags = new .() ~ DeleteContainerAndItems!(_);
	public List<int64> Ports ~ delete _;
	public List<SerLogLevel> Levels = new .() ~ delete _;
	public List<SerPlugin> Plugins = new .() ~ DeleteContainerAndItems!(_);
	[TomlIgnore] public int Scratch = 42;
	int mPrivate = 7;
	public static int sShared = 1;

	public int Private => mPrivate;

	public ~this()
	{
		delete Admin.Host;
	}
}

[TomlObject]
class SerBaseSettings
{
	public String Title = new .() ~ delete _;
}

[TomlObject]
class SerDerivedSettings : SerBaseSettings
{
	public int32 Extra;
}

[TomlObject(Naming = .KebabCase)]
class SerNaming
{
	public int HTTPPort;
	public int Utf8Name;
	public int max_depth;
	[TomlName("a key.with dots")] public int Odd;
}

[TomlObject(Naming = .CamelCase)]
class SerCamel
{
	public int PoolSize;
	public int HTTPPort;
}

static class TomlSerializerTests
{
	const String cConfig = """
		name = "api"
		port = 9000
		retries = 5
		ratio = 2
		debug = true
		log-level = "Warn"
		released = 2024-05-01
		started = 2024-05-01T08:30:00Z
		tags = ["a", "b"]
		ports = [1, 2, 3]
		levels = ["Debug", "Warn"]
		scratch = 1

		[db]
		url = "postgres://db"
		pool_size = 16

		[admin]
		host = "localhost"
		port = 8443

		[[plugins]]
		name = "auth"
		enabled = true

		[[plugins]]
		name = "cache"
		""";

	static void ReadOk<T>(StringView toml, T target) where T : class, ITomlSerializable
	{
		if (TomlSerializer.Read(toml, target) case .Err(let err))
			Test.Assert(false, scope $"{err.mLine}:{err.mColumn}: {err.mMessage}");
	}

	[Test]
	public static void Read_FillsEveryKindOfField()
	{
		let config = scope SerServerConfig();
		config.Tags.Add(new String("old"));
		ReadOk(cConfig, config);

		Test.Assert(config.Name == "api" && config.Port == 9000 && config.Retries == 5);
		Test.Assert(config.Ratio == 2 && config.Debug && config.Level == .Warn);
		Test.Assert(config.Released == TomlLocalDate(2024, 5, 1));
		Test.Assert(config.Started.mHour == 8 && config.Started.mMinute == 30 && config.Started.mOffsetMinutes == 0);
		Test.Assert(config.Tags.Count == 2 && config.Tags[0] == "a" && config.Tags[1] == "b", "A read list replaces the old items");
		Test.Assert(config.Ports != null && config.Ports.Count == 3 && config.Ports[2] == 3, "A null List field gets a new list");
		Test.Assert(config.Levels.Count == 2 && config.Levels[0] == .Debug && config.Levels[1] == .Warn);
		Test.Assert(config.Db.Url == "postgres://db" && config.Db.PoolSize == 16 && config.Db.Timeout == 1.5, "Absent keys keep their values");
		Test.Assert(config.Admin.Host == "localhost" && config.Admin.Port == 8443);
		Test.Assert(config.Plugins.Count == 2 && config.Plugins[0].Name == "auth" && config.Plugins[0].Enabled);
		Test.Assert(config.Plugins[1].Name == "cache" && !config.Plugins[1].Enabled);
		Test.Assert(config.Scratch == 42 && config.Private == 7, "Ignored and private fields are not read");
	}

	[Test]
	public static void Write_ThenRead_RoundTrips()
	{
		let config = scope SerServerConfig();
		ReadOk(cConfig, config);
		let text = scope String();
		Test.Assert(TomlSerializer.Write(config, text) case .Ok);

		let copy = scope SerServerConfig();
		ReadOk(text, copy);
		let again = scope String();
		Test.Assert(TomlSerializer.Write(copy, again) case .Ok);
		Test.Assert(text == again, text);
		Test.Assert(text.Contains("log-level = \"Warn\"") && text.Contains("[[plugins]]") && text.Contains("pool_size = 16"), text);
		Test.Assert(!text.Contains("scratch") && !text.Contains("private"), text);
	}

	[Test]
	public static void Read_ReportsLocatedErrors()
	{
		(StringView toml, TomlErrorKind kind, StringView message, int32 line)[?] cases = .(
			("port = 1", .MissingKey, "name: missing required string", 0),
			("name = \"x\"\nport = \"80\"", .WrongType, "port: expected integer, found string", 2),
			("name = \"x\"\nretries = 300", .InvalidValue, "retries: 300 is outside the range 0 to 255", 2),
			("name = \"x\"\nlog-level = \"Loud\"", .InvalidValue, "log-level: 'Loud' is not one of Debug, Info, Warn", 2),
			("name = \"x\"\nlevels = [\"Info\", 3]", .WrongType, "[1]: expected string, found integer", 2),
			("name = \"x\"\n[admin]\nport = -1", .InvalidValue, "port: -1 is outside the range 0 to 65535", 3),
			("name = \"x\"\ndb = 5", .WrongType, "db: expected table, found integer", 2));
		for (let (toml, kind, message, line) in cases)
		{
			let config = scope SerServerConfig();
			switch (TomlSerializer.Read(toml, config))
			{
			case .Ok: Test.Assert(false, scope $"accepted: {toml}");
			case .Err(let err):
				Test.Assert(err.mKind == kind && err.mMessage == message, scope $"{toml}: {err.mKind} {err.mMessage}");
				Test.Assert(line == 0 || err.mLine == line, scope $"{toml}: line {err.mLine}");
			}
		}
	}

	[Test]
	public static void Inheritance_ReadsAndWritesBaseFields()
	{
		let settings = scope SerDerivedSettings();
		ReadOk("Title = \"t\"\nExtra = 3", settings);
		Test.Assert(settings.Title == "t" && settings.Extra == 3);
		let text = scope String();
		Test.Assert(TomlSerializer.Write(settings, text) case .Ok);
		Test.Assert(text == "Title = \"t\"\nExtra = 3\n", text);
	}

	[Test]
	public static void Naming_SplitsWordsAndAcronyms()
	{
		let kebab = scope SerNaming() { HTTPPort = 1, Utf8Name = 2, max_depth = 3, Odd = 4 };
		let text = scope String();
		Test.Assert(TomlSerializer.Write(kebab, text) case .Ok);
		Test.Assert(text == "http-port = 1\nutf8-name = 2\nmax-depth = 3\n\"a key.with dots\" = 4\n", text);

		let camel = scope SerCamel() { PoolSize = 1, HTTPPort = 2 };
		text.Clear();
		Test.Assert(TomlSerializer.Write(camel, text) case .Ok);
		Test.Assert(text == "poolSize = 1\nhttpPort = 2\n", text);
	}
}
