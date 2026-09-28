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

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			// Handle stream EOF where PeekByte() returns 0 before IsEOF is true
			if (b == 0 && mCursor.IsEOF)
				break;
			if (b == '\r')
			{
				if (mCursor.PeekByteAt(1) == '\n')
					break;
				return .Err(Error(.ControlCharInDocument, "Bare CR in comment"));
			}
			if (b == '\n') break;

			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInDocument, "Control character in comment"));

			mCursor.AdvanceByte();
		}
		CountAndSkipNewline();
		return .Ok;
	}

	/// @brief Capture comment text from the cursor into outText.
	/// Requires/consumes #, copies bytes until newline/CRLF/EOF,
	/// validates comment control chars, consumes newline if present,
	/// and normalizes only the single leading space after #.
	private Result<void, TomlParseError> CaptureCommentText(String outText)
	{
		if (mCursor.PeekByte() != '#') return .Ok;
		mCursor.AdvanceByte(); // skip #

		while (!mCursor.IsEOF)
		{
			char8 b = mCursor.PeekByte();
			// Handle stream EOF where PeekByte() returns 0 before IsEOF is true
			if (b == 0 && mCursor.IsEOF)
				break;
			if (b == '\r')
			{
				if (mCursor.PeekByteAt(1) == '\n')
					break;
				return .Err(Error(.ControlCharInDocument, "Bare CR in comment"));
			}
			if (b == '\n') break;

			if (((uint8)b < 0x20 && b != '\t') || (uint8)b == 0x7F)
				return .Err(Error(.ControlCharInDocument, "Control character in comment"));

			outText.Append(b);
			mCursor.AdvanceByte();
		}
		CountAndSkipNewline();
		// Trim only leading space (the conventional space after #)
		if (outText.Length > 0 && outText[0] == ' ')
			outText.Remove(0, 1);
		return .Ok;
	}

	/// @brief Capture a comment line and add it to the pending leading comments list.
	private Result<void, TomlParseError> CapturePendingComment()
	{
		if (mStyle == null)
		{
			// Not capturing style — just skip the comment
			return SkipCommentText();
		}

		String commentText = new String();
		if (CaptureCommentText(commentText) case .Err(let e))
		{
			delete commentText;
			return .Err(e);
		}
		mPendingComments.Add(commentText);
		return .Ok;
	}

	/// @brief Capture a trailing comment on the same line as a key/val or header.
	/// Stores it in mTrailingCommentText for later attachment.
	private Result<void, TomlParseError> CaptureTrailingComment()
	{
		if (mStyle == null)
		{
			return SkipCommentText();
		}

		// Clear any previous trailing comment
		if (mTrailingCommentText != null)
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
		}

		mTrailingCommentText = new String();
		if (CaptureCommentText(mTrailingCommentText) case .Err(let e))
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
			return .Err(e);
		}
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
		if (mStyle == null || mTrailingCommentText == null)
			return;

		let commentSet = mStyle.GetOrCreateCommentSet(nodeId);
		if (commentSet != null)
		{
			if (commentSet.mTrailing != null)
				delete commentSet.mTrailing;
			commentSet.mTrailing = mTrailingCommentText;
			mTrailingCommentText = null; // Ownership transferred
		}
		else
		{
			delete mTrailingCommentText;
			mTrailingCommentText = null;
		}
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
		while (!mPendingComments.IsEmpty && mPendingComments.Back == null)
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
