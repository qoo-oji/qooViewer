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
/// 本は bookID(パス)で指すので、Finder で移した本の分は残ったまま使われない。
///
/// ■ 知らない本の分も捨てない(2026-09-22 の監査で指摘)
/// 以前は窓を開くたびに、一覧に無い本の下書きを捨てていた(`keepOnly`)。ところが一覧の母体のうちスマートライブラリの
/// 対象フォルダの本は、スマートライブラリを OFF にした・対象フォルダのボリュームが繋がっていない・対象から外した、の
/// どれでも一覧から消える ―― そのまま窓を開くだけで、その本の下書きが戻せない形で消えた。下書きは利用者が直した本の分
/// しか無く小さいので、捨てずに持ち続ける(一覧に戻ってくれば、また出る)。
///
/// ■ 読めないファイルは上書きしない
/// 読めなかった drafts.json(qooMeta の版が上がって `Confirmation` の形が変わった、など)は、空として読んだうえで次の
/// 保存で黙って上書きしていた。隣に写しを残してから使い始め、残せなければ保存しない(`MetadataRulesStore.keepCopy` と同じ)。
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

    /// その本の下書きを置き換える(nil なら消す)。
    func set(_ draft: Draft?, for bookID: String) {
        drafts[bookID] = draft
    }

    func save() {
        guard !holdsSaving else { return }
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
