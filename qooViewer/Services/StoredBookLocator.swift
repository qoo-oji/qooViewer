import Foundation

/// 保存データ(ブックマーク・レイアウト・メタデータ・コレクション)にしか居場所の手がかりが無い本の場所を、**メインの外で**解決する
/// (2026-10-04 の監査 O-12・BE-12)。編集ウインドウ(ブックマーク・レイアウト / メタデータ)の「開く」とページのダブルクリック、
/// 編集ウインドウの右ペインの読み込みが使う。
///
/// ■ なぜ 1 つにまとめたか
/// 以前は入口ごとに手がかりの選び方と解決の仕方が違った。ブックマーク・レイアウトの編集ウインドウの左ペインのダブルクリックは
/// ブックマーク → レイアウトの順に `.userOpen` で**メインで同期に**解決し(電源の落ちた NAS では約 30 秒メインが止まる)、
/// 右ペインの読み込み・ページのダブルクリックはレイアウトの行だけを見たので、ブックマークしか持たない本(許可の無い場所の本を直接
/// 開いてブックマークだけ付けた)は「見つかりません」になった(左ペインでは開けるのに)。メタデータの編集の「開く」は既定の
/// `.background` で解決し、繋がっていないボリュームの本を素のパスで新しい窓に渡してエラーにした。
///
/// ■ 形
/// `CollectionItemOpenProbe`(コレクションの本を開く前の確かめ)と同じ: 材料(`Material`)はメインで値へ写し取り、解決は `FileIO` の上で
/// 期限つき。手がかりはブックマーク → レイアウト → メタデータ → コレクションの順に試し、どれも無ければ記録したパスそのもの。
/// ゴミ箱の中まで追った場所は見つからない扱い(`BookLocationResolver.outsideTrash`。監査 O-11)。
nonisolated enum StoredBookLocator {
    /// 解決の材料。SwiftData のモデルはアクターを跨げないので、メインにいるうちに値へ写し取る。
    struct Material: Sendable {
        let bookID: String
        /// 試す順のブックマーク(ブックマーク → レイアウト → メタデータ → コレクション)。
        let bookmarks: [Data]
    }

    enum Outcome: Sendable {
        case found(URL)
        case notFound
        /// 期限までに返ってこなかった(`CollectionItemOpenProbe` の型コメント「期限」)。
        case timedOut
    }

    /// 期限は `CollectionItemOpenProbe` と同じ(利用者が自分で開いた本。眠っていた共有へ繋ぎに行く時間は待つ)。
    static var limit: Duration { CollectionItemOpenProbe.limit }

    @MainActor
    static func material(
        forBookID bookID: String, bookmarkStore: BookmarkStore?, layoutStore: LayoutStore?,
        metadataStore: BookMetadataStore? = nil, collectionStore: CollectionStore? = nil
    ) -> Material {
        var bookmarks = bookmarkStore?.bookmarks(forBookID: bookID).compactMap(\.bookmarkData) ?? []
        if let data = layoutStore?.bookLayoutSettings(forBookID: bookID)?.bookmarkData { bookmarks.append(data) }
        if let data = metadataStore?.metadata(forBookID: bookID)?.bookmarkData { bookmarks.append(data) }
        if let data = collectionStore?.anyBookmarkData(forBookID: bookID) { bookmarks.append(data) }
        return Material(bookID: bookID, bookmarks: bookmarks)
    }

    /// 解決の本体。**ブロッキングする**(ボリュームへの問い合わせ)ので、メインから呼ばない。
    static func resolveNow(_ material: Material, purpose: BookmarkResolution.Purpose) -> URL? {
        for data in material.bookmarks {
            if let url = BookmarkResolution.resolve(data, purpose: purpose),
               FileManager.default.fileExists(atPath: url.path),
               let outside = BookLocationResolver.outsideTrash(url) {
                return outside
            }
        }
        let recorded = URL(fileURLWithPath: material.bookID)
        guard FileManager.default.fileExists(atPath: recorded.path) else { return nil }
        return BookLocationResolver.outsideTrash(recorded)
    }

    /// `FileIO` の上で、期限つきで解決する。
    static func resolve(_ material: Material, purpose: BookmarkResolution.Purpose = .userOpen) async -> Outcome {
        do {
            let url = try await FileIO.withDeadline(limit) {
                await FileIO.perform { resolveNow(material, purpose: purpose) }
            }
            return url.map(Outcome.found) ?? .notFound
        } catch {
            return .timedOut
        }
    }
}
