using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlParserImpl: arrays and inline tables.
extension TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	// ================================================================
	// Array parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseArray()
	{
		mCursor.AdvanceByte();
		int startLine = mCursor.Line;
		TomlArray arr = mStore.NewArray();
		arr.IsStatic = true;
		if (mMetadata == null)
			return ParsePlainArray(arr);

		// Array-local pending comment list for PreserveStyle mode (its buffer is only allocated by a comment)
		List<StringView> arrayPendingComments = (mStyle != null) ? scope:: List<StringView>() : null;
		// Layout, recorded at the array's own separators rather than read back from its text: a newline
		// between them makes it multi-line (one inside an element does not), and the first element that
		// starts a line gives the indent. lastLine is where the previous separator or element ended.
		var layout = TomlArrayFormat();
		bool indentKnown = false;
		int lastLine = startLine;
		// Tracks whether the preceding comma was followed by a blank line
		bool arraySawBlankLine = false;

		// Capture comments after opening bracket
		bool unusedBlank = false;
		if (SkipWsAndCaptureComments(arrayPendingComments, out unusedBlank) case .Err(let e))
		{
			
			return .Err(e);
		}
		if (mCursor.PeekByte() == ']')
		{
			mCursor.AdvanceByte();
			FinishArrayLayout(arr, ref layout, lastLine);
			// Empty array: flush comments to the array node itself
			if (arrayPendingComments != null && arrayPendingComments.Count > 0)
			{
				EnsureArrayContext(arr);
				let commentSet = mStyle.GetOrCreateCommentSet(arr.MetadataContext.mNodeId);
				if (commentSet != null)
				{
					for (int ci = 0; ci < arrayPendingComments.Count; ci++)
						commentSet.mLeading.Add(arrayPendingComments[ci]);
					arrayPendingComments.Clear();
				}
			}
			return TomlValue.Array(arr);
		}

		while (true)
		{
			// Capture comments before element (potential leading comments)
			bool unusedBlank2 = false;
			if (SkipWsAndCaptureComments(arrayPendingComments, out unusedBlank2) case .Err(let wsErr))
			{
				
				return .Err(wsErr);
			}

			if (mCursor.PeekByte() == ']')
			{
				mCursor.AdvanceByte();
				// Flush any pending comments to the last element (e.g., trailing comment without comma)
				if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
				{
					TomlNodeId lastId = .Invalid;
					if (arr.MetadataContext != null)
						arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
					if (lastId.IsValid)
					{
						let commentSet = mStyle.GetOrCreateCommentSet(lastId);
						if (commentSet != null)
						{
							for (int ci = 0; ci < arrayPendingComments.Count; ci++)
								commentSet.mLeading.Add(arrayPendingComments[ci]);
							arrayPendingComments.Clear();
						}
					}
				}
				FinishArrayLayout(arr, ref layout, lastLine);
				return TomlValue.Array(arr);
			}

			// Check the item count before parsing another item, not after building it
			Try!(CheckArrayItem(arr));
			// Mark value start for raw token capture. Containers record their layout while they are parsed
			// (mLastArrayFormat, mLastTableFormat), so their text is not needed or retained.
			var elemStart = TomlCursorMark();
			bool elemMarked = mStyle != null && !IsContainerStart(mCursor.PeekByte());
			if (elemMarked)
				elemStart = mCursor.Mark();
			let elemLine = mCursor.Line;
			let elemColumn = mCursor.Column;
			let elemOffset = mCursor.Offset;
			if (elemLine != lastLine)
			{
				layout.mStyle = .Multiline;
				if (!indentKnown)
				{
					indentKnown = true;
					NoteContainerIndent(ref layout.mIndentSize, elemColumn - 1);
				}
			}

			int elemEnd = 0;
			switch (ParseValue())
			{
			case .Err(let valErr):

				return .Err(valErr);
			case .Ok(let val):
				elemEnd = mCursor.Offset;
				arr.Add(val);
				// Give the element a node ID (and, in PreserveStyle, capture its token and format)
				if (mMetadata != null)
					CaptureArrayElement(arr, val, elemStart, elemMarked);
			}
			lastLine = mCursor.Line;

			// Get node ID for this element for comment attachment
			TomlNodeId elemNodeId = .Invalid;
			if (arr.MetadataContext != null)
				arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out elemNodeId);
			RecordSourceRange(elemNodeId, elemLine, elemColumn, elemOffset, elemEnd);

			// Flush pending comments as leading comments for this element
			if (arrayPendingComments != null && arrayPendingComments.Count > 0 && elemNodeId.IsValid)
			{
				let commentSet = mStyle.GetOrCreateCommentSet(elemNodeId);
				if (commentSet != null)
				{
					for (int ci = 0; ci < arrayPendingComments.Count; ci++)
						commentSet.mLeading.Add(arrayPendingComments[ci]);
					arrayPendingComments.Clear();
				}
			}
			// Set blank line flag from array-level tracking (e.g., blank line before this element)
			if (arraySawBlankLine && elemNodeId.IsValid && mStyle != null)
			{
				let commentSet = mStyle.GetOrCreateCommentSet(elemNodeId);
				if (commentSet != null)
					commentSet.mSeparatedByBlankLine = true;
				arraySawBlankLine = false;
			}

			// Skip whitespace/newlines after value and capture trailing content
			bool afterValBlank = false;
			if (SkipWsAndCaptureComments(arrayPendingComments, out afterValBlank) case .Err(let trailErr))
			{
				
				return .Err(trailErr);
			}

			char8 afterValB = mCursor.PeekByte();
			if (afterValB == ',')
			{
				if (mCursor.Line != lastLine)
					layout.mStyle = .Multiline;
				mCursor.AdvanceByte();
				lastLine = mCursor.Line;
				// After comma, capture any trailing comment on same line
				mCursor.SkipWhitespace();
				if (!mCursor.IsEOF && mCursor.PeekByte() == '#')
				{
					if (mStyle == null)
						Try!(SkipCommentText());
					else
					{
						let trailingText = Try!(CaptureComment());
						if (elemNodeId.IsValid)
						{
							let commentSet = mStyle.GetOrCreateCommentSet(elemNodeId);
							if (commentSet != null)
								commentSet.mTrailing = trailingText;
						}
					}
				}

				// Capture ws/comments between elements (leading for next element)
				bool afterCommaBlank = false;
				if (SkipWsAndCaptureComments(arrayPendingComments, out afterCommaBlank) case .Err(let commaWsErr))
				{
					
					return .Err(commaWsErr);
				}
				// Track blank line for the next element
				if (afterCommaBlank)
					arraySawBlankLine = true;
				if (mCursor.PeekByte() == ']')
				{
					layout.mTrailingComma = true;
					mCursor.AdvanceByte();
					// Flush pending comments to the last element
					if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
					{
						TomlNodeId lastId = .Invalid;
						if (arr.MetadataContext != null)
							arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
						if (lastId.IsValid)
						{
							let commentSet = mStyle.GetOrCreateCommentSet(lastId);
							if (commentSet != null)
							{
								for (int ci = 0; ci < arrayPendingComments.Count; ci++)
									commentSet.mLeading.Add(arrayPendingComments[ci]);
								arrayPendingComments.Clear();
							}
						}
					}
					FinishArrayLayout(arr, ref layout, lastLine);
					return TomlValue.Array(arr);
				}
				continue;
			}
			else if (afterValB == ']')
			{
				mCursor.AdvanceByte();
				// Flush pending comments to the last element (e.g., trailing comment without comma)
				if (arrayPendingComments != null && arrayPendingComments.Count > 0 && arr.Count > 0)
				{
					TomlNodeId lastId = .Invalid;
					if (arr.MetadataContext != null)
						arr.MetadataContext.TryGetItemNodeId(arr.Count - 1, out lastId);
					if (lastId.IsValid)
					{
						let commentSet = mStyle.GetOrCreateCommentSet(lastId);
						if (commentSet != null)
						{
							for (int ci = 0; ci < arrayPendingComments.Count; ci++)
								commentSet.mLeading.Add(arrayPendingComments[ci]);
							arrayPendingComments.Clear();
						}
					}
				}
				FinishArrayLayout(arr, ref layout, lastLine);
				return TomlValue.Array(arr);
			}
			else
			{
				
				return .Err(Error(.UnexpectedToken, "Expected ',' or ']' in array"));
			}
		}
	}

	/// ParseArray without metadata: no positions, comments or style to record, so each element is
	/// just whitespace, value, whitespace, then ',' or ']'. The opening '[' is already consumed.
	private Result<TomlValue, TomlParseError> ParsePlainArray(TomlArray arr)
	{
		// The loop top is reached only after '[' or ',', the two places where ']' may follow
		while (true)
		{
			Try!(SkipWsAndComments());
			if (mCursor.PeekByte() == ']')
			{
				mCursor.AdvanceByte();
				return TomlValue.Array(arr);
			}
			// Check the item count before parsing another item, not after building it
			Try!(CheckArrayItem(arr));
			let val = Try!(ParseValue());
			arr.Add(val);

			Try!(SkipWsAndComments());
			switch (mCursor.PeekByte())
			{
			case ',':
				mCursor.AdvanceByte();
			case ']':
				mCursor.AdvanceByte();
				return TomlValue.Array(arr);
			default:
				return .Err(Error(.UnexpectedToken, "Expected ',' or ']' in array"));
			}
		}
	}

	/// Ensure the array has a metadata context allocated.
	private void EnsureArrayContext(TomlArray arr)
	{
		if (mMetadata != null && arr.MetadataContext == null)
		{
			let ctxNodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext = new TomlContainerMetadataContext(mMetadata, ctxNodeId, true);
		}
	}

	// ================================================================
	// Inline table parsing
	// ================================================================

	private Result<TomlValue, TomlParseError> ParseInlineTable()
	{
		mCursor.AdvanceByte();
		TomlTable tbl = mStore.NewTable(.InlineTable);
		// With metadata, give the table a context up front so each field gets a node ID (and dotted
		// sub-tables inherit contexts through Insert) before its range and format are recorded.
		if (mMetadata != null)
			tbl.MetadataContext = new TomlContainerMetadataContext(mMetadata, mMetadata.AllocateNodeId(), false);

		// Comments can only appear inside inline tables in TOML 1.1 (they need newlines). In PreserveStyle
		// they are collected here and attached: lines above a field become its leading comments, a comment
		// on the field's own line its trailing comment, and comments before `}` the table's closing comments.
		List<StringView> pendingComments = (mStyle != null && mVersion != .V1_0) ? scope:: List<StringView>() : null;

		// Layout (PreserveStyle), recorded at the table's own separators as for arrays (see ParseArray):
		// spacing inside the braces, around '=' and after ',', multi-line and the entry indent. lastEnd is
		// where the previous separator or value ended.
		var layout = TomlTableFormat() { mInline = true, mEqualsSpacing = 0, mCommaSpacing = 0 };
		bool indentKnown = false;
		int lastLine = mCursor.Line;
		int lastEnd = mCursor.Offset;
		if (mStyle != null)
		{
			char8 afterBrace = mCursor.PeekByte();
			if (afterBrace == ' ' || afterBrace == '\t' || afterBrace == '\r' || afterBrace == '\n')
				layout.mOpenBraceSpacing = 1;
		}

		Try!(SkipInlineTableWs(pendingComments));
		if (mCursor.PeekByte() == '}')
		{
			FinishTableLayout(ref layout, lastLine, lastEnd);
			mCursor.AdvanceByte();
			FlushCommentsToLeading(pendingComments, tbl.MetadataContext?.mNodeId ?? .Invalid);
			tbl.SealInlineRecursively();
			return TomlValue.Table(tbl);
		}

		while (true)
		{
			Try!(SkipInlineTableWs(pendingComments));

			let fieldLine = mCursor.Line;
			let fieldColumn = mCursor.Column;
			let fieldOffset = mCursor.Offset;
			if (fieldLine != lastLine)
			{
				layout.mMultiline = true;
				if (!indentKnown)
				{
					indentKnown = true;
					NoteContainerIndent(ref layout.mEntryIndent, fieldColumn - 1);
				}
			}
			// Key style only depends on the key's first byte
			TomlKeyStyle keyStyle = .Bare;
			if (mStyle != null)
			{
				char8 first = mCursor.PeekByte();
				if (first == '"')
					keyStyle = .QuotedBasic;
				else if (first == '\'')
					keyStyle = .QuotedLiteral;
			}

			let keyPathBuffer = AcquireKeyPath();
			defer ReleaseKeyPath();
			let keyPath = keyPathBuffer.mParts;
			if (ParseKeyPath(keyPathBuffer) case .Err(let keyErr))
				return .Err(keyErr);

			mCursor.SkipWhitespace();
			if (mCursor.PeekByte() != '=')
				return .Err(Error(.UnexpectedToken, "Expected '=' in inline table"));
			if (mCursor.Offset > mLastKeyEnd)
				layout.mEqualsSpacing = 1;
			mCursor.AdvanceByte();
			if (mCursor.PeekByte() == ' ' || mCursor.PeekByte() == '\t')
				layout.mEqualsSpacing = 1;

			mCursor.SkipWhitespace();

			// A full table fails before its new value is parsed
			if (keyPath.Count == 1)
				Try!(CheckTableEntry(tbl));

			// Only scalars need their token; containers record their layout as they are parsed
			var valueStart = TomlCursorMark();
			char8 valueFirst = mCursor.PeekByte();
			bool valueMarked = mStyle != null && !IsContainerStart(valueFirst);
			if (valueMarked)
				valueStart = mCursor.Mark();

			TomlValue val;
			mKeyDepth += keyPath.Count - 1;
			let parsedValue = ParseValue();
			mKeyDepth -= keyPath.Count - 1;
			switch (parsedValue)
			{
			case .Err(let valErr):
				return .Err(valErr);
			case .Ok(let parsed):
				val = parsed;
			}

			TomlTable target = tbl;
			if (keyPath.Count == 1)
			{
				if (tbl.ContainsKey(keyPath[0]))
					return .Err(Error(.DuplicateKey, "Duplicate key in inline table"));
				tbl.Insert(keyPath[0], val);
			}
			else
			{
				switch (InsertDottedKeyIntoTable(tbl, keyPath, val))
				{
				case .Err(let insertErr):
					return .Err(insertErr);
				case .Ok(let inserted):
					target = inserted;
				}
			}

			// Record the field's range, and in PreserveStyle its token and formats, against its node ID.
			// Slicing releases the mark.
			TomlNodeId fieldNodeId = .Invalid;
			if (mMetadata != null)
			{
				target.TryGetEntryNodeId(keyPath[keyPath.Count - 1], out fieldNodeId);
				RecordSourceRange(fieldNodeId, fieldLine, fieldColumn, fieldOffset, mCursor.Offset);
			}
			if (mStyle != null)
			{
				String scratch = scope String();
				StringView rawToken = valueMarked ? mCursor.Slice(valueStart, scratch) : default;
				CaptureValueMetadata(fieldNodeId, val, rawToken, keyStyle, keyPath.Count > 1);
			}
			lastLine = mCursor.Line;
			lastEnd = ValueEnd(valueFirst);
			FlushCommentsToLeading(pendingComments, fieldNodeId);

			// A comment on the field's own line, before any comma: `a = 1 # note`
			Try!(CaptureInlineTrailingComment(pendingComments, fieldNodeId));
			Try!(SkipInlineTableWs(pendingComments));

			char8 b = mCursor.PeekByte();
			if (b == ',')
			{
				if (mCursor.Line != lastLine)
					layout.mMultiline = true;
				mCursor.AdvanceByte();
				if (mCursor.PeekByte() == ' ' || mCursor.PeekByte() == '\t')
					layout.mCommaSpacing = 1;
				lastLine = mCursor.Line;
				lastEnd = mCursor.Offset;
				mCursor.SkipWhitespace();
				// Trailing comma: reject in v1.0
				if (mVersion == .V1_0 && mCursor.PeekByte() == '}')
				{
					return .Err(Error(.UnexpectedToken,
						"Trailing comma in inline table requires TOML v1.1"));
				}
				// A comment on the field's line after its comma: `a = 1, # note`
				Try!(CaptureInlineTrailingComment(pendingComments, fieldNodeId));
				Try!(SkipInlineTableWs(pendingComments));
				if (mCursor.PeekByte() == '}')
				{
					layout.mTrailingComma = true;
					FinishTableLayout(ref layout, lastLine, lastEnd);
					mCursor.AdvanceByte();
					break;
				}
				continue;
			}
			else if (b == '}')
			{
				FinishTableLayout(ref layout, lastLine, lastEnd);
				mCursor.AdvanceByte();
				break;
			}
			else
			{
				return .Err(Error(.UnexpectedToken, "Expected ',' or '}' in inline table"));
			}
		}

		// Comments after the last field belong to the closing brace
		FlushCommentsToLeading(pendingComments, tbl.MetadataContext?.mNodeId ?? .Invalid);
		tbl.SealInlineRecursively();
		return TomlValue.Table(tbl);
	}

	/// Skips whitespace, newlines (1.1) and comments inside an inline table. With `pendingComments`
	/// (PreserveStyle on 1.1) comment text is collected instead of discarded.
	private Result<void, TomlParseError> SkipInlineTableWs(List<StringView> pendingComments)
	{
		if (pendingComments == null)
			return SkipWsAndComments(mVersion != .V1_0);
		return SkipWsAndCaptureComments(pendingComments, let _);
	}

	/// If a comment follows on the current line, records it as `nodeId`'s trailing comment.
	private Result<void, TomlParseError> CaptureInlineTrailingComment(List<StringView> pendingComments, TomlNodeId nodeId)
	{
		if (pendingComments == null)
			return .Ok;
		mCursor.SkipWhitespace();
		if (mCursor.IsEOF || mCursor.PeekByte() != '#')
			return .Ok;
		let text = Try!(CaptureComment());
		if (nodeId.IsValid)
			mStyle.GetOrCreateCommentSet(nodeId).mTrailing = text;
		return .Ok;
	}

	/// Moves collected comments onto `nodeId` as leading comments.
	private void FlushCommentsToLeading(List<StringView> pendingComments, TomlNodeId nodeId)
	{
		if (pendingComments == null || pendingComments.IsEmpty || !nodeId.IsValid)
			return;
		let commentSet = mStyle.GetOrCreateCommentSet(nodeId);
		for (let text in pendingComments)
			commentSet.mLeading.Add(text);
		pendingComments.Clear();
	}

	/// Inserts `value` at a dotted key path inside an inline table, creating intermediate inline tables.
	/// Returns the table that received the final key.
	private Result<TomlTable, TomlParseError> InsertDottedKeyIntoTable(TomlTable tbl, List<String> keyPath, TomlValue value)
	{
		TomlTable current = tbl;
		for (int i = 0; i < keyPath.Count - 1; i++)
		{
			StringView key = keyPath[i];
			if (current.TryGetValue(key, let existing))
			{
				if (existing case .Table(let existingTable))
				{
					// Cannot navigate into sealed inline tables
					if (existingTable.IsInlineSealed)
						return .Err(Error(.InlineTableSealed, scope $"Cannot add keys to sealed inline table via dotted key '{key}'"));
					current = existingTable;
				}
				else
				{
					// Type conflict: dotted key segment is not a table
					String msg = scope String();
					msg.AppendF("Key '{}' is not a table — cannot use dotted key path through it", key);
					return .Err(Error(.TypeConflict, msg));
				}
			}
			else
			{
				Try!(CheckNodeCount());
				TomlTable newTbl = mStore.NewTable(.InlineTable);
				Try!(CheckTableEntry(current));
				current.Insert(key, TomlValue.Table(newTbl));
				current = newTbl;
			}
		}

		StringView finalKey = keyPath[keyPath.Count - 1];
		if (current.ContainsKey(finalKey))
			return .Err(Error(.DuplicateKey, scope $"Duplicate key '{finalKey}' in inline table"));
		Try!(CheckTableEntry(current));
		current.Insert(finalKey, value);
		return .Ok(current);
	}
}
