import Foundation

/// 「同じフォルダ内の次の本/前の本」を探すためのヘルパー。
/// 現在開いている本の親フォルダの直下だけを見る(サブフォルダは再帰しない)。
///
/// フォルダ内のファイル列挙はメインスレッドを塞がないよう、async版はTask.detachedで
/// バックグラウンドで行う(BookLoader.swiftと同じ理由。詳細はそちらのコメント参照)。
/// nonisolated: Xcode 26既定のMainActor自動分離の対象外にしている。
nonisolated enum SiblingFinder {
    /// url と同じ階層(直下)にある本(画像を直接含むフォルダ、またはzip/rar/7z/pdfファイル)を
    /// 自然順に並べて返す
    static func siblingBookURLs(of url: URL) -> [URL] {
        let parent = url.deletingLastPathComponent()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: parent,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let books = children.filter { child -> Bool in
            let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let hasImage = (try? FileManager.default.contentsOfDirectory(
                    at: child,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ))?.contains { isImageFile($0.lastPathComponent) } ?? false
                return hasImage
            } else {
                return isArchiveFile(child.lastPathComponent) || isPDFFile(child.lastPathComponent)
            }
        }
        return books.sorted {
            $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending
        }
    }

    /// siblingBookURLs(of:)をメインスレッド外で実行する版。
    /// 「同じフォルダのファイルを開く」メニューの一覧取得や、次/前の本への移動に使う。
    static func siblingBookURLsAsync(of url: URL) async -> [URL] {
        await Task.detached(priority: .utility) {
            siblingBookURLs(of: url)
        }.value
    }

    /// 「次の本へ」「前の本へ」は、今開いている本がアーカイブ/PDFファイルならファイル同士、
    /// フォルダならフォルダ同士の間だけを移動する(種類の異なる本を挟まない)。
    /// 「同じフォルダのファイルを開く」メニュー(siblingBookURLsAsyncを直接使う側)は
    /// 種類を問わず全件を一覧したいので、絞り込みはこちらだけで行っている。
    static func url(after current: URL) async -> URL? {
        let siblings = await sameTypeSiblingBookURLs(of: current)
        guard let index = siblings.firstIndex(of: current), index + 1 < siblings.count else { return nil }
        return siblings[index + 1]
    }

    static func url(before current: URL) async -> URL? {
        let siblings = await sameTypeSiblingBookURLs(of: current)
        guard let index = siblings.firstIndex(of: current), index > 0 else { return nil }
        return siblings[index - 1]
    }

    /// siblingBookURLsAsync(of:)の結果を、current自身と同じ種類(フォルダ/ファイル)のものだけに
    /// 絞り込んで返す。
    private static func sameTypeSiblingBookURLs(of current: URL) async -> [URL] {
        let all = await siblingBookURLsAsync(of: current)
        let currentIsDirectory = (try? current.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return all.filter { url in
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            return isDirectory == currentIsDirectory
        }
    }
}
