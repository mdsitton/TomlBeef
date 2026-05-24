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
		Runtime.Assert(month >= 1 && month <= 12);
		Runtime.Assert(day >= 1 && day <= 31);
		Runtime.Assert(hour >= 0 && hour <= 23);
		Runtime.Assert(minute >= 0 && minute <= 59);
		Runtime.Assert(second >= 0 && second <= 60);
		Runtime.Assert(nanosecond >= 0 && nanosecond <= 999999999);
		Runtime.Assert(offsetMinutes >= -1439 && offsetMinutes <= 1439);
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
		Runtime.Assert(month >= 1 && month <= 12);
		Runtime.Assert(day >= 1 && day <= 31);
		Runtime.Assert(hour >= 0 && hour <= 23);
		Runtime.Assert(minute >= 0 && minute <= 59);
		Runtime.Assert(second >= 0 && second <= 60);
		Runtime.Assert(nanosecond >= 0 && nanosecond <= 999999999);
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
public struct TomlLocalDate
{
	public int32 mYear;
	public int32 mMonth;
	public int32 mDay;

	public this(int32 year, int32 month, int32 day)
	{
		Runtime.Assert(month >= 1 && month <= 12);
		Runtime.Assert(day >= 1 && day <= 31);
		mYear = year;
		mMonth = month;
		mDay = day;
	}
}

/// Local Time: time of day without date or timezone.
public struct TomlLocalTime
{
	public int32 mHour;
	public int32 mMinute;
	public int32 mSecond;
	public int64 mNanosecond;

	public this(int32 hour, int32 minute, int32 second, int64 nanosecond)
	{
		Runtime.Assert(hour >= 0 && hour <= 23);
		Runtime.Assert(minute >= 0 && minute <= 59);
		Runtime.Assert(second >= 0 && second <= 60);
		Runtime.Assert(nanosecond >= 0 && nanosecond <= 999999999);
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
	}
}
