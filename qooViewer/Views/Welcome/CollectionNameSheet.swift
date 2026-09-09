import AppKit
import SwiftUI

/// ライブラリ/コレクションの名前を入力するシート(改善要望5)。作成とリネームの4通りを
/// 1つの部品で受ける ―― 出す文言が違うだけで、欄の検証も確定の押し心地も同じであるべきなため。
///
/// **検証は入力のたびに行い、通らない間は確定ボタンを押せない。** 押してから「その名前は
/// 使えません」と返すより、押せない理由が欄の下に出ているほうが分かりやすい(重複の判定は
/// 呼び出し側がCollectionStore.hasCollectionNamed / hasLibraryNamedで行う)。
///
/// シートの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct CollectionNameSheet: View {
    enum Kind {
        case newCollection
        case renameCollection
        case newLibrary
        case renameLibrary

        var titleKey: LocalizedStringKey {
            switch self {
            case .newCollection: return "New Collection"
            case .renameCollection: return "Rename Collection"
            case .newLibrary: return "New Library"
            case .renameLibrary: return "Rename Library"
            }
        }

        /// 確定ボタン。作成は「Create」、リネームは「Rename」。
        var confirmKey: LocalizedStringKey {
            switch self {
            case .newCollection, .newLibrary: return "Create"
            case .renameCollection, .renameLibrary: return "Rename"
            }
        }

        /// 幅の実測に使う、確定ボタンのローカライズ用キーの文字列表現
        /// (LocalizedStringKeyからは文字列を取り出せないため、実測用に別に持つ)。
        var confirmLiteral: String.LocalizationValue {
            switch self {
            case .newCollection, .newLibrary: return "Create"
            case .renameCollection, .renameLibrary: return "Rename"
            }
        }

        var emptyMessageKey: LocalizedStringKey {
            isLibrary ? "Enter a library name." : "Enter a collection name."
        }

        var duplicateMessageKey: LocalizedStringKey {
            isLibrary
                ? "A library with this name already exists."
                : "A collection with this name already exists."
        }

        private var isLibrary: Bool {
            switch self {
            case .newLibrary, .renameLibrary: return true
            case .newCollection, .renameCollection: return false
            }
        }
    }

    /// 自動登録フォルダの欄の設定。
    struct AutoFolderField {
        /// 欄の初期値。ドロップ由来なら落とされた場所、「＋」からならnil(空欄)。
        var initial: URL?
    }

    let kind: Kind
    /// 名前欄の初期値(リネームなら今の名前、棚のドロップならフォルダ名)。
    let initialName: String
    /// 前後の空白を除いた名前が既に使われているか。
    let isDuplicate: (String) -> Bool
    /// 自動登録フォルダの欄を出すか(ユーザー要望 2026-09-09)。**新しいコレクションを作る
    /// ときだけ**渡す ―― リネームは名前を直すためだけの面で、ライブラリは自動登録を持たない。
    ///
    /// `nil`なら欄ごと出さない。`.some(nil)`(欄はあるが未選択)は「＋」から作った場合で、
    /// ここに値が入るのはドロップ由来のときだけ
    /// (WelcomeLibraryState.PendingCollectionCreation.autoFolder参照)。
    var autoFolder: AutoFolderField?

    /// 確定。前後の空白を除いた名前と、選ばれている自動登録フォルダ(欄を出していなければ
    /// 常にnil)が渡る。
    let onCommit: (String, URL?) -> Void
    /// 取り消し。待ち行列の先頭を取り除くために、Cancelでも呼び出し側へ返す必要がある
    /// (WelcomeLibraryState.pendingCreations参照)。
    var onCancel: () -> Void = {}
    /// 確定・取り消しのあと、このシートが自分で閉じるか。
    ///
    /// falseにするのは、**同じシートに続けて次の入力を出す**場合(棚をまとめてドロップした
    /// ときの待ち行列。WelcomeView参照)。閉じてすぐ開き直すとmacOSでは2枚目が出ないことが
    /// あるため、あちらは1枚を開いたまま中身だけ差し替え、行列が空になった時点で
    /// 提示のBindingがfalseになって閉じる、という形にしている。
    var dismissesOnFinish: Bool = true

    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    /// 選ばれている自動登録フォルダ(欄を出しているときだけ意味がある)。
    @State private var selectedAutoFolder: URL?
    /// 初期値をonAppearで入れるため、最初の1回だけ検証メッセージを出さない
    /// (開いた瞬間に赤い文字が出ているのは、まだ何も間違えていないので不親切)。
    @State private var didEdit = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var validationMessage: LocalizedStringKey? {
        if trimmedName.isEmpty { return kind.emptyMessageKey }
        if isDuplicate(trimmedName) { return kind.duplicateMessageKey }
        return nil
    }

    var body: some View {
        // **幅はボタンではなくラベルに与える。** `Button(...).frame(width:)`では、与えた幅は
        // レイアウト上の枠にしか効かず、実際に描かれるベゼルは文字列の長さのまま枠の中央に
        // 置かれる(実測。WelcomeTopBarの同じコメント参照)。ラベル側を同じ幅にすれば、
        // ベゼルもその幅+左右のインセットで揃う。余白(chrome)を0にしているのはそのため。
        let labelWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Cancel", language: locale),
                String(localized: kind.confirmLiteral, language: locale),
            ],
            minWidth: 60,
            chrome: 0
        )
        return VStack(alignment: .leading, spacing: 12) {
            Text(kind.titleKey)
                .font(.headline)

            // 欄と検証メッセージは**1つの塊**にする(ユーザー指摘 2026-09-09)。以前は3つを同じ
            // 間隔で並べていたので、見えていないメッセージのぶんだけ欄とボタンが離れて見えた。
            VStack(alignment: .leading, spacing: 2) {
                // SwiftUIの`TextField`ではなくNSTextFieldのラッパー(SelectAllTextField)を使う。
                // ブックマークのリネームシートと同じ部品で、開いた瞬間に今の名前が全選択される ――
                // リネームでそのまま打ち直せる、という同じ要望がここにも当てはまるため。
                //
                // 幅は**面に合わせて伸ばす**。固定幅(320)にしていたときは、シートの幅が別の
                // 都合で決まると欄の右にだけ余白が残った(ユーザー指摘)。
                SelectAllTextField(text: $name, onSubmit: commitIfPossible)
                    .frame(maxWidth: .infinity)
                    .frame(height: 22)
                    .onChange(of: name) { _, _ in didEdit = true }

                // 高さを予約しておく(メッセージの有無でシートの高さが跳ねないようにするため)。
                Group {
                    if didEdit, let validationMessage {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    } else {
                        Text(verbatim: " ")
                    }
                }
                .font(.caption)
            }

            if autoFolder != nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Add Folder")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    CollectionAutoFolderRow(folder: $selectedAutoFolder)
                }
            }

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button(role: .cancel) {
                    onCancel()
                    if dismissesOnFinish { dismiss() }
                } label: {
                    Text("Cancel").frame(width: labelWidth)
                }
                .keyboardShortcut(.cancelAction)
                Button { commitIfPossible() } label: {
                    Text(kind.confirmKey).frame(width: labelWidth)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(validationMessage != nil)
            }
        }
        .padding(20)
        // **幅は自分で決める。** 決めないと面の幅が中身から決まるのだが、いちばん広い部品が
        // 320ptの欄なのに**実測470pt**になっていた(ユーザー指摘 2026-09-09)。何がその幅を
        // 出しているのかは特定できていない ―― 有力なのはNSViewRepresentable(SelectAllTextField)が
        // 親へ返す寸法だが、確かめていないので断定しない。いずれにせよ、欄の右にだけ
        // 説明のつかない余白が残るのは面として読めないので、ここで決め打ちにする。
        // 名前を1つ入れるだけの面なので、欄が320ptになるこの値で足りる。自動登録フォルダの
        // 欄が増えてもこの幅のまま ―― パスは中略して出す(CollectionAutoFolderRow)ので、
        // 面の幅をパスの長さに引きずられないようにする。
        .frame(width: 360)
        .onAppear {
            name = initialName
            selectedAutoFolder = autoFolder?.initial
            // 初期値が入っているだけの状態を「編集した」と見なさない(didEditのコメント参照)。
            DispatchQueue.main.async { didEdit = false }
        }
    }

    private func commitIfPossible() {
        guard validationMessage == nil else { return }
        onCommit(trimmedName, autoFolder == nil ? nil : selectedAutoFolder)
        if dismissesOnFinish { dismiss() }
    }
}
