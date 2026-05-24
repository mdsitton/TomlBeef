using System;

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

	/// Disposes any heap-allocated payload (String, TomlArray, TomlTable).
	public void Dispose()
	{
		switch (this)
		{
		case .String(let s):
			if (s != null) delete s;
		case .Array(let arr):
			if (arr != null) delete arr;
		case .Table(let tbl):
			if (tbl != null) delete tbl;
		default:
		}
	}

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

	public TomlValue Clone()
	{
		switch (this)
		{
		case .String(let s):      return .String(new String(s));
		case .Integer(let v):     return .Integer(v);
		case .Float(let v):       return .Float(v);
		case .Bool(let v):        return .Bool(v);
		case .OffsetDateTime(let v): return .OffsetDateTime(v);
		case .LocalDateTime(let v):  return .LocalDateTime(v);
		case .LocalDate(let v):      return .LocalDate(v);
		case .LocalTime(let v):      return .LocalTime(v);
		case .Array(let arr):     return .Array(arr.Clone());
		case .Table(let tbl):     return .Table(tbl.Clone());
		}
	}
}
