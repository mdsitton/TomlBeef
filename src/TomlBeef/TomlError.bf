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

	// Document
	MissingNewlineAfterKeyVal,
	EmptyBareKey,
	InvalidKey
}

/// A parse error with location information for precise error reporting.
public struct TomlParseError
{
	public TomlErrorKind mKind;
	public String mMessage;
	public int mLine;
	public int mColumn;
	public int mOffset;
	public int mLength;

	/// Creates a new parse error at the given location.
	/// @param kind The category of error.
	/// @param message Human-readable description.
	/// @param line 1-based line number.
	/// @param column 1-based column number.
	/// @param offset Byte offset into the input.
	/// @param length Length of the erroneous span in bytes.
	public this(TomlErrorKind kind, StringView message, int line, int column, int offset, int length = 1)
	{
		mKind = kind;
		mMessage = new String(message);
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;
	}

	/// Disposes the error message string.
	public void Dispose()
	{
		delete mMessage;
	}
}
