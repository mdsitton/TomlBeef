using System;

namespace TomlBeef;

/// Offset Date-Time: date + time + UTC offset.
/// Corresponds to TOML's offset-date-time type.
public struct TomlOffsetDateTime
{
	public int32 mYear;
	public int32 mMonth;
	public int32 mDay;
	public int32 mHour;
	public int32 mMinute;
	public int32 mSecond;
	public int64 mNanosecond;     // Fractional seconds in nanoseconds (0-999999999)
	public int32 mOffsetMinutes;  // UTC offset in minutes (e.g., Z = 0, +05:30 = 330)

	public this(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int64 nanosecond,
		int32 offsetMinutes)
	{
		mYear = year;
		mMonth = month;
		mDay = day;
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
		mOffsetMinutes = offsetMinutes;
	}
}

/// Local Date-Time: date + time without timezone info.
/// Corresponds to TOML's local-date-time type.
public struct TomlLocalDateTime
{
	public int32 mYear;
	public int32 mMonth;
	public int32 mDay;
	public int32 mHour;
	public int32 mMinute;
	public int32 mSecond;
	public int64 mNanosecond;

	public this(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int64 nanosecond)
	{
		mYear = year;
		mMonth = month;
		mDay = day;
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
	}
}

/// Local Date: date only (year-month-day).
/// Corresponds to TOML's local-date type.
public struct TomlLocalDate
{
	public int32 mYear;
	public int32 mMonth;
	public int32 mDay;

	public this(int32 year, int32 month, int32 day)
	{
		mYear = year;
		mMonth = month;
		mDay = day;
	}
}

/// Local Time: time of day without date or timezone.
/// Corresponds to TOML's local-time type.
public struct TomlLocalTime
{
	public int32 mHour;
	public int32 mMinute;
	public int32 mSecond;
	public int64 mNanosecond;

	public this(int32 hour, int32 minute, int32 second, int64 nanosecond)
	{
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
	}
}
