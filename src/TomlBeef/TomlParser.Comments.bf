using System;
using System.Collections;
using internal TomlBeef;

namespace TomlBeef;

/// TomlParserImpl: comment skipping, capture, and attachment to nodes.
extension TomlParserImpl<TCursor> where TCursor : ITomlCursor
{
	// ================================================================
	// Comment capture helpers
	// ================================================================

	/// @brief Skip a TOML comment using parser-level TOML semantics.
	/// Requires/consumes #, validates comment control chars, and consumes newline if present.
	private Result<void, TomlParseError> SkipCommentText()
	{
		if (mCursor.PeekByte() != '#') return .Ok;
		mCursor.AdvanceByte(); // skip #
		Try!(ScanCommentBody(null));
		CountAndSkipNewline();
		return .Ok;
	}

	/// Consumes a comment's text up to the end of its line (or EOF), appending it to `outText` unless null.
	/// Control characters other than tab, and a CR not followed by LF, are errors at that character.
	private Result<void, TomlParseError> ScanCommentBody(String outText)
	{
		mCursor.ScanRun(TomlChar.StopComment, outText);
		if (mCursor.IsEOF)
			return .Ok;
		char8 b = mCursor.PeekByte();
		if (b == '\n')
			return .Ok;
		if (b == '\r')
		{
			if (mCursor.PeekByteAt(1) == '\n')
				return .Ok;
			return .Err(Error(.ControlCharInDocument, "Bare CR in comment"));
		}
		// Handle stream EOF where PeekByte() returns 0 before IsEOF is true
		if (b == 0 && mCursor.IsEOF)
			return .Ok;
		return .Err(Error(.ControlCharInDocument, "Control character in comment"));
	}

	/// @brief Capture a comment (PreserveStyle only) and store its text in the sidecar's text arena.
	/// Requires the cursor at '#'. Consumes the comment and its newline, validating control characters,
	/// and drops only the single conventional space after '#'.
	/// @return A view of the stored text, valid as long as the sidecar.
	private Result<StringView, TomlParseError> CaptureComment()
	{
		mCursor.AdvanceByte(); // skip #
		mCommentScratch.Clear();
		Try!(ScanCommentBody(mCommentScratch));
		CountAndSkipNewline();
		StringView text = mCommentScratch;
		if (text.Length > 0 && text[0] == ' ')
			text = text.Substring(1);
		return mStyle.mText.Add(text);
	}

	/// @brief Capture a comment line and add it to the pending leading comments list.
	private Result<void, TomlParseError> CapturePendingComment()
	{
		if (mStyle == null)
		{
			// Not capturing style — just skip the comment
			return SkipCommentText();
		}
		mPendingComments.Add(Try!(CaptureComment()));
		return .Ok;
	}

	/// @brief Capture a trailing comment on the same line as a key/val or header.
	/// Stores it in mTrailingCommentText for later attachment.
	private Result<void, TomlParseError> CaptureTrailingComment()
	{
		if (mStyle == null)
			return SkipCommentText();
		mTrailingCommentText = default;
		mTrailingCommentText = Try!(CaptureComment());
		return .Ok;
	}

	/// @brief Attach pending leading comments to a node.
	private void AttachPendingComments(TomlNodeId nodeId)
	{
		if (mStyle == null)
			return;

		// If there are comments or a blank line preceded this node, create a comment set
		if (mPendingComments.Count == 0 && mSavedBlankLineCount == 0)
			return;

		let commentSet = mStyle.GetOrCreateCommentSet(nodeId);
		if (commentSet != null)
		{
			if (mPendingComments.Count > 0)
			{
				for (int i = 0; i < mPendingComments.Count; i++)
					commentSet.mLeading.Add(mPendingComments[i]);
				mPendingComments.Clear();
			}
			// If a blank line preceded this content, mark it on the comment set
			if (mSavedBlankLineCount > 0)
				commentSet.mSeparatedByBlankLine = true;
			mSavedBlankLineCount = 0;
		}
	}

	/// @brief Attach the stored trailing comment to a node.
	private void AttachTrailingComment(TomlNodeId nodeId)
	{
		if (mStyle == null || TomlCommentSet.IsAbsent(mTrailingCommentText))
			return;

		let commentSet = mStyle.GetOrCreateCommentSet(nodeId);
		if (commentSet != null)
			commentSet.mTrailing = mTrailingCommentText;
		mTrailingCommentText = default;
	}

	/// @brief Attach any remaining pending comments as file header comments on the root node.
	private void AttachPendingCommentsToRoot()
	{
		if (mStyle == null || mPendingComments.Count == 0)
			return;

		// The writer always separates file-header comments from content, so a trailing blank marker is implied
		TrimTrailingBlankMarkers();
		let commentSet = mStyle.GetOrCreateRootComments();
		// A second block reaches the root only after a blank line, so keep that separation
		if (!commentSet.mLeading.IsEmpty && !mPendingComments.IsEmpty)
			commentSet.mLeading.Add(null);
		for (int i = 0; i < mPendingComments.Count; i++)
			commentSet.mLeading.Add(mPendingComments[i]);
		mPendingComments.Clear();
	}

	/// @brief Attach any remaining pending comments as footer/EOF comments.
	private void AttachPendingCommentsToFooter()
	{
		if (mStyle == null || mPendingComments.Count == 0)
			return;

		// Blank lines at the very end of the file are not kept
		TrimTrailingBlankMarkers();
		let commentSet = mStyle.GetOrCreateFooterComments();
		for (int i = 0; i < mPendingComments.Count; i++)
			commentSet.mLeading.Add(mPendingComments[i]);
		if (mBlankLineCount > 0)
			commentSet.mSeparatedByBlankLine = true;
		mPendingComments.Clear();
	}

	/// Drops blank-line markers (null entries) from the end of the pending comment block.
	private void TrimTrailingBlankMarkers()
	{
		while (!mPendingComments.IsEmpty && TomlCommentSet.IsAbsent(mPendingComments.Back))
			mPendingComments.PopBack();
	}

	/// Count and skip a newline for document-level style inference.
	/// Use for document-structure newlines; string parsing should use plain SkipNewline().
	private void CountAndSkipNewline()
	{
		if (mStyle != null)
		{
			char8 b = mCursor.PeekByte();
			if (b == '\r' && mCursor.PeekByteAt(1) == '\n')
				mCrlfCount++;
			else if (b == '\n')
				mLfOnlyCount++;
		}
		mCursor.SkipNewline();
	}
}
