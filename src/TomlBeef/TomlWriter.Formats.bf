using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlWriterImpl: regenerating numbers and date/times from captured formats (PreserveStyle).
extension TomlWriterImpl
{
	/// Write an integer value using format metadata for style preservation.
	private static void WriteIntegerWithFormat(int64 val, TomlIntegerFormat fmt, String outStr)
	{
		if (fmt.mBase == .Decimal && !fmt.mUseUnderscores)
		{
			val.ToString(outStr);
			return;
		}

		bool negative = val < 0;
		// Negative values can't be hex/octal/binary per TOML spec.
		if (negative && fmt.mBase != .Decimal)
		{
			val.ToString(outStr);
			return;
		}

		uint64 uval = negative ? (uint64)(-(val + 1)) + 1 : (uint64)val;
		if (fmt.mBase == .Decimal)
		{
			if (negative)
				outStr.Append('-');
			String digits = scope String();
			uval.ToString(digits);
			int groupSize = fmt.mGroupSize > 0 ? fmt.mGroupSize : 3;
			EmitGroupedDigits(digits, outStr, groupSize, false);
			return;
		}

		String rawDigits = scope String();
		char8 prefix = '\0';

		switch (fmt.mBase)
		{
		case .Hex:
			prefix = 'x';
			// Convert to hex manually
			if (uval == 0)
				rawDigits.Append('0');
			else
			{
				while (uval > 0)
				{
					uint8 d = (uint8)(uval & 0xF);
					rawDigits.Insert(0, (char8)(d < 10 ? '0' + d : (fmt.mUppercaseDigits ? 'A' : 'a') + d - 10));
					uval >>= 4;
				}
			}
		case .Octal:
			prefix = 'o';
			if (uval == 0)
				rawDigits.Append('0');
			else
			{
				while (uval > 0)
				{
					rawDigits.Insert(0, (char8)('0' + (uval & 7)));
					uval >>= 3;
				}
			}
		case .Binary:
			prefix = 'b';
			if (uval == 0)
				rawDigits.Append('0');
			else
			{
				while (uval > 0)
				{
					rawDigits.Insert(0, (char8)('0' + (uval & 1)));
					uval >>= 1;
				}
			}
		default:
		}

		while (fmt.mMinDigits > rawDigits.Length)
			rawDigits.Insert(0, '0');

		outStr.Append('0');
		outStr.Append(prefix);

		if (fmt.mUseUnderscores && fmt.mGroupSize > 0)
			EmitGroupedDigits(rawDigits, outStr, fmt.mGroupSize, false);
		else
			outStr.Append(rawDigits);
	}

	/// Write a float value using format metadata for style preservation.
	/// Appends zeros to the fraction of the number written from `start` until it has `digits` fraction
	/// digits (adding a '.' if needed). Leaves exponent forms alone.
	private static void PadFractionDigits(String outStr, int start, int digits)
	{
		int dot = -1;
		for (int i = start; i < outStr.Length; i++)
		{
			char8 c = outStr[i];
			if (c == 'e' || c == 'E')
				return;
			if (c == '.')
				dot = i;
		}
		if (dot < 0)
		{
			dot = outStr.Length;
			outStr.Append('.');
		}
		for (int fraction = outStr.Length - dot - 1; fraction < digits; fraction++)
			outStr.Append('0');
	}

	private static void WriteFloatWithFormat(double val, TomlFloatFormat fmt, String outStr)
	{
		// Special values — use captured sign style
		if (val.IsInfinity)
		{
			// Infinity sign is semantic; only preserve explicit plus for positive infinity.
			if (val < 0)
				outStr.Append("-inf");
			else if (fmt.mSpecialSign == .ExplicitPlus)
				outStr.Append("+inf");
			else
				outStr.Append("inf");
			return;
		}
		if (val.IsNaN)
		{
			if (fmt.mSpecialSign == .ExplicitPlus)
				outStr.Append("+nan");
			else if (fmt.mSpecialSign == .Minus)
				outStr.Append("-nan");
			else
				outStr.Append("nan");
			return;
		}

		if (fmt.mStyle == .Decimal)
		{
			// IEEE 754: preserve negative zero sign
			if (val == 0.0 && (1.0 / val) < 0.0)
			{
				outStr.Append("-0.0");
				return;
			}
			int before = outStr.Length;
			// Start from the exact round-trip form, then only pad fraction zeros up to the captured
			// precision ("5.50" stays "5.50"). Never round to it: fixed-point "F<n>" formatting keeps
			// only ~15 significant digits and would change the value (3.141592653589793 → ...790).
			val.ToString(outStr, "R", null);
			if (fmt.mPrecision > 0)
				PadFractionDigits(outStr, before, fmt.mPrecision);
			// Apply underscore grouping to decimal floats
			if (fmt.mUseUnderscores && (fmt.mIntGroupSize > 0 || fmt.mFracGroupSize > 0))
			{
				String pre = scope String(outStr.Substring(before));
				outStr.Remove(before, outStr.Length - before);
				ApplyFloatUnderscoreGrouping(pre, fmt, outStr);
			}
			else
			{
				// Ensure unambiguously a float
				bool hasDot = false;
				for (int fi = before; fi < outStr.Length; fi++)
				{
					char8 fc = outStr[fi];
					if (fc == '.' || fc == 'e' || fc == 'E') { hasDot = true; break; }
				}
				if (!hasDot) outStr.Append(".0");
			}
			return;
		}

		// Scientific notation.
		// Do NOT use fmt.mPrecision for the format string — it controls significant digits
		// and would round the value to match the original source's precision instead of
		// preserving the actual numeric value. Use a roundtrip format and let
		// ReformatExponent handle only the exponent style (case, sign, digit width).
		if (fmt.mStyle == .Scientific)
		{
			if (val == 0.0 && (1.0 / val) < 0.0)
			{
				outStr.Append("-0.0");
				return;
			}
			// Choose the exponent character for case preservation; roundtrip precision for value fidelity.
			String format = scope String();
			format.Append(fmt.mUppercaseExponent ? 'E' : 'e');
			String formatted = scope String();
			val.ToString(formatted, format, null);
			ReformatExponent(formatted, fmt, outStr);
			return;
		}

		// Fallback
		val.ToString(outStr, "R", null);
	}

	/// Reformat a scientific notation string to match captured exponent style.
	/// Handles uppercase/lowercase E, explicit plus sign, exponent digit width,
	/// and strips unnecessary trailing zeros from the mantissa.
	private static void ReformatExponent(StringView formatted, TomlFloatFormat fmt, String outStr)
	{
		// Find the exponent marker
		int expPos = -1;
		for (int i = 0; i < formatted.Length; i++)
		{
			if (formatted[i] == 'e' || formatted[i] == 'E')
			{
				expPos = i;
				break;
			}
		}
		if (expPos < 0)
		{
			outStr.Append(formatted);
			return;
		}

		// Strip trailing zeros from mantissa (e.g. 2.000000 → 2, 2.500000 → 2.5)
		int mantissaEnd = expPos - 1;
		while (mantissaEnd > 0 && formatted[mantissaEnd] == '0')
			mantissaEnd--;
		if (mantissaEnd > 0 && formatted[mantissaEnd] == '.')
			mantissaEnd--; // remove trailing dot too
		outStr.Append(StringView(&formatted[0], mantissaEnd + 1));

		// Emit exponent marker with captured case
		outStr.Append(fmt.mUppercaseExponent ? 'E' : 'e');

		// Parse exponent sign and digits
		int expStart = expPos + 1;
		char8 signChar = '\0';
		if (expStart < formatted.Length && (formatted[expStart] == '+' || formatted[expStart] == '-'))
		{
			signChar = formatted[expStart];
			expStart++;
		}

		// Collect exponent digits
		String expDigits = scope String();
		while (expStart < formatted.Length && TomlChar.IsDigit(formatted[expStart]))
		{
			expDigits.Append(formatted[expStart]);
			expStart++;
		}

		// Emit sign
		if (signChar == '-')
		{
			outStr.Append('-');
		}
		else if (fmt.mExplicitPlusExponent)
		{
			outStr.Append('+');
		}

		// Pad or trim exponent digits to match captured width. Without one (a format set in code), use
		// the minimal width: 1.5e3, not the formatter's 1.5e003.
		int width = (fmt.mExponentDigits > 0) ? fmt.mExponentDigits : 1;
		while (expDigits.Length < width)
			expDigits.Insert(0, '0');
		// Trim excess leading zeros (safe: they don't change the value)
		while (expDigits.Length > width && expDigits[0] == '0')
			expDigits.Remove(0, 1);

		outStr.Append(expDigits);
	}

	/// Reinsert underscores into a decimal float string according to captured grouping.
	private static void ApplyFloatUnderscoreGrouping(StringView number, TomlFloatFormat fmt, String outStr)
	{
		if (!fmt.mUseUnderscores)
		{
			outStr.Append(number);
			return;
		}

		// Detect sign prefix
		int start = 0;
		if (start < number.Length && (number[start] == '-' || number[start] == '+'))
		{
			outStr.Append(number[start]);
			start++;
		}

		// Find dot and exponent positions
		int dotPos = -1;
		int ePos = -1;
		for (int i = start; i < number.Length; i++)
		{
			if (number[i] == '.') dotPos = i;
			if (number[i] == 'e' || number[i] == 'E') { ePos = i; break; }
		}

		// Integer part: from start to dot (or end)
		int intEnd = (dotPos >= 0) ? dotPos : ((ePos >= 0) ? ePos : number.Length);
		StringView intPart = StringView(&number[start], intEnd - start);

		if (fmt.mIntGroupSize > 0 && fmt.mIntGroupSize < intPart.Length)
			EmitGroupedDigitsFromRight(intPart, outStr, fmt.mIntGroupSize);
		else
			outStr.Append(intPart);

		// Fractional part and optional exponent
		if (dotPos >= 0 || ePos >= 0)
		{
			if (dotPos >= 0)
			{
				outStr.Append('.');
				int fracEnd = (ePos >= 0) ? ePos : number.Length;
				StringView fracPart = StringView(&number[dotPos + 1], fracEnd - (dotPos + 1));
				if (fmt.mFracGroupSize > 0 && fmt.mFracGroupSize < fracPart.Length)
					EmitGroupedDigitsFromLeft(fracPart, outStr, fmt.mFracGroupSize);
				else
					outStr.Append(fracPart);
			}
			if (ePos >= 0)
			{
				// Append exponent as-is (already handled by scientific path)
				outStr.Append(StringView(&number[ePos], number.Length - ePos));
			}
		}
	}

	/// Emit digits grouped with underscores from the right (for integer parts, e.g., 224_617).
	private static void EmitGroupedDigitsFromRight(StringView digits, String outStr, int groupSize)
	{
		if (groupSize <= 0 || digits.Length <= groupSize)
		{
			outStr.Append(digits);
			return;
		}
		int firstChunk = digits.Length % groupSize;
		if (firstChunk == 0) firstChunk = groupSize;
		outStr.Append(StringView(&digits[0], firstChunk));
		int pos = firstChunk;
		while (pos < digits.Length)
		{
			outStr.Append('_');
			outStr.Append(StringView(&digits[pos], groupSize));
			pos += groupSize;
		}
	}

	/// Emit digits grouped with underscores from the left (for fractional parts, e.g., 445_991).
	private static void EmitGroupedDigitsFromLeft(StringView digits, String outStr, int groupSize)
	{
		if (groupSize <= 0 || digits.Length <= groupSize)
		{
			outStr.Append(digits);
			return;
		}
		int pos = 0;
		while (pos < digits.Length)
		{
			if (pos > 0) outStr.Append('_');
			int remaining = digits.Length - pos;
			int chunk = (remaining > groupSize) ? groupSize : remaining;
			outStr.Append(StringView(&digits[pos], chunk));
			pos += chunk;
		}
	}

	/// The captured date-time separator, or 'T' if none valid was captured.
	private static char8 DateTimeSeparator(TomlDateTimeFormat fmt)
	{
		return (fmt.mSeparator == 't' || fmt.mSeparator == ' ') ? fmt.mSeparator : 'T';
	}

	/// Write a date-time value using format metadata for style preservation.
	private static void WriteDateTimeWithFormat(TomlValue val, TomlDateTimeFormat fmt, String outStr, TomlVersion version)
	{
		if (val.IsOffsetDateTime)
		{
			let dt = val.AsOffsetDateTime;
			FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
			outStr.Append(DateTimeSeparator(fmt));
			FormatTimeWithFormat(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, fmt, version, outStr);
			if (dt.mOffsetMinutes == 0 && fmt.mUsesZ)
				outStr.Append(fmt.mLowercaseZ ? 'z' : 'Z');
			else
			{
				int32 absOff = dt.mOffsetMinutes;
				if (absOff < 0) { outStr.Append('-'); absOff = -absOff; }
				else outStr.Append('+');
				Pad2(absOff / 60, outStr);
				outStr.Append(':');
				Pad2(absOff % 60, outStr);
			}
			return;
		}
		if (val.IsLocalDateTime)
		{
			let dt = val.AsLocalDateTime;
			FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
			outStr.Append(DateTimeSeparator(fmt));
			FormatTimeWithFormat(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, fmt, version, outStr);
			return;
		}
		if (val.IsLocalDate)
		{
			WriteLocalDate(val.AsLocalDate, outStr);
			return;
		}
		if (val.IsLocalTime)
		{
			let t = val.AsLocalTime;
			FormatTimeWithFormat(t.mHour, t.mMinute, t.mSecond, t.mNanosecond, fmt, version, outStr);
			return;
		}
		WriteValue(val, outStr, version);
	}

	/// Write a time component using captured seconds/fraction precision where it is safe to do so.
	private static void FormatTimeWithFormat(int32 h, int32 min, int32 s, int64 ns, TomlDateTimeFormat fmt, TomlVersion version, String outStr)
	{
		Pad2(h, outStr);
		outStr.Append(':');
		Pad2(min, outStr);

		bool includeSeconds = version == .V1_0 || fmt.mHasSeconds || fmt.mFractionalDigits > 0 || s != 0 || ns != 0;
		if (!includeSeconds)
			return;

		outStr.Append(':');
		Pad2(s, outStr);

		int digitsToEmit = fmt.mFractionalDigits;
		if (ns > 0 || digitsToEmit > 0)
		{
			String nsStr = scope String();
			ns.ToString(nsStr);
			while (nsStr.Length < 9) nsStr.Insert(0, '0');

			int significantDigits = 9;
			while (significantDigits > 0 && nsStr[significantDigits - 1] == '0')
				significantDigits--;
			if (digitsToEmit < significantDigits)
				digitsToEmit = significantDigits;
			if (digitsToEmit > 9)
				digitsToEmit = 9;

			if (digitsToEmit > 0)
			{
				outStr.Append('.');
				outStr.Append(StringView(&nsStr[0], digitsToEmit));
			}
		}
	}

	/// Write digits with optional underscore grouping from the right (e.g., 1_000_000 or DEAD_BEEF).
	private static void EmitGroupedDigits(StringView digits, String outStr, int groupSize, bool leftToRight)
	{
		if (groupSize <= 0 || digits.Length <= groupSize)
		{
			outStr.Append(digits);
			return;
		}
		int firstChunk = digits.Length % groupSize;
		if (firstChunk == 0) firstChunk = groupSize;
		outStr.Append(StringView(&digits[0], firstChunk));
		int pos = firstChunk;
		while (pos < digits.Length)
		{
			outStr.Append('_');
			outStr.Append(StringView(&digits[pos], groupSize));
			pos += groupSize;
		}
	}
}
