using System;
using internal TomlBeef;

namespace TomlBeef;

/// Origin of a TOML table, used for conflict detection during parsing.
public enum TomlTableOrigin : uint8
{
	Root,
	Implicit,
	ImplicitHeaderSuper,
	ExplicitHeader,
	InlineTable,
	ArrayElement
}

/// A TOML value — a tagged union supporting all TOML types.
public enum TomlValue
{
	case String(String s);
	case Integer(int64 v);
	case Float(double v);
	case Bool(bool v);
	case OffsetDateTime(TomlOffsetDateTime v);
	case LocalDateTime(TomlLocalDateTime v);
	case LocalDate(TomlLocalDate v);
	case LocalTime(TomlLocalTime v);
	case Array(TomlArray arr);
	case Table(TomlTable tbl);

	public bool IsString         => this case .String;
	public bool IsInteger        => this case .Integer;
	public bool IsFloat          => this case .Float;
	public bool IsBool           => this case .Bool;
	public bool IsOffsetDateTime => this case .OffsetDateTime;
	public bool IsLocalDateTime  => this case .LocalDateTime;
	public bool IsLocalDate      => this case .LocalDate;
	public bool IsLocalTime      => this case .LocalTime;
	public bool IsArray          => this case .Array;
	public bool IsTable          => this case .Table;

	public StringView AsString
	{
		get
		{
			if (this case .String(let s))
				return StringView(s);
			Runtime.FatalError("TomlValue is not a String");
		}
	}

	public int64 AsInteger
	{
		get
		{
			if (this case .Integer(let v))
				return v;
			Runtime.FatalError("TomlValue is not an Integer");
		}
	}

	public double AsFloat
	{
		get
		{
			if (this case .Float(let v))
				return v;
			Runtime.FatalError("TomlValue is not a Float");
		}
	}

	public bool AsBool
	{
		get
		{
			if (this case .Bool(let v))
				return v;
			Runtime.FatalError("TomlValue is not a Bool");
		}
	}

	public TomlOffsetDateTime AsOffsetDateTime
	{
		get
		{
			if (this case .OffsetDateTime(let v))
				return v;
			Runtime.FatalError("TomlValue is not an OffsetDateTime");
		}
	}

	public TomlLocalDateTime AsLocalDateTime
	{
		get
		{
			if (this case .LocalDateTime(let v))
				return v;
			Runtime.FatalError("TomlValue is not a LocalDateTime");
		}
	}

	public TomlLocalDate AsLocalDate
	{
		get
		{
			if (this case .LocalDate(let v))
				return v;
			Runtime.FatalError("TomlValue is not a LocalDate");
		}
	}

	public TomlLocalTime AsLocalTime
	{
		get
		{
			if (this case .LocalTime(let v))
				return v;
			Runtime.FatalError("TomlValue is not a LocalTime");
		}
	}

	public TomlArray AsArray
	{
		get
		{
			if (this case .Array(let arr))
				return arr;
			Runtime.FatalError("TomlValue is not an Array");
		}
	}

	public TomlTable AsTable
	{
		get
		{
			if (this case .Table(let tbl))
				return tbl;
			Runtime.FatalError("TomlValue is not a Table");
		}
	}

	public Result<StringView> TryGetString()
	{
		if (this case .String(let s))
			return StringView(s);
		return .Err;
	}

	public Result<int64> TryGetInteger()
	{
		if (this case .Integer(let v))
			return v;
		return .Err;
	}

	public Result<double> TryGetFloat()
	{
		if (this case .Float(let v))
			return v;
		return .Err;
	}

	public Result<bool> TryGetBool()
	{
		if (this case .Bool(let v))
			return v;
		return .Err;
	}

	public Result<TomlOffsetDateTime> TryGetOffsetDateTime()
	{
		if (this case .OffsetDateTime(let v))
			return v;
		return .Err;
	}

	public Result<TomlLocalDateTime> TryGetLocalDateTime()
	{
		if (this case .LocalDateTime(let v))
			return v;
		return .Err;
	}

	public Result<TomlLocalDate> TryGetLocalDate()
	{
		if (this case .LocalDate(let v))
			return v;
		return .Err;
	}

	public Result<TomlLocalTime> TryGetLocalTime()
	{
		if (this case .LocalTime(let v))
			return v;
		return .Err;
	}

	public Result<TomlArray> TryGetArray()
	{
		if (this case .Array(let arr))
			return arr;
		return .Err;
	}

	public Result<TomlTable> TryGetTable()
	{
		if (this case .Table(let tbl))
			return tbl;
		return .Err;
	}

	/// @brief Try to extract a String value, returning false if the type doesn't match.
	/// @param value On success, the string value.
	/// @return True if this TomlValue is a String.
	public bool TryGetString(out StringView value)
	{
		if (this case .String(let s))
		{
			value = StringView(s);
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract an Integer value, returning false if the type doesn't match.
	/// @param value On success, the integer value.
	/// @return True if this TomlValue is an Integer.
	public bool TryGetInteger(out int64 value)
	{
		if (this case .Integer(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a Float value, returning false if the type doesn't match.
	/// @param value On success, the float value.
	/// @return True if this TomlValue is a Float.
	public bool TryGetFloat(out double value)
	{
		if (this case .Float(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a Bool value, returning false if the type doesn't match.
	/// @param value On success, the boolean value.
	/// @return True if this TomlValue is a Bool.
	public bool TryGetBool(out bool value)
	{
		if (this case .Bool(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract an OffsetDateTime value, returning false if the type doesn't match.
	/// @param value On success, the offset date-time value.
	/// @return True if this TomlValue is an OffsetDateTime.
	public bool TryGetOffsetDateTime(out TomlOffsetDateTime value)
	{
		if (this case .OffsetDateTime(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a LocalDateTime value, returning false if the type doesn't match.
	/// @param value On success, the local date-time value.
	/// @return True if this TomlValue is a LocalDateTime.
	public bool TryGetLocalDateTime(out TomlLocalDateTime value)
	{
		if (this case .LocalDateTime(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a LocalDate value, returning false if the type doesn't match.
	/// @param value On success, the local date value.
	/// @return True if this TomlValue is a LocalDate.
	public bool TryGetLocalDate(out TomlLocalDate value)
	{
		if (this case .LocalDate(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a LocalTime value, returning false if the type doesn't match.
	/// @param value On success, the local time value.
	/// @return True if this TomlValue is a LocalTime.
	public bool TryGetLocalTime(out TomlLocalTime value)
	{
		if (this case .LocalTime(let v))
		{
			value = v;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract an Array value, returning false if the type doesn't match.
	/// @param value On success, the array value.
	/// @return True if this TomlValue is an Array.
	public bool TryGetArray(out TomlArray value)
	{
		if (this case .Array(let arr))
		{
			value = arr;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Try to extract a Table value, returning false if the type doesn't match.
	/// @param value On success, the table value.
	/// @return True if this TomlValue is a Table.
	public bool TryGetTable(out TomlTable value)
	{
		if (this case .Table(let tbl))
		{
			value = tbl;
			return true;
		}
		value = default;
		return false;
	}

	/// @brief Deep-copy this value into the given store.
	internal TomlValue CloneInto(TomlDocumentStore store)
	{
		switch (this)
		{
		case .String(let s):      return .String(store.NewString(s));
		case .Integer(let v):     return .Integer(v);
		case .Float(let v):       return .Float(v);
		case .Bool(let v):        return .Bool(v);
		case .OffsetDateTime(let v): return .OffsetDateTime(v);
		case .LocalDateTime(let v):  return .LocalDateTime(v);
		case .LocalDate(let v):      return .LocalDate(v);
		case .LocalTime(let v):      return .LocalTime(v);
		case .Array(let arr):     return .Array(arr.CloneInto(store));
		case .Table(let tbl):     return .Table(tbl.CloneInto(store));
		}
	}

	/// Semantic equality used by mutation dirty tracking.
	/// Scalar values compare by value; arrays and tables compare by identity to avoid treating
	/// replacement containers as unchanged when their ownership and metadata contexts differ.
	internal bool IsSemanticallyEqualTo(TomlValue other)
	{
		switch (this)
		{
		case .String(let sa):
			return other case .String(let sb) && sa == sb;
		case .Integer(let ia):
			return other case .Integer(let ib) && ia == ib;
		case .Float(let fa):
			if (other case .Float(let fb))
			{
				if (fa.IsNaN && fb.IsNaN) return true;
				return fa == fb;
			}
			return false;
		case .Bool(let ba):
			return other case .Bool(let bb) && ba == bb;
		case .OffsetDateTime(let da):
			return other case .OffsetDateTime(let db) && da == db;
		case .LocalDateTime(let da):
			return other case .LocalDateTime(let db) && da == db;
		case .LocalDate(let da):
			return other case .LocalDate(let db) && da == db;
		case .LocalTime(let da):
			return other case .LocalTime(let db) && da == db;
		case .Array(let aa):
			return other case .Array(let ab) && aa === ab;
		case .Table(let ta):
			return other case .Table(let tb) && ta === tb;
		}
	}
}
