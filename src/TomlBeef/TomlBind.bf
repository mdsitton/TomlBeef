using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// @brief Runtime support for the code [TomlObject] generates: each helper reads or checks one value,
/// so the generated methods stay a short call per field. Public because the generated code lives in
/// the user's types; not meant to be called directly.
///
/// The Read* helpers return whether the key was present: false leaves the field alone, and a missing
/// required key or a value of the wrong type is a located error. The Element* helpers read item `index`
/// of an array the same way.
public static class TomlBind
{
	/// The value at `key` if it has type `typeName`; false if the key is missing and not required.
	static Result<bool, TomlParseError> Lookup(TomlTable table, StringView key, bool required, StringView typeName, out TomlValue value)
	{
		value = default;
		if (!required && !table.ContainsKey(key))
			return false;
		value = Try!(table.RequireValue(key, key, typeName));
		return true;
	}

	/// @brief Read an integer and check it fits the field's type.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param min The field type's smallest value.
	/// @param max The field type's largest value (at most int64.MaxValue).
	/// @param value Receives the integer when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadInteger(TomlTable table, StringView key, bool required, int64 min, int64 max, out int64 value)
	{
		value = 0;
		if (!Try!(Lookup(table, key, required, "integer", let found)))
			return false;
		value = found.AsInteger;
		if (value < min || value > max)
			return .Err(table.MakeError(key, scope $"{value} is outside the range {min} to {max}"));
		return true;
	}

	/// @brief Read a float; an integer is accepted too.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the number when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadFloat(TomlTable table, StringView key, bool required, out double value)
	{
		value = 0;
		if (table.TryGetValue(key, let raw) && raw case .Integer(let asInteger))
		{
			value = asInteger;
			return true;
		}
		if (!Try!(Lookup(table, key, required, "float", let found)))
			return false;
		value = found.AsFloat;
		return true;
	}

	/// @brief Read a boolean.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the boolean when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadBool(TomlTable table, StringView key, bool required, out bool value)
	{
		value = false;
		if (!Try!(Lookup(table, key, required, "boolean", let found)))
			return false;
		value = found.AsBool;
		return true;
	}

	/// @brief Read a string (for String and enum fields; enums match their case names in generated code,
	/// which needs no reflection).
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the string, borrowed from the document, when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadString(TomlTable table, StringView key, bool required, out StringView value)
	{
		value = default;
		if (!Try!(Lookup(table, key, required, "string", let found)))
			return false;
		value = found.AsString;
		return true;
	}

	/// @brief Read an offset date-time.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value The field, set when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadDateTime(TomlTable table, StringView key, bool required, ref TomlOffsetDateTime value)
	{
		if (!Try!(Lookup(table, key, required, "offset datetime", let found)))
			return false;
		value = found.AsOffsetDateTime;
		return true;
	}

	/// @brief Read a local date-time.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value The field, set when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadDateTime(TomlTable table, StringView key, bool required, ref TomlLocalDateTime value)
	{
		if (!Try!(Lookup(table, key, required, "local datetime", let found)))
			return false;
		value = found.AsLocalDateTime;
		return true;
	}

	/// @brief Read a local date.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value The field, set when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadDateTime(TomlTable table, StringView key, bool required, ref TomlLocalDate value)
	{
		if (!Try!(Lookup(table, key, required, "local date", let found)))
			return false;
		value = found.AsLocalDate;
		return true;
	}

	/// @brief Read a local time.
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value The field, set when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadDateTime(TomlTable table, StringView key, bool required, ref TomlLocalTime value)
	{
		if (!Try!(Lookup(table, key, required, "local time", let found)))
			return false;
		value = found.AsLocalTime;
		return true;
	}

	/// @brief Read a sub-table (for a [TomlObject] field).
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the sub-table when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadTable(TomlTable table, StringView key, bool required, out TomlTable value)
	{
		value = null;
		if (!Try!(Lookup(table, key, required, "table", let found)))
			return false;
		value = found.AsTable;
		return true;
	}

	/// @brief Read an array (for a List field).
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the array when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadArray(TomlTable table, StringView key, bool required, out TomlArray value)
	{
		value = null;
		if (!Try!(Lookup(table, key, required, "array", let found)))
			return false;
		value = found.AsArray;
		return true;
	}

	/// @brief Read a value of any type (for a converter field).
	/// @param table The table.
	/// @param key The key.
	/// @param required Whether a missing key is an error.
	/// @param value Receives the value when the key is present.
	/// @return True if the key was present, or the error.
	public static Result<bool, TomlParseError> ReadValue(TomlTable table, StringView key, bool required, out TomlValue value)
	{
		if (table.TryGetValue(key, out value))
			return true;
		if (required)
			return .Err(TomlParseError.Located(.MissingKey, scope $"{key}: missing required value", table.ProblemLocation()));
		return false;
	}

	/// Item `index` of `array` if it has type `typeName`, or a WrongType error located at the item.
	static Result<TomlValue, TomlParseError> Element(TomlArray array, int index, StringView typeName)
	{
		let value = array.GetValueAt(index);
		if (value.TypeName != typeName)
		{
			array.TryGetSourceRange(index, var range);
			return .Err(TomlParseError.Located(.WrongType, scope $"[{index}]: expected {typeName}, found {value.TypeName}", range));
		}
		return value;
	}

	/// @brief Read array item `index` as an integer within [min, max].
	/// @param array The array.
	/// @param index The item.
	/// @param min The element type's smallest value.
	/// @param max The element type's largest value.
	/// @return The integer, or the error.
	public static Result<int64, TomlParseError> ElementInteger(TomlArray array, int index, int64 min, int64 max)
	{
		let value = Try!(Element(array, index, "integer")).AsInteger;
		if (value < min || value > max)
			return .Err(array.MakeError(index, scope $"{value} is outside the range {min} to {max}"));
		return value;
	}

	/// @brief Read array item `index` as a float (an integer is accepted too).
	/// @param array The array.
	/// @param index The item.
	/// @return The number, or the error.
	public static Result<double, TomlParseError> ElementFloat(TomlArray array, int index)
	{
		if (array.GetValueAt(index) case .Integer(let asInteger))
			return (double)asInteger;
		return Try!(Element(array, index, "float")).AsFloat;
	}

	/// @brief Read array item `index` as a boolean.
	/// @param array The array.
	/// @param index The item.
	/// @return The boolean, or the error.
	public static Result<bool, TomlParseError> ElementBool(TomlArray array, int index)
	{
		return Try!(Element(array, index, "boolean")).AsBool;
	}

	/// @brief Read array item `index` as a string.
	/// @param array The array.
	/// @param index The item.
	/// @return The string (borrowed from the document), or the error.
	public static Result<StringView, TomlParseError> ElementString(TomlArray array, int index)
	{
		return Try!(Element(array, index, "string")).AsString;
	}

	/// @brief Read array item `index` as an offset date-time.
	/// @param array The array.
	/// @param index The item.
	/// @return The value, or the error.
	public static Result<TomlOffsetDateTime, TomlParseError> ElementOffsetDateTime(TomlArray array, int index)
	{
		return Try!(Element(array, index, "offset datetime")).AsOffsetDateTime;
	}

	/// @brief Read array item `index` as a local date-time.
	/// @param array The array.
	/// @param index The item.
	/// @return The value, or the error.
	public static Result<TomlLocalDateTime, TomlParseError> ElementLocalDateTime(TomlArray array, int index)
	{
		return Try!(Element(array, index, "local datetime")).AsLocalDateTime;
	}

	/// @brief Read array item `index` as a local date.
	/// @param array The array.
	/// @param index The item.
	/// @return The value, or the error.
	public static Result<TomlLocalDate, TomlParseError> ElementLocalDate(TomlArray array, int index)
	{
		return Try!(Element(array, index, "local date")).AsLocalDate;
	}

	/// @brief Read array item `index` as a local time.
	/// @param array The array.
	/// @param index The item.
	/// @return The value, or the error.
	public static Result<TomlLocalTime, TomlParseError> ElementLocalTime(TomlArray array, int index)
	{
		return Try!(Element(array, index, "local time")).AsLocalTime;
	}

	/// @brief Read array item `index` as a table (for a List of [TomlObject] items).
	/// @param array The array.
	/// @param index The item.
	/// @return The table, or the error.
	public static Result<TomlTable, TomlParseError> ElementTable(TomlArray array, int index)
	{
		return Try!(Element(array, index, "table")).AsTable;
	}

	/// @brief Check that an unsigned field's value fits a TOML integer before it is written.
	/// @param key The key being written, for the message.
	/// @param value The value.
	/// @return .Ok, or InvalidValue when the value is above int64.MaxValue.
	public static Result<void, TomlParseError> CheckWritable(StringView key, uint64 value)
	{
		if (value > (uint64)int64.MaxValue)
			return .Err(TomlParseError(.InvalidValue, scope $"{key}: {value} is above the largest TOML integer", 0, 0, 0));
		return .Ok;
	}

	/// @brief The error for a string that names no case of an enum field.
	/// @param table The table.
	/// @param key The key.
	/// @param name The string that was read.
	/// @param cases The case names, generated from the enum at compile time.
	/// @return An InvalidValue error located at the value.
	public static TomlParseError UnknownCase(TomlTable table, StringView key, StringView name, StringView cases)
	{
		return table.MakeError(key, scope $"'{name}' is not one of {cases}");
	}

	/// @brief The error for an array item that names no case of the list's enum type.
	/// @param array The array.
	/// @param index The item.
	/// @param name The string that was read.
	/// @param cases The case names, generated from the enum at compile time.
	/// @return An InvalidValue error located at the item.
	public static TomlParseError UnknownCase(TomlArray array, int index, StringView name, StringView cases)
	{
		return array.MakeError(index, scope $"'{name}' is not one of {cases}");
	}
}
