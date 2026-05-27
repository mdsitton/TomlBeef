using System;
using System.IO;
using System.Collections;

namespace TomlBeef;

/// Read mode for parsing TOML into a document.
public enum TomlReadMode
{
	/// Clear existing root table, populate from input (default).
	Replace,
	/// Retain existing content, insert new top-level keys.
	Merge
}

/// Conflict resolution strategy when merging duplicate keys.
public enum MergeConflict
{
	/// Duplicate key returns an error (default — strict TOML semantics).
	Error,
	/// Keep the existing value, ignore the incoming duplicate.
	Skip,
	/// Replace the existing value with the incoming one.
	Overwrite
}

/// Configuration for reading TOML into a document.
public struct TomlReadConfig
{
	public TomlReadMode Mode = .Replace;
	public MergeConflict OnConflict = .Error;
	public TomlVersion Version = .V1_1;
}

/// Configuration for writing a document to a TOML string.
public struct TomlWriteConfig
{
	public TomlVersion Version = .V1_1;
}

/// The root of a parsed TOML document.
/// Owns the complete value tree; disposal of the document cleans up everything.
public class TomlDocument
{
	/// @brief Global default read configuration. Set once at startup before any Read() calls.
	/// Not thread-safe — changing this while other threads are reading produces undefined behavior.
	public static TomlReadConfig DefaultReadConfig = .();

	/// @brief Global default write configuration. Set once at startup before any Write() calls.
	/// Not thread-safe — changing this while other threads are writing produces undefined behavior.
	public static TomlWriteConfig DefaultWriteConfig = .();

	private TomlTable mRootTable ~ delete _;

	/// @brief The document's root table (read-only). Modify via Insert/Remove, or use Read() to replace.
	public TomlTable RootTable => mRootTable;

	/// @brief Remove all content from this document.
	public void Clear()
	{
		mRootTable.Clear();
	}

	public this()
	{
		mRootTable = new TomlTable(.Root);
	}

	/// @brief Parse a TOML string into this document using the current DefaultReadConfig.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(StringView input)
	{
		return Read(input, DefaultReadConfig);
	}

	/// @brief Parse a TOML string into this document with an explicit configuration.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(StringView input, TomlReadConfig config)
	{
		int start = 0;
		if (TomlChar.ValidateUtf8(input, out start) case .Err(let utf8Err))
			return ReadFailure(utf8Err, config);

		let cursor = TomlByteCursor(StringView(&input.Ptr[start], input.Length - start));
		return ReadWithCursor(cursor, config);
	}

	/// @brief Parse raw UTF-8 bytes into this document.
	/// @param data The TOML input bytes. Must remain valid for the duration of the call.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadBytes(Span<uint8> data)
	{
		return ReadBytes(data, DefaultReadConfig);
	}

	/// @brief Parse raw UTF-8 bytes with an explicit configuration.
	/// @param data The TOML input bytes. Must remain valid for the duration of the call.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadBytes(Span<uint8> data, TomlReadConfig config)
	{
		StringView sv = StringView((char8*)data.Ptr, data.Length);
		int start = 0;
		if (TomlChar.ValidateUtf8(sv, out start) case .Err(let utf8Err))
			return ReadFailure(utf8Err, config);

		let cursor = TomlByteCursor(Span<uint8>((uint8*)data.Ptr + start, data.Length - start));
		return ReadWithCursor(cursor, config);
	}

	/// @brief Parse TOML from a stream into this document.
	/// The stream must be readable. The caller owns the stream and should close it after.
	/// @param stream The stream to read from.
	/// @return .Ok on success, or .Err on parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(Stream stream)
	{
		return Read(stream, DefaultReadConfig);
	}

	/// @brief Parse TOML from a stream with an explicit configuration.
	/// @param stream The stream to read from.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err on parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(Stream stream, TomlReadConfig config)
	{
		uint8[] buffer = new uint8[8192];
		defer delete buffer;
		String spill = new String();
		defer delete spill;

		var state = new TomlStreamState();
		defer delete state;
		var cursor = TomlBufferedStreamCursor(stream, buffer, spill, state);

		// Handle optional UTF-8 BOM at stream start
		{
			char8 b0 = cursor.PeekByte();
			if ((uint8)b0 == 0xEF)
			{
				char8 b1 = cursor.PeekByte(1);
				char8 b2 = cursor.PeekByte(2);
				if ((uint8)b1 == 0xBB && (uint8)b2 == 0xBF)
				{
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					// Reject a second BOM immediately following the first
					b0 = cursor.PeekByte();
					if ((uint8)b0 == 0xEF)
					{
						b1 = cursor.PeekByte(1);
						b2 = cursor.PeekByte(2);
						if ((uint8)b1 == 0xBB && (uint8)b2 == 0xBF)
							return ReadFailure(TomlParseError(.ControlCharInDocument, "BOM must only appear at start of file", 1, 1, 3), config);
					}
					// Reset cursor position so parsing sees line 1, column 1 after BOM
					cursor.ResetPosition();
				}
			}
		}

		if (!ShouldParseDirectly(config))
			return ReadMergeFromStreamCursor(cursor, config, state);

		if (ReadWithCursor(cursor, config) case .Err(let e))
		{
			if (state.mError)
			{
				e.Dispose();
				return ReadFailure(TomlParseError(.IoError, "Stream read error", 0, 0, 0), config);
			}
			if (state.mUtf8Error)
			{
				e.Dispose();
				return ReadFailure(TomlParseError(.InvalidUtf8, "Invalid UTF-8 sequence",
					state.mUtf8ErrorLine, state.mUtf8ErrorColumn, state.mUtf8ErrorOffset), config);
			}
			return .Err(e);
		}
		if (state.mError)
			return ReadFailure(TomlParseError(.IoError, "Stream read error", 0, 0, 0), config);
		if (state.mUtf8Error)
			return ReadFailure(TomlParseError(.InvalidUtf8, "Invalid UTF-8 sequence",
				state.mUtf8ErrorLine, state.mUtf8ErrorColumn, state.mUtf8ErrorOffset), config);
		return .Ok;
	}

	private Result<void, TomlParseError> ReadMergeFromStreamCursor<TCursor>(TCursor cursor, TomlReadConfig config, TomlStreamState state) where TCursor : ITomlCursor
	{
		let parser = scope TomlParserImpl<TCursor>(config.Version);
		var incoming = new TomlTable(.Root);
		defer delete incoming;

		let resolver = scope TomlPathResolver(incoming);
		if (parser.Parse(cursor, resolver) case .Err(let e))
		{
			if (state.mError)
			{
				e.Dispose();
				return .Err(TomlParseError(.IoError, "Stream read error", 0, 0, 0));
			}
			if (state.mUtf8Error)
			{
				e.Dispose();
				return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 sequence",
					state.mUtf8ErrorLine, state.mUtf8ErrorColumn, state.mUtf8ErrorOffset));
			}
			return .Err(e);
		}
		if (state.mError)
			return .Err(TomlParseError(.IoError, "Stream read error", 0, 0, 0));
		if (state.mUtf8Error)
			return .Err(TomlParseError(.InvalidUtf8, "Invalid UTF-8 sequence",
				state.mUtf8ErrorLine, state.mUtf8ErrorColumn, state.mUtf8ErrorOffset));
		return mRootTable.MergeFrom(incoming, config.OnConflict);
	}

	private bool ShouldParseDirectly(TomlReadConfig config)
	{
		return mRootTable.Count == 0 || config.Mode == .Replace;
	}

	private Result<void, TomlParseError> ReadFailure(TomlParseError error, TomlReadConfig config)
	{
		if (ShouldParseDirectly(config))
			mRootTable.Clear();
		return .Err(error);
	}

	private Result<void, TomlParseError> ReadWithCursor<TCursor>(TCursor cursor, TomlReadConfig config) where TCursor : ITomlCursor
	{
		let parser = scope TomlParserImpl<TCursor>(config.Version);

		// Fast path: nothing to preserve — parse directly into root
		if (ShouldParseDirectly(config))
		{
			if (config.Mode == .Replace)
				mRootTable.Clear();
			let resolver = scope TomlPathResolver(mRootTable);
			if (parser.Parse(cursor, resolver) case .Err(let parseErr))
			{
				mRootTable.Clear();
				return .Err(parseErr);
			}
			return .Ok;
		}

		// Merge with existing content — transactional via temp table
		var incoming = new TomlTable(.Root);
		defer delete incoming;
		{
			let resolver = scope TomlPathResolver(incoming);
			if (parser.Parse(cursor, resolver) case .Err(let e))
				return .Err(e);
		}
		return mRootTable.MergeFrom(incoming, config.OnConflict);
	}

	/// @brief Serialize this document to a TOML string using the current DefaultWriteConfig.
	/// @param output The destination string to append to.
	public void Write(String output)
	{
		Write(output, DefaultWriteConfig);
	}

	/// @brief Serialize this document to a TOML string with an explicit configuration.
	/// @param output The destination string to append to.
	/// @param config Write options.
	public void Write(String output, TomlWriteConfig config)
	{
		TomlWriterImpl.Write(this, output, config.Version);
	}

	/// @brief Remove a key and its value from the root table.
	/// @param key The key to remove.
	/// @return True if the key was found and removed.
	public bool Remove(StringView key)
	{
		return mRootTable.Remove(key);
	}

	public Result<TomlValue> Get(StringView dottedPath)
	{
		TomlTable current = mRootTable;
		int start = 0;
		for (int i = 0; i <= dottedPath.Length; i++)
		{
			if (i == dottedPath.Length || dottedPath[i] == '.')
			{
				StringView segment = dottedPath.Substring(start, i - start);
				if (segment.IsEmpty)
					return .Err;
				if (i == dottedPath.Length)
				{
					// Final segment — return the value
					if (current.TryGetValue(segment, let val))
						return val;
					return .Err;
				}
				// Intermediate segment — must be a table
				if (!current.TryGetValue(segment, let val) || !val.IsTable)
					return .Err;
				current = val.AsTable;
				start = i + 1;
			}
		}
		return .Err;
	}

	/// @brief Navigate a dotted path and extract a String value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the string value at the path.
	/// @return True if the path exists and holds a String.
	public bool TryGetString(StringView dottedPath, out StringView value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetString(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an Integer value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the integer value at the path.
	/// @return True if the path exists and holds an Integer.
	public bool TryGetInteger(StringView dottedPath, out int64 value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetInteger(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Float value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the float value at the path.
	/// @return True if the path exists and holds a Float.
	public bool TryGetFloat(StringView dottedPath, out double value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetFloat(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Bool value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the boolean value at the path.
	/// @return True if the path exists and holds a Bool.
	public bool TryGetBool(StringView dottedPath, out bool value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetBool(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Table value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the table value at the path.
	/// @return True if the path exists and holds a Table.
	public bool TryGetTable(StringView dottedPath, out TomlTable value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetTable(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an Array value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the array value at the path.
	/// @return True if the path exists and holds an Array.
	public bool TryGetArray(StringView dottedPath, out TomlArray value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetArray(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an OffsetDateTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the offset date-time value at the path.
	/// @return True if the path exists and holds an OffsetDateTime.
	public bool TryGetOffsetDateTime(StringView dottedPath, out TomlOffsetDateTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetOffsetDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalDateTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local date-time value at the path.
	/// @return True if the path exists and holds a LocalDateTime.
	public bool TryGetLocalDateTime(StringView dottedPath, out TomlLocalDateTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalDate value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local date value at the path.
	/// @return True if the path exists and holds a LocalDate.
	public bool TryGetLocalDate(StringView dottedPath, out TomlLocalDate value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalDate(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local time value at the path.
	/// @return True if the path exists and holds a LocalTime.
	public bool TryGetLocalTime(StringView dottedPath, out TomlLocalTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Parse a TOML file into this document. Convenience wrapper around Read().
	/// @param path File path to read from.
	/// @return .Ok on success, or .Err on file or parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadFile(StringView path)
	{
		return ReadFile(path, DefaultReadConfig);
	}

	/// @brief Parse a TOML file into this document with an explicit configuration.
	/// @param path File path to read from.
	/// @param config Read options.
	/// @return .Ok on success, or .Err on file or parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadFile(StringView path, TomlReadConfig config)
	{
		String content = scope String();
		if (ReadFileContent(path, content) case .Err(let e))
			return ReadFailure(e, config);
		return Read(content, config);
	}

	/// @brief Write this document to a file. Convenience wrapper around Write().
	/// @param path File path to write to. Overwrites existing files.
	/// @return .Ok on success, or .Err if the write failed.
	public Result<void, TomlParseError> WriteFile(StringView path)
	{
		return WriteFile(path, DefaultWriteConfig);
	}

	/// @brief Write this document to a file with an explicit configuration.
	/// @param path File path to write to. Overwrites existing files.
	/// @param config Write options.
	/// @return .Ok on success, or .Err if the write failed.
	public Result<void, TomlParseError> WriteFile(StringView path, TomlWriteConfig config)
	{
		String output = scope String();
		Write(output, config);
		if (File.WriteAllText(path, output) case .Err)
			return .Err(TomlParseError(.IoError, scope $"Cannot write file: {path}" , 0, 0, 0));
		return .Ok;
	}

	/// @brief Read raw bytes from a file into a String, returning an IoError on failure.
	private static Result<void, TomlParseError> ReadFileContent(StringView path, String outContent)
	{
		var data = new List<uint8>();
		defer delete data;
		if (File.ReadAll(path, data) case .Err)
			return .Err(TomlParseError(.IoError, scope $"Cannot read file: {path}" , 0, 0, 0));
		for (int i = 0; i < data.Count; i++)
			outContent.Append((char8)data[i]);
		return .Ok;
	}
}
