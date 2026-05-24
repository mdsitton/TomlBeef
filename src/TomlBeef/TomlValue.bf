using System;

namespace TomlBeef;

/// The type tag for a TomlValue.
public enum TomlValueType : uint8
{
	String,
	Integer,
	Float,
	Bool,
	OffsetDateTime,
	LocalDateTime,
	LocalDate,
	LocalTime,
	Array,
	Table
}

/// Origin of a TOML table, used for conflict detection during parsing.
public enum TomlTableOrigin : uint8
{
	Root,
	Implicit,              // Created by dotted key resolution (e.g., fruit.apple in fruit.apple.color)
	ImplicitHeaderSuper,   // Created as super-path of a header (e.g., x in [x.y.z])
	ExplicitHeader,
	InlineTable,
	ArrayElement
}

/// A TOML value — a tagged union supporting all TOML types.
/// Struct-based with manual disposal of heap-allocated data.
public struct TomlValue
{
	public TomlValueType mType;

	public String mStringVal;
	public int64 mIntVal;
	public double mFloatVal;
	public bool mBoolVal;
	public TomlOffsetDateTime mOffsetDtVal;
	public TomlLocalDateTime mLocalDtVal;
	public TomlLocalDate mDateVal;
	public TomlLocalTime mTimeVal;
	public TomlArray mArrayVal;
	public TomlTable mTableVal;

	public static TomlValue FromString(StringView s)
	{
		TomlValue v = default;
		v.mType = .String;
		v.mStringVal = new String(s);
		return v;
	}

	public static TomlValue FromInteger(int64 val)
	{
		TomlValue v = default;
		v.mType = .Integer;
		v.mIntVal = val;
		return v;
	}

	public static TomlValue FromFloat(double val)
	{
		TomlValue v = default;
		v.mType = .Float;
		v.mFloatVal = val;
		return v;
	}

	public static TomlValue FromBool(bool val)
	{
		TomlValue v = default;
		v.mType = .Bool;
		v.mBoolVal = val;
		return v;
	}

	public static TomlValue FromOffsetDateTime(TomlOffsetDateTime val)
	{
		TomlValue v = default;
		v.mType = .OffsetDateTime;
		v.mOffsetDtVal = val;
		return v;
	}

	public static TomlValue FromLocalDateTime(TomlLocalDateTime val)
	{
		TomlValue v = default;
		v.mType = .LocalDateTime;
		v.mLocalDtVal = val;
		return v;
	}

	public static TomlValue FromLocalDate(TomlLocalDate val)
	{
		TomlValue v = default;
		v.mType = .LocalDate;
		v.mDateVal = val;
		return v;
	}

	public static TomlValue FromLocalTime(TomlLocalTime val)
	{
		TomlValue v = default;
		v.mType = .LocalTime;
		v.mTimeVal = val;
		return v;
	}

	public static TomlValue FromArray(TomlArray arr)
	{
		TomlValue v = default;
		v.mType = .Array;
		v.mArrayVal = arr;
		return v;
	}

	public static TomlValue FromTable(TomlTable tbl)
	{
		TomlValue v = default;
		v.mType = .Table;
		v.mTableVal = tbl;
		return v;
	}

	public bool IsString => mType == .String;
	public bool IsInteger => mType == .Integer;
	public bool IsFloat => mType == .Float;
	public bool IsBool => mType == .Bool;
	public bool IsOffsetDateTime => mType == .OffsetDateTime;
	public bool IsLocalDateTime => mType == .LocalDateTime;
	public bool IsLocalDate => mType == .LocalDate;
	public bool IsLocalTime => mType == .LocalTime;
	public bool IsArray => mType == .Array;
	public bool IsTable => mType == .Table;

	public void Dispose()
	{
		switch (mType)
		{
		case .String:
			if (mStringVal != null)
				delete mStringVal;
			return;
		case .Array:
			if (mArrayVal != null)
				delete mArrayVal;
			return;
		case .Table:
			if (mTableVal != null)
				delete mTableVal;
			return;
		default:
			return;
		}
	}

	public StringView AsString
	{
		get
		{
			Runtime.Assert(mType == .String, "TomlValue is not a String");
			return StringView(mStringVal);
		}
	}

	public int64 AsInteger
	{
		get { return mIntVal; }
	}

	public double AsFloat
	{
		get { return mFloatVal; }
	}

	public bool AsBool
	{
		get { return mBoolVal; }
	}

	public TomlOffsetDateTime AsOffsetDateTime
	{
		get { return mOffsetDtVal; }
	}

	public TomlLocalDateTime AsLocalDateTime
	{
		get { return mLocalDtVal; }
	}

	public TomlLocalDate AsLocalDate
	{
		get { return mDateVal; }
	}

	public TomlLocalTime AsLocalTime
	{
		get { return mTimeVal; }
	}

	public TomlArray AsArray
	{
		get { return mArrayVal; }
	}

	public TomlTable AsTable
	{
		get { return mTableVal; }
	}
}
