import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// このビューを、ファイル/フォルダをドロップして本を開けるドロップ先にする。
    ///
    /// ウェルカム画面(WelcomeView)とビューア画面(ViewerView)の両方で使う。
    /// **ドロップの受け口はこの1か所にまとめること。** 画面ごとに`.onDrop`を書くと、
    /// 複数ファイルの扱い・並び順・失敗したアイテムの数え方といった細部が経路ごとに
    /// 食い違い、「ウェルカム画面なら複数開けるがビューア画面では1枚しか開けない」といった
    /// 差が生まれる(実際に、Finderからの`application(_:open:)`とウェルカム画面のドロップが
    /// どちらも先頭1件しか見ていなかった、という状態が長く残っていた)。
    ///
    /// 何をどう1冊にまとめるか(全部画像なら1冊 / それ以外は先頭のみ)の判定自体は、さらに
    /// その先の`BookOpenRequest.init(openingCandidates:)`が一手に引き受ける。ここが担うのは
    /// 「ドロップされたNSItemProviderの束から、URLの配列を漏れなく取り出す」ところまで。
    ///
    /// - Parameters:
    ///   - isTargeted: ドロップ先として反応している間trueになる(呼び出し側が見た目の強調に使う)。
    ///   - openURLs: 取り出せたURLをまとめて渡す。1つも取り出せなかった場合は空配列で呼ぶ。
    func bookFileDropTarget(
        isTargeted: Binding<Bool>, openURLs: @escaping ([URL]) -> Void
    ) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            guard !providers.isEmpty else { return false }
            // providersを1つも捨てずに全部からURLを取り出してからまとめて開く
            // (ユーザー要望: Finderで複数選択した画像をまとめて開く)。
            //
            // 1件ずつ順番にawaitしている。loadObjectのコールバックは任意のスレッドから順不同で
            // 呼ばれるうえ、URLを取り出せず失敗するアイテムも混ざりうるため、コールバックの
            // 到着順に頼らない形にしておきたい。並列化しない代わりに集計コードが要らず、
            // 実際の待ち時間もペーストボードの読み出しだけなので問題にならない
            // (大量選択の主な経路はFinder/Dockからのapplication(_:open:)で、そちらはそもそも
            // NSItemProviderを経由しない)。
            Task { @MainActor in
                var droppedURLs: [URL] = []
                for provider in providers {
                    if let url = await loadFileURL(from: provider) {
                        droppedURLs.append(url)
                    }
                }
                openURLs(droppedURLs)
            }
            return true
        }
    }
}

/// NSItemProvider.loadObjectのコールバックをasyncで待てるようにした薄いラッパー。
/// コールバックは仕様上ちょうど1回だけ呼ばれるため、continuationの二重再開は起こらない。
@MainActor
private func loadFileURL(from provider: NSItemProvider) async -> URL? {
    await withCheckedContinuation { continuation in
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            continuation.resume(returning: url)
        }
    }
}
