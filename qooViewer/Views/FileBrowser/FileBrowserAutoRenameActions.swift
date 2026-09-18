import SwiftUI

/// ファイルブラウザの右クリックの「自動リネーム」(2026-09-15、ユーザー要望。docs/plans/auto-rename-study.md §3.2)。
///
/// サブメニューに規則を並べ、チェックは「このフォルダがその規則の対象に入っているか」。入れる・外すがその場で保存される。
/// 入れたときは設定ウインドウを開いてその規則を選ぶ ―― 今ある項目に掛ける前の確認(§8 の 2)がそこに出るため。
///
/// 淡色にするのは: フォルダ 1 つでない、よく使う項目の配下でない、ネットワーク上、シークレットウインドウ(規則は保存を伴う ―― 決定事項 Q8)。
/// 読み取り専用モードとは関係しない(設定はファイルを変えない。止まっていることは設定ウインドウに出る)。
extension FileBrowserActions {
    /// 「自動リネーム」を押せるか。
    func canConfigureAutoRename(_ entries: [FileBrowserEntry]) -> Bool {
        guard allowsSaving, autoRenameStore != nil, let service = autoRenameService,
              entries.count == 1, let entry = entries.first, entry.isNavigableFolder, !entry.isVolume
        else { return false }
        return service.eligibility(ofFolder: entry.url) == .available
    }

    func autoRenameMenuNodes(for entries: [FileBrowserEntry], locale: Locale) -> [FileBrowserMenuNode] {
        guard let store = autoRenameStore, let entry = entries.first else { return [] }
        let isEnabled = canConfigureAutoRename(entries)
        let folder = entry.url
        let path = AutoRename.canonicalPath(of: folder)
        var nodes: [FileBrowserMenuNode] = store.rules.map { rule in
            .toggle(
                title: rule.displayName(locale: locale), isOn: store.ruleContains(path: path, ruleID: rule.id),
                isEnabled: isEnabled && (store.ruleContains(path: path, ruleID: rule.id) || rule.targets.count < AutoRename.maxTargetsPerRule),
                action: { [weak self] in self?.toggleAutoRename(folder: folder, ruleID: rule.id) }
            )
        }
        if !nodes.isEmpty { nodes.append(.separator) }
        nodes.append(.item(
            title: String(localized: "New Rule for This Folder…", language: locale), image: nil,
            isEnabled: isEnabled && store.canAddRule,
            action: { [weak self] in self?.createAutoRenameRule(for: folder) }
        ))
        nodes.append(.item(
            title: String(localized: "Auto Rename Settings…", language: locale), image: nil, isEnabled: true,
            action: { [weak self] in self?.openAutoRenameSettings(selecting: nil) }
        ))
        return nodes
    }

    /// 規則にこのフォルダを入れる・外す。
    ///
    /// 入れるほうはブックマークを作る I/O を挟むので非同期で、その Task を返す(外すほうはその場で済むので nil)。
    /// メニューからは捨てる。返すのはテストが完了そのものを待つため ―― 以前のテストは保存されるまで
    /// 5 秒を期限に時間で見張っていて、CI の混んだ機では期限を過ぎて落ちた(2026-09-18。docs/13 の「時間で待たない」)。
    @discardableResult
    func toggleAutoRename(folder: URL, ruleID: UUID) -> Task<Void, Never>? {
        guard let store = autoRenameStore, let service = autoRenameService else { return nil }
        let path = AutoRename.canonicalPath(of: folder)
        if store.ruleContains(path: path, ruleID: ruleID) {
            store.removeTarget(path: path, fromRule: ruleID)
            return nil
        }
        guard allowsSaving, service.eligibility(ofFolder: folder) == .available else { return nil }
        return Task { [weak self] in
            let result = await service.addTarget(folder: folder, toRule: ruleID)
            guard result == .added else { return }
            self?.openAutoRenameSettings(selecting: ruleID)
        }
    }

    /// 「このフォルダの規則を作る…」: このフォルダを対象に入れた規則を作って、設定ウインドウでそれを選ぶ。
    /// 返す Task は toggleAutoRename と同じくテストが完了を待つためのもの。
    @discardableResult
    func createAutoRenameRule(for folder: URL) -> Task<Void, Never>? {
        guard allowsSaving, let store = autoRenameStore, let service = autoRenameService, let rule = store.addRule() else { return nil }
        return Task { [weak self] in
            _ = await service.addTarget(folder: folder, toRule: rule.id)
            self?.openAutoRenameSettings(selecting: rule.id)
        }
    }

    func openAutoRenameSettings(selecting ruleID: UUID?) {
        if let ruleID { autoRenameService?.requestedRuleID = ruleID }
        openWindow?(id: AutoRenameSettingsWindow.windowID)
    }
}
