using System;
using System.Collections;

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
			EmitCommentSet(metadata.mRootComments, outStr);
		WriteTablePreserving(doc.RootTable, "", outStr, version, metadata);
		// Emit footer/EOF comments after content
		if (metadata.mFooterComments != null && metadata.mFooterComments.mLeading.Count > 0)
			EmitCommentSet(metadata.mFooterComments, outStr);
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
			TomlValue elem = arr[i];
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
		// Phase 1: scalar keys, inline tables, static arrays
		for (int i = 0; i < tbl.KeyOrder.Count; i++)
		{
			String key = tbl.KeyOrder[i];
			TomlValue val = tbl.Entries[key];

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

					// Emit separator newline before comments (only if not at start)
					if (outStr.Length > 0)
						outStr.Append('\n');

					// Emit leading comments for the table header
					if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
						EmitLeadingComments(sub.MetadataContext.mNodeId, outStr, metadata);

					outStr.Append('[');
					outStr.Append(fullPath);
					outStr.Append(']');

					// Emit trailing comment on the header line
					if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
						EmitTrailingComment(sub.MetadataContext.mNodeId, outStr, metadata);

					outStr.Append("\n");
					WriteTablePreserving(sub, fullPath, outStr, version, metadata);
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
			TomlValue elem = arr[i];
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
				outStr.Append('\n');

			// Emit leading comments for the array element header
			if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
				EmitLeadingComments(sub.MetadataContext.mNodeId, outStr, metadata);

			outStr.Append("[[");
			outStr.Append(fullPath);
			outStr.Append("]]");

			// Emit trailing comment on the header line
			if (sub.MetadataContext != null && sub.MetadataContext.mNodeId.IsValid)
				EmitTrailingComment(sub.MetadataContext.mNodeId, outStr, metadata);

			outStr.Append("\n");

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

		outStr.Append("\n");
	}

	/// Write a value, reusing the original token if available and clean.
	private static void WriteValuePreserving(TomlValue val, String outStr, TomlVersion version, TomlTable parentTable, StringView key, TomlDocumentMetadata metadata)
	{
		// Try to reuse original token for string values
		if (val.IsString && parentTable != null && parentTable.MetadataContext != null)
		{
			if (parentTable.MetadataContext.TryGetEntryNodeId(key, let nodeId) && nodeId.IsValid)
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
		}

		// Fall back to canonical generation
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
			WriteValue(arr[i], outStr, version);
		}
		outStr.Append(']');
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

		EmitCommentSet(commentSet, outStr);
	}

	/// @brief Emit all leading comments from a comment set.
	private static void EmitCommentSet(TomlCommentSet commentSet, String outStr)
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
			outStr.Append('\n');
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
