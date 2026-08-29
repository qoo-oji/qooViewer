import SwiftUI

/// 一覧を持つウインドウの下部ステータスバー。
///
/// ユーザー指摘: 「何件中いくつ」の表示が、ウインドウによって下部中央だったり右寄せだったり
/// でバラバラだった。同じ種類の要素はどのウインドウでも同じ場所・同じ見た目にする。
///
/// 形はFinderのステータスバーに揃えてある ―― 中央寄せの小さい二次色の文字、`.bar`素材、
/// 上端に区切り線。`.safeAreaInset(edge: .bottom)`で敷くと、一覧がこのバーの下へ潜る
/// (クロームをツールバーへ載せた一連のウインドウと同じ作法。ScrollEdgeEffect.swift参照)。
///
/// 使う側は件数などのTextを並べるだけでよい。文字の大きさ・色・余白・背景はここで決める。
struct ListWindowStatusBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 6) {
            content
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// ステータスバーの項目どうしの区切り。文字列カタログへ登録させたくないためText(verbatim:)。
/// 「10件 / 30件を表示中 ・ 3件を選択中」のように、独立した情報を1行へ並べるときに挟む。
struct ListWindowStatusSeparator: View {
    var body: some View {
        Text(verbatim: "·")
            .foregroundStyle(.tertiary)
    }
}
