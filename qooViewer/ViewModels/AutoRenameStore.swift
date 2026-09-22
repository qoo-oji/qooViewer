import Combine
import Foundation
import SwiftUI

/// 自動リネームの規則(2026-09-15、ユーザー要望。docs/plans/auto-rename-study.md)。アプリ全体で 1 つ(AppStores)。
///
/// ■ 持つのは規則だけ
/// 対象フォルダが「いま使えるか」(よく使う項目の配下か・ボリュームが繋がっているか・権限・読み取り専用モード)は保存せず、
/// 実行役(AutoRenameService)が毎回見る(検討メモ §4)。ここに残るのは、利用者が決めたことと、自動で OFF にした事実
/// (`disabledMissing`)と、今ある項目に掛けることを確認した印(`confirmedSignature`)だけ。
///
/// ■ 確認の印が外れる場面(§8 の 2)
/// 検索文字列・置換文字列・大文字小文字・フォルダの名前も変えるか・サブフォルダを含めるかが変わると、印の中身と合わなくなって
/// 自然に外れる(AutoRenameTarget.isConfirmed)。規則や対象を OFF にしたときは、ここで印を消す ―― ON に戻したら確認し直す。
///
/// 保存は `UserDefaults` の JSON。「すべてのデータを削除」はドメインごと消すので一緒に消え、「初期設定に戻す」の対象ではない
/// (よく使う項目と同じ。§8 の 10)。`AppStores.allObjectWillChangePublishers` には**足さない**(メニューバーに現れない)。
@MainActor
final class AutoRenameStore: ObservableObject {
    static let defaultsKey = "qooViewer.fileBrowser.autoRename.rules"
    static let excludedPathsKey = "qooViewer.fileBrowser.autoRename.excludedPaths"
    /// 除外するパスの上限(古いものから捨てる)。
    static let maxExcludedPaths = 2000

    @Published private(set) var rules: [AutoRenameRule]
    /// 実行ログから元の名前に戻した項目のパス。規則はこれらの名前を変えない(戻した直後にまた変えないため)。
    /// 利用者が後で名前を変えればパスが変わるので、自然に外れる。
    @Published private(set) var excludedPaths: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([AutoRenameRule].self, from: data) {
            rules = decoded
        } else {
            rules = []
        }
        excludedPaths = defaults.stringArray(forKey: Self.excludedPathsKey) ?? []
    }

    func exclude(path: String) {
        let path = AutoRename.canonicalPath(path)
        guard !excludedPaths.contains(path) else { return }
        excludedPaths = Array((excludedPaths + [path]).suffix(Self.maxExcludedPaths))
        defaults.set(excludedPaths, forKey: Self.excludedPathsKey)
    }

    /// アプリの中での移動・名前の変更に、除外したパスを付いていかせる(2026-09-22 の監査)。**名前がそのままのもの**だけ ――
    /// 親のフォルダの名前を変えた・その項目を別のフォルダへ移した。以前は付いていかず、利用者が明示的に戻した項目が、親の名前を
    /// 変えただけでまた自動で改名された。項目自身の名前が変わったもの(利用者が名前を変えた)は、今までどおり自然に外れる。
    /// - Returns: 書き換えたか。
    @discardableResult
    func relocateExcludedPaths(using change: FileSystemChange) -> Bool {
        guard !change.relocations.isEmpty, !excludedPaths.isEmpty else { return false }
        var changed = false
        var relocated: [String] = []
        for path in excludedPaths {
            guard let moved = change.relocatedPath(for: path).map(AutoRename.canonicalPath), moved != path,
                  (moved as NSString).lastPathComponent == (path as NSString).lastPathComponent else {
                relocated.append(path)
                continue
            }
            changed = true
            if !relocated.contains(moved) { relocated.append(moved) }
        }
        guard changed else { return false }
        excludedPaths = relocated
        defaults.set(excludedPaths, forKey: Self.excludedPathsKey)
        return true
    }

    /// アプリの中での移動・名前の変更に、対象フォルダを付いていかせる(2026-09-22 の監査。以前はファイルブラウザで対象フォルダの
    /// 名前を変えると、対象が「見つからない」→ OFF → 移動の提案 →「更新」待ちになった。よく使う項目のほうは自動で付いていく)。
    /// 同じボリュームの中での移動だけ(ボリュームをまたぐと記録したボリュームの UUID が合わなくなるので、今までどおり移動の提案に任せる)。
    /// 確認の印は、付け替える前に確認済みだったなら新しいパスで付け直す(中身は同じなので、確認し直させない)。
    /// - Returns: 書き換えたか。
    @discardableResult
    func relocateTargets(using change: FileSystemChange, mounts: MountTable = .current()) -> Bool {
        guard !change.relocations.isEmpty else { return false }
        var changed = false
        for ruleIndex in rules.indices {
            let rule = rules[ruleIndex]
            var targets = rule.targets
            for targetIndex in targets.indices {
                let old = targets[targetIndex]
                guard let moved = change.relocatedPath(for: old.path).map(AutoRename.canonicalPath), moved != old.path,
                      mounts.areOnSameVolume(URL(fileURLWithPath: old.path), URL(fileURLWithPath: moved)),
                      !targets.contains(where: { $0.id != old.id && $0.path == moved }) else { continue }
                let wasConfirmed = old.confirmedSignature == old.signature(for: rule)
                targets[targetIndex].path = moved
                targets[targetIndex].confirmedSignature = wasConfirmed ? targets[targetIndex].signature(for: rule) : nil
            }
            if targets != rule.targets {
                rules[ruleIndex].targets = targets
                changed = true
            }
        }
        if changed { save() }
        return changed
    }

    var canAddRule: Bool { rules.count < AutoRename.maxRules }

    func rule(withID id: UUID) -> AutoRenameRule? {
        rules.first { $0.id == id }
    }

    // MARK: - 規則

    /// 規則を末尾に足す。上限なら nil。
    @discardableResult
    func addRule(targets: [AutoRenameTarget] = []) -> AutoRenameRule? {
        guard canAddRule else { return nil }
        let rule = AutoRenameRule(targets: Array(targets.prefix(AutoRename.maxTargetsPerRule)))
        rules.append(rule)
        save()
        return rule
    }

    func removeRule(id: UUID) {
        guard rules.contains(where: { $0.id == id }) else { return }
        rules.removeAll { $0.id == id }
        save()
    }

    /// 並べ替え(一覧のドラッグ)。`List.onMove` の引数そのまま。
    func moveRules(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = rules
        reordered.move(fromOffsets: source, toOffset: destination)
        guard reordered != rules else { return }
        rules = reordered
        save()
    }

    /// 規則の中身を書き換える(名前・検索/置換・大文字小文字・フォルダ・ON/OFF)。対象の列は `update(target:inRule:)` などで変える
    /// ―― ここで渡された `targets` は使わない(画面が古い写しを持ったまま書き戻して、裏で OFF にした対象を ON に戻さないように)。
    func update(rule updated: AutoRenameRule) {
        guard let index = rules.firstIndex(where: { $0.id == updated.id }) else { return }
        var rule = updated
        rule.targets = rules[index].targets
        if !rule.isEnabled {
            for targetIndex in rule.targets.indices { rule.targets[targetIndex].confirmedSignature = nil }
        }
        guard rule != rules[index] else { return }
        rules[index] = rule
        save()
    }

    // MARK: - 対象

    /// 対象を足す。上限・同じパスが既にあるときは false。
    @discardableResult
    func add(target: AutoRenameTarget, toRule ruleID: UUID) -> Bool {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }),
              rules[index].targets.count < AutoRename.maxTargetsPerRule,
              !rules[index].targets.contains(where: { $0.path == target.path })
        else { return false }
        rules[index].targets.append(target)
        save()
        return true
    }

    func removeTarget(id targetID: UUID, fromRule ruleID: UUID) {
        guard let index = rules.firstIndex(where: { $0.id == ruleID }) else { return }
        let before = rules[index].targets.count
        rules[index].targets.removeAll { $0.id == targetID }
        guard rules[index].targets.count != before else { return }
        save()
    }

    /// そのパスを対象に持つ規則から、そのパスの対象を外す(右クリックのチェックを外したとき)。
    func removeTarget(path: String, fromRule ruleID: UUID) {
        let path = AutoRename.canonicalPath(path)
        guard let target = rule(withID: ruleID)?.targets.first(where: { $0.path == path }) else { return }
        removeTarget(id: target.id, fromRule: ruleID)
    }

    /// 対象の設定(ON/OFF・サブフォルダを含める)を書き換える。OFF にしたら確認の印を消す。
    func update(target updated: AutoRenameTarget, inRule ruleID: UUID) {
        guard let ruleIndex = rules.firstIndex(where: { $0.id == ruleID }),
              let targetIndex = rules[ruleIndex].targets.firstIndex(where: { $0.id == updated.id })
        else { return }
        var target = updated
        if target.state != .enabled {
            target.confirmedSignature = nil
        }
        if target.state != .disabledMissing {
            target.stateBeforeMissing = nil
        }
        guard target != rules[ruleIndex].targets[targetIndex] else { return }
        rules[ruleIndex].targets[targetIndex] = target
        save()
    }

    /// ON/OFF だけを切り替える(チェックボックス)。
    func setTarget(id targetID: UUID, inRule ruleID: UUID, enabled: Bool) {
        guard var target = rule(withID: ruleID)?.targets.first(where: { $0.id == targetID }) else { return }
        target.state = enabled ? .enabled : .disabledByUser
        update(target: target, inRule: ruleID)
    }

    /// 見つからなかった対象を自動で OFF にする(§6.2)。ON のものだけ。同じパスの対象は規則をまたいでそろって OFF になる
    /// (呼び出し側がパスで集めて渡す)。
    func markMissing(targetIDs: Set<UUID>) {
        var changed = false
        for ruleIndex in rules.indices {
            for targetIndex in rules[ruleIndex].targets.indices where targetIDs.contains(rules[ruleIndex].targets[targetIndex].id) {
                guard rules[ruleIndex].targets[targetIndex].state != .disabledMissing else { continue }
                rules[ruleIndex].targets[targetIndex].stateBeforeMissing = rules[ruleIndex].targets[targetIndex].state
                rules[ruleIndex].targets[targetIndex].state = .disabledMissing
                rules[ruleIndex].targets[targetIndex].confirmedSignature = nil
                changed = true
            }
        }
        if changed { save() }
    }

    /// 今ある項目に掛けることを確認した(§8 の 2)。いまの中身で印を付ける。
    func confirm(targetIDs: Set<UUID>) {
        var changed = false
        for ruleIndex in rules.indices {
            let rule = rules[ruleIndex]
            for targetIndex in rule.targets.indices where targetIDs.contains(rule.targets[targetIndex].id) {
                let signature = rule.targets[targetIndex].signature(for: rule)
                guard rules[ruleIndex].targets[targetIndex].confirmedSignature != signature else { continue }
                rules[ruleIndex].targets[targetIndex].confirmedSignature = signature
                changed = true
            }
        }
        if changed { save() }
    }

    /// 移動の提案で「更新」した(§6.3)。パス・ボリューム・ブックマークを新しい場所で書き直し、見つからなくなる前の ON/OFF に戻す。
    /// 確認の印は外れる(パスが印の中身に入っている)ので、ON に戻った対象は確認し直してから掛かる。
    func relocate(targetIDs: Set<UUID>, to path: String, volumeUUID: String?, bookmark: Data?) {
        let normalized = AutoRename.canonicalPath(path)
        var changed = false
        for ruleIndex in rules.indices {
            var targets = rules[ruleIndex].targets
            var removing: Set<UUID> = []
            for targetIndex in targets.indices where targetIDs.contains(targets[targetIndex].id) {
                // 同じ規則に移動先のパスが既にあれば、重複させずに見つからない方を外す。
                if targets.contains(where: { $0.id != targets[targetIndex].id && $0.path == normalized }) {
                    removing.insert(targets[targetIndex].id)
                    continue
                }
                targets[targetIndex].path = normalized
                targets[targetIndex].volumeUUID = volumeUUID
                targets[targetIndex].bookmark = bookmark
                targets[targetIndex].state = targets[targetIndex].stateBeforeMissing ?? .enabled
                targets[targetIndex].stateBeforeMissing = nil
                targets[targetIndex].confirmedSignature = nil
                targets[targetIndex].suppressesMoveSuggestion = false
            }
            targets.removeAll { removing.contains($0.id) }
            if targets != rules[ruleIndex].targets {
                rules[ruleIndex].targets = targets
                changed = true
            }
        }
        if changed { save() }
    }

    /// 「この提案を表示しない」。
    func suppressMoveSuggestion(targetIDs: Set<UUID>) {
        var changed = false
        for ruleIndex in rules.indices {
            for targetIndex in rules[ruleIndex].targets.indices where targetIDs.contains(rules[ruleIndex].targets[targetIndex].id) {
                guard !rules[ruleIndex].targets[targetIndex].suppressesMoveSuggestion else { continue }
                rules[ruleIndex].targets[targetIndex].suppressesMoveSuggestion = true
                changed = true
            }
        }
        if changed { save() }
    }

    /// そのパスを対象に持つか(右クリックのチェック)。
    func ruleContains(path: String, ruleID: UUID) -> Bool {
        let path = AutoRename.canonicalPath(path)
        return rule(withID: ruleID)?.targets.contains { $0.path == path } ?? false
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(rules) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// 自動リネームの実行ログ(§8 の 7・9。画面の呼び名は「実行ログ」。「履歴」は本の履歴に使っているので使わない)。
/// 新しい順に `maxEntries` 件まで `UserDefaults` に持つ。
@MainActor
final class AutoRenameActivityLog: ObservableObject {
    nonisolated struct Entry: Codable, Identifiable, Equatable, Sendable {
        nonisolated enum Outcome: Codable, Equatable, Sendable {
            case renamed(newName: String)
            /// 名前を変えなかった(理由の文を持つ。文は書いた時点の表示言語)。
            case skipped(result: String, reason: String)
            case failed(newName: String, message: String)
            /// 実行ログから元の名前に戻した。`fromName` は自動で付けていた名前。
            case restored(fromName: String)
        }

        var id: UUID
        var date: Date
        /// 項目があったフォルダ。
        var folderPath: String
        var originalName: String
        var outcome: Outcome
        /// かけた規則の表示名。
        var ruleNames: [String]
        /// 名前を変えた直後の実体(元に戻すとき、同じパスの別の項目に触らないため)。
        var identity: FileIdentity?

        init(
            id: UUID = UUID(), date: Date = Date(), folderPath: String, originalName: String, outcome: Outcome,
            ruleNames: [String], identity: FileIdentity? = nil
        ) {
            self.id = id
            self.date = date
            self.folderPath = folderPath
            self.originalName = originalName
            self.outcome = outcome
            self.ruleNames = ruleNames
            self.identity = identity
        }
    }

    static let defaultsKey = "qooViewer.fileBrowser.autoRename.activityLog"
    static let maxEntries = 500

    @Published private(set) var entries: [Entry]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded
        } else {
            entries = []
        }
    }

    /// まとめて足す(フォルダ 1 つぶんの結果ごと。1 件ずつ書くと 1000 件の名前の変更で 1000 回保存する)。
    func append(_ newEntries: [Entry]) {
        guard !newEntries.isEmpty else { return }
        entries = Array((newEntries.reversed() + entries).prefix(Self.maxEntries))
        save()
    }

    func removeAll() {
        guard !entries.isEmpty else { return }
        entries = []
        save()
    }

    func replace(_ entry: Entry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
