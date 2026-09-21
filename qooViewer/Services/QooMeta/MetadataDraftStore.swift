import Foundation
import QooMetaKit

/// メタデータの編集ウインドウで**直したが、まだロック(登録)していない**値の置き場(2026-09-21)。
///
/// 利用者の決定(2026-09-21、案 A)で「ロック = 登録」になった: 欄を直しても DB には書かず、鍵を掛けた時点の値で登録する。
/// 直しただけの値を窓の中にだけ持つと、窓を閉じたとき(アプリを終えたとき)に黙って消えるので、ここにファイルで残す
/// (qooMeta のアプリの作業ファイルに当たるもの)。鍵を掛けた本・提案に戻した本の分は消す。
///
/// 中身は本ごとの qooMeta の確定した内容(`Confirmation`)と、右クリックで選んだルールセット。保存先はコンテナの
/// Application Support/qooMeta/drafts.json(**蔵書の名前が入る** ―― 規則の設定と同じくコンテナの外へは書かない)。
/// 本は bookID(パス)で指すので、Finder で移した本の分は残ったまま使われない(窓を開いたときに、知らない本の分は捨てる)。
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

    init(url: URL = MetadataDraftStore.defaultURL) {
        self.url = url
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode([String: Draft].self, from: data) {
            drafts = decoded
        }
    }

    /// その本の下書きを置き換える(nil なら消す)。
    func set(_ draft: Draft?, for bookID: String) {
        drafts[bookID] = draft
    }

    /// 知らない本の分を捨てる(窓を開いたとき)。
    func keepOnly(_ bookIDs: Set<String>) {
        let before = drafts.count
        drafts = drafts.filter { bookIDs.contains($0.key) }
        if drafts.count != before { save() }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if drafts.isEmpty {
                try? FileManager.default.removeItem(at: url)
            } else {
                try encoder.encode(drafts).write(to: url, options: .atomic)
            }
        } catch {
            NSLog("qooViewer: saving the metadata drafts failed: %@", error.localizedDescription)
        }
    }
}
