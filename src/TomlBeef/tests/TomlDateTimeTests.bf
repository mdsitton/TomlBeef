using System;
using TomlBeef;

namespace TomlBeef;

/// Date/time validation: the Create factories, and the same rules in the parser.
static class TomlDateTimeTests
{
	static void AssertInvalid<T>(Result<T, TomlParseError> result, TomlErrorKind kind, StringView message)
	{
		switch (result)
		{
		case .Ok:
			Test.Assert(false, scope $"expected {kind}: {message}");
		case .Err(let e):
			Test.Assert(e.mKind == kind && e.mMessage == message, scope $"expected {kind} '{message}', got {e.mKind} '{e.mMessage}'");
		}
	}

	[Test]
	public static void Create_ChecksRealMonthLengthsAndLeapYears()
	{
		Test.Assert(TomlLocalDate.Create(2024, 2, 29) case .Ok(let leapDay) && leapDay.mDay == 29);
		Test.Assert(TomlLocalDate.Create(2000, 2, 29) case .Ok, "divisible by 400 is a leap year");
		AssertInvalid(TomlLocalDate.Create(2023, 2, 29), .InvalidDate, "Invalid date: day 29 is outside 1-28 for 2023-02");
		AssertInvalid(TomlLocalDate.Create(1900, 2, 29), .InvalidDate, "Invalid date: day 29 is outside 1-28 for 1900-02");
		AssertInvalid(TomlLocalDate.Create(2024, 2, 31), .InvalidDate, "Invalid date: day 31 is outside 1-29 for 2024-02");
		AssertInvalid(TomlLocalDate.Create(2024, 4, 31), .InvalidDate, "Invalid date: day 31 is outside 1-30 for 2024-04");
		Test.Assert(TomlLocalDate.Create(2024, 12, 31) case .Ok);
		AssertInvalid(TomlLocalDate.Create(2024, 13, 1), .InvalidDate, "Invalid date: month 13 is outside 1-12");
		AssertInvalid(TomlLocalDate.Create(2024, 1, 0), .InvalidDate, "Invalid date: day 0 is outside 1-31 for 2024-01");
		// Four-digit years only: anything else would be written as invalid TOML
		Test.Assert(TomlLocalDate.Create(0, 1, 1) case .Ok);
		AssertInvalid(TomlLocalDate.Create(10000, 1, 1), .InvalidDate, "Invalid date: year 10000 is outside 0-9999");
		AssertInvalid(TomlLocalDate.Create(-1, 1, 1), .InvalidDate, "Invalid date: year -1 is outside 0-9999");
	}

	[Test]
	public static void Create_ChecksTimesAndOffsets()
	{
		Test.Assert(TomlLocalTime.Create(23, 59, 60, 999999999) case .Ok, "a leap second is allowed");
		AssertInvalid(TomlLocalTime.Create(24, 0, 0, 0), .InvalidTime, "Invalid time: hour 24 is outside 0-23");
		AssertInvalid(TomlLocalTime.Create(12, 60, 0, 0), .InvalidTime, "Invalid time: minute 60 is outside 0-59");
		AssertInvalid(TomlLocalTime.Create(12, 0, 61, 0), .InvalidTime, "Invalid time: second 61 is outside 0-60");
		AssertInvalid(TomlLocalTime.Create(12, 0, 0, 1000000000), .InvalidTime, "Invalid time: nanosecond 1000000000 is outside 0-999999999");

		Test.Assert(TomlLocalDateTime.Create(2024, 2, 29, 12, 30, 0, 0) case .Ok);
		AssertInvalid(TomlLocalDateTime.Create(2023, 2, 29, 12, 30, 0, 0), .InvalidDate, "Invalid date: day 29 is outside 1-28 for 2023-02");
		AssertInvalid(TomlLocalDateTime.Create(2024, 2, 29, 25, 0, 0, 0), .InvalidTime, "Invalid time: hour 25 is outside 0-23");

		Test.Assert(TomlOffsetDateTime.Create(2024, 5, 1, 8, 0, 0, 0, -1439) case .Ok(let odt) && odt.mOffsetMinutes == -1439);
		AssertInvalid(TomlOffsetDateTime.Create(2024, 5, 1, 8, 0, 0, 0, 1440), .InvalidDateTime, "Invalid UTC offset: 1440 minutes is outside ±1439");
		AssertInvalid(TomlOffsetDateTime.Create(2024, 4, 31, 8, 0, 0, 0, 0), .InvalidDate, "Invalid date: day 31 is outside 1-30 for 2024-04");
	}

	[Test]
	public static void Created_ValuesRoundTripThroughTheDocument()
	{
		var doc = scope TomlDocument();
		Test.Assert(TomlLocalDate.Create(2024, 2, 29) case .Ok(let date));
		Test.Assert(TomlOffsetDateTime.Create(1999, 12, 31, 23, 59, 60, 5000000, 330) case .Ok(let stamp));
		doc.RootTable.Set("date", date);
		doc.RootTable.Set("stamp", stamp);
		let text = doc.Write(.. scope String());
		var reread = scope TomlDocument();
		Test.Assert(reread.Read(text) case .Ok, text);
		Test.Assert(reread.TryGetLocalDate("date", let d) && d == date, text);
		Test.Assert(reread.TryGetOffsetDateTime("stamp", let s) && s == stamp, text);

		// The parser applies the same rules
		Test.Assert(reread.Read("d = 2023-02-29") case .Err(let bad) && bad.mKind == .InvalidDate);
		Test.Assert(reread.Read("d = 2024-02-29") case .Ok);
	}
}
