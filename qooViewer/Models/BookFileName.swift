import Foundation

/// 本の bookID(パス)から、表示名と形式の拡張子を取り出す。
///
/// **拡張子として扱うのは書庫・PDF・EPUB の拡張子だけ**(2026-09-22 の監査)。フォルダの本の名前にはふつうに「.」が入る
/// (「作品名 vol.3」)ので、`pathExtension` / `deletingPathExtension` で決めると、名前が「作品名 vol」に切れ、形式のバッジに「3」と
/// 出て、書き出しの「フォルダ」の絞り込みから落ちた。メタデータの読み(`MetadataRulesStore.baseName`)と同じ決まり。
nonisolated enum BookFileName {
    /// 書庫・PDF・EPUB の本なら、その拡張子(小文字)。フォルダの本など、それ以外は空文字列。
    static func bookExtension(forBookID bookID: String) -> String {
        let fileName = (bookID as NSString).lastPathComponent
        guard isArchiveFile(fileName) || isPDFFile(fileName) || isEpubFile(fileName) else { return "" }
        return (fileName as NSString).pathExtension.lowercased()
    }

    /// 表示名(書庫・PDF・EPUB の拡張子だけを外したもの)。
    static func displayName(forBookID bookID: String) -> String {
        MetadataRulesStore.baseName(forBookID: bookID)
    }
}
