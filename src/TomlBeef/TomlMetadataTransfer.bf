using System;
using internal TomlBeef;

namespace TomlBeef;

/// Carries PreserveStyle metadata across a merge.
///
/// Merged values are deep-copied into the destination store, which gives them fresh containers with no
/// metadata. These helpers attach destination node IDs throughout a copied subtree and, when the source
/// document has its own sidecar, copy each node's original token, formats, and comments across.
static class TomlMetadataTransfer
{
	/// Gives the copied value `dst` (a CloneInto of `src`) node IDs and styles in `dstMeta`.
	/// @param srcMeta The source sidecar, or null to attach IDs with default styling.
	internal static void AdoptValue(TomlValue dst, TomlValue src, TomlDocumentMetadata dstMeta, TomlDocumentMetadata srcMeta)
	{
		if (dst case .Table(let dstTable) && src case .Table(let srcTable))
			AdoptTable(dstTable, srcTable, dstMeta, srcMeta);
		else if (dst case .Array(let dstArray) && src case .Array(let srcArray))
			AdoptArray(dstArray, srcArray, dstMeta, srcMeta);
	}

	static void AdoptTable(TomlTable dst, TomlTable src, TomlDocumentMetadata dstMeta, TomlDocumentMetadata srcMeta)
	{
		if (dst.MetadataContext == null)
			dst.MetadataContext = new TomlContainerMetadataContext(dstMeta, dstMeta.AllocateNodeId(), false);
		let dstCtx = dst.MetadataContext;
		let srcCtx = srcMeta != null ? src.MetadataContext : null;
		// The container's own node carries header comments and similar table-level style
		if (srcCtx != null)
			CopyNodeStyle(srcMeta, srcCtx.mNodeId, dstMeta, dstCtx.mNodeId, true);

		for (int i = 0; i < dst.Count; i++)
		{
			StringView key = dst.GetKeyAt(i);
			TomlNodeId dstId;
			if (!dstCtx.TryGetEntryNodeId(key, out dstId))
			{
				dstId = dstMeta.AllocateNodeId();
				dstCtx.SetEntryNodeId(key, dstId);
			}
			if (srcCtx != null && srcCtx.TryGetEntryNodeId(key, let srcId))
				CopyNodeStyle(srcMeta, srcId, dstMeta, dstId, true);
			if (src.TryGetValue(key, let srcValue))
				AdoptValue(dst.GetValueAt(i), srcValue, dstMeta, srcMeta);
		}
	}

	static void AdoptArray(TomlArray dst, TomlArray src, TomlDocumentMetadata dstMeta, TomlDocumentMetadata srcMeta)
	{
		if (dst.MetadataContext == null)
			dst.MetadataContext = new TomlContainerMetadataContext(dstMeta, dstMeta.AllocateNodeId(), true);
		let dstCtx = dst.MetadataContext;
		let srcCtx = srcMeta != null ? src.MetadataContext : null;
		if (srcCtx != null)
			CopyNodeStyle(srcMeta, srcCtx.mNodeId, dstMeta, dstCtx.mNodeId, true);

		for (int i = 0; i < dst.Count; i++)
		{
			TomlNodeId dstId;
			if (!dstCtx.TryGetItemNodeId(i, out dstId))
			{
				dstId = dstMeta.AllocateNodeId();
				dstCtx.AddItemNodeId(dstId);
			}
			if (srcCtx != null && srcCtx.TryGetItemNodeId(i, let srcId))
				CopyNodeStyle(srcMeta, srcId, dstMeta, dstId, true);
			AdoptValue(dst.GetValueAt(i), src.GetValueAt(i), dstMeta, srcMeta);
		}
	}

	/// Copies one node's style from `srcMeta` into an existing node in `dstMeta`. The copied node is clean:
	/// it represents the source text exactly, so its original token is valid for its value.
	/// @param includeSlotStyle Also copy the key format and comments. False when overwriting a value in an
	/// existing slot, where the key and comments belong to the destination.
	internal static void CopyNodeStyle(TomlDocumentMetadata srcMeta, TomlNodeId srcId, TomlDocumentMetadata dstMeta, TomlNodeId dstId, bool includeSlotStyle)
	{
		let srcStyle = srcMeta.GetNodeStyle(srcId);
		let dstStyle = dstMeta.GetNodeStyle(dstId);
		if (srcStyle == null || dstStyle == null)
			return;

		dstStyle.mDirtyFlags = .None;
		dstStyle.mOriginalValueToken = srcStyle.mOriginalValueToken.IsValid
			? dstMeta.AddOriginalToken(srcMeta.GetOriginalToken(srcStyle.mOriginalValueToken))
			: .Invalid;
		dstStyle.mValueFormatRef = srcStyle.mValueFormatRef.IsValid
			? dstMeta.AddValueFormat(srcMeta.mValueFormats[srcStyle.mValueFormatRef.mIndex])
			: .Invalid;
		if (!includeSlotStyle)
			return;

		if (srcStyle.mKeyFormatRef.IsValid)
			dstStyle.mKeyFormatRef = dstMeta.AddKeyFormat(srcMeta.mKeyFormats[srcStyle.mKeyFormatRef.mIndex]);
		let srcComments = srcMeta.GetCommentSet(srcId);
		if (srcComments != null)
		{
			let dstComments = dstMeta.GetOrCreateCommentSet(dstId);
			for (let line in srcComments.mLeading)
				dstComments.mLeading.Add(new String(line));
			if (srcComments.mTrailing != null)
			{
				delete dstComments.mTrailing;
				dstComments.mTrailing = new String(srcComments.mTrailing);
			}
			dstComments.mSeparatedByBlankLine = srcComments.mSeparatedByBlankLine;
		}
	}
}
