using System;

namespace TomlBeef;

/// @brief Generates TOML reading and writing for a class or struct at compile time.
///
/// ```
/// [TomlObject]
/// class ServerConfig
/// {
/// 	public String Host = new .() ~ delete _;
/// 	public int32 Port = 8080;
/// 	[TomlName("log-level")] public LogLevel Level;
/// 	public List<String> Tags = new .() ~ DeleteContainerAndItems!(_);
/// }
///
/// let config = scope ServerConfig();
/// Try!(TomlSerializer.Read(text, config));
/// ```
///
/// The type gets ITomlSerializable and its two methods, TomlRead and TomlWrite. Public instance fields
/// are serialized under their own names (see TomlNameAttribute, TomlIgnoreAttribute and
/// TomlRequiredAttribute). Supported field types: bool, the integer types, float and double, String,
/// enums (as their case name), the four TOML date/time types, other [TomlObject] types (as tables) and
/// List<T> of any of these (a list of objects is an array of tables). Any other field type stops the
/// build with an error naming the field.
///
/// Reading fills an existing object: a key missing from the table leaves its field as it was (unless
/// the field is [TomlRequired]), a present key replaces the field's value. A String, object or List
/// field that is null when its key is read gets a new instance, which the type then owns (declare
/// such fields with `~ delete _` or a container delete). Reading a List replaces its items, deleting
/// the old String or object items.
[AttributeUsage(.Class | .Struct)]
public struct TomlObjectAttribute : Attribute, IComptimeTypeApply
{
	/// @brief How field names become TOML keys (a TomlName on a field overrides it). Also applies to the
	/// type name when it is the type's key (see Key).
	public TomlKeyNaming Naming;

	/// @brief Where the type lives in a document: the table TomlDocument.Deserialize(obj) and Serialize(obj)
	/// use when given no path, as a dotted path (`"server"`, `"tool.poetry"`). Unset, it is the type's
	/// name through Naming (`ServerSection` is `server_section` in snake case). It does not affect a field
	/// of this type inside another [TomlObject], which the field's own name decides, nor the whole-file
	/// TomlSerializer calls and `root: true`, which use the document root.
	public String Key;

	/// @brief Checks the type's fields and emits ITomlSerializable, TomlRead and TomlWrite into it.
	/// @param type The type carrying the attribute.
	[Comptime]
	public void ApplyToType(Type type)
	{
		TomlSerializerCodeGen.Emit(type, Naming, (Key != null) ? Key : "");
	}
}

/// @brief How [TomlObject] turns field names into keys. Words split at case changes, keeping
/// acronyms together: `HTTPPort` is `http_port` in snake case.
public enum TomlKeyNaming
{
	/// @brief The field name as written: `PoolSize`.
	AsDeclared,
	/// @brief `pool_size`.
	SnakeCase,
	/// @brief `pool-size`.
	KebabCase,
	/// @brief `poolSize`.
	CamelCase
}

/// @brief Serializes a field under `name` instead of the field's own name.
[AttributeUsage(.Field)]
public struct TomlNameAttribute : Attribute
{
	/// @brief The TOML key.
	public String mName;

	/// @brief Use `name` as the field's TOML key.
	/// @param name The key; any text, quoted in the output when it is not a bare key.
	public this(String name)
	{
		mName = name;
	}
}

/// @brief Leaves a field out of the generated reading and writing.
[AttributeUsage(.Field)]
public struct TomlIgnoreAttribute : Attribute
{
}

/// @brief Makes reading fail (MissingKey, located at the table) when the field's key is absent.
[AttributeUsage(.Field)]
public struct TomlRequiredAttribute : Attribute
{
}
