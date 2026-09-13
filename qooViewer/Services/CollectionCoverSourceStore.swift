import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// **コレクション表紙の元画像**の保管庫。
/// `~/Library/Application Support/<bundle id>/CollectionCoverSources/<uuid>.jpg`
///
/// ■ CollectionCoverStoreとの違い
/// あちら(`CollectionCovers/<itemID>.jpg`)は**表示のために焼いた派生物**で、コレクションの
/// アイテム1件につき1枚、いつでも作り直せる前提の絵。こちらは**作り直しの元になる絵**で、
/// 本1冊につき1枚、利用者が「この画像を表紙にする」と指定したときにだけ増える。
///
/// ■ なぜ元画像をアプリの中へ複製するのか(2026-09-11)
/// 以前は利用者が選んだ画像をセキュリティスコープ付きブックマークで参照するだけだった。
/// 表示用の派生物はアプリの中にあるので、**元ファイルが消えても棚は何も変わらない** ――
/// 一方でEPUB/CBZの書き出しは毎回元ファイルを読み直すため、そちらだけが黙って既定へ戻る。
/// 実測(2026-09-11)では、外部ファイルを指定していた131冊すべてで元ファイルが失われていた
/// (置き場所は全件`~/Downloads`で、しかも`表紙.webp`のような使い回しの名前だった)。
/// 「これから消す場所に置いた画像を指定する」という自然な操作が、そのまま壊れる操作に
/// なっていたことになる。複製してしまえば、元をどう扱われても表紙は壊れない。
///
/// ■ Cachesではない
/// CollectionCoverStoreと同じ理由(あちらの型コメント参照)。消えると作り直せない
/// ―― 利用者が元ファイルを捨てていれば、この複製がその絵の最後の1枚になる。
///
/// ■ 保存するときに正規化する
/// 受け取った画像はそのままではなく、**復号してから長辺`maxPixelSize`までのJPEGへ焼き直して**
/// 保存する(`store(imageAt:)`)。理由は3つ:
/// - 表紙は最大でも768px(CollectionCoverStore.maxPixelSize)でしか使わないので、原寸を抱える
///   意味が無い。利用者が数十MBのTIFFを指定してもディスクは膨らまない
/// - 形式がJPEGに揃うので、読む側(CoverImageResolver)がImage I/Oの対応形式を気にしなくてよい
/// - 復号を1回通すので、**画像として読めないファイル・細工されたファイルはここで落ちる**。
///   ディスクへ届くのは常にこのアプリ自身がエンコードしたバイト列になる
/// 唯一の例外が`storeCopy(of:)`(下記)で、こちらは既にこのアプリが焼いたJPEGを引き取る移行
/// 専用の入り口。
///
/// nonisolated: 復号とファイルI/Oをメインアクターの外(CollectionCoverExtractorの抽出タスク、
/// LayoutStoreからの書き込み)から呼ぶため。
nonisolated struct CollectionCoverSourceStore: Sendable {
    /// 保存する元画像の最大辺。表示に使うのは768px(CollectionCoverStore.maxPixelSize)なので、
    /// その2倍を上限にしておく ―― 将来表示側の上限を上げても、既にある表紙を作り直さずに
    /// 済ませられるだけの余裕を持たせつつ、原寸を抱え込まない。
    static let maxPixelSize: CGFloat = 1536
    static let jpegQuality: CGFloat = 0.85

    /// 実際のアプリの保存先。ここではフォルダを作らない(最初の書き込み時に作る)。
    /// CollectionCoverStore.defaultDirectory()と同じ作り。
    static func defaultDirectory() -> URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "qooViewer"
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent("CollectionCoverSources", isDirectory: true)
    }

    let directory: URL

    /// - Parameter directory: nilなら実際のアプリの保存先。**テストは必ず一時フォルダを渡すこと**
    ///   (既定のままだと利用者の表紙の元画像を触ってしまう。CollectionCoverStore.initと同じ)。
    ///   静的な差し替え口ではなくインスタンスにしてあるのは、テストが並列に走るため ――
    ///   グローバルな1個を書き換える形だと、同時に走るテスト同士で保存先を奪い合う。
    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    /// 保存済みファイル名から実際の場所を求める。
    ///
    /// **ファイル名は必ずここを通して組み立てる。** 保存名はこのアプリが振るUUIDなので普段は
    /// 問題にならないが、DBの値をそのままパスへ継ぎ足す形にはしない ―― 将来zipから表紙を
    /// 読み込む機能を足したときに、外から来た名前がここへ流れ込む余地を作らないため
    /// (パス区切り・`..`・空文字を弾き、保管庫の外を指せないようにする)。
    func url(forFileName fileName: String) -> URL? {
        guard Self.isValidFileName(fileName) else { return nil }
        let url = directory.appendingPathComponent(fileName, isDirectory: false)
        // 組み立てた結果が保管庫の直下から出ていないことを、最後にもう一度確かめる。
        guard url.deletingLastPathComponent().standardizedFileURL.path
            == directory.standardizedFileURL.path
        else { return nil }
        return url
    }

    private static func isValidFileName(_ fileName: String) -> Bool {
        guard !fileName.isEmpty, fileName.count <= 255 else { return false }
        guard fileName != ".", fileName != ".." else { return false }
        guard !fileName.contains("/"), !fileName.contains("\0") else { return false }
        // 制御文字を含む名前は受け付けない。
        return !fileName.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    // MARK: - 書き込み

    enum StoreError: Error {
        /// 画像として読めなかった(形式が違う・壊れている・大きすぎる)。
        case notAnImage
        case encodeFailed
    }

    /// 利用者が指定した画像を保管庫へ取り込み、保存名を返す。
    ///
    /// **メインアクターの外で走らせる。** 復号と再エンコードは画像の大きさに比例して時間が
    /// かかるので、数十MBのファイルを指定されるとメインが目に見えて止まる。
    ///
    /// **`@concurrent`が要る**: このプロジェクトはApproachable Concurrencyが有効で、
    /// `nonisolated async`は呼び出し側のアクター(ここではMainActor)を引き継いで走る
    /// (CollectionCoverStore.image(for:)に同じ落とし穴の記録がある)。
    ///
    /// 呼び出し側は、セキュリティスコープが要るURL(利用者が選んだファイル)については
    /// あらかじめ`startAccessingSecurityScopedResource()`を済ませておくこと。あの許可は
    /// プロセス全体に効くので、開いたままこの関数を待てばよい(LayoutStore.setShelfCoverImage)。
    @concurrent func store(imageAt fileURL: URL) async throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try store(imageData: data)
    }

    /// 上のデータ版。復号 → 長辺maxPixelSizeまで縮小 → JPEGで書き出す。
    ///
    /// `ImageDecoder.decode`を通すので、画素数の上限(デコード爆弾よけ)もそちらの判断に乗る。
    func store(imageData data: Data) throws -> String {
        guard let image = ImageDecoder.decode(data, maxPixelSize: Self.maxPixelSize) else {
            throw StoreError.notAnImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil
        ) else { throw StoreError.encodeFailed }
        CGImageDestinationAddImage(
            destination, image, [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else { throw StoreError.encodeFailed }
        return try write(output as Data, fileExtension: "jpg")
    }

    /// 外から持ち込まれた画像(zipから読み込んだコレクション表紙)を取り込む。
    ///
    /// **検査に通れば元のバイトのまま保存する**(ImageIntegrityCheckの型コメント参照)。
    /// 上限より大きいものと、終端を確かめられない形式だけを焼き直す。検査に落ちたものは
    /// 取り込まず、理由を返して呼び出し側が一覧に出す ―― 黙って焼き直して通すことはしない。
    ///
    /// `@concurrent`が要る理由は`store(imageAt:)`と同じ。
    @concurrent static func inspectAndStore(
        imported data: Data, into store: CollectionCoverSourceStore
    ) async -> Result<(fileName: String, wasReencoded: Bool), ImageIntegrityCheck.Reason> {
        switch ImageIntegrityCheck.inspect(data, maxPixelSize: maxPixelSize) {
        case .verbatim(let fileExtension):
            guard let fileName = try? store.write(data, fileExtension: fileExtension) else {
                return .failure(.unreadable)
            }
            return .success((fileName, false))
        case .reencode(let reason):
            guard let fileName = try? store.store(imageData: data) else { return .failure(reason) }
            return .success((fileName, true))
        case .rejected(let reason):
            return .failure(reason)
        }
    }

    /// **このアプリが焼いたJPEGをそのまま引き取る**移行専用の入り口
    /// (CollectionCoverExtractor.migrateShelfCoverSeparationIfNeeded)。
    ///
    /// 復号し直さないのは、移行元が`CollectionCovers/<itemID>.jpg` ―― 既に長辺768pxまで
    /// 縮めてこのアプリがエンコードしたJPEG ―― だから。ここで焼き直すとJPEGの世代がもう1つ
    /// 増えるだけで、得るものが何も無い。
    func storeCopy(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return try write(data, fileExtension: "jpg")
    }

    /// バイト列をそのまま保管庫へ書き、保存名を返す。**内部用** ―― 外から来たバイト列を
    /// この入り口へ直接流さないこと(必ず`inspectAndStore`を通す)。
    fileprivate func write(_ data: Data, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileName = UUID().uuidString + "." + fileExtension
        guard let url = url(forFileName: fileName) else { throw StoreError.encodeFailed }
        // 書き込み途中のファイルを表示側が読まないように(CollectionCoverStore.writeと同じ)。
        try data.write(to: url, options: .atomic)
        return fileName
    }

    // MARK: - 削除

    /// 1件消す。行(BookLayoutSettings)から参照を外す側が、**外す前に**名前を控えて呼ぶこと
    /// (CollectionCoverStore.remove(_:)と同じ約束)。
    func remove(fileName: String?) {
        guard let fileName, let url = url(forFileName: fileName) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// フォルダごと消す(「すべてのデータを削除」)。
    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// 「すべてのデータを削除」等、保管庫のインスタンスを持たない画面から呼ぶ入り口
    /// (CollectionCoverStore.removeDefaultDirectory()と同じ趣旨)。
    static func removeDefaultDirectory() {
        try? FileManager.default.removeItem(at: defaultDirectory())
    }

    /// どの行からも参照されていないファイルを掃除する。起動時に1回だけ呼ぶ
    /// (CollectionCoverStore.sweepOrphansと同じ理由 ―― 削除の経路を丁寧に書いても、
    /// アプリが落ちれば参照だけ消えることはある)。
    ///
    /// ■ すぐには消さず、`orphanRetention`のあいだ隔離しておく(2026-09-13)
    /// ここにあるのは**作り直せない絵**(利用者が選んだ画像の複製で、元ファイルはもう無いことが
    /// 多い)。以前は参照が無ければその場で消していたが、2026-09-11に**参照のほうが間違って
    /// 消えた**(古いqooViewerがストアを開き、表紙の列を削除した。StoreSchemaGuardの型コメント)
    /// ときに、この掃除が131枚の元画像をまとめて消した。DBの記録が正しいとは限らない以上、
    /// 「参照が無い」は「要らない」の証明にならない。
    ///
    /// 隔離先は保管庫の中の`.orphaned/`。消すのは隔離してから`orphanRetention`を過ぎたものだけ。
    /// **参照が戻っていれば隔離から戻す**(DBをバックアップから戻した・修復した、など)。
    ///
    /// - Parameter now: 隔離した時刻と経過の判定に使う(**テストのための口**)。
    func sweepOrphans(keeping fileNames: Set<String>, now: Date = Date()) {
        let fileManager = FileManager.default
        let quarantine = directory.appendingPathComponent(Self.quarantineFolderName, isDirectory: true)

        // 1. 参照が戻っているものを隔離から戻す(同名のファイルが保管庫に無いときだけ)。
        if let quarantined = try? fileManager.contentsOfDirectory(at: quarantine, includingPropertiesForKeys: nil) {
            for url in quarantined where fileNames.contains(url.lastPathComponent) {
                let restored = directory.appendingPathComponent(url.lastPathComponent, isDirectory: false)
                guard !fileManager.fileExists(atPath: restored.path) else { continue }
                try? fileManager.moveItem(at: url, to: restored)
            }
        }

        // 2. 参照の無いものを隔離する。隔離した時刻を更新時刻に刻む(期限はそこから数える)。
        if let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for url in urls where !fileNames.contains(url.lastPathComponent) {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true else { continue }
                try? fileManager.createDirectory(at: quarantine, withIntermediateDirectories: true)
                let destination = quarantine.appendingPathComponent(url.lastPathComponent, isDirectory: false)
                try? fileManager.removeItem(at: destination)
                guard (try? fileManager.moveItem(at: url, to: destination)) != nil else { continue }
                // **刻めなかったら隔離から戻す**(監査で指摘 2026-09-13)。刻めないまま置くと、
                // すぐ下の3.が元の更新時刻で期限を判定し、30日より古い画像をこの場で消してしまう
                // ―― 隔離の猶予がこの画像にだけ効かない。戻しておけば次の起動でやり直せる。
                do {
                    try fileManager.setAttributes([.modificationDate: now], ofItemAtPath: destination.path)
                } catch {
                    try? fileManager.moveItem(at: destination, to: url)
                }
            }
        }

        // 3. 期限を過ぎた隔離を消す。
        guard let quarantined = try? fileManager.contentsOfDirectory(
            at: quarantine, includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        for url in quarantined {
            let movedAt = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? now
            if now.timeIntervalSince(movedAt) > Self.orphanRetention {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// 参照を失った元画像を消すまでの猶予(30日)。
    static let orphanRetention: TimeInterval = 30 * 24 * 60 * 60
    /// 隔離先のフォルダ名(保管庫の中)。先頭の`.`はFinderで見えなくするため。
    static let quarantineFolderName = ".orphaned"

    /// 保管庫が使っているディスク容量(サイドパネルの「リソース」モードの内訳用)。
    func totalByteCount() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return urls.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
