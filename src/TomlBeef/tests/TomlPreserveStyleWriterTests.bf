using System;
using System.Collections;
using System.IO;
using TomlBeef;
using internal TomlBeef;
using static TomlBeef.TomlTestSupport;

namespace TomlBeef;

/// Preserve-style writer output: token reuse, formats, comments, and dirty-write effects.
static class TomlPreserveStyleWriterTests
{
	[Test]
	public static void PreserveStyle_CommentEmission()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading\na = 1 # trailing";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Verify exact comment placement
		Test.Assert(output.Contains("# leading\na = 1 # trailing"));
	}

	[Test]
	public static void PreserveStyle_EmptyTrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 #";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let commentSet = CommentsFor(doc, "a");
		Test.Assert(commentSet != null);
		// Trailing comment should exist (empty string, not null)
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing.IsEmpty);

		// Writer should emit the # marker
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("a = 1 #"));
	}

	[Test]
	public static void PreserveStyle_CommentEmissionExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading\na = 1 # trailing";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output assertion
		let expected = "# leading\na = 1 # trailing\n";
		Test.Assert(output == expected, scope $"Expected:\n{expected}\nGot:\n{output}");
	}

	[Test]
	public static void PreserveStyle_EmptyTrailingCommentExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 #";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output: should be 'a = 1 #' with no trailing space
		let expected = "a = 1 #\n";
		Test.Assert(output == expected, scope $"Expected: '{expected}' Got: '{output}'");
	}

	[Test]
	public static void PreserveStyle_CommentedTableHeaderExactOutput()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# server config\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Exact output: no leading blank line, comment directly before [server]
		let expected = "# server config\n[server]\nport = 8080\n";
		Test.Assert(output == expected, scope $"Expected:\n{expected}\nGot:\n{output}");
	}

	// ================================================================
	// Float style preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_FloatExponentDigitWidth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 1e06 has exponent width 2, no explicit plus
		if (doc.Read("f = 1e06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = ValueFormatFor(doc, "f");
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mExponentDigits == 2, scope $"Expected 2 exponent digits, got {floatFmt.mExponentDigits}");
			Test.Assert(floatFmt.mUppercaseExponent == false);
			Test.Assert(floatFmt.mExplicitPlusExponent == false);
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate and verify exponent width preserved
		doc.RootTable.ReplaceValue("f", .Float(2.0e3));
		String output = scope String();
		doc.Write(output);
		// Should have 2-digit exponent, lowercase e, no plus: 2e03
		Test.Assert(output.Contains("2e03"), scope $"Expected '2e03' in output (exponent width not preserved), got: {output}");
		Test.Assert(!output.Contains("2e+03"), scope $"Explicit plus must not appear: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatExponentUppercasePlusWidth()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 1E+006 has uppercase E, explicit plus, exponent width 3
		if (doc.Read("f = 1E+006", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = ValueFormatFor(doc, "f");
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mStyle == .Scientific);
			Test.Assert(floatFmt.mExponentDigits == 3, scope $"Expected 3 exponent digits, got {floatFmt.mExponentDigits}");
			Test.Assert(floatFmt.mUppercaseExponent == true);
			Test.Assert(floatFmt.mExplicitPlusExponent == true);
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate and verify format preserved
		doc.RootTable.ReplaceValue("f", .Float(2.0e3));
		String output = scope String();
		doc.Write(output);
		// Should have uppercase E, explicit plus, 3-digit exponent: 2E+003
		Test.Assert(output.Contains("2E+003"), scope $"Expected '2E+003' in output, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatExponentWidthDoesNotTrimMagnitude()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1e06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(1.0e100));
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("e100"), scope $"Exponent digits must not be trimmed: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatUnderscoreGrouping()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Original: 224_617.445_991 has underscore grouping in both parts
		if (doc.Read("f = 224_617.445_991", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		let fmt = ValueFormatFor(doc, "f");
		if (fmt case .Float(let floatFmt))
		{
			Test.Assert(floatFmt.mUseUnderscores == true);
			Test.Assert(floatFmt.mIntGroupSize == 3, scope $"Expected int group size 3, got {floatFmt.mIntGroupSize}");
			Test.Assert(floatFmt.mFracGroupSize == 3, scope $"Expected frac group size 3, got {floatFmt.mFracGroupSize}");
		}
		else
			Test.Assert(false, "Expected Float format");

		// Mutate to a different value and verify grouping preserved
		doc.RootTable.ReplaceValue("f", .Float(225000.5));
		String output = scope String();
		doc.Write(output);
		// Should have underscores in both parts: 225_000.500_000 (precision preserved too)
		Test.Assert(output.Contains("225_000.500"), scope $"Expected grouped output, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatInfinitySignRemainsSemantic()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = -inf", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(double.PositiveInfinity));
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("f = inf"), scope $"Positive infinity must not become negative: {output}");
		Test.Assert(!output.Contains("-inf"));
	}

	[Test]
	public static void PreserveStyle_FloatSpecialSignPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = +inf\nb = +nan", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Check +inf format
		{
			let fmtA = ValueFormatFor(doc, "a");
			if (fmtA case .Float(let floatFmt))
			{
				Test.Assert(floatFmt.mStyle == .Special);
				Test.Assert(floatFmt.mSpecialSign == .ExplicitPlus,
					scope $"Expected ExplicitPlus for +inf, got {floatFmt.mSpecialSign}");
			}
			else
				Test.Assert(false, "Expected Float format for +inf");
		}

		// Check +nan format
		{
			let fmtB = ValueFormatFor(doc, "b");
			if (fmtB case .Float(let floatFmt))
			{
				Test.Assert(floatFmt.mStyle == .Special);
				Test.Assert(floatFmt.mSpecialSign == .ExplicitPlus,
					scope $"Expected ExplicitPlus for +nan, got {floatFmt.mSpecialSign}");
			}
			else
				Test.Assert(false, "Expected Float format for +nan");
		}

		// Mutate and verify +inf preserved
		doc.RootTable.ReplaceValue("a", .Float(double.NaN));
		String output = scope String();
		doc.Write(output);
		// +nan should be preserved with explicit plus (from format metadata)
		Test.Assert(output.Contains("+nan"), scope $"Expected +nan with explicit plus, got: {output}");
		Test.Assert(!output.Contains("-nan"), scope $"Must not be -nan: {output}");
	}

	// ================================================================
	// Inline table format preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_InlineTableStaysInlineAfterMutation()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = { a = 1, b = 2 }", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate a value inside the inline table
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		// Should remain inline, not switch to [t] header format
		Test.Assert(output.Contains("{ a = 42, b = 2 }") ||
			output.Contains("t = { a = 42, b = 2 }"),
			scope $"Expected inline table in output, got: {output}");
		Test.Assert(!output.Contains("[t]"), scope $"Should not use header syntax: {output}");
	}

	[Test]
	public static void PreserveStyle_MultilineInlineTableFallsBackForV1_0Write()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("t = {\n  a = 1,\n}", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(2));

		var writeConfig = TomlWriteConfig();
		writeConfig.Version = .V1_0;
		String output = scope String();
		doc.Write(output, writeConfig);
		Test.Assert(output.Contains("t = {"), scope $"Expected inline table, got: {output}");
		Test.Assert(!output.Contains("{\n"), scope $"TOML v1.0 writer must not emit multiline inline table: {output}");
	}

	[Test]
	public static void PreserveStyle_MultilineInlineTablePreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = {\n  a = 1,\n  b = 2,\n}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Check multiline format was captured
		let fmt = ValueFormatFor(doc, "t");
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mMultiline == true);
			Test.Assert(tFmt.mTrailingComma == true);
		}

		// Mutate and verify multiline preserved
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("{\n"), scope $"Expected multiline inline table, got: {output}");
		Test.Assert(output.Contains("  a = 42"), scope $"Expected indented entry, got: {output}");
	}

	// ================================================================
	// Array indentation preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_ArrayIndent2Spaces()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		arr.Add(.Integer(3));

		String output = scope String();
		doc.Write(output);
		// New element should use 2-space indent (from captured format)
		Test.Assert(output.Contains("  3"), scope $"Expected 2-space indent for new element, got: {output}");
	}

	[Test]
	public static void PreserveStyle_ArrayIndent4Spaces()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n    1,\n    2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify indent size was captured. The array format is on the key-value entry node.
		TomlNodeId arrNodeId = .Invalid;
		if (doc.RootTable.MetadataContext != null)
			doc.RootTable.MetadataContext.TryGetEntryNodeId("arr", out arrNodeId);
		Test.Assert(arrNodeId.IsValid, "Expected arr entry node ID");
		let nodeStyle = doc.Metadata.GetNodeStyle(arrNodeId);
		Test.Assert(nodeStyle != null && nodeStyle.mValueFormatRef.IsValid, "Expected value format ref to be valid");
		let fmt = doc.Metadata.mValueFormats[nodeStyle.mValueFormatRef.mIndex];
		if (fmt case .Array(let arrFmt))
			Test.Assert(arrFmt.mIndentSize == 4, scope $"Expected indent 4, got {arrFmt.mIndentSize}");

		doc.RootTable.TryGetArray("arr", var arr);
		arr.Add(.Integer(3));

		String output = scope String();
		doc.Write(output);
		// New element should use 4-space indent
		Test.Assert(output.Contains("    3"), scope $"Expected 4-space indent, got: {output}");
	}

	// ================================================================
	// Array comment preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_ArrayElementLeadingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  # lead\n  1\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the comment was captured on the element node
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(0, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element");
		Test.Assert(commentSet.mLeading.Count == 1, scope $"Expected 1 leading comment, got {commentSet.mLeading.Count}");
		Test.Assert(commentSet.mLeading[0] == "lead", scope $"Expected 'lead', got '{commentSet.mLeading[0]}'");

		// Writer should preserve the comment WITH indentation matching the element
		String output = scope String();
		doc.Write(output);
		// Comment should be indented to same level as element
		Test.Assert(output.Contains("  # lead"), scope $"Expected indented comment '  # lead', got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayElementTrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1, # trail\n  2\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the trailing comment was captured
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(0, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element 0");
		Test.Assert(commentSet.mTrailing != null, "Expected trailing comment");
		Test.Assert(commentSet.mTrailing == "trail", scope $"Expected 'trail', got '{commentSet.mTrailing}'");

		String output = scope String();
		doc.Write(output);
		// Comma must appear BEFORE comment: `1, # trail` not `1 # trail,`
		Test.Assert(output.Contains("1, # trail"),
			scope $"Expected comma before trailing comment '1, # trail', got: {output}");
		Test.Assert(!output.Contains("1 # trail,"),
			"Comma must not appear after trailing comment");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayBlankLineBeforeElement()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two elements with a blank line between them
		let input = "arr = [\n  1,\n\n  2\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify blank line separation on element 1
		doc.RootTable.TryGetArray("arr", var arr);
		TomlNodeId elemId = .Invalid;
		if (arr.MetadataContext != null)
			arr.MetadataContext.TryGetItemNodeId(1, out elemId);
		Test.Assert(elemId.IsValid);
		let commentSet = doc.Metadata.GetCommentSet(elemId);
		Test.Assert(commentSet != null, "Expected comment set on element 1");
		Test.Assert(commentSet.mSeparatedByBlankLine, "Expected blank line flag");

		// Writer should preserve the blank line
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("1,\n\n  2") || output.Contains("1,\r\n\r\n  2"),
			scope $"Expected blank line between elements, got: {output}");
	}

	[Test]
	public static void PreserveStyle_ArrayEmptyWithComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  # empty comment\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);
		// Comment inside empty array should be preserved
		Test.Assert(output.Contains("# empty comment"),
			scope $"Expected comment in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayLastElementTrailingCommentNoComma()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Last element has a trailing comment without a comma before it
		let input = "arr = [\n  1 # last\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);
		// Comment should be preserved
		Test.Assert(output.Contains("# last"), scope $"Expected comment in output, got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayTrailingCommaWithComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Trailing comma with comment before close bracket
		let input = "arr = [\n  1, # trail\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify trailing comma format was captured
		TomlNodeId arrNodeId = .Invalid;
		if (doc.RootTable.MetadataContext != null)
			doc.RootTable.MetadataContext.TryGetEntryNodeId("arr", out arrNodeId);
		Test.Assert(arrNodeId.IsValid);
		let nodeStyle = doc.Metadata.GetNodeStyle(arrNodeId);
		Test.Assert(nodeStyle != null && nodeStyle.mValueFormatRef.IsValid);
		let valFmt = doc.Metadata.mValueFormats[nodeStyle.mValueFormatRef.mIndex];
		if (valFmt case .Array(let arrFmt))
			Test.Assert(arrFmt.mTrailingComma == true,
				scope $"Expected trailing comma=true, got {arrFmt.mTrailingComma}");

		String output = scope String();
		doc.Write(output);
		// Should have both trailing comma and comment
		Test.Assert(output.Contains("1, # trail"),
			scope $"Expected '1, # trail', got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	// ================================================================
	// Inline table spacing preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_InlineTableCompactSpacing()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = {a=1,b=2}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify compact spacing was captured
		TomlNodeId nodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out nodeId);
		let style = doc.Metadata.GetNodeStyle(nodeId);
		let fmt = doc.Metadata.mValueFormats[style.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mEqualsSpacing == 0, scope $"Expected equals spacing 0, got {tFmt.mEqualsSpacing}");
			Test.Assert(tFmt.mCommaSpacing == 0, scope $"Expected comma spacing 0, got {tFmt.mCommaSpacing}");
			Test.Assert(tFmt.mOpenBraceSpacing == 0, scope $"Expected open brace spacing 0, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 0, scope $"Expected close brace spacing 0, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");

		// Mutate and verify compact style preserved
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("{a=42,b=2}"), scope $"Expected compact inline table, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_InlineTableV10ForcesSingleLine()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Parse a multiline inline table
		let input = "t = {\n  a = 1,\n  b = 2,\n}";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate
		doc.RootTable.TryGetTable("t", var tbl);
		tbl.ReplaceValue("a", .Integer(42));

		// Write with v1.0 should force single-line
		var writeConfig = TomlWriteConfig();
		writeConfig.Version = .V1_0;
		String output = scope String();
		doc.Write(output, writeConfig);
		// Should be single-line, no newlines inside braces
		Test.Assert(!output.Contains("{\n") && !output.Contains("{\r"),
			scope $"Expected single-line inline table in v1.0, got: {output}");
		// Should contain proper spacing
		Test.Assert(output.Contains(" = ") && output.Contains(", "),
			scope $"Expected spaced inline table in v1.0, got: {output}");

		// Write with v1.1 should preserve multiline
		writeConfig.Version = .V1_1;
		String output2 = scope String();
		doc.Write(output2, writeConfig);
		Test.Assert(output2.Contains("{\n"), scope $"Expected multiline inline table in v1.1, got: {output2}");
	}

	// ================================================================
	// Table header blank line preservation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_BlankLineBeforeTableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two tables with a blank line between
		let input = "[a]\nx = 1\n\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify blank line metadata was captured on the [b] table node
		doc.RootTable.TryGetTable("b", var tblB);
		Test.Assert(tblB.MetadataContext != null);
		let commentSet = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(commentSet != null, "Expected comment set on table b");
		Test.Assert(commentSet.mSeparatedByBlankLine, "Expected blank line flag on table b");

		// Verify table [a] does NOT have the blank line flag
		doc.RootTable.TryGetTable("a", var tblA);
		let commentSetA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(commentSetA == null || !commentSetA.mSeparatedByBlankLine,
			"Table a should not have blank line flag");

		String output = scope String();
		doc.Write(output);
		// Writer always emits blank line separator before headers
		Test.Assert(output.Contains("x = 1\n\n[b]") || output.Contains("x = 1\r\n\r\n[b]"),
			scope $"Expected blank line between sections, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	[Test]
	public static void PreserveStyle_ArrayCrlfWithComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// CRLF array with comments
		List<uint8> bytes = scope .();
		AddAscii(bytes, "arr = [\r\n");
		AddAscii(bytes, "  # header\r\n");
		AddAscii(bytes, "  1, # first\r\n");
		AddAscii(bytes, "  2\r\n");
		AddAscii(bytes, "]\r\n");

		var doc2 = new TomlDocument();
		defer delete doc2;
		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;
		if (doc2.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc2.Write(output);
		// Should contain all comments
		Test.Assert(output.Contains("# header"), scope $"Expected header comment, got: {output}");
		Test.Assert(output.Contains("# first"), scope $"Expected trailing comment, got: {output}");
		Test.Assert(output.Contains("  1"), scope $"Expected value 1, got: {output}");
		Test.Assert(output.Contains("  2"), scope $"Expected value 2, got: {output}");
	}

	// ================================================================
	// Dirty propagation tests
	// ================================================================

	[Test]
	public static void PreserveStyle_CleanSiblingTokensReused()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Two sibling values in a table — one will be mutated
		let input = "a = 'hello'\nb = 'world'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Get original tokens
		let meta = doc.Metadata;
		TomlNodeId aNodeId = .Invalid, bNodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("a", out aNodeId);
		doc.RootTable.MetadataContext.TryGetEntryNodeId("b", out bNodeId);
		Test.Assert(aNodeId.IsValid && bNodeId.IsValid);

		let aStyle = meta.GetNodeStyle(aNodeId);
		let bStyle = meta.GetNodeStyle(bNodeId);
		Test.Assert(aStyle.mDirtyFlags == .None);
		Test.Assert(bStyle.mDirtyFlags == .None);
		let bOrigToken = meta.GetOriginalToken(bStyle.mOriginalValueToken);

		// Mutate only 'a' — 'b' should stay clean
		// ReplaceValue does not allocate metadata, so pointers remain valid.
		doc.RootTable.SetString("a", "changed");

		Test.Assert(aStyle.mDirtyFlags == .Value, "Mutated entry should be dirty");
		Test.Assert(bStyle.mDirtyFlags == .None, "Sibling should remain clean");

		// Writer should reuse b's original token and regenerate a
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("changed"), scope $"Output should contain mutated value, got: {output}");
		Test.Assert(output.Contains(bOrigToken), scope $"Output should contain b's original token '{bOrigToken}', got: {output}");
	}

	[Test]
	public static void PreserveStyle_InlineTableMutationDoesNotDirtyParentEntry()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = { a = 1, b = 2 }";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Get node IDs
		TomlNodeId tNodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out tNodeId);
		Test.Assert(tNodeId.IsValid);

		doc.RootTable.TryGetTable("t", var tbl);

		// The inline table container has its own node ID from BindContainerMetadata
		let inlineNodeId = tbl.MetadataContext?.mNodeId ?? .Invalid;
		Test.Assert(inlineNodeId.IsValid, "Inline table should have a container node");
		let inlineStyle = doc.Metadata.GetNodeStyle(inlineNodeId);
		Test.Assert(inlineStyle != null && inlineStyle.mDirtyFlags == .None,
			"Inline table container should start clean");

		// The parent 't' entry should also start clean
		let tStyle = doc.Metadata.GetNodeStyle(tNodeId);
		Test.Assert(tStyle != null && tStyle.mDirtyFlags == .None,
			"Parent 't' entry should start clean");

		// Mutate a value inside the inline table (replacing existing key)
		tbl.ReplaceValue("a", .Integer(42));

		// No upward propagation: parent 't' entry stays clean
		Test.Assert(tStyle != null && tStyle.mDirtyFlags == .None,
			"Parent 't' entry should remain clean after inline table child mutation");

		// Inline table container also stays clean (replacing existing key, not structural)
		Test.Assert(inlineStyle != null && inlineStyle.mDirtyFlags == .None,
			"Inline table container should stay clean after value replacement");

		// Mutate the inline table's structure (insert a new key).
		// This may reallocate mNodeStyles, so re-fetch pointers after.
		tbl.Insert("c", .Integer(3));

		// The inline table container gets Children dirty
		let inlineStyle2 = doc.Metadata.GetNodeStyle(inlineNodeId);
		Test.Assert(inlineStyle2 != null && (inlineStyle2.mDirtyFlags & .Children) != 0,
			"Inline table container should get Children dirty after structural change");

		// Still no upward propagation to parent 't' entry
		let tStyle2 = doc.Metadata.GetNodeStyle(tNodeId);
		Test.Assert(tStyle2 != null && tStyle2.mDirtyFlags == .None,
			"Parent 't' entry should still be clean after inline table structural change");

		// Writer should still produce valid output
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("a = 42") && output.Contains("c = 3"),
			scope $"Expected mutated inline table in output, got: {output}");

		// Re-parse should be valid
		var doc2 = new TomlDocument();
		defer delete doc2;
		if (doc2.Read(output) case .Err(let reErr))
		{
			defer reErr.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {reErr.mMessage}");
		}
	}

	// ================================================================
	// Quoted path syntax tests
	[Test]
	public static void PreserveStyle_WriterReusesStringTokens()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Use a string where the original token differs from the canonical form.
		// "a\u0020b" contains a unicode escape for space — canonical output is "a b".
		// If the writer reuses the original token, output contains \u0020.
		let input = "s = \"a\\u0020b\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify semantic value is correct
		Test.Assert(doc.TryGetString("s", var val));
		Test.Assert(val == "a b");

		// Write with preserving mode
		String output = scope String();
		doc.Write(output);

		// Token reuse: the original \u0020 escape should be preserved.
		// Canonical regeneration would produce "a b" instead.
		Test.Assert(output.Contains("\\u0020"), scope $"Expected \\u0020 token reuse, got: {output}");
		Test.Assert(!output.Contains("a b"), scope $"Canonical 'a b' must not appear: {output}");
	}

	[Test]
	public static void PreserveStyle_WriterReusesLiteralStringToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Literal string: backslash is literal
		let input = "path = 'C:\\Users\\test'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify semantic value
		Test.Assert(doc.TryGetString("path", var val));
		Test.Assert(val == "C:\\Users\\test");

		// Write
		String output = scope String();
		doc.Write(output);

		// Should preserve the literal string style with original token
		Test.Assert(output.Contains("path = 'C:\\Users\\test'"));
	}

	[Test]
	public static void PreserveStyle_WriterReusesMultilineToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "msg = \"\"\"Hello,\\nWorld!\"\"\"";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Should preserve the multiline basic string token exactly
		Test.Assert(output.Contains("msg = \"\"\"Hello,\\nWorld!\"\"\""));
	}

	[Test]
	public static void PreserveStyle_IntegerFormatPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0xDEAD_BEEF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify format was captured
		if (ValueFormatFor(doc, "n") case .Integer(let intFmt))
			Test.Assert(intFmt.mBase == .Hex);
		else
			Test.Assert(false, "Expected Integer format");

		// Mutate the value to a different hex value
		bool replaced = doc.RootTable.ReplaceValue("n", .Integer(0x12345));
		Test.Assert(replaced);

		// Verify dirty
		Test.Assert(StyleFor(doc, "n").mDirtyFlags == .Value);

		String output = scope String();
		doc.Write(output);

		// Should regenerate using hex format, preserving original digit width and grouping
		Test.Assert(output.Contains("0x0001_2345"), scope $"Expected hex, got: {output}");
	}

	[Test]
	public static void PreserveStyle_IntegerMinDigitsPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0x00FF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("n", .Integer(1));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("n = 0x0001"), scope $"Expected padded hex, got: {output}");
	}

	[Test]
	public static void PreserveStyle_NegativeDecimalIntegerKeepsGrouping()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = -1_000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("n", .Integer(-2000));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("n = -2_000"), scope $"Expected grouped negative decimal, got: {output}");
	}

	[Test]
	public static void PreserveStyle_NegativeIntegerFallsBackToDecimal()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("n = 0xFF", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate to a negative value
		doc.RootTable.ReplaceValue("n", .Integer(-42));

		String output = scope String();
		doc.Write(output);

		// Negative values must be decimal, not hex
		Test.Assert(output.Contains("n = -42"));
		Test.Assert(!output.Contains("0x"));
	}

	[Test]
	public static void PreserveStyle_FloatPrecisionPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1.000", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("f", .Float(2.5));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("f = 2.500"), scope $"Expected fixed precision, got: {output}");
	}

	[Test]
	public static void PreserveStyle_FloatFormatPreserved()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("f = 1E+06", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Mutate to a different float value
		doc.RootTable.ReplaceValue("f", .Float(2.5e3));

		String output = scope String();
		doc.Write(output);

		// Should use scientific notation with uppercase E and explicit plus (from format metadata).
		// Original format was 1E+06 (uppercase E, explicit plus, 2-digit exponent).
		Test.Assert(output.Contains("2.5E+03"), scope $"Expected 2.5E+03, got: {output}");
		Test.Assert(!output.Contains("e"), scope $"Lowercase e must not appear: {output}");
	}

	[Test]
	public static void PreserveStyle_DateTimeOmittedSecondsPreservedOnDirtyWrite()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("dt = 1979-05-27 07:32Z", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.ReplaceValue("dt", .OffsetDateTime(TomlOffsetDateTime(1979, 5, 27, 8, 33, 0, 0, 0)));

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("dt = 1979-05-27 08:33Z"), scope $"Expected omitted seconds, got: {output}");
		Test.Assert(!output.Contains("08:33:00"));
	}

	[Test]
	public static void PreserveStyle_MultilineArrayFormatPreservedOnDirtyWrite()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "arr = [\n  1,\n  2,\n]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		arr[1] = 3;

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("arr = [\n"), scope $"Expected multiline array, got: {output}");
		Test.Assert(output.Contains("  3,"), scope $"Expected indented changed element with comma, got: {output}");
	}

	[Test]
	public static void PreserveStyle_InsertNewKeyMarksChildrenDirty()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("[tbl]\n  a = 1", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Insert a new key into the table — auto-allocates node ID and marks dirty
		doc.RootTable.TryGetTable("tbl", var tbl);
		tbl.Insert("b", .Integer(2));

		// Write the document - new key 'b' should appear
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("b = 2"));
	}

	[Test]
	public static void PreserveStyle_DottedKeysReemitted()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "server.port = 8080\nserver.host = 'localhost'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Output should preserve dotted-key style, not normalize to [server] header
		Test.Assert(output.Contains("server.port = 8080"));
		Test.Assert(!output.Contains("[server]"));
	}

	[Test]
	public static void PreserveStyle_DottedKeysNestedTables()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "server.port = 8080\nserver.db.host = 'localhost'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String output = scope String();
		doc.Write(output);

		// Both values should appear, and db.host should be emitted as a dotted key
		Test.Assert(output.Contains("server.port = 8080"));
		Test.Assert(output.Contains("server.db.host = 'localhost'"));
	}

	[Test]
	public static void PreserveStyle_ArrayElementTokenReuse()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("arr = ['hello', 'world']", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify array has metadata context
		doc.RootTable.TryGetArray("arr", var arr);
		Test.Assert(arr.MetadataContext != null);
		Test.Assert(arr.MetadataContext.mItemNodeIds.Count == 2);

		// Write and verify original tokens reused
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'hello'"));
		Test.Assert(output.Contains("'world'"));
	}

	[Test]
	public static void PreserveStyle_DocumentStyleFallbackForString()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Document uses mostly literal strings
		let input = "a = 'hello'\nb = 'world'";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify dominant style is literal
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);

		// Mutate a value
		doc.RootTable.SetString("a", "changed");

		// Write - changed string should use document's literal style
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("'changed'"));
	}

	[Test]
	public static void PreserveStyle_ChangedStringKeepsItsOwnStyle()
	{
		var doc = scope TomlDocument();
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Literal strings dominate, but `basic` is a basic string and the multiline ones differ in shape
		let input = "a = 'one'\nb = 'two'\nc = 'three'\nbasic = \"four\"\nml = \"\"\"inline start\"\"\"\nmlnl = '''\nnewline start'''";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata.mDocumentStyle.mDefaultStringStyle == .Literal);

		doc.RootTable.SetString("basic", "changed");
		doc.RootTable.SetString("ml", "still inline");
		doc.RootTable.SetString("mlnl", "still newline");
		doc.RootTable.SetString("added", "new key");

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("basic = \"changed\""), scope $"Changed basic string should stay basic:\n{output}");
		Test.Assert(output.Contains("ml = \"\"\"still inline\"\"\""), scope $"Multiline string without leading newline should keep that shape:\n{output}");
		Test.Assert(output.Contains("mlnl = '''\nstill newline'''"), scope $"Multiline literal with leading newline should keep it:\n{output}");
		Test.Assert(output.Contains("added = 'new key'"), scope $"A new key should use the dominant (literal) style:\n{output}");

		var reparsed = scope TomlDocument();
		if (reparsed.Read(output) case .Err(let e2))
		{
			defer e2.Dispose();
			Test.Assert(false, scope $"Re-parse failed: {e2.mMessage}\n{output}");
		}
		Test.Assert(TomlDocumentEquals(doc, reparsed));
	}

	[Test]
	public static void PreserveStyle_EofCommentEmittedAfterContent()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\n\n# eof comment";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify the comment was captured as footer
		Test.Assert(doc.Metadata.mFooterComments != null);
		Test.Assert(doc.Metadata.mFooterComments.mLeading.Count == 1);

		// Write and verify output order
		String output = scope String();
		doc.Write(output);

		// The comment should appear AFTER the content, not before
		int aPos = output.IndexOf("a = 1");
		int commentPos = output.IndexOf("# eof comment");
		Test.Assert(aPos >= 0);
		Test.Assert(commentPos >= 0);
		Test.Assert(commentPos > aPos, "EOF comment should appear after content, not before");
	}

	// ================================================================
	// PreserveStyle metadata tests
	// ================================================================

	[Test]
	public static void PreserveStyle_RemoveThenReinsertDoesNotReuseOldToken()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 'old'", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify original token is captured
		Test.Assert(doc.Metadata != null);
		Test.Assert(StyleFor(doc, "a").mOriginalValueToken.IsValid);

		// Remove and reinsert with a new value
		doc.RootTable.Remove("a");
		doc.RootTable.SetString("a", "new");

		// Writer should emit 'new', not 'old'
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("new"));
		Test.Assert(!output.Contains("old"));
	}

	static void ReadPreserving(TomlDocument doc, StringView input, TomlReadMode mode = .Replace, MergeConflict onConflict = .Error, TomlMetadataMode metadataMode = .PreserveStyle)
	{
		if (doc.Read(input, .() { Mode = mode, OnConflict = onConflict, MetadataMode = metadataMode }) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Read failed: {e.mMessage}\n{input}");
		}
	}

	static void AssertContains(StringView output, StringView expected)
	{
		Test.Assert(output.Contains(expected), scope $"Expected to find:\n{expected}\nin output:\n{output}");
	}

	[Test]
	public static void PreserveStyle_BlankLinesAndDetachedCommentsRoundTrip()
	{
		// Unedited documents must come back exactly (runs of blank lines collapse to one)
		for (let input in StringView[](
			"a = 1\nb = 2\n\nc = 3\n",
			"a = 1\n\n# detached\n\nb = 2\n",
			"a = 1\n\n# attached to b\nb = 2\n",
			"# header\n\n# detached\n\na = 1\n",
			"# header\n\na = 1\n",
			"[x]\na = 1\n\n# detached before y\n\n[y]\nb = 2\n",
			"[x]\n\na = 1\n",
			"a = 1\n\n# trailing block at end\n",
			"# only a comment\n",
			"# one\n\n# two\n",
			"a = 1\r\n\r\nb = 2\r\n"))
		{
			var doc = scope:: TomlDocument();
			ReadPreserving(doc, input);
			String output = scope String();
			doc.Write(output);
			Test.Assert(output == input, scope $"Round trip changed the document.\nInput:\n{input}\nOutput:\n{output}");
		}

		var collapsed = scope TomlDocument();
		ReadPreserving(collapsed, "a = 1\n\n\n\nb = 2\n");
		String collapsedOut = scope String();
		collapsed.Write(collapsedOut);
		Test.Assert(collapsedOut == "a = 1\n\nb = 2\n", scope $"Blank-line runs should collapse:\n{collapsedOut}");
	}

	[Test]
	public static void PreserveStyle_DottedKeysMixedWithHeadersKeepData()
	{
		for (let input in StringView[](
			"many.dots.here = {a.b = 1}\n",
			"[x]\na.b = 1\na.c.d = 2\n",
			"a.b = 1\n[a.c]\nx = 1\n",
			"a.b = 1\n[[a.list]]\nn = 1\n[[a.list]]\nn = 2\n",
			"[x]\na.b = 1\n[[x.a.list]]\nn = 1\n",
			"[fruit]\napple.color = \"red\"\napple.taste.sweet = true\n\n[fruit.apple.texture]\nsmooth = true\n"))
		{
			var doc = scope:: TomlDocument();
			ReadPreserving(doc, input);
			String output = scope String();
			doc.Write(output);
			var reparsed = scope:: TomlDocument();
			if (reparsed.Read(output) case .Err(let e))
			{
				defer e.Dispose();
				Test.Assert(false, scope $"Output does not re-parse: {e.mMessage}\nInput:\n{input}\nOutput:\n{output}");
				continue;
			}
			Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Data changed.\nInput:\n{input}\nOutput:\n{output}");
		}

		// A single dotted key stays a single dotted key (no synthesized [header] tables)
		var single = scope TomlDocument();
		ReadPreserving(single, "many.dots.here = 1\n");
		String singleOut = scope String();
		single.Write(singleOut);
		Test.Assert(singleOut == "many.dots.here = 1\n", scope $"Unexpected output:\n{singleOut}");
	}

	[Test]
	public static void PreserveStyle_BlankLineMarkersInCommentApiAndMerge()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "a = 1\n\n# about b\n\nb = 2\n");
		// The blank line is layout, not comment text
		String comment = scope String();
		Test.Assert(doc.RootTable.TryGetComment("b", comment) && comment == "about b", scope $"Got '{comment}'");

		// A merged key carries its comment block, including the blank line after it
		var merged = scope TomlDocument();
		ReadPreserving(merged, "x = 0\n");
		ReadPreserving(merged, "a = 1\n\n# about b\n\nb = 2\n", .Merge);
		String output = scope String();
		merged.Write(output);
		AssertContains(output, "# about b\n\nb = 2\n");
	}

	[Test]
	public static void PreserveStyle_TabIndentationKept()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "a = [\n\t1,\n\t2,\n]\nt = {\n\tx = 1,\n}\n");
		Test.Assert(doc.Metadata.mDocumentStyle.mUseTabs);

		Test.Assert(doc.TryGetArray("a", var a));
		a[0] = 10;
		String output = scope String();
		doc.Write(output);
		AssertContains(output, "a = [\n\t10,\n\t2,\n]");
		AssertContains(output, "t = {\n\tx = 1,\n}");

		// A new array in a tab-indented document is indented with one tab, not four
		var added = doc.AddArray("b");
		added.Add(1);
		String withNew = scope String();
		doc.Write(withNew);
		AssertContains(withNew, "b = [\n\t1,\n]");
		var reparsed = scope TomlDocument();
		ReadPreserving(reparsed, withNew, .Replace, .Error, .None);
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Output changed on re-read:\n{withNew}");
	}

	[Test]
	public static void PreserveStyle_NewArraysFollowDominantLayout()
	{
		var multiline = scope TomlDocument();
		ReadPreserving(multiline, "a = [\n  1,\n  2,\n]\nb = [\n  3,\n]\nc = [4]\n");
		var added = multiline.AddArray("n");
		added.Add(5);
		added.Add(6);
		String output = scope String();
		multiline.Write(output);
		AssertContains(output, "n = [\n  5,\n  6,\n]");
		AssertContains(output, "c = [4]");

		var singleLine = scope TomlDocument();
		ReadPreserving(singleLine, "a = [1, 2]\nb = [3]\n");
		var added2 = singleLine.AddArray("n");
		added2.Add(5);
		added2.Add(6);
		String output2 = scope String();
		singleLine.Write(output2);
		AssertContains(output2, "n = [5, 6]");
	}

	[Test]
	public static void PreserveStyle_CommentsInsideMultilineInlineTableKept()
	{
		let input = "t = {\n  # about a\n  a = 1, # trailing a\n  # about b\n  b = 2 # trailing b\n  ,\n  # closing\n}\n";
		var doc = scope TomlDocument();
		ReadPreserving(doc, input);

		String output = scope String();
		doc.Write(output);
		AssertContains(output, "  # about a\n  a = 1, # trailing a\n");
		AssertContains(output, "  # about b\n  b = 2, # trailing b\n");
		AssertContains(output, "  # closing\n}");

		// Editing a field keeps its comments
		Test.Assert(doc.TryGetTable("t", var t));
		t.SetInteger("a", 10);
		String edited = scope String();
		doc.Write(edited);
		AssertContains(edited, "  # about a\n  a = 10, # trailing a\n");

		var reparsed = scope TomlDocument();
		ReadPreserving(reparsed, edited);
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Output changed on re-read:\n{edited}");

		// TOML 1.0 has no multi-line inline tables: the table is written on one line without comments
		String v10 = scope String();
		doc.Write(v10, .() { Version = .V1_0 });
		var reparsed10 = scope TomlDocument();
		if (reparsed10.Read(v10, .() { Version = .V1_0 }) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"V1_0 output is not valid TOML 1.0: {e.mMessage}\n{v10}");
		}
		Test.Assert(!v10.Contains("#"), scope $"Comments cannot be kept in a single-line inline table:\n{v10}");
	}

	[Test]
	public static void PreserveStyle_QuotedKeyStylesKept()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "'raw key' = 1\n\"simple\" = 2\nbare = 3\n\"has'quote\" = 4\nt = { 'lk' = 5, \"bk\" = 6 }\n'dot'.leaf = 7");

		String output = scope String();
		doc.Write(output);
		AssertContains(output, "'raw key' = 1");
		AssertContains(output, "\"simple\" = 2");
		AssertContains(output, "bare = 3");
		AssertContains(output, "\"has'quote\" = 4");
		AssertContains(output, "'lk' = 5");
		AssertContains(output, "\"bk\" = 6");
		Test.Assert(!output.Contains("'leaf'"), scope $"A dotted key's first-segment quoting must not apply to the leaf:\n{output}");

		// A literal-quoted key renamed to something a literal key cannot hold falls back to basic quotes
		Test.Assert(doc.RootTable[0].Rename("it's") case .Ok);
		String renamed = scope String();
		doc.Write(renamed);
		AssertContains(renamed, "\"it's\" = 1");

		var reparsed = scope TomlDocument();
		ReadPreserving(reparsed, renamed, .Replace, .Error, .None);
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Output changed on re-read:\n{renamed}");
	}

	[Test]
	public static void PreserveStyle_DateTimeSeparatorAndZCaseKept()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "a = 1979-05-27t07:32:00z\nb = 1979-05-27 07:32:00Z\nc = 1979-05-27t07:32:00\nd = 1979-05-27T07:32:00Z");

		String clean = scope String();
		doc.Write(clean);
		AssertContains(clean, "a = 1979-05-27t07:32:00z");
		AssertContains(clean, "b = 1979-05-27 07:32:00Z");
		AssertContains(clean, "c = 1979-05-27t07:32:00");
		AssertContains(clean, "d = 1979-05-27T07:32:00Z");

		// Edited values keep the captured separator and Z case
		doc.RootTable.SetOffsetDateTime("a", TomlOffsetDateTime(2000, 1, 2, 3, 4, 5, 0, 0));
		doc.RootTable.SetLocalDateTime("c", TomlLocalDateTime(2000, 1, 2, 3, 4, 5, 0));
		String edited = scope String();
		doc.Write(edited);
		AssertContains(edited, "a = 2000-01-02t03:04:05z");
		AssertContains(edited, "c = 2000-01-02t03:04:05");
	}

	[Test]
	public static void PreserveStyle_MergeKeepsBaseStyleAndBringsIncomingStyle()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "# base header\nname = 'base'\nport = 0x1F\n\n[server]\nhost = \"a\\u0020b\"");
		ReadPreserving(doc, "# about extra\nextra = 0o17\n\n[server]\n# about timeout\ntimeout = 1e3\n\n[[items]]\nn = 0b101", .Merge);

		String output = scope String();
		doc.Write(output);
		// Destination style is untouched
		AssertContains(output, "# base header\nname = 'base'");
		AssertContains(output, "port = 0x1F");
		AssertContains(output, "host = \"a\\u0020b\"");
		// Incoming values keep their own formats and comments, including inside a shared table
		AssertContains(output, "# about extra\nextra = 0o17");
		AssertContains(output, "# about timeout\ntimeout = 1e3");
		AssertContains(output, "n = 0b101");

		var reparsed = scope TomlDocument();
		ReadPreserving(reparsed, output, .Replace, .Error, .None);
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"Merged output changed on re-read:\n{output}");

		// Merged nodes stay editable with their captured format
		doc.RootTable.SetInteger("extra", 8);
		String edited = scope String();
		doc.Write(edited);
		AssertContains(edited, "extra = 0o10");
	}

	[Test]
	public static void PreserveStyle_MergeOverwriteTakesIncomingValueStyleKeepsSlotComments()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "# port comment\nport = 0x1F\ns = 'lit'");
		ReadPreserving(doc, "# ignored comment\nport = 0o17\ns = \"esc\\u0041\"", .Merge, .Overwrite);

		String output = scope String();
		doc.Write(output);
		AssertContains(output, "# port comment\nport = 0o17");
		AssertContains(output, "s = \"esc\\u0041\"");
		Test.Assert(!output.Contains("# ignored comment"), scope $"Overwrite keeps the destination slot's comments:\n{output}");
	}

	[Test]
	public static void PreserveStyle_MergeWithoutIncomingMetadataUsesSlotFormats()
	{
		var doc = scope TomlDocument();
		ReadPreserving(doc, "port = 0x1F\n[t]\nx = 1");
		// The override is read without PreserveStyle, so only the destination has style data
		ReadPreserving(doc, "port = 32\nadded = 5\n[t]\ny = 2", .Merge, .Overwrite, .None);

		Test.Assert(doc.Metadata != null);
		String output = scope String();
		doc.Write(output);
		AssertContains(output, "port = 0x20");
		AssertContains(output, "added = 5");
		AssertContains(output, "y = 2");
		Test.Assert(StyleFor(doc, "port").mDirtyFlags == .Value, "Overwritten value without incoming style is dirty");
		Test.Assert(NodeIdFor(doc, "t.y").IsValid);
	}

	[Test]
	public static void PreserveStyle_ClearedTableKeepsCommentsAndTracksNewKeys()
	{
		var doc = scope TomlDocument();
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 1\n\n# about t\n[t] # trailing\nx = 1\ny = 2", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetTable("t", var t));
		t.Clear();
		Test.Assert(t.MetadataContext != null, "Clear must keep the table's metadata context");
		Test.Assert((doc.Metadata.GetNodeStyle(t.MetadataContext.mNodeId).mDirtyFlags & .Children) != 0, "Clear should mark children dirty");

		t.SetString("z", "new");
		Test.Assert(NodeIdFor(doc, "t.z").IsValid, "Keys added after Clear should get node IDs");

		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("# about t\n[t] # trailing\n"), scope $"Header comments should survive Clear:\n{output}");
		Test.Assert(output.Contains("z = \"new\"") && !output.Contains("x = 1"), scope $"Unexpected content after Clear:\n{output}");
	}

	[Test]
	public static void PreserveStyle_InlineTableFieldsKeepTokensAndFormats()
	{
		var doc = scope TomlDocument();
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = { s = \"a\\u0020b\", n = 0xFF, d = 1979-05-27 07:32:00Z, sub.f = 1e3 }";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String clean = scope String();
		doc.Write(clean);
		Test.Assert(clean.Contains("s = \"a\\u0020b\""), scope $"String token inside inline table should be reused:\n{clean}");
		Test.Assert(clean.Contains("n = 0xFF"), scope $"Hex format inside inline table lost:\n{clean}");
		Test.Assert(clean.Contains("d = 1979-05-27 07:32:00Z"), scope $"Datetime format inside inline table lost:\n{clean}");
		Test.Assert(clean.Contains("f = 1e3"), scope $"Float format inside dotted inline key lost:\n{clean}");

		// Editing one field keeps its format; untouched siblings keep their tokens
		Test.Assert(doc.TryGetTable("t", var t));
		t.SetInteger("n", 16);
		Test.Assert(StyleFor(doc, "t.n").mDirtyFlags == .Value, "Edited inline field should be dirty");
		Test.Assert(StyleFor(doc, "t.s").mDirtyFlags == .None, "Untouched inline field should stay clean");
		String edited = scope String();
		doc.Write(edited);
		Test.Assert(edited.Contains("n = 0x10"), scope $"Edited hex field should keep hex format:\n{edited}");
		Test.Assert(edited.Contains("s = \"a\\u0020b\""), scope $"Sibling token should still be reused:\n{edited}");
	}

	[Test]
	public static void PreserveStyle_V1_0WriteRegeneratesTokensWithV1_1Escapes()
	{
		var doc = scope TomlDocument();
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "e = \"a\\eb\"\nx = \"c\\x41\"\nsafe = \"keep\\\\e\"\nlit = 'lit\\e'\narr = [\"y\\e\", \"z\"]";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		String v10 = scope String();
		doc.Write(v10, .() { Version = .V1_0 });
		var reparsed = scope TomlDocument();
		if (reparsed.Read(v10, .() { Version = .V1_0 }) case .Err(let e2))
		{
			defer e2.Dispose();
			Test.Assert(false, scope $"V1_0 output is not valid TOML 1.0: {e2.mMessage}\n{v10}");
		}
		Test.Assert(TomlDocumentEquals(doc, reparsed), scope $"V1_0 output changed values:\n{v10}");
		// Tokens without 1.1-only escapes are still reused verbatim
		Test.Assert(v10.Contains("safe = \"keep\\\\e\""), scope $"Escaped backslash token should be reused:\n{v10}");
		Test.Assert(v10.Contains("lit = 'lit\\e'"), scope $"Literal token should be reused:\n{v10}");

		// A 1.1 write still reuses the original tokens
		String v11 = scope String();
		doc.Write(v11);
		Test.Assert(v11.Contains("e = \"a\\eb\"") && v11.Contains("x = \"c\\x41\""), scope $"V1_1 write should reuse tokens:\n{v11}");
	}

	/// Parses `input` in PreserveStyle mode via string and via stream, applies `mutate`, and requires identical output.
	static void AssertStreamMatchesStringPreserveStyle(StringView input, delegate void(TomlDocument doc) mutate)
	{
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;

		var fromString = scope TomlDocument();
		if (fromString.Read(input, config) case .Err(let e1))
		{
			defer e1.Dispose();
			Test.Assert(false, scope $"String parse failed: {e1.mMessage}");
			return;
		}

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>((uint8*)input.Ptr, input.Length));
		ms.Position = 0;
		var fromStream = scope TomlDocument();
		if (fromStream.Read(ms, config) case .Err(let e2))
		{
			defer e2.Dispose();
			Test.Assert(false, scope $"Stream parse failed: {e2.mMessage}");
			return;
		}

		mutate(fromString);
		mutate(fromStream);
		String outString = scope String();
		fromString.Write(outString);
		String outStream = scope String();
		fromStream.Write(outStream);
		Test.Assert(outString == outStream, scope $"Stream output differs from string output (lengths {outString.Length} vs {outStream.Length})");
	}

	[Test]
	public static void PreserveStyle_StreamMultilineArrayCrossesBuffer()
	{
		// A multiline array far larger than the 8 KiB stream buffer, so refills happen mid-container.
		String input = scope String("arr = [\n");
		for (int i = 0; i < 2000; i++)
			input.AppendF("  {},\n", i);
		input.Append("]\n");
		AssertStreamMatchesStringPreserveStyle(input, scope (doc) =>
		{
			doc.RootTable.TryGetArray("arr", var arr);
			arr[1] = 42;
		});
	}

	[Test]
	public static void PreserveStyle_StreamInlineTableCrossesBuffer()
	{
		String input = scope String();
		input.Append("# pad\n");
		for (int i = 0; i < 8150; i++)
			input.Append('#');
		input.Append("\nt = { a = 1, b = 'x', c = [1, 2] }\n");
		AssertStreamMatchesStringPreserveStyle(input, scope (doc) =>
		{
			doc.RootTable.TryGetTable("t", var t);
			t.SetInteger("a", 2);
		});
	}

	[Test]
	public static void PreserveStyle_StreamDottedLiteralKeyCrossesBuffer()
	{
		String input = scope String();
		for (int i = 0; i < 8170; i++)
			input.Append('#');
		input.Append("\n'lit'.\"quoted\".bare = 'v'\nplain = 1\n");
		AssertStreamMatchesStringPreserveStyle(input, scope (doc) =>
		{
			doc.SetInteger("plain", 2);
		});
	}
}
