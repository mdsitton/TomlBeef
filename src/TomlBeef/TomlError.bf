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
	IoError
}

/// A parse error with location information for precise error reporting.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next TomlParseError is created on the
/// same thread, which in practice means the next failing TomlBeef call. Copy it to keep it longer.
public struct TomlParseError
{
	/// Per-thread message storage, freed when the thread exits.
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;

	public TomlErrorKind mKind;
	/// @brief Human-readable description. Valid until the next error on this thread.
	public StringView mMessage;
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
		mLine = line;
		mColumn = column;
		mOffset = offset;
		mLength = length;

		String buffer = sMessageBuffer.Value;
		// The message may itself be a view of the buffer (an error rebuilt from a previous one)
		char8* start = buffer.Ptr;
		if (message.Ptr >= start && message.Ptr < start + buffer.Length)
		{
			let copy = scope String(message);
			buffer.Set(copy);
		}
		else
			buffer.Set(message);
		mMessage = buffer;
	}
}
