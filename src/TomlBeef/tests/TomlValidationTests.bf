using System;
using TomlBeef;

namespace TomlBeef;

/// Errors located in the source: source names, parse and merge errors, MakeError and the Require* getters.
static class TomlValidationTests
{
	static TomlDocument ReadNamed(TomlDocument doc, StringView input, StringView sourceName, TomlMetadataMode mode = .Positions)
	{
		if (doc.Read(input, .() { MetadataMode = mode, SourceName = sourceName }) case .Err(let e))
		{
			Test.Assert(false, scope $"Parse failed: {e}");
		}
		return doc;
	}

	static void AssertText(TomlParseError error, StringView expected)
	{
		let text = scope String();
		error.ToString(text);
		Test.Assert(text == expected, scope $"expected '{expected}', got '{text}'");
	}

	[Test]
	public static void ParseErrors_NameTheirSource()
	{
		var doc = scope TomlDocument();
		switch (doc.Read("a = 1\na = 2\n", .() { SourceName = "config.toml" }))
		{
		case .Ok:
			Test.Assert(false, "expected DuplicateKey");
		case .Err(let e):
			Test.Assert(e.mSource == "config.toml");
			AssertText(e, "config.toml:2:1: Duplicate key 'a'");
		}

		// Unnamed input: just the position
		Test.Assert(doc.Read("a = 1\na = 2\n") case .Err(let unnamed));
		AssertText(unnamed, "2:1: Duplicate key 'a'");

		// ReadFile names the path, for I/O errors too
		switch (doc.ReadFile("tests/does-not-exist.toml"))
		{
		case .Ok:
			Test.Assert(false, "expected IoError");
		case .Err(let e):
			Test.Assert(e.mKind == .IoError);
			AssertText(e, "tests/does-not-exist.toml: Cannot read file");
		}
	}

	[Test]
	public static void SourceRanges_KeepTheirSourceAcrossMerges()
	{
		let doc = ReadNamed(scope .(), "[server]\nhost = \"a\"\n", "base.toml");
		Test.Assert(doc.Read("[server]\nport = 80\n", .() { Mode = .Merge, MetadataMode = .Positions, SourceName = "local.toml" }) case .Ok);

		TomlSourceRange range;
		Test.Assert(doc.TryGetSourceRange("server.host", out range) && range.mSource == "base.toml" && range.mLine == 2);
		Test.Assert(doc.TryGetSourceRange("server.port", out range) && range.mSource == "local.toml" && range.mLine == 2);
		let text = scope String();
		range.ToString(text);
		Test.Assert(text == "local.toml:2:1", text);

		// Merging a table that only the incoming file defines carries its positions too
		Test.Assert(doc.Read("[db]\nname = \"x\"\n", .() { Mode = .Merge, MetadataMode = .Positions, SourceName = "db.toml" }) case .Ok);
		Test.Assert(doc.TryGetSourceRange("db.name", out range) && range.mSource == "db.toml" && range.mLine == 2);
		Test.Assert(doc.TryGetSourceRange("db", out range) && range.mSource == "db.toml" && range.mLine == 1);
	}

	[Test]
	public static void MergeConflicts_PointAtTheIncomingKey()
	{
		let doc = ReadNamed(scope .(), "a = 1\n", "base.toml");
		switch (doc.Read("x = 0\na = 2\n", .() { Mode = .Merge, MetadataMode = .Positions, SourceName = "local.toml" }))
		{
		case .Ok:
			Test.Assert(false, "expected a merge conflict");
		case .Err(let e):
			Test.Assert(e.mKind == .DuplicateKey);
			AssertText(e, "local.toml:2:1: Duplicate key 'a' during merge");
		}

		// Without metadata the conflict still names the file and path
		var plain = scope TomlDocument();
		Test.Assert(plain.Read("a = 1\n") case .Ok);
		Test.Assert(plain.Read("a = 2\n", .() { Mode = .Merge, SourceName = "local.toml" }) case .Err(let plainErr));
		AssertText(plainErr, "local.toml: Duplicate key 'a' during merge");
	}

	[Test]
	public static void MakeError_LocatesValuesAndMissingKeys()
	{
		let input = "[server]\nport = -1\nports = [80, 70000]\n";
		let doc = ReadNamed(scope .(), input, "config.toml");

		AssertText(doc.MakeError("server.port", "must be positive"), "config.toml:2:1: server.port: must be positive");
		Test.Assert(doc.MakeError("server.port", "x").mKind == .InvalidValue);
		// Missing: at the deepest table on the path, or just the file for the root
		AssertText(doc.MakeError("server.host", "is required"), "config.toml:1:1: server.host: is required");
		AssertText(doc.MakeError("db.host", "is required"), "config.toml: db.host: is required");

		Test.Assert(doc.TryGetTable("server", let server));
		AssertText(server.MakeError("port", "must be positive"), "config.toml:2:1: port: must be positive");
		Test.Assert(server.TryGetArray("ports", let ports));
		AssertText(ports.MakeError(1, "must be below 65536"), "config.toml:3:14: [1]: must be below 65536");

		// A value added in code has no position: it is reported at its table
		Test.Assert(doc.Set("server.added", 1));
		AssertText(doc.MakeError("server.added", "bad"), "config.toml:1:1: server.added: bad");
	}

	[Test]
	public static void Require_ReturnsValuesOrLocatedErrors()
	{
		let doc = ReadNamed(scope .(), "name = \"app\"\n[server]\nport = 8080\nratio = 0.5\ntls = true\nhosts = [\"a\"]\n[server.limits]\nmax = 3\n", "config.toml");

		Test.Assert(doc.RequireString("name") case .Ok(let name) && name == "app");
		Test.Assert(doc.RequireInteger("server.port") case .Ok(let port) && port == 8080);
		Test.Assert(doc.RequireFloat("server.ratio") case .Ok(let ratio) && ratio == 0.5);
		Test.Assert(doc.RequireBool("server.tls") case .Ok(let tls) && tls);
		Test.Assert(doc.RequireArray("server.hosts") case .Ok(let hosts) && hosts.Count == 1);
		Test.Assert(doc.RequireTable("server.limits") case .Ok(let limits) && limits.Count == 1);

		// Wrong type: at the value
		Test.Assert(doc.RequireString("server.port") case .Err(let wrongType));
		Test.Assert(wrongType.mKind == .WrongType);
		AssertText(wrongType, "config.toml:3:1: server.port: expected string, found integer");
		Test.Assert(doc.RequireFloat("server.port") case .Err(let noWidening), "integers are not floats");
		AssertText(noWidening, "config.toml:3:1: server.port: expected float, found integer");

		// Missing: at the table that should hold it
		Test.Assert(doc.RequireInteger("server.timeout") case .Err(let missing));
		Test.Assert(missing.mKind == .MissingKey);
		AssertText(missing, "config.toml:2:1: server.timeout: missing required integer");
		Test.Assert(doc.RequireInteger("server.limits.min") case .Err(let missingNested));
		AssertText(missingNested, "config.toml:7:1: server.limits.min: missing required integer");

		// A non-table segment on the way
		Test.Assert(doc.RequireInteger("server.port.x") case .Err(let notTable));
		AssertText(notTable, "config.toml:3:1: server.port.x: expected 'port' to be a table, found integer");
		Test.Assert(doc.RequireInteger("a..b") case .Err(let badPath) && badPath.mKind == .InvalidKey);

		// Table-level forms name just the key
		Test.Assert(doc.TryGetTable("server", let server));
		Test.Assert(server.RequireInteger("port") case .Ok);
		Test.Assert(server.RequireBool("port") case .Err(let tableErr));
		AssertText(tableErr, "config.toml:3:1: port: expected boolean, found integer");
	}

	[Test]
	public static void Validation_WorksWithoutMetadata()
	{
		// No positions: the messages still name the path
		var doc = scope TomlDocument();
		Test.Assert(doc.Read("[server]\nport = 80\n") case .Ok);
		AssertText(doc.MakeError("server.port", "must be above 1024"), "server.port: must be above 1024");
		Test.Assert(doc.RequireBool("server.tls") case .Err(let missing));
		AssertText(missing, "server.tls: missing required boolean");
	}

	static Result<int64, TomlParseError> LoadPort(TomlDocument doc)
	{
		let port = Try!(doc.RequireInteger("server.port"));
		if (port <= 0)
			return .Err(doc.MakeError("server.port", "must be positive"));
		return port;
	}

	[Test]
	public static void Validation_ComposesWithTry()
	{
		Test.Assert(LoadPort(ReadNamed(scope .(), "[server]\nport = 80\n", "a.toml")) case .Ok(let port) && port == 80);
		Test.Assert(LoadPort(ReadNamed(scope .(), "[server]\nport = 0\n", "b.toml")) case .Err(let invalid));
		AssertText(invalid, "b.toml:2:1: server.port: must be positive");
		Test.Assert(LoadPort(ReadNamed(scope .(), "[server]\n", "c.toml")) case .Err(let missing));
		AssertText(missing, "c.toml:1:1: server.port: missing required integer");
	}
}
