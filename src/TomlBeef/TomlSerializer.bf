using System;

namespace TomlBeef;

/// @brief Reads TOML into [TomlObject] types and writes them back out (see TomlObjectAttribute).
public static class TomlSerializer
{
	/// @brief Parse `toml` and fill `target` from its root table. Errors (parse errors, and missing
	/// required keys or wrong types) are located in the source: `config.toml:3:8: port: expected integer,
	/// found string` once a source name is set in `config`.
	/// @param toml The TOML text.
	/// @param target The object to fill; fields whose keys are absent keep their values.
	/// @param config Read settings. Metadata below Positions is raised to Positions, for error locations.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> Read<T>(StringView toml, T target, TomlReadConfig config = .()) where T : class, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Read(toml, WithPositions(config)));
		return target.TomlRead(doc.RootTable);
	}

	/// @brief Parse `toml` and fill the struct `target` from its root table; see the class overload.
	/// @param toml The TOML text.
	/// @param target The struct to fill.
	/// @param config Read settings.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> Read<T>(StringView toml, ref T target, TomlReadConfig config = .()) where T : struct, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Read(toml, WithPositions(config)));
		return target.TomlRead(doc.RootTable);
	}

	/// @brief Write `source` as a TOML document, appending to `output`.
	/// @param source The object to write.
	/// @param output Receives the TOML text.
	/// @param config Write settings.
	/// @return .Ok, or an error for a value TOML cannot hold.
	public static Result<void, TomlParseError> Write<T>(T source, String output, TomlWriteConfig config = .()) where T : ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(source.TomlWrite(doc.RootTable));
		doc.Write(output, config);
		return .Ok;
	}

	static TomlReadConfig WithPositions(TomlReadConfig config)
	{
		var config;
		if (config.MetadataMode == .None)
			config.MetadataMode = .Positions;
		return config;
	}
}
