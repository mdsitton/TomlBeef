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

// Types the serializer does not know, with converters

struct SerVec3
{
	public float X, Y, Z;
}

/// [x, y, z], registered for every SerVec3
[TomlConverter(typeof(SerVec3))]
struct SerVec3Toml : ITomlConverter<SerVec3>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref SerVec3 target)
	{
		if (!value.TryGetArray(let array) || array.Count != 3)
			return .Err(context.MakeError("expected [x, y, z]"));
		float[3] parts = ?;
		for (int i < 3)
		{
			if (array.TryGetFloat(i, let asFloat))
				parts[i] = (float)asFloat;
			else if (array.TryGetInteger(i, let asInteger))
				parts[i] = asInteger;
			else
				return .Err(context.MakeError("expected [x, y, z]"));
		}
		target = .() { X = parts[0], Y = parts[1], Z = parts[2] };
		return .Ok;
	}

	public static Result<void, TomlParseError> Write(SerVec3 value, TomlConvertContext context)
	{
		let array = context.SetArray();
		array.Add((double)value.X);
		array.Add((double)value.Y);
		array.Add((double)value.Z);
		return .Ok;
	}
}

struct SerDuration
{
	public int64 mMilliseconds;
}

/// "1500ms", registered for every SerDuration
[TomlConverter(typeof(SerDuration))]
struct SerDurationToml : ITomlConverter<SerDuration>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref SerDuration target)
	{
		if (!value.TryGetString(let text) || !text.EndsWith("ms"))
			return .Err(context.MakeError("expected a duration like \"1500ms\""));
		switch (int64.Parse(text.Substring(0, text.Length - 2)))
		{
		case .Ok(let ms): target.mMilliseconds = ms;
		case .Err: return .Err(context.MakeError("expected a duration like \"1500ms\""));
		}
		return .Ok;
	}

	public static Result<void, TomlParseError> Write(SerDuration value, TomlConvertContext context)
	{
		context.Set(scope $"{value.mMilliseconds}ms");
		return .Ok;
	}
}

/// Whole seconds as an integer, used for one field with [TomlUseConverter]
struct SerSecondsToml : ITomlConverter<SerDuration>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref SerDuration target)
	{
		if (!value.TryGetInteger(let seconds))
			return .Err(context.MakeError("expected whole seconds"));
		target.mMilliseconds = seconds * 1000;
		return .Ok;
	}

	public static Result<void, TomlParseError> Write(SerDuration value, TomlConvertContext context)
	{
		context.Set(value.mMilliseconds / 1000);
		return .Ok;
	}
}

class SerColor
{
	public uint8 R, G, B;
}

/// "#rrggbb"; a class, so reading allocates when the target is null
[TomlConverter(typeof(SerColor))]
struct SerColorToml : ITomlConverter<SerColor>
{
	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref SerColor target)
	{
		uint32 rgb = 0;
		if (!value.TryGetString(let text) || text.Length != 7 || text[0] != '#')
			return .Err(context.MakeError("expected a color like \"#ff8800\""));
		switch (uint32.Parse(text.Substring(1), .HexNumber))
		{
		case .Ok(let parsed): rgb = parsed;
		case .Err: return .Err(context.MakeError("expected a color like \"#ff8800\""));
		}
		if (target == null)
		{
			// From the read's allocator when it has one, like everything else the read creates
			let allocator = context.Allocator;
			target = (allocator != null) ? new:allocator SerColor() : new SerColor();
		}
		target.R = (uint8)(rgb >> 16);
		target.G = (uint8)(rgb >> 8);
		target.B = (uint8)rgb;
		return .Ok;
	}

	public static Result<void, TomlParseError> Write(SerColor value, TomlConvertContext context)
	{
		if (value != null)
			context.Set(scope $"#{value.R:x2}{value.G:x2}{value.B:x2}");
		return .Ok;
	}
}

[TomlObject(Naming = .SnakeCase)]
class SerScene
{
	public SerVec3 Position;
	public List<SerVec3> Path = new .() ~ delete _;
	public SerDuration Timeout;
	[TomlUseConverter(typeof(SerSecondsToml))] public SerDuration Interval;
	public SerColor Tint ~ delete _;
	public List<SerColor> Palette = new .() ~ DeleteContainerAndItems!(_);
}

[TomlObject(Naming = .SnakeCase)]
class SerRoute
{
	public String Path ~ delete _;
	public int32 Weight = 1;
}

[TomlObject(Naming = .SnakeCase)]
class SerServerSection
{
	public String Host = new .() ~ delete _;
	public int32 Port;
	public List<String> Aliases = new .() ~ DeleteContainerAndItems!(_);
	public List<SerRoute> Routes = new .() ~ DeleteContainerAndItems!(_);
}

// Read through an allocator, which owns everything the read creates: no field deletes anything

[TomlObject(Naming = .SnakeCase)]
class SerArenaLimits
{
	public int32 MaxConnections;
}

[TomlObject(Naming = .SnakeCase)]
struct SerArenaEndpoint
{
	public String Host;
	public uint16 Port;
}

[TomlObject(Naming = .SnakeCase)]
class SerArenaServer
{
	public String Name;
	public List<String> Tags;
	public SerArenaLimits Limits;
	public SerArenaEndpoint Admin;
	public SerColor Tint;
	public List<SerColor> Palette;
}

[TomlObject(Naming = .SnakeCase)]
class SerArenaRoot
{
	public String Title;
	public List<SerArenaServer> Servers;
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
	public static void Serializer_FileWrappersRoundTrip()
	{
		let path = scope String();
		Test.Assert(System.IO.Path.GetTempFileName(path) case .Ok);
		defer System.IO.File.Delete(path).IgnoreError();

		let config = scope SerServerConfig();
		ReadOk(cConfig, config);
		Test.Assert(TomlSerializer.WriteFile(config, path) case .Ok);
		let copy = scope SerServerConfig();
		Test.Assert(TomlSerializer.ReadFile(path, copy) case .Ok);
		Test.Assert(copy.Port == 9000 && copy.Plugins.Count == 2 && copy.Level == .Warn);

		// Errors from a file name it
		Test.Assert(System.IO.File.WriteAllText(path, "name = \"x\"\nport = true\n") case .Ok);
		switch (TomlSerializer.ReadFile(path, copy))
		{
		case .Ok: Test.Assert(false);
		case .Err(let err): Test.Assert(err.mSource == path && err.mLine == 2 && err.mKind == .WrongType);
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
	public static void Converters_RegisteredAndPerField()
	{
		const String toml = """
			position = [1, 2.5, -3]
			path = [[0, 0, 0], [1, 1, 1]]
			timeout = "1500ms"
			interval = 30
			tint = "#ff8800"
			palette = ["#000000", "#ffffff"]
			""";
		let scene = scope SerScene();
		scene.Palette.Add(new SerColor());
		ReadOk(toml, scene);
		Test.Assert(scene.Position.X == 1 && scene.Position.Y == 2.5f && scene.Position.Z == -3);
		Test.Assert(scene.Path.Count == 2 && scene.Path[1].Y == 1);
		Test.Assert(scene.Timeout.mMilliseconds == 1500, "Registered converter");
		Test.Assert(scene.Interval.mMilliseconds == 30000, "[TomlUseConverter] wins over the registered one");
		Test.Assert(scene.Tint != null && scene.Tint.R == 0xff && scene.Tint.G == 0x88 && scene.Tint.B == 0);
		Test.Assert(scene.Palette.Count == 2 && scene.Palette[1].G == 0xff, "Old items are deleted, converters fill new ones");

		let text = scope String();
		Test.Assert(TomlSerializer.Write(scene, text) case .Ok);
		Test.Assert(text == """
			position = [1.0, 2.5, -3.0]
			path = [[0.0, 0.0, 0.0], [1.0, 1.0, 1.0]]
			timeout = "1500ms"
			interval = 30
			tint = "#ff8800"
			palette = ["#000000", "#ffffff"]

			""", text);

		// Converter errors are located at the value, naming its key or index
		let bad = scope SerScene();
		switch (TomlSerializer.Read("position = [1, 2]", bad))
		{
		case .Ok: Test.Assert(false);
		case .Err(let err): Test.Assert(err.mLine == 1 && err.mMessage == "position: expected [x, y, z]", scope String(err.mMessage));
		}
		switch (TomlSerializer.Read("palette = [\"#000000\", \"red\"]", bad))
		{
		case .Ok: Test.Assert(false);
		case .Err(let err): Test.Assert(err.mMessage == "[1]: expected a color like \"#ff8800\"", scope String(err.mMessage));
		}
	}

	[Test]
	public static void Document_MixesTypedAndHandWrittenData()
	{
		// One section is bound to a type; the rest is read and written by hand. Writing the object back
		// changes only what changed: comments, formatting and keys the type does not know stay.
		const String input = """
			# App configuration
			version = 3 # bumped by hand

			[server] # the public listener
			host = 'localhost' # bind address
			port = 0x1F90
			aliases = [
			  "a", # first
			  "b",
			]
			tls = true # not in SerServerSection

			# The routes
			[[server.routes]]
			path = "/"
			weight = 1

			[[server.routes]]
			path = "/api" # versioned
			weight = 5
			""";
		let doc = scope TomlDocument();
		Test.Assert(doc.Read(input, .() { MetadataMode = .PreserveStyle }) case .Ok);

		let server = scope SerServerSection();
		Test.Assert(doc.Deserialize("server", server) case .Ok);
		Test.Assert(server.Host == "localhost" && server.Port == 8080 && server.Aliases.Count == 2 && server.Routes.Count == 2);
		Test.Assert(doc.GetInteger("version", 0) == 3);

		// Unchanged: the document is written exactly as read
		Test.Assert(doc.Serialize("server", server) case .Ok);
		let unchanged = scope String();
		doc.Write(unchanged);
		Test.Assert(unchanged == scope $"{input}\n", unchanged);

		// Typed and hand-written changes side by side
		server.Port = 9090;
		server.Aliases[1].Set("c");
		server.Routes[1].Weight = 7;
		let added = new SerRoute();
		added.Path = new String("/health");
		server.Routes.Add(added);
		Test.Assert(doc.Serialize("server", server) case .Ok);
		doc.Set("version", 4);
		doc.Set("server.tls", false);

		let output = scope String();
		doc.Write(output);
		Test.Assert(output == """
			# App configuration
			version = 4 # bumped by hand

			[server] # the public listener
			host = 'localhost' # bind address
			port = 0x2382
			aliases = [
			  "a", # first
			  "c",
			]
			tls = false # not in SerServerSection

			# The routes
			[[server.routes]]
			path = "/"
			weight = 1

			[[server.routes]]
			path = "/api" # versioned
			weight = 7

			[[server.routes]]
			path = "/health"
			weight = 1

			""", output);

		// Shrinking the list removes the extra [[server.routes]]; a new section is created by path
		server.Routes.PopBack();
		delete server.Routes.PopBack();
		delete added;
		Test.Assert(doc.Serialize("server", server) case .Ok);
		Test.Assert(doc.Serialize("mirror.server", server) case .Ok);
		let reread = scope TomlDocument();
		let text = scope String();
		doc.Write(text);
		Test.Assert(reread.Read(text) case .Ok, text);
		Test.Assert(reread.TryGetArray("server.routes", let routes) && routes.Count == 1, text);
		Test.Assert(reread.GetInteger("mirror.server.port", 0) == 9090 && reread.GetBool("server.tls", true) == false, text);

		// Writing states every field: a key that was absent when read is written with the field's value
		let sparse = scope TomlDocument();
		Test.Assert(sparse.Read("[[routes]]\npath = \"/\"") case .Ok);
		let route = scope SerRoute();
		TomlTable first = null;
		Test.Assert(sparse.TryGetArray("routes", let sparseRoutes) && sparseRoutes.TryGetTable(0, out first));
		Test.Assert(first.Deserialize(route) case .Ok && first.Serialize(route) case .Ok);
		Test.Assert(first.GetInteger("weight", 0) == 1);
	}

	[Test]
	public static void Allocator_OwnsEverythingTheReadCreates()
	{
		// The types delete nothing, so any heap allocation by the read would show up as a leak
		// (test-leaks.sh): Strings, nested objects, Lists, list items, struct fields and
		// converter-created objects all come from the scoped arena and go with it.
		const String toml = """
			title = "arena"

			[[servers]]
			name = "a"
			tags = ["x", "y"]
			tint = "#010203"
			palette = ["#000000", "#ffffff"]
			[servers.limits]
			max_connections = 10
			[servers.admin]
			host = "localhost"
			port = 8443

			[[servers]]
			name = "b"
			tags = []
			""";
		let arena = scope BumpAllocator();
		let root = scope SerArenaRoot();
		Test.Assert(TomlSerializer.Read(toml, root, .(), arena) case .Ok);
		Test.Assert(root.Title == "arena" && root.Servers.Count == 2);
		let first = root.Servers[0];
		Test.Assert(first.Name == "a" && first.Tags.Count == 2 && first.Tags[1] == "y" && first.Limits.MaxConnections == 10);
		Test.Assert(first.Admin.Host == "localhost" && first.Admin.Port == 8443);
		Test.Assert(first.Tint.B == 3 && first.Palette.Count == 2 && first.Palette[1].R == 0xff);
		Test.Assert(root.Servers[1].Name == "b" && root.Servers[1].Tags.Count == 0 && root.Servers[1].Limits == null);

		// The document API takes the allocator too, and reading again drops the old items without
		// deleting them (the arena still owns them)
		let doc = scope TomlDocument();
		Test.Assert(doc.Read("[mirror]\ntitle = \"again\"\n[[mirror.servers]]\nname = \"c\"") case .Ok);
		Test.Assert(doc.Deserialize("mirror", root, arena) case .Ok);
		Test.Assert(root.Title == "again" && root.Servers.Count == 1 && root.Servers[0].Name == "c");
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
