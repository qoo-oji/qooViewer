import Foundation

/// 右クリックの「シークレットフォルダに追加」/「シークレットフォルダから外す」(2026-10-03。SecretFolderStore)。
///
/// - 相手はフォルダ 1 つ(リンクは先の項目。ボリュームのルートも可)。
/// - 一覧にそのまま載っていれば「外す」、載っていなければ「追加」(題が替わるだけで、項目の数は変わらない)。
/// - もう別のシークレットフォルダの中にあるフォルダは、足しても何も変わらないので淡色。
/// - **元からシークレットウインドウなら淡色**(パスを保存する設定なので、よく使う項目と同じ扱い。決定事項 Q8)。
///   シークレットフォルダの本を表示しているノーマルの窓では普段どおり(窓の性質は元のモードのまま。docs/plans/secret-folder-plan.md
///   の決定 15)。環境設定のペインはどの窓にも属さないので、そちらからはいつでも変えられる。
extension FileBrowserActions {
    /// 右クリックした 1 つのフォルダ(リンクなら先)。
    private func secretFolderTarget(_ entries: [FileBrowserEntry]) -> FileBrowserEntry? {
        guard entries.count == 1, let entry = entries.first.map(effective), entry.isNavigableFolder else { return nil }
        return entry
    }

    /// そのフォルダが一覧にそのまま載っているか(題を「外す」にする)。
    func isListedSecretFolder(_ entries: [FileBrowserEntry]) -> Bool {
        guard let target = secretFolderTarget(entries), let secretFolderStore else { return false }
        return secretFolderStore.isListed(target.url)
    }

    func canToggleSecretFolder(_ entries: [FileBrowserEntry]) -> Bool {
        guard allowsSaving, let secretFolderStore, let target = secretFolderTarget(entries) else { return false }
        if secretFolderStore.isListed(target.url) { return true }
        return !secretFolderStore.contains(path: target.url.path)
    }

    func toggleSecretFolder(_ entries: [FileBrowserEntry]) {
        guard canToggleSecretFolder(entries), let secretFolderStore, let target = secretFolderTarget(entries) else { return }
        if secretFolderStore.isListed(target.url) {
            secretFolderStore.remove(target.url.standardizedFileURL.path)
        } else {
            secretFolderStore.add(target.url)
        }
    }
}
