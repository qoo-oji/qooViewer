import SwiftUI

/// 書き出しウインドウ(EPUB / PDF / CBZ)の、対象一覧の絞り込み(ユーザー要望)。
/// ツールバーの「絞り込みオプション…」ボタンから、隣の「書き出しオプション…」と**同じ形**で
/// ポップオーバーとして開く(ユーザーの指示: 名前が似ている以上、出し方も揃える)。
///
/// そのため見た目の作法もあちら(ExportWindowContentのoptionsクロージャの中身 =
/// BookExportFormatOptions)に合わせてある ―― 見出しも説明文も、確定・解除のボタンも置かず、
/// 項目だけを左揃えで縦に並べる(ユーザーの指示: 説明文と「絞り込みを解除」ボタンは、
/// 隣の書き出しオプションには無いもので、並べると見た目が崩れる)。
/// 解除は各項目を戻す操作そのもの ―― チェックを外す / ファイル形式を「すべて」に戻す ――
/// で行う。ポップオーバーは一覧を隠さないので、条件を変えるたびに後ろの一覧と下部の
/// ステータスバーの件数がその場で変わる。
///
/// 絞り込むのは一覧の見え方だけで、チェックボックス(選択)には触れない
/// (BookExportViewModel.selectedBookIDs / BookExportRowFilterのコメント参照)。
struct ExportFilterOptions: View {
    @ObservedObject var viewModel: BookExportViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 保存データの登録状態。3つのチェックボックスはAND(BookExportRowFilter参照)。
            // 「チェックした条件をすべて満たす本を表示します」といった説明文は置かない
            // (ユーザーの指示。隣の書き出しオプションと同じく、項目だけを並べる)。
            Toggle("Has Layout Info", isOn: $viewModel.rowFilter.requiresLayout)
            Toggle("Has Bookmarks", isOn: $viewModel.rowFilter.requiresBookmarks)
            Toggle("Has Metadata", isOn: $viewModel.rowFilter.requiresMetadata)

            // 元のファイル形式。1冊は必ず1形式なので単一選択のドロップダウンにしてある
            // (複数選択にできない理由はBookExportRowFilterのコメント参照)。
            Picker(selection: $viewModel.rowFilter.format) {
                ForEach(BookExportSourceFormat.allCases) { format in
                    format.titleText.tag(format)
                }
            } label: {
                Text("File Format")
            }
            .pickerStyle(.menu)
        }
    }
}
