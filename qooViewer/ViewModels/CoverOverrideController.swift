import Combine
import Foundation
import SwiftUI

/// 「この本の表紙/カバーを何にするか」というユーザーの指定を扱う部品。
///
/// ■ 2つの別物を、同じ形で扱う(2026-09-11)
/// この部品が編集する対象は`Target`で決まる ―― EPUB/CBZ/PDFへ書き出す**カバー画像**か、
/// 棚に並ぶ**コレクション表紙**か。2つは別の列に保存され、片方を変えてももう片方は変わらない
/// (分けた理由はBookLayoutSettingsの型コメント)。選び方・表示名の出し方・既定の意味は
/// まったく同じなので、画面と手順はこの1つで賄い、**行き先だけ**を切り替える。
///
/// 元はBookExportViewModelの一部だった(EPUB/CBZ出力ウインドウのカバー列)。改善要望5で
/// コレクションが加わり、**本を開いていない画面**からも同じ選び方をしたくなったため、
/// 書き出しとは無関係な部分だけをここへ切り出してある:
///
/// - EPUB/CBZ書き出しウインドウのカバー列(ExportCoverCell、従来どおり)
/// - 「メタデータの編集」ウインドウのカバー列(§5.4)
/// - ウェルカム画面のメタデータ編集シート(§5.3)
///
/// 書き出し側に残したのは`BookExportViewModel.resolveCoverOverride`(BookLayoutSettingsを
/// Exporterの語彙へ詰め替えるところ)だけ。読み書きの相手はどちらもLayoutStoreなので、
/// この切り出しで「同じDBの行を2つの経路が別々に解釈する」形にはならない。
///
/// @MainActor: SwiftUIのView(@ObservedObject)から直接観測される。
@MainActor
final class CoverOverrideController: ObservableObject {
    /// この部品がどちらを編集するか。
    enum Target {
        /// EPUB/CBZ/PDFへ書き出すカバー画像(書き出しウインドウ、1冊書き出しシート)。
        case coverImage
        /// 棚・コレクションに出るコレクション表紙(「メタデータの編集」ウインドウ、
        /// ウェルカム画面のメタデータ編集シート)。
        case collectionCover
    }

    let target: Target
    private let layoutStore: LayoutStore
    private let preferences: AppPreferences

    /// bookIDから元ファイル/フォルダのURLを解決する手立て。呼び出し元ごとに手がかり
    /// (どのストアのブックマークを見るか)が違うため、閉包で受け取る
    /// (BookExportViewModel.resolveURL / MetadataEditorViewModelのそれぞれの列)。
    private let resolveURL: (String) -> URL?

    /// 「この本のカバーの見え方が変わった」ことだけを表す通し番号。**値そのものは誰も読まない。**
    ///
    /// カバーの指定(どの画像か / どこを残すか)はすべてDB(BookLayoutSettings)にあり、この
    /// コントローラは毎回そこから読む。LayoutStoreはこの種の変更で`objectWillChange`を
    /// 出さない(読み取りが頻繁なので、publishを「レイアウト情報を持つ本の集合が変わったとき」に
    /// 絞ってある。LayoutStore.refreshLayoutBookID参照)ため、**このコントローラを見ている画面が
    /// 描き直される契機が無かった。**
    ///
    /// ユーザー報告 2026-09-09: メタデータ編集シートでカバーの「切り取るときに残す位置」を
    /// 変えても、カバーもメニューのチェックマークも更新されない(閉じて開き直すと反映済み)。
    /// DBへの書き込みも読み戻しも成立していることは実測で確認済みで、古いのは表示だけだった。
    /// 当時のシートは`@State`のカウンタを自分で増やして描き直しを促していたが、`.contextMenu`の
    /// 中身は`@State`の変化だけでは組み直されないことがある ―― macOSのSwiftUIでは、メニュー系
    /// (MenuBarExtra・ToolbarItem・contextMenu)が`@State`の変化に追随しない事例が知られており、
    /// 回避策として案内されているのも「`@State`ではなく観測対象(ObservableObject)から描く」こと。
    /// そこで契機をこの`@Published`に一本化し、見る側は`@ObservedObject`で購読する。
    @Published private(set) var revision: UInt64 = 0

    /// カバーの見え方が変わったことを知らせる(このクラスの書き込み口と、外から届く
    /// `.layoutDataDidChange`の受け口が呼ぶ)。
    func noteCoverDidChange() {
        revision &+= 1
    }

    /// カバー列に表示する名前のキャッシュ(bookID -> 表示名)。上書き設定がある場合は
    /// BookLayoutSettingsに保存済みの値をそのまま使えるが、既定(先頭ページ)の場合は本を
    /// 読み込んで確認する必要があるため、非同期で解決してここへキャッシュする
    /// (refreshCoverName(forBookID:)参照)。
    @Published private(set) var resolvedCoverNames: [String: String] = [:]

    /// loadBook(forBookID:)でstartAccessingSecurityScopedResource()に成功したURLの集合。
    ///
    /// 読み込んだ本は、この後もカバー列の表示名の解決やカバーピッカーのサムネイル取得で
    /// 元のファイルを読み続けるため、loadBook()の中でアクセスを閉じることはできず、この
    /// インスタンスが生きている間ずっと開いたままにしておく必要がある。そのため対になる
    /// stopAccessingSecurityScopedResource()はdeinitで呼ぶ
    /// (BookLayoutEditorViewModel.securityScopedURLと同じ方針)。
    ///
    /// 以前は`_ = url.startAccessingSecurityScopedResource()`と開きっぱなしにしており、
    /// アクセス権がリークしていた。しかもBookLayoutEditorViewModel(1冊ごとに作り直される)と
    /// 違い、この持ち主(書き出しウインドウのViewModel)はウインドウを閉じてもアプリ終了まで
    /// 使い回されるうえ、loadBook()はカバー列のセルの.task(refreshCoverName)から行ごとに
    /// 呼ばれるため、一覧をスクロールして行が再表示されるたびに対象の本の数だけ
    /// 積み上がっていた。
    ///
    /// Set(URL単位で1回だけ開く)にしているのは、startAccessingSecurityScopedResourceが
    /// 参照カウント式のため。同じ本を何度読み込んでも開くのは1回だけにしておかないと、
    /// deinitでの1回のstopでは釣り合わない。
    private var securityScopedURLs: Set<URL> = []

    init(
        target: Target, layoutStore: LayoutStore, preferences: AppPreferences,
        resolveURL: @escaping (String) -> URL?
    ) {
        self.target = target
        self.layoutStore = layoutStore
        self.preferences = preferences
        self.resolveURL = resolveURL
    }

    deinit {
        // loadBook(forBookID:)で開いたセキュリティスコープ付きアクセスを閉じる
        // (securityScopedURLsのコメント参照)。
        for url in securityScopedURLs {
            url.stopAccessingSecurityScopedResource()
        }
    }

    // MARK: - カバーの表示名

    /// カバー列の表示文字列。まだ解決できていない間は読み込み中であることが分かる文字列を返す。
    func coverDisplayName(forBookID bookID: String) -> String {
        resolvedCoverNames[bookID] ?? String(localized: "Loading…", language: preferences.effectiveLocale)
    }

    /// この本のカバー表示名を最新化する。呼び出し元(カバー列のセル)の.taskから、行の表示中に
    /// 一度だけ呼ぶ想定(BookmarkListView.PageRowViewのサムネイル読み込みと同じ考え方)。
    func refreshCoverName(forBookID bookID: String) async {
        guard let settings = layoutStore.bookLayoutSettings(forBookID: bookID) else {
            await resolveDefaultCoverName(forBookID: bookID)
            return
        }
        switch target {
        case .coverImage:
            if let externalName = settings.externalCoverFileName {
                resolvedCoverNames[bookID] = externalName
                return
            }
            if settings.coverPageKey != nil, let cached = settings.coverPageDisplayName {
                resolvedCoverNames[bookID] = cached
                return
            }
        case .collectionCover:
            // 画像指定の表紙は、元の画像をアプリの中へ複製してある(名前はこちらが振ったUUID)。
            // 利用者に見せるのはその機械的な名前ではなく、「画像を指定している」という事実
            // ―― 元のファイル名は複製した時点の名前でしかなく、指し示す先はもう無いかも
            // しれない(それがそもそも分離した理由。BookLayoutSettingsの型コメント参照)。
            if settings.shelfCoverImageFileName != nil {
                resolvedCoverNames[bookID] = String(
                    localized: "Selected Image", language: preferences.effectiveLocale
                )
                return
            }
            if settings.shelfCoverPageKey != nil, let cached = settings.shelfCoverPageDisplayName {
                resolvedCoverNames[bookID] = cached
                return
            }
        }
        await resolveDefaultCoverName(forBookID: bookID)
    }

    /// 既定(上書き無し)の場合のカバー名。実際に書き出したときと同じロジック
    /// (EffectivePageOrder)で実質的な先頭ページを求める。
    ///
    /// ユーザー報告と同じ構図の改善: 以前はここで必ずBookLoader.load(from:)を呼んでいた。
    /// 欲しいのは「実質的な先頭ページのファイル名」1つだけなのに、そのために書庫を全走査して
    /// いたことになる。しかもこれは一覧のカバー列のセルごと(=対象の本の数だけ)呼ばれるため、
    /// 本体が未接続の外付け/ネットワークボリューム上にあるとウインドウを開くだけで延々と
    /// 読み込みが続いていた。
    ///
    /// 並べ替え(pageOrderOverride)と除外(excluded)はDBから引けるので、必要な本体側の情報は
    /// ページの並び順とファイル名だけ。まずキャッシュ(BookPageListCache)を見て、あればそれで
    /// 済ませる。無い場合だけ従来どおり読み込む(その読み込み自体がBookLoader.load経由で
    /// キャッシュを埋めるため、次回以降は読み込み無しで解決できる)。
    private func resolveDefaultCoverName(forBookID bookID: String) async {
        let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
        let excludedKeys = Set(
            layoutStore.pageOverrides(forBookID: bookID).filter { $0.state == .excluded }.map(\.pageKey)
        )

        if let cached = await BookPageListCache.shared.pageList(forBookID: bookID), !cached.pages.isEmpty {
            // キャッシュのEntryはpageOrderSourceを持たないため、本体を読まずに分かる情報
            // (bookID=パスの拡張子)から判定する。PDF/EPUBはファイル自身が持つページ順
            // (.document)なので名前順に並べ替えてはいけない(MangaBook.pageOrderSource参照。
            // 現状はPDF/EPUBのsortKeyがゼロ埋め連番(%06d)のため並べ替えても偶然同じ順に
            // なるが、その偶然に依存しないための明示)。
            let pageOrderSource: PageOrderSource =
                (isPDFFile(bookID) || isEpubFile(bookID)) ? .document : .fileName
            let ordered = EffectivePageOrder.orderedPages(
                for: cached.pages, pageOrderSource: pageOrderSource,
                pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
            )
            if let first = ordered.first {
                // 書庫の中のフォルダ・入れ子の書庫の中にある画像は、ファイル名だけでは
                // どのページか区別できないため、本の直下からの相対パスで表示する
                // (PageLocation参照)。folderPathを持たない古いキャッシュではnilになり、
                // 従来どおりファイル名だけになる。
                //
                // EPUBをここでも改めて弾いているのは、**この経路だけが本体を読み直さない**ため。
                // EPUBのfolderPathを残していた頃のキャッシュが手元にあると、その本を開き直す
                // まで`OEBPS/Images/001.jpg`のままになってしまう。
                let folderPath = isEpubFile(bookID) ? nil : first.folderPath
                resolvedCoverNames[bookID] = folderPath.map { "\($0)/\(first.displayName)" }
                    ?? first.displayName
                return
            }
        }

        guard let book = await loadBook(forBookID: bookID) else { return }
        let ordered = EffectivePageOrder.orderedPages(
            for: book, pageOrderOverride: settings?.pageOrderOverride, excludedKeys: excludedKeys
        )
        guard let first = ordered.first else { return }
        resolvedCoverNames[bookID] = first.location(inBookAt: book.sourceURL).fullPath
    }

    // MARK: - 本の読み込み

    /// カバーピッカー(本のページ一覧を表示する画面)から呼ばれる。この本を読み込んで返す
    /// (セキュリティスコープ付きアクセスはBookLayoutEditorViewModel.loadと同じく、ウインドウが
    /// 開いている間ずっとサムネイルを読み込めるよう、明示的に閉じずに保持したままにし、
    /// deinitでまとめて閉じる。securityScopedURLsのコメント参照)。
    func loadBookForCoverPicker(bookID: String) async -> MangaBook? {
        await loadBook(forBookID: bookID)
    }

    private func loadBook(forBookID bookID: String) async -> MangaBook? {
        guard let url = resolveURL(bookID) else { return nil }
        // 同じ本を何度読み込んでも、開くのは最初の1回だけにする(securityScopedURLsのコメント参照)。
        if !securityScopedURLs.contains(url), url.startAccessingSecurityScopedResource() {
            securityScopedURLs.insert(url)
        }
        return try? await BookLoader.load(from: url)
    }

    // MARK: - カバーの指定

    /// 本に含まれる既存ページをカバーに指定する。
    func setCover(forBookID bookID: String, book: MangaBook, page: PageRef) {
        // 表示名は、書庫の中のフォルダ・入れ子の書庫まで含めた本の中での相対パスで持つ
        // (ファイル名だけでは、章ごとに001.jpgから振り直されている本でどのページを
        // カバーにしたのか分からないため。PageLocation参照)。
        let coverName = page.location(inBookAt: book.sourceURL).fullPath
        switch target {
        case .coverImage:
            layoutStore.setCoverPageKey(for: book, pageKey: page.sortKey, displayName: coverName)
        case .collectionCover:
            layoutStore.setShelfCoverPageKey(
                forBookID: bookID, sourceURL: book.sourceURL,
                pageKey: page.sortKey, displayName: coverName
            )
        }
        resolvedCoverNames[bookID] = coverName
        noteCoverDidChange()
    }

    /// 本に含まれない画像ファイルを指定する。行き先で扱いが違う:
    /// - `.coverImage`: そのファイルへのブックマークを持つ(従来どおり。書き出しのたびに
    ///   元ファイルを読み直すので、原寸のまま書き出せる)
    /// - `.collectionCover`: **画像をアプリの中へ複製する**(元ファイルがどうなっても表紙は
    ///   壊れない。CollectionCoverSourceStoreの型コメント参照)
    ///
    /// どちらの場合も、指定した画像は本の一部としては扱わない(ビューアのページ一覧には
    /// 現れない)。
    ///
    /// 本を読み込まずに呼べる(メタデータ編集シートへの画像のドロップ)。行がまだ無い本のために
    /// 元ファイルのURLを一緒に渡すが、解決できなくても指定自体は成立する
    /// (LayoutStore.existingOrNewSettings(forBookID:sourceURL:)参照)。
    func setCoverFile(forBookID bookID: String, fileURL: URL) async {
        switch target {
        case .coverImage:
            guard (try? layoutStore.setExternalCover(
                forBookID: bookID, sourceURL: resolveURL(bookID), fileURL: fileURL
            )) != nil else { return }
            resolvedCoverNames[bookID] = fileURL.lastPathComponent
        case .collectionCover:
            // 表紙は画像をアプリの中へ複製する(元ファイルが消えても壊れないようにするため。
            // CollectionCoverSourceStoreの型コメント参照)。画像として読めなければ何もしない。
            guard (try? await layoutStore.setShelfCoverImage(
                forBookID: bookID, sourceURL: resolveURL(bookID), fileURL: fileURL
            )) != nil else { return }
            resolvedCoverNames[bookID] = String(
                localized: "Selected Image", language: preferences.effectiveLocale
            )
        }
        noteCoverDidChange()
    }

    /// カバーの上書きを解除し、既定(先頭ページ)に戻す。
    ///
    /// カバーの切り出し位置(setCropAnchor)はここでは消さない ―― あちらは「どの画像か」ではなく
    /// 「その画像のどこを見せるか」という本の属性で、カバーを既定に戻しても意味を失わない
    /// (LayoutStore.setCoverCropAnchorのコメント参照)。
    func resetCover(forBookID bookID: String) {
        switch target {
        case .coverImage: layoutStore.clearCoverOverride(forBookID: bookID)
        case .collectionCover: layoutStore.clearShelfCover(forBookID: bookID)
        }
        resolvedCoverNames.removeValue(forKey: bookID)
        noteCoverDidChange()
        Task { await refreshCoverName(forBookID: bookID) }
    }

    /// いまカバーに指定されている本の中のページ(未指定・外部ファイル指定ならnil)。
    /// ページを選ぶ画面が「いまどれが選ばれているか」を出すために読む。
    func coverPageKey(forBookID bookID: String) -> String? {
        let settings = layoutStore.bookLayoutSettings(forBookID: bookID)
        switch target {
        case .coverImage: return settings?.coverPageKey
        case .collectionCover: return settings?.shelfCoverPageKey
        }
    }

    // MARK: - カバーの切り出し位置(コレクションのグリッド表示にだけ効く)

    /// 本ごとの切り出し位置の上書き(nil = そのライブラリの設定に従う)。
    func cropAnchor(forBookID bookID: String) -> CoverCropAnchor? {
        layoutStore.bookLayoutSettings(forBookID: bookID)?.coverCropAnchor
    }

    func setCropAnchor(forBookID bookID: String, _ anchor: CoverCropAnchor?) {
        layoutStore.setCoverCropAnchor(
            forBookID: bookID, sourceURL: resolveURL(bookID), anchor: anchor
        )
        noteCoverDidChange()
    }
}
