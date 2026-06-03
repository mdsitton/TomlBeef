using System; using System.Collections; using System.IO; using TomlBeef; using internal TomlBeef; using static TomlBeef.TomlTestSupport; namespace TomlBeef; static class TomlPreserveStyleWriterTests {
	[Test]
	public static void PreserveStyle_LeadingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# leading comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Check that the node has a leading comment
		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading comment");
	}

	[Test]
	public static void PreserveStyle_TrailingComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1 # trailing comment";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing == "trailing comment");
	}

	[Test]
	public static void PreserveStyle_LeadingAndTrailingComment()
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
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "leading");
		Test.Assert(commentSet.mTrailing != null);
		Test.Assert(commentSet.mTrailing == "trailing");
	}

	[Test]
	public static void PreserveStyle_MultipleLeadingComments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# comment 1\n# comment 2\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 2);
		Test.Assert(commentSet.mLeading[0] == "comment 1");
		Test.Assert(commentSet.mLeading[1] == "comment 2");
	}

	[Test]
	public static void PreserveStyle_CommentBeforeTableHeader()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# table comment\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// The server table should have the comment
		let serverTable = doc.RootTable.Entries["server"].AsTable;
		Test.Assert(serverTable.MetadataContext != null);
		let nodeId = serverTable.MetadataContext.mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(commentSet != null);
		Test.Assert(commentSet.mLeading.Count == 1);
		Test.Assert(commentSet.mLeading[0] == "table comment");
	}

	[Test]
	public static void PreserveStyle_FileHeaderComment()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Blank line separates the comment from [server], making it a root comment
		let input = "# file header\n\n[server]\nport = 8080";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// The file header comment should be on the dedicated root comment set
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "file header");
	}

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
	public static void PreserveStyle_CommentOnMultpleKeys()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# first comment\na = 1\n# second comment\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);

		// Check first key
		let nodeIdA = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSetA = doc.Metadata.GetCommentSet(nodeIdA);
		Test.Assert(commentSetA != null);
		Test.Assert(commentSetA.mLeading.Count == 1);
		Test.Assert(commentSetA.mLeading[0] == "first comment");

		// Check second key
		let nodeIdB = doc.Metadata.mNodeStyles[1].mNodeId;
		let commentSetB = doc.Metadata.GetCommentSet(nodeIdB);
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "second comment");
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

		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSet = doc.Metadata.GetCommentSet(nodeId);
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
	public static void PreserveStyle_RootCommentDoesNotCollideWithFirstNode()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Blank line separates root comment from the leading comment for 'a'
		let input = "# root comment\n\n# first node comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 1);

		// Root comment should be on dedicated root comment set
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "root comment");

		// First node comment should be on first node (node ID 0)
		let firstNodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let firstComments = doc.Metadata.GetCommentSet(firstNodeId);
		Test.Assert(firstComments != null);
		Test.Assert(firstComments.mLeading.Count == 1);
		Test.Assert(firstComments.mLeading[0] == "first node comment");
	}

	[Test]
	public static void PreserveStyle_DetachedCommentSeparatedByBlankLine()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "# detached comment\n\n# leading comment\na = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);

		// Detached comment should be on root comment set (separated by blank line)
		let rootComments = doc.Metadata.mRootComments;
		Test.Assert(rootComments != null);
		Test.Assert(rootComments.mLeading.Count == 1);
		Test.Assert(rootComments.mLeading[0] == "detached comment");

		// Leading comment should be on the key node
		let nodeId = doc.Metadata.mNodeStyles[0].mNodeId;
		let nodeComments = doc.Metadata.GetCommentSet(nodeId);
		Test.Assert(nodeComments != null);
		Test.Assert(nodeComments.mLeading.Count == 1);
		Test.Assert(nodeComments.mLeading[0] == "leading comment");
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
	public static void PreserveStyle_DetachedAfterContentStaysWithNextNode()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "a = 1\n\n# note for b\nb = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mNodeStyles.Count == 2);

		// 'a' should have no comments
		let nodeIdA = doc.Metadata.mNodeStyles[0].mNodeId;
		let commentSetA = doc.Metadata.GetCommentSet(nodeIdA);
		Test.Assert(commentSetA == null || commentSetA.mLeading.Count == 0);

		// 'b' should have the comment (detached after content stays with next node)
		let nodeIdB = doc.Metadata.mNodeStyles[1].mNodeId;
		let commentSetB = doc.Metadata.GetCommentSet(nodeIdB);
		Test.Assert(commentSetB != null);
		Test.Assert(commentSetB.mLeading.Count == 1);
		Test.Assert(commentSetB.mLeading[0] == "note for b");

		// Root comments should be empty (no pre-content detached comments)
		Test.Assert(doc.Metadata.mRootComments == null || doc.Metadata.mRootComments.mLeading.Count == 0);
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

	[Test]
	public static void PreserveStyle_StreamCommentAtEof()
	{
		// Build a comment at EOF (no trailing newline)
		List<uint8> bytes = scope .();
		AddAscii(bytes, "# eof comment");

		let ms = scope MemoryStream();
		ms.TryWrite(Span<uint8>(bytes.Ptr, (int)bytes.Count));
		ms.Position = 0;

		// First parse without metadata to establish a value
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("a = 1", config) case .Err(let setupErr))
		{
			defer setupErr.Dispose();
			Test.Assert(false, scope $"Setup parse failed: {setupErr.mMessage}");
		}

		// Parse the stream comment (EOF without newline)
		if (doc.Read(ms, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// The comment should be captured correctly (trimmed leading space)
		Test.Assert(doc.Metadata != null);
		Test.Assert(doc.Metadata.mRootComments != null);
		Test.Assert(doc.Metadata.mRootComments.mLeading.Count == 1);
		Test.Assert(doc.Metadata.mRootComments.mLeading[0] == "eof comment");
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
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
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
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
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
		let fmt = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
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
			let fmtA = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[0].mValueFormatRef.mIndex];
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
			let fmtB = doc.Metadata.mValueFormats[doc.Metadata.mNodeStyles[1].mValueFormatRef.mIndex];
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
	public static void PreserveStyle_InlineTableFormatCaptured()
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

		// Check that table format was captured
		let nodeId = doc.Metadata.mNodeStyles[0];
		Test.Assert(nodeId.mValueFormatRef.IsValid);
		let fmt = doc.Metadata.mValueFormats[nodeId.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mInline == true);
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
		}
		else
			Test.Assert(false, "Expected Table format");
	}

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
		let nodeId = doc.Metadata.mNodeStyles[0];
		let fmt = doc.Metadata.mValueFormats[nodeId.mValueFormatRef.mIndex];
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
	public static void PreserveStyle_InlineTableSpacedEqualsAndComma()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "t = { a = 1 , b = 2 }";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		TomlNodeId nodeId = .Invalid;
		doc.RootTable.MetadataContext.TryGetEntryNodeId("t", out nodeId);
		let style = doc.Metadata.GetNodeStyle(nodeId);
		let fmt = doc.Metadata.mValueFormats[style.mValueFormatRef.mIndex];
		if (fmt case .Table(let tFmt))
		{
			Test.Assert(tFmt.mEqualsSpacing == 1, scope $"Expected equals spacing 1, got {tFmt.mEqualsSpacing}");
			Test.Assert(tFmt.mCommaSpacing == 1, scope $"Expected comma spacing 1, got {tFmt.mCommaSpacing}");
			Test.Assert(tFmt.mOpenBraceSpacing == 1, scope $"Expected open brace spacing 1, got {tFmt.mOpenBraceSpacing}");
			Test.Assert(tFmt.mCloseBraceSpacing == 1, scope $"Expected close brace spacing 1, got {tFmt.mCloseBraceSpacing}");
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
	public static void PreserveStyle_BlankLineMetadataCaptured()
	{
		// Verify blank line metadata is correctly distinguished between
		// separated and non-separated cases
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "[a]\nx = 1\n\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine,
			"First table should not have blank line flag");

		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		Test.Assert(csB != null && csB.mSeparatedByBlankLine,
			"Second table should have blank line flag");
	}

	[Test]
	public static void PreserveStyle_NoBlankLineForDirectAdjacentSections()
	{
		// Direct-adjacent sections (no blank line between) should NOT get blank line flag
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		let input = "[a]\nx = 1\n[b]\ny = 2";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetTable("a", var tblA);
		let csA = doc.Metadata.GetCommentSet(tblA.MetadataContext.mNodeId);
		Test.Assert(csA == null || !csA.mSeparatedByBlankLine,
			"Table a should not have blank line flag");

		doc.RootTable.TryGetTable("b", var tblB);
		let csB = doc.Metadata.GetCommentSet(tblB.MetadataContext.mNodeId);
		// When sections are directly adjacent, [b]'s header follows immediately
		// after the preceding content's newline with no extra blank line.
		// mBlankLineCount catches the single newline between sections but only
		// flags it as separatedByBlankLine when there's at least one extra.
		Test.Assert(csB == null || !csB.mSeparatedByBlankLine,
			"Table b should not have blank line flag when directly adjacent");
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
	public static void PreserveStyle_NestedMutationDoesNotDirtyParent()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		// Nested table: [tbl] with entry x = 1
		let input = "[tbl]\nx = 1";
		if (doc.Read(input, config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		// Verify all nodes start clean
		for (int i = 0; i < doc.Metadata.mNodeStyles.Count; i++)
			Test.Assert(doc.Metadata.mNodeStyles[i].mDirtyFlags == .None,
				scope $"Node {i} should start clean");

		// Mutate x inside [tbl]
		doc.RootTable.TryGetTable("tbl", var tbl);
		tbl.ReplaceValue("x", .Integer(42));

		// Find node IDs
		doc.RootTable.MetadataContext.TryGetEntryNodeId("tbl", let tblNodeId);
		Test.Assert(tblNodeId.IsValid);
		tbl.MetadataContext.TryGetEntryNodeId("x", let xNodeId);
		Test.Assert(xNodeId.IsValid);

		// The x entry should be dirty
		let xStyle = doc.Metadata.GetNodeStyle(xNodeId);
		Test.Assert(xStyle != null && xStyle.mDirtyFlags == .Value,
			"x entry should have Value dirty flag");

		// The tbl entry and the root table should NOT be dirty
		let tblStyle = doc.Metadata.GetNodeStyle(tblNodeId);
		Test.Assert(tblStyle != null && tblStyle.mDirtyFlags == .None,
			"Parent tbl entry should remain clean after child mutation");

		// Mutate tbl itself — should mark tbl dirty
		// Re-fetch style after Insert since it may reallocate mNodeStyles
		tbl.Insert("y", .Integer(99));
		let tblStyle2 = doc.Metadata.GetNodeStyle(tblNodeId);
		Test.Assert(tblStyle2 != null && (tblStyle2.mDirtyFlags & .Children) != 0,
			"Parent tbl should get Children dirty after direct insertion");
	}

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
		Test.Assert(doc.Metadata.mValueFormats.Count == 1);
		let fmt = doc.Metadata.mValueFormats[0];
		if (fmt case .Integer(let intFmt))
			Test.Assert(intFmt.mBase == .Hex);
		else
			Test.Assert(false, "Expected Integer format");

		// Verify node has format ref
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mValueFormatRef.IsValid);

		// Mutate the value to a different hex value
		bool replaced = doc.RootTable.ReplaceValue("n", .Integer(0x12345));
		Test.Assert(replaced);

		// Verify dirty
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .Value);

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
	public static void PreserveStyle_ArrayAddMarksChildrenDirtyAfterParse()
	{
		var doc = new TomlDocument();
		defer delete doc;
		var config = TomlReadConfig();
		config.MetadataMode = .PreserveStyle;
		if (doc.Read("arr = [1]", config) case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}

		doc.RootTable.TryGetArray("arr", var arr);
		let nodeId = arr.MetadataContext.mNodeId;
		Test.Assert(doc.Metadata.mNodeStyles[nodeId.mIndex].mDirtyFlags == .None);

		arr.Add(.Integer(2));
		Test.Assert(doc.Metadata.mNodeStyles[nodeId.mIndex].mDirtyFlags == .Children);
	}

	[Test]
	public static void PreserveStyle_ReplaceEqualValueKeepsClean()
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
		let style = doc.Metadata.mNodeStyles[0];
		Test.Assert(style.mOriginalValueToken.IsValid);
		Test.Assert(style.mDirtyFlags == .None);

		// Replace with same value
		doc.RootTable.SetString("s", "original");
		Test.Assert(doc.Metadata.mNodeStyles[0].mDirtyFlags == .None); // still clean
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
		Test.Assert(doc.Metadata.mNodeStyles[0].mOriginalValueToken.IsValid);

		// Remove and reinsert with a new value
		doc.RootTable.Remove("a");
		doc.RootTable.SetString("a", "new");

		// Writer should emit 'new', not 'old'
		String output = scope String();
		doc.Write(output);
		Test.Assert(output.Contains("new"));
		Test.Assert(!output.Contains("old"));
	}

}
