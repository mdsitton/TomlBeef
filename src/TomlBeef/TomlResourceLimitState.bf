namespace TomlBeef;

using System;

/// @brief Shared resource limit state for parser and path resolver.
/// Owned by the parser, passed to the resolver to enforce document-level limits.
internal class TomlResourceLimitState
{
	public int mMaxDepth;
	public int mMaxInputBytes;
	public int mMaxStringBytes;
	public int mMaxArrayItems;
	public int mMaxTableEntries;
	public int mMaxPathSegments;
	public int mMaxNodes;

	public int mNodeCount;

	/// @brief Create from a read configuration.
	public this(TomlReadConfig config)
	{
		mMaxDepth = config.MaxDepth > 0 ? config.MaxDepth : int.MaxValue;
		mMaxInputBytes = config.MaxInputBytes;
		mMaxStringBytes = config.MaxStringBytes;
		mMaxArrayItems = config.MaxArrayItems;
		mMaxTableEntries = config.MaxTableEntries;
		mMaxPathSegments = config.MaxPathSegments;
		mMaxNodes = config.MaxNodes;
		mNodeCount = 0;
	}

	public Result<void, TomlParseError> CheckDepth(int depth, int line, int column, int offset)
	{
		if (depth >= mMaxDepth)
			return .Err(TomlParseError(.MaxDepthExceeded, "Maximum nesting depth exceeded", line, column, offset));
		return .Ok;
	}

	public Result<void, TomlParseError> CheckStringBytes(int byteLength, int line, int column, int offset)
	{
		if (mMaxStringBytes > 0 && byteLength > mMaxStringBytes)
			return .Err(TomlParseError(.ResourceLimitExceeded,
				scope $"String length {byteLength} exceeds maximum {mMaxStringBytes}", line, column, offset));
		return .Ok;
	}

	public Result<void, TomlParseError> CheckTableEntry(TomlTable table, int line, int column, int offset)
	{
		if (mMaxTableEntries > 0 && table.Count >= mMaxTableEntries)
			return .Err(TomlParseError(.ResourceLimitExceeded,
				scope $"Table entry count exceeds maximum {mMaxTableEntries}", line, column, offset));
		return .Ok;
	}

	public Result<void, TomlParseError> CheckArrayItem(TomlArray array, int line, int column, int offset)
	{
		if (mMaxArrayItems > 0 && array.Count >= mMaxArrayItems)
			return .Err(TomlParseError(.ResourceLimitExceeded,
				scope $"Array item count exceeds maximum {mMaxArrayItems}", line, column, offset));
		return .Ok;
	}

	public Result<void, TomlParseError> CheckPathSegments(int count, int line, int column, int offset)
	{
		if (mMaxPathSegments > 0 && count > mMaxPathSegments)
			return .Err(TomlParseError(.ResourceLimitExceeded,
				scope $"Path segment count {count} exceeds maximum {mMaxPathSegments}", line, column, offset));
		return .Ok;
	}

	public Result<void, TomlParseError> CheckNodeCount(int line, int column, int offset)
	{
		if (mMaxNodes > 0)
		{
			mNodeCount++;
			if (mNodeCount > mMaxNodes)
				return .Err(TomlParseError(.ResourceLimitExceeded,
					scope $"Node count exceeds maximum {mMaxNodes}", line, column, offset));
		}
		return .Ok;
	}
}
