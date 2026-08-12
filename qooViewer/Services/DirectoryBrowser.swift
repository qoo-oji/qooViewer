import Foundation

/// サイドパネル上段(フォルダブラウザ)が、ファイルシステム上の任意のフォルダ/ボリューム
/// 一覧を取得するためのヘルパー。SiblingFinder.swiftと同じ形の`nonisolated enum`
/// (Swift 6.2既定のMainActor自動分離の対象外にする必要があるため。ArchiveReading.swift
/// 冒頭のコメント参照)。
///
/// SiblingFinderと違い、ここでの一覧は「本として開けるかどうか」ではなく「ナビゲーション先と
/// して意味があるかどうか」で絞り込む: サブフォルダはそれ自体が本として開けるかに関わらず
/// 常に含める(でないと本を含まない中間フォルダを経由して奥のフォルダへたどり着けなくなる)。
/// ファイルは開ける形式(アーカイブ/PDF/EPUB)のみに絞る。
nonisolated enum DirectoryBrowser {
    struct Entry: Identifiable, Hashable {
        let url: URL
        let isDirectory: Bool
        var id: String { url.path }

        /// 一覧に表示する名前。DirectoryBrowser.displayName(for:)参照。
        var displayName: String { DirectoryBrowser.displayName(for: url) }
    }

    /// FolderAccessStore.Entry.displayNameと同じ考え方(ボリュームのルートフォルダは
    /// lastPathComponentが"/"や空文字になってしまうため、可能ならFinderと同じ
    /// .localizedNameKeyを優先する)。Entry.displayNameだけでなく、現在地表示
    /// (SidePanelView、Entryを経由しない生のURL)からも使うためstatic funcとして公開する。
    static func displayName(for url: URL) -> String {
        if let localizedName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName,
           !localizedName.isEmpty {
            return localizedName
        }
        return url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
    }

    /// directory直下の項目一覧を返す。フォルダは常に含み、ファイルは開ける形式のみに絞る。
    /// 自然順ソート(SiblingFinderと同じ.compare(_:options:.numeric))。並び順自体は
    /// sortOrder(環境設定「一般」タブ)に従う(sortedEntries(_:order:)参照)。
    ///
    /// アクセス権が無い場合は、FileManagerが投げるエラーをそのままthrowする(SiblingFinderの
    /// ようにtry?でもみ消さない)。空フォルダと権限エラーを区別し、呼び出し側で「その場で
    /// アクセスを許可」の案内を出し分けられるようにするため。
    static func entries(in directory: URL, sortOrder: SidePanelSortOrder) throws -> [Entry] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        let entries: [Entry] = children.compactMap { child in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                return Entry(url: child, isDirectory: true)
            }
            let name = child.lastPathComponent
            guard isArchiveFile(name) || isPDFFile(name) || isEpubFile(name) else { return nil }
            return Entry(url: child, isDirectory: false)
        }
        return sortedEntries(entries, order: sortOrder)
    }

    /// フォルダ・ファイルの一覧を、環境設定「一般」タブの並び順設定に従って並べ替える。
    /// nonisolated enum(MainActor隔離のAppPreferencesを直接読めない)のため、呼び出し側が
    /// 現在の設定値を引数として渡す(AppPreferences.sidePanelSortOrderのコメント参照)。
    private static func sortedEntries(_ entries: [Entry], order: SidePanelSortOrder) -> [Entry] {
        switch order {
        case .mixedByName:
            return entries.sorted {
                $0.url.lastPathComponent.compare($1.url.lastPathComponent, options: .numeric) == .orderedAscending
            }
        case .foldersFirst:
            return entries.sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                return lhs.url.lastPathComponent.compare(rhs.url.lastPathComponent, options: .numeric)
                    == .orderedAscending
            }
        }
    }

    /// directory直下(サブフォルダは見ない)に画像ファイルが1つでもあるかどうか。
    /// サイドパネルの「開く・移動をダブルクリックにする」設定時、フォルダへのダブル
    /// クリックが「画像フォルダとして本を開く」「フォルダへ移動する」のどちらになるかを
    /// 判定するために使う(ユーザー要望: 直下に画像があれば本として開き、無ければ移動)。
    /// 見つかり次第すぐ打ち切るため、最初の1件を探すだけの軽い処理(全件列挙・ソートは
    /// 行わない)。読み取れない場合はfalse(その場合はSidePanelView側で「移動」扱いになる)。
    static func directlyContainsImageFile(_ directory: URL) -> Bool {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        return children.contains { isImageFile($0.lastPathComponent) }
    }

    /// 上記をメインスレッド外(Task.detached)で実行する版。SiblingFinder.siblingBookURLsAsyncと
    /// 同じ形。エラーはそのまま呼び出し側へ伝播する。
    static func entriesAsync(in directory: URL, sortOrder: SidePanelSortOrder) async throws -> [Entry] {
        try await Task.detached(priority: .utility) {
            try entries(in: directory, sortOrder: sortOrder)
        }.value
    }

    /// ウェルカム画面でパネルを開いたときの最上位階層として使う、マウント中のボリューム一覧。
    /// 列挙自体はアクセス権を必要としない(実際にその中へ移動して一覧しようとした時点で
    /// 初めてentries(in:)側の権限判定が効く)。
    static func mountedVolumeEntries() -> [Entry] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumes
            .map { Entry(url: $0, isDirectory: true) }
            .sorted { $0.displayName.compare($1.displayName, options: .numeric) == .orderedAscending }
    }

    static func mountedVolumeEntriesAsync() async -> [Entry] {
        await Task.detached(priority: .utility) {
            mountedVolumeEntries()
        }.value
    }

    /// goUp()で「ボリューム一覧へ戻る」べきタイミングの判定に使う。対象がボリュームのルート
    /// 自身(またはファイルシステムのルート"/")であるかどうか。
    static func isVolumeRoot(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL
        if standardized.path == "/" { return true }
        return mountedVolumeEntries().contains { $0.url.standardizedFileURL == standardized }
    }
}
