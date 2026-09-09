import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// コレクションのカバー画像(本を登録した時点で1回だけ抽出したJPEG)の保管庫。
/// `~/Library/Application Support/<bundle id>/CollectionCovers/<itemID>.jpg`
///
/// ■ なぜCachesではなくApplication Supportなのか
/// ページサムネイル(ThumbnailDiskCache)は「消えても元ファイルから作り直せる」ためCaches配下に
/// 置いてあり、実際OSは容量が逼迫すると消してよい。カバーはそうではない ―― 消えると
/// ウェルカム画面のタイルが全部空になり、登録してある本の**全冊ぶん**を読み直すことになる
/// (未接続の外付けボリューム上の本なら作り直せもしない)。1冊あたり768px/JPEG品質0.8で
/// 百数十KB程度と小さく、上限を設けて刈り込む必要も無いため、消えては困るデータとして
/// Application Supportに置く。
///
/// ■ なぜSwiftDataの外部ストレージ(@Attribute(.externalStorage))ではないのか
/// 画像をモデルの属性として持つと、行を読むだけでBLOBが付いてくる(検討メモ §2.2)。
/// カバーは一覧のスクロールに合わせて出し入れしたいもので、行の読み込みと寿命を分けたい。
///
/// actorそのものは(このプロジェクトの既定のMainActor隔離とは無関係に)固有の隔離を持つため、
/// `nonisolated`の指定は不要かつ書けない。
actor CollectionCoverStore {
    /// 保存するカバーの最大辺。
    ///
    /// 決め手はタイルではなく**コレクションの中**の一覧で、こちらはセルの幅が最大300pt
    /// (WelcomeLibraryState.coverSizeRange)、Retinaの2倍で600px要る。さらにカバーは切らずに
    /// 保存する(CoverImageResolver.cropped(_:to:anchor:))ので、横長の画像から正方形(1:1)を
    /// 切り出すと**長辺の一部しか残らない** ―― 512pxだと目に見えて甘くなるため768pxにしてある。
    static let maxPixelSize: CGFloat = 768
    static let jpegQuality: CGFloat = 0.8

    /// 保存先。`nonisolated let`にしてあるのは、読み書きの本体(復号・JPEGエンコード・ファイル
    /// I/O)をこのactorの**外**で実行するため(ThumbnailDiskCache.directoryと同じ理由)。
    nonisolated let directory: URL

    /// - Parameter directory: nilなら実際のアプリの保存先。**テストは必ず一時フォルダを渡すこと**
    ///   (既定のままだと利用者のカバー画像を消してしまう)。
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// 実際のアプリの保存先。ここではディレクトリを作らない(最初の書き込み時に作る) ――
    /// 起動しただけで空フォルダを作らないため。
    ///
    /// Application Supportが取れないという事態は通常起こらないが、その場合でも「常に失敗する
    /// 無害な保管庫」にはせず、一時フォルダへ逃がす(その起動の間だけカバーが残る)。
    nonisolated static func defaultDirectory() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CollectionCovers", isDirectory: true)
    }

    /// 実際のアプリの保存先をフォルダごと消す。**保管庫のインスタンスを持たない画面**
    /// (環境設定「リセット」の「すべてのデータを削除」、および起動時の予約済み削除)から
    /// 呼ぶための入り口。通常の削除経路は`removeAll()`。
    nonisolated static func removeDefaultDirectory() {
        try? FileManager.default.removeItem(at: defaultDirectory())
    }

    /// このitemのカバーの置き場所を求めるだけの純粋な計算(ディスクには触れない)。
    nonisolated func url(for itemID: UUID) -> URL {
        directory.appendingPathComponent(itemID.uuidString + ".jpg", isDirectory: false)
    }

    // MARK: - 読み書き

    /// 抽出済みのカバーを読む。無ければnil。
    ///
    /// `nonisolated`: ファイルの読み出しと復号をactorの上で行わない(directoryのコメント参照)。
    /// グリッドのセルごとに呼ばれるため、1枚の復号で他のセルの読み出しを待たせたくない。
    ///
    /// **`@concurrent`が要る**(監査で指摘 2026-09-09)。このプロジェクトはApproachable
    /// Concurrency(`NonisolatedNonsendingByDefault`)が有効で、`nonisolated async`関数は
    /// **呼び出し側のアクタを引き継いで**走る。付けないと、セルの`.task`(MainActor)から呼ばれた
    /// この復号がそのままメインスレッドで走り、一覧を流すたびにセルの数だけメインが止まる。
    /// `@concurrent`を付けて初めてグローバルエグゼキュータへ移る。
    ///
    /// - Parameter maxPixelSize: 指定するとその最大辺まで縮めて復号する(ImageIOのサムネイル
    ///   生成に任せる)。保存してあるのは常に768px(maxPixelSize)だが、コレクションのタイルの
    ///   中の1セルは実寸で50〜100pt程度しかない。等倍で復号すると1枚あたり1.5MB前後のビットマップ
    ///   になり、6枚×タイル数ぶんが画面に載る ―― LazyVGridは画面外のセルの保持物を手放さない
    ///   (LazyCellImageBudget参照)ため、表示に必要な大きさで復号することが効いてくる。
    @concurrent nonisolated func image(for itemID: UUID, maxPixelSize: CGFloat? = nil) async -> CGImage? {
        let fileURL = url(for: itemID)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        guard let maxPixelSize else {
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize.rounded()),
        ] as CFDictionary)
    }

    /// カバーを保存する。呼び出し側(CollectionCoverExtractor)は失敗を
    /// `CollectionCoverStatus.failed`として記録する。
    ///
    /// actor隔離のまま(nonisolatedにしない)なのは、書き込みを1件ずつ直列にするため。
    /// 抽出そのものが同時1件で走る作りなので、ここが詰まることは無い。
    func write(_ image: CGImage, for itemID: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // 一度メモリ上でJPEGにしてから、Data.write(options: .atomic)で書き出す。
        // 直接ファイルへ書くと、書き込み途中のファイルを表示側(image(for:))が読みうる
        // (ThumbnailDiskCache.storeと同じ理由)。
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(
            destination, image,
            [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (output as Data).write(to: url(for: itemID), options: .atomic)
    }

    // MARK: - 削除

    /// 指定したitemのカバーを消す。行(CollectionItem)を消す側が、**消える前に**idを集めて
    /// 呼ぶこと(SwiftDataのcascadeはディスク上のファイルまでは面倒を見ない)。
    func remove(_ itemIDs: [UUID]) {
        for itemID in itemIDs {
            try? FileManager.default.removeItem(at: url(for: itemID))
        }
    }

    /// フォルダごと消す(「すべてのデータを削除」/ JSONの上書き取り込み)。
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 行が残っていないカバーファイルを掃除する。起動時に1回だけ呼ぶ(CollectionStoreの
    /// 読み込みが終わってから)。
    ///
    /// 削除の経路をいくら丁寧に書いても、アプリが落ちた・ストアを作り直した、といった理由で
    /// 行だけが消えることはありうる。放っておくと二度と参照されないJPEGが残り続けるため、
    /// 起動のたびに突き合わせておく。
    func sweepOrphans(keeping itemIDs: Set<UUID>) {
        guard let names = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return }
        for fileURL in names where fileURL.pathExtension.lowercased() == "jpg" {
            let base = fileURL.deletingPathExtension().lastPathComponent
            // UUIDとして読めないファイルは、このアプリが書いたものではないので触らない。
            guard let id = UUID(uuidString: base) else { continue }
            if !itemIDs.contains(id) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
