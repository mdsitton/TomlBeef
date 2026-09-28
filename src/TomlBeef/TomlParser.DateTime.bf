using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlParserImpl: offset/local date-time, date, and time parsing.
extension TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	// ================================================================
	// Date/Time parsing
	// ================================================================

	private static bool LooksLikeDateTime(StringView token)
	{
		// Date pattern: starts with YYYY-
		if (token.Length >= 5 &&
			TomlChar.IsDigit(token[0]) && TomlChar.IsDigit(token[1]) &&
			TomlChar.IsDigit(token[2]) && TomlChar.IsDigit(token[3]) &&
			token[4] == '-')
			return true;

		for (int i = 0; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == 'T' || c == 't' || c == ':' || c == 'Z' || c == 'z')
				return true;
		}
		return false;
	}

	private Result<TomlValue, TomlParseError> TryParseDateTime(StringView token)
	{
		bool hasT = false;
		bool hasColon = false;
		bool hasZ = false;
		bool hasDash = false;

		for (int i = 0; i < token.Length; i++)
		{
			char8 c = token[i];
			if (c == 'T' || c == 't' || c == ' ') hasT = true;
			if (c == ':') hasColon = true;
			if (c == 'Z' || c == 'z') hasZ = true;
			if (c == '-') hasDash = true;
		}

		// If token has Z or ends with offset pattern, it must be offset datetime
		bool hasOffsetIndicator = hasZ;
		if (!hasOffsetIndicator)
		{
			// Check for +/- timezone offset (look after the last time digit for + or -)
			for (int i = token.Length - 1; i >= 0; i--)
			{
				if (token[i] == '+' || token[i] == '-')
				{
					if (i > 10) { hasOffsetIndicator = true; break; }
				}
			}
		}

		if (hasT || hasZ)
		{
			if (hasOffsetIndicator)
				return TryParseOffsetDateTime(token);
			return TryParseLocalDateTime(token);
		}
		if (!hasColon && !hasT && hasDash)
			return TryParseLocalDate(token);
		if (hasColon && !hasT && !hasDash)
			return TryParseLocalTime(token);

		// Should not reach here — LooksLikeDateTime already filtered non-dates
		return .Err(Error(.UnexpectedToken, "Cannot parse date/time"));
	}

	private Result<TomlValue, TomlParseError> TryParseOffsetDateTime(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDateTime, "Invalid date in datetime"));

		if (pos >= token.Length) return .Err(Error(.InvalidDateTime, "Missing time part"));
		char8 sep = token[pos];
		if (sep == 'T' || sep == 't' || sep == ' ') pos++;
		else return .Err(Error(.InvalidDateTime, "Expected date-time separator"));

		int32 hour = ?; int32 minute = ?; int32 second = 0; int32 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time in datetime"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));

		int32 offsetMinutes = 0;
		if (pos >= token.Length)
			return .Err(Error(.InvalidDateTime, "Expected timezone offset"));
		{
			char8 tz = token[pos];
			if (tz == 'Z' || tz == 'z') { pos++; offsetMinutes = 0; }
			else if (tz == '+' || tz == '-')
			{
				pos++;
				int32 tzh = 0, tzm = 0;
				if (!TryReadNDigits(token, ref pos, 2, out tzh))
					return .Err(Error(.InvalidDateTime, "Invalid timezone offset hours"));
				if (tzh > 23)
					return .Err(Error(.InvalidDateTime, "Timezone offset hour overflow"));
				// The ':' separator is required for timezone offset
				if (pos >= token.Length || token[pos] != ':')
					return .Err(Error(.InvalidDateTime, "Expected ':' in timezone offset"));
				pos++;
				if (!TryReadNDigits(token, ref pos, 2, out tzm))
					return .Err(Error(.InvalidDateTime, "Invalid timezone offset minutes"));
				if (tzm > 59)
					return .Err(Error(.InvalidDateTime, "Timezone offset minute overflow"));
				offsetMinutes = tzh * 60 + tzm;
				if (tz == '-') offsetMinutes = -offsetMinutes;
			}
			else { return .Err(Error(.InvalidDateTime, "Expected timezone offset")); }
		}

		if (pos != token.Length)
			return .Err(Error(.InvalidDateTime, "Trailing characters after offset date-time"));
		return TomlValue.OffsetDateTime(TomlOffsetDateTime(year, month, day, hour, minute, second, ns, offsetMinutes));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalDateTime(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDateTime, "Invalid date"));

		if (pos >= token.Length) return .Err(Error(.InvalidDateTime, "Missing time part"));
		char8 sep = token[pos];
		if (sep == 'T' || sep == 't' || sep == ' ') pos++;
		else return .Err(Error(.InvalidDateTime, "Expected date-time separator"));

		int32 hour = ?; int32 minute = ?; int32 second = 0; int32 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));

		if (pos != token.Length)
			return .Err(Error(.InvalidDateTime, "Trailing characters after local date-time"));
		return TomlValue.LocalDateTime(TomlLocalDateTime(year, month, day, hour, minute, second, ns));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalDate(StringView token)
	{
		int pos = 0;
		int32 year = ?; int32 month = ?; int32 day = ?;
		if (!ParseDatePart(token, ref pos, out year, out month, out day))
			return .Err(Error(.InvalidDate, "Invalid date"));
		if (pos != token.Length) return .Err(Error(.InvalidDate, "Trailing characters in date"));
		return TomlValue.LocalDate(TomlLocalDate(year, month, day));
	}

	private Result<TomlValue, TomlParseError> TryParseLocalTime(StringView token)
	{
		int pos = 0;
		int32 hour = ?; int32 minute = ?; int32 second = 0; int32 ns = 0;
		bool secondsOmitted = false;
		if (!ParseTimePart(token, ref pos, out hour, out minute, out second, out ns, out secondsOmitted))
			return .Err(Error(.InvalidTime, "Invalid time"));
		if (mVersion == .V1_0 && secondsOmitted)
			return .Err(Error(.InvalidTime, "Seconds are required in TOML v1.0"));
		if (pos != token.Length) return .Err(Error(.InvalidTime, "Trailing characters in time"));
		return TomlValue.LocalTime(TomlLocalTime(hour, minute, second, ns));
	}

	private bool ParseDatePart(StringView token, ref int pos, out int32 year, out int32 month, out int32 day)
	{
		year = 0; month = 0; day = 0;
		if (!TryReadNDigits(token, ref pos, 4, out year)) return false;
		if (pos >= token.Length || token[pos] != '-') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out month)) return false;
		if (month < 1 || month > 12) return false;
		if (pos >= token.Length || token[pos] != '-') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out day)) return false;
		if (day < 1 || day > 31) return false;
		// Basic month/day validation
		if (month == 2)
		{
			bool leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
			int32 maxDay = leap ? 29 : 28;
			if (day > maxDay) return false;
		}
		else if (month == 4 || month == 6 || month == 9 || month == 11)
		{
			if (day > 30) return false;
		}
		return true;
	}

	private bool ParseTimePart(StringView token, ref int pos,
		out int32 hour, out int32 minute, out int32 second, out int32 nanosecond,
		out bool secondsOmitted)
	{
		hour = 0; minute = 0; second = 0; nanosecond = 0;
		secondsOmitted = true;
		if (!TryReadNDigits(token, ref pos, 2, out hour)) return false;
		if (hour > 23) return false;
		if (pos >= token.Length || token[pos] != ':') return false;
		pos++;
		if (!TryReadNDigits(token, ref pos, 2, out minute)) return false;
		if (minute > 59) return false;

		if (pos < token.Length && token[pos] == ':')
		{
			secondsOmitted = false;
			pos++;
			if (!TryReadNDigits(token, ref pos, 2, out second)) return false;
			if (second > 60) return false; // 60 for leap seconds

			if (pos < token.Length && token[pos] == '.')
			{
				pos++;
				int fracStart = pos;
				while (pos < token.Length && TomlChar.IsDigit(token[pos]))
					pos++;
				int fracLen = pos - fracStart;
				if (fracLen == 0)
				{
					return false; // trailing dot with no fractional digits
				}
				else
				{
					String fracStr = scope String(token.Substring(fracStart, fracLen));
					while (fracStr.Length < 9) fracStr.Append('0');
					if (fracStr.Length > 9) fracStr.Remove(9, fracStr.Length - 9);
					// At most 9 digits, so the value fits int32
					nanosecond = 0;
					for (int i = 0; i < fracStr.Length; i++)
						nanosecond = nanosecond * 10 + (int32)(fracStr[i] - '0');
				}
			}
		}
		return true;
	}

	private bool TryReadNDigits(StringView token, ref int pos, int n, out int32 value)
	{
		value = 0;
		if (pos + n > token.Length) return false;
		for (int i = 0; i < n; i++)
		{
			char8 c = token[pos + i];
			if (c < '0' || c > '9') return false;
			value = value * 10 + (c - '0');
		}
		pos += n;
		return true;
	}
}
