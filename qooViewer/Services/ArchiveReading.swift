import Foundation

enum ArchiveReaderError: Error {
    case cannotOpen
    case entryNotFound
}

/// zip / 7z / rar など、圧縮ファイルの中身を読み出すための共通インターフェース。
/// 形式ごとの違いは各 Reader(ZipArchiveReader など)の内部に閉じ込め、
/// 呼び出し側はこのプロトコルだけを見ればよいようにする。
// nonisolated: Xcode 26 (Swift 6.2)からの新規プロジェクトは既定で「Default Actor Isolation = MainActor」
// になっており、注釈のない型・関数は暗黙的にMainActor専用になる。ここから下のプロトコル・関数は
// すべてPageLoader(actor、メインスレッド外)から呼ばれるため、明示的にnonisolatedを付けている。
protocol ArchiveReading {
    /// アーカイブ内の全ファイルパス一覧(ディレクトリ自体は含まない)
    nonisolated func listFilePaths() throws -> [String]
    /// 指定パスのファイルをDataとして取り出す
    nonisolated func data(at path: String) throws -> Data
    /// 指定パスのファイルの先頭maxByteCountバイトだけを取り出す(それより小さいエントリなら
    /// 全体)。画像のヘッダー(JPEGのSOFマーカー、PNGのIHDRチャンク等)だけを読めれば十分な
    /// 用途(PageLoader.pageSize/pageImageInfo)向け。
    ///
    /// 画像1枚を丸ごと伸長するコストは、ページ数ぶん積み上がると無視できない
    /// (ViewerViewModel.warmUpWideImageCacheForEntireBookは本を開いた直後に全ページの
    /// 縦横比を調べる)。実際に必要なのは先頭のごく一部だけなので、途中で打ち切れる形式では
    /// 打ち切る。
    ///
    /// 既定実装はdata(at:)による全体読みへのフォールバック。途中で伸長を打ち切れるかどうかは
    /// 形式・ライブラリ依存のため、対応できる実装(ZipArchiveReader)だけが上書きする。
    nonisolated func dataPrefix(at path: String, maxByteCount: Int) throws -> Data
    /// 指定エントリの作成日時・更新日時(コンテキストメニュー「情報を見る」、ユーザー要望向け)。
    /// アーカイブ形式によって保持している情報が異なる: zip/7zは更新日時のみ(作成日時という
    /// 概念自体を持たない)、rarは両方持つ。取得できない項目はnil。エントリが見つからない場合は
    /// 両方nil。
    nonisolated func entryDates(at path: String) -> (created: Date?, modified: Date?)
}

extension ArchiveReading {
    /// dataPrefix(at:maxByteCount:)の既定実装(プロトコルのコメント参照)。
    /// 7z/rarは使用しているライブラリが「エントリの先頭だけを伸長する」形の読み出しに
    /// 対応していないため、この既定実装のまま(=従来通りの全体読み)になる。
    nonisolated func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        try data(at: path)
    }
}

/// 対応する画像の拡張子。AVIFはmacOS Sonoma(14)以降でImageIOがシステム全体で
/// デコードに対応している(本アプリの対象macOS 15以降ではすべて対応)ため含めている。
nonisolated let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "tif", "tiff", "avif"]

/// 対応する圧縮アーカイブの拡張子
nonisolated let archiveExtensions: Set<String> = ["zip", "cbz", "rar", "cbr", "7z", "cb7"]

nonisolated func isImageFile(_ path: String) -> Bool {
    imageExtensions.contains((path as NSString).pathExtension.lowercased())
}

nonisolated func isArchiveFile(_ path: String) -> Bool {
    archiveExtensions.contains((path as NSString).pathExtension.lowercased())
}

/// PDFファイルかどうか。PDFは中身を展開するアーカイブではなく、1ファイルの中に複数ページを
/// 直接持つ形式のため、アーカイブ(archiveExtensions)とは別に扱う(BookLoader.loadPDF、
/// PageLoader.renderPDFPage参照)。
nonisolated func isPDFFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "pdf"
}

/// EPUBファイルかどうか。EPUB自体はzipコンテナ(=archiveExtensionsのzip/cbzと読み出し方法は
/// 共通)だが、「zip内の画像ファイルを名前順に並べる」だけのcbz/cbrとは異なり、
/// container.xml/package documentが定義する正しい読み順(spine)を解決する必要があるため、
/// archiveExtensionsには含めず、BookLoader.loadEpubという専用の読み込み経路にしている
/// (詳細はEpubStructureResolver.swift参照)。
nonisolated func isEpubFile(_ path: String) -> Bool {
    (path as NSString).pathExtension.lowercased() == "epub"
}

/// 拡張子を見て、適切な ArchiveReading の実装を返す。
/// EPUBはzipコンテナなのでZipArchiveReaderをそのまま流用できる(ページの読み順の解決は
/// BookLoader.loadEpub/EpubStructureResolver側の責務で、ここでは単なるzip展開として扱ってよい)。
nonisolated func makeArchiveReader(for url: URL) throws -> ArchiveReading {
    switch url.pathExtension.lowercased() {
    case "zip", "cbz", "epub":
        return try ZipArchiveReader(url: url)
    case "7z", "cb7":
        return try SevenZipArchiveReader(url: url)
    case "rar", "cbr":
        return try RarArchiveReader(url: url)
    default:
        throw ArchiveReaderError.cannotOpen
    }
}

/// アーカイブの拡張子から、そのアーカイブ内エントリ用の PageSource を作る。
/// EPUBもzipコンテナとして読み出すため、cbz等と同じ.zipケースを使う。
nonisolated func pageSource(for archiveURL: URL, entryPath: String) -> PageSource {
    switch archiveURL.pathExtension.lowercased() {
    case "zip", "cbz", "epub":
        return .zip(archiveURL: archiveURL, entryPath: entryPath)
    case "7z", "cb7":
        return .sevenZip(archiveURL: archiveURL, entryPath: entryPath)
    default:
        return .rar(archiveURL: archiveURL, entryPath: entryPath)
    }
}
