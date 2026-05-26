using System;

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
	/// @return .Ok on success, or .Err with line/column info on failure.
	public Result<void, TomlParseError> Read(StringView input)
	{
		return Read(input, DefaultReadConfig);
	}

	/// @brief Parse a TOML string into this document with an explicit configuration.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err with line/column info on failure.
	public Result<void, TomlParseError> Read(StringView input, TomlReadConfig config)
	{
		let parser = scope TomlParserImpl(config.Version);

		// Fast path: nothing to preserve — parse directly into root
		if (mRootTable.Count == 0 || config.Mode == .Replace)
		{
			if (config.Mode == .Replace)
				mRootTable.Clear();
			let resolver = scope TomlPathResolver(mRootTable);
			return parser.Parse(input, resolver);
		}

		// Merge with existing content — transactional via temp table
		var incoming = new TomlTable(.Root);
		defer delete incoming;
		{
			let resolver = scope TomlPathResolver(incoming);
			if (parser.Parse(input, resolver) case .Err(let e))
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
}
