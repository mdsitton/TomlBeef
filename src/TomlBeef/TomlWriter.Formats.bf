using System;
using System.Collections;
using FormatCore;
using internal FormatCore;
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

		// FormatCore's IntegerText: the base, digit case, minimum digits and underscore grouping
		IntegerLayout layout = .();
		switch (fmt.mBase)
		{
		case .Hex: layout.mBase = .Hex;
		case .Octal: layout.mBase = .Octal;
		case .Binary: layout.mBase = .Binary;
		default: layout.mBase = .Decimal;
		}
		if (layout.mBase == .Decimal)
		{
			// Decimal is written with underscores only (a plain one took the path above), in groups of 3
			// unless another size was captured
			layout.mGroupSize = fmt.mGroupSize > 0 ? fmt.mGroupSize : 3;
		}
		else
		{
			layout.mPrefix = true;
			layout.mUppercase = fmt.mUppercaseDigits;
			layout.mMinDigits = fmt.mMinDigits;
			if (fmt.mUseUnderscores)
				layout.mGroupSize = fmt.mGroupSize;
		}
		IntegerText.Append(outStr, val, layout);
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

		// Scientific notation: the shortest round-trip digits as d[.ddd]e±x, never fmt.mPrecision (that
		// would round the value), with the captured exponent style (case, sign, digit width; without a
		// width, the fewest digits: 1.5e3)
		if (fmt.mStyle == .Scientific)
		{
			if (val == 0.0 && (1.0 / val) < 0.0)
			{
				outStr.Append("-0.0");
				return;
			}
			ShortestDouble.Append(outStr, val, FloatLayout.Scientific(fmt.mUppercaseExponent, fmt.mExplicitPlusExponent, fmt.mExponentDigits));
			return;
		}

		// Fallback
		val.ToString(outStr, "R", null);
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
			IntegerText.AppendGrouped(outStr, intPart, fmt.mIntGroupSize);
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
					IntegerText.AppendGrouped(outStr, fracPart, fmt.mFracGroupSize, true);
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
}
