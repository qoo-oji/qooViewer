import SwiftUI

/// コレクション1つ分の設定(ユーザー要望 2026-09-09)。コレクションの中を見ているときに、
/// 右上のスライダーの右の歯車から出す。
///
/// **一覧ではライブラリの設定(LibrarySettingsPopover)が同じ場所から出る。** 以前は
/// コレクションの中でも一覧と同じライブラリの設定が出ていたが、開いている棚があるのに
/// その外側の設定が出るのは筋が通らない、というユーザーの判断で分けた。カバーの見せ方
/// (縦横比・切り出す位置・地の色)はライブラリ単位の設定のままなので、変えるときは
/// 一覧へ戻る。
///
/// いま持っているのは自動登録フォルダだけ:
/// - **自動登録フォルダ** … ここに指定したフォルダの直下へ本が増えると、ウェルカム画面を
///   見にきたタイミングでこのコレクションへ自動的に足される(CollectionAutoFolderScanner)。
///   拾う本の範囲は、そのフォルダを編集モード中にドロップしたときとまったく同じ
///   (直下だけ。ShelfFolderResolver)。
///
/// LibrarySettingsPopoverと同じく**説明文は置かない**(ユーザー指示 2026-09-09)。例外は
/// アクセス権が無いときの1行だけで、あれは飾りではなく「設定は入っているのに何も起きない」
/// 状態を画面から読めるようにするためのもの(CollectionAutoFolderRow参照)。
///
/// ポップオーバーの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md)。
struct CollectionSettingsPopover: View {
    let collection: BookCollection

    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var autoFolderScanner: CollectionAutoFolderScanner

    /// 欄で編集している最中の値。**DBへはまだ書かない**(下書き)。
    ///
    /// パスは直接打てる(CollectionAutoFolderRow)ので、1文字ごとにDBへ書くと、そのたびに
    /// save() と `.collectionsDidChange` の通知と `reload()` が走り、後ろの一覧が描き直される。
    /// 打ち終わりを待って1回だけ書く。
    @State private var draftFolder: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Collection Settings")
                    .font(.headline)
                Text(collection.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 300, alignment: .leading)
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Add Folder")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                CollectionAutoFolderRow(folder: $draftFolder)
            }
        }
        .onAppear { draftFolder = collection.autoFolderURL }
        // 打ち終わりの合図は2つ ―― Returnと、この面が閉じたとき。`.onSubmit`は下にある
        // TextFieldの確定を拾う(SwiftUIの確定は親へ伝わる)。パネルやドロップで選んだ場合も
        // 同じく閉じたときに書かれる ―― どのみち結果が見えるのは一覧へ戻ってからなので、
        // 入り口によって書く時機を変えない。
        .onSubmit { commitDraft() }
        .onDisappear { commitDraft() }
        .padding(12)
        // パスを出す欄があるので、ライブラリの設定より広めの下限を与える(それでも長いパスは
        // 中略されるが、末尾のフォルダ名は必ず見えるようにしてある)。
        .frame(minWidth: 340, alignment: .leading)
    }

    /// 下書きをDBへ書く。変わっていなければ何もしない。
    ///
    /// 書いた直後に走査を予約するのは、指定した瞬間にそのフォルダの本が入ってほしいため
    /// (次にアプリがアクティブになるまで何も起きないと、設定が効いているのか分からない)。
    ///
    /// LibrarySettingsPopoverのラジオは`@State`に写さず毎回DBを読んでいるが、こちらは
    /// 打っている途中という中間状態があるので下書きを持つ(draftFolderのコメント参照)。
    private func commitDraft() {
        guard draftFolder?.path != collection.autoFolderPath else { return }
        collectionStore.setAutoFolder(draftFolder, for: collection)
        autoFolderScanner.scheduleScan()
    }
}
