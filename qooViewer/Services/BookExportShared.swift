import Foundation

/// EPUB(目次)・PDF(アウトライン)・CBZ(ComicInfo.xmlのPage@Bookmark)の各書き出しが共通で
/// 受け取る、1件ぶんのブックマーク。
///
/// 以前はEpubExportBookmark / PDFExportBookmarkという、フィールドがまったく同じ2つの型が
/// 別々に定義されていた。CBZ書き出しを足すと3つ目の同じ型が増えるため、1つに統合した
/// (書き出し先ごとに違うのは「この情報をどの形で埋め込むか」だけで、呼び出し側が用意する
/// 材料自体は完全に同一のため)。
///
/// nonisolated: 各Exporter(nonisolated enum、メインアクター外)が受け取るため
/// (詳細はServices/ArchiveReading.swift冒頭のコメント参照)。
nonisolated struct ExportBookmark {
    /// 元のPageRef.sortKey(BookLoaderが読み込んだ、並べ替え前のページキー)。
    let pageKey: String
    let name: String
}

/// カバー画像の上書き指定(ユーザー要望: 出力時のカバー画像を選択・変更できるようにしたい)。
/// nilの場合は、書き出し後の実質的な先頭ページ(除外・並べ替え反映後の1ページ目)を
/// 既定のカバーとして使う。
///
/// EPUB書き出し専用のEpubCoverOverrideとして始まったが、CBZ書き出し(ComicInfo.xmlの
/// Page@Type="FrontCover")でも同じ指定をそのまま使えるため、共通の型に改名して共有している。
/// PDF書き出しはカバーの概念自体を持たないため使わない(PDFExportInputのコメント参照)。
nonisolated enum ExportCoverOverride {
    /// 本に含まれる既存ページをカバーにする(pageKeyは元のPageRef.sortKey)。除外設定により
    /// このページ自体は通常の読書順に含まれない場合でも、カバーとしては使えるようにする
    /// (ユーザー要望を汲んだ挙動)。
    case existingPage(pageKey: String)
    /// 本に含まれない専用ファイルをカバーにする。
    case externalFile(data: Data, fileExtension: String)
}

/// 書き出す文字列(ファイル名・書誌メタデータ)をUnicode正規化形式C(NFC)に揃える。
///
/// ■ なぜ必要か(ユーザー報告 2026-09-03)
/// このアプリはファイル名を素通しで書き出す。フォルダの本の場合、名前はファイルシステムから
/// 返ってきたものそのままで、APFSは正規化保存(書かれたバイト列をそのまま保つ)なので、
/// NFDで作られたファイルは`readdir`もNFDで返す ―― 実測では"ば"が「は+結合濁点」の
/// ままzipのエントリ名になり、EPUBのOPFのhrefにもNFDがパーセントエンコードされて入っていた。
/// Windowsで展開すると、いわゆる文字化け(CP932誤読)は起きない ―― ZIPFoundationは
/// エントリ名を常にUTF-8フラグ(汎用フラグbit11)付きで書くため ―― が、濁点・半濁点が
/// 分離して表示され、並び順や検索も崩れる。
///
/// 書庫の本ではこの問題は起きにくい(実測では`ditto`(Finderの「圧縮」)もInfo-ZIPの`zip`も
/// 書き込み時にNFCへ正規化していた)が、正規化の責任を相手のツールに委ねる理由が無いため、
/// 書き出しの出口で一律に揃える。
///
/// ■ ファイル名に使うときの注意
/// EPUBはzipのエントリ名とOPF/XHTMLのhrefが一致していなければ参照が切れる。**同じ
/// 正規化済みの文字列から両方を組み立てること**(EpubExporterはimageFileName/xhtmlFileNameを
/// 1箇所で決めており、hrefもそこから作っているため、入口で1回通せば両方に効く)。
nonisolated func nfcNormalizedForExport(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping
}
