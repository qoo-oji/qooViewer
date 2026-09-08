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

    let kind: Kind
    /// 名前欄の初期値(リネームなら今の名前、棚のドロップならフォルダ名)。
    let initialName: String
    /// 前後の空白を除いた名前が既に使われているか。
    let isDuplicate: (String) -> Bool
    /// 確定。前後の空白を除いた名前が渡る。
    let onCommit: (String) -> Void
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
        let buttonWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Cancel", language: locale),
                String(localized: kind.confirmLiteral, language: locale),
            ],
            minWidth: 80
        )
        return VStack(alignment: .leading, spacing: 10) {
            Text(kind.titleKey)
                .font(.headline)

            // SwiftUIの`TextField`ではなくNSTextFieldのラッパー(SelectAllTextField)を使う。
            // ブックマークのリネームシートと同じ部品で、開いた瞬間に今の名前が全選択される ――
            // リネームでそのまま打ち直せる、という同じ要望がここにも当てはまるため。
            SelectAllTextField(text: $name, onSubmit: commitIfPossible)
                .frame(width: 320, height: 22)
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

            HStack(spacing: 12) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) {
                    onCancel()
                    if dismissesOnFinish { dismiss() }
                }
                .keyboardShortcut(.cancelAction)
                .frame(width: buttonWidth)
                Button(kind.confirmKey) { commitIfPossible() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(validationMessage != nil)
                    .frame(width: buttonWidth)
            }
        }
        .padding(20)
        .onAppear {
            name = initialName
            // 初期値が入っているだけの状態を「編集した」と見なさない(didEditのコメント参照)。
            DispatchQueue.main.async { didEdit = false }
        }
    }

    private func commitIfPossible() {
        guard validationMessage == nil else { return }
        onCommit(trimmedName)
        if dismissesOnFinish { dismiss() }
    }
}
