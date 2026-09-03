import SwiftUI

/// 「お気に入りに追加」を実行したときに表示する、登録先フォルダを選ぶシート。
/// メニューバー・ツールバー・コンテキストメニュー・キーボードショートカット(addToFavorites)の
/// すべてから、このView1つを共通で呼び出す(ViewerView.swift参照)。
///
/// 登録の実行(FavoritesStore.addFavorite)が返す結果に応じて、
/// - 上書き/新規登録が成功した場合はそのまま閉じる
/// - 別フォルダに既に登録されていた場合は確認ダイアログを出し、了承されたらforceAddFavoriteで再実行
/// - 件数上限に達していた場合はエラーメッセージを表示する
/// という分岐を行う(要望5関連の仕様。favorites_feature_assessment.md参照)。
struct FavoriteFolderPickerView: View {
    let book: MangaBook
    @ObservedObject var favoritesStore: FavoritesStore
    /// 登録(新規追加・上書きのどちらも)が成功したときに呼ばれる。呼び出し元(ViewerView)が
    /// 「“Xxx”をお気に入りに追加しました」というトースト表示に使う。件数上限などで登録
    /// できなかった場合、および「Cancel」で閉じた場合は呼ばれない。
    var onAdded: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale

    /// nilは「フォルダ分けせず、お気に入りの一番上の階層に直接置く」ことを表す。
    @State private var selectedFolder: FavoriteFolder?
    @State private var isShowingNewFolderPrompt = false
    @State private var newFolderName = ""
    @State private var newFolderErrorMessage: String?
    @State private var duplicateConfirmationBreadcrumb: String?
    @State private var registrationErrorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                List {
                    Button {
                        selectedFolder = nil
                    } label: {
                        HStack {
                            Image(systemName: "star")
                            Text("Favorites (Top Level)")
                            Spacer()
                            if selectedFolder == nil {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    ForEach(favoritesStore.rootFolders, id: \.id) { folder in
                        FolderTreeRow(
                            folder: folder,
                            depth: 0,
                            favoritesStore: favoritesStore,
                            selectedFolder: $selectedFolder
                        )
                    }
                }
                .navigationTitle(String(localized: "Add to Favorites", language: locale))
            }

            Divider()
            bottomBar
        }
        .frame(minWidth: 360, minHeight: 420)
        .alert("New Folder", isPresented: $isShowingNewFolderPrompt) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Cannot Create Folder",
            isPresented: Binding(
                get: { newFolderErrorMessage != nil },
                set: { isPresented in if !isPresented { newFolderErrorMessage = nil } }
            )
        ) {
            Button("OK") { newFolderErrorMessage = nil }
        } message: {
            Text(newFolderErrorMessage ?? "")
        }
        // 別フォルダに既に登録されている場合の確認(要望2)。フォルダのパンくずを示した上で、
        // それでもここに登録するかを確認する。
        .alert(
            "Already in Favorites",
            isPresented: Binding(
                get: { duplicateConfirmationBreadcrumb != nil },
                set: { isPresented in if !isPresented { duplicateConfirmationBreadcrumb = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { duplicateConfirmationBreadcrumb = nil }
            Button("Add Anyway") {
                duplicateConfirmationBreadcrumb = nil
                handle(favoritesStore.forceAddFavorite(book: book, to: selectedFolder))
            }
        } message: {
            // 文字列補間をそのままText("...")に渡すと、Xcodeの文字列カタログ抽出を経ていない
            // 手書きのLocalizable.xcstringsでは正しく翻訳と紐付かないため、KeyBindingSettingsView.swift
            // の「ショートカットが割り当て済み」アラートと同じく、固定文字列の断片をText同士の+で
            // つなぐ形にしている。
            Text("This book is already in “") + Text(duplicateConfirmationBreadcrumb ?? "")
                + Text("”. Add it here as well?")
        }
        // 件数上限(999件)に達していた場合など、登録できなかった場合のエラー表示。
        // ボタンを事前に無効化するのではなく、実際に「追加」を実行した時点でチェックする。
        .alert(
            "Could Not Add to Favorites",
            isPresented: Binding(
                get: { registrationErrorMessage != nil },
                set: { isPresented in if !isPresented { registrationErrorMessage = nil } }
            )
        ) {
            Button("OK") { registrationErrorMessage = nil }
        } message: {
            Text(registrationErrorMessage ?? "")
        }
    }

    /// ウインドウ下部のアクションバー。macOSの保存パネルと同じレイアウトで、
    /// 左端に「新規フォルダ…」、右端に「キャンセル」「追加」を同じ行に並べる
    /// (ユーザー要望: 新規フォルダボタンはキャンセル・追加ボタンと横一列になるように
    /// 左下に配置してほしい)。以前はツールバーのsecondaryActionに置いていたため、
    /// フォルダ作成の入口が分かりづらいという指摘があった
    /// (FavoritesOrganizerView.swiftで右クリックメニューを追加したのと同じ理由の指摘)。
    @ViewBuilder
    private var bottomBar: some View {
        HStack {
            Button {
                newFolderName = ""
                isShowingNewFolderPrompt = true
            } label: {
                Label("New Folder…", systemImage: "folder.badge.plus")
            }
            // 選択中のフォルダの直下に新規フォルダを作ると、階層の上限(3階層)を
            // 超えてしまう場合はここで無効化する。上限に達している旨は、それでも
            // 実行しようとしたとき(createFolder失敗時)にもアラートで表示する
            // (ボタンの無効化だけに頼らない。FavoritesStore.createFolderのコメント参照)。
            .disabled(!favoritesStore.canCreateSubfolder(in: selectedFolder))

            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)

            Button("Add") { performRegistration() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private func performRegistration() {
        handle(favoritesStore.addFavorite(book: book, to: selectedFolder))
    }

    private func handle(_ outcome: FavoriteAddOutcome) {
        switch outcome {
        case .added, .overwritten:
            onAdded?()
            dismiss()
        case .needsDuplicateConfirmation(let breadcrumb):
            duplicateConfirmationBreadcrumb = breadcrumb
        case .limitReached:
            registrationErrorMessage = FavoritesLimitError.favoritesLimitReached.errorDescription
        case .failed:
            registrationErrorMessage = String(localized: "The favorite could not be registered.", language: locale)
        }
    }

    private func createFolder() {
        switch favoritesStore.createFolder(name: newFolderName, parent: selectedFolder) {
        case .success(let folder):
            selectedFolder = folder
        case .failure(let error):
            newFolderErrorMessage = error.errorDescription
        }
    }
}

/// フォルダツリーを再帰的に描画する行。SwiftUIでは`some View`を返す関数は自分自身を
/// 再帰呼び出しできないため、専用のView構造体として実装する(FavoritesOrganizerView.swiftでも
/// 同じ理由で似た構造のViewを使う)。
private struct FolderTreeRow: View {
    let folder: FavoriteFolder
    let depth: Int
    @ObservedObject var favoritesStore: FavoritesStore
    @Binding var selectedFolder: FavoriteFolder?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                selectedFolder = folder
            } label: {
                HStack {
                    Image(systemName: "folder")
                    Text(folder.name)
                    Spacer()
                    if selectedFolder?.id == folder.id {
                        Image(systemName: "checkmark")
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.leading, CGFloat(depth) * 16)

            ForEach(favoritesStore.subfolders(of: folder), id: \.id) { child in
                FolderTreeRow(
                    folder: child,
                    depth: depth + 1,
                    favoritesStore: favoritesStore,
                    selectedFolder: $selectedFolder
                )
            }
        }
    }
}
