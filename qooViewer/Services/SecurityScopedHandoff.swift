import Foundation

/// セキュリティスコープ付きURLを、**別のウインドウ/タブへ渡してからそちらが自分で
/// アクセスを開くまでの間だけ**開いたままにするための小さな仕組み。
///
/// ■ なぜ必要か
/// 履歴・お気に入り・ブックマーク一覧から本を開く経路では、保存しておいたセキュリティスコープ
/// 付きブックマークを解決してURLを得る。このURLを実際に開くのは`AppState.open(url:)`で、
/// そちらは自前で`startAccessingSecurityScopedResource()`し、次の本を開くときまで保持する
/// (`AppState.securityScopedBookURL`参照)。
///
/// ところが`openWindow(id:value:)`で新しいウインドウ/タブに渡す場合、そのウインドウの
/// `AppState.open(url:)`が走るのは**次以降のランループ**になる。その間アクセスを開いておくため、
/// 呼び出し側が渡す直前に1回開いておく必要がある。
///
/// ■ 何を直したのか
/// 以前は各所で`_ = url.startAccessingSecurityScopedResource()`と開きっぱなしにしていた。
/// Appleのドキュメントは、対になる`stopAccessingSecurityScopedResource()`を呼ばないことに
/// ついて「カーネルリソースを漏らす。使い果たすと、アプリはファイルシステム上の場所を自身の
/// サンドボックスへ追加する能力そのものを失う」と明記している。履歴やお気に入りから本を開く
/// たびに1つずつ確実に積み上がっていた(`AppState.securityScopedBookURL`が同じ理由で既に
/// 直されており、こちらはその取りこぼし)。
///
/// ■ なぜ「渡し終わった合図」ではなく時間で閉じるのか
/// 受け取り側が実際にアクセスを開いた瞬間を知る手立てがない(SwiftUIがウインドウを作り、
/// その中のContentView/AppStateが動き出すまでに何段階か挟まる)。一方でこの橋渡しは、
/// 受け取り側が自分のぶんを開くまでのごく短い間つながっていれば足りる。
/// `startAccessingSecurityScopedResource()`は参照カウント式なので、受け取り側が開いた後に
/// こちらが閉じてもアクセスは途切れない。十分に長い一定時間で閉じることで、受け取り側が
/// 現れなかった場合(ウインドウの生成に失敗した等)も含めて必ず収支が合う。
///
/// 待ち時間は、ウインドウの出現を待つ各所のポーリング(25ms × 20回 = 0.5秒)よりずっと長く
/// 取ってある。
///
/// ■ 猶予を引数にし、Taskを返してある理由
/// この仕組みの要は「開けたものは必ず閉じる」という収支で、それを確かめるテストが**時間で
/// 待ってはいけない**(協調スレッドが埋まると、テスト側のsleepが再開する前に対象が走り切る
/// ―― docs/13の段階2参照)。そのため猶予を呼び出し側から差し替えられるようにし、解放を行う
/// Taskをそのまま返す。テストは猶予0で呼んでawaitすれば、時間に頼らずに解放後の状態を見られる。
/// アプリ側の6か所は引数を渡さず戻り値も使わないので、これまでとまったく同じ挙動になる。
@MainActor
enum SecurityScopedHandoff {
    /// 受け取り側が自分のアクセスを開くまでの猶予。
    ///
    /// `nonisolated`にしてあるのは、下の既定引数の式がメインアクターの外として検査されるため
    /// (`@MainActor`な型のstaticをそのまま既定値に置くと、警告=エラーのCIでだけ落ちる。
    ///  docs/13の段階3・4で2度踏んだ落とし穴)。
    nonisolated static let releaseDelay: Duration = .seconds(10)

    /// `url`のセキュリティスコープを開き、猶予のあとに必ず閉じる。
    /// 開けなかった場合(スコープ付きでない素のfile URLなど)は何もしない。
    @discardableResult
    static func begin(_ url: URL, releaseAfter delay: Duration = releaseDelay) -> Task<[URL], Never>? {
        begin([url], releaseAfter: delay)
    }

    /// 複数のURLをまとめて開く(Finderで複数選択された画像を1冊として新しいウインドウ/タブへ
    /// 渡す場合)。開けたものだけをまとめて、**猶予後に1本のTaskで**閉じる。
    ///
    /// **1件ずつbegin(_:)をループで呼ばないこと。** URL 1つにつきTaskを1本作ることになり、
    /// 数百枚の選択では数百本のTaskが猶予時間(10秒)のあいだ生き残ってしまう。
    ///
    /// - Returns: 解放を行うTask(その値は実際に閉じたURL)。開けたURLが1つも無ければnil。
    ///   戻り値は収支を確かめるテストのためのもので、アプリ側は使わない。
    @discardableResult
    static func begin(_ urls: [URL], releaseAfter delay: Duration = releaseDelay) -> Task<[URL], Never>? {
        let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
        guard !accessedURLs.isEmpty else { return nil }
        return Task { @MainActor in
            try? await Task.sleep(for: delay)
            accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
            return accessedURLs
        }
    }
}
