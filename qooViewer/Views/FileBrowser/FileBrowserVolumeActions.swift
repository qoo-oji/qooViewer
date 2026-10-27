import Foundation

/// ボリュームの「取り出す」(2026-10-27、利用者の要望)。ツリーの取り出しの印(2026-10-25)と、右クリックの「“名前”を取り出す」
/// (ツリーの行・右ペインの「コンピュータ」のボリューム)が同じこれを呼ぶ。することは `VolumeUnmounting` の型コメントのとおり、
/// そのボリュームだけのアンマウント(ディスクは取り出さない。文言は Finder の右クリックに合わせて「取り出す」)。
///
/// - 相手はアンマウントできるボリューム 1 つ(`FileBrowserEntry.isUnmountable`。ボリュームの一覧と一緒に読んだ値)。
/// - 読み取り専用モードでも使える(ファイルを変えない)。
/// - ビューアで開いている本がそのボリュームにあるとき、qooViewer の作業が走っている・並んでいるときは断り、理由を出す。
///   使用中で失敗したら理由を出す。右ペインがそのボリュームの中を見ていたら、外したあとはコンピュータへ移る。
extension FileBrowserActions {
    /// 「取り出す」の相手(アンマウントできるボリューム 1 つ)。ほかは nil(右クリックに項目を出さない)。
    static func ejectTarget(_ entries: [FileBrowserEntry]) -> FileBrowserEntry? {
        guard entries.count == 1, let entry = entries.first, entry.isVolume, entry.isUnmountable else { return nil }
        return entry
    }

    /// 押せるか: 相手があり、そのボリュームをまだ外している最中でない。
    func canEject(_ entries: [FileBrowserEntry]) -> Bool {
        guard let state, let entry = Self.ejectTarget(entries) else { return false }
        return !state.unmountingVolumePaths.contains(entry.url.standardizedFileURL.path)
    }

    func ejectVolume(_ entry: FileBrowserEntry) {
        guard let state, canEject([entry]) else { return UserFeedback.beep() }
        let url = entry.url
        let path = url.standardizedFileURL.path
        let name = entry.displayName
        let locale = preferences?.effectiveLocale ?? AppLanguage.currentLocale
        // ビューアで開いている本がこのボリュームにある(ファイルブラウザの操作と同じ判定 ―― 本そのもの・祖先・中身)。
        if FileBrowserOperations.openBookConflict(among: [url], openBookPaths: state.operations.openBookPaths()) != nil {
            return showEjectProblem(
                title: String(format: String(localized: "“%@” can’t be unmounted while a book on it is open.", language: locale), name),
                message: String(localized: "Close the book, then try again.", language: locale)
            )
        }
        // qooViewer の作業(ファイルブラウザのコピー・移動・圧縮、書き出し、保存データの読み込み)が走っている・並んでいる間は断る。
        // どのボリュームを触っているかは数えていないので、どれか 1 つでも走っていれば断る(コピーの途中で外すと、写しが中途半端に
        // 残る ―― 2026-10-25 のレビュー)。
        if RunningWorkRegistry.forCurrentProcess?.hasRunningWork == true || state.operations.isBusy {
            return showEjectProblem(
                title: String(
                    format: String(localized: "“%@” can’t be unmounted while qooViewer is working on files.", language: locale), name
                ),
                message: String(localized: "Try again after the work finishes.", language: locale)
            )
        }
        state.setUnmounting(path, true)
        Task { [weak self, weak state] in
            let error = await VolumeUnmounting.unmount(url)
            state?.setUnmounting(path, false)
            if let error {
                self?.showEjectProblem(
                    title: String(format: String(localized: "“%@” couldn’t be unmounted.", language: locale), name),
                    message: error.localizedDescription
                )
                return
            }
            // 右ペインが外したボリュームの中にいたらコンピュータへ(ツリーの行・「コンピュータ」の一覧はボリュームの着脱の知らせで読み直す)。
            if let folder = state?.currentFolder, MountTable.path(folder.standardizedFileURL.path, isAtOrUnder: path) {
                state?.navigate(to: nil as URL?)
            }
        }
    }

    private func showEjectProblem(title: String, message: String) {
        guard let presenter = state?.operations.presenter else { return UserFeedback.beep() }
        presenter.showProblem(FileBrowserProblem(title: title, message: message))
    }
}
