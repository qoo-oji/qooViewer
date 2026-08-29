import SwiftUI
import AppKit

/// 設計コンセプト5節: 選択中の本のブックマークをまとめてリネームするための画面。
/// 「ブックマーク・レイアウトの編集」ウインドウ(4.4節)の「一括リネーム」から開く。
///
/// 以前は独立したWindowシーン(id: "bulkRenameBookmarks")だった。Windowシーンは単一インスタンスで
/// `for:`による値のパラメータ化ができないため、対象のbookIDを
/// launchCoordinator.pendingBulkRenameBookID経由で渡す橋渡しが要り、さらに「まだ値が来ていない
/// 場合」のための「本が選ばれていません」というフォールバック画面まで抱えていた。
/// 実際には常に編集ウインドウの中の操作から開くものなので、そのウインドウ上のシートにした。
/// これで対象のbookIDは引数で受け取れるようになり、橋渡しの配管もフォールバック画面も消えた。
enum LastBookmarkTreatment: String, CaseIterable, Identifiable {
    case normal
    case afterword
    case colophon
    case bonus

    var id: String { rawValue }

    var titleKey: LocalizedStringKey {
        switch self {
        case .normal: return "Normal Bookmark"
        case .afterword: return "Afterword"
        case .colophon: return "Colophon"
        case .bonus: return "Bonus"
        }
    }

    /// String(localized:locale:)で使う、実際にリネームする際の固定名。
    /// .normalの場合は固定名を持たない(連番リネームの対象に含める)。
    var fixedNameKey: String.LocalizationValue? {
        switch self {
        case .normal: return nil
        case .afterword: return "Afterword"
        case .colophon: return "Colophon"
        case .bonus: return "Bonus"
        }
    }
}

struct BulkRenameBookmarksSheet: View {
    let bookID: String

    @EnvironmentObject private var bookmarkStore: BookmarkStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss

    @State private var assignFixedCover = false
    @State private var lastBookmarkTreatment: LastBookmarkTreatment = .normal
    @State private var startNumber = 1
    @State private var prefix = ""
    @State private var suffix = ""
    @State private var hasInitializedDefaults = false
    /// ユーザー要望: 「番号前の文字列」「番号後の文字列」を、右寄せのテキストフィールドではなく
    /// クリックして編集する「ボタン」に変更した(prefixSuffixEditorのコメント参照)。
    /// これらは、そのボタンをクリックしたときに開くポップオーバーの表示制御に使う。
    @State private var isEditingPrefix = false
    @State private var isEditingSuffix = false

    /// このシートが対象にするブックマーク(ページ順)。
    private var sortedBookmarks: [Bookmark] {
        bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
    }

    var body: some View {
        VStack(spacing: 0) {
            content(for: bookID)
            Divider()
            bottomBar
        }
        .frame(minWidth: 420, minHeight: 480)
        .onAppear { initializeDefaultsIfNeeded() }
    }

    /// シートなので、独立ウインドウだった頃はタイトルバーの閉じるボタンが担っていた「やめる」を
    /// ボタンとして置く必要がある。並び(キャンセル→既定ボタン)とショートカットの割り当ては、
    /// このアプリの他のダイアログ(FavoriteFolderPickerView.bottomBar等)と揃えてある。
    private var bottomBar: some View {
        HStack {
            Spacer()

            Button("Cancel") {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button("Apply") {
                applyRenaming(bookID: bookID, bookmarks: sortedBookmarks)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(sortedBookmarks.isEmpty && !assignFixedCover)
        }
        .padding()
    }

    private func initializeDefaultsIfNeeded() {
        guard !hasInitializedDefaults else { return }
        hasInitializedDefaults = true
        // 表示言語(preferences.effectiveLocale)に応じた既定値。既存のブックマーク既定名
        // (ViewerViewModel.addBookmarkの"Page N")と同じ考え方(設計コンセプト5節)。
        let isJapanese = preferences.effectiveLocale.identifier.hasPrefix("ja")
        prefix = isJapanese ? "第" : "Episode "
        suffix = isJapanese ? "話" : ""
    }

    @ViewBuilder
    private func content(for bookID: String) -> some View {
        let bookmarks = bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
        let displayName = URL(fileURLWithPath: bookID).deletingPathExtension().lastPathComponent

        Form {
            Section {
                Text(displayName)
                    .font(.headline)
            }

            Section {
                // ユーザー報告: 従来の文言・説明だと、既にブックマークされている先頭ページの
                // 名前だけを変える機能に見えてしまう。実際は先頭ページにブックマークが無くても
                // (強制的に)「表紙」という名前のブックマークを付与する機能のため、それが
                // 伝わる文言に変更した(実装(applyRenaming)自体は元から変更なし)。
                //
                // ユーザー要望: さらに、「先頭ページに固定で表紙を割り当てる」という文言だと、
                // まだ何をもって「表紙」とみなすのかが伝わりにくかった。実際にはこのトグルは
                // 「先頭ページをブックマークとして登録し、その名前を『表紙』にする」機能なので、
                // それがそのまま伝わる文言に変更した(こちらも実装は変更なし)。
                Toggle("Bookmark the First Page as the Cover", isOn: $assignFixedCover)

                Picker("Last Bookmark", selection: $lastBookmarkTreatment) {
                    ForEach(LastBookmarkTreatment.allCases) { treatment in
                        Text(treatment.titleKey).tag(treatment)
                    }
                }
            }

            // ユーザー要望: 「番号前の文字列」「連番開始番号」「番号後の文字列」の3項目が縦に
            // 別々のフィールドとして並んでいると直感的でない。実際にはこの3つはまとめて
            // 「第[1][2][3]…話」のような1つの命名テンプレートを表しているため、見た目も
            // それが伝わるよう「ボタン(前の文字列)+ 数字ボックス(開始番号)+ ボタン(後の文字列)」を
            // 隙間なく横に並べ、1つの連続したコントロールに見えるようにした
            // (prefix/suffixの編集自体はボタンを押して開くポップオーバーで行う。
            // prefixSuffixEditorPopoverのコメント参照)。
            //
            // バグ修正(ユーザー報告): 当初はButton(.buttonStyle(.bordered))+
            // TextField(.textFieldStyle(.roundedBorder))というmacOS標準の見た目の部品を
            // HStack(spacing: 0)で並べていたが、それでも間に隙間が見えてしまっていた。
            // これはmacOSの標準ベゼル(.bordered/.roundedBorder)がフォーカスリング用の余白を
            // 描画領域の内側に確保しており、その分だけ実際に塗られる見た目がレイアウト上の
            // 幅より小さくなるため(HStackのspacing自体は0でも、各部品の「見た目」の方が
            // 内側に痩せて見える)。この余白は公開APIで調整できないため、代わりに
            // .buttonStyle(.plain)/.textFieldStyle(.plain)を使い、背景・区切り線・外枠を
            // すべて自前で描画することで、隙間が原理的に生まれないようにした。
            // 左右のボタンは明るめの背景で「盛り上がって」見えるように、中央のボックスは
            // 暗めの背景と上端の細い影で「凹んで」見えるようにしている(要望どおりの見た目を維持)。
            Section("Sequential Rename Settings") {
                HStack(spacing: 0) {
                    Button {
                        isEditingPrefix = true
                    } label: {
                        Text(prefix)
                            .frame(minWidth: Self.prefixSuffixButtonWidth)
                            .frame(height: Self.segmentHeight)
                    }
                    .buttonStyle(.plain)
                    .background(Self.segmentRaisedBackground)
                    .help("Set the prefix string")
                    .popover(isPresented: $isEditingPrefix) {
                        prefixSuffixEditorPopover(title: "Text Before Number", text: $prefix)
                    }

                    Divider().frame(height: Self.segmentHeight)

                    // 開始番号は左右のボタンに挟まれた「凹んだ」見た目にしたい(要望)ため、
                    // .plainスタイルの上に自前の暗めの背景+上端の影を重ねて表現する
                    // (上のコメント参照)。
                    TextField("", value: $startNumber, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .frame(width: Self.startNumberFieldWidth)
                        .frame(height: Self.segmentHeight)
                        .background(Self.segmentSunkenBackground)
                        .help("Enter the starting number")

                    Divider().frame(height: Self.segmentHeight)

                    Button {
                        isEditingSuffix = true
                    } label: {
                        Text(suffix)
                            .frame(minWidth: Self.prefixSuffixButtonWidth)
                            .frame(height: Self.segmentHeight)
                    }
                    .buttonStyle(.plain)
                    .background(Self.segmentRaisedBackground)
                    .help("Set the suffix string")
                    .popover(isPresented: $isEditingSuffix) {
                        prefixSuffixEditorPopover(title: "Text After Number", text: $suffix)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.secondary.opacity(0.35), lineWidth: 1)
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 4)
            }

            if !bookmarks.isEmpty {
                // ユーザー報告: プレビューが先頭6件しか表示されず、ブックマークが多い本では
                // 大半が確認できなかった。Form(macOSではList相当でスクロール可能)の中に
                // そのままForEachで全件並べれば、件数が多くてもスクロールして全件確認できる
                // ため、6件への打ち切りをやめた。
                Section("Preview") {
                    // ユーザー要望: 矢印と、リネーム後の名前の左端が縦に揃うようにする。
                    // 変更前の名前の長さは行ごとにばらばらなので、いちばん長い名前の幅
                    // (上限あり)を実測して1列ぶんの幅に固定し、そこへ左寄せで置く。
                    let items = previewNames(bookID: bookID, bookmarks: bookmarks)
                    let originalColumnWidth = Self.previewOriginalColumnWidth(for: items.map(\.originalName))
                    ForEach(items, id: \.id) { item in
                        HStack(spacing: 6) {
                            Text(item.originalName)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: originalColumnWidth, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                                .font(.caption2)
                            Text(item.newName)
                                .lineLimit(1)
                        }
                        .font(.caption)
                    }
                }
            }

        }
        .formStyle(.grouped)
    }

    /// プレビューの「変更前の名前」列の幅。いちばん長い名前に合わせつつ、極端に長い名前が
    /// 1件あるだけでシートが横に広がらないよう上限を設ける(超えた名前は中略表示)。
    private static func previewOriginalColumnWidth(for names: [String]) -> CGFloat {
        let font = NSFont.preferredFont(forTextStyle: .caption1)
        let widest = names.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
        return min(220, max(80, widest.rounded(.up)))
    }

    /// 前後の文字列ボタンの幅。全角文字5文字ぶんを切り詰めずに表示できる余裕を持たせてある
    /// (ユーザー要望)。
    private static let prefixSuffixButtonWidth: CGFloat = 100
    /// 開始番号ボックスの幅。全角文字2文字ぶん程度(ユーザー要望)。
    private static let startNumberFieldWidth: CGFloat = 44
    /// 3つのセグメント(ボタン・ボックス・ボタン)共通の高さ。標準的なborderedボタンの見た目の
    /// 高さに合わせてある。
    private static let segmentHeight: CGFloat = 22

    /// 左右のボタン部分の背景(「盛り上がって」見えるように、上が明るく下がやや暗いグラデーション)。
    private static let segmentRaisedBackground = LinearGradient(
        colors: [Color(nsColor: .controlColor), Color(nsColor: .controlColor).opacity(0.85)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// 中央の開始番号ボックスの背景(「凹んで」見えるように、暗めの地に上端だけ薄い影を重ねる)。
    private static var segmentSunkenBackground: some View {
        ZStack {
            Color(nsColor: .controlColor).opacity(0.4)
            VStack(spacing: 0) {
                Color.black.opacity(0.18)
                    .frame(height: 1)
                Spacer(minLength: 0)
            }
        }
    }

    /// 前後の文字列ボタンをクリックしたときに開く、編集用のポップオーバー。
    /// 「小さなポップオーバー+テキストフィールド」という、この用途としては最も簡単な形にした
    /// (ボタンをまとめて1つのコントロールに見せるという今回のUI変更の主眼はプレビュー欄の
    /// 見た目にあり、編集操作自体はシートを開くほど大掛かりにする必要が無いため)。
    /// textはprefix/suffixへ直接Bindingしているため、入力するそばからプレビュー欄
    /// (previewNames)にも即座に反映される。
    @ViewBuilder
    private func prefixSuffixEditorPopover(title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)
                .onSubmit {
                    isEditingPrefix = false
                    isEditingSuffix = false
                }
            Button("Done") {
                isEditingPrefix = false
                isEditingSuffix = false
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(12)
    }

    private struct PreviewItem: Identifiable {
        let id: UUID
        let originalName: String
        let newName: String
    }

    /// 実際のApply処理と同じロジックで、プレビュー表示用の「旧名 → 新名」一覧を組み立てる。
    /// 表紙をまだ追加していない状態(assignFixedCover ON、かつ先頭ページにブックマークが
    /// 無い)の場合は、追加される表紙自体はまだ存在しないためプレビューには含めない。
    private func previewNames(bookID: String, bookmarks: [Bookmark]) -> [PreviewItem] {
        var excludedIDs: Set<UUID> = []
        var items: [PreviewItem] = []

        if assignFixedCover, let cover = bookmarks.first(where: { $0.pageIndex == 0 }) {
            // EPUB出力ウインドウの列見出し(EpubExportWindow.swift)で使っている"Cover"キーとは
            // 意図的に別のローカライズキーにしてある。あちらは「カバー画像」という列見出しの
            // 訳語(カバー画像)のままでよいが、ここで割り当てるのはブックマークの名前そのもの
            // (ユーザー要望: 「表紙」という名前を付けてほしい)のため、共用すると列見出しの
            // 訳語まで意図せず変わってしまう。
            let coverName = String(localized: "Cover Bookmark Name", locale: preferences.effectiveLocale)
            items.append(PreviewItem(id: cover.id, originalName: cover.name, newName: coverName))
            excludedIDs.insert(cover.id)
        }

        if let fixedNameKey = lastBookmarkTreatment.fixedNameKey, let last = bookmarks.last, !excludedIDs.contains(last.id) {
            let name = String(localized: fixedNameKey, locale: preferences.effectiveLocale)
            items.append(PreviewItem(id: last.id, originalName: last.name, newName: name))
            excludedIDs.insert(last.id)
        }

        var number = startNumber
        for bookmark in bookmarks where !excludedIDs.contains(bookmark.id) {
            items.append(PreviewItem(id: bookmark.id, originalName: bookmark.name, newName: "\(prefix)\(number)\(suffix)"))
            number += 1
        }

        // ソート比較のたびにbookmarksを線形探索すると要素数が多いほど二乗オーダーで重くなる
        // (テキストフィールドを1文字打つたびに再計算されるため無視できない)。
        // 事前にID -> pageIndexの辞書を1回だけ作り、比較はO(1)ルックアップにする(結果は従来と同一)。
        let pageIndexByID = Dictionary(uniqueKeysWithValues: bookmarks.map { ($0.id, $0.pageIndex) })
        return items.sorted { lhs, rhs in
            let lhsIndex = pageIndexByID[lhs.id] ?? 0
            let rhsIndex = pageIndexByID[rhs.id] ?? 0
            return lhsIndex < rhsIndex
        }
    }

    /// 実際にリネームを適用する(設計コンセプト5節)。
    ///
    /// 経緯(ユーザー報告): 他にも「一括で処理できるはずのSQLite書き込みを個別に行っている
    /// 箇所」がないか確認してほしい、との依頼を受けて見つかった箇所。以前はここで
    /// bookmarkStore.rename(_:to:)を対象ブックマーク数ぶんループで個別に呼んでおり、
    /// そのたびに同期save()+reload()+通知が走っていた(本によっては数百件になることも
    /// 珍しくない)。実際のリネームはpendingRenamesへ集計するだけにとどめ、最後に
    /// bookmarkStore.renameBookmarks(bookID:renames:)へまとめて渡すことで、この「一括
    /// リネーム」の実行1回につき保存・再フェッチ・通知を1回にまとめる。
    private func applyRenaming(bookID: String, bookmarks: [Bookmark]) {
        var sorted = bookmarks
        var excludedIDs: Set<UUID> = []
        var pendingRenames: [(bookmark: Bookmark, newName: String)] = []

        if assignFixedCover {
            // EPUB出力ウインドウの列見出し(EpubExportWindow.swift)で使っている"Cover"キーとは
            // 意図的に別のローカライズキーにしてある。あちらは「カバー画像」という列見出しの
            // 訳語(カバー画像)のままでよいが、ここで割り当てるのはブックマークの名前そのもの
            // (ユーザー要望: 「表紙」という名前を付けてほしい)のため、共用すると列見出しの
            // 訳語まで意図せず変わってしまう。
            let coverName = String(localized: "Cover Bookmark Name", locale: preferences.effectiveLocale)
            if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                pendingRenames.append((cover, coverName))
                excludedIDs.insert(cover.id)
            } else {
                // 先頭ページにブックマークが無い場合は自動で追加する(5節)。本を今開いているか
                // どうかに関わらず動作させる必要があるため、BookmarkStore.addBookmark(bookID:
                // pageIndex:name:)を直接呼ぶ(ViewerViewModel.addBookmarkは今開いている本にしか
                // 使えないため)。これは新規追加(リネームではない)1件だけなので、まとめる対象には
                // 含めない。
                // ユーザー要望: ここで作成するブックマークにもファイルノード識別子を記録したい
                // (BookmarkDetailPane.addBookmark(atPageIndex:)と同じ理由・同じ解決手段)。
                var fileNodeIdentifier: FileNodeIdentifier?
                if let url = layoutStore.resolvedURL(forBookID: bookID) {
                    let didAccess = url.startAccessingSecurityScopedResource()
                    fileNodeIdentifier = FileNodeIdentifier.current(for: url)
                    if didAccess { url.stopAccessingSecurityScopedResource() }
                }
                bookmarkStore.addBookmark(
                    bookID: bookID, pageIndex: 0, name: coverName, fileNodeIdentifier: fileNodeIdentifier
                )
                sorted = bookmarkStore.bookmarks(forBookID: bookID).sorted { $0.pageIndex < $1.pageIndex }
                if let cover = sorted.first(where: { $0.pageIndex == 0 }) {
                    excludedIDs.insert(cover.id)
                }
            }
        }

        if let fixedNameKey = lastBookmarkTreatment.fixedNameKey, let last = sorted.last, !excludedIDs.contains(last.id) {
            let name = String(localized: fixedNameKey, locale: preferences.effectiveLocale)
            pendingRenames.append((last, name))
            excludedIDs.insert(last.id)
        }

        var number = startNumber
        for bookmark in sorted where !excludedIDs.contains(bookmark.id) {
            pendingRenames.append((bookmark, "\(prefix)\(number)\(suffix)"))
            number += 1
        }

        bookmarkStore.renameBookmarks(bookID: bookID, renames: pendingRenames)
    }
}
