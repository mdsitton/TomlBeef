using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlWriterImpl: the PreserveStyle writer (token reuse, per-node styles, comments, blank lines).
extension TomlWriterImpl
{
	/// Metadata-aware write path that can reuse original tokens for clean string values.
	private static void WritePreserving(TomlDocument doc, String outStr, TomlVersion version, TomlDocumentMetadata metadata)
	{
		// Emit file header comments. They are separated from the content by a blank line (that separation
		// is what made them file-header comments rather than a key's leading comments).
		if (metadata.mRootComments != null && metadata.mRootComments.mLeading.Count > 0)
		{
			EmitCommentSet(metadata.mRootComments, outStr, metadata);
			WriteBlankLine(outStr, metadata);
		}
		int headerEnd = outStr.Length;
		WriteTablePreserving(doc.RootTable, "", outStr, version, metadata);
		// No content: drop the separator written after the header comments
		if (outStr.Length == headerEnd && EndsWithBlankLine(outStr))
			TrimLastNewline(outStr);
		// Emit footer/EOF comments after content
		if (metadata.mFooterComments != null && metadata.mFooterComments.mLeading.Count > 0)
		{
			if (metadata.mFooterComments.mSeparatedByBlankLine)
				WriteBlankLine(outStr, metadata);
			EmitCommentSet(metadata.mFooterComments, outStr, metadata);
		}
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
		for (int i = 0; i < tbl.Count; i++)
		{
			StringView key = tbl.GetKeyAt(i);
			TomlValue val = tbl.GetValueAt(i);

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
					// An empty array of tables has no [[header]] form, so write it as `key = []`
					if (arr.IsStatic || arr.Count == 0)
						WriteKeyValLinePreserving(key, val, outStr, version, tbl, metadata);
				}
				else
				{
					WriteKeyValLinePreserving(key, val, outStr, version, tbl, metadata);
				}
			}
		}

		// Phase 2: non-inline, non-array-element sub-tables as [header] or dotted keys
		for (int i = 0; i < tbl.Count; i++)
		{
			StringView key = tbl.GetKeyAt(i);
			TomlValue val = tbl.GetValueAt(i);

			if (val.IsTable)
			{
				TomlTable sub = val.AsTable;
				if (sub.Origin != .ArrayElement && sub.Origin != .InlineTable)
				{
					// Check if entries prefer dotted-key emission
					if (sub.HasDottedPreference(metadata))
					{
						// Emit dotted keys from parent level, then recurse for non-dotted sub-tables
						for (int j = 0; j < sub.Count; j++)
						{
							StringView sk = sub.GetKeyAt(j);
							TomlValue sv = sub.GetValueAt(j);
							if (!sv.IsTable || sv.AsTable.Origin == .InlineTable)
							{
								// Emit leading comments
								if (sub.MetadataContext != null && sub.TryGetEntryNodeId(sk, let nid))
									EmitLeadingBlock(nid, outStr, metadata);
								// Write dotted key = value. Under a [header] keys are relative to it; only an
								// enclosing dotted context contributes a prefix.
								String dk = scope String();
								if (dottedContext && !pathPrefix.IsEmpty)
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
								if (dottedContext && !pathPrefix.IsEmpty)
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
						WriteBlankLine(outStr, metadata);

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
		for (int i = 0; i < tbl.Count; i++)
		{
			StringView key = tbl.GetKeyAt(i);
			TomlValue val = tbl.GetValueAt(i);

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
			TomlValue elem = arr.GetValueAt(i);
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
			WriteBlankLine(outStr, metadata);

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
			parentTable.TryGetEntryNodeId(key, out nodeId);

		// Emit the blank line that preceded this entry in the source, then its leading comments
		if (nodeId.IsValid)
			EmitLeadingBlock(nodeId, outStr, metadata);

		WriteKeyPreserving(key, parentTable, metadata, outStr, version);
		outStr.Append(" = ");
		WriteValuePreserving(val, outStr, version, parentTable, key, metadata);

		// Emit trailing comment on the same line
		if (nodeId.IsValid)
			EmitTrailingComment(nodeId, outStr, metadata);

		WriteNewline(outStr, metadata);
	}

	/// Write a value, reusing the original token if available and clean. `baseIndent` is the indent of the
	/// line the value starts on, which a multi-line array or inline table nests its lines under.
	private static void WriteValuePreserving(TomlValue val, String outStr, TomlVersion version, TomlTable parentTable, StringView key, TomlDocumentMetadata metadata, int baseIndent = 0)
	{
		// Look up node ID for this entry
		TomlNodeId nodeId = .Invalid;
		if (parentTable != null && parentTable.MetadataContext != null)
			parentTable.TryGetEntryNodeId(key, out nodeId);

		// Try to reuse original token for string values
		if (val.IsString && nodeId.IsValid)
		{
			let style = metadata.GetNodeStyle(nodeId);
			if (style != null && style.mDirtyFlags == .None && style.mOriginalValueToken.IsValid)
			{
				let token = metadata.GetOriginalToken(style.mOriginalValueToken);
				if (!token.IsEmpty && IsTokenValidForVersion(token, version))
				{
					outStr.Append(token);
					return;
				}
			}
		}

		// Fall back to style-aware generation using document defaults and node format
		WriteValueWithDocumentStyle(val, outStr, version, metadata, nodeId, baseIndent);
	}

	/// Emit document-configured newline.
	private static void WriteNewline(String outStr, TomlDocumentMetadata metadata)
	{
		if (metadata != null && metadata.mDocumentStyle.mNewlineStyle == .CRLF)
			outStr.Append("\r\n");
		else
			outStr.Append('\n');
	}

	/// Write key = value with a dotted path prefix (for nested dotted contexts).
	private static void WriteDottedKeyVal(StringView key, TomlValue val, StringView pathPrefix, String outStr, TomlVersion version, TomlTable parentTable, TomlDocumentMetadata metadata)
	{
		// Look up node ID for leading comments
		TomlNodeId nodeId = .Invalid;
		if (parentTable.MetadataContext != null)
			parentTable.TryGetEntryNodeId(key, out nodeId);
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
	private static void WriteValueWithDocumentStyle(TomlValue val, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlNodeId nodeId, int baseIndent = 0)
	{
		if (val.IsString && metadata != null)
		{
			// Style follows the slot: a changed string keeps its own captured style; only strings
			// without one (e.g. newly added keys) use the document's dominant style.
			var style = metadata.mDocumentStyle.mDefaultStringStyle;
			bool leadingNewline = true;
			if (nodeId.IsValid)
			{
				let nodeStyle = metadata.GetNodeStyle(nodeId);
				if (nodeStyle != null && nodeStyle.mValueFormatRef.IsValid
					&& metadata.mValueFormats[nodeStyle.mValueFormatRef.mIndex] case .String(let stringFmt))
				{
					style = stringFmt.mStyle;
					leadingNewline = stringFmt.mStartsWithNewline;
				}
			}
			switch (style)
			{
			case .Literal:
				WriteLiteralString(val.AsString, outStr, version);
				return;
			case .MultilineBasic:
				WriteMultiLineBasicString(val.AsString, outStr, version, leadingNewline);
				return;
			case .MultilineLiteral:
				WriteMultiLineLiteralString(val.AsString, outStr, version, leadingNewline);
				return;
			case .Basic:
				WriteBasicString(val.AsString, outStr, version);
				return;
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
				// A new array (no captured format) follows the document's dominant array layout
				if (!hasArrayFmt && arr.Count > 0 && metadata.mDocumentStyle.mDefaultArrayStyle == .Multiline)
				{
					arrayFmt.mStyle = .Multiline;
					arrayFmt.mIndentSize = metadata.mDocumentStyle.mIndentSize;
					arrayFmt.mTrailingComma = metadata.mDocumentStyle.mDefaultArrayTrailingComma;
					hasArrayFmt = true;
				}
				WriteArrayPreserving(arr, outStr, version, metadata, arrayFmt, hasArrayFmt, baseIndent);
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
				WriteInlineTablePreserving(tbl, outStr, version, metadata, tableFmt, hasTableFmt, baseIndent);
				return;
			}
		}
		WriteValue(val, outStr, version);
	}

	/// Write a key using its captured key style: a key written quoted stays quoted, and a literal-quoted
	/// key stays literal when it can be. Dotted keys only captured the first segment's style, so they
	/// (and keys without metadata) fall back to AppendKey.
	private static void WriteKeyPreserving(StringView key, TomlTable parentTable, TomlDocumentMetadata metadata, String dest, TomlVersion version)
	{
		TomlNodeId nodeId = .Invalid;
		if (parentTable != null && parentTable.MetadataContext != null)
			parentTable.TryGetEntryNodeId(key, out nodeId);
		let style = nodeId.IsValid ? metadata.GetNodeStyle(nodeId) : null;
		if (style != null && style.mKeyFormatRef.IsValid)
		{
			let keyFmt = metadata.mKeyFormats[style.mKeyFormatRef.mIndex];
			if (!keyFmt.mPreferDottedPath)
			{
				if (keyFmt.mStyle == .QuotedLiteral && IsLiteralKeyRepresentable(key))
				{
					dest.Append('\'');
					dest.Append(key);
					dest.Append('\'');
					return;
				}
				if (keyFmt.mStyle == .QuotedBasic || keyFmt.mStyle == .QuotedLiteral)
				{
					WriteBasicString(key, dest, version);
					return;
				}
			}
		}
		AppendKey(key, dest, version);
	}

	/// A literal-quoted key cannot contain a single quote, a newline, or other control characters.
	private static bool IsLiteralKeyRepresentable(StringView key)
	{
		for (let c in key)
		{
			if (c == '\'' || c == '\n' || c == '\r' || (uint8)c == 0x7F || ((uint8)c < 0x20 && c != '\t'))
				return false;
		}
		return true;
	}

	/// Write an array preserving element tokens where possible.
	private static void WriteArrayPreserving(TomlArray arr, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlArrayFormat fmt, bool hasFormat, int baseIndent)
	{
		let ctx = arr.MetadataContext;
		if (hasFormat && fmt.mStyle == .Multiline)
		{
			WriteMultilineArrayPreserving(arr, outStr, version, metadata, fmt, baseIndent);
			return;
		}
		// Comments (e.g. added through TomlArray.SetComment) need their own lines
		if (ArrayHasComments(arr, metadata))
		{
			var multilineFmt = hasFormat ? fmt : TomlArrayFormat();
			multilineFmt.mStyle = .Multiline;
			multilineFmt.mTrailingComma = metadata.mDocumentStyle.mDefaultArrayTrailingComma;
			WriteMultilineArrayPreserving(arr, outStr, version, metadata, multilineFmt, baseIndent);
			return;
		}

		outStr.Append('[');
		for (int i = 0; i < arr.Count; i++)
		{
			if (i > 0) outStr.Append(", ");
			TomlValue elem = arr.GetValueAt(i);
			TomlNodeId elemNodeId = .Invalid;
			if (ctx != null)
				ctx.TryGetItemNodeId(i, out elemNodeId);

			WriteArrayElementPreserving(elem, elemNodeId, outStr, version, metadata, baseIndent);
		}
		outStr.Append(']');
	}

	/// The indent of a multi-line container's entries: its own (captured from the source, where it is a
	/// column, or the document's), but deeper than `baseIndent`, the line the container opens on, when
	/// it is nested in another multi-line container.
	private static int EntryIndent(int own, int baseIndent, TomlDocumentMetadata metadata)
	{
		if (baseIndent == 0 || own > baseIndent)
			return own;
		int step = metadata.mDocumentStyle.mIndentSize;
		return baseIndent + ((step > 0) ? step : 2);
	}

	private static void WriteMultilineArrayPreserving(TomlArray arr, String outStr, TomlVersion version, TomlDocumentMetadata metadata, TomlArrayFormat fmt, int baseIndent)
	{
		let ctx = arr.MetadataContext;
		int indentSize = EntryIndent(fmt.mIndentSize > 0 ? fmt.mIndentSize : metadata.mDocumentStyle.mIndentSize, baseIndent, metadata);
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

			AppendIndent(outStr, indentSize, metadata);
			TomlValue elem = arr.GetValueAt(i);
			WriteArrayElementPreserving(elem, elemNodeId, outStr, version, metadata, indentSize);

			// Emit comma BEFORE trailing comment (correct TOML: `1, # trail`)
			if (i < arr.Count - 1 || fmt.mTrailingComma)
				outStr.Append(',');

			// Emit trailing comment after the comma (attached to the element node)
			if (elemNodeId.IsValid)
				EmitTrailingComment(elemNodeId, outStr, metadata);

			WriteNewline(outStr, metadata);
		}
		AppendIndent(outStr, baseIndent, metadata);
		outStr.Append(']');
	}

	private static void WriteArrayElementPreserving(TomlValue elem, TomlNodeId elemNodeId, String outStr, TomlVersion version, TomlDocumentMetadata metadata, int baseIndent)
	{
		if (elem.IsString && elemNodeId.IsValid)
		{
			let style = metadata.GetNodeStyle(elemNodeId);
			if (style != null && style.mDirtyFlags == .None && style.mOriginalValueToken.IsValid)
			{
				let token = metadata.GetOriginalToken(style.mOriginalValueToken);
				if (!token.IsEmpty && IsTokenValidForVersion(token, version))
				{
					outStr.Append(token);
					return;
				}
			}
		}
		WriteValueWithDocumentStyle(elem, outStr, version, metadata, elemNodeId, baseIndent);
	}

	/// Returns false when an original string token uses syntax the target version lacks, so it must be
	/// regenerated instead of reused. TOML 1.0 has no `\e` or `\xHH` escapes; literal strings have no escapes.
	private static bool IsTokenValidForVersion(StringView token, TomlVersion version)
	{
		if (version != .V1_0 || token[0] == '\'')
			return true;
		for (int i = 0; i < token.Length - 1; i++)
		{
			if (token[i] != '\\')
				continue;
			char8 next = token[i + 1];
			if (next == 'e' || next == 'x')
				return false;
			i++; // skip the escaped character so `\\e` is not misread
		}
		return true;
	}

	/// Write an inline table using captured format metadata.
	/// Whether any field of an inline table, or its closing position, carries a comment.
	private static bool InlineTableHasComments(TomlTable tbl, TomlDocumentMetadata metadata)
	{
		let ctx = tbl.MetadataContext;
		if (ctx == null)
			return false;
		if (ctx.mNodeId.IsValid && HasComments(metadata.GetCommentSet(ctx.mNodeId)))
			return true;
		for (int i = 0; i < tbl.Count; i++)
		{
			if (tbl.TryGetEntryNodeId(tbl.GetKeyAt(i), let fieldId) && HasComments(metadata.GetCommentSet(fieldId)))
				return true;
		}
		return false;
	}

	/// Whether any element of an array, or the array itself, carries a comment.
	private static bool ArrayHasComments(TomlArray arr, TomlDocumentMetadata metadata)
	{
		let ctx = arr.MetadataContext;
		if (ctx == null)
			return false;
		if (ctx.mNodeId.IsValid && HasComments(metadata.GetCommentSet(ctx.mNodeId)))
			return true;
		for (int i = 0; i < arr.Count; i++)
		{
			if (ctx.TryGetItemNodeId(i, let elemId) && HasComments(metadata.GetCommentSet(elemId)))
				return true;
		}
		return false;
	}

	private static bool HasComments(TomlCommentSet commentSet)
	{
		return commentSet != null && (!commentSet.mLeading.IsEmpty || commentSet.HasTrailing);
	}

	private static void WriteInlineTablePreserving(TomlTable tbl, String outStr, TomlVersion version,
		TomlDocumentMetadata metadata, TomlTableFormat fmt, bool hasFormat, int baseIndent)
	{
		if (hasFormat && fmt.mMultiline && fmt.mInline && version != .V1_0)
		{
			WriteMultilineInlineTablePreserving(tbl, outStr, version, metadata, fmt, baseIndent);
			return;
		}
		// Comments (e.g. added through SetComment) only fit in the multi-line layout, which needs 1.1
		if (version != .V1_0 && InlineTableHasComments(tbl, metadata))
		{
			var multilineFmt = hasFormat ? fmt : TomlTableFormat();
			multilineFmt.mMultiline = true;
			multilineFmt.mInline = true;
			if (multilineFmt.mEntryIndent == 0 && metadata.mDocumentStyle.mIndentSize == 0)
				multilineFmt.mEntryIndent = 2;
			WriteMultilineInlineTablePreserving(tbl, outStr, version, metadata, multilineFmt, baseIndent);
			return;
		}

		// Single-line inline table
		outStr.Append('{');
		if (hasFormat && fmt.mOpenBraceSpacing > 0)
			outStr.Append(' ');

		for (int i = 0; i < tbl.Count; i++)
		{
			if (i > 0)
			{
				outStr.Append(',');
				// In single-line, default to space after comma unless explicitly captured as no-space
				bool noCommaSpace = hasFormat && fmt.mCommaSpacing == 0 && !fmt.mMultiline;
				if (!noCommaSpace)
					outStr.Append(' ');
			}
			StringView key = tbl.GetKeyAt(i);
			TomlValue val = tbl.GetValueAt(i);
			WriteKeyPreserving(key, tbl, metadata, outStr, version);
			// Without a captured format (e.g. a sub-table created by a dotted key), match the normal writer
			if (!hasFormat || fmt.mEqualsSpacing > 0)
				outStr.Append(" = ");
			else
				outStr.Append('=');
			WriteValuePreserving(val, outStr, version, tbl, key, metadata, baseIndent);
		}

		if (hasFormat && fmt.mCloseBraceSpacing > 0)
			outStr.Append(' ');
		outStr.Append('}');
	}

	/// Write a multiline inline table (v1.1).
	private static void WriteMultilineInlineTablePreserving(TomlTable tbl, String outStr, TomlVersion version,
		TomlDocumentMetadata metadata, TomlTableFormat fmt, int baseIndent)
	{
		outStr.Append('{');
		WriteNewline(outStr, metadata);

		int entryIndent = EntryIndent(fmt.mEntryIndent > 0 ? fmt.mEntryIndent : metadata.mDocumentStyle.mIndentSize, baseIndent, metadata);

		for (int i = 0; i < tbl.Count; i++)
		{
			StringView key = tbl.GetKeyAt(i);
			TomlValue val = tbl.GetValueAt(i);
			TomlNodeId fieldId = .Invalid;
			if (tbl.MetadataContext != null)
				tbl.TryGetEntryNodeId(key, out fieldId);
			if (fieldId.IsValid)
				EmitIndentedCommentSet(metadata.GetCommentSet(fieldId), entryIndent, outStr, metadata);

			AppendIndent(outStr, entryIndent, metadata);
			WriteKeyPreserving(key, tbl, metadata, outStr, version);
			if (fmt.mEqualsSpacing > 0)
				outStr.Append(" = ");
			else
				outStr.Append('=');
			WriteValuePreserving(val, outStr, version, tbl, key, metadata, entryIndent);
			if (i < tbl.Count - 1 || fmt.mTrailingComma)
				outStr.Append(',');
			if (fieldId.IsValid)
				EmitTrailingComment(fieldId, outStr, metadata);
			WriteNewline(outStr, metadata);
		}

		// Comments that sat after the last field, before the closing brace
		if (tbl.MetadataContext != null && tbl.MetadataContext.mNodeId.IsValid)
			EmitIndentedCommentSet(metadata.GetCommentSet(tbl.MetadataContext.mNodeId), entryIndent, outStr, metadata);
		AppendIndent(outStr, baseIndent, metadata);
		outStr.Append('}');
	}

	/// Indent by `count` characters, using tabs when the source document indented with tabs.
	private static void AppendIndent(String outStr, int count, TomlDocumentMetadata metadata)
	{
		char8 c = (metadata != null && metadata.mDocumentStyle.mUseTabs) ? '\t' : ' ';
		for (int i = 0; i < count; i++)
			outStr.Append(c);
	}

	// ================================================================
	// Comment emission helpers
	// ================================================================

	/// @brief Emit leading comments for a node (one # comment per line).
	/// Emits the blank line that separated a key/value from the preceding content in the source (if any),
	/// then its leading comments.
	private static void EmitLeadingBlock(TomlNodeId nodeId, String outStr, TomlDocumentMetadata metadata)
	{
		let commentSet = metadata.GetCommentSet(nodeId);
		if (commentSet != null && commentSet.mSeparatedByBlankLine)
			WriteBlankLine(outStr, metadata);
		EmitLeadingComments(nodeId, outStr, metadata);
	}

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
			let text = commentSet.mLeading[i];
			if (TomlCommentSet.IsAbsent(text))
			{
				WriteBlankLine(outStr, metadata);
				continue;
			}
			outStr.Append('#');
			if (!text.IsEmpty)
			{
				outStr.Append(' ');
				outStr.Append(text);
			}
			WriteNewline(outStr, metadata);
		}
	}

	private static void TrimLastNewline(String outStr)
	{
		if (outStr.EndsWith("\r\n"))
			outStr.RemoveFromEnd(2);
		else if (outStr.EndsWith('\n'))
			outStr.RemoveFromEnd(1);
	}

	/// Whether the output ends with an empty line (so another blank line would double it).
	private static bool EndsWithBlankLine(String outStr)
	{
		StringView view = outStr;
		if (view.EndsWith("\r\n"))
			view.RemoveFromEnd(2);
		else if (view.EndsWith('\n'))
			view.RemoveFromEnd(1);
		else
			return false;
		return view.IsEmpty || view.EndsWith('\n');
	}

	/// Writes a blank line, unless the output is empty or already ends with one.
	private static void WriteBlankLine(String outStr, TomlDocumentMetadata metadata)
	{
		if (!outStr.IsEmpty && !EndsWithBlankLine(outStr))
			WriteNewline(outStr, metadata);
	}

	/// @brief Emit all leading comments from a comment set, indented to the given level.
	/// Used for array element comments that should match the element indent.
	private static void EmitIndentedCommentSet(TomlCommentSet commentSet, int indentSize, String outStr, TomlDocumentMetadata metadata)
	{
		if (commentSet == null || commentSet.mLeading.Count == 0)
			return;

		for (int i = 0; i < commentSet.mLeading.Count; i++)
		{
			let text = commentSet.mLeading[i];
			if (TomlCommentSet.IsAbsent(text))
			{
				WriteBlankLine(outStr, metadata);
				continue;
			}
			AppendIndent(outStr, indentSize, metadata);
			outStr.Append('#');
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
		if (commentSet == null || !commentSet.HasTrailing)
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
