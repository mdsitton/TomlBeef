using System;

namespace TomlBeef;

/// Categories of parse errors that can occur when processing a TOML document.
public enum TomlErrorKind : uint8
{
	// Lexical
	UnexpectedChar,
	UnexpectedToken,
	UnterminatedString,
	InvalidEscape,
	ReservedEscape,
	InvalidUnicodeScalar,
	ControlCharInString,
	ControlCharInDocument,
	InvalidUtf8,

	// Numeric
	InvalidInteger,
	IntegerOverflow,
	InvalidFloat,
	LeadingZero,
	InvalidUnderscore,

	// Date/Time
	InvalidDateTime,
	InvalidDate,
	InvalidTime,

	// Structure
	DuplicateKey,
	DuplicateTable,
	TypeConflict,
	InlineTableSealed,
	AppendToStaticArray,
	ArrayElementOrdering,
	MaxDepthExceeded,
	ResourceLimitExceeded,

	// Document
	MissingNewlineAfterKeyVal,
	EmptyBareKey,
	InvalidKey,

	// File I/O
	IoError,

	// Validation (errors built from a document: MakeError, Require*)
	/// A required key is not present.
	MissingKey,
	/// A key holds a value of another type than required.
	WrongType,
	/// A value is present with the right type but rejected by the caller's validation.
	InvalidValue
}

/// @brief A parse error with location information for precise error reporting: FormatCore's
/// `ParseError` (kind, message, source, path, line, column, byte offset, length).
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next TomlParseError is created on the
/// same thread, which in practice means the next failing TomlBeef call. Copy it to keep it longer
/// (`TomlDiagnostic`). Formats as `source:line:column: message`.
public typealias TomlParseError = FormatCore.ParseError<TomlErrorKind>;

/// @brief An error that owns its text, for keeping it (FormatCore's `Diagnostic`): delete it when done.
public typealias TomlDiagnostic = FormatCore.Diagnostic<TomlErrorKind>;

/// Error construction helpers.
internal static class TomlErrors
{
	/// An error at `range` (line 0 means no position; an empty source means unnamed).
	public static TomlParseError Located(TomlErrorKind kind, StringView message, TomlSourceRange range)
	{
		var error = TomlParseError(kind, message, range.mLine, range.mColumn, range.mOffset, range.mLength);
		if (!range.mSource.IsEmpty)
			error.SetSource(range.mSource);
		return error;
	}
}
