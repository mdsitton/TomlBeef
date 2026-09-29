using System;

namespace TomlBeef;

/// @brief One-call reading and writing of whole documents as [TomlObject] types (see TomlObjectAttribute).
/// Each is a short wrapper: a scoped TomlDocument, its Read/ReadFile or Write/WriteFile, and its
/// Deserialize or Serialize. Use those directly to bind one section by path, mix typed and hand-written
/// data, or update a document read with PreserveStyle in place.
public static class TomlSerializer
{
	/// @brief Parse `toml` and fill `target` from its root table. Errors (parse errors, and missing
	/// required keys or wrong types) are located in the source.
	/// @param toml The TOML text.
	/// @param target The object to fill; fields whose keys are absent keep their values.
	/// @param config Read settings. Metadata below Positions is raised to Positions, for error locations.
	/// @param allocator Where created Strings, objects and Lists come from (for example a
	/// `scope BumpAllocator`), or null for the heap; see TomlDocument.Deserialize for ownership.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> Read<T>(StringView toml, T target, TomlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Read(toml, WithPositions(config)));
		return doc.Deserialize(target, allocator);
	}

	/// @brief Parse `toml` and fill the struct `target` from its root table; see the class overload.
	/// @param toml The TOML text.
	/// @param target The struct to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> Read<T>(StringView toml, ref T target, TomlReadConfig config = .(), ITypedAllocator allocator = null) where T : struct, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Read(toml, WithPositions(config)));
		return doc.Deserialize(ref target, allocator);
	}

	/// @brief Parse the file at `path` and fill `target` from its root table. Errors name the file:
	/// `app.toml:3:8: port: expected integer, found string`.
	/// @param path The file to read.
	/// @param target The object to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> ReadFile<T>(StringView path, T target, TomlReadConfig config = .(), ITypedAllocator allocator = null) where T : class, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.ReadFile(path, WithPositions(config)));
		return doc.Deserialize(target, allocator);
	}

	/// @brief Parse the file at `path` and fill the struct `target`; see the class overload.
	/// @param path The file to read.
	/// @param target The struct to fill.
	/// @param config Read settings.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error.
	public static Result<void, TomlParseError> ReadFile<T>(StringView path, ref T target, TomlReadConfig config = .(), ITypedAllocator allocator = null) where T : struct, ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.ReadFile(path, WithPositions(config)));
		return doc.Deserialize(ref target, allocator);
	}

	/// @brief Write `source` as a new TOML document, appending to `output`.
	/// @param source The object to write.
	/// @param output Receives the TOML text.
	/// @param config Write settings.
	/// @return .Ok, or an error for a value TOML cannot hold.
	public static Result<void, TomlParseError> Write<T>(T source, String output, TomlWriteConfig config = .()) where T : ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Serialize(source));
		doc.Write(output, config);
		return .Ok;
	}

	/// @brief Write `source` as a new TOML document to the file at `path`, replacing it. To update an
	/// existing file and keep its comments, read it with PreserveStyle and use TomlDocument.Serialize.
	/// @param source The object to write.
	/// @param path The file to write.
	/// @param config Write settings.
	/// @return .Ok, or an error (a value TOML cannot hold, or the file write).
	public static Result<void, TomlParseError> WriteFile<T>(T source, StringView path, TomlWriteConfig config = .()) where T : ITomlSerializable
	{
		let doc = scope TomlDocument();
		Try!(doc.Serialize(source));
		return doc.WriteFile(path, config);
	}

	static TomlReadConfig WithPositions(TomlReadConfig config)
	{
		var config;
		if (config.MetadataMode == .None)
			config.MetadataMode = .Positions;
		return config;
	}
}
