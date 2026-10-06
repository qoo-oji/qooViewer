import AppKit
import Observation

/// コレクションの本 1 冊を、開く・Finder に表示するなどの**直前に**確かめる(2026-09-27、表示の切り替えの監査の 11)。
///
/// ■ なぜメインの外か
/// 以前は `CollectionDetailView` がクリックの中で `CollectionStore.resolvedExistingURL(for:purpose: .userOpen)` を呼び、
/// ブックマークの解決(繋がっていない共有へは繋ぎに行く)と `fileExists` をメインで行い、見つからなければ
/// `CollectionStore.location(for:)` でもう一度解決していた。眠っている・応答しない NAS の本をダブルクリックすると、
/// SMB のタイムアウト(約 30 秒)まで回転カーソルのままアプリ全体が固まり、そのあいだ何の表示も無かった。
/// スマートライブラリ(`SmartLibraryPane.withResolvedURL`)と一覧の並びの「次の本へ」(`AppState.openInSequence`)は
/// すでに `FileIO` の上で確かめているので、同じ形にそろえる。
///
/// ■ 期限
/// 利用者が自分で開いた本なので、「次の本へ」の 5 秒(`AppState.sequenceProbeLimit`)よりずっと長く待つ ―― 眠っていた
/// 共有へ繋ぎに行くのは数秒〜十数秒かかり、繋がらなければ macOS が 30 秒ほどで自分のダイアログを出して解決が失敗する
/// (そのときは従来どおり「本が見つかりません」)。期限はそれより先の、返ってこない場合(NFS の hard マウントなど)だけの
/// 歯止めで、過ぎたら鳴らして待つのをやめる(I/O 自体は止まらない。FileIO.withDeadline)。
nonisolated enum CollectionItemOpenProbe {
    /// 確かめの材料。SwiftData のモデルはアクターを跨げないので、メインにいるうちに値へ写し取る
    /// (`BookLocationResolver.Probe` と同じ理由)。
    struct Material: Sendable {
        let itemID: UUID
        let title: String
        let bookmark: Data
        let recordedPath: String
        let volumeUUID: String?

        @MainActor
        init(_ item: CollectionItem) {
            itemID = item.id
            title = item.title
            bookmark = item.bookmarkData
            recordedPath = item.bookID
            volumeUUID = item.volumeUUID
        }
    }

    enum Outcome: Sendable {
        /// 解決でき、実体もある(スコープはもう閉じてある。`CollectionStore.existingURL` と同じ)。
        case found(URL)
        /// 見つからなかった。理由は `CollectionStore.location(for:)` と同じ割り出し(裏の解決。繋ぎに行かない)。
        case notFound(BookLocation)
        /// 期限までに返ってこなかった(上の型コメント「期限」)。
        case timedOut
    }

    static let limit: Duration = .seconds(45)

    static func resolve(_ material: Material) async -> Outcome {
        do {
            return try await FileIO.withDeadline(limit) {
                await FileIO.perform { () -> Outcome in
                    if let url = CollectionStore.existingURL(fromBookmark: material.bookmark, purpose: .userOpen) {
                        return .found(url)
                    }
                    return .notFound(location(of: material))
                }
            }
        } catch {
            return .timedOut
        }
    }

    /// 見つからなかった理由の割り出しだけ(「本が見つかりません」の文言を理由ごとに書き分ける)。以前はメインで
    /// `CollectionStore.location(for:)` を呼んでいた ―― 中身はこれと同じ(裏の解決。繋ぎに行かない)。**ブロッキングする**。
    static func location(of material: Material) -> BookLocation {
        BookLocationResolver.resolve(
            BookLocationResolver.Probe(
                itemID: material.itemID, bookmark: material.bookmark,
                recordedPath: material.recordedPath, volumeUUID: material.volumeUUID
            ),
            mountedVolumeUUIDs: BookLocationResolver.mountedVolumeUUIDs()
        )
    }
}

/// いま確かめている本(1 画面に 1 冊)。`CollectionDetailView` が `@State` で持つ。
///
/// **参照型で持つ**: 確かめを待つ Task が画面より長生きしても(待っている間にコレクションから出た)、同じ箱を見て
/// 「まだ自分の番か」を判断できるように。`@State` の値型だと、画面が外れた後に読んだ値は初期値に戻っていて、
/// 頼まれた本が黙って開かなくなる。
@MainActor @Observable
final class CollectionItemOpenTracker {
    /// 回転表示を出している本。確かめが短い間(ローカルの本はほぼ一瞬)に出すとちらつくので、少し待ってから立てる。
    private(set) var resolvingItemID: UUID?
    @ObservationIgnored private var currentToken: UUID?

    /// 回転表示を出すまでの待ち。**時限は `DispatchQueue`**(協調スレッドプールが塞がると `Task.sleep` は発火しない ―― FileIO.swift の
    /// 型コメントの実測。2026-10-06 の応答性の点検 R7-2)。
    private static let indicatorDelay: TimeInterval = 0.25

    /// 1 冊を確かめてから `body`(見つかった)か `onNotFound`(見つからない)を呼ぶ。続けて別の本(同じ本でも)を頼まれたら、
    /// 前の結果は捨てる(後から押したほうが利用者の意図)。期限切れは鳴らすだけ(上の「期限」)。
    ///
    /// - Parameter stillWanted: 待った後に、まだ頼んだときのままかを答える(2026-10-04 の監査 SP-10 = O-8)。このトラッカーは
    ///   同じ画面の次の頼みしか見ないので、待つ間(最長 45 秒)に**別の入口で**本を頼んだ(開く意図 `AppState.OpenIntent` が進んだ。
    ///   レビューの R6-1)、
    ///   ライブラリ機能を OFF にした、を呼ぶ側が確かめる。false なら何もしない(鳴らしもしない ―― 利用者はもう別のことをしている)。
    ///
    /// - Parameter onTimedOut: 期限切れのとき(既定はビープ)。窓の下に理由を出せる画面は渡す ―― 45 秒待たせた末にビープだけでは
    ///   理由が分からない(2026-10-06 の応答性の点検 R2-5)。
    func resolve(
        _ material: CollectionItemOpenProbe.Material,
        stillWanted: (@MainActor () -> Bool)? = nil,
        onNotFound: @escaping @MainActor (BookLocation) -> Void,
        onTimedOut: (@MainActor () -> Void)? = nil,
        _ body: @escaping @MainActor (URL) -> Void
    ) {
        let token = UUID()
        currentToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.indicatorDelay) { [weak self] in
            guard let self, self.currentToken == token else { return }
            self.resolvingItemID = material.itemID
        }
        Task { [self] in
            let outcome = await CollectionItemOpenProbe.resolve(material)
            guard currentToken == token else { return }
            currentToken = nil
            resolvingItemID = nil
            if let stillWanted, !stillWanted() { return }
            switch outcome {
            case .found(let url): body(url)
            case .notFound(let location): onNotFound(location)
            case .timedOut:
                if let onTimedOut { onTimedOut() } else { NSSound.beep() }
            }
        }
    }
}
