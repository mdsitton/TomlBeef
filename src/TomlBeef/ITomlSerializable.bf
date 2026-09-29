using System;

namespace TomlBeef;

/// @brief A type that reads itself from and writes itself to a TomlTable. [TomlObject] generates both
/// methods; a type can also implement them by hand.
public interface ITomlSerializable
{
	/// @brief Fill this object's fields from `table`.
	/// @param table The table to read.
	/// @return .Ok, or the first error, located in the source when the document has positions.
	Result<void, TomlParseError> TomlRead(TomlTable table) mut;

	/// @brief Add this object's fields to `table`.
	/// @param table The table to write into (normally empty).
	/// @return .Ok, or an error for a value TOML cannot hold (an unsigned integer above int64.MaxValue).
	Result<void, TomlParseError> TomlWrite(TomlTable table);
}
