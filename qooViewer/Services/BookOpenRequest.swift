import Foundation

/// 「これから1冊として開く対象」を表す値。
///
/// ■ なぜURL1つではなく専用の型なのか
/// ユーザー要望により、Finderで複数選択した画像ファイル群を1冊の本として開けるようにした。
/// そのため「開く対象」がURL1つでは表せなくなり、本を開くすべての経路(Finder/Dockからの
/// application(_:open:)、ウェルカム画面へのドロップ、NSOpenPanel、新しいウインドウ/タブ)が
/// 複数URLを運べる必要がある。特に`WindowGroup(id:"book", for:)`の提示値は1つの型しか取れないため、
/// ここを`URL`のままにしておくと「複数画像を新しいウインドウで開く」が原理的に作れない。
///
/// ■ 値に含めてよいもの
/// **UUIDやタイムスタンプのような「毎回変わる値」を絶対に入れないこと。**
/// SwiftUIの`openWindow(id:value:)`は「同じid + 等値のvalueのウインドウが既にあればそれを前面に
/// 出す」という重複防止を持っており、これがLaunchCoordinator側の重複判定をすり抜けたとき
/// (閉じたはずのウインドウのAppStateが生き残る既知の挙動)の最後の砦になっている。
/// 毎回異なる値を含めるとこの砦が無くなり、同じ本のウインドウが際限なく開きうる。
/// `urls`を正規化(重複除去＋自然順ソート)しているのも、同じ選択が常に同じ値になるようにするため。
///
/// ■ Codable
/// `WindowGroup(for:)`の要件を満たすためだけのもので、実際に永続化されることはない
/// ("book"/"private"の両WindowGroupは`.restorationBehavior(.disabled)`済み)。
///
/// nonisolated: このプロジェクトの既定のアクター隔離はMainActorのため、明示しないと
/// メインアクター限定になり、`WindowGroup(for:)`の要求(Sendableな値型)と噛み合わなくなる
/// (Services/ArchiveReading.swift冒頭のコメント参照)。
nonisolated struct BookOpenRequest: Codable, Hashable, Sendable {
    /// 1件のみなら従来どおりの1冊(フォルダ / zip・rar・7z / PDF / EPUB / 画像1枚)。
    /// 2件以上なら、それらの画像をまとめた「その場限りの本」(MangaBook.BookOrigin参照)。
    /// **必ず1件以上**になるよう、生成経路の両方で保証している。
    let urls: [URL]

    /// 一度に1冊へまとめられる画像の上限。
    ///
    /// サンドボックスのセキュリティスコープ付きアクセスは有限のカーネルリソースで、Appleは
    /// 使い果たした場合について「アプリはファイルシステム上の場所を自身のサンドボックスへ追加する
    /// 能力そのものを失う」と明記している。そうなるとこの本だけでなく、フォルダのアクセス許可
    /// (FolderAccessStore)もお気に入りの登録も壊れる=アプリ全体が使えなくなる。
    /// 実際にはFinder/Dockから渡されるURLは拡張が消費済みで`startAccessingSecurityScopedResource()`が
    /// falseを返す(=何も消費しない)ことが多いが、それに寄りかからず上限で頭を押さえておく。
    ///
    /// **判定は必ず`exceedsImageSelectionLimit`を通すこと**(そちらのコメント参照)。
    static let maxImageSelectionCount = 1000

    /// この要求が上限を超えているかどうか。
    ///
    /// **セキュリティスコープを開く箇所は、開く前に必ずこれを見ること。**
    /// 開く箇所は2つあり、以前は`AppState.open(request:)`にしか判定が無かった:
    ///   ・`AppState.open(request:)` … 開いた本のぶんを、次に本を開くまで握り続ける
    ///   ・`QooViewerApp.openInNewWindow` … 新しいウインドウへ渡すあいだだけ握る
    ///     (SecurityScopedHandoff)
    /// 後者に判定が無かったため、「新しいウインドウ/タブで開く」やFinderからの複数選択では、
    /// この後どのみち上限で弾かれる要求のために**URLの数だけ拡張を消費**していた
    /// (10秒で解放されるので恒久リークではないが、上限を設けた理由そのものに穴が空いていた)。
    var exceedsImageSelectionLimit: Bool { urls.count > Self.maxImageSelectionCount }

    /// この本を「最近開いたファイル」に残すかどうか。既定はtrue(残す)。
    ///
    /// falseにするのはサイドパネルのフォルダブラウザ経由だけ。あちらは**フォルダを移動する
    /// たびにその場でそのフォルダの画像を表示する**ようになったため(SidePanelView.
    /// moveAndShowImages参照)、そのまま記録すると目的の本を探して通り抜けただけのフォルダで
    /// 履歴が埋まってしまう(ユーザーの指示)。
    ///
    /// **履歴に残さないだけで、その他の記録は通常どおり**行う ―― 読書位置・ブックマーク・
    /// お気に入り・レイアウトは本ごとの資産で、これらまで捨てると「同じフォルダへ戻ったら
    /// 続きから読める」が壊れる。何も残さないのはシークレットウインドウとその場限りの本
    /// (MangaBook.isTransient)の役目で、そちらとは別の話。
    var recordsInHistory = true

    /// 従来どおり、1つのURLをそのまま開く。
    init(_ url: URL, recordsInHistory: Bool = true) {
        self.urls = [url]
        self.recordsInHistory = recordsInHistory
    }

    /// Finder / Dock / ドラッグ&ドロップ / NSOpenPanel から渡された複数のURLを分類し、
    /// 実際に開く対象へ正規化する。**この4経路はすべてこのイニシャライザを通すこと**
    /// (経路ごとに分類を書くと必ず食い違う)。
    ///
    /// 分類ルール:
    /// - **すべて画像**で2件以上 → それらをまとめて1冊にする(その場限りの本)
    /// - それ以外(1件だけ、または画像以外が混ざる) → **先頭の1つだけ**を従来どおり開く。
    ///   複数の書庫を同時に選んだ場合にウインドウが大量に開くのを避けるための意図的な仕様で、
    ///   これは複数選択に対応する前からの挙動(`urls.first`)をそのまま踏襲したもの。
    ///
    /// 実在確認はここでは行わない。未接続の外付け/ネットワークボリューム上のファイルでは1件あたり
    /// 秒単位ブロックしうるため、メインアクターから同期で呼ばれるこの処理では触らず、
    /// もともとメインスレッド外で走るBookLoader側に任せる。
    ///
    /// - Returns: candidatesが空ならnil。
    init?(openingCandidates candidates: [URL]) {
        guard let first = candidates.first else { return nil }
        guard candidates.count > 1, candidates.allSatisfy({ isImageFile($0.lastPathComponent) }) else {
            self.urls = [first]
            return
        }
        // 同じファイルが2回渡されても1ページにする。PageRefの等値判定はidだけなので、
        // 重複したまま通すと同じページが並び、ページ送り・ジャンプ・レイアウトが混乱する。
        var seenPaths = Set<String>()
        let unique = candidates.filter { seenPaths.insert($0.path).inserted }
        guard unique.count > 1 else {
            self.urls = [first]
            return
        }
        self.urls = naturalOrderSortedByPath(unique)
    }

    /// 画像ファイルそのものを開く要求かどうか(1枚でも複数枚でも)。
    /// このとき出来上がる本は「その場限りの本」になり、DBにもディスクキャッシュにも履歴にも
    /// 何も残さない(MangaBook.BookOrigin.imageFiles参照)。読み込みを始める前にそれが分かるので、
    /// キャッシュへ書くかどうかの判断(AppState.openのcachesPageList)にも使える。
    var opensImageFiles: Bool {
        !urls.isEmpty && urls.allSatisfy { isImageFile($0.lastPathComponent) }
    }

    /// 複数枚の画像を1冊にまとめる要求かどうか。
    /// 正規化済みなので「2件以上 == 全部画像」であり、枚数だけで判定できる
    /// (openingCandidatesは、全部画像でなければ必ず1件に絞る)。
    var bundlesMultipleImages: Bool { urls.count > 1 }

    /// 履歴への記録・ウインドウの重複判定など、「1つのURLで代表させたい」場面で使う先頭のURL。
    /// urlsは生成経路の両方で1件以上を保証しているが、Codableのデコード経由で空になる可能性を
    /// 完全には否定できないためOptionalにしてある。
    var primaryURL: URL? { urls.first }
}

/// ファイルパスの自然順(数字を数値として比較する順)で並べる。
///
/// `BookLoader.loadFolder`が使っているのと同じ比較(comparePageOrder)で、キーもフルパス。
/// フォルダをまたいで選択された場合でも、フォルダごとにまとまった上で各フォルダ内が名前順になる。
///
/// macOSがドロップや`application(_:open:)`で渡すURLの順序は仕様上保証されていない(Finderの表示順に
/// 見えることが多いだけ)ため、渡された順ではなく常にここで決め直す。同じ選択が常に同じ並びに
/// なることは、BookOpenRequestを`WindowGroup`の提示値として使う上での前提でもある。
nonisolated func naturalOrderSortedByPath(_ urls: [URL]) -> [URL] {
    let usesFinderOrder = PageOrder.usesFinderOrder
    return urls.sorted {
        comparePageOrder($0.path, $1.path, usesFinderOrder: usesFinderOrder) == .orderedAscending
    }
}
