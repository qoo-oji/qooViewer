import SwiftUI

/// 起動時に「見つからなくなった本をコレクションから外しますか」と尋ねるシート
/// (ユーザー要望 2026-09-10。環境設定「一般」→「ウェルカム画面」の
/// `offersRemovingMissingCollectionBooks`がONのときだけ出る)。
///
/// **勝手に消さないための面**である。対象は`BookLocation.missing`の本だけ ―― ボリュームは
/// 付いているのに、ブックマークでも記録してあるパスでも実体に届かない本に限る(外付けを
/// 外しているだけの本は入らない。判定の根拠はBookLocationの型コメント)。それでも
/// 「実体が無い」と「別のボリュームへ移した」は区別できないので、消すかどうかは人が決める。
///
/// キャンセルしたら何も起きず、次の起動でまた尋ねる(煩わしければ設定でOFFにする、という
/// ユーザーの指定。その導線を面の下に文字で置いてある)。
///
/// シートの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct MissingBooksCleanupSheet: View {
    let sweep: CollectionStore.MissingBookSweep
    let onRemove: () -> Void
    let onCancel: () -> Void

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 幅はボタンではなくラベルに与える(CollectionNameSheetの同じコメント参照)。
        let labelWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [String(localized: "Cancel", language: locale), String(localized: "Remove", language: locale)],
            minWidth: 60,
            chrome: 0
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text("Books That Are No Longer There")
                .font(.headline)
            Text("The volume these books were on is connected, but their files are no longer there. They can be removed from their collections. The files themselves are already gone — removing does not delete anything.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            list

            if !sweep.emptiedCollectionNames.isEmpty {
                // 「コレクションごと消える」は取り消せない副作用なので、一覧とは別に名指しで出す
                // (自動登録フォルダを設定していたコレクションなら、その指定も一緒に失われる)。
                VStack(alignment: .leading, spacing: 2) {
                    Text("Every book in these collections is gone, so the collections are removed too:")
                        .font(.caption)
                    // 区切りは表示言語に従う(日本語なら「、」、英語なら "A and B")。
                    // ここを文字リテラルで繋ぐと、言語を切り替えたときだけ不自然になる。
                    Text(sweep.emptiedCollectionNames.formatted(.list(type: .and).locale(locale)))
                        .font(.caption)
                        .fontWeight(.semibold)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("You can turn this off in Settings ▸ General ▸ Welcome Screen.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) {
                    onCancel()
                    dismiss()
                } label: {
                    Text("Cancel").frame(width: labelWidth)
                }
                .keyboardShortcut(.cancelAction)
                // 取り消せない削除なので、Returnの既定ボタンにはしない(うっかり確定させない)。
                Button(role: .destructive) {
                    onRemove()
                    dismiss()
                } label: {
                    Text("Remove").frame(width: labelWidth)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    /// 本の一覧。コレクションごとにまとまった並びで届く(CollectionStore.missingBookSweep)。
    /// パスは出す ―― 「どの本か」はタイトルだけでは決められない(同名の本が別の場所にある、
    /// というのがまさにこの機能が扱う状況)。
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(sweep.books) { book in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(book.title)
                            .font(.callout)
                        Text(book.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                            .lineLimit(1)
                        if !book.collectionName.isEmpty {
                            Text(book.collectionName)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(8)
        }
        // 1冊でも枠の形が決まるようにし、多いときは中でスクロールさせる(面の高さを
        // 冊数に引きずらせない ―― 数百冊が対象になることはありうる)。
        .frame(height: 220)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
