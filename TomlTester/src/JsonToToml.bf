using System;
using BJSON;
using BJSON.Models;
using TomlBeef;

namespace TomlTester;

/// Builds a TomlDocument from toml-test tagged JSON (the encoder direction).
///
/// A JSON object with exactly the keys "type" and "value", both strings, is a tagged scalar.
/// Any other object is a table and any JSON array is a TOML array. The document is built only
/// through the public typed mutation API.
class JsonToToml
{
	/// Scratch document used to parse scalar literals with TomlBeef's own grammar.
	TomlDocument mScratch = new .() ~ delete _;

	/// @brief Convert tagged JSON text into `doc`.
	/// @param json The toml-test tagged JSON input.
	/// @param doc The document to populate. Existing content is kept.
	/// @param error Receives a description on failure.
	/// @return .Ok on success, .Err if the JSON is malformed or a tag/value is invalid.
	public Result<void> Convert(StringView json, TomlDocument doc, String error)
	{
		var parsed = Json.Deserialize(json);
		defer parsed.Dispose();
		switch (parsed)
		{
		case .Err(let jsonErr):
			error.AppendF("Invalid JSON: {}", jsonErr);
			return .Err;
		case .Ok(let root):
			if (root.AsObject() case .Ok(let rootObject))
				return FillTable(doc.RootTable, rootObject, error);
			error.Append("Top-level JSON value must be an object");
			return .Err;
		}
	}

	Result<void> FillTable(TomlTable table, JsonObject obj, String error)
	{
		for (let (key, value) in obj)
		{
			let type = scope String();
			let text = scope String();
			if (TryGetTag(value, type, text))
			{
				table.Set(key, Try!(ToScalar(type, text, error)));
			}
			else if (value.AsObject() case .Ok(let child))
			{
				Try!(FillTable(table.AddTable(key), child, error));
			}
			else if (value.AsArray() case .Ok(let items))
			{
				Try!(FillArray(table.AddArray(key), items, error));
			}
			else
			{
				error.AppendF("Key '{}': expected a tagged value, object, or array", key);
				return .Err;
			}
		}
		return .Ok;
	}

	Result<void> FillArray(TomlArray array, JsonArray items, String error)
	{
		for (let value in items)
		{
			let type = scope String();
			let text = scope String();
			if (TryGetTag(value, type, text))
			{
				array.Add(Try!(ToScalar(type, text, error)));
			}
			else if (value.AsObject() case .Ok(let child))
			{
				Try!(FillTable(array.AddTable(), child, error));
			}
			else if (value.AsArray() case .Ok(let nested))
			{
				Try!(FillArray(array.AddArray(), nested, error));
			}
			else
			{
				error.Append("Array element: expected a tagged value, object, or array");
				return .Err;
			}
		}
		return .Ok;
	}

	/// Returns true when `value` is a tagged scalar {"type": "...", "value": "..."}, copying the tag
	/// and value text into the caller's buffers. They must be copied: BJSON stores short strings
	/// inline in the JsonValue struct, so a view into a returned copy would dangle.
	static bool TryGetTag(JsonValue value, String type, String text)
	{
		if (!(value.AsObject() case .Ok(let obj)) || obj.Count != 2)
			return false;
		if (!(obj.GetValue("type") case .Ok(var typeValue)) || !typeValue.IsString())
			return false;
		if (!(obj.GetValue("value") case .Ok(var textValue)) || !textValue.IsString())
			return false;
		type.Append((StringView)typeValue);
		text.Append((StringView)textValue);
		return true;
	}

	/// Parses `literal` as the right-hand side of a TOML key/value pair into the scratch document.
	Result<void> ParseLiteral(StringView type, StringView literal, String error)
	{
		if (mScratch.Read(scope $"v = {literal}") case .Err(let e))
		{
			defer e.Dispose();
			error.AppendF("Invalid {} value '{}': {}", type, literal, e.mMessage);
			return .Err;
		}
		return .Ok;
	}

	/// Converts a tagged scalar to a TomlInputValue. A string value borrows `text`, so the result must be
	/// stored (Set/Add copy it) while `text` is alive.
	Result<TomlInputValue> ToScalar(StringView type, StringView text, String error)
	{
		switch (type)
		{
		case "string":
			return (TomlInputValue)(text);
		case "bool":
			if (text != "true" && text != "false")
			{
				error.AppendF("Invalid bool value '{}'", text);
				return .Err;
			}
			return (TomlInputValue)(text == "true");
		}

		Try!(ParseLiteral(type, text, error));
		switch (type)
		{
		case "integer":
			if (mScratch.TryGetInteger("v", let v)) return (TomlInputValue)(v);
		case "float":
			if (mScratch.TryGetFloat("v", let v)) return (TomlInputValue)(v);
			// toml-test writes integral floats without a fraction, e.g. "5"
			if (mScratch.TryGetInteger("v", let i)) return (TomlInputValue)((double)i);
		case "datetime":
			if (mScratch.TryGetOffsetDateTime("v", let v)) return (TomlInputValue)(v);
		case "datetime-local":
			if (mScratch.TryGetLocalDateTime("v", let v)) return (TomlInputValue)(v);
		case "date-local":
			if (mScratch.TryGetLocalDate("v", let v)) return (TomlInputValue)(v);
		case "time-local":
			if (mScratch.TryGetLocalTime("v", let v)) return (TomlInputValue)(v);
		default:
			error.AppendF("Unknown type tag '{}'", type);
			return .Err;
		}
		error.AppendF("Value '{}' is not a valid {}", text, type);
		return .Err;
	}
}
