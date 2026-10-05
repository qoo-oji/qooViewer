import Foundation

/// 「起動時に前回開いていた本を自動的に開く」設定のために、直前にアクティブだった
/// ウインドウ/タブが表示していた本のURLを記録しておく仕組み。
///
/// すべてのウインドウ・タブを復元するわけではなく、終了時にアクティブだった1つの本だけを
/// 対象にする。そのため、キーウインドウになった/本を切り替えた、といったタイミングの
/// たびに記録を更新しておき、「最後にアクティブだった状態」が常にここに反映されるようにする
/// (ContentView.swiftのobserveWindowBecameKey/onChange(of: appState.currentBook)参照)。
/// アプリの終了時に何か特別な処理をする必要はない(終了時点で最後に記録された内容が
/// そのまま使われる)。
///
/// サンドボックス環境では単なるファイルパスの文字列を保存しても、次回アプリを起動したときに
/// そのURLへアクセスする権限がない。そのため、RecentFilesStoreと同じく
/// 「セキュリティスコープ付きブックマーク」(bookmarkData)としてUserDefaultsに保存する。
///
/// 3つの関数が受け取る`defaults`は**テストのための口**で、既定はこれまでどおり`.standard`
/// (LastUsedFolderMemory.init(defaults:)と同じ作法)。テストは実物のアプリと同じコンテナで
/// 走るため、利用者の「前回開いていた本」を書き換えてはいけない。
enum LastActiveBookStore {
    private nonisolated static let defaultsKey = "qooViewer.lastActiveBookBookmark"

    /// アクティブなウインドウ/タブが表示している本が変わったとき、またはそのウインドウが
    /// キーウインドウになったときに呼ぶ。
    ///
    /// **ブックマークはメインの外で作る**(2026-09-27、表示の切り替えの監査の 11)。本を替えるたび・ウインドウを切り替えるたびに
    /// 呼ばれ、以前はここでメインのままセキュリティスコープ付きブックマークを作っていた(ボリュームへの問い合わせ。遅い・眠っている
    /// ボリュームの本では目に見えて止まる)。書き込みは作り終えた時点で、**まだ最後の記録・消去だったときだけ**行う
    /// (`recordGenerations`)―― 続けて別の本を記録した・ホームへ戻って消した後に、先の記録が遅れて届いて上書きしないように。
    /// 呼び出し側は待たない(戻り値はテストが終わりを待つためのもの)。
    ///
    /// **いま記録してある本と同じなら作り直さない**(2026-10-05 の効率の監査 C9)。ウインドウを切り替えるたびに呼ばれるので、以前は
    /// 同じ本でも毎回ブックマークを作り(ネットワーク上の本なら往復)、UserDefaults へ書いていた。「記録してある」は、この起動の中で
    /// 書き終えた記録だけ(`lastRecorded`)で、パスに加えてファイルそのもの(`FileNodeIdentifier`)も同じときだけ。パスだけで
    /// 見ると、開いている間に同じパスへ置き換えられた本(Finder の「置き換える」・ダウンロードし直し)で古い記録が残り、ブックマークが
    /// ゴミ箱へ入った前のファイルを指したまま、次の起動で開き直せなかった(2026-10-05 のコードレビュー)。確かめの stat もメインの外。
    @discardableResult
    static func record(url: URL, defaults: UserDefaults = .standard) -> Task<Void, Never> {
        let key = ObjectIdentifier(defaults)
        // 記録がまだ残っているかも見る(保存先の中身が外で消された ―― テストの保存先が作り直された ―― ときは書き直す)。
        let recorded = defaults.data(forKey: defaultsKey) != nil ? lastRecorded[key] : nil
        recordGenerations[key, default: 0] &+= 1
        let generation = recordGenerations[key]
        return Task { @MainActor in
            if let recorded, recorded.path == url.path {
                let node = await FileIO.perform { FileNodeIdentifier.current(for: url) }
                if node != nil, node == recorded.node { return }
            }
            let made = await FileIO.perform { () -> (data: Data?, node: FileNodeIdentifier?) in
                let data = try? url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
                return (data, FileNodeIdentifier.current(for: url))
            }
            guard let data = made.data, generation == recordGenerations[key] else { return }
            defaults.set(data, forKey: defaultsKey)
            lastRecorded[key] = (url.path, made.node)
        }
    }

    /// この起動の中で書き終えた記録の本のパスとファイル(`record` のコメント)。保存先ごと。
    private static var lastRecorded: [ObjectIdentifier: (path: String, node: FileNodeIdentifier?)] = [:]

    /// 記録・消去の世代(`record` のコメント)。後から呼ばれたものが勝つ。保存先ごとに数える(テストは保存先を分けて並行に走る。
    /// 別の保存先への記録で自分の記録が捨てられないように)。
    private static var recordGenerations: [ObjectIdentifier: Int] = [:]

    /// アクティブなウインドウ/タブが「何も本を開いていない状態(ウェルカム画面)」になった
    /// ときに呼ぶ。記録をクリアすることで、次回起動時に誤って本を復元してしまわないようにする
    /// (終了時にウェルカム画面を見ていたなら、次回もウェルカム画面から始まるのが正しい)。
    static func clear(defaults: UserDefaults = .standard) {
        // 作っている最中の記録があっても、届いたときに書かせない(`record` のコメント)。
        recordGenerations[ObjectIdentifier(defaults), default: 0] &+= 1
        lastRecorded[ObjectIdentifier(defaults)] = nil
        defaults.removeObject(forKey: defaultsKey)
    }

    /// 保存されているブックマークからURLを解決する。ブックマークが存在しない場合や、
    /// 指しているファイル/フォルダが実際にはもう存在しない(削除・移動された)場合はnilを返す。
    /// 内容が変わっていないかどうかまではここでは確認しない(呼び出し元のContentView.swift
    /// resolveLastActiveBookURLIfUnchanged参照。BookReadingStateの指紋と比較する必要があり、
    /// SwiftDataのModelContextを使うため、ここでは行わない)。
    ///
    /// ブックマークの解決と存在確認でファイルシステムに触れるので、メインの外(FileIO)から呼ぶ(2026-09-27、表示の切り替えの
    /// 監査の 11。以前は起動時にメインで呼んでいて、応答しないボリューム上の本だと起動が止まった)。
    nonisolated static func resolve(defaults: UserDefaults = .standard) -> URL? {
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return resolve(bookmarkData: data)
    }

    /// 記録そのもの(ブックマークのデータ)。起動時の確かめは、これをメインで先に読んでから解決だけをメインの外で行う ――
    /// 確かめている間にウインドウがキーになると、本を開いていない状態として記録が消される(`clear`)ため。
    static func recordedBookmarkData(defaults: UserDefaults = .standard) -> Data? {
        defaults.data(forKey: defaultsKey)
    }

    /// `resolve(defaults:)`の、記録を読んだ後の部分。
    nonisolated static func resolve(bookmarkData data: Data) -> URL? {
        // 起動時に自動で開き直すものなので、繋がっていない共有へは繋ぎに行かない(BookmarkResolution。NAS の電源が落ちていると
        // 起動のたびに 30 秒後にダイアログが出る)。
        guard let url = BookmarkResolution.resolve(data) else { return nil }
        // ゴミ箱へ移した本は開き直さない(BookLocationResolver.isInTrash。ブックマークはゴミ箱の中まで追う。2026-09-22 の監査)。
        guard !BookLocationResolver.isInTrash(url) else { return nil }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
