using System;
using System.Collections;

namespace TomlBeef;

/// Serializes a TOML document to tagged JSON format for toml-test compliance.
public class TomlSerializer
{
	public void Serialize(TomlDocument doc, String outStr)
	{
		SerializeTable(doc.mRootTable, outStr);
	}

	private void SerializeTable(TomlTable tbl, String outStr)
	{
		outStr.Append('{');

		if (tbl == null)
		{
			outStr.Append('}');
			return;
		}

		int count = tbl.KeyOrder.Count;
		for (int i = 0; i < count; i++)
		{
			String key = tbl.KeyOrder[i];
			if (i > 0) outStr.Append(',');

			WriteString(key, outStr);
			outStr.Append(':');

			TomlValue val = tbl.Entries[key];
			SerializeValue(val, outStr);
		}

		outStr.Append('}');
	}

	private void SerializeValue(TomlValue val, String outStr)
	{
		switch (val)
		{
		case .String(let s):           WriteTagged("string", s, outStr);
		case .Integer(let i):          WriteTagged("integer", i, outStr);
		case .Float(let f):            WriteTaggedFloat("float", f, outStr);
		case .Bool(let b):             WriteTagged("bool", b ? "true" : "false", outStr);
		case .OffsetDateTime(let dt):  WriteTaggedDateTime("datetime", dt, outStr);
		case .LocalDateTime(let dt):   WriteTaggedLocalDateTime("datetime-local", dt, outStr);
		case .LocalDate(let d):        WriteTaggedLocalDate("date-local", d, outStr);
		case .LocalTime(let t):        WriteTaggedLocalTime("time-local", t, outStr);
		case .Array(let arr):          SerializeArray(arr, outStr);
		case .Table(let tbl):          SerializeTable(tbl, outStr);
		}
	}

	private void WriteTagged(StringView type, StringView value, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		EscapeString(value, outStr);
		outStr.Append("\"}");
	}

	private void WriteTagged(StringView type, int64 value, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		value.ToString(outStr);
		outStr.Append("\"}");
	}

	private void WriteTaggedFloat(StringView type, double value, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");

		if (value.IsInfinity)
		{
			if (value > 0) outStr.Append("inf");
			else outStr.Append("-inf");
		}
		else if (value.IsNaN)
		{
			outStr.Append("nan");
		}
		else
		{
			value.ToString(outStr, "R", null);
		}

		outStr.Append("\"}");
	}

	private void WriteTaggedDateTime(StringView type, TomlOffsetDateTime dt, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		FormatOffsetDateTime(dt, outStr);
		outStr.Append("\"}");
	}

	private void WriteTaggedLocalDateTime(StringView type, TomlLocalDateTime dt, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		FormatLocalDateTime(dt, outStr);
		outStr.Append("\"}");
	}

	private void WriteTaggedLocalDate(StringView type, TomlLocalDate d, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		FormatLocalDate(d, outStr);
		outStr.Append("\"}");
	}

	private void WriteTaggedLocalTime(StringView type, TomlLocalTime t, String outStr)
	{
		outStr.Append("{\"type\":\"");
		EscapeString(type, outStr);
		outStr.Append("\",\"value\":\"");
		FormatLocalTime(t, outStr);
		outStr.Append("\"}");
	}

	private void SerializeArray(TomlArray arr, String outStr)
	{
		outStr.Append('[');
		if (arr != null)
		{
			for (int i = 0; i < arr.Count; i++)
			{
				if (i > 0) outStr.Append(',');
				SerializeValue(arr[i], outStr);
			}
		}
		outStr.Append(']');
	}

	private void FormatOffsetDateTime(TomlOffsetDateTime dt, String outStr)
	{
		FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
		outStr.Append('T');
		FormatTime(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, outStr);

		if (dt.mOffsetMinutes == 0)
		{
			outStr.Append('Z');
		}
		else
		{
			int32 absOff = dt.mOffsetMinutes;
			if (absOff < 0)
			{
				outStr.Append('-');
				absOff = -absOff;
			}
			else
			{
				outStr.Append('+');
			}
			Pad2(absOff / 60, outStr);
			outStr.Append(':');
			Pad2(absOff % 60, outStr);
		}
	}

	private void FormatLocalDateTime(TomlLocalDateTime dt, String outStr)
	{
		FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
		outStr.Append('T');
		FormatTime(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, outStr);
	}

	private void FormatLocalDate(TomlLocalDate d, String outStr)
	{
		FormatDate(d.mYear, d.mMonth, d.mDay, outStr);
	}

	private void FormatLocalTime(TomlLocalTime t, String outStr)
	{
		FormatTime(t.mHour, t.mMinute, t.mSecond, t.mNanosecond, outStr);
	}

	private void FormatDate(int32 y, int32 m, int32 d, String outStr)
	{
		Pad4(y, outStr);
		outStr.Append('-');
		Pad2(m, outStr);
		outStr.Append('-');
		Pad2(d, outStr);
	}

	private void FormatTime(int32 h, int32 min, int32 s, int64 ns, String outStr)
	{
		Pad2(h, outStr);
		outStr.Append(':');
		Pad2(min, outStr);

		outStr.Append(':');
		Pad2(s, outStr);

		if (ns > 0)
		{
			String nsStr = scope String();
			ns.ToString(nsStr);
			while (nsStr.Length < 9)
				nsStr.Insert(0, '0');
			while (nsStr.Length > 0 && nsStr[nsStr.Length - 1] == '0')
				nsStr.Remove(nsStr.Length - 1);

			if (!nsStr.IsEmpty)
			{
				outStr.Append('.');
				outStr.Append(nsStr);
			}
		}
	}

	private void Pad2(int32 val, String outStr)
	{
		if (val < 10) outStr.Append('0');
		val.ToString(outStr);
	}

	private void Pad4(int32 val, String outStr)
	{
		if (val < 10) outStr.Append("000");
		else if (val < 100) outStr.Append("00");
		else if (val < 1000) outStr.Append('0');
		val.ToString(outStr);
	}

	private void EscapeString(StringView s, String outStr)
	{
		for (int i = 0; i < s.Length; i++)
		{
			char8 c = s[i];
			switch (c)
			{
			case '"':  outStr.Append("\\\""); break;
			case '\\': outStr.Append("\\\\"); break;
			case '\b': outStr.Append("\\b"); break;
			case '\f': outStr.Append("\\f"); break;
			case '\n': outStr.Append("\\n"); break;
			case '\r': outStr.Append("\\r"); break;
			case '\t': outStr.Append("\\t"); break;
			default:
				if ((uint8)c < 0x20)
				{
					outStr.Append("\\u00");
					uint8 hi = (uint8)c >> 4;
					uint8 lo = (uint8)c & 0x0F;
					outStr.Append((char8)(hi < 10 ? '0' + hi : 'a' + hi - 10));
					outStr.Append((char8)(lo < 10 ? '0' + lo : 'a' + lo - 10));
				}
				else
				{
					outStr.Append(c);
				}
			}
		}
	}

	private void WriteString(StringView s, String outStr)
	{
		outStr.Append('"');
		EscapeString(s, outStr);
		outStr.Append('"');
	}
}
