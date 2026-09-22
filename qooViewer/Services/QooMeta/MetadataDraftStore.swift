import Foundation
import QooMetaKit

/// メタデータの編集ウインドウで**直したが、まだロック(登録)していなかった**値の置き場(2026-09-21〜22)。**今は引き継ぐだけ**。
///
/// 2026-09-21〜22 は「ロック = 登録」で、ロックしていない本の直した値は DB に書かず、ここ(コンテナの
/// Application Support/qooMeta/drafts.json。**蔵書の名前が入る**)に持っていた。利用者の指示(2026-09-22)で、解析した本は
/// すべて DB に登録し、直した欄も行に持つようになった(`BookMetadata.edits`)ので、起動時に 1 度だけ DB へ移して
/// ファイルを消す(`migrate(into:rules:)`)。
///
/// ■ 読めないファイルは消さない
/// 読めなかった drafts.json(qooMeta の版が上がって `Confirmation` の形が変わった、など)は、隣へ写しを残す(`drafts.unreadable-<日時>.json`)。
@MainActor
final class MetadataDraftStore {
    struct Draft: Codable, Hashable {
        var confirmation: Confirmation
        /// 右クリックで選んだルールセット(nil なら自動)。
        var preset: String?
    }

    private(set) var drafts: [String: Draft] = [:]
    let url: URL

    nonisolated static var defaultURL: URL {
        MetadataRulesStore.defaultURL.deletingLastPathComponent().appendingPathComponent("drafts.json")
    }

    /// 読めなかったファイルの写しを残せなかった。このあいだは上書きしない(型コメント「読めないファイル」)。
    private(set) var holdsSaving = false

    init(url: URL = MetadataDraftStore.defaultURL) {
        self.url = url
        guard let data = try? Data(contentsOf: url) else { return }
        if let decoded = try? JSONDecoder().decode([String: Draft].self, from: data) {
            drafts = decoded
        } else {
            keepUnreadableCopy()
        }
    }

    /// 読めなかったファイルを隣へ移しておく(drafts.unreadable-<日時>.json)。移せなければ保存を止める。
    private func keepUnreadableCopy() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let copy = url.deletingLastPathComponent().appendingPathComponent("drafts.unreadable-\(stamp).json")
        do {
            try FileManager.default.moveItem(at: url, to: copy)
            NSLog("qooViewer: the metadata drafts could not be read and were kept as %@", copy.lastPathComponent)
        } catch {
            holdsSaving = true
            NSLog("qooViewer: the metadata drafts could not be read or kept aside; drafts are not saved: %@",
                  error.localizedDescription)
        }
    }

    /// 下書きを DB へ移し、ファイルを消す。行の無い本はロックせずに登録し(直した欄とルールセットつき)、ロックしていない
    /// 行には直した欄とルールセットを入れる。**ロックした行は変えない**(以前から、登録した値が下書きより優先だった)。
    /// - Returns: 移した本の数。
    @discardableResult
    func migrate(into metadataStore: BookMetadataStore, rules: CompiledRules) -> Int {
        guard !drafts.isEmpty else { return 0 }
        var entries: [BookMetadataStore.BatchEntry] = []
        for (bookID, draft) in drafts.sorted(by: { $0.key < $1.key }) {
            guard metadataStore.metadata(forBookID: bookID)?.isLocked != true else { continue }
            let values = MetadataParsing.values(forBookID: bookID, edits: draft.confirmation, ruleSet: draft.preset,
                                                rules: rules)
            entries.append(BookMetadataStore.BatchEntry(
                bookID: bookID, values: values,
                state: BookMetadataRowState(isLocked: false, edits: draft.confirmation, ruleSet: draft.preset)))
        }
        let count = metadataStore.upsertAll(entries)
        drafts = [:]
        try? FileManager.default.removeItem(at: url)
        return count
    }
}
