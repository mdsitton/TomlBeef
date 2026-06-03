using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

static class TomlWriterImpl
{
	public static void Write(TomlDocument doc, String outStr, TomlVersion version = .V1_1)
	{
		if (doc.Metadata != null)
			WritePreserving(doc, outStr, version, doc.Metadata);
		else
			WriteTable(doc.RootTable, "", outStr, version);
	}

	/// Metadata-aware write path that can reuse original tokens for clean string values.
	private static void WritePreserving(TomlDocument doc, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		// Emit file header comments
		if (metadata.mRootComments != null && metadata.mRootComments.mLeading.Count > 0)
			EmitCommentSet(metadata.mRootComments, outStr, metadata);
		WriteTablePreserving(doc.RootTable, "", outStr, version, metadata);
		// Emit footer/EOF comments after content
		if (metadata.mFooterComments != null && metadata.mFooterComments.mLeading.Count > 0)
			EmitCommentSet(metadata.mFooterComments, outStr, metadata);
	}

	private static void WriteTable(TomlTable tbl, StringView pathPrefix, String outStr, TomlVersion version)
	{
		// Phase 1: scalar keys, inline tables, static arrays
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (val.IsTable)
			{
				TomlTable sub = val.AsTable;
				if (sub.Origin == .InlineTable)
					WriteKeyValLine(key, val, outStr, version);
			}
			else if (val.IsArray)
			{
				TomlArray arr = val.AsArray;
				if (arr.IsStatic)
					WriteKeyValLine(key, val, outStr, version);
			}
			else
			{
				WriteKeyValLine(key, val, outStr, version);
			}
		}

		// Phase 2: non-inline, non-array-element sub-tables as [header]
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (val.IsTable)
			{
				TomlTable sub = val.AsTable;
				if (sub.Origin != .ArrayElement && sub.Origin != .InlineTable)
				{
					String fullPath = scope String();
					if (!pathPrefix.IsEmpty)
					{
						fullPath.Append(pathPrefix);
						fullPath.Append(".");
					}
					AppendKey(key, fullPath, version);

					outStr.Append("\n[");
					outStr.Append(fullPath);
					outStr.Append("]\n");
					WriteTable(sub, fullPath, outStr, version);
				}
			}
		}

		// Phase 3: array-of-tables last to avoid absorbing parent keys
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (val.IsArray)
			{
				TomlArray arr = val.AsArray;
				if (!arr.IsStatic && arr.Count > 0)
					EmitArrayOfTables(key, arr, pathPrefix, outStr, version);
			}
		}
	}

	private static void EmitArrayOfTables(StringView key, TomlArray arr, StringView pathPrefix, String outStr, TomlVersion version)
	{
		for (int i = 0; i < arr.Count; i++)
		{
			TomlValue elem = arr.GetValue(i);
			if (!elem.IsTable)
				continue;

			TomlTable sub = elem.AsTable;

			String fullPath = scope String();
			if (!pathPrefix.IsEmpty)
			{
				fullPath.Append(pathPrefix);
				fullPath.Append(".");
			}
			AppendKey(key, fullPath, version);

			outStr.Append("\n[[");
			outStr.Append(fullPath);
			outStr.Append("]]\n");

			WriteTable(sub, fullPath, outStr, version);
		}
	}

	private static void WriteKeyValLine(StringView key, TomlValue val, String outStr, TomlVersion version)
	{
		WriteKey(key, outStr, version);
		outStr.Append(" = ");
		WriteValue(val, outStr, version);
		outStr.Append("\n");
	}

	// ================================================================
	// Preserving writer: reuses original tokens for clean string values
	// ================================================================

	private static void WriteTablePreserving(TomlTable tbl, StringView pathPrefix, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		WriteTablePreserving(tbl, pathPrefix, false, outStr, version, metadata);
	}

	/// @param dottedContext When true, Phase 1 scalars get pathPrefix prepended (nested dotted context).
	private static void WriteTablePreserving(TomlTable tbl, StringView pathPrefix, bool dottedContext, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		// Phase 1: scalar keys, inline tables, static arrays
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (dottedContext)
			{
				// Emit with full dotted key prefix (for nested dotted contexts)
				if (val.IsTable)
				{
					TomlTable sub = val.AsTable;
					if (sub.Origin == .InlineTable)
						WriteDottedKeyVal(key, val, pathPrefix, outStr, version, tbl, metadata);
				}
				else if (!val.IsTable || val.AsTable.Origin == .InlineTable)
				{
					WriteDottedKeyVal(key, val, pathPrefix, outStr, version, tbl, metadata);
				}
			}
			else
			{
				if (val.IsTable)
				{
					TomlTable sub = val.AsTable;
					if (sub.Origin == .InlineTable)
						WriteKeyValLinePreserving(key, val, outStr, version, tbl, metadata);
				}
				else if (val.IsArray)
				{
					TomlArray arr = val.AsArray;
					if (arr.IsStatic)
						WriteKeyValLinePreserving(key, val, outStr, version, tbl, metadata);
				}
				else
				{
					WriteKeyValLinePreserving(key, val, outStr, version, tbl, metadata);
				}
			}
		}

		// Phase 2: non-inline, non-array-element sub-tables as [header] or dotted keys
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (val.IsTable)
			{
				TomlTable sub = val.AsTable;
				if (sub.Origin != .ArrayElement && sub.Origin != .InlineTable)
				{
					// Check if entries prefer dotted-key emission
					if (sub.HasDottedPreference(metadata))
					{
						// Emit dotted keys from parent level, then recurse for non-dotted sub-tables
						for (int j = 0; j < sub.KeyOrder.Count; j++)
						{
							String sk = sub.KeyOrder[j];
							TomlValue sv = sub.Entries[sk];
							if (!sv.IsTable || sv.AsTable.Origin == .InlineTable)
							{
								// Emit leading comments
								if (sub.MetadataContext != null && sub.MetadataContext.TryGetEntryNodeId(sk, let nid) && nid.IsValid)
									EmitLeadingComments(nid, outStr, metadata);
								// Write dotted key = value
								String dk = scope String();
								if (!pathPrefix.IsEmpty)
								{
									dk.Append(pathPrefix);
									dk.Append('.');
								}
								AppendKey(key, dk, version);
								dk.Append('.');
								AppendKey(sk, dk, version);
								outStr.Append(dk);
								outStr.Append(" = ");
								WriteValuePreserving(sv, outStr, version, sub, sk, metadata);
								WriteNewline(outStr, metadata);
							}
							else
							{
								// Non-inline sub-table: recurse with dotted path prefix
								String dp = scope String();
								if (!pathPrefix.IsEmpty)
								{
									dp.Append(pathPrefix);
									dp.Append('.');
								}
								AppendKey(key, dp, version);
								dp.Append('.');
								AppendKey(sk, dp, version);
								WriteTablePreserving(sv.AsTable, dp, true, outStr, version, metadata);
							}
						}
					}
					else
					{
						String fullPath = scope String();
						if (!pathPrefix.IsEmpty)
						{
							fullPath.Append(pathPrefix);
							fullPath.Append(".");
						}
						AppendKey(key, fullPath, version);

						// Emit separator newline before header (only if not at start)
						if (outStr.Length > 0)
							WriteNewline(outStr, metadata);

						// Emit leading comments for the table header
						if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
							EmitLeadingComments(sub.MetadataContext.mNodeId, outStr, metadata);

						outStr.Append('[');
						outStr.Append(fullPath);
						outStr.Append(']');

						// Emit trailing comment on the header line
						if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
							EmitTrailingComment(sub.MetadataContext.mNodeId, outStr, metadata);

						WriteNewline(outStr, metadata);
						WriteTablePreserving(sub, fullPath, outStr, version, metadata);
					}
				}
			}
		}

		// Phase 3: array-of-tables
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

			if (val.IsArray)
			{
				TomlArray arr = val.AsArray;
				if (!arr.IsStatic && arr.Count > 0)
					EmitArrayOfTablesPreserving(key, arr, pathPrefix, outStr, version, metadata);
			}
		}
	}

	private static void EmitArrayOfTablesPreserving(StringView key, TomlArray arr, StringView pathPrefix, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		for (int i = 0; i < arr.Count; i++)
		{
			TomlValue elem = arr.GetValue(i);
			if (!elem.IsTable)
				continue;

			TomlTable sub = elem.AsTable;

			String fullPath = scope String();
			if (!pathPrefix.IsEmpty)
			{
				fullPath.Append(pathPrefix);
				fullPath.Append(".");
			}
			AppendKey(key, fullPath, version);

			// Emit separator newline before comments (only if not at start)
			if (outStr.Length > 0)
				WriteNewline(outStr, metadata);

			// Emit leading comments for the array element header
			if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
				EmitLeadingComments(sub.MetadataContext.mNodeId, outStr, metadata);

			outStr.Append("[[");
			outStr.Append(fullPath);
			outStr.Append("]]");

			// Emit trailing comment on the header line
			if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
				EmitTrailingComment(sub.MetadataContext.mNodeId, outStr, metadata);

			WriteNewline(outStr, metadata);

			WriteTablePreserving(sub, fullPath, outStr, version, metadata);
		}
	}

	private static void WriteKeyValLinePreserving(StringView key, TomlValue val, String outStr, TomlVersion version, TomlTable parentTable, TomlDocumentMetadata metadata)
	{
		// Look up node ID for this entry
		TomlNodeId nodeId = .Invalid;
		if (parentTable.MetadataContext != null)
			parentTable.MetadataContext.TryGetEntryNodeId(key, out nodeId);

		// Emit leading comments
		if (nodeId.IsValid)
			EmitLeadingComments(nodeId, outStr, metadata);

		WriteKey(key, outStr, version);
		outStr.Append(" = ");
		WriteValuePreserving(val, outStr, version, parentTable, key, metadata);

		// Emit trailing comment on the same line
		if (nodeId.IsValid)
			EmitTrailingComment(nodeId, outStr, metadata);

		WriteNewline(outStr, metadata);
	}

	/// Write a value, reusing the original token if available and clean.
	private static void WriteValuePreserving(TomlValue val, String outStr, TomlVersion version, TomlTable parentTable, StringView key, TomlDocumentMetadata metadata)
	{
		// Look up node ID for this entry
		TomlNodeId nodeId = .Invalid;
		if (parentTable != null && parentTable.MetadataContext != null)
			parentTable.MetadataContext.TryGetEntryNodeId(key, out nodeId);

		// Try to reuse original token for string values
		if (val.IsString && nodeId.IsValid)
		{
			let style = metadata.GetNodeStyle(nodeId);
			if (style != null && style.mDirtyFlags == .None && style.mOriginalValueToken.IsValid)
			{
				let token = metadata.GetOriginalToken(style.mOriginalValueToken);
				if (!token.IsEmpty)
				{
					outStr.Append(token);
					return;
				}
			}
		}

		// Fall back to style-aware generation using document defaults and node format
		WriteValueWithDocumentStyle(val, outStr, version, metadata, nodeId);
	}

	/// Emit document-configured newline.
	private static void WriteNewline(String outStr, TomlDocumentMetadata metadata)
	{
		if (metadata != null && metadata.mDocumentStyle.mNewlineStyle == .CRLF)
			outStr.Append("\r\n");
		else
			outStr.Append('\n');
	}

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
			if (fmt.mPrecision >= 0)
			{
				String format = scope String("F");
				fmt.mPrecision.ToString(format);
				val.ToString(outStr, format, null);
			}
			else
			{
				val.ToString(outStr, "R", null);
			}
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

		// Pad or trim exponent digits to match captured width.
		if (fmt.mExponentDigits > 0)
		{
			while (expDigits.Length < fmt.mExponentDigits)
				expDigits.Insert(0, '0');
			// Trim excess leading zeros (safe: they don't change the value)
			while (expDigits.Length > fmt.mExponentDigits && expDigits[0] == '0')
				expDigits.Remove(0, 1);
		}

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

	/// Write a date-time value using format metadata for style preservation.
	private static void WriteDateTimeWithFormat(TomlValue val, TomlDateTimeFormat fmt, String outStr, TomlVersion version)
	{
		if (val.IsOffsetDateTime)
		{
			let dt = val.AsOffsetDateTime;
			FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
			outStr.Append(fmt.mUsesUppercaseT ? 'T' : ' ');
			FormatTimeWithFormat(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, fmt, version, outStr);
			if (dt.mOffsetMinutes == 0 && fmt.mUsesZ)
				outStr.Append('Z');
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
			outStr.Append(fmt.mUsesUppercaseT ? 'T' : ' ');
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

	/// Write key = value with a dotted path prefix (for nested dotted contexts).
	private static void WriteDottedKeyVal(StringView key, TomlValue val, StringView pathPrefix, String outStr, TomlVersion version, TomlTable parentTable, TomlDocumentMetadata metadata)
	{
		// Look up node ID for leading comments
		TomlNodeId nodeId = .Invalid;
		if (parentTable.MetadataContext != null)
			parentTable.MetadataContext.TryGetEntryNodeId(key, out nodeId);
		if (nodeId.IsValid)
			EmitLeadingComments(nodeId, outStr, metadata);

		// Write dotted.key = value
		if (!pathPrefix.IsEmpty)
		{
			outStr.Append(pathPrefix);
			outStr.Append('.');
		}
		AppendKey(key, outStr, version);
		outStr.Append(" = ");
		WriteValuePreserving(val, outStr, version, parentTable, key, metadata);

		// Trailing comment on same line
		if (nodeId.IsValid)
			EmitTrailingComment(nodeId, outStr, metadata);
		WriteNewline(outStr, metadata);
	}

	/// Write a value using document-level style defaults when available.
	private static void WriteValueWithDocumentStyle(TomlValue val, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlNodeId nodeId)
	{
		if (val.IsString && metadata != null)
		{
			let style = metadata.mDocumentStyle.mDefaultStringStyle;
			switch (style)
			{
			case .Literal:
				WriteLiteralString(val.AsString, outStr, version);
				return;
			case .MultilineBasic:
				WriteMultiLineBasicString(val.AsString, outStr, version);
				return;
			case .MultilineLiteral:
				WriteMultiLineLiteralString(val.AsString, outStr, version);
				return;
			default:
				break;
			}
		}
		// Try node-level numeric format metadata
		if (nodeId.IsValid && metadata != null)
		{
			let style = metadata.GetNodeStyle(nodeId);
			if (style != null && style.mValueFormatRef.IsValid)
			{
				let fmt = metadata.mValueFormats[style.mValueFormatRef.mIndex];
				if (val.IsInteger && fmt case .Integer(let intFmt))
				{
					WriteIntegerWithFormat(val.AsInteger, intFmt, outStr);
					return;
				}
				if (val.IsFloat && fmt case .Float(let floatFmt))
				{
					WriteFloatWithFormat(val.AsFloat, floatFmt, outStr);
					return;
				}
				if (fmt case .DateTime(let dtFmt))
				{
					WriteDateTimeWithFormat(val, dtFmt, outStr, version);
					return;
				}
			}
		}
		if (val.IsArray && metadata != null)
		{
			TomlArray arr = val.AsArray;
			if (arr != null && arr.MetadataContext != null)
			{
				TomlArrayFormat arrayFmt = .();
				bool hasArrayFmt = false;
				if (nodeId.IsValid)
				{
					let style = metadata.GetNodeStyle(nodeId);
					if (style != null && style.mValueFormatRef.IsValid)
					{
						let fmt = metadata.mValueFormats[style.mValueFormatRef.mIndex];
						if (fmt case .Array(let arrFmt))
						{
							arrayFmt = arrFmt;
							hasArrayFmt = true;
						}
					}
				}
				WriteArrayPreserving(arr, outStr, version, metadata, arrayFmt, hasArrayFmt);
				return;
			}
		}
		// Inline table format preservation
		if (val.IsTable && metadata != null)
		{
			TomlTable tbl = val.AsTable;
			if (tbl != null && tbl.Origin == .InlineTable)
			{
				TomlTableFormat tableFmt = .();
				bool hasTableFmt = false;
				if (nodeId.IsValid)
				{
					let style = metadata.GetNodeStyle(nodeId);
					if (style != null && style.mValueFormatRef.IsValid)
					{
						let fmt = metadata.mValueFormats[style.mValueFormatRef.mIndex];
						if (fmt case .Table(let tFmt))
						{
							tableFmt = tFmt;
							hasTableFmt = true;
						}
					}
				}
				WriteInlineTablePreserving(tbl, outStr, version, metadata, tableFmt, hasTableFmt);
				return;
			}
		}
		WriteValue(val, outStr, version);
	}

	private static void WriteKey(StringView key, String outStr, TomlVersion version)
	{
		AppendKey(key, outStr, version);
	}

	private static void AppendKey(StringView key, String dest, TomlVersion version)
	{
		if (IsBareKey(key))
			dest.Append(key);
		else
			WriteBasicString(key, dest, version);
	}

	private static void WriteValue(TomlValue val, String outStr, TomlVersion version)
	{
		switch (val)
		{
		case .String(let s):      WriteBasicString(s, outStr, version);
		case .Integer(let v):     v.ToString(outStr);
		case .Float(let v):
			if (v.IsInfinity)
			{
				if (v > 0) outStr.Append("inf");
				else outStr.Append("-inf");
			}
			else if (v.IsNaN)
			{
				outStr.Append("nan");
			}
			else
			{
				// IEEE 754: preserve negative zero sign
				if (v == 0.0 && (1.0 / v) < 0.0)
				{
					outStr.Append("-0.0");
				}
				else
				{
					int before = outStr.Length;
					v.ToString(outStr, "R", null);
					// Ensure the output is unambiguously a float (must contain '.', 'e', or 'E')
					bool hasDot = false;
					for (int fi = before; fi < outStr.Length; fi++)
					{
						char8 fc = outStr[fi];
						if (fc == '.' || fc == 'e' || fc == 'E')
							{ hasDot = true; break; }
					}
					if (!hasDot)
						outStr.Append(".0");
				}
			}
		case .Bool(let v):        outStr.Append(v ? "true" : "false");
		case .OffsetDateTime(let v): WriteOffsetDateTime(v, outStr);
		case .LocalDateTime(let v):  WriteLocalDateTime(v, outStr);
		case .LocalDate(let v):      WriteLocalDate(v, outStr);
		case .LocalTime(let v):      WriteLocalTime(v, outStr);
		case .Array(let arr):     WriteInlineArray(arr, outStr, version);
		case .Table(let tbl):     WriteInlineTable(tbl, outStr, version);
		}
	}

	private static void WriteBasicString(StringView s, String outStr, TomlVersion version)
	{
		outStr.Append('"');
		for (int i = 0; i < s.Length; i++)
		{
			char8 c = s[i];
			switch (c)
			{
			case '"':  outStr.Append("\\\""); break;
			case '\\': outStr.Append("\\\\"); break;
			case '\b': outStr.Append("\\b"); break;
			case '\t': outStr.Append("\\t"); break;
			case '\n': outStr.Append("\\n"); break;
			case '\f': outStr.Append("\\f"); break;
			case '\r': outStr.Append("\\r"); break;
			case (char8)0x1B:
			if (version == .V1_0)
				outStr.Append("\\u001b");
			else
				outStr.Append("\\e");
			break;
			default:
				if ((uint8)c < 0x20 || (uint8)c == 0x7F)
				{
					outStr.Append("\\u00");
					uint8 cb = (uint8)c;
					outStr.Append(TomlChar.HexDigitChar((cb >> 4) & 0x0F));
					outStr.Append(TomlChar.HexDigitChar(cb & 0x0F));
				}
				else
				{
					outStr.Append(c);
				}
			}
		}
		outStr.Append('"');
	}

	private static void WriteLiteralString(StringView s, String outStr, TomlVersion version)
	{
		// Pre-scan: literal strings can't contain ', newlines, or control chars (except tab)
		for (int i = 0; i < s.Length; i++)
		{
			char8 c = s[i];
			if (c == '\'' || c == '\n' || c == '\r' || (uint8)c == 0x7F || ((uint8)c < 0x20 && c != '\t'))
			{
				WriteBasicString(s, outStr, version);
				return;
			}
		}
		outStr.Append('\'');
		outStr.Append(s);
		outStr.Append('\'');
	}

	private static void WriteMultiLineBasicString(StringView s, String outStr, TomlVersion version)
	{
		outStr.Append('"'); outStr.Append('"'); outStr.Append('"');
		// Emit an extra newline to protect a leading \n from being trimmed by spec
		outStr.Append('\n');
		for (int i = 0; i < s.Length; i++)
		{
			char8 c = s[i];
			switch (c)
			{
			case '"': outStr.Append("\\\""); break;
			case '\\': outStr.Append("\\\\"); break;
			case '\b': outStr.Append("\\b"); break;
			case '\t': outStr.Append("\\t"); break;
			case '\n': outStr.Append('\n'); break;
			case '\f': outStr.Append("\\f"); break;
			case '\r': outStr.Append("\\r"); break;
			default:
				if ((uint8)c < 0x20 || (uint8)c == 0x7F)
				{
					outStr.Append("\\u00");
					uint8 cb = (uint8)c;
					outStr.Append(TomlChar.HexDigitChar((cb >> 4) & 0x0F));
					outStr.Append(TomlChar.HexDigitChar(cb & 0x0F));
				}
				else
				{
					outStr.Append(c);
				}
			}
		}
		outStr.Append('"'); outStr.Append('"'); outStr.Append('"');
	}

	private static void WriteMultiLineLiteralString(StringView s, String outStr, TomlVersion version)
	{
		// Pre-scan: multiline literal strings can't contain ''' or control chars (except tab/newline)
		// Bare \r is also rejected
		for (int i = 0; i < s.Length - 2; i++)
		{
			if (s[i] == '\'' && s[i + 1] == '\'' && s[i + 2] == '\'')
			{
				WriteMultiLineBasicString(s, outStr, version);
				return;
			}
		}
		for (int i = 0; i < s.Length; i++)
		{
			char8 c = s[i];
			if (c == '\r' || (uint8)c == 0x7F || ((uint8)c < 0x20 && c != '\t' && c != '\n'))
			{
				WriteMultiLineBasicString(s, outStr, version);
				return;
			}
		}
		outStr.Append('\''); outStr.Append('\''); outStr.Append('\'');
		outStr.Append('\n');
		outStr.Append(s);
		outStr.Append('\''); outStr.Append('\''); outStr.Append('\'');
	}

	private static void WriteOffsetDateTime(TomlOffsetDateTime dt, String outStr)
	{
		FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
		outStr.Append('T');
		FormatTime(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, outStr);
		if (dt.mOffsetMinutes == 0)
			outStr.Append('Z');
		else
		{
			int32 absOff = dt.mOffsetMinutes;
			if (absOff < 0) { outStr.Append('-'); absOff = -absOff; }
			else outStr.Append('+');
			Pad2(absOff / 60, outStr);
			outStr.Append(':');
			Pad2(absOff % 60, outStr);
		}
	}

	private static void WriteLocalDateTime(TomlLocalDateTime dt, String outStr)
	{
		FormatDate(dt.mYear, dt.mMonth, dt.mDay, outStr);
		outStr.Append('T');
		FormatTime(dt.mHour, dt.mMinute, dt.mSecond, dt.mNanosecond, outStr);
	}

	private static void WriteLocalDate(TomlLocalDate d, String outStr)
	{
		FormatDate(d.mYear, d.mMonth, d.mDay, outStr);
	}

	private static void WriteLocalTime(TomlLocalTime t, String outStr)
	{
		FormatTime(t.mHour, t.mMinute, t.mSecond, t.mNanosecond, outStr);
	}

	private static void WriteInlineArray(TomlArray arr, String outStr, TomlVersion version)
	{
		outStr.Append('[');
		for (int i = 0; i < arr.Count; i++)
		{
			if (i > 0) outStr.Append(", ");
			WriteValue(arr.GetValue(i), outStr, version);
		}
		outStr.Append(']');
	}

	/// Write an array preserving element tokens where possible.
	private static void WriteArrayPreserving(TomlArray arr, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlArrayFormat fmt, bool hasFormat)
	{
		let ctx = arr.MetadataContext;
		if (hasFormat && fmt.mStyle == .Multiline)
		{
			WriteMultilineArrayPreserving(arr, outStr, version, metadata, fmt);
			return;
		}

		outStr.Append('[');
		for (int i = 0; i < arr.Count; i++)
		{
			if (i > 0) outStr.Append(", ");
			TomlValue elem = arr.GetValue(i);
			TomlNodeId elemNodeId = .Invalid;
			if (ctx != null)
				ctx.TryGetItemNodeId(i, out elemNodeId);

			WriteArrayElementPreserving(elem, elemNodeId, outStr, version, metadata);
		}
		outStr.Append(']');
	}

	private static void WriteMultilineArrayPreserving(TomlArray arr, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlArrayFormat fmt)
	{
		let ctx = arr.MetadataContext;
		int indentSize = fmt.mIndentSize > 0 ? fmt.mIndentSize : metadata.mDocumentStyle.mIndentSize;
		outStr.Append('[');
		WriteNewline(outStr, metadata);

		// Emit leading comments on the array node itself (for empty arrays with comments)
		TomlNodeId arrayNodeId = (ctx != null) ? ctx.mNodeId : .Invalid;
		if (arrayNodeId.IsValid)
		{
			let commentSet = metadata.GetCommentSet(arrayNodeId);
			if (commentSet != null && commentSet.mLeading.Count > 0)
				EmitIndentedCommentSet(commentSet, indentSize, outStr, metadata);
		}

		for (int i = 0; i < arr.Count; i++)
		{
			TomlNodeId elemNodeId = .Invalid;
			if (ctx != null)
				ctx.TryGetItemNodeId(i, out elemNodeId);

			// Emit leading comments before the element — indented to match element indent
			if (elemNodeId.IsValid)
			{
				let commentSet = metadata.GetCommentSet(elemNodeId);
				if (commentSet != null)
				{
					if (commentSet.mSeparatedByBlankLine)
						WriteNewline(outStr, metadata);
					EmitIndentedCommentSet(commentSet, indentSize, outStr, metadata);
				}
			}

			AppendIndent(outStr, indentSize);
			TomlValue elem = arr.GetValue(i);
			WriteArrayElementPreserving(elem, elemNodeId, outStr, version, metadata);

			// Emit comma BEFORE trailing comment (correct TOML: `1, # trail`)
			if (i < arr.Count - 1 || fmt.mTrailingComma)
				outStr.Append(',');

			// Emit trailing comment after the comma (attached to the element node)
			if (elemNodeId.IsValid)
				EmitTrailingComment(elemNodeId, outStr, metadata);

			WriteNewline(outStr, metadata);
		}
		outStr.Append(']');
	}

	private static void WriteArrayElementPreserving(TomlValue elem, TomlNodeId elemNodeId, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		if (elem.IsString && elemNodeId.IsValid)
		{
			let style = metadata.GetNodeStyle(elemNodeId);
			if (style != null && style.mDirtyFlags == .None && style.mOriginalValueToken.IsValid)
			{
				let token = metadata.GetOriginalToken(style.mOriginalValueToken);
				if (!token.IsEmpty)
				{
					outStr.Append(token);
					return;
				}
			}
		}
		WriteValueWithDocumentStyle(elem, outStr, version, metadata, elemNodeId);
	}

	private static void WriteInlineTable(TomlTable tbl, String outStr, TomlVersion version)
	{
		outStr.Append('{');
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			if (i > 0) outStr.Append(", ");
			String key = tbl.KeyOrder[i];
			WriteKey(key, outStr, version);
			outStr.Append(" = ");
			WriteValue(tbl.Entries[key], outStr, version);
		}
		outStr.Append('}');
	}

	/// Write an inline table using captured format metadata.
	private static void WriteInlineTablePreserving(TomlTable tbl, String outStr, TomlVersion version,
		TomlDocumentMetadata metadata, TomlTableFormat fmt, bool hasFormat)
	{
		if (hasFormat && fmt.mMultiline && fmt.mInline && version != .V1_0)
		{
			WriteMultilineInlineTablePreserving(tbl, outStr, version, metadata, fmt);
			return;
		}

		// Single-line inline table
		outStr.Append('{');
		if (hasFormat && fmt.mOpenBraceSpacing > 0)
			outStr.Append(' ');

		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			if (i > 0)
			{
				outStr.Append(',');
				// In single-line, default to space after comma unless explicitly captured as no-space
				bool noCommaSpace = hasFormat && fmt.mCommaSpacing == 0 && !fmt.mMultiline;
				if (!noCommaSpace)
					outStr.Append(' ');
			}
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];
			WriteKey(key, outStr, version);
			if (hasFormat && fmt.mEqualsSpacing > 0)
				outStr.Append(" = ");
			else
				outStr.Append('=');
			WriteValuePreserving(val, outStr, version, tbl, key, metadata);
		}

		if (hasFormat && fmt.mCloseBraceSpacing > 0)
			outStr.Append(' ');
		outStr.Append('}');
	}

	/// Write a multiline inline table (v1.1).
	private static void WriteMultilineInlineTablePreserving(TomlTable tbl, String outStr, TomlVersion version,
		TomlDocumentMetadata metadata, TomlTableFormat fmt)
	{
		outStr.Append('{');
		WriteNewline(outStr, metadata);

		int entryIndent = fmt.mEntryIndent > 0
			? fmt.mEntryIndent
			: metadata.mDocumentStyle.mIndentSize;

		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			AppendIndent(outStr, entryIndent);
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];
			WriteKey(key, outStr, version);
			if (fmt.mEqualsSpacing > 0)
				outStr.Append(" = ");
			else
				outStr.Append('=');
			WriteValuePreserving(val, outStr, version, tbl, key, metadata);
			if (i < tbl.KeyOrder.Count - 1 || fmt.mTrailingComma)
				outStr.Append(',');
			WriteNewline(outStr, metadata);
		}

		outStr.Append('}');
	}

	private static void FormatDate(int32 y, int32 m, int32 d, String outStr)
	{
		Pad4(y, outStr); outStr.Append('-');
		Pad2(m, outStr); outStr.Append('-');
		Pad2(d, outStr);
	}

	private static void FormatTime(int32 h, int32 min, int32 s, int64 ns, String outStr)
	{
		Pad2(h, outStr); outStr.Append(':');
		Pad2(min, outStr); outStr.Append(':');
		Pad2(s, outStr);
		if (ns > 0)
		{
			String nsStr = scope String();
			ns.ToString(nsStr);
			while (nsStr.Length < 9) nsStr.Insert(0, '0');
			while (nsStr.Length > 0 && nsStr[nsStr.Length - 1] == '0')
				nsStr.Remove(nsStr.Length - 1);
			if (!nsStr.IsEmpty)
			{
				outStr.Append('.');
				outStr.Append(nsStr);
			}
		}
	}

	private static void Pad2(int32 val, String outStr)
	{
		if (val < 10) outStr.Append('0');
		val.ToString(outStr);
	}

	private static void AppendIndent(String outStr, int count)
	{
		for (int i = 0; i < count; i++)
			outStr.Append(' ');
	}

	private static void Pad4(int32 val, String outStr)
	{
		if (val < 10) outStr.Append("000");
		else if (val < 100) outStr.Append("00");
		else if (val < 1000) outStr.Append('0');
		val.ToString(outStr);
	}

	private static bool IsBareKey(StringView key)
	{
		if (key.IsEmpty) return false;
		for (int i = 0; i < key.Length; i++)
		{
			if (!TomlChar.IsBareKeyChar(key[i]))
				return false;
		}
		return true;
	}

	// ================================================================
	// Comment emission helpers
	// ================================================================

	/// @brief Emit leading comments for a node (one # comment per line).
	private static void EmitLeadingComments(TomlNodeId nodeId, String outStr, TomlDocumentMetadata metadata)
	{
		let commentSet = metadata.GetCommentSet(nodeId);
		if (commentSet == null || commentSet.mLeading.Count == 0)
			return;

		EmitCommentSet(commentSet, outStr, metadata);
	}

	/// @brief Emit all leading comments from a comment set.
	private static void EmitCommentSet(TomlCommentSet commentSet, String outStr, TomlDocumentMetadata metadata)
	{
		if (commentSet == null || commentSet.mLeading.Count == 0)
			return;

		for (int i = 0; i < commentSet.mLeading.Count; i++)
		{
			outStr.Append('#');
			let text = commentSet.mLeading[i];
			if (!text.IsEmpty)
			{
				outStr.Append(' ');
				outStr.Append(text);
			}
			WriteNewline(outStr, metadata);
		}
	}

	/// @brief Emit all leading comments from a comment set, indented to the given level.
	/// Used for array element comments that should match the element indent.
	private static void EmitIndentedCommentSet(TomlCommentSet commentSet, int indentSize, String outStr, TomlDocumentMetadata metadata)
	{
		if (commentSet == null || commentSet.mLeading.Count == 0)
			return;

		for (int i = 0; i < commentSet.mLeading.Count; i++)
		{
			AppendIndent(outStr, indentSize);
			outStr.Append('#');
			let text = commentSet.mLeading[i];
			if (!text.IsEmpty)
			{
				outStr.Append(' ');
				outStr.Append(text);
			}
			WriteNewline(outStr, metadata);
		}
	}

	/// @brief Emit a trailing comment on the current line (after the value, before newline).
	/// Emits the comment marker even for empty trailing comments (e.g., a = 1 #).
	private static void EmitTrailingComment(TomlNodeId nodeId, String outStr, TomlDocumentMetadata metadata)
	{
		let commentSet = metadata.GetCommentSet(nodeId);
		if (commentSet == null || commentSet.mTrailing == null)
			return;

		if (commentSet.mTrailing.IsEmpty)
			outStr.Append(" #");
		else
		{
			outStr.Append(" # ");
			outStr.Append(commentSet.mTrailing);
		}
	}
}
