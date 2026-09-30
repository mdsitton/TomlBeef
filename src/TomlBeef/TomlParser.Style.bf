using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlParserImpl: PreserveStyle capture (source ranges, value/key/container formats, document style).
extension TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	/// Records where a node appeared in the source: its start (key, header `[`, or array element value)
	/// and the length through the end of its value or header.
	private void RecordSourceRange(TomlNodeId nodeId, int line, int column, int offset, int endOffset)
	{
		if (mMetadata != null)
			mMetadata.SetSourceRange(nodeId, line, column, offset, Math.Max(endOffset - offset, 0), mSourceIndex);
	}

	/// Record PreserveStyle metadata for a parsed key/value: the original token for strings, the value
	/// format for numbers, date/times, arrays and inline tables, and the key format.
	private void CaptureValueMetadata(TomlNodeId nodeId, TomlValue value, StringView rawToken, TomlKeyStyle keyStyle, bool isDotted)
	{
		if (mStyle == null || !nodeId.IsValid)
			return;
		CaptureValueFormat(nodeId, value, rawToken);
		CaptureKeyFormat(nodeId, keyStyle, isDotted);
	}

	/// Capture the value's own token and format (a key's value or an array element).
	private void CaptureValueFormat(TomlNodeId nodeId, TomlValue value, StringView rawToken)
	{
		if (value.IsString)
		{
			let tokenRef = mStyle.AddOriginalToken(rawToken);
			let style = mStyle.GetNodeStyle(nodeId);
			if (style != null)
				style.mOriginalValueToken = tokenRef;
			CaptureStringFormat(nodeId, rawToken);
		}
		else if (value.IsInteger || value.IsFloat)
			CaptureNumericFormat(nodeId, rawToken);
		else if (value.IsArray || value.IsTable)
			RecordContainerFormat(nodeId, value);
		else if (value.IsOffsetDateTime || value.IsLocalDateTime || value.IsLocalDate || value.IsLocalTime)
			CaptureDateTimeFormat(nodeId, rawToken);
	}

	/// Capture string format metadata for a parsed string value.
	private void CaptureStringFormat(TomlNodeId nodeId, StringView rawToken)
	{
		if (mStyle == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		var fmt = TomlStringFormat();

		char8 first = rawToken[0];
		if (first == '"' && rawToken.Length >= 3 && rawToken[1] == '"' && rawToken[2] == '"')
		{
			fmt.mStyle = .MultilineBasic;
			// Check for newline after opening quotes
			if (rawToken.Length >= 4 && (rawToken[3] == '\n' || rawToken[3] == '\r'))
				fmt.mStartsWithNewline = true;
		}
		else if (first == '"')
		{
			fmt.mStyle = .Basic;
		}
		else if (first == '\'' && rawToken.Length >= 3 && rawToken[1] == '\'' && rawToken[2] == '\'')
		{
			fmt.mStyle = .MultilineLiteral;
			if (rawToken.Length >= 4 && (rawToken[3] == '\n' || rawToken[3] == '\r'))
				fmt.mStartsWithNewline = true;
		}
		else if (first == '\'')
		{
			fmt.mStyle = .Literal;
		}

		// Detect escapes in basic strings
		if (fmt.mStyle == .Basic || fmt.mStyle == .MultilineBasic)
		{
			for (int i = 1; i < rawToken.Length - 1; i++)
			{
				if (rawToken[i] == '\\') { fmt.mHadEscapes = true; break; }
			}
		}

		let valueFormat = mStyle.AddValueFormat(.String(fmt));
		let style = mStyle.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = valueFormat;
	}

	/// Detect numeric format metadata from a raw token string.
	private void CaptureNumericFormat(TomlNodeId nodeId, StringView rawTokenIn)
	{
		// A bare value is scanned up to a delimiter such as '#', so the slice can end in whitespace
		StringView rawToken = rawTokenIn;
		rawToken.Trim();
		if (mStyle == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		// Detect special float sign style
		TomlFloatSpecialSign specialSign = .None;
		int pos = 0;
		if (pos < rawToken.Length && rawToken[pos] == '+')
		{
			specialSign = .ExplicitPlus;
			pos++;
		}
		else if (pos < rawToken.Length && rawToken[pos] == '-')
		{
			specialSign = .Minus;
			pos++;
		}

		// Check for special floats (inf, nan) before checking for 0x/0o/0b prefix
		if (pos < rawToken.Length)
		{
			let body = rawToken.Substring(pos);
			if (body == "inf" || body == "nan")
			{
				var fmt = TomlFloatFormat();
				fmt.mStyle = .Special;
				fmt.mSpecialSign = specialSign;
				let fmtRef = mStyle.AddValueFormat(.Float(fmt));
				let style = mStyle.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
		}
		// Reset pos for normal number detection. For non-special floats
		// we need to re-parse including sign because the sign is part of the
		// semantic value.
		pos = 0;
		if (pos < rawToken.Length && (rawToken[pos] == '+' || rawToken[pos] == '-'))
			pos++;


		if (pos + 1 < rawToken.Length && rawToken[pos] == '0')
		{
			char8 next = rawToken[pos + 1];
			if (next == 'x' || next == 'X')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Hex;
				fmt.mUppercaseDigits = (next == 'X');
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				// Check for uppercase hex digits
				if (!fmt.mUppercaseDigits)
				{
					for (int i = pos + 2; i < rawToken.Length; i++)
					{
						char8 c = rawToken[i];
						if (c >= 'A' && c <= 'F') { fmt.mUppercaseDigits = true; break; }
					}
				}
				let fmtRef = mStyle.AddValueFormat(.Integer(fmt));
				let style = mStyle.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
			if (next == 'o' || next == 'O')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Octal;
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				let fmtRef = mStyle.AddValueFormat(.Integer(fmt));
				let style = mStyle.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
			if (next == 'b' || next == 'B')
			{
				var fmt = TomlIntegerFormat();
				fmt.mBase = .Binary;
				DetectUnderscoreGrouping(rawToken, pos + 2, ref fmt);
				DetectMinimumDigits(rawToken, pos + 2, ref fmt);
				let fmtRef = mStyle.AddValueFormat(.Integer(fmt));
				let style = mStyle.GetNodeStyle(nodeId);
				if (style != null) style.mValueFormatRef = fmtRef;
				return;
			}
		}

		// Check for float indicators
		bool hasDot = false;
		bool hasExp = false;
		for (int i = pos; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == '.') hasDot = true;
			if (c == 'e' || c == 'E') { hasExp = true; break; }
		}

		if (hasDot || hasExp)
		{
			var fmt = TomlFloatFormat();
			DetectFloatPrecision(rawToken, pos, ref fmt);
			if (hasExp)
			{
				fmt.mStyle = .Scientific;
				for (int i = pos; i < rawToken.Length; i++)
				{
					if (rawToken[i] == 'E') { fmt.mUppercaseExponent = true; break; }
					if (rawToken[i] == 'e') { fmt.mUppercaseExponent = false; break; }
				}
				// Check for explicit + in exponent and count exponent digits
				for (int i = pos; i < rawToken.Length - 1; i++)
				{
					if (rawToken[i] == 'e' || rawToken[i] == 'E')
					{
						int expStart = i + 1;
						if (expStart < rawToken.Length && (rawToken[expStart] == '+' || rawToken[expStart] == '-'))
						{
							if (rawToken[expStart] == '+')
								fmt.mExplicitPlusExponent = true;
							expStart++;
						}
						// Count exponent digits
						int digitCount = 0;
						for (int j = expStart; j < rawToken.Length; j++)
						{
							if (TomlChar.IsDigit(rawToken[j]))
								digitCount++;
							else
								break;
						}
						if (digitCount > 0)
							fmt.mExponentDigits = (uint8)digitCount;
						break;
					}
				}
			}
			else
			{
				fmt.mStyle = .Decimal;
			}
			// Detect underscore grouping in integer and fractional parts
			DetectFloatUnderscoreGrouping(rawToken, pos, ref fmt);
			let fmtRef = mStyle.AddValueFormat(.Float(fmt));
			let style = mStyle.GetNodeStyle(nodeId);
			if (style != null) style.mValueFormatRef = fmtRef;
			return;
		}

		// Plain decimal integer
		{
			var fmt = TomlIntegerFormat();
			fmt.mBase = .Decimal;
			DetectUnderscoreGrouping(rawToken, pos, ref fmt);
			let fmtRef = mStyle.AddValueFormat(.Integer(fmt));
			let style = mStyle.GetNodeStyle(nodeId);
			if (style != null) style.mValueFormatRef = fmtRef;
		}
	}

	/// Detect fractional precision in a float token, ignoring underscores.
	private void DetectFloatPrecision(StringView rawToken, int start, ref TomlFloatFormat fmt)
	{
		fmt.mPrecision = -1;
		for (int i = start; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '.')
			{
				int digits = 0;
				for (int j = i + 1; j < rawToken.Length; j++)
				{
					char8 c = rawToken[j];
					if (c == 'e' || c == 'E') break;
					if (c != '_') digits++;
				}
				fmt.mPrecision = (int16)digits;
				return;
			}
			if (rawToken[i] == 'e' || rawToken[i] == 'E')
			{
				fmt.mPrecision = 0;
				return;
			}
		}
	}

	/// Detect underscore grouping in an integer token starting at digitStart.
	private void DetectUnderscoreGrouping(StringView rawToken, int digitStart, ref TomlIntegerFormat fmt)
	{
		for (int i = digitStart; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '_')
			{
				fmt.mUseUnderscores = true;
				// Detect group size: count digits after this underscore until next underscore or end
				int groupSize = 0;
				for (int j = i + 1; j < rawToken.Length && rawToken[j] != '_'; j++)
					groupSize++;
				if (groupSize > 0)
					fmt.mGroupSize = (uint8)groupSize;
				break;
			}
		}
	}

	/// Detect minimum digit width for prefixed integer tokens, ignoring underscores.
	private void DetectMinimumDigits(StringView rawToken, int digitStart, ref TomlIntegerFormat fmt)
	{
		int digitCount = 0;
		for (int i = digitStart; i < rawToken.Length; i++)
		{
			if (rawToken[i] != '_')
				digitCount++;
		}
		if (digitCount > 0 && digitCount <= 255)
			fmt.mMinDigits = (uint8)digitCount;
	}

	/// Detect underscore grouping in the integer and fractional parts of a float token.
	private void DetectFloatUnderscoreGrouping(StringView rawToken, int start, ref TomlFloatFormat fmt)
	{
		// Find the decimal point
		int dotPos = -1;
		int ePos = -1;
		for (int i = start; i < rawToken.Length; i++)
		{
			if (rawToken[i] == '.') { dotPos = i; }
			if (rawToken[i] == 'e' || rawToken[i] == 'E') { ePos = i; break; }
		}

		// Integer part: from start to dotPos or ePos
		int intEnd = (dotPos >= 0) ? dotPos : ((ePos >= 0) ? ePos : rawToken.Length);
		bool foundIntUnderscore = false;
		for (int i = start; i < intEnd; i++)
		{
			if (rawToken[i] == '_') { foundIntUnderscore = true; break; }
		}

		// Detect integer group size (last underscore before dot or exponent)
		if (foundIntUnderscore)
		{
			fmt.mUseUnderscores = true;
			// Find the last underscore in the integer part
			int lastUnderscore = -1;
			for (int i = start; i < intEnd; i++)
			{
				if (rawToken[i] == '_') lastUnderscore = i;
			}
			if (lastUnderscore >= 0)
			{
				int groupSize = 0;
				for (int j = lastUnderscore + 1; j < intEnd; j++)
					groupSize++;
				if (groupSize > 0)
					fmt.mIntGroupSize = (uint8)groupSize;
			}
		}

		// Fractional part: after dot, before exponent
		if (dotPos >= 0)
		{
			int fracEnd = (ePos >= 0) ? ePos : rawToken.Length;
			bool foundFracUnderscore = false;
			for (int i = dotPos + 1; i < fracEnd; i++)
			{
				if (rawToken[i] == '_') { foundFracUnderscore = true; break; }
			}
			if (foundFracUnderscore)
			{
				fmt.mUseUnderscores = true;
				int firstUnderscore = -1;
				for (int i = dotPos + 1; i < fracEnd; i++)
				{
					if (rawToken[i] == '_') { firstUnderscore = i; break; }
				}
				if (firstUnderscore >= 0)
				{
					int groupSize = firstUnderscore - (dotPos + 1);
					if (groupSize > 0)
						fmt.mFracGroupSize = (uint8)groupSize;
				}
			}
		}
	}

	// ================================================================
	// Key and container format capture
	// ================================================================

	/// Store key format metadata from pre-detected style and dotted path preference.
	private void CaptureKeyFormat(TomlNodeId nodeId, TomlKeyStyle keyStyle, bool isDotted)
	{
		if (mStyle == null || !nodeId.IsValid)
			return;

		var fmt = TomlKeyFormat();
		fmt.mStyle = keyStyle;
		if (isDotted)
			fmt.mPreferDottedPath = true;

		let fmtRef = mStyle.AddKeyFormat(fmt);
		let style = mStyle.GetNodeStyle(nodeId);
		if (style != null)
			style.mKeyFormatRef = fmtRef;
	}

	/// Detect date-time format metadata from a raw token.
	private void CaptureDateTimeFormat(TomlNodeId nodeId, StringView rawTokenIn)
	{
		// A bare value is scanned up to a delimiter such as '#', so the slice can end in whitespace
		// (which would otherwise be mistaken for a space date-time separator)
		StringView rawToken = rawTokenIn;
		rawToken.Trim();
		if (mStyle == null || !nodeId.IsValid || rawToken.Length == 0)
			return;

		var fmt = TomlDateTimeFormat();

		// Detect separator style (T vs t vs space)
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T' || c == 't' || c == ' ') { fmt.mSeparator = c; break; }
		}

		// Detect offset style (Z vs +00:00)
		// Only scan after the time separator to avoid matching date dashes
		int timeSepPos = -1;
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T' || c == 't' || c == ' ') { timeSepPos = i; break; }
		}
		if (timeSepPos >= 0 && timeSepPos < rawToken.Length - 1)
		{
			for (int i = rawToken.Length - 1; i > timeSepPos; i--)
			{
				char8 c = rawToken[i];
				if (c == 'Z' || c == 'z') { fmt.mUsesZ = true; fmt.mLowercaseZ = c == 'z'; fmt.mHasOffset = true; break; }
				if (c == '+' || c == '-') { fmt.mUsesZ = false; fmt.mHasOffset = true; break; }
			}
		}

		// Detect seconds and fractional digits
		// Find the time separator first, then count colons only in the time component
		int timeStart = 0;
		for (int i = 0; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			if (c == 'T' || c == 't' || c == ' ') { timeStart = i + 1; break; }
		}
		int colonCount = 0;
		int fracDigits = 0;
		for (int i = timeStart; i < rawToken.Length; i++)
		{
			char8 c = rawToken[i];
			// Stop at timezone offset indicators
			if (c == 'Z' || c == 'z' || (i > timeStart && (c == '+' || c == '-'))) break;
			if (c == ':') colonCount++;
			if (c == '.')
			{
				// Count fractional digits
				for (int j = i + 1; j < rawToken.Length && TomlChar.IsDigit(rawToken[j]); j++)
					fracDigits++;
				break;
			}
		}
		fmt.mHasSeconds = colonCount >= 2;
		fmt.mFractionalDigits = (uint8)fracDigits;

		let fmtRef = mStyle.AddValueFormat(.DateTime(fmt));
		let style = mStyle.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = fmtRef;
	}

	// Container layout. ParseArray and ParseInlineTable record it at their own separators while they
	// parse: whether a newline separates them, the column of the first entry that starts a line, the
	// spacing around braces, '=' and ','. Reading it back from the container's text instead needed that
	// whole text (retained across stream refills) and could not tell the container's own newlines and
	// indentation from those of nested values or of punctuation inside strings.

	/// Whether a value starting with `b` is an array or inline table (whose layout is recorded while it
	/// is parsed, so no mark is needed for its text).
	[Inline]
	private static bool IsContainerStart(char8 b) => b == '[' || b == '{';

	/// Records a container's entry indent: `count` is the column (from 0) of its first entry that starts
	/// a line. The first such indent in the document also becomes its indent size.
	private void NoteContainerIndent(ref uint8 indent, int count)
	{
		if (mStyle == null)
			return;
		if (count > 0 && count <= 255)
			indent = (uint8)count;
		NoteIndentSize(count);
	}

	/// Completes the layout of the array whose ']' was just consumed (PreserveStyle): counts it for the
	/// document's dominant array style, and leaves it in mLastArrayFormat, which the caller records
	/// against the array's node right after ParseValue returns (nested arrays finished earlier).
	private void FinishArrayLayout(TomlArray arr, ref TomlArrayFormat layout, int lastLine)
	{
		if (mStyle == null)
			return;
		if (mCursor.Line != lastLine)
			layout.mStyle = .Multiline;
		if (layout.mStyle == .Multiline)
		{
			mArrayStyleCount_Multiline++;
			if (arr.Count > 0)
			{
				if (layout.mTrailingComma)
					mArrayTrailingCommaCount++;
				else
					mArrayNoTrailingCommaCount++;
			}
		}
		else
			mArrayStyleCount_Inline++;
		if (layout.mIndentSize == 0)
			layout.mIndentSize = mStyle.mDocumentStyle.mIndentSize;
		mLastArrayFormat = layout;
	}

	/// Completes the layout of the inline table whose '}' is next (PreserveStyle) and leaves it in
	/// mLastTableFormat, as FinishArrayLayout does. `lastEnd` is where the last value or ',' ended.
	private void FinishTableLayout(ref TomlTableFormat layout, int lastLine, int lastEnd)
	{
		if (mStyle == null)
			return;
		if (mCursor.Line != lastLine)
			layout.mMultiline = true;
		else if (mCursor.Offset > lastEnd)
			layout.mCloseBraceSpacing = 1;
		mLastTableFormat = layout;
	}

	/// Records the layout the container just parsed left (see FinishArrayLayout) as `nodeId`'s format.
	private void RecordContainerFormat(TomlNodeId nodeId, TomlValue value)
	{
		let fmtRef = mStyle.AddValueFormat(value.IsArray ? .Array(mLastArrayFormat) : .Table(mLastTableFormat));
		let style = mStyle.GetNodeStyle(nodeId);
		if (style != null)
			style.mValueFormatRef = fmtRef;
	}

	/// Give the element just added to `arr` a node ID and, in PreserveStyle, capture its token and format.
	/// `elemStart` is only marked (and must then be sliced or released) when `marked`.
	private void CaptureArrayElement(TomlArray arr, TomlValue val, TomlCursorMark elemStart, bool marked)
	{
		if (mMetadata == null)
			return;

		// Ensure the array has a metadata context
		if (arr.MetadataContext == null)
		{
			let ctxNodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext = new TomlContainerMetadataContext(mMetadata, ctxNodeId, true);
		}

		// Reuse node ID if Add() already allocated one, otherwise allocate new
		TomlNodeId nodeId;
		if (arr.MetadataContext.mItemNodeIds != null && arr.MetadataContext.mItemNodeIds.Count >= arr.Count)
		{
			// Add() already allocated a node ID for this element
			nodeId = arr.MetadataContext.mItemNodeIds[arr.Count - 1];
		}
		else
		{
			nodeId = mMetadata.AllocateNodeId();
			arr.MetadataContext.AddItemNodeId(nodeId);
		}

		if (mStyle == null)
			return;

		if (!marked)
		{
			CaptureValueFormat(nodeId, val, default);
			return;
		}
		if (val.IsBool)
		{
			// No format to capture, but the mark must be released
			mCursor.ReleaseMark(elemStart);
			return;
		}
		String scratch = scope String();
		CaptureValueFormat(nodeId, val, mCursor.Slice(elemStart, scratch));
	}

	/// Count a string style occurrence for document-level inference.
	/// Called from all string parse methods, not just key/val paths.
	private void CountStringStyle(TomlStringStyle style)
	{
		if (mStyle == null)
			return;
		switch (style)
		{
		case .Basic: mStringStyleCount_Basic++;
		case .Literal: mStringStyleCount_Literal++;
		case .MultilineBasic: mStringStyleCount_MultilineBasic++;
		case .MultilineLiteral: mStringStyleCount_MultilineLiteral++;
		}
	}

	// ================================================================
	// Document style inference
	// ================================================================

	/// Records the document's indentation character from the first indented container line seen.
	private void NoteIndentChar(char8 c)
	{
		if (mIndentCharKnown || mStyle == null)
			return;
		mIndentCharKnown = true;
		mStyle.mDocumentStyle.mUseTabs = c == '\t';
	}

	/// Records the document's indent size (in characters: with tabs, 1 means one tab) from the first
	/// indented array or inline-table entry, unless an indented top-level line already set it. New
	/// containers are indented with it.
	private void NoteIndentSize(int count)
	{
		if (mIndentSizeKnown || mInferredIndentFromContent || mStyle == null || count <= 0 || count > 255)
			return;
		mIndentSizeKnown = true;
		mStyle.mDocumentStyle.mIndentSize = (uint8)count;
	}

	/// Infer document-level style from accumulated parsing state.
	/// Called once at the end of ParseDocument.
	private void InferDocumentStyle()
	{
		if (mStyle == null)
			return;

		// Determine dominant string style
		int maxCount = mStringStyleCount_Basic;
		var dominant = TomlStringStyle.Basic;

		if (mStringStyleCount_Literal > maxCount)
		{
			maxCount = mStringStyleCount_Literal;
			dominant = .Literal;
		}
		if (mStringStyleCount_MultilineBasic > maxCount)
		{
			maxCount = mStringStyleCount_MultilineBasic;
			dominant = .MultilineBasic;
		}
		if (mStringStyleCount_MultilineLiteral > maxCount)
		{
			maxCount = mStringStyleCount_MultilineLiteral;
			dominant = .MultilineLiteral;
		}

		mStyle.mDocumentStyle.mDefaultStringStyle = dominant;

		// Determine dominant array style
		if (mArrayStyleCount_Multiline > mArrayStyleCount_Inline)
			mStyle.mDocumentStyle.mDefaultArrayStyle = .Multiline;
		else
			mStyle.mDocumentStyle.mDefaultArrayStyle = .Inline;
		// New multi-line arrays follow the document's trailing-comma habit (with a comma on a tie or when
		// the document has no multi-line arrays)
		mStyle.mDocumentStyle.mDefaultArrayTrailingComma = mArrayTrailingCommaCount >= mArrayNoTrailingCommaCount;

		// Detect CRLF from cursor
		if (mCrlfCount > 0 && mCrlfCount >= mLfOnlyCount)
			mStyle.mDocumentStyle.mNewlineStyle = .CRLF;
		else
			mStyle.mDocumentStyle.mNewlineStyle = .LF;
	}
}
