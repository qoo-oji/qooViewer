import Foundation
import os

/// 本の実体(フォルダ・書庫・PDF・EPUB)について、保存データの行を作る・照らし合わせるときに要る事実を、**メインの外で**
/// 1 度に求めたもの(2026-10-11 の規約監査)。`MangaBook.sourceFacts` に入れて運ぶ。
///
/// ■ なぜ要るか
/// レイアウト・ブックマーク・お気に入り・メタデータの行を作るとき、以前はその場(メイン)で元ファイルに問い合わせていた ――
/// ファイルノード識別子(`attributesOfItem` + ボリューム UUID)、差し替え検知の指紋(更新日時・大きさ)、セキュリティスコープ付き
/// ブックマークの作成。どれもボリュームへの問い合わせで、応答しない共有の上の本では 1 回ごとに最長約 30 秒メインが止まる。
/// しかも本を開くたびに指紋の stat が 1 回(`ViewerViewModel.init`)、EPUB/PDF を初めて開くときはレイアウトの取り込みで
/// さらに 3 回、最初の見開きを読む前にメインで走っていた。
///
/// いまは本を読み終えた直後(`AppState.open` の反映の前、レイアウトの編集ウインドウ・カバーを選ぶ画面・保存データの取り込みの
/// 読み込みの後)に `FileIO` の上で 1 度だけ求め、書き込み側はこの値だけを使う(`MangaBook.recordBookmarkData` ほか)。
///
/// **振る舞いの変わる所**: 識別子・指紋・ブックマークは**開いた時点の値**になる。以前は指紋(ビューアの初期化)だけが開いた直後の
/// 値で、レイアウト・ブックマーク・お気に入りの行は書く時点で問い合わせていた。開いている間に元ファイルが入れ替わっても、
/// 開いている間の記録は開いた時点の本のものとして揃う(次に開いたときに指紋で入れ替わりが分かる)。
nonisolated struct BookSourceFacts: Sendable {
    /// iノード + ボリューム(`FileNodeIdentifier.current`)。取れなければ nil。
    var fileNodeIdentifier: FileNodeIdentifier?
    /// 本がフォルダか。
    var isDirectory: Bool
    /// 元ファイル/フォルダの更新日時(差し替え検知の指紋。`ContentFingerprint`)。
    var modificationDate: Date?
    /// 元ファイルの大きさ(同上。フォルダでは取れない)。
    var fileSize: Int64?
    /// 行に添えるセキュリティスコープ付きブックマーク。記録しない本(シークレットウインドウ・記録の残らない本)では作らない。
    var bookmarkData: Data?

    /// 求める本体。**ブロッキングする**ので `FileIO` の上で呼ぶ。サンドボックスで許可の要る場所なら、呼び出し側がスコープを開いておく
    /// (`FileNodeIdentifier.current` と同じ役割分担)。
    ///
    /// - Parameter makesBookmark: ブックマークも作るか(記録する本だけ)。
    static func probe(_ url: URL, makesBookmark: Bool) -> BookSourceFacts {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey])
        return BookSourceFacts(
            fileNodeIdentifier: FileNodeIdentifier.current(for: url),
            isDirectory: values?.isDirectory ?? false,
            modificationDate: values?.contentModificationDate,
            fileSize: values?.fileSize.map(Int64.init),
            bookmarkData: makesBookmark ? makeBookmark(for: url) : nil
        )
    }

    /// `FileIO` の上で求める。
    static func gather(_ url: URL, makesBookmark: Bool) async -> BookSourceFacts {
        await FileIO.perform { probe(url, makesBookmark: makesBookmark) }
    }

    /// 事実を持たない本で、その場で問い合わせる代わりの道へ落ちた(Debug ビルドのアプリだけで知らせる。テストは事実の無い本を
    /// わざと組むので数えない)。アプリの中でここへ来るのは、本を組み直した所が `sourceFacts` を引き継ぎ忘れたとき
    /// (2026-10-11 のレビューで、ビューアの `prepareBook` が落としていた)。落とすのではなくログに出す ―― 書き込み自体は正しく済む。
    static func noteMissingFacts(_ book: MangaBook, _ caller: String) {
        #if DEBUG
        guard !RuntimeEnvironment.isRunningTests else { return }
        missingFactsLogger.fault("\(caller, privacy: .public): MangaBook has no sourceFacts; querying the file synchronously")
        #endif
    }

    #if DEBUG
    private static let missingFactsLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "qooViewer", category: "BookSourceFacts")
    #endif

    /// セキュリティスコープ付きブックマークを作る(ブロッキングする)。
    static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

/// 保存データの行に添える居場所の手がかり(ブックマークとファイルノード識別子)。**本を開かずに**行を作る所(カバーの指定・
/// メタデータの登録)が、`FileIO` の上で求めてから書き込み側へ渡す(`BookSourceFacts` と同じ理由)。
nonisolated struct BookRowAnchors: Sendable {
    var fileNodeIdentifier: FileNodeIdentifier?
    var bookmarkData: Data?

    /// 求める本体。**ブロッキングする**ので `FileIO` の上で呼ぶ。
    static func probe(_ url: URL) -> BookRowAnchors {
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        return BookRowAnchors(fileNodeIdentifier: FileNodeIdentifier.current(for: url),
                              bookmarkData: BookSourceFacts.makeBookmark(for: url))
    }

    /// `FileIO` の上で求める。`url` が nil なら nil。
    static func gather(_ url: URL?) async -> BookRowAnchors? {
        guard let url else { return nil }
        return await FileIO.perform(qos: .utility) { probe(url) }
    }
}

extension MangaBook {
    /// 保存データの行に添えるブックマーク。開いたときにメインの外で作ったもの(`sourceFacts`)を使う。事実を持たない本
    /// (テストが直接組んだ本)だけ、その場で作る。
    var recordBookmarkData: Data? {
        if let sourceFacts { return sourceFacts.bookmarkData }
        BookSourceFacts.noteMissingFacts(self, "recordBookmarkData")
        return BookSourceFacts.makeBookmark(for: sourceURL)
    }

    /// 保存データの行に添えるファイルノード識別子(同上)。
    var recordFileNodeIdentifier: FileNodeIdentifier? {
        if let sourceFacts { return sourceFacts.fileNodeIdentifier }
        BookSourceFacts.noteMissingFacts(self, "recordFileNodeIdentifier")
        return FileNodeIdentifier.current(for: sourceURL)
    }

    /// 行を作るときの手がかり(同上)。
    var recordAnchors: BookRowAnchors {
        BookRowAnchors(fileNodeIdentifier: recordFileNodeIdentifier, bookmarkData: recordBookmarkData)
    }
}
