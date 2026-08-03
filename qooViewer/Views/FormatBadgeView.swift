import SwiftUI

/// 設計コンセプト9節: bookID(拡張子を含むフルパス)から導出する、ファイル形式を示す小さな
/// バッジ。フォルダ(拡張子なし)は「フォルダ」、それ以外は拡張子を大文字にしたラベル
/// (CBZ/EPUB/ZIP/RAR/CBR/7Z/CB7)。
///
/// EPUB書き出し機能(7節)により、同じ作品のcbz版とepub版が両方存在する(別々のbookIDとして、
/// お気に入り・ブックマーク・レイアウトにそれぞれ登録されうる)ケースが増える。
/// FavoriteBook.title・BookmarkBookGroup.displayNameのいずれも拡張子を除いた名前を保持・
/// 表示しており、同名のcbz/epubが並ぶと区別が付かないため、「ブックマーク・レイアウトの編集」
/// ウインドウ(4節)・EPUB出力ウインドウ(7節)の一覧行で、タイトルと並べてこれを表示する。
struct FormatBadgeView: View {
    let bookID: String

    private var pathExtension: String {
        URL(fileURLWithPath: bookID).pathExtension
    }

    var body: some View {
        Group {
            if pathExtension.isEmpty {
                Text("Folder")
            } else {
                // 拡張子自体(CBZ/ZIP/RARなど)は表示言語に関わらず同じ表記のため、
                // ローカライズキーとしては扱わずTextの直接値として表示する。
                Text(verbatim: pathExtension.uppercased())
            }
        }
        .font(.caption2)
        .fontWeight(.semibold)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color.secondary.opacity(0.15))
        .foregroundStyle(.secondary)
        .clipShape(Capsule())
    }

    /// NSMenuItem/プレーンテキストのButtonタイトルなど、このView自体を埋め込めない場所
    /// (AppKitネイティブのメニュー項目はカスタムViewを表示できない)向けの、拡張子付き
    /// ファイル名のプレーンテキスト版。
    ///
    /// ユーザー要望: 「ファイル名 (CBZ)」のように括弧書きで拡張子を添えるより、素直に
    /// 「ファイル名.cbz」と拡張子付きのファイル名として表示したほうが分かりやすい。
    /// 以前は" (CBZ)"のような大文字の括弧書きサフィックスを末尾に付けていたが、実際の
    /// ファイル名の見た目に近い「baseName.拡張子」(拡張子は小文字)の形に変更する。
    /// 「Folder」は元々拡張子が無く区別の必要が無いためbaseNameをそのまま返す
    /// (FavoritesMenuContent/FavoritesNSMenuBridgeのお気に入り一覧・FavoritesOrganizerView
    /// 以外の、メニュー項目としてタイトルを表示する箇所で使う)。
    static func plainTextTitle(baseName: String, bookID: String) -> String {
        let pathExtension = URL(fileURLWithPath: bookID).pathExtension
        guard !pathExtension.isEmpty else { return baseName }
        return "\(baseName).\(pathExtension.lowercased())"
    }
}
