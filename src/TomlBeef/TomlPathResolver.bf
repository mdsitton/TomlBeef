using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// Navigates the TOML table tree, handles implicit table creation,
/// and enforces conflict detection rules.
class TomlPathResolver
{
	private TomlTable mRootTable;
	private TomlTable mCurrentTable;
	private TomlDocumentMetadata mMetadata;
	private TomlDocumentStore mStore;

	internal this(TomlTable rootTable, TomlDocumentMetadata metadata, TomlDocumentStore store)
	{
		mRootTable = rootTable;
		mCurrentTable = rootTable;
		mMetadata = metadata;
		mStore = store;
	}

	public int mCurrentLine = 1;
	public int mCurrentColumn = 1;
	public int mCurrentOffset = 0;

	private TomlParseError MakeError(TomlErrorKind kind, StringView message, int offset, int length = 1)
	{
		return TomlParseError(kind, message, mCurrentLine, mCurrentColumn, offset, length);
	}

	// ========================================================================
	// Public entry points
	// ========================================================================

	public Result<void, TomlParseError> EnterTable(List<String> path)
	{
		return EnterTable(path, null);
	}

	/// @brief Enter a table header, optionally returning the allocated node ID.
	/// @param path The key path for the table header.
	/// @param outNodeId Receives the allocated node ID, or null if not needed.
	/// @return .Ok on success, or .Err on conflict.
	public Result<void, TomlParseError> EnterTable(List<String> path, TomlNodeId* outNodeId)
	{
		mCurrentTable = mRootTable;

		if (path.Count == 0)
			return .Ok;

		for (int i = 0; i < path.Count - 1; i++)
		{
			switch (NavigateSegment(path[i], true, .ImplicitHeaderSuper))
			{
			case .Err(let err): return .Err(err);
			default:
			}
		}

		return DefineTable(path[path.Count - 1], .ExplicitHeader, outNodeId);
	}

	public Result<void, TomlParseError> EnterArrayOfTables(List<String> path)
	{
		return EnterArrayOfTables(path, null);
	}

	/// @brief Enter an array-of-tables header, optionally returning the allocated node ID.
	/// @param path The key path for the array-of-tables header.
	/// @param outNodeId Receives the allocated node ID, or null if not needed.
	/// @return .Ok on success, or .Err on conflict.
	public Result<void, TomlParseError> EnterArrayOfTables(List<String> path, TomlNodeId* outNodeId)
	{
		mCurrentTable = mRootTable;

		if (path.Count == 0)
			return .Err(MakeError(.UnexpectedToken, "Empty array-of-tables header", mCurrentOffset));

		for (int i = 0; i < path.Count - 1; i++)
		{
			switch (NavigateSegment(path[i], true, .ImplicitHeaderSuper))
			{
			case .Err(let err): return .Err(err);
			default:
			}
		}

		return DefineArrayOfTables(path[path.Count - 1], outNodeId);
	}

	public Result<void, TomlParseError> SetKeyValue(List<String> keyPath, TomlValue value)
	{
		return SetKeyValue(keyPath, value, null);
	}

	/// SetKeyValue overload that allocates a node ID when metadata is present.
	/// @param outNodeId Receives the allocated node ID, or remains default if metadata is null.
	public Result<void, TomlParseError> SetKeyValue(List<String> keyPath, TomlValue value, TomlNodeId* outNodeId)
	{
		if (keyPath.Count == 0)
			return .Err(MakeError(.EmptyBareKey, "Empty key", mCurrentOffset));

		TomlTable savedTable = mCurrentTable;

		for (int i = 0; i < keyPath.Count - 1; i++)
		{
			switch (NavigateSegment(keyPath[i], true, .Implicit))
			{
			case .Err(let err):
				mCurrentTable = savedTable;
				return .Err(err);
			default:
			}
		}

		StringView finalKey = keyPath[keyPath.Count - 1];
		switch (InsertKeyValue(finalKey, value, outNodeId))
		{
		case .Err(let err):
			mCurrentTable = savedTable;
			return .Err(err);
		default:
		}

		mCurrentTable = savedTable;
		return .Ok;
	}

	// ========================================================================
	// Internal navigation
	// ========================================================================

	/// Navigates to a key segment, optionally creating an implicit table.
	/// @param key The segment name.
	/// @param create If true, create an implicit table of the given origin when the key doesn't exist.
	/// @param implicitOrigin The origin to use when creating an implicit table.
	private Result<void, TomlParseError> NavigateSegment(StringView key, bool create, TomlTableOrigin implicitOrigin)
	{
		if (mCurrentTable.TryGetValue(key, let existing))
		{
			TomlTable existingTable = null; if (existing case .Table(ref existingTable))
			{
				// Bug 2 fix: don't cross into ExplicitHeader tables from dotted-key implicit scope.
				if (implicitOrigin == .Implicit && existingTable.Origin == .ExplicitHeader)
					return .Err(MakeError(.TypeConflict, scope $"Key '{key}' references a table defined by a [table] header - cannot extend with dotted keys" , mCurrentOffset));

				mCurrentTable = existingTable;
				return .Ok;
			}
			else if (existing case .Array(let arr))
			{
				// Only header navigation can traverse into array-of-tables.
				if (implicitOrigin == .Implicit)
					return .Err(MakeError(.TypeConflict, scope $"Cannot use dotted key to access elements of array-of-tables '{key}'" , mCurrentOffset));

				if (arr.Count == 0)
					return .Err(MakeError(.ArrayElementOrdering,
						"Cannot access child of empty array-of-tables; define an [[array]] element first", mCurrentOffset));
				TomlValue lastVal = arr.GetValue(arr.Count - 1);
				TomlTable lastTable = null; if (lastVal case .Table(ref lastTable))
					mCurrentTable = lastTable;
				else
					return .Err(MakeError(.TypeConflict, "Expected table in array-of-tables element", mCurrentOffset));
				return .Ok;
			}
			else
			{
				String msg = scope String();
				msg.AppendF("Cannot use key '{}' as table — it is a ", key);
				ValueTypeName(existing, msg);
				return .Err(MakeError(.TypeConflict, msg, mCurrentOffset));
			}
		}

		if (create)
		{
			if (mCurrentTable.IsInlineSealed)
				return .Err(MakeError(.InlineTableSealed, "Cannot add keys to a sealed inline table", mCurrentOffset));

			TomlTable newTable = 
				mStore.NewTable(implicitOrigin, true);
			TomlValue tableVal = TomlValue.Table(newTable);
			mCurrentTable.Insert(key, tableVal);
			mCurrentTable = newTable;
			return .Ok;
		}

		return .Err(MakeError(.TypeConflict, scope $"Table key '{key}' does not exist" , mCurrentOffset));
	}

	/// Defines a table at the given key in the current table, or navigates into
	/// an existing table after conflict checks.
	private Result<void, TomlParseError> DefineTable(StringView key, TomlTableOrigin origin, TomlNodeId* outNodeId = null)
	{
		if (mCurrentTable.TryGetValue(key, let existing))
		{
			TomlTable existingTable = null; if (existing case .Table(ref existingTable))
			{
				// Only duplicate ExplicitHeader→ExplicitHeader is an error.
				if (origin == .ExplicitHeader && existingTable.Origin == .ExplicitHeader)
					return .Err(MakeError(.DuplicateTable, scope $"Duplicate table '[{key}]'" , mCurrentOffset));

				// Bug 1 fix: Implicit (from dotted key) cannot be redefined with explicit header.
				if (existingTable.Origin == .Implicit)
					return .Err(MakeError(.DuplicateTable, scope $"Cannot redefine implicit table '{key}' with explicit header" , mCurrentOffset));

				// Inline tables are sealed.
				if (existingTable.Origin == .InlineTable)
					return .Err(MakeError(.DuplicateTable, scope $"Cannot redefine inline table '{key}'" , mCurrentOffset));

				// Cannot enter a sealed inline table for header definition
				if (existingTable.IsInlineSealed)
					return .Err(MakeError(.InlineTableSealed, "Cannot add sub-table to sealed inline table", mCurrentOffset));

				// Upgrade ImplicitHeaderSuper to ExplicitHeader on explicit definition
				if (origin == .ExplicitHeader && existingTable.Origin == .ImplicitHeaderSuper)
				{
					existingTable.Origin = .ExplicitHeader;
				}

				mCurrentTable = existingTable;
				// Allocate node ID for existing table if requested
				if (mMetadata != null && outNodeId != null)
				{
					let nodeId = mMetadata.AllocateNodeId();
					*outNodeId = nodeId;
					let ctx = EnsureTableContext(existingTable);
					if (ctx != null)
						ctx.mNodeId = nodeId;
				}
				return .Ok;
			}
			else if (existing case .Array(let arr))
			{
				return .Err(MakeError(.TypeConflict, scope $"Cannot define table '{key}' - name already used as array-of-tables" , mCurrentOffset));
			}
			else
			{
				String msg = scope String();
				msg.AppendF("Cannot define table '{}' — name already used as ", key);
				ValueTypeName(existing, msg);
				return .Err(MakeError(.TypeConflict, msg, mCurrentOffset));
			}
		}

		// Cannot add sub-tables to sealed inline tables
		if (mCurrentTable.IsInlineSealed)
			return .Err(MakeError(.InlineTableSealed, "Cannot add sub-table to sealed inline table", mCurrentOffset));

		TomlTable newTable = 
			mStore.NewTable(origin, true);
		TomlValue tableVal = TomlValue.Table(newTable);
		mCurrentTable.Insert(key, tableVal);
		mCurrentTable = newTable;

		// Allocate node ID for new table if requested
		if (mMetadata != null && outNodeId != null)
		{
			let nodeId = mMetadata.AllocateNodeId();
			*outNodeId = nodeId;
			let ctx = EnsureTableContext(newTable);
			if (ctx != null)
				ctx.mNodeId = nodeId;
		}

		return .Ok;
	}

	private Result<void, TomlParseError> DefineArrayOfTables(StringView key, TomlNodeId* outNodeId = null)
	{
		if (mCurrentTable.TryGetValue(key, let existing))
		{
			TomlArray arr = null; if (existing case .Array(ref arr))
			{

				// Reject append to static array
				if (arr.IsStatic)
					return .Err(MakeError(.AppendToStaticArray, scope $"Cannot define array-of-tables '[[{key}]]' - name already defined as a static array" , mCurrentOffset));

				TomlTable newElement = 
				mStore.NewTable(.ArrayElement, true);
				arr.Add(TomlValue.Table(newElement));
				mCurrentTable = newElement;

				// Allocate node ID for new array element if requested
				if (mMetadata != null && outNodeId != null)
				{
					let nodeId = mMetadata.AllocateNodeId();
					*outNodeId = nodeId;
					let ctx = EnsureTableContext(newElement);
					if (ctx != null)
						ctx.mNodeId = nodeId;
				}

				return .Ok;
			}
			else if (existing case .Table)
			{
				return .Err(MakeError(.TypeConflict, scope $"Cannot define array-of-tables '[[{key}]]' - name already used as table" , mCurrentOffset));
			}
			else
			{
				String msg = scope String();
				msg.AppendF("Cannot define array-of-tables '[[{}]]' — name already defined as ", key);
				ValueTypeName(existing, msg);
				return .Err(MakeError(.AppendToStaticArray, msg, mCurrentOffset));
			}
		}

		TomlArray newArray = 
			mStore.NewArray(true);
		TomlTable firstElement = 
			mStore.NewTable(.ArrayElement, true);
		newArray.Add(.Table(firstElement));
		mCurrentTable.Insert(key, TomlValue.Array(newArray));
		mCurrentTable = firstElement;

		// Allocate node ID for first array element if requested
		if (mMetadata != null && outNodeId != null)
		{
			let nodeId = mMetadata.AllocateNodeId();
			*outNodeId = nodeId;
			let ctx = EnsureTableContext(firstElement);
			if (ctx != null)
				ctx.mNodeId = nodeId;
		}

		return .Ok;
	}

	private Result<void, TomlParseError> InsertKeyValue(StringView key, TomlValue value, TomlNodeId* outNodeId)
	{
		if (mCurrentTable.TryGetValue(key, let existing))
			return .Err(MakeError(.DuplicateKey, scope $"Duplicate key '{key}'" , mCurrentOffset));

		if (mCurrentTable.IsInlineSealed)
			return .Err(MakeError(.InlineTableSealed, "Cannot add keys to a sealed inline table", mCurrentOffset));

		if (mMetadata != null && outNodeId != null)
		{
			let nodeId = mMetadata.AllocateNodeId();
			*outNodeId = nodeId;

			// Ensure current table has a metadata context
			let ctx = EnsureTableContext(mCurrentTable);
			if (ctx != null)
				ctx.SetEntryNodeId(key, nodeId);
		}

		mCurrentTable.Insert(key, value);
		return .Ok;
	}

	/// Ensure a table has a metadata context allocated, if metadata is active.
	private TomlContainerMetadataContext EnsureTableContext(TomlTable table)
	{
		if (mMetadata == null)
			return null;
		if (table.MetadataContext != null)
			return table.MetadataContext;
		let ctx = new TomlContainerMetadataContext(mMetadata, .Invalid, false);
		table.MetadataContext = ctx;
		return ctx;
	}

	public void Reset()
	{
		mCurrentTable = mRootTable;
	}

	private void ValueTypeName(TomlValue value, String outStr)
	{
		switch (value)
		{
		case .String:       outStr.Append("string");
		case .Integer:      outStr.Append("integer");
		case .Float:        outStr.Append("float");
		case .Bool:         outStr.Append("boolean");
		case .OffsetDateTime: outStr.Append("offset datetime");
		case .LocalDateTime:  outStr.Append("local datetime");
		case .LocalDate:      outStr.Append("local date");
		case .LocalTime:      outStr.Append("local time");
		case .Array:        outStr.Append("array");
		case .Table:        outStr.Append("table");
		default:            outStr.Append("unknown");
		}
	}
}
