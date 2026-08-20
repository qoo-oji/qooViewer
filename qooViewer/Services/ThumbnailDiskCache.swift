import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

/// ページサムネイル(ImageDecoder.progressBarThumbnailMaxPixelSize = 240px)を、アプリの
/// キャッシュディレクトリへ永続化しておくための保管庫。
///
/// なぜ必要か: PageLoaderのthumbnailCache(NSCache)は開いている本ごと・メモリ上だけのもので、
/// 本を閉じるかウインドウを閉じると失われる。「ブックマーク・レイアウトの編集」ウインドウは
/// 左ペインで本を選ぶたびにBookLoader.load()とPageLoaderの生成をやり直すため、同じ本を
/// 行き来するだけで毎回アーカイブを開き直してサムネイルをデコードし直していた。本体が
/// 未接続の外付け/ネットワークボリューム上にあると、これがそのまま描画待ちになる。
///
/// サムネイルはローカルの~/Library/Caches配下へ置くため、本体が低速なボリュームにあっても
/// 2回目以降はローカルディスクから読める。キャッシュディレクトリなので、容量が逼迫すれば
/// OSに削除されうるし、Time Machineのバックアップ対象にもならない(消えても再生成できる
/// 情報しか置かない)。
///
/// actorそのものは(このプロジェクトの既定のMainActor隔離とは無関係に)固有の隔離を持つため、
/// `nonisolated`の指定は不要かつ書けない。複数の本・複数のウインドウから同時に触っても安全。
actor ThumbnailDiskCache {
    static let shared = ThumbnailDiskCache()

    /// キャッシュ全体の上限。240pxのPNGは1枚あたりおおむね数十KBのため、200MBあれば
    /// 数千ページ分に相当する。超過分は最終アクセスが古いものから捨てる(trimIfNeeded)。
    private static let maxTotalBytes: Int = 200 * 1024 * 1024

    /// 保存先(~/Library/Caches/<bundle id>/PageThumbnails)。作成に失敗した場合はnilになり、
    /// このキャッシュは「常にミスする」だけの無害な存在になる。
    private let directory: URL?
    /// 起動後に一度だけ容量の刈り込みを行うためのフラグ。
    private var hasTrimmed = false

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let base else {
            directory = nil
            return
        }
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        let url = base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("PageThumbnails", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            directory = url
        } catch {
            directory = nil
        }
    }

    // MARK: - キー

    /// 1冊分の識別子。サムネイルの中身が変わりうる要素をすべて含める。
    ///
    /// - bookID: 本のパス
    /// - modificationDate / fileSize: 本体が差し替えられたら別物として扱うための指紋
    ///   (BookReadingStateのrecordedSourceModificationDate/recordedSourceFileSizeと同じ考え方)
    /// - contrastCorrectionEnabled: 補正の有無でデコード結果が変わる
    ///   (PageLoader.setContrastCorrectionEnabledがNSCacheを捨てるのと同じ理由)
    /// - maxPixelSize: サムネイルの寸法
    struct BookKey: Hashable, Sendable {
        let bookID: String
        let modificationDate: Date?
        let fileSize: Int64?
        let contrastCorrectionEnabled: Bool
        let maxPixelSize: CGFloat

        /// 本体の更新日時・サイズを実際に読み取ってキーを組み立てる。ファイル1つに対する
        /// 属性の問い合わせ1回だけなので、本を開く時点で1度呼ぶぶんには軽い。
        init(sourceURL: URL, bookID: String, contrastCorrectionEnabled: Bool, maxPixelSize: CGFloat) {
            let values = try? sourceURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            self.bookID = bookID
            self.modificationDate = values?.contentModificationDate
            self.fileSize = values?.fileSize.map(Int64.init)
            self.contrastCorrectionEnabled = contrastCorrectionEnabled
            self.maxPixelSize = maxPixelSize
        }

        var fingerprint: String {
            let date = modificationDate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-"
            let size = fileSize.map(String.init) ?? "-"
            return "\(bookID)|\(date)|\(size)|\(contrastCorrectionEnabled)|\(maxPixelSize)"
        }
    }

    /// 1ページ分のファイル名。PageRef.idは本の中でのパス相当で、そのままではファイル名に
    /// できない(区切り文字・長さ・大文字小文字の扱い)ため、本の指紋と合わせてハッシュ化する。
    private static func fileName(bookKey: BookKey, pageID: String) -> String {
        let digest = SHA256.hash(data: Data("\(bookKey.fingerprint)\u{0}\(pageID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".png"
    }

    private func fileURL(bookKey: BookKey, pageID: String) -> URL? {
        guard let directory else { return nil }
        let name = Self.fileName(bookKey: bookKey, pageID: pageID)
        // 1つのディレクトリにファイルが集中しないよう、先頭2文字でサブディレクトリを切る。
        let sub = directory.appendingPathComponent(String(name.prefix(2)), isDirectory: true)
        return sub.appendingPathComponent(name, isDirectory: false)
    }

    // MARK: - 読み書き

    /// キャッシュ済みのサムネイルを返す。無ければnil。
    func thumbnail(bookKey: BookKey, pageID: String) -> CGImage? {
        guard let url = fileURL(bookKey: bookKey, pageID: pageID),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        // 最終アクセス日時を更新しておく(trimIfNeededがこれを基準に捨てる)。書き込みに
        // 失敗しても実害は無いので結果は見ない。
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return image
    }

    /// デコード済みのサムネイルを保存する。失敗しても呼び出し側には影響しない
    /// (次回もキャッシュミスになるだけ)。
    func store(_ image: CGImage, bookKey: BookKey, pageID: String) {
        guard let url = fileURL(bookKey: bookKey, pageID: pageID) else { return }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return
        }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return }

        // 起動後の最初の書き込みのタイミングで一度だけ容量を点検する。毎回走らせるほどの
        // 頻度は不要で、点検自体がディレクトリ全走査になるため。
        if !hasTrimmed {
            hasTrimmed = true
            trimIfNeeded()
        }
    }

    // MARK: - 容量の管理

    /// 上限を超えていたら、最終アクセスが古いものから削除する。
    private func trimIfNeeded() {
        guard let directory else { return }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: keys
        ) else { return }

        var files: [(url: URL, size: Int, date: Date)] = []
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { continue }
            let size = values.fileSize ?? 0
            let date = values.contentModificationDate ?? .distantPast
            files.append((url, size, date))
            total += size
        }
        guard total > Self.maxTotalBytes else { return }

        // 上限の8割まで落とす(削除のたびにすぐ上限へ戻らないようにするため)。
        let target = Self.maxTotalBytes * 8 / 10
        for file in files.sorted(by: { $0.date < $1.date }) {
            guard total > target else { break }
            try? FileManager.default.removeItem(at: file.url)
            total -= file.size
        }
    }

    /// キャッシュを丸ごと捨てる(環境設定「リセット」タブから使えるようにするための入口)。
    func removeAll() {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        hasTrimmed = false
    }
}
