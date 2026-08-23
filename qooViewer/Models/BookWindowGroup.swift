import Foundation

/// 本を表示する新しいウインドウ/タブを開くときに、どのWindowGroupを使うかを決める。
///
/// このアプリには本を表示するWindowGroupが4つある(QooViewerApp.swift参照)。
///   ・"main"    … 起動時にSwiftUIが自動で作る。環境設定「シークレットモードで起動」に従う
///   ・"book"    … 常に通常ウインドウ。`openWindow(id:value:)`で本を指定して開く
///   ・"normal"  … 常に通常ウインドウ。File ›「新規ノーマルウインドウ」専用(値なし)
///   ・"private" … 常にシークレットウインドウ
///
/// 「新しいウインドウ/タブで開く」経路は、コードのあちこち(メニューバー、ビューアの
/// お気に入り一覧、お気に入りの編集ウインドウ、ブックマークの編集ウインドウ)に散らばって
/// いて、どれも素の`openWindow(id: "book", value:)`を直接呼んでいた。環境設定
/// 「シークレットモードで起動」(ユーザー要望)を足したことで、これらがすべて
/// **設定を無視して記録の残るウインドウを開いてしまう**ようになったため、
/// 判断をこの1箇所へ集約する。
///
/// `AppState`/`AppPreferences`に触れるためメインアクター隔離のまま(このプロジェクトの
/// 既定の隔離。明示していないのは既定に従うため)。呼び出し元はいずれもViewである。
enum BookWindowGroup {
    /// - Parameter source: この操作の「派生元」となるウインドウのAppState。
    ///   ユーザーがあるウインドウの中で「新しいタブ/ウインドウで開く」を選んだ場合は、
    ///   **そのウインドウの性質をそのまま引き継ぐ**(シークレットウインドウから開いたタブだけ
    ///   記録される、あるいは「新規ノーマルウインドウ」から開いたタブが勝手にシークレットに
    ///   なる、のどちらも起こさないため)。
    ///   派生元が無い場合(独立した編集ウインドウからの操作、本を1つも開いていない場合、
    ///   Finder等の外部から渡された場合)はnilを渡す ―― そのときは環境設定に従う。
    static func id(inheritingFrom source: AppState?) -> String {
        let opensPrivately = source?.isPrivateWindow ?? AppPreferences.isPrivateModeDefault
        return opensPrivately ? "private" : "book"
    }
}

extension BookWindowGroup {
    /// 明示的な行き先(BookOpenDestination)から、使うWindowGroupのidを決める。
    /// 「引き継ぐ」以外の選択肢が増えたことによる拡張で、判断をここ1箇所に集めておく意図は
    /// 上の`id(inheritingFrom:)`とまったく同じ。
    ///
    /// - Parameter source: `.newWindow` / `.newTab`のときだけ意味を持つ派生元
    ///   (`id(inheritingFrom:)`へそのまま渡す)。`.newNormalWindow` / `.newPrivateWindow`は
    ///   ユーザーが性質そのものを選んでいるので、派生元も環境設定も見ない。
    static func id(for destination: BookOpenDestination, inheritingFrom source: AppState?) -> String {
        switch destination {
        case .newWindow, .newTab:
            return id(inheritingFrom: source)
        case .newNormalWindow:
            // "normal"ではなく"book"を使う。どちらも「常に通常ウインドウ」だが、"normal"は
            // ウェルカム画面から始まる**値なし**のウインドウ専用で、リサイズの都合から
            // `.windowResizability(.automatic)`にしてある。本を指定して開く場合は、
            // 従来どおり`.contentSize`の"book"が正しい(QooViewerApp.swiftの両WindowGroupの
            // コメント参照)。
            return "book"
        case .newPrivateWindow:
            return "private"
        }
    }
}
