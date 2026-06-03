using System; using System.Collections; using System.IO; using TomlBeef; using internal TomlBeef; using static TomlBeef.TomlTestSupport; namespace TomlBeef; static class TomlPreserveStyleMetadataTests {
	[Test]
	public static void PreserveStyle_DetectsDottedKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("server.port = 8080\nserver.host = 'localhost'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mPreferDottedKeys == true);
	}

	[Test]
	public static void PreserveStyle_DetectsNoDottedKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("port = 8080\nhost = 'localhost'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mPreferDottedKeys == false);
	}

	[Test]
	public static void PreserveStyle_DetectsDominantStringStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 3 literal strings, 1 basic string
		let input = "a = 'one'\nb = 'two'\nc = 'three'\nd = \"four\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);
	}

	[Test]
	public static void PreserveStyle_DetectsIndentation()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// TOML allows leading whitespace before keys.
		// First key at column 3 means 2-space indent.
		let input = "  a = 1\n  b = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mIndentSize == 2);
	}

	[Test]
	public static void PreserveStyle_IndentDefaultForTopLevel()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Top-level keys at column 1 → indent stays at default
		let input = "a = 1\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mIndentSize == 4); // default
	}

	[Test]
	public static void PreserveStyle_DetectsCrlfNewlines()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\r\nb = 2\r\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .CRLF);
	}

	[Test]
	public static void PreserveStyle_DetectsLfNewlines()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\nb = 2\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .LF);
	}

	[Test]
	public static void PreserveStyle_DetectsMultilineArrayStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n  3,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultArrayStyle == .Multiline);
	}

	[Test]
	public static void PreserveStyle_DetectsInlineArrayStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [1, 2, 3]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultArrayStyle == .Inline);
	}

	[Test]
	public static void PreserveStyle_CapturesDottedKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("server.port = 8080", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mKeyFormatRef.IsValid);
		let fmt = doc.Metadata.mKeyFormats[style.mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .Bare);
		Test.Assert(fmt.mPreferDottedPath == true);
	}

	[Test]
	public static void PreserveStyle_CapturesQuotedKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("\"my key\" = 42", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .QuotedBasic);
	}

	[Test]
	public static void PreserveStyle_CapturesLiteralKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("'raw key' = 99", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .QuotedLiteral);
	}

	[Test]
	public static void PreserveStyle_CapturesBareKeyFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("simple = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mKeyFormats[doc.Metadata.mNodeStyles[0].mKeyFormatRef.mIndex];
		Test.Assert(fmt.mStyle == .Bare);
		Test.Assert(fmt.mPreferDottedPath == false);
	}

	[Test]
	public static void PreserveStyle_CapturesDateTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dob = 1979-05-27T07:32:00Z", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == true);
			Test.Assert(dtFmt.mUsesZ == true);
			Test.Assert(dtFmt.mHasOffset == true);
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesDateTimeFormatWithOffset()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27 07:32:00-08:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == false); // space separator
			Test.Assert(dtFmt.mUsesZ == false); // offset, not Z
			Test.Assert(dtFmt.mHasOffset == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalDateFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dob = 1979-05-27", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			// Local date has no time separator, no offset
			Test.Assert(dtFmt.mHasOffset == false);
			Test.Assert(dtFmt.mHasSeconds == false);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = 07:32:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mHasOffset == false);
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_CapturesLocalDateTimeFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27T07:32:00", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mUsesUppercaseT == true);
			Test.Assert(dtFmt.mHasOffset == false); // no offset
			Test.Assert(dtFmt.mHasSeconds == true);
		}
		else
			Test.Assert(false, "Expected DateTime format");
	}

	[Test]
	public static void PreserveStyle_MixedNewlinesFavorsDominant()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 2 CRLF, 1 LF → CRLF dominant
		let input = "a = 1\r\nb = 2\r\nc = 3\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .CRLF);
	}

	[Test]
	public static void PreserveStyle_LfDominantOverCrlf()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 1 CRLF, 2 LF → LF dominant
		let input = "a = 1\r\nb = 2\nc = 3\n";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mNewlineStyle == .LF);
	}

	[Test]
	public static void PreserveStyle_ArrayStringsCountForDominantStyle()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 3 literals in array, 1 basic scalar
		let input = "arr = ['a', 'b', 'c']\nname = \"x\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);
	}

	[Test]
	public static void PreserveStyle_DefaultStringStyleBasic()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// 2 basic strings, 1 literal
		let input = "a = \"one\"\nb = \"two\"\nc = 'three'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Basic);
	}

	[Test]
	public static void PreserveStyle_CapturesSpecialFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = inf\nb = +inf\nc = -inf\nd = nan\ne = +nan\nf = -nan", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 6);
		Test.Assert(metadata.mValueFormats.Count == 6);

		// All should be Special float format
		for (int i = 0; i < 6; i++)
		{
			let fmt = metadata.mValueFormats[i];
			if (fmt case .Float(let floatFmt))
				Test.Assert(floatFmt.mStyle == .Special);
			else
				Test.Assert(false, scope $"Expected Float format for node {i}");
		}
	}

	[Test]
	public static void PreserveStyle_CapturesHexIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 0xDEAD_BEEF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let fmtRef = metadata.mNodeStyles[0].mValueFormatRef;
		Test.Assert(fmtRef.IsValid);
		let fmt = metadata.mValueFormats[fmtRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Hex);
			Test.Assert(intFmt.mUseUnderscores == true);
			Test.Assert(intFmt.mGroupSize == 4);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesOctalIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("mode = 0o755", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
			Test.Assert(intFmt.mBase == .Octal);
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesBinaryIntegerFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("flags = 0b1101_0010", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Binary);
			Test.Assert(intFmt.mUseUnderscores == true);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesUnderscoreDecimal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("pop = 1_000_000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Integer(let intFmt))
		{
			Test.Assert(intFmt.mBase == .Decimal);
			Test.Assert(intFmt.mUseUnderscores == true);
			Test.Assert(intFmt.mGroupSize == 3);
		}
		else
			Test.Assert(false, "Expected Integer format");
	}

	[Test]
	public static void PreserveStyle_CapturesScientificFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("val = 1E+06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mUppercaseExponent == true);
			Test.Assert(floatFmt.mExplicitPlusExponent == true);
		}
		else
			Test.Assert(false, "Expected Float format");
	}

	[Test]
	public static void PreserveStyle_CapturesDecimalFloatFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("pi = 3.14", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
		if (fmt case .Float(let floatFmt))
			Test.Assert(floatFmt.mStyle == .Decimal);
		else
			Test.Assert(false, "Expected Float format");
	}

	[Test]
	public static void PreserveStyle_StreamLongStringCrossesBuffer()
	{
		// Build a string value that crosses the 8192-byte stream buffer
		List<uint8> bytes = scope .();
		AddAscii(bytes, "s = '");
		AddRepeat(bytes, 'x', 8190); // 8190 chars of 'x'
		AddAscii(bytes, "'");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);

		// Verify the captured token is correct
		let token = doc.Metadata.GetOriginalToken(style.mOriginalValueToken);
		Test.Assert(token.Length == 8192, scope $"Expected 8192, got {token.Length}"); // ' + 8190 x's + '
		Test.Assert(token[0] == '\'');
		Test.Assert(token[token.Length - 1] == '\'');

		// Verify the writer reuses the token
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Length > 8190);
		Test.Assert(output.Contains("'xxxxxxxxxx"));
	}

	[Test]
	public static void PreserveStyle_NoneModeHasNoMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("a = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata == null);
	}

	[Test]
	public static void PreserveStyle_AllocatesMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
	}

	[Test]
	public static void PreserveStyle_CapturesStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "s = \"hello world\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		let token = metadata.GetOriginalToken(style.mOriginalValueToken);
		Test.Assert(token == "\"hello world\"");
	}

	[Test]
	public static void PreserveStyle_CapturesMultilineStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "s = \"\"\"line1\nline2\"\"\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		let token = metadata.GetOriginalToken(style.mOriginalValueToken);
		// Raw token should include the triple-quote delimiters
		Test.Assert(token.StartsWith("\"\"\""));
		Test.Assert(token.EndsWith("\"\"\""));
	}

	[Test]
	public static void PreserveStyle_NoTokenForInteger()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 42", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 1);
		let style = metadata.mNodeStyles[0];
		// Integers should not have original tokens captured (Stage 4: strings only)
		Test.Assert(!style.mOriginalValueToken.IsValid);
	}

	[Test]
	public static void PreserveStyle_MultipleKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = \"hello\"\nb = \"world\"\nc = 42";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		// 3 keys: a, b, c
		Test.Assert(metadata.mNodeStyles.Count == 3);
		// a and b are strings, should have tokens
		Test.Assert(metadata.mNodeStyles[0].mOriginalValueToken.IsValid);
		Test.Assert(metadata.mNodeStyles[1].mOriginalValueToken.IsValid);
		// c is integer, should not have token
		Test.Assert(!metadata.mNodeStyles[2].mOriginalValueToken.IsValid);
		// Verify token content
		Test.Assert(metadata.GetOriginalToken(metadata.mNodeStyles[0].mOriginalValueToken) == "\"hello\"");
		Test.Assert(metadata.GetOriginalToken(metadata.mNodeStyles[1].mOriginalValueToken) == "\"world\"");
	}

	[Test]
	public static void PreserveStyle_ReplaceClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = \"hello\"", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Re-read without PreserveStyle
		if (doc.Read("b = 1") case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-read failed: {reErr.mMessage}");
		}
		Test.Assert(doc.Metadata == null);
	}

	[Test]
	public static void PreserveStyle_CapturesStringFormat()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = \"basic\"\nb = 'literal'\nc = \"\"\"multi\nline\"\"\"\nd = '''ml\nlit'''";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let metadata = doc.Metadata;
		Test.Assert(metadata != null);
		Test.Assert(metadata.mNodeStyles.Count == 4);

		// Check value formats
		Test.Assert(metadata.mValueFormats.Count == 4);

		// a = "basic" -> Basic
		let fmtA = metadata.mValueFormats[0];
		if (fmtA case .String(let fmtStr))
			Test.Assert(fmtStr.mStyle == .Basic);
		else
			Test.Assert(false, "Expected String format for a");

		// b = 'literal' -> Literal
		let fmtB = metadata.mValueFormats[1];
		if (fmtB case .String(let fmtStrB))
			Test.Assert(fmtStrB.mStyle == .Literal);
		else
			Test.Assert(false, "Expected String format for b");

		// c = """multi\nline""" -> MultilineBasic
		let fmtC = metadata.mValueFormats[2];
		if (fmtC case .String(let fmtStrC))
			Test.Assert(fmtStrC.mStyle == .MultilineBasic);
		else
			Test.Assert(false, "Expected String format for c");

		// d = '''ml\nlit''' -> MultilineLiteral
		let fmtD = metadata.mValueFormats[3];
		if (fmtD case .String(let fmtStrD))
			Test.Assert(fmtStrD.mStyle == .MultilineLiteral);
		else
			Test.Assert(false, "Expected String format for d");
	}

	[Test]
	public static void PreserveStyle_MutationMarksDirty()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("s = 'original'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify metadata exists and node is clean
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .None);

		// Mutate the value
		doc.RootTable.SetString("s", "changed");

		// Node should now be marked dirty
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .Value);

		// Writer should emit the new value, not the original token
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("changed"));
		Test.Assert(!output.Contains("original"));
	}

	[Test]
	public static void PreserveStyle_ReplaceReadTwice()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;

		// First read with PreserveStyle
		if (doc.Read("a = 'first'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"First read failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Second read with PreserveStyle (Replace mode)
		if (doc.Read("b = 'second'\nc = 'third'", config) case .Err(let read2Err))
		{
			defer read2Err.Dispose();
			Test.Assert(false, scope $"Second read failed: {read2Err.mMessage}");
		}
		// Metadata should be replaced with new document's metadata
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);
		Test.Assert(doc.RootTable.Count == 2);

		// Verify tokens are captured for new content
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'second'"));
		Test.Assert(output.Contains("'third'"));
	}

	[Test]
	public static void PreserveStyle_MergeClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;

		if (doc.Read("a = 'hello'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Setup failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// Merge — metadata should be cleared since merge-aware metadata is not yet implemented
		var mergeConfig = TomlReadConfig();
		mergeConfig.MetadataMode = .PreserveStyle;
		mergeConfig.Mode = .Merge;
		if (doc.Read("b = 'world'", mergeConfig) case .Err(let mergeErr))
		{
			defer mergeErr.Dispose();
			Test.Assert(false, scope $"Merge failed: {mergeErr.mMessage}");
		}
		// Metadata should be cleared after merge
		Test.Assert(doc.Metadata == null);
		// Semantic content should be merged
		Test.Assert(doc.RootTable.Count == 2);
	}

	[Test]
	public static void PreserveStyle_ErrorClearsMetadata()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = ???invalid", config) case .Err(let e))
		{
			defer e.Dispose();
		}
		else
		{
			Test.Assert(false, "Expected parse error");
		}
		// Metadata should be cleaned up on error
		Test.Assert(doc.Metadata == null);
	}

	// ================================================================
	// Comment preservation tests
	// ================================================================
}
