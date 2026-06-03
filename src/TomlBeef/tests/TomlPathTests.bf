using System;
using System.Collections;
using TomlBeef;

namespace TomlBeef;

static class TomlPathTests
{
	[Test]
	public static void QuotedPath_BareDottedStillWorks()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[a]\nb.c = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Existing bare dotted path still works
		Test.Assert(doc.TryGetInteger("a.b.c", var val) && val == 1);
		// GetPath with params
		Test.Assert(doc.GetPath("a", "b", "c") case .Ok(let v) && v.IsInteger && v.AsInteger == 1);
	}

	[Test]
	public static void QuotedPath_RootKeyWithDot()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"a.b\" = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Bracket syntax to access key containing '.'
		Test.Assert(doc.TryGetInteger("[a.b]", var val) && val == 1);
		// Bare dotted path should NOT find it (it would split into ["a", "b"])
		Test.Assert(!doc.TryGetInteger("a.b", var _));
	}

	[Test]
	public static void QuotedPath_NestedKeyWithDot()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[servers]\n\"192.168.1.1\" = { host = \"db1\" }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Access server's IP with bracket syntax, then read a sub-field
		Test.Assert(doc.TryGetString("servers.[192.168.1.1].host", var host) && host == "db1");
		// GetPath with params
		Test.Assert(doc.GetPath("servers", "192.168.1.1", "host") case .Ok(let v) && v.IsString && v.AsString == "db1");
	}

	[Test]
	public static void QuotedPath_MultipleBracketedSegments()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"a.b\" = { \"c.d\" = { \"e.f\" = 1 } }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		Test.Assert(doc.TryGetInteger("[a.b].[c.d].[e.f]", var val) && val == 1);
	}

	[Test]
	public static void QuotedPath_MalformedSyntaxRejected()
	{
		var doc = new TomlDocument();
		defer delete doc;
		// Setup: create keys where malformed paths would resolve if accepted
		if (doc.Read("a = { b = 1 }\n\"x.y\" = { z = 2 }") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Empty path
		Test.Assert(doc.Get("") case .Err);
		// Leading dot
		Test.Assert(doc.Get(".a") case .Err);
		// Trailing dot
		Test.Assert(doc.Get("a.") case .Err);
		// Consecutive dots
		Test.Assert(doc.Get("a..b") case .Err);
		// Empty bracketed segment
		Test.Assert(doc.Get("a.[].b") case .Err);
		// Unmatched opening bracket
		Test.Assert(doc.Get("a.[b") case .Err);
		// Unmatched closing bracket — would hit "a.b]" as a bare key path if accepted
		Test.Assert(doc.Get("a.b]") case .Err);
		// Unmatched bracket in middle
		Test.Assert(doc.Get("a.[b].[c") case .Err);
		// Bare segment containing '[' should be rejected
		Test.Assert(doc.Get("a[b") case .Err);
		// Bare segment containing ']' should be rejected
		Test.Assert(doc.Get("a]b") case .Err);
		// Missing dot between bracketed and bare segment
		Test.Assert(doc.Get("[a]b") case .Err);
		// Missing dot between bare and bracketed segment
		Test.Assert(doc.Get("a.[b]c") case .Err);
		// Bracketed segment followed by garbage
		Test.Assert(doc.Get("a.[b]x") case .Err);

		// Bare segment immediately followed by bracket: a[b] should NOT parse as ["a", "b"]
		Test.Assert(doc.Get("a[b]") case .Err);
	}

	[Test]
	public static void QuotedPath_TryGetTypedInheritsBracketSyntax()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("\"x.y\" = \"hello\"") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// Typed accessor should inherit bracket syntax via Get()
		Test.Assert(doc.TryGetString("[x.y]", var val) && val == "hello");
	}

	[Test]
	public static void QuotedPath_GetPathParams()
	{
		var doc = new TomlDocument();
		defer delete doc;
		if (doc.Read("[a]\nb.c = 1") case .Err(let e))
		{
			defer e.Dispose();
			Test.Assert(false, scope $"Parse failed: {e.mMessage}");
		}
		// params StringView[] — clean multi-segment syntax
		Test.Assert(doc.GetPath("a", "b", "c") case .Ok(let v) && v.IsInteger && v.AsInteger == 1);

		// Single segment
		if (doc.Read("x = 42") case .Err(let e2))
		{
			defer e2.Dispose();
			Test.Assert(false, scope $"Parse failed: {e2.mMessage}");
		}
		Test.Assert(doc.GetPath("x") case .Ok(let v2) && v2.IsInteger && v2.AsInteger == 42);

		// GetPath is the escape hatch for keys bracket syntax can't represent.
		// A key containing ']' cannot be reached via string-path syntax.
		if (doc.Read("\"weird]key\" = 1") case .Err(let e2b))
		{
			defer e2b.Dispose();
			Test.Assert(false, scope $"Parse failed: {e2b.mMessage}");
		}
		Test.Assert(doc.Get("weird]key") case .Err);
		Test.Assert(doc.GetPath("weird]key") case .Ok(let v3) && v3.IsInteger && v3.AsInteger == 1);

		// List<StringView> overload for programmatic callers
		var segs = scope List<StringView>();
		segs.Add("a");
		segs.Add("b");
		segs.Add("c");
		if (doc.Read("[a]\nb.c = 99") case .Err(let e3))
		{
			defer e3.Dispose();
			Test.Assert(false, scope $"Parse failed: {e3.mMessage}");
		}
		Test.Assert(doc.GetPath(segs) case .Ok(let v4) && v4.IsInteger && v4.AsInteger == 99);
	}
}
