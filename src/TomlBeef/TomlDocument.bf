using System;
using System.IO;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// Read mode for parsing TOML into a document.
public enum TomlReadMode
{
	/// Clear existing root table, populate from input (default).
	Replace,
	/// Retain existing content and deep-merge the input into it (see TomlTable.MergeFrom).
	Merge
}

/// Conflict resolution for a merge. Tables present on both sides are always merged recursively;
/// these strategies apply only to conflicting leaves (scalars, whole arrays, type mismatches).
public enum MergeConflict
{
	/// A conflicting leaf fails the merge with DuplicateKey and leaves the document unchanged (default).
	Error,
	/// Keep the existing leaf, ignore the incoming one.
	Skip,
	/// Replace the existing leaf (or whole subtree, on a type mismatch) with the incoming one.
	Overwrite
}

/// Configuration for reading TOML into a document.
public struct TomlReadConfig
{
	public TomlReadMode Mode = .Replace;
	public MergeConflict OnConflict = .Error;
	public TomlVersion Version = .V1_1;
	public TomlMetadataMode MetadataMode = .None;
	/// @brief Name of the input for error messages and source ranges, typically its file path (ReadFile
	/// uses the path when this is empty). Only read during the call; the document keeps its own copy.
	public StringView SourceName = default;

	/// @brief Maximum nesting depth (tables / arrays). 0 = unlimited.
	/// Default of 256 matches historical behavior.
	public int MaxDepth = 256;

	/// @brief Maximum input size in bytes. 0 = unlimited.
	public int MaxInputBytes = 0;

	/// @brief Maximum string length in bytes. 0 = unlimited.
	public int MaxStringBytes = 0;

	/// @brief Maximum array items. 0 = unlimited.
	public int MaxArrayItems = 0;

	/// @brief Maximum table entries. 0 = unlimited.
	public int MaxTableEntries = 0;

	/// @brief Maximum dotted/bracketed key path segments. 0 = unlimited.
	public int MaxPathSegments = 0;

	/// @brief Maximum total value nodes (scalars + tables + arrays). 0 = unlimited.
	public int MaxNodes = 0;

	/// @brief Buffer size in bytes for Read(Stream). 0 = default (8 KiB); values below 16 are raised
	/// to 16. Setting it also makes ReadFile stream the file through a buffer of this size instead of
	/// loading it whole, bounding memory for large files (the parsed document still grows with the
	/// content). Tokens longer than the buffer are handled, at the cost of an extra copy.
	public int StreamBufferBytes = 0;

	/// @brief Streamed reads only (Read(Stream), and ReadFile with StreamBufferBytes set): the longest
	/// span of input the reader may hold in memory at once. That is a bare value (number, date, bool),
	/// or with PreserveStyle metadata a whole value's source text, including an inline array
	/// or table. Spans longer than the buffer are otherwise kept in a growing copy, bounded only by
	/// MaxInputBytes and MaxStringBytes. 0 = unlimited. In-memory input needs no such copy and ignores it.
	public int MaxTokenBytes = 0;
}

/// Configuration for writing a document to a TOML string.
public struct TomlWriteConfig
{
	public TomlVersion Version = .V1_1;
}

/// The root of a parsed TOML document.
/// Owns the complete value tree; disposal of the document cleans up everything.
public class TomlDocument
{
	/// @brief This document's read configuration, used by the Read/ReadBytes/ReadFile overloads that take
	/// no config. Set fields directly: `doc.ReadConfig.MetadataMode = .PreserveStyle;`.
	public TomlReadConfig ReadConfig = .();

	/// @brief This document's write configuration, used by the Write/WriteFile overloads that take no
	/// config: `doc.WriteConfig.Version = .V1_0;`.
	public TomlWriteConfig WriteConfig = .();

	/// Default stream buffer size when TomlReadConfig.StreamBufferBytes is 0.
	const int DefaultStreamBufferBytes = 8192;
	/// The parser peeks a few bytes ahead, so the buffer must hold at least this many.
	const int MinStreamBufferBytes = 16;

	private TomlDocumentStore mStore ~ delete _;
	private TomlTable mRootTable; // borrowed from mStore.RootTable
	/// PreserveStyle sidecar. Only replaced or deleted together with a store reset (Clear/destruction),
	/// because containers the caller removed earlier stay alive in the arena and may still reference it.
	private TomlDocumentMetadata mMetadata ~ delete _;

	/// @brief The document's root table (read-only). Use Set, AddTable and AddArray to modify content.
	public TomlTable RootTable => mRootTable;

	/// @brief True when the document carries style metadata (it was read with MetadataMode =
	/// PreserveStyle). Comment and style setters only work in this mode, and only then is the
	/// original formatting written back.
	public bool PreservesStyle => mMetadata != null && mMetadata.CapturesStyle;

	/// @brief True when the document records source positions (it was read with MetadataMode =
	/// Positions or PreserveStyle), so TryGetSourceRange can answer for parsed values.
	public bool HasSourcePositions => mMetadata != null;

	/// @brief Style metadata sidecar, or null if MetadataMode is None.
	internal TomlDocumentMetadata Metadata => mMetadata;

	/// @brief Remove all content from this document.
	public void Clear()
	{
		ClearMetadata();
		mStore.Reset();
		mRootTable = mStore.RootTable;
	}

	/// Deletes the sidecar. Only called right before the store reset, whose destructors free every
	/// container's metadata context, so no walk over the tree is needed.
	private void ClearMetadata()
	{
		if (mMetadata != null)
		{
			delete mMetadata;
			mMetadata = null;
		}
	}

	public this()
	{
		mStore = new TomlDocumentStore();
		mRootTable = mStore.RootTable;
	}

	/// @brief Parse a TOML string into a new document with the default configuration.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @return A new document the caller owns (delete it), or the parse error.
	public static Result<TomlDocument, TomlParseError> Parse(StringView input)
	{
		return Parse(input, .());
	}

	/// @brief Parse a TOML string into a new document.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @param config Read options. Also stored as the new document's ReadConfig.
	/// @return A new document the caller owns (delete it), or the parse error.
	public static Result<TomlDocument, TomlParseError> Parse(StringView input, TomlReadConfig config)
	{
		let doc = new TomlDocument();
		doc.ReadConfig = config;
		if (doc.Read(input, config) case .Err(let err))
		{
			delete doc;
			return .Err(err);
		}
		return doc;
	}

	/// @brief Parse a TOML file into a new document with the default configuration.
	/// @param path File path to read from.
	/// @return A new document the caller owns (delete it), or the file or parse error.
	public static Result<TomlDocument, TomlParseError> ParseFile(StringView path)
	{
		return ParseFile(path, .());
	}

	/// @brief Parse a TOML file into a new document.
	/// @param path File path to read from.
	/// @param config Read options. Also stored as the new document's ReadConfig.
	/// @return A new document the caller owns (delete it), or the file or parse error.
	public static Result<TomlDocument, TomlParseError> ParseFile(StringView path, TomlReadConfig config)
	{
		let doc = new TomlDocument();
		doc.ReadConfig = config;
		if (doc.ReadFile(path, config) case .Err(let err))
		{
			delete doc;
			return .Err(err);
		}
		return doc;
	}

	/// @brief Parse a TOML string into this document using this document's ReadConfig.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(StringView input)
	{
		return Read(input, ReadConfig);
	}

	/// @brief Parse a TOML string into this document with an explicit configuration.
	/// @param input The TOML text to parse. Must be valid UTF-8.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(StringView input, TomlReadConfig config)
	{
		return WithSource(ReadString(input, config), config);
	}

	/// Tags a failed read's error with the input's source name, unless it already names one.
	private static Result<void, TomlParseError> WithSource(Result<void, TomlParseError> result, TomlReadConfig config)
	{
		if (result case .Err(var error))
		{
			if (error.mSource.IsEmpty && !config.SourceName.IsEmpty)
				error.SetSource(config.SourceName);
			return .Err(error);
		}
		return .Ok;
	}

	private Result<void, TomlParseError> ReadString(StringView input, TomlReadConfig config)
	{
		if (config.MaxInputBytes > 0 && input.Length > config.MaxInputBytes)
			return ReadFailure(TomlParseError(.ResourceLimitExceeded, scope $"Input size {input.Length} exceeds maximum {config.MaxInputBytes}", 1, 1, 0), config);

		int start = 0;
		if (TomlChar.ValidateUtf8(input, out start) case .Err(let utf8Err))
			return ReadFailure(utf8Err, config);

		let cursor = TomlByteCursor(Span<uint8>((uint8*)input.Ptr, input.Length), start);
		return ReadWithCursor(cursor, config);
	}

	/// @brief Parse raw UTF-8 bytes into this document.
	/// @param data The TOML input bytes. Must remain valid for the duration of the call.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadBytes(Span<uint8> data)
	{
		return ReadBytes(data, ReadConfig);
	}

	/// @brief Parse raw UTF-8 bytes with an explicit configuration.
	/// @param data The TOML input bytes. Must remain valid for the duration of the call.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err with line/column info on failure. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadBytes(Span<uint8> data, TomlReadConfig config)
	{
		return WithSource(ReadBytesCore(data, config), config);
	}

	private Result<void, TomlParseError> ReadBytesCore(Span<uint8> data, TomlReadConfig config)
	{
		if (config.MaxInputBytes > 0 && data.Length > config.MaxInputBytes)
			return ReadFailure(TomlParseError(.ResourceLimitExceeded, scope $"Input size {data.Length} exceeds maximum {config.MaxInputBytes}", 1, 1, 0), config);

		StringView sv = StringView((char8*)data.Ptr, data.Length);
		int start = 0;
		if (TomlChar.ValidateUtf8(sv, out start) case .Err(let utf8Err))
			return ReadFailure(utf8Err, config);

		let cursor = TomlByteCursor(data, start);
		return ReadWithCursor(cursor, config);
	}

	/// @brief Parse TOML from a stream into this document.
	/// The stream must be readable. The caller owns the stream and should close it after.
	/// @param stream The stream to read from.
	/// @return .Ok on success, or .Err on parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(Stream stream)
	{
		return Read(stream, ReadConfig);
	}

	/// @brief Parse TOML from a stream with an explicit configuration.
	/// @param stream The stream to read from.
	/// @param config Read mode, conflict strategy, and TOML version.
	/// @return .Ok on success, or .Err on parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> Read(Stream stream, TomlReadConfig config)
	{
		return WithSource(ReadStream(stream, config), config);
	}

	private Result<void, TomlParseError> ReadStream(Stream stream, TomlReadConfig config)
	{
		int bufferBytes = config.StreamBufferBytes > 0 ? Math.Max(config.StreamBufferBytes, MinStreamBufferBytes) : DefaultStreamBufferBytes;
		uint8[] buffer = new uint8[bufferBytes];
		defer delete buffer;
		String spill = new String();
		defer delete spill;

		var state = new TomlStreamState();
		state.mMaxInputBytes = config.MaxInputBytes;
		state.mMaxTokenBytes = config.MaxTokenBytes;
		defer delete state;
		var cursor = TomlBufferedStreamCursor(stream, buffer, spill, state);

		// Handle optional UTF-8 BOM at stream start
		{
			char8 b0 = cursor.PeekByte();
			if ((uint8)b0 == 0xEF)
			{
				char8 b1 = cursor.PeekByte(1);
				char8 b2 = cursor.PeekByte(2);
				if ((uint8)b1 == 0xBB && (uint8)b2 == 0xBF)
				{
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					cursor.AdvanceByte();
					// Reject a second BOM immediately following the first
					b0 = cursor.PeekByte();
					if ((uint8)b0 == 0xEF)
					{
						b1 = cursor.PeekByte(1);
						b2 = cursor.PeekByte(2);
						if ((uint8)b1 == 0xBB && (uint8)b2 == 0xBF)
							return ReadFailure(TomlParseError(.ControlCharInDocument, "BOM must only appear at start of file", 1, 1, 3), config);
					}
					// Reset cursor position so parsing sees line 1, column 1 after BOM
					cursor.ResetPosition();
				}
			}
		}

		if (!ShouldParseDirectly(config))
			return ReadMergeFromStreamCursor(cursor, config, state);

		let result = ReadWithCursor(cursor, config);
		if (TryGetStreamError(state, config, var streamError))
			return ReadFailure(streamError, config);
		return result;
	}

	/// The failure that stopped a streamed read, if any. The parser then reports a secondary error
	/// (or none, when the stream failed at the end of the input), so this cause takes precedence.
	private static bool TryGetStreamError(TomlStreamState state, TomlReadConfig config, out TomlParseError error)
	{
		if (state.mBytesExceeded)
			error = TomlParseError(.ResourceLimitExceeded, scope $"Input size exceeds maximum {config.MaxInputBytes}", 0, 0, 0);
		else if (state.mTokenExceeded)
			error = TomlParseError(.ResourceLimitExceeded, scope $"Token length exceeds maximum {config.MaxTokenBytes}",
				state.mTokenErrorLine, state.mTokenErrorColumn, state.mTokenErrorOffset);
		else if (state.mError)
			error = TomlParseError(.IoError, "Stream read error", 0, 0, 0);
		else if (state.mUtf8Error)
			error = TomlParseError(.InvalidUtf8, "Invalid UTF-8 sequence",
				state.mUtf8ErrorLine, state.mUtf8ErrorColumn, state.mUtf8ErrorOffset);
		else
		{
			error = default;
			return false;
		}
		return true;
	}

	private Result<void, TomlParseError> ReadMergeFromStreamCursor<TCursor>(TCursor cursor, TomlReadConfig config, TomlStreamState state) where TCursor : ITomlCursor
	{
		TomlResourceLimitState limits = scope TomlResourceLimitState(config);
		var tempStore = new TomlDocumentStore();
		defer delete tempStore;
		var incoming = tempStore.RootTable;
		tempStore.mSuppressAutoDirty = true;

		TomlDocumentMetadata incomingMetadata = null;
		if (config.MetadataMode != .None)
		{
			incomingMetadata = new TomlDocumentMetadata(config.MetadataMode);
			incoming.MetadataContext = new TomlContainerMetadataContext(incomingMetadata, .Invalid, false);
		}
		defer { if (incomingMetadata != null) delete incomingMetadata; }

		let parser = scope TomlParserImpl<TCursor>(config, tempStore, incomingMetadata, limits);
		let resolver = scope TomlPathResolver(incoming, incomingMetadata, tempStore, limits);
		let parsed = parser.Parse(cursor, resolver);
		if (TryGetStreamError(state, config, var streamError))
			return .Err(streamError);
		if (parsed case .Err(let e))
			return .Err(e);
		return MergeIncoming(incoming, incomingMetadata, config);
	}

	/// Deep-merges a parsed temporary document into this one. The destination keeps its PreserveStyle
	/// metadata; merged values get node IDs and, when `incomingMetadata` exists, the incoming styles.
	private Result<void, TomlParseError> MergeIncoming(TomlTable incoming, TomlDocumentMetadata incomingMetadata, TomlReadConfig config)
	{
		// The root context is how MergeFrom finds the incoming sidecar
		if (incomingMetadata != null && incoming.MetadataContext == null)
			incoming.MetadataContext = new TomlContainerMetadataContext(incomingMetadata, .Invalid, false);
		incoming.mStore.mSuppressAutoDirty = false;
		// Styles and comments merged from a PreserveStyle read make a Positions document preserve style.
		// Upgrade first so the merge has style records to copy into; a rejected merge changes nothing.
		let previousMode = mMetadata?.mMode ?? .None;
		if (mMetadata != null && incomingMetadata != null)
			mMetadata.Upgrade(incomingMetadata.mMode);
		if (mRootTable.MergeFrom(incoming, config.OnConflict) case .Err(let e))
		{
			if (mMetadata != null)
				mMetadata.mMode = previousMode;
			return .Err(e);
		}
		return .Ok;
	}

	private bool ShouldParseDirectly(TomlReadConfig config)
	{
		return mRootTable.Count == 0 || config.Mode == .Replace;
	}

	private Result<void, TomlParseError> ReadFailure(TomlParseError error, TomlReadConfig config)
	{
		if (ShouldParseDirectly(config))
		{
			Clear();
		}
		return .Err(error);
	}

	private Result<void, TomlParseError> ReadWithCursor<TCursor>(TCursor cursor, TomlReadConfig config) where TCursor : ITomlCursor
	{
		TomlResourceLimitState limits = scope TomlResourceLimitState(config);
		bool wantsMetadata = config.MetadataMode != .None;

		// Fast path: nothing to preserve — parse directly into root
		if (ShouldParseDirectly(config))
		{
			if (config.Mode == .Replace)
				Clear();
			// A Merge into an empty document keeps an existing sidecar (nothing may delete it before a
			// store reset); Replace has just cleared it.
			if (wantsMetadata && mMetadata == null)
				mMetadata = new TomlDocumentMetadata(config.MetadataMode);
			else if (wantsMetadata)
				mMetadata.Upgrade(config.MetadataMode);
			let parser = scope TomlParserImpl<TCursor>(config, mStore, wantsMetadata ? mMetadata : null, limits);
			mStore.mSuppressAutoDirty = true;
			// Attach the root context before parsing so every table created during the parse (including
			// intermediate tables of dotted keys) inherits a context and its keys get node IDs
			if (wantsMetadata && mRootTable.MetadataContext == null)
				mRootTable.MetadataContext = new TomlContainerMetadataContext(mMetadata, .Invalid, false);
			let resolver = scope TomlPathResolver(mRootTable, mMetadata, mStore, limits);
			if (parser.Parse(cursor, resolver) case .Err(let parseErr))
			{
				Clear();
				return .Err(parseErr);
			}
			mStore.mSuppressAutoDirty = false;
			return .Ok;
		}

		// Merge with existing content — transactional via temp store
		var tempStore = new TomlDocumentStore();
		defer delete tempStore;
		var incoming = tempStore.RootTable;
		tempStore.mSuppressAutoDirty = true;
		TomlDocumentMetadata incomingMetadata = null;
		if (wantsMetadata)
		{
			incomingMetadata = new TomlDocumentMetadata(config.MetadataMode);
			incoming.MetadataContext = new TomlContainerMetadataContext(incomingMetadata, .Invalid, false);
		}
		defer { if (incomingMetadata != null) delete incomingMetadata; }
		{
			let parser = scope TomlParserImpl<TCursor>(config, tempStore, incomingMetadata, limits);
			let resolver = scope TomlPathResolver(incoming, incomingMetadata, tempStore, limits);
			if (parser.Parse(cursor, resolver) case .Err(let e))
				return .Err(e);
		}
		return MergeIncoming(incoming, incomingMetadata, config);
	}

	/// @brief Serialize this document to a TOML string using this document's WriteConfig.
	/// @param output The destination string to append to.
	public void Write(String output)
	{
		Write(output, WriteConfig);
	}

	/// @brief Serialize this document to a TOML string with an explicit configuration.
	/// @param output The destination string to append to.
	/// @param config Write options.
	public void Write(String output, TomlWriteConfig config)
	{
		TomlWriterImpl.Write(this, output, config.Version);
	}

	/// @brief Set a scalar value at a dotted path, creating any missing parent tables:
	/// `doc.Set("server.port", 8080)`. Accepts strings, integers, floats, bools and the date/time types.
	/// @param dottedPath The path (bracketed segments allowed, e.g. `a.[b.c]`).
	/// @param value The value.
	/// @return False if the path is malformed or a parent segment exists but is not a table.
	public bool Set(StringView dottedPath, TomlInputValue value)
	{
		TomlTable parent;
		StringView key;
		if (!ResolvePath(dottedPath, true, out parent, out key))
			return false;
		parent.Set(key, value);
		return true;
	}

	/// @brief Remove the value at a dotted path.
	/// @param dottedPath The path of the value to remove.
	/// @return True if the value existed and was removed.
	public bool Remove(StringView dottedPath)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.Remove(key);
	}

	/// @brief Create a new table at a dotted path (written as a `[header]`), creating missing parents.
	/// @param dottedPath The path of the new table.
	/// @return The new table, or null if the key already exists or a parent segment is not a table.
	public TomlTable AddTable(StringView dottedPath)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, true, out parent, out key) ? parent.AddTable(key) : null;
	}

	/// @brief Create a new array at a dotted path, creating missing parents.
	/// @param dottedPath The path of the new array.
	/// @return The new array, or null if the key already exists or a parent segment is not a table.
	public TomlArray AddArray(StringView dottedPath)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, true, out parent, out key) ? parent.AddArray(key) : null;
	}

	// ================================================================
	// Comments and presentation style (documents read with PreserveStyle)
	// ================================================================

	/// @brief Set the comment block at the top of the file, above all content. Lines separated by '\n',
	/// each written as `# line`. Empty removes it.
	/// @param comment The comment text without '#' markers.
	/// @return False if the document has no PreserveStyle metadata or the text contains control characters.
	public bool SetFileHeaderComment(StringView comment)
	{
		if (!PreservesStyle || !IsValidCommentText(comment))
			return false;
		mMetadata.ReplaceCommentLines(mMetadata.GetOrCreateRootComments(), comment);
		return true;
	}

	/// @brief Set the comment block at the end of the file, after all content. Empty removes it.
	/// @param comment The comment text without '#' markers; lines separated by '\n'.
	/// @return False if the document has no PreserveStyle metadata or the text contains control characters.
	public bool SetFileFooterComment(StringView comment)
	{
		if (!PreservesStyle || !IsValidCommentText(comment))
			return false;
		mMetadata.ReplaceCommentLines(mMetadata.GetOrCreateFooterComments(), comment);
		return true;
	}

	/// @brief Set the comment lines above the value at a dotted path. See TomlTable.SetComment.
	/// @param dottedPath The path of the value (bracketed segments allowed).
	/// @param comment The comment text without '#' markers; lines separated by '\n'. Empty removes it.
	/// @return False if the path does not resolve or TomlTable.SetComment fails.
	public bool SetComment(StringView dottedPath, StringView comment)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetComment(key, comment);
	}

	/// @brief Set the comment at the end of the line of the value at a dotted path.
	/// See TomlTable.SetTrailingComment.
	/// @param dottedPath The path of the value (bracketed segments allowed).
	/// @param comment The comment text without the '#' marker. Must be a single line; empty removes it.
	/// @return False if the path does not resolve or TomlTable.SetTrailingComment fails.
	public bool SetTrailingComment(StringView dottedPath, StringView comment)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetTrailingComment(key, comment);
	}

	/// @brief Choose how the string at a dotted path is written. See TomlTable.SetStringStyle.
	/// @param dottedPath The path of a string value.
	/// @param style The string style to write.
	/// @return False if the path does not resolve or TomlTable.SetStringStyle fails.
	public bool SetStringStyle(StringView dottedPath, TomlStringStyle style)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetStringStyle(key, style);
	}

	/// @brief Choose the base the integer at a dotted path is written in. See TomlTable.SetIntegerBase.
	/// @param dottedPath The path of an integer value.
	/// @param integerBase The base to write.
	/// @return False if the path does not resolve or TomlTable.SetIntegerBase fails.
	public bool SetIntegerBase(StringView dottedPath, TomlIntegerBase integerBase)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetIntegerBase(key, integerBase);
	}

	/// @brief Choose decimal or scientific notation for the float at a dotted path. See
	/// TomlTable.SetFloatNotation.
	/// @param dottedPath The path of a float value.
	/// @param notation The notation to write.
	/// @return False if the path does not resolve or TomlTable.SetFloatNotation fails.
	public bool SetFloatNotation(StringView dottedPath, TomlFloatNotation notation)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetFloatNotation(key, notation);
	}

	/// @brief Choose how the date-time or time at a dotted path is written. See TomlTable.SetDateTimeStyle.
	/// @param dottedPath The path of a date-time or time value.
	/// @param style The style to write.
	/// @return False if the path does not resolve or TomlTable.SetDateTimeStyle fails.
	public bool SetDateTimeStyle(StringView dottedPath, TomlDateTimeStyle style)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetDateTimeStyle(key, style);
	}

	/// @brief Choose one-line or one-element-per-line layout for the array at a dotted path. See
	/// TomlTable.SetArrayLayout.
	/// @param dottedPath The path of an array.
	/// @param layout The layout to write.
	/// @param trailingComma For the multi-line layout, whether the last element gets a comma.
	/// @return False if the path does not resolve or TomlTable.SetArrayLayout fails.
	public bool SetArrayLayout(StringView dottedPath, TomlArrayLayout layout, bool trailingComma = true)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetArrayLayout(key, layout, trailingComma);
	}

	/// @brief Choose the layout of the inline table at a dotted path. See TomlTable.SetInlineTableLayout.
	/// @param dottedPath The path of an inline table.
	/// @param layout The layout to write.
	/// @return False if the path does not resolve or TomlTable.SetInlineTableLayout fails.
	public bool SetInlineTableLayout(StringView dottedPath, TomlInlineTableLayout layout)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetInlineTableLayout(key, layout);
	}

	/// @brief Choose how the last key of a dotted path is quoted. See TomlTable.SetKeyQuoting.
	/// @param dottedPath The path of the entry.
	/// @param quoting The quoting to write.
	/// @return False if the path does not resolve or TomlTable.SetKeyQuoting fails.
	public bool SetKeyQuoting(StringView dottedPath, TomlKeyQuoting quoting)
	{
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.SetKeyQuoting(key, quoting);
	}

	/// @brief Where the value at a dotted path appeared in the source. See TomlTable.TryGetSourceRange.
	/// Example: report `port must be positive (line {range.mLine})`.
	/// @param dottedPath The path of the value (bracketed segments allowed).
	/// @param range Receives the 1-based line and column, byte offset, and length.
	/// @return True if the path resolves and a source position is known (requires Positions or PreserveStyle).
	public bool TryGetSourceRange(StringView dottedPath, out TomlSourceRange range)
	{
		range = default;
		TomlTable parent;
		StringView key;
		return ResolvePath(dottedPath, false, out parent, out key) && parent.TryGetSourceRange(key, out range);
	}

	private static bool IsValidCommentText(StringView text)
	{
		return TomlDocumentMetadata.IsValidCommentText(text, true);
	}

	/// Parses a dotted path and walks all but its last segment, returning the parent table and final key
	/// (which borrows from `dottedPath`). With `createParents`, missing segments become new tables.
	/// @return False if the path is malformed, or a parent segment is missing (without createParents)
	/// or exists but is not a table.
	private bool ResolvePath(StringView dottedPath, bool createParents, out TomlTable parent, out StringView finalKey)
	{
		parent = null;
		finalKey = default;
		var segments = scope List<StringView>();
		if (!ParseDottedPath(dottedPath, segments) || segments.IsEmpty)
			return false;

		TomlTable current = mRootTable;
		for (int i = 0; i < segments.Count - 1; i++)
		{
			if (current.TryGetValue(segments[i], let val))
			{
				if (!val.IsTable)
					return false;
				current = val.AsTable;
			}
			else if (createParents)
				current = current.AddTable(segments[i]);
			else
				return false;
		}
		parent = current;
		finalKey = segments.Back;
		return true;
	}

	/// @brief Navigate a bracket-aware dotted path and return the value at that path, regardless of type.
	/// The value borrows document-owned storage: valid until the document is cleared. Prefer the typed
	/// TryGet* path accessors when the type is known.
	/// Supports `[segment]` syntax for path segments that contain literal dots:
	///   "a.b.c"      → ["a", "b", "c"]
	///   "a.[b.c]"    → ["a", "b.c"]
	///   "[a.b]"      → ["a.b"]
	/// @param dottedPath The path to traverse. Supports bracket-delimited segments.
	/// @return The value on success, or .Err if any segment is not found or the path is malformed.
	public Result<TomlValue> Get(StringView dottedPath)
	{
		var segments = scope List<StringView>();
		if (!ParseDottedPath(dottedPath, segments))
			return .Err;
		return GetPath(segments);
	}

	/// @brief Indexer over dotted paths, the same as Get: `Try!(doc["server.port"])` or
	/// `if (doc["server.port"] case .Ok(let port))`. Read-only; use Set to write.
	/// @param dottedPath The path to traverse. Supports bracket-delimited segments.
	/// @return The value (borrowed, like Get), or .Err if any segment is not found or the path is malformed.
	public Result<TomlValue> this[StringView dottedPath]
	{
		get
		{
			return Get(dottedPath);
		}
	}

	/// @brief Navigate exact path segments and return the value (borrowed, like Get). Accepts individual
	/// segment strings for ergonomic multi-segment lookups.
	/// @param segments The path segments to traverse, in order.
	/// @return The value on success, or .Err if any segment is not found.
	public Result<TomlValue> GetPath(params StringView[] segments)
	{
		var list = scope List<StringView>();
		for (int i = 0; i < segments.Count; i++)
			list.Add(segments[i]);
		return GetPath(list);
	}

	/// @brief Navigate exact path segments from a list (value borrowed, like Get). Useful when segments are
	/// already in a list (e.g., from ParseDottedPath).
	/// @param segments The path segments to traverse, in order.
	/// @return The value on success, or .Err if any segment is not found.
	public Result<TomlValue> GetPath(List<StringView> segments)
	{
		TomlTable current = mRootTable;
		for (int i = 0; i < segments.Count; i++)
		{
			StringView segment = segments[i];
			if (segment.IsEmpty)
				return .Err;
			if (i == segments.Count - 1)
			{
				// Final segment — return the value
				if (current.TryGetValue(segment, let val))
					return val;
				return .Err;
			}
			// Intermediate segment — must be a table
			if (!current.TryGetValue(segment, let val) || !val.IsTable)
				return .Err;
			current = val.AsTable;
		}
		return .Err;
	}

	/// Parse a bracket-aware dotted path into StringView segments.
	/// Segments borrow from the input path.
	/// @param path The path string to parse.
	/// @param segments Output list of segment views.
	/// @return False if the path is malformed (empty segments, unmatched brackets).
	internal static bool ParseDottedPath(StringView path, List<StringView> segments)
	{
		if (path.IsEmpty)
			return false;

		int i = 0;
		while (i < path.Length)
		{
			// Skip the leading dot between segments (not on first iteration)
			if (i > 0 && path[i] == '.')
			{
				i++;
				// Consecutive dots mean empty segment
				if (i >= path.Length || path[i] == '.')
					return false;
			}

			if (path[i] == '[')
			{
				i++; // skip '['
				int segStart = i;
				// Scan for matching ']'
				while (i < path.Length && path[i] != ']')
					i++;
				if (i >= path.Length)
					return false; // unmatched '['
				int segLen = i - segStart;
				i++; // skip ']'
				if (segLen == 0)
					return false; // empty bracketed segment
				segments.Add(path.Substring(segStart, segLen));

				// After a bracketed segment, next char must be '.' or end
				if (i < path.Length && path[i] != '.')
					return false;
			}
			else if (path[i] == ']')
			{
				return false; // unmatched ']'
			}
			else
			{
				// Bare (unbracketed) segment — scan until '.' or end
				int segStart = i;
				while (i < path.Length && path[i] != '.' && path[i] != '[' && path[i] != ']')
					i++;
				int segLen = i - segStart;
				if (segLen == 0)
					return false; // empty segment
				segments.Add(path.Substring(segStart, segLen));

				// After a bare segment, next char must be '.' or end
				if (i < path.Length && path[i] != '.')
					return false;
			}
		}

		return segments.Count > 0;
	}

	/// @brief Navigate a dotted path and extract a String value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the string value at the path.
	/// @return True if the path exists and holds a String.
	public bool TryGetString(StringView dottedPath, out StringView value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetString(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an Integer value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the integer value at the path.
	/// @return True if the path exists and holds an Integer.
	public bool TryGetInteger(StringView dottedPath, out int64 value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetInteger(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Float value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the float value at the path.
	/// @return True if the path exists and holds a Float.
	public bool TryGetFloat(StringView dottedPath, out double value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetFloat(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Bool value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the boolean value at the path.
	/// @return True if the path exists and holds a Bool.
	public bool TryGetBool(StringView dottedPath, out bool value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetBool(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a Table value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the table value at the path.
	/// @return True if the path exists and holds a Table.
	public bool TryGetTable(StringView dottedPath, out TomlTable value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetTable(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an Array value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the array value at the path.
	/// @return True if the path exists and holds an Array.
	public bool TryGetArray(StringView dottedPath, out TomlArray value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetArray(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract an OffsetDateTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the offset date-time value at the path.
	/// @return True if the path exists and holds an OffsetDateTime.
	public bool TryGetOffsetDateTime(StringView dottedPath, out TomlOffsetDateTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetOffsetDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalDateTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local date-time value at the path.
	/// @return True if the path exists and holds a LocalDateTime.
	public bool TryGetLocalDateTime(StringView dottedPath, out TomlLocalDateTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalDateTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalDate value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local date value at the path.
	/// @return True if the path exists and holds a LocalDate.
	public bool TryGetLocalDate(StringView dottedPath, out TomlLocalDate value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalDate(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Navigate a dotted path and extract a LocalTime value in a single call.
	/// @param dottedPath The dotted path to traverse.
	/// @param value On success, the local time value at the path.
	/// @return True if the path exists and holds a LocalTime.
	public bool TryGetLocalTime(StringView dottedPath, out TomlLocalTime value)
	{
		if (Get(dottedPath) case .Ok(let val) && val.TryGetLocalTime(out value))
			return true;
		value = default;
		return false;
	}

	/// @brief Get a String at a dotted path, or a fallback when it is missing or not a String.
	/// @param dottedPath The dotted path to traverse.
	/// @param defaultValue Returned when the path is missing or holds another type.
	/// @return The stored string (borrowed from this document) or defaultValue.
	public StringView GetString(StringView dottedPath, StringView defaultValue)
	{
		return TryGetString(dottedPath, let value) ? value : defaultValue;
	}

	/// @brief Get an Integer at a dotted path, or a fallback when it is missing or not an Integer.
	/// @param dottedPath The dotted path to traverse.
	/// @param defaultValue Returned when the path is missing or holds another type.
	/// @return The stored integer or defaultValue.
	public int64 GetInteger(StringView dottedPath, int64 defaultValue)
	{
		return TryGetInteger(dottedPath, let value) ? value : defaultValue;
	}

	/// @brief Get a Float at a dotted path, or a fallback when it is missing or not a Float.
	/// @param dottedPath The dotted path to traverse.
	/// @param defaultValue Returned when the path is missing or holds another type.
	/// @return The stored float or defaultValue.
	public double GetFloat(StringView dottedPath, double defaultValue)
	{
		return TryGetFloat(dottedPath, let value) ? value : defaultValue;
	}

	/// @brief Get a Bool at a dotted path, or a fallback when it is missing or not a Bool.
	/// @param dottedPath The dotted path to traverse.
	/// @param defaultValue Returned when the path is missing or holds another type.
	/// @return The stored bool or defaultValue.
	public bool GetBool(StringView dottedPath, bool defaultValue)
	{
		return TryGetBool(dottedPath, let value) ? value : defaultValue;
	}

	// ================================================================
	// Validation: errors located in the source
	// ================================================================

	/// @brief Build an error about the value at a dotted path for your own validation, located where the
	/// value appeared in the source: `return .Err(doc.MakeError("server.port", "must be positive"));`
	/// prints (via ToString) as `config.toml:12:3: server.port: must be positive`. A missing value is
	/// located at the deepest table on the path. Needs a document read with Positions or PreserveStyle
	/// for a position; without one the message still names the path.
	/// @param dottedPath The path the problem is about (it need not exist).
	/// @param message What is wrong with it.
	/// @return An error of kind InvalidValue.
	public TomlParseError MakeError(StringView dottedPath, StringView message)
	{
		WalkToParent(dottedPath, let parent, let key);
		return TomlParseError.Located(.InvalidValue, scope $"{dottedPath}: {message}", parent.ProblemLocation(key));
	}

	/// @brief Get a required String at a dotted path. A missing value or a value of another type is a
	/// located error naming the path: MissingKey (at the deepest table on the path) or WrongType (at the
	/// value, or at a non-table segment on the way).
	/// @param dottedPath The path.
	/// @return The string (borrowed from this document), or the error.
	public Result<StringView, TomlParseError> RequireString(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "string")).AsString;
	}

	/// @brief Get a required Integer at a dotted path; see RequireString for the errors.
	/// @param dottedPath The path.
	/// @return The integer, or the error.
	public Result<int64, TomlParseError> RequireInteger(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "integer")).AsInteger;
	}

	/// @brief Get a required Float at a dotted path (an integer is not accepted); see RequireString.
	/// @param dottedPath The path.
	/// @return The float, or the error.
	public Result<double, TomlParseError> RequireFloat(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "float")).AsFloat;
	}

	/// @brief Get a required Bool at a dotted path; see RequireString for the errors.
	/// @param dottedPath The path.
	/// @return The bool, or the error.
	public Result<bool, TomlParseError> RequireBool(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "boolean")).AsBool;
	}

	/// @brief Get a required Table at a dotted path; see RequireString for the errors.
	/// @param dottedPath The path.
	/// @return The table, or the error.
	public Result<TomlTable, TomlParseError> RequireTable(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "table")).AsTable;
	}

	/// @brief Get a required Array at a dotted path; see RequireString for the errors.
	/// @param dottedPath The path.
	/// @return The array, or the error.
	public Result<TomlArray, TomlParseError> RequireArray(StringView dottedPath)
	{
		return Try!(RequireValue(dottedPath, "array")).AsArray;
	}

	// ================================================================
	// [TomlObject] serialization, mixed freely with the rest of the API
	// ================================================================

	/// @brief Fill a [TomlObject] class from its own table: the type's Key, or its name
	/// (`doc.Deserialize(server)` reads `[server]` for `[TomlObject(Key = "server")]`), or from the whole
	/// document with `root: true` (see TomlObjectAttribute).
	///
	/// A String, nested object or List field that is null when its key is read gets a new instance, as
	/// does every String or object item of a list. Without `allocator` these come from the heap and the
	/// type owns them (declare such fields with `~ delete _`), and a list's old items are deleted when it
	/// is read again. With `allocator` (for example a `scope BumpAllocator`) they come from it and it
	/// owns them: the type must not delete them (no `~ delete _` on those fields), and old list items
	/// are dropped, not deleted, so read into objects that do not already own heap items.
	/// @param target The object to fill.
	/// @param root True to read the whole document (the root table) instead of the type's table.
	/// @param allocator Where created objects come from, or null for the heap.
	/// @return .Ok, or the first error (a missing table is MissingKey; errors are located when the
	/// document was read with positions).
	public Result<void, TomlParseError> Deserialize<T>(T target, bool root = false, ITypedAllocator allocator = null) where T : class, ITomlSerializable
	{
		if (root)
			return target.TomlRead(mRootTable, allocator);
		return target.TomlRead(Try!(RequireTable(T.TomlKey)), allocator);
	}

	/// @brief Fill a [TomlObject] class from the table at a dotted path: `doc.Deserialize("server", server)`.
	/// The rest of the document stays available through the ordinary API.
	/// @param dottedPath The path of the table.
	/// @param target The object to fill.
	/// @param allocator Where created objects come from, or null for the heap (see the path-less overload).
	/// @return .Ok, or the first error (a missing table is MissingKey).
	public Result<void, TomlParseError> Deserialize<T>(StringView dottedPath, T target, ITypedAllocator allocator = null) where T : class, ITomlSerializable
	{
		return target.TomlRead(Try!(RequireTable(dottedPath)), allocator);
	}

	/// @brief Fill a [TomlObject] struct from its own table, or the whole document with `root: true`; see
	/// the class overload.
	/// @param target The struct to fill.
	/// @param root True to read the whole document instead of the type's table.
	/// @param allocator Where created objects come from, or null for the heap (see the class overload).
	/// @return .Ok, or the first error.
	public Result<void, TomlParseError> Deserialize<T>(ref T target, bool root = false, ITypedAllocator allocator = null) where T : struct, ITomlSerializable
	{
		if (root)
			return target.TomlRead(mRootTable, allocator);
		return target.TomlRead(Try!(RequireTable(T.TomlKey)), allocator);
	}

	/// @brief Fill a [TomlObject] struct from the table at a dotted path.
	/// @param dottedPath The path of the table.
	/// @param target The struct to fill.
	/// @param allocator Where created objects come from, or null for the heap (see the class overload).
	/// @return .Ok, or the first error.
	public Result<void, TomlParseError> Deserialize<T>(StringView dottedPath, ref T target, ITypedAllocator allocator = null) where T : struct, ITomlSerializable
	{
		return target.TomlRead(Try!(RequireTable(dottedPath)), allocator);
	}

	/// @brief Write a [TomlObject]'s fields into its own table (the type's Key, or its name; created if
	/// needed), or into the whole document with `root: true`, updating it in place (see
	/// TomlTable.Serialize): keys the type does not know stay, unchanged values keep their formatting.
	/// @param source The object to write.
	/// @param root True to write into the root table instead of the type's table.
	/// @return .Ok, or an error for a value TOML cannot hold.
	public Result<void, TomlParseError> Serialize<T>(T source, bool root = false) where T : ITomlSerializable
	{
		if (root)
			return source.TomlWrite(mRootTable);
		return Serialize(T.TomlKey, source);
	}

	/// @brief Write a [TomlObject]'s fields into the table at a dotted path, creating it (and missing
	/// parents) if needed and otherwise updating it in place: `doc.Serialize("server", server)`.
	/// @param dottedPath The path of the table. A value there that is not a table is replaced.
	/// @param source The object to write.
	/// @return .Ok, or an error (a malformed path, a parent that is not a table, or a value TOML cannot hold).
	public Result<void, TomlParseError> Serialize<T>(StringView dottedPath, T source) where T : ITomlSerializable
	{
		if (!ResolvePath(dottedPath, true, let parent, let key))
			return .Err(TomlParseError(.InvalidKey, scope $"Cannot write a table at '{dottedPath}': the path is malformed or a parent is not a table", 0, 0, 0));
		return source.TomlWrite(parent.WriteTableAt(key, true));
	}

	private Result<TomlValue, TomlParseError> RequireValue(StringView dottedPath, StringView typeName)
	{
		if (WalkToParent(dottedPath, let parent, let key))
			return parent.RequireValue(key, dottedPath, typeName);
		if (key.IsEmpty)
			return .Err(TomlParseError(.InvalidKey, scope $"Invalid path '{dottedPath}'", 0, 0, 0));
		// A segment on the way is not a table, or is missing
		if (parent.TryGetValue(key, let blocking))
			return .Err(TomlParseError.Located(.WrongType, scope $"{dottedPath}: expected '{key}' to be a table, found {blocking.TypeName}", parent.ProblemLocation(key)));
		return .Err(TomlParseError.Located(.MissingKey, scope $"{dottedPath}: missing required {typeName}", parent.ProblemLocation()));
	}

	/// Walks `dottedPath` to the table that holds its last segment. On success `key` is that segment. If
	/// a segment on the way is missing or not a table, `parent` is the deepest table reached and `key` the
	/// segment that stopped the walk; for a malformed path `parent` is the root and `key` empty.
	/// @return True if every parent segment is a table (the last segment itself may still be missing).
	private bool WalkToParent(StringView dottedPath, out TomlTable parent, out StringView key)
	{
		parent = mRootTable;
		key = default;
		var segments = scope List<StringView>();
		if (!ParseDottedPath(dottedPath, segments) || segments.IsEmpty)
			return false;
		for (int i = 0; i < segments.Count - 1; i++)
		{
			TomlValue value;
			if (!parent.TryGetValue(segments[i], out value) || !value.IsTable)
			{
				key = segments[i];
				return false;
			}
			parent = value.AsTable;
		}
		key = segments.Back;
		return true;
	}

	/// @brief Parse a TOML file into this document. Convenience wrapper around Read().
	/// @param path File path to read from.
	/// @return .Ok on success, or .Err on file or parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadFile(StringView path)
	{
		return ReadFile(path, ReadConfig);
	}

	/// @brief Parse a TOML file into this document with an explicit configuration.
	/// @param path File path to read from.
	/// @param config Read options. An empty SourceName defaults to `path`, which errors and source ranges
	/// then report.
	/// @return .Ok on success, or .Err on file or parse error. Replace failures leave this document empty; Merge failures leave existing content unchanged.
	public Result<void, TomlParseError> ReadFile(StringView path, TomlReadConfig config)
	{
		var config;
		if (config.SourceName.IsEmpty)
			config.SourceName = path;

		// With an explicit stream buffer, stream the file instead of loading it whole
		if (config.StreamBufferBytes > 0)
		{
			let file = scope FileStream();
			if (file.Open(path, .Read, .Read) case .Err)
				return WithSource(ReadFailure(TomlParseError(.IoError, "Cannot read file", 0, 0, 0), config), config);
			return Read(file, config);
		}

		// Parse the loaded bytes directly; no second copy into a String
		let data = scope List<uint8>();
		if (File.ReadAll(path, data) case .Err)
			return WithSource(ReadFailure(TomlParseError(.IoError, "Cannot read file", 0, 0, 0), config), config);
		return ReadBytes(Span<uint8>(data.Ptr, data.Count), config);
	}

	/// @brief Write this document to a file. Convenience wrapper around Write().
	/// @param path File path to write to. Overwrites existing files.
	/// @return .Ok on success, or .Err if the write failed.
	public Result<void, TomlParseError> WriteFile(StringView path)
	{
		return WriteFile(path, WriteConfig);
	}

	/// @brief Write this document to a file with an explicit configuration.
	/// @param path File path to write to. Overwrites existing files.
	/// @param config Write options.
	/// @return .Ok on success, or .Err if the write failed.
	public Result<void, TomlParseError> WriteFile(StringView path, TomlWriteConfig config)
	{
		String output = scope String();
		Write(output, config);
		if (File.WriteAllText(path, output) case .Err)
		{
			var error = TomlParseError(.IoError, "Cannot write file", 0, 0, 0);
			error.SetSource(path);
			return .Err(error);
		}
		return .Ok;
	}
}
