using System;
using System.Collections;
using System.IO;
using TomlBeef;
using internal TomlBeef;
using static TomlBeef.TomlTestSupport;

namespace TomlBeef;

/// Preserve-style metadata capture: formats, comments, and dirty tracking. Node lookups go through
/// the TomlTestSupport key helpers rather than allocation order.
static class TomlPreserveStyleMetadataTests
{
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
		let fmt = KeyFormatFor(doc, "server.port");
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
		let fmt = KeyFormatFor(doc, "my key");
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
		let fmt = KeyFormatFor(doc, "raw key");
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
		let fmt = KeyFormatFor(doc, "simple");
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
		let fmt = ValueFormatFor(doc, "dob");
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mSeparator == 'T');
			Test.Assert(dtFmt.mUsesZ == true);
			Test.Assert(dtFmt.mLowercaseZ == false);
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
		let fmt = ValueFormatFor(doc, "dt");
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mSeparator == ' ');
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
		let fmt = ValueFormatFor(doc, "dob");
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
		let fmt = ValueFormatFor(doc, "t");
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
		let fmt = ValueFormatFor(doc, "dt");
		if (fmt case .DateTime(let dtFmt))
		{
			Test.Assert(dtFmt.mSeparator == 'T');
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
		for (let key in StringView[]("a", "b", "c", "d", "e", "f"))
		{
			if (ValueFormatFor(doc, key) case .Float(let floatFmt))
				Test.Assert(floatFmt.mStyle == .Special);
			else
				Test.Assert(false, scope $"Expected Float format for '{key}'");
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
		let fmt = ValueFormatFor(doc, "a");
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
		let fmt = ValueFormatFor(doc, "mode");
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
		let fmt = ValueFormatFor(doc, "flags");
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
		let fmt = ValueFormatFor(doc, "pop");
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
		let fmt = ValueFormatFor(doc, "val");
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
		let fmt = ValueFormatFor(doc, "pi");
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
		let style = StyleFor(doc, "s");
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
		let style = StyleFor(doc, "s");
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
		let style = StyleFor(doc, "s");
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
		let style = StyleFor(doc, "a");
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
		Test.Assert(StyleFor(doc, "a").mOriginalValueToken.IsValid);
		Test.Assert(StyleFor(doc, "b").mOriginalValueToken.IsValid);
		// c is integer, should not have token
		Test.Assert(!StyleFor(doc, "c").mOriginalValueToken.IsValid);
		// Verify token content
		Test.Assert(metadata.GetOriginalToken(StyleFor(doc, "a").mOriginalValueToken) == "\"hello\"");
		Test.Assert(metadata.GetOriginalToken(StyleFor(doc, "b").mOriginalValueToken) == "\"world\"");
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
		let fmtA = ValueFormatFor(doc, "a");
		if (fmtA case .String(let fmtStr))
			Test.Assert(fmtStr.mStyle == .Basic);
		else
			Test.Assert(false, "Expected String format for a");

		// b = 'literal' -> Literal
		let fmtB = ValueFormatFor(doc, "b");
		if (fmtB case .String(let fmtStrB))
			Test.Assert(fmtStrB.mStyle == .Literal);
		else
			Test.Assert(false, "Expected String format for b");

		// c = """multi\nline""" -> MultilineBasic
		let fmtC = ValueFormatFor(doc, "c");
		if (fmtC case .String(let fmtStrC))
			Test.Assert(fmtStrC.mStyle == .MultilineBasic);
		else
			Test.Assert(false, "Expected String format for c");

		// d = '''ml\nlit''' -> MultilineLiteral
		let fmtD = ValueFormatFor(doc, "d");
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
		Test.Assert(StyleFor(doc, "s").mDirtyFlags == .None);

		// Mutate the value
		doc.RootTable.SetString("s", "changed");

		// Node should now be marked dirty
		Test.Assert(StyleFor(doc, "s").mDirtyFlags == .Value);

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
	public static void PreserveStyle_MergeKeepsMetadataAndTracksMergedNodes()
	{
		let doc = ReadPreserveStyle(scope .(), "a = 'hello'\n[t]\nx = 1");
		let metadata = doc.Metadata;

		var mergeConfig = TomlReadConfig();
		mergeConfig.MetadataMode = .PreserveStyle;
		mergeConfig.Mode = .Merge;
		if (doc.Read("b = 'world'\n[t]\ny = 2\n[u.v]\nz = 3", mergeConfig) case .Err(let mergeErr))
		{
			defer mergeErr.Dispose();
			Test.Assert(false, scope $"Merge failed: {mergeErr.mMessage}");
		}
		Test.Assert(doc.Metadata === metadata, "Merge must keep the destination sidecar");
		Test.Assert(doc.RootTable.Count == 4);

		// Existing nodes stay clean; merged nodes are tracked and carry the incoming tokens
		Test.Assert(StyleFor(doc, "a").mDirtyFlags == .None);
		Test.Assert(StyleFor(doc, "b").mDirtyFlags == .None);
		Test.Assert(metadata.GetOriginalToken(StyleFor(doc, "b").mOriginalValueToken) == "'world'");
		Test.Assert(NodeIdFor(doc, "t.y").IsValid, "Keys merged into an existing table get node IDs");
		Test.Assert(NodeIdFor(doc, "u.v.z").IsValid, "Keys inside merged subtrees get node IDs");
		Test.Assert(metadata.mRootDirtyFlags == .Children, "Adding root keys marks the root Children-dirty");
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
	// Comment capture tests
	// ================================================================

	static TomlDocument ReadPreserveStyle(TomlDocument doc, StringView input)
	{
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		return doc;
	}

	[Test]
	public static void PreserveStyle_LeadingComment()
	{
		let doc = ReadPreserveStyle(scope .(), "# leading comment\na = 1");
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);
		let commentSet = CommentsFor(doc, "a");
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading comment");
	}

	[Test]
	public static void PreserveStyle_TrailingComment()
	{
		let doc = ReadPreserveStyle(scope .(), "a = 1 # trailing comment");
		let commentSet = CommentsFor(doc, "a");
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mTrailing == "trailing comment");
	}

	[Test]
	public static void PreserveStyle_LeadingAndTrailingComment()
	{
		let doc = ReadPreserveStyle(scope .(), "# leading\na = 1 # trailing");
		let commentSet = CommentsFor(doc, "a");
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading");
		Test.Assert(commentSet.mTrailing == "trailing");
	}

	[Test]
	public static void PreserveStyle_MultipleLeadingComments()
	{
		let doc = ReadPreserveStyle(scope .(), "# comment 1\n# comment 2\na = 1");
		let commentSet = CommentsFor(doc, "a");
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 2);
		Test.Assert(commentSet.mLeading[0] == "comment 1");
		Test.Assert(commentSet.mLeading[1] == "comment 2");
	}

	[Test]
	public static void PreserveStyle_CommentBeforeTableHeader()
	{
		let doc = ReadPreserveStyle(scope .(), "# table comment\n[server]\nport = 8080");
		Test.Assert(doc.TryGetTable("server", var serverTable));
		Test.Assert(serverTable.MetadataContext != null);
		let commentSet = doc.Metadata.GetCommentSet(serverTable.MetadataContext.mNodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "table comment");
	}

	[Test]
	public static void PreserveStyle_FileHeaderComment()
	{
		// Blank line separates the comment from [server], making it a root comment
		let doc = ReadPreserveStyle(scope .(), "# file header\n\n[server]\nport = 8080");
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "file header");
	}

	[Test]
	public static void PreserveStyle_CommentOnMultipleKeys()
	{
		let doc = ReadPreserveStyle(scope .(), "# first comment\na = 1\n# second comment\nb = 2");
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);

		let commentSetA = CommentsFor(doc, "a");
		Test.Assert(commentSetA != null);
		Test.Assert(commentSetA.mLeading.Count == 1);
		Test.Assert(commentSetA.mLeading[0] == "first comment");

		let commentSetB = CommentsFor(doc, "b");
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "second comment");
	}

	[Test]
	public static void PreserveStyle_RootCommentDoesNotCollideWithFirstNode()
	{
		// Blank line separates root comment from the leading comment for 'a'
		let doc = ReadPreserveStyle(scope .(), "# root comment\n\n# first node comment\na = 1");
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "root comment");

		let firstComments = CommentsFor(doc, "a");
		Test.Assert(firstComments != null);
		Test.Assert(firstComments.mLeading.Count == 1);
		Test.Assert(firstComments.mLeading[0] == "first node comment");
	}

	[Test]
	public static void PreserveStyle_DetachedCommentSeparatedByBlankLine()
	{
		let doc = ReadPreserveStyle(scope .(), "# detached comment\n\n# leading comment\na = 1");
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "detached comment");

		let nodeComments = CommentsFor(doc, "a");
		Test.Assert(nodeComments != null);
		Test.Assert(nodeComments.mLeading.Count == 1);
		Test.Assert(nodeComments.mLeading[0] == "leading comment");
	}

	[Test]
	public static void PreserveStyle_DetachedAfterContentStaysWithNextNode()
	{
		let doc = ReadPreserveStyle(scope .(), "a = 1\n\n# note for b\nb = 2");
		let commentSetA = CommentsFor(doc, "a");
		Test.Assert(commentSetA == null || commentSetA.mLeading.Count == 0);

		let commentSetB = CommentsFor(doc, "b");
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "note for b");

		// No pre-content detached comments
		Test.Assert(doc.Metadata.mRootComments == null || doc.Metadata.mRootComments.mLeading.Count == 0);
	}

	[Test]
	public static void PreserveStyle_StreamCommentAtEof()
	{
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# eof comment"); // no trailing newline
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;

		var doc = scope TomlDocument();
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mRootComments != null);
		Test.Assert(doc.Metadata.mRootComments.mLeading.Count == 1);
		Test.Assert(doc.Metadata.mRootComments.mLeading[0] == "eof comment");
	}

	[Test]
	public static void PreserveStyle_BlankLineMetadataCaptured()
	{
		let doc = ReadPreserveStyle(scope .(), "[a]\nx = 1\n\n[b]\ny = 2");
		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine, "First table should not have blank line flag");

		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(csB != null && csB.mSeparatedByBlankLine, "Second table should have blank line flag");
	}

	[Test]
	public static void PreserveStyle_NoBlankLineForDirectAdjacentSections()
	{
		let doc = ReadPreserveStyle(scope .(), "[a]\nx = 1\n[b]\ny = 2");
		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine, "Table a should not have blank line flag");

		// A single newline between sections is not a blank-line separator
		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(csB == null || !csB.mSeparatedByBlankLine, "Table b should not have blank line flag when directly adjacent");
	}

	// ================================================================
	// Container format capture tests
	// ================================================================

	[Test]
	public static void PreserveStyle_InlineTableFormatCaptured()
	{
		let doc = ReadPreserveStyle(scope .(), "t = { a = 1, b = 2 }");
		if (ValueFormatFor(doc, "t") case .Table(let tFmt))
		{
			Test.Assert(tFmt.mInline == true);
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");
	}

	[Test]
	public static void PreserveStyle_InlineTableSpacedEqualsAndComma()
	{
		let doc = ReadPreserveStyle(scope .(), "t = { a = 1 , b = 2 }");
		if (ValueFormatFor(doc, "t") case .Table(let tFmt))
		{
			Test.Assert(tFmt.mEqualsSpacing == 1, scope $"Expected equals spacing 1, got {tFmt.mEqualsSpacing}");
			Test.Assert(tFmt.mCommaSpacing == 1, scope $"Expected comma spacing 1, got {tFmt.mCommaSpacing}");
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");
	}

	// ================================================================
	// Dirty tracking tests
	// ================================================================

	[Test]
	public static void PreserveStyle_NestedMutationDoesNotDirtyParent()
	{
		let doc = ReadPreserveStyle(scope .(), "[tbl]\nx = 1");
		for (int i = 0; i < doc.Metadata.mNodeStyles.Count; i++)
			Test.Assert(doc.Metadata.mNodeStyles[i].mDirtyFlags == .None, scope $"Node {i} should start clean");

		doc.RootTable.TryGetTable("tbl", var tbl);
		tbl.ReplaceValue("x", .Integer(42));

		Test.Assert(StyleFor(doc, "tbl.x").mDirtyFlags == .Value, "x entry should have Value dirty flag");
		Test.Assert(StyleFor(doc, "tbl").mDirtyFlags == .None, "Parent tbl entry should remain clean after child mutation");

		// Direct insertion into tbl marks it Children-dirty
		tbl.Insert("y", .Integer(99));
		Test.Assert((StyleFor(doc, "tbl").mDirtyFlags & .Children) != 0, "Parent tbl should get Children dirty after direct insertion");
	}

	[Test]
	public static void PreserveStyle_RootInsertAndRemoveMarkRootChildrenDirty()
	{
		let doc = ReadPreserveStyle(scope .(), "a = 1\n[t]\nx = 1");
		Test.Assert(doc.Metadata.mRootDirtyFlags == .None, "Freshly parsed root should be clean");

		doc.RootTable.SetString("new", "v");
		Test.Assert(doc.Metadata.mRootDirtyFlags == .Children, "Inserting a root key should mark the root Children-dirty");

		let removed = ReadPreserveStyle(scope .(), "a = 1\nb = 2");
		Test.Assert(removed.RootTable.Remove("a"));
		Test.Assert(removed.Metadata.mRootDirtyFlags == .Children, "Removing a root key should mark the root Children-dirty");
	}

	[Test]
	public static void PreserveStyle_ArrayAddMarksChildrenDirtyAfterParse()
	{
		let doc = ReadPreserveStyle(scope .(), "arr = [1]");
		doc.RootTable.TryGetArray("arr", var arr);
		let nodeId = arr.MetadataContext.mNodeId;
		Test.Assert(doc.Metadata.GetNodeStyle(nodeId).mDirtyFlags == .None);

		arr.Add(.Integer(2));
		Test.Assert(doc.Metadata.GetNodeStyle(nodeId).mDirtyFlags == .Children);
	}

	[Test]
	public static void PreserveStyle_EqualAssignmentsKeepNodesClean()
	{
		let doc = ReadPreserveStyle(scope .(), "s = 'original'\nn = 0x10\narr = ['x', 2]");
		let tokenCount = doc.Metadata.mOriginalTokens.Count;

		// TomlTableEntry.Value setter
		doc.RootTable[0].Value = "original";
		doc.RootTable[1].Value = 16;
		Test.Assert(StyleFor(doc, "s").mDirtyFlags == .None, "Equal entry assignment should stay clean");
		Test.Assert(StyleFor(doc, "n").mDirtyFlags == .None, "Equal entry assignment should stay clean");

		// Array indexer setter
		Test.Assert(doc.TryGetArray("arr", var arr));
		arr[0] = "x";
		arr[1] = 2;
		Test.Assert(arr.MetadataContext.TryGetItemNodeId(0, var item0));
		Test.Assert(doc.Metadata.GetNodeStyle(item0).mDirtyFlags == .None, "Equal array assignment should stay clean");

		// Internal Insert on an existing key
		doc.RootTable.Insert("n", .Integer(16));
		Test.Assert(StyleFor(doc, "n").mDirtyFlags == .None, "Equal Insert on an existing key should stay clean");
		Test.Assert(doc.Metadata.mOriginalTokens.Count == tokenCount);

		// A real change still marks the node dirty
		doc.RootTable[1].Value = 17;
		Test.Assert(StyleFor(doc, "n").mDirtyFlags == .Value);
		arr[0] = "y";
		Test.Assert(doc.Metadata.GetNodeStyle(item0).mDirtyFlags == .Value);

		// The unchanged literal keeps its original token on write
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("s = 'original'"), scope $"Clean token should be reused:\n{output}");
		Test.Assert(output.Contains("n = 0x11"), scope $"Changed hex value should keep its format:\n{output}");
	}

	[Test]
	public static void PreserveStyle_ReplaceEqualValueKeepsClean()
	{
		let doc = ReadPreserveStyle(scope .(), "s = 'original'");
		Test.Assert(StyleFor(doc, "s").mOriginalValueToken.IsValid);
		Test.Assert(StyleFor(doc, "s").mDirtyFlags == .None);

		doc.RootTable.SetString("s", "original");
		Test.Assert(StyleFor(doc, "s").mDirtyFlags == .None);
	}
}
