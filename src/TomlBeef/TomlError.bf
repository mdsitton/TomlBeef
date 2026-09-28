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

/// A parse error with location information for precise error reporting.
///
/// The error owns nothing and needs no cleanup, so it can be dropped freely (including by `Try!`).
/// `mMessage` views a per-thread buffer: it stays valid until the next TomlParseError is created on the
/// same thread, which in practice means the next failing TomlBeef call. Copy it to keep it longer.
public struct TomlParseError
{
	/// Per-thread message and source-name storage, freed when the thread exits.
	static LazyTLS<String> sMessageBuffer = new .() ~ delete _;
	static LazyTLS<String> sSourceBuffer = new .() ~ delete _;

	public TomlErrorKind mKind;
	/// @brief Human-readable description. Valid until the next error on this thread.
	public StringView mMessage;
	/// @brief Name of the input the position refers to (TomlReadConfig.SourceName, or the path for
	/// ReadFile/WriteFile); empty if unnamed. Valid until the next error on this thread.
	public StringView mSource;
	// 32-bit positions keep the error (and every parser Result that carries it) small: it is copied on
	// each return up the parser's call chain, even when no error occurs
	/// @brief 1-based line (0 when there is no position).
	public int32 mLine;
	/// @brief 1-based column.
	public int32 mColumn;
	/// @brief Byte offset into the input.
	public int32 mOffset;
	/// @brief Length of the erroneous span in bytes.
	public int32 mLength;

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
		mLine = (int32)line;
		mColumn = (int32)column;
		mOffset = (int32)offset;
		mLength = (int32)length;

		mMessage = Store(sMessageBuffer.Value, message);
		mSource = default;
	}

	/// An error at `range` (line 0 means no position; an empty source means unnamed).
	internal static TomlParseError Located(TomlErrorKind kind, StringView message, TomlSourceRange range)
	{
		var error = TomlParseError(kind, message, range.mLine, range.mColumn, range.mOffset, range.mLength);
		if (!range.mSource.IsEmpty)
			error.SetSource(range.mSource);
		return error;
	}

	/// Copies `text` into a per-thread buffer and returns a view of it.
	static StringView Store(String buffer, StringView text)
	{
		// The text may itself be a view of the buffer (an error rebuilt from a previous one)
		char8* start = buffer.Ptr;
		if (text.Ptr >= start && text.Ptr < start + buffer.Length)
		{
			let copy = scope String(text);
			buffer.Set(copy);
		}
		else
			buffer.Set(text);
		return buffer;
	}

	/// @brief Set the source name the position refers to. Stored like the message: valid until the next
	/// error on this thread.
	/// @param source The source name, e.g. a file path.
	public void SetSource(StringView source) mut
	{
		mSource = Store(sSourceBuffer.Value, source);
	}

	/// @brief Formats the error as `source:line:column: message`, dropping the parts that are unknown
	/// (no source name, or no position: line 0).
	/// @param strBuffer The string to append to.
	public override void ToString(String strBuffer)
	{
		if (!mSource.IsEmpty)
		{
			strBuffer.Append(mSource);
			strBuffer.Append(':');
		}
		if (mLine > 0)
			strBuffer.AppendF("{}:{}:", mLine, mColumn);
		if (!mSource.IsEmpty || mLine > 0)
			strBuffer.Append(' ');
		strBuffer.Append(mMessage);
	}
}
