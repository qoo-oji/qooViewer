import AppKit

/// **起動時に、「置き換える」の途中で見失った項目を元の場所へ戻し、利用者に知らせる**
/// (改善要望7 段階 4b、2026-09-14。qooLibrary の同名の型を写したもの)。
///
/// 戻すのは `ReplaceBackupJournal.recoverAll()`、ここは**いつ呼ぶかと、どう伝えるか**だけを持つ。
/// 通常時は記録のファイルが無く、何も起きない。
///
/// - Note: サンドボックスでは、退避のあるフォルダに今回の起動でも触れる必要がある。ファイルブラウザが書けるのは
///   `FolderAccessStore` の許可の下だけで、その許可は `AppStores` の生成時(この呼び出しより前)に開かれている。
///   許可を取り消していれば戻せず、`orphaned` として知らせて記録を残す(許可し直した次の起動で戻る)。
@MainActor
enum ReplaceBackupRecovery {
    /// `applicationDidFinishLaunching` から 1 回だけ。**テスト中は動かさない**(テストホストは本物のアプリなので、
    /// 起動のたびにモーダルのアラートを出しうる。記録もテスト用の置き場所を見る)。
    static func runAtLaunch(journal: ReplaceBackupJournal = .shared) {
        guard !RuntimeEnvironment.isRunningTests else { return }
        Task { @MainActor in
            // 退避先が応答しない共有のことがあるので FileIO の上で。
            let outcomes = await FileIO.perform { journal.recoverAll() }
            for notice in notices(for: outcomes) {
                let alert = NSAlert()
                alert.alertStyle = notice.isWarning ? .warning : .informational
                alert.messageText = notice.title
                alert.informativeText = notice.message
                alert.addButton(withTitle: String(localized: "OK", language: AppLanguage.currentLocale))
                alert.runModal()
            }
        }
    }

    /// 見せる内容。**戻せたものも黙って済ませない**(利用者は前回「ファイルが消えた」と思っているかもしれない)。
    /// 戻せなかったものは利用者が動かないと直らないので警告にする。
    struct Notice: Equatable {
        let title: String
        let message: String
        let isWarning: Bool
    }

    static func notices(for outcomes: [ReplaceBackupJournal.Outcome]) -> [Notice] {
        let locale = AppLanguage.currentLocale
        var restored: [URL] = []
        var orphaned: [(backup: URL, target: URL, reason: String)] = []
        for outcome in outcomes {
            switch outcome {
            case .alreadyClean: break
            case let .restored(target): restored.append(target)
            case let .orphaned(backup, target, reason): orphaned.append((backup, target, reason))
            }
        }
        var notices: [Notice] = []
        if !restored.isEmpty {
            notices.append(Notice(
                title: String(localized: "Items that were being replaced were put back.", language: locale),
                message: String(
                    localized: "qooViewer quit while replacing these items, so the original items were put back where they were:",
                    language: locale
                ) + "\n" + listing(restored.map(\.path), locale: locale),
                isWarning: false
            ))
        }
        if !orphaned.isEmpty {
            notices.append(Notice(
                title: String(localized: "Some items that were being replaced couldn’t be put back.", language: locale),
                message: String(
                    localized: "qooViewer quit while replacing these items. The original items are kept as hidden items in the same folder. qooViewer will try to put them back the next time it opens (if an item with the same name is in the way, move it somewhere else first):",
                    language: locale
                ) + "\n" + listing(orphaned.map { "\($0.backup.path): \($0.reason)" }, locale: locale),
                isWarning: true
            ))
        }
        return notices
    }

    private static func listing(_ lines: [String], locale: Locale) -> String {
        var shown = lines.prefix(FileBrowserProblem.listedFailureLimit).map { $0 }
        if lines.count > FileBrowserProblem.listedFailureLimit {
            shown.append(String(
                format: String(localized: "…and %lld more.", language: locale),
                lines.count - FileBrowserProblem.listedFailureLimit
            ))
        }
        return shown.joined(separator: "\n")
    }
}
