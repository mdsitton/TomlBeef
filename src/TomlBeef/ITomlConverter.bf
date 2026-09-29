using System;

namespace TomlBeef;

/// @brief Reads and writes one type `T` for [TomlObject] serialization, for types the serializer does not
/// know (types from other libraries, or a custom TOML form for your own). Register it for every field of
/// type T with [TomlConverter(typeof(T))] on the converter, or use it for one field with
/// [TomlUseConverter(typeof(Converter))].
///
/// ```
/// [TomlConverter(typeof(Vector3))]
/// struct Vector3Toml : ITomlConverter<Vector3>
/// {
/// 	public static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref Vector3 target)
/// 	{
/// 		if (!value.TryGetArray(let array) || array.Count != 3)
/// 			return .Err(context.MakeError("expected [x, y, z]"));
/// 		...
/// 	}
///
/// 	public static Result<void, TomlParseError> Write(Vector3 value, TomlConvertContext context)
/// 	{
/// 		let array = context.AddArray();
/// 		...
/// 	}
/// }
/// ```
public interface ITomlConverter<T>
{
	/// @brief Read `value` into `target`.
	/// @param value The TOML value (any type: check it and report a mismatch through `context`).
	/// @param context Where the value is, for located errors.
	/// @param target The field or new list item to fill. A list item starts as default (null for a class),
	/// a field holds its current value.
	/// @return .Ok, or an error (usually from context.MakeError).
	static Result<void, TomlParseError> Read(TomlValue value, TomlConvertContext context, ref T target);

	/// @brief Write `value` through `context`: exactly one Set, AddTable, AddArray or AddArrayOfTables.
	/// @param value The value to write.
	/// @param context Where to write it (a key in a table, or the next item of an array).
	/// @return .Ok, or an error for a value that cannot be written.
	static Result<void, TomlParseError> Write(T value, TomlConvertContext context);
}

/// @brief Where a converter's value lives: under a key in a table, or an item of an array. Reports errors
/// located at the value and writes the converter's output in the right place.
public struct TomlConvertContext
{
	TomlTable mTable;
	StringView mKey;
	TomlArray mArray;
	int mIndex;

	/// @brief The value under `key` in `table`.
	/// @param table The table.
	/// @param key The key.
	public this(TomlTable table, StringView key)
	{
		mTable = table;
		mKey = key;
		mArray = null;
		mIndex = -1;
	}

	/// @brief Item `index` of `array` (reading), or the next item appended to it (writing: index -1).
	/// @param array The array.
	/// @param index The item, or -1 to append.
	public this(TomlArray array, int index = -1)
	{
		mTable = null;
		mKey = default;
		mArray = array;
		mIndex = index;
	}

	/// @brief An InvalidValue error located at the value, naming its key or index.
	/// @param message What is wrong.
	/// @return The error.
	public TomlParseError MakeError(StringView message)
	{
		if (mTable != null)
			return mTable.MakeError(mKey, message);
		return mArray.MakeError(mIndex, message);
	}

	/// @brief Write a scalar.
	/// @param value The value (a string, number, bool or date/time).
	public void Set(TomlInputValue value)
	{
		if (mTable != null)
			mTable.Set(mKey, value);
		else
			mArray.Add(value);
	}

	/// @brief Write a table and return it to fill.
	/// @return The new table.
	public TomlTable AddTable()
	{
		return (mTable != null) ? mTable.AddTable(mKey) : mArray.AddTable();
	}

	/// @brief Write an inline array and return it to fill.
	/// @return The new array.
	public TomlArray AddArray()
	{
		return (mTable != null) ? mTable.AddArray(mKey) : mArray.AddArray();
	}
}

/// @brief Registers the converter it is placed on (an ITomlConverter<T>) for every [TomlObject] field and
/// list item of type `T`, in every project that can see the converter. At most one converter per type.
[AttributeUsage(.Struct | .Class)]
public struct TomlConverterAttribute : Attribute
{
	/// @brief The type the converter handles.
	public Type mTarget;

	/// @brief Register the converter for `target`.
	/// @param target The type the converter handles.
	public this(Type target)
	{
		mTarget = target;
	}
}

/// @brief Reads and writes one field with the given converter (an ITomlConverter<T> for the field's
/// type; for a List field, the whole list), ahead of any registered converter or built-in handling.
[AttributeUsage(.Field)]
public struct TomlUseConverterAttribute : Attribute
{
	/// @brief The converter type.
	public Type mConverter;

	/// @brief Use `converter` for this field.
	/// @param converter The converter type.
	public this(Type converter)
	{
		mConverter = converter;
	}
}
