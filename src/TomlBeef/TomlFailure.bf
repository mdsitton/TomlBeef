using System;

namespace TomlBeef;

/// The parser's failure token (KdlBeef's, XmlBeef's and JsonBeef's pattern): the parser, the path
/// resolver and the limit checks return `Result<T, TomlFailure>`, an empty error, so the error is not
/// copied on every return up the call chain; the error itself is kept once per thread (its message
/// is in a per-thread buffer anyway) and handed out by TomlParserImpl.Parse.
internal struct TomlFailure
{
	// Not empty on purpose: Beef converts any struct to an empty struct implicitly, so with no field
	// `.Err(TomlParseError(...))` would compile and silently drop the error instead of raising it
	uint8 mUnused;

	[ThreadStatic]
	static TomlParseError sError;

	/// @brief The error the last Raise on this thread kept.
	public static TomlParseError Error => sError;

	/// @brief Keep `error` as this thread's failure.
	/// @param error The error.
	/// @return The token to return in `.Err`.
	[NoInline]
	public static TomlFailure Raise(TomlParseError error)
	{
		sError = error;
		return default;
	}}
