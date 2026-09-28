using System;
using internal TomlBeef;

namespace TomlBeef;

/// Date/time validity rules shared by the parser, the date/time constructors and their Create factories.
/// TOML dates are RFC 3339 dates: four-digit years (0000-9999), real month lengths (leap years for
/// February), times up to 23:59:60 (a leap second), nanosecond fractions and offsets within ±23:59.
internal static class TomlDateRules
{
	public static bool IsLeapYear(int32 year)
	{
		return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
	}

	public static int32 DaysInMonth(int32 year, int32 month)
	{
		switch (month)
		{
		case 2: return IsLeapYear(year) ? 29 : 28;
		case 4, 6, 9, 11: return 30;
		default: return 31;
		}
	}

	public static bool IsValidDate(int32 year, int32 month, int32 day)
	{
		return year >= 0 && year <= 9999 && month >= 1 && month <= 12 && day >= 1 && day <= DaysInMonth(year, month);
	}

	public static bool IsValidTime(int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59 && second >= 0 && second <= 60 &&
			nanosecond >= 0 && nanosecond <= 999999999;
	}

	public static bool IsValidOffset(int32 offsetMinutes)
	{
		return offsetMinutes >= -1439 && offsetMinutes <= 1439;
	}

	/// The first rule a date breaks, as an InvalidDate error.
	public static Result<void, TomlParseError> CheckDate(int32 year, int32 month, int32 day)
	{
		if (year < 0 || year > 9999)
			return .Err(TomlParseError(.InvalidDate, scope $"Invalid date: year {year} is outside 0-9999", 0, 0, 0));
		if (month < 1 || month > 12)
			return .Err(TomlParseError(.InvalidDate, scope $"Invalid date: month {month} is outside 1-12", 0, 0, 0));
		int32 maxDay = DaysInMonth(year, month);
		if (day < 1 || day > maxDay)
			return .Err(TomlParseError(.InvalidDate, scope $"Invalid date: day {day} is outside 1-{maxDay} for {year:0000}-{month:00}", 0, 0, 0));
		return .Ok;
	}

	/// The first rule a time breaks, as an InvalidTime error.
	public static Result<void, TomlParseError> CheckTime(int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		if (hour < 0 || hour > 23)
			return .Err(TomlParseError(.InvalidTime, scope $"Invalid time: hour {hour} is outside 0-23", 0, 0, 0));
		if (minute < 0 || minute > 59)
			return .Err(TomlParseError(.InvalidTime, scope $"Invalid time: minute {minute} is outside 0-59", 0, 0, 0));
		if (second < 0 || second > 60)
			return .Err(TomlParseError(.InvalidTime, scope $"Invalid time: second {second} is outside 0-60", 0, 0, 0));
		if (nanosecond < 0 || nanosecond > 999999999)
			return .Err(TomlParseError(.InvalidTime, scope $"Invalid time: nanosecond {nanosecond} is outside 0-999999999", 0, 0, 0));
		return .Ok;
	}

	/// An InvalidDateTime error unless the offset is within ±23:59.
	public static Result<void, TomlParseError> CheckOffset(int32 offsetMinutes)
	{
		if (!IsValidOffset(offsetMinutes))
			return .Err(TomlParseError(.InvalidDateTime, scope $"Invalid UTC offset: {offsetMinutes} minutes is outside ±1439", 0, 0, 0));
		return .Ok;
	}
}

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
	// int32 is enough for 0-999999999 and keeps this struct (TomlValue's largest payload) at 32 bytes
	public int32 mNanosecond; // Fractional seconds in nanoseconds (0-999999999)
	public int32 mOffsetMinutes; // UTC offset in minutes (e.g., Z = 0, +05:30 = 330)

	/// @brief Construct from components that are known to be valid; an invalid date, time or offset is a
	/// fatal error. Use Create for values from untrusted input.
	public this(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int32 nanosecond,
		int32 offsetMinutes)
	{
		Runtime.Assert(TomlDateRules.IsValidDate(year, month, day), "Invalid date");
		Runtime.Assert(TomlDateRules.IsValidTime(hour, minute, second, nanosecond), "Invalid time");
		Runtime.Assert(TomlDateRules.IsValidOffset(offsetMinutes), "Invalid UTC offset");
		mYear = year;
		mMonth = month;
		mDay = day;
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
		mOffsetMinutes = offsetMinutes;
	}

	/// @brief Validate and construct, e.g. from user input: years 0-9999, real month lengths (leap
	/// years), times up to 23:59:60, offsets within ±23:59 (±1439 minutes).
	/// @param year Year, 0-9999.
	/// @param month Month, 1-12.
	/// @param day Day of the month.
	/// @param hour Hour, 0-23.
	/// @param minute Minute, 0-59.
	/// @param second Second, 0-60 (60 is a leap second).
	/// @param nanosecond Fraction of the second, 0-999999999.
	/// @param offsetMinutes UTC offset in minutes (0 is Z).
	/// @return The value, or an InvalidDate/InvalidTime/InvalidDateTime error naming the broken rule.
	public static Result<TomlOffsetDateTime, TomlParseError> Create(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int32 nanosecond, int32 offsetMinutes)
	{
		Try!(TomlDateRules.CheckDate(year, month, day));
		Try!(TomlDateRules.CheckTime(hour, minute, second, nanosecond));
		Try!(TomlDateRules.CheckOffset(offsetMinutes));
		return TomlOffsetDateTime(year, month, day, hour, minute, second, nanosecond, offsetMinutes);
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
	public int32 mNanosecond;

	/// @brief Construct from components that are known to be valid; an invalid date or time is a fatal
	/// error. Use Create for values from untrusted input.
	public this(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		Runtime.Assert(TomlDateRules.IsValidDate(year, month, day), "Invalid date");
		Runtime.Assert(TomlDateRules.IsValidTime(hour, minute, second, nanosecond), "Invalid time");
		mYear = year;
		mMonth = month;
		mDay = day;
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
	}

	/// @brief Validate and construct; see TomlOffsetDateTime.Create for the rules.
	/// @param year Year, 0-9999.
	/// @param month Month, 1-12.
	/// @param day Day of the month.
	/// @param hour Hour, 0-23.
	/// @param minute Minute, 0-59.
	/// @param second Second, 0-60.
	/// @param nanosecond Fraction of the second, 0-999999999.
	/// @return The value, or an InvalidDate/InvalidTime error naming the broken rule.
	public static Result<TomlLocalDateTime, TomlParseError> Create(int32 year, int32 month, int32 day,
		int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		Try!(TomlDateRules.CheckDate(year, month, day));
		Try!(TomlDateRules.CheckTime(hour, minute, second, nanosecond));
		return TomlLocalDateTime(year, month, day, hour, minute, second, nanosecond);
	}
}

/// Local Date: date only (year-month-day).
public struct TomlLocalDate
{
	public int32 mYear;
	public int32 mMonth;
	public int32 mDay;

	/// @brief Construct from components that are known to be valid; an invalid date is a fatal error.
	/// Use Create for values from untrusted input.
	public this(int32 year, int32 month, int32 day)
	{
		Runtime.Assert(TomlDateRules.IsValidDate(year, month, day), "Invalid date");
		mYear = year;
		mMonth = month;
		mDay = day;
	}

	/// @brief Validate and construct: years 0-9999 and real month lengths (leap years for February).
	/// @param year Year, 0-9999.
	/// @param month Month, 1-12.
	/// @param day Day of the month.
	/// @return The date, or an InvalidDate error naming the broken rule.
	public static Result<TomlLocalDate, TomlParseError> Create(int32 year, int32 month, int32 day)
	{
		Try!(TomlDateRules.CheckDate(year, month, day));
		return TomlLocalDate(year, month, day);
	}
}

/// Local Time: time of day without date or timezone.
public struct TomlLocalTime
{
	public int32 mHour;
	public int32 mMinute;
	public int32 mSecond;
	public int32 mNanosecond;

	/// @brief Construct from components that are known to be valid; an invalid time is a fatal error.
	/// Use Create for values from untrusted input.
	public this(int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		Runtime.Assert(TomlDateRules.IsValidTime(hour, minute, second, nanosecond), "Invalid time");
		mHour = hour;
		mMinute = minute;
		mSecond = second;
		mNanosecond = nanosecond;
	}

	/// @brief Validate and construct: times up to 23:59:60 with a nanosecond fraction.
	/// @param hour Hour, 0-23.
	/// @param minute Minute, 0-59.
	/// @param second Second, 0-60 (60 is a leap second).
	/// @param nanosecond Fraction of the second, 0-999999999.
	/// @return The time, or an InvalidTime error naming the broken rule.
	public static Result<TomlLocalTime, TomlParseError> Create(int32 hour, int32 minute, int32 second, int32 nanosecond)
	{
		Try!(TomlDateRules.CheckTime(hour, minute, second, nanosecond));
		return TomlLocalTime(hour, minute, second, nanosecond);
	}
}
