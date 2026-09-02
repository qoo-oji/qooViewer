import Foundation

enum ArchiveReaderError: Error {
    case cannotOpen
    case entryNotFound
    /// `extract(at:to:maxByteCount:)`で、書き出したバイト数が上限を超えた(索引の申告より
    /// 実際の展開結果が大きい、細工された・壊れた書庫)。
    case entryTooLarge
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

    /// 指定エントリを展開したときのバイト数。実際に展開する**前**に大きさを知るための問い合わせ。
    ///
    /// 入れ子になった書庫を開くとき、その中身をメモリに載せてよいのか、一時ファイルへ
    /// 書き出すべきなのか、そもそも展開してよい大きさなのか(伸長爆弾よけ)を、
    /// 展開してしまう前に決める必要がある(NestedArchiveResolver参照)。3形式とも
    /// エントリの索引に非圧縮サイズを持っているため、追加のI/Oは発生しない。
    ///
    /// 取得できない場合はnil。呼び出し側は「分からない」を安全側(=メモリに載せない)へ
    /// 倒すこと。
    nonisolated func entryUncompressedSize(at path: String) -> Int64?

    /// 指定エントリを、メモリへ丸ごと読み込まずに`url`へ直接書き出す。
    ///
    /// 入れ子になった書庫を一時ファイルへ取り出す経路(NestedArchiveResolver)専用。
    /// `data(at:)`で受け取ってから`write(to:)`すると、**その書庫の全バイトが一度メモリに
    /// 載る** ―― 数GBのrarでラップされた本では、そのまま数GBの一時的な確保になる。
    /// zip/rarはライブラリが逐次読み出しに対応しているため、チャンクごとに書き出せば
    /// ピークはバッファ1つぶんで済む。
    ///
    /// 既定実装は`data(at:)`+`write(to:)`へのフォールバック(7zで使っているLZMA SDKは
    /// 展開結果をバッファごと返す形しか持たないため、そちらはこのまま)。
    ///
    /// - Parameter maxByteCount: 書き出してよい上限。索引の申告サイズ(entryUncompressedSize)は
    ///   呼び出し側が事前に見ているが、細工された・壊れた書庫では申告と実際が食い違う。
    ///   **展開しながら数えて**、超えた時点で打ち切る(監査で指摘: 展開が終わってから
    ///   測るだけでは、上限を超えて一時ファイルを書き潰すまで止まらない)。超えたら
    ///   `ArchiveReaderError.entryTooLarge`を投げ、書きかけのファイルは残さない。
    nonisolated func extract(at path: String, to url: URL, maxByteCount: Int) throws

    /// このreaderが、エントリの取り出しのために**保持し続けている**展開バッファの上限見積り
    /// (バイト)。ページ画像や入れ子の書庫のキャッシュとは別に、ライブラリの内部に
    /// 居座っているメモリで、リソースモニタに出すためのもの。
    ///
    /// zip/rarは0(チャンクごとに読み捨てる)。7zはLZMA SDKが**ソリッドブロック全体**を
    /// 伸長してバッファに保持し続けるため、そのブロックの大きさになる
    /// (SevenZipArchiveReader参照)。
    nonisolated var residentDecompressionBufferUpperBoundBytes: Int { get }
}

extension ArchiveReading {
    /// dataPrefix(at:maxByteCount:)の既定実装(プロトコルのコメント参照)。
    /// 7z/rarは使用しているライブラリが「エントリの先頭だけを伸長する」形の読み出しに
    /// 対応していないため、この既定実装のまま(=従来通りの全体読み)になる。
    nonisolated func dataPrefix(at path: String, maxByteCount: Int) throws -> Data {
        try data(at: path)
    }

    /// entryUncompressedSize(at:)の既定実装。3形式とも上書きしているため実際には使われないが、
    /// 将来ArchiveReadingの実装が増えたときに「サイズを答えられない」を選べるようにしておく。
    nonisolated func entryUncompressedSize(at path: String) -> Int64? { nil }

    /// extract(at:to:maxByteCount:)の既定実装(プロトコル側のコメント参照)。逐次読み出しに
    /// 対応できない実装(SevenZipArchiveReader)はこのまま=従来通りの全体読み+書き出しになる。
    /// 全体を読んでしまう以上、上限の検査は読み終えた後にしかできないが、上限を超えたものを
    /// ディスクへ書き出さない点は逐次版と同じ。
    nonisolated func extract(at path: String, to url: URL, maxByteCount: Int) throws {
        let data = try data(at: path)
        guard data.count <= maxByteCount else { throw ArchiveReaderError.entryTooLarge }
        try data.write(to: url)
    }

    /// residentDecompressionBufferUpperBoundBytesの既定実装。バッファを抱えない形式は0。
    nonisolated var residentDecompressionBufferUpperBoundBytes: Int { 0 }
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

/// 書庫の形式。拡張子だけで決まり、「どのReader実装を使うか」「メモリ上のDataから直接
/// 開けるか」の判断をこの1箇所に集約する(makeArchiveReader / NestedArchiveResolver)。
/// 対応形式を増やすときに触るのはarchiveKind(forFileName:)とarchiveExtensionsだけで済む。
nonisolated enum ArchiveKind {
    case zip
    case sevenZip
    case rar

    /// メモリ上のDataからそのまま開けるか。
    ///
    /// zipだけがtrue ―― ZIPFoundationがData版のAPI(ZipArchiveReader.init(data:))を持つため。
    /// rar/7zで使っているライブラリは、いずれも公開APIがファイルパスしか受け付けない
    /// (unrarのRAROpenArchiveEx、LZMA SDKのInFile_Open)ため、いったん一時ファイルへ
    /// 書き出す必要がある。この違いが、入れ子の書庫でディスクを使うかどうかを分ける
    /// (NestedArchiveResolver.materialize参照)。
    var opensFromMemory: Bool { self == .zip }
}

/// ファイル名の拡張子から書庫の形式を返す。書庫ではない(対応していない)ならnil。
///
/// EPUBをzip扱いにしているのは、EPUB自体がzipコンテナで読み出し方法が同じだから
/// (ページの読み順の解決はBookLoader.loadEpub/EpubStructureResolver側の責務で、
/// ここでは単なるzip展開として扱ってよい)。
nonisolated func archiveKind(forFileName fileName: String) -> ArchiveKind? {
    switch (fileName as NSString).pathExtension.lowercased() {
    case "zip", "cbz", "epub":
        return .zip
    case "7z", "cb7":
        return .sevenZip
    case "rar", "cbr":
        return .rar
    default:
        return nil
    }
}

/// ディスク上の書庫ファイルを開いて、適切な ArchiveReading の実装を返す。
nonisolated func makeArchiveReader(for url: URL) throws -> ArchiveReading {
    guard let kind = archiveKind(forFileName: url.lastPathComponent) else {
        throw ArchiveReaderError.cannotOpen
    }
    return try makeArchiveReader(kind: kind, url: url)
}

/// 形式が既に分かっている場合の版(NestedArchiveResolverが一時ファイルを開くときに使う。
/// 一時ファイルの拡張子は元のエントリ名から付け直しているが、形式は取り出した時点で
/// 確定しているので、そちらを信じるほうが素直)。
nonisolated func makeArchiveReader(kind: ArchiveKind, url: URL) throws -> ArchiveReading {
    switch kind {
    case .zip:
        return try ZipArchiveReader(url: url)
    case .sevenZip:
        return try SevenZipArchiveReader(url: url)
    case .rar:
        return try RarArchiveReader(url: url)
    }
}
