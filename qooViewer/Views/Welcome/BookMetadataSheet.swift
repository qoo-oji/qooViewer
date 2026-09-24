import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// コレクションの中から1冊ぶんのメタデータとカバー画像を編集するシート(改善要望5 §5.3)。
///
/// 「メタデータの編集」ウインドウと**同じDBの同じ行**を書く。違いは2つだけ:
///
/// - この画面は本のURLを持てている(コレクションのブックマークから解決済み)ので、登録の際に
///   セキュリティスコープ付きブックマークとinodeも一緒に保存できる(ウインドウ版はファイルを
///   開いていないため`sourceURL: nil`で登録するしかない)。
/// - カバーを1枚の画像として大きく出し、そこへ直接画像ファイルを落とせる。
///
/// **カバーの操作はメタデータの4欄とは独立に即時保存される**(書き出しウインドウのカバー列と
/// 同じ挙動)。Cancelで戻るのは4欄の入力だけで、カバーの変更は取り消されない ―― カバーの変更は
/// その場でコレクションのタイルへ反映されるものなので、シートを閉じるまで確定しない作りに
/// すると「変わったのに戻った」と見えてしまう。
///
/// ■ ファイルブラウザから開く版(改善要望7 段階 8、2026-09-14)
/// ファイルブラウザの右クリックからは、コレクションに入っていない本も編集できる(`init(fileBrowserEntry:)`)。
/// 4欄の初期値と登録先は同じ(DBの行はパスで引く)。
///
/// カバーの面も出す(2026-09-14、ユーザー要望。段階 8 では出していなかった):
/// - その本がどこかのコレクションに入っていれば、その行とライブラリで**コレクションから開いたときと同じ面**
/// - 入っていなければ、ライブラリの比が無いので**切らずに**出す(`FileBrowserCoverArea`)。絵はアイコン表示と同じ提供役
///   (FileBrowserThumbnailProvider)から引く ―― 指定したコレクション表紙がアイコン表示にもそのまま出る。
///   表紙は切らないが、右クリックの「切り取るときに残す位置」は出す(2026-09-23 から。本ごとの指定はライブラリとスマートライブラリで
///   共有で、どちらかに並べたときに効く。`coverCropAnchorMenuItems`)
/// 指定の保存先はどちらも同じ(BookLayoutSettings の shelfCover* の列。本ごと)なので、後からコレクションに入れると
/// 指定した表紙で抽出される。
///
/// ■ スマートライブラリから開く版(2026-09-23、利用者の要望)
/// スマートライブラリの右クリックからは `fromSmartLibrary: true` で開く。コレクションに入っている本でも、表紙の面は
/// **スマートライブラリに並んでいるとおり**(環境設定「スマートライブラリ」のカバーの形・切り取るときに残す位置)に出し、
/// 右クリックの「切り取るときに残す位置」で選んだ所がすぐに見える。本ごとの指定の列(BookLayoutSettings.coverCropAnchor)は
/// ライブラリと共有なので、ここで選べばコレクションの表紙も同じ所を残す(「設定なし」ならそれぞれの設定に従う)。
///
/// シートの中身はmacOSが不透明に描くので、すりガラス面の輪郭は要らない(CLAUDE.md参照)。
struct BookMetadataSheet: View {
    /// 対象の本(コレクションの行)のid。カバーの状態(抽出済みか・横長を切ったか)も行から読む。
    ///
    /// **モデルの参照ではなくidで受ける**(監査で指摘 2026-09-09)。シートを出している間に
    /// 別のウインドウがその本をコレクションから外してsaveすると、`CollectionItem`本体を
    /// 持ったままでは次の描き直しで消えた行の属性を読んで落ちる(SwiftDataの
    /// "model instance was invalidated")。毎回ストアから引き直し、無くなっていたら閉じる。
    ///
    /// nil は URL だけで開いた版(型コメント)。
    let itemID: UUID?
    /// 本の実体。呼び出し側が`CollectionStore.resolvedExistingURL`で解決してから渡す
    /// (解決できない本ではシートを出さず「本が見つかりません」のアラートにする)。
    let sourceURL: URL
    /// この本が入っているライブラリ。カバーのプレビューをそのライブラリの縦横比で描き、
    /// 「残す位置」の既定(=ライブラリの設定)を示すために要る。ファイルブラウザから開いた版では nil。
    let library: BookLibrary?
    /// ファイルブラウザから開いた版の項目(型コメント)。コレクションから開いた版では nil。
    let fileBrowserEntry: FileBrowserEntry?
    /// スマートライブラリから開いた版か(型コメント「スマートライブラリから開く版」)。
    let fromSmartLibrary: Bool

    init(itemID: UUID, sourceURL: URL, library: BookLibrary) {
        self.itemID = itemID
        self.sourceURL = sourceURL
        self.library = library
        fileBrowserEntry = nil
        fromSmartLibrary = false
    }

    /// ファイルブラウザ・スマートライブラリの右クリック。コレクションの外の本でも開ける(型コメント)。
    init(fileBrowserEntry entry: FileBrowserEntry, fromSmartLibrary: Bool = false) {
        itemID = nil
        sourceURL = entry.url
        library = nil
        fileBrowserEntry = entry
        self.fromSmartLibrary = fromSmartLibrary
    }

    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(MetadataRulesStore.self) private var rulesStore
    @EnvironmentObject private var layoutStore: LayoutStore
    @EnvironmentObject private var collectionStore: CollectionStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss

    /// 編集中の欄。「メタデータの編集」ウインドウと同じ初期値の決め方
    /// (登録済みならDBの値、未登録ならファイル名を qooMeta で読んだ提案)。2026-09-21 から qooMeta の欄
    /// (複数の著者・ジャンル・イベント・原作・情報)も持つ。
    @State private var draft = BookMetadataValues()
    /// 著者の欄の文字(「、」で区切って複数。qooMeta の一覧のセルと同じ書き方)。
    @State private var authorsText = ""
    /// 開いたときの巻の表記(手で変えたら、qooMeta が導いた並べ替え用の数を捨てる)。
    @State private var openedVolume = ""
    /// 巻数(並べ替え用)の欄の文字と、開いたときのその文字(2026-09-22、利用者の要望でシートでも直せるようにした)。
    @State private var volumeSortText = ""
    @State private var openedVolumeSortText = ""
    /// 開いたときの値(変えた欄だけを「直した欄」にする)。
    @State private var openedValues = BookMetadataValues()
    /// ロックしている本か(欄を変えさせない。利用者の指示 2026-09-22「ロックされたら DB を変更不可」)。
    @State private var isLocked = false
    /// 開いたときにロックしていたか。シートの鍵のボタンは `isLocked` だけを変え、「保存」で DB へ書く(「キャンセル」なら
    /// 変わらない。2026-09-22、利用者の要望でシートからもロック・解除できるようにした)。
    @State private var openedIsLocked = false
    /// カバーの指定。環境オブジェクトが要るのでinitでは作れず、onAppearで組み立てる
    /// (MetadataEditorWindowが@StateのViewModelを組み立てるのと同じ形)。
    @State private var coverController: CoverOverrideController?

    /// カバーの表示幅。高さはライブラリの縦横比から決まる(2:3なら1.5倍、1:1なら等倍)。
    /// 右の4欄+説明とだいたい同じ高さになる値にしてある ―― どちらかが極端に長いと、
    /// 短いほうの下に用の無い余白が残る。
    private static let coverWidth: CGFloat = 130

    /// 対象の行。別のウインドウが外していればnil(itemIDのコメント参照)。
    private var item: CollectionItem? {
        itemID.flatMap { collectionStore.item(withID: $0) }
    }

    var body: some View {
        if itemID == nil {
            // ファイルブラウザから開いた版。DBの行はパス(= BookLoader が付ける本の id)で引く。コレクションに入っている本なら、
            // その行とライブラリでカバーの面を出す(型コメント)。
            let bookID = sourceURL.path
            // ライブラリ機能がOFFの間はコレクションの行を引かず(全件フェッチを伴う)、入っていない本と同じ面を出す。
            // スマートライブラリから開いた版も引かない(スマートライブラリに並ぶとおりの面を出す。型コメント)。
            let registered = !preferences.libraryFeatureEnabled || fromSmartLibrary ? nil
                : collectionStore.items(forBookID: bookID).lazy
                    .compactMap { item in item.collection?.library.map { (item, $0) } }
                    .first
            content(
                bookID: bookID, title: MetadataRulesStore.baseName(forBookID: bookID),
                item: registered?.0, library: registered?.1
            )
        } else if let item {
            content(bookID: item.bookID, title: item.title, item: item, library: library)
        } else {
            // 出している間に外された(itemIDのコメント参照)。何も描かずに閉じる。
            Color.clear
                .frame(width: 460, height: 120)
                .onAppear { dismiss() }
        }
    }

    /// - Parameters:
    ///   - item / library: コレクションの行とそのライブラリ。nil なら、ファイルブラウザから開いた版は切らないカバーの面を出す。
    private func content(bookID: String, title: String, item: CollectionItem?, library: BookLibrary?) -> some View {
        // **幅はボタンではなくラベルに与える。** `Button(...).frame(width:)`では、与えた幅は
        // レイアウト上の枠にしか効かず、実際に描かれるベゼルは文字列の長さのまま枠の中央に
        // 置かれる(実測。WelcomeTopBarの同じコメント参照)。ラベル側を同じ幅にすれば、
        // ベゼルもその幅+左右のインセットで揃う。余白(chrome)を0にしているのはそのため。
        let labelWidth = MetadataButtonWidthEstimator.equalWidth(
            for: [
                String(localized: "Cancel", language: locale),
                String(localized: "Save", language: locale),
            ],
            minWidth: 60,
            chrome: 0
        )
        return VStack(alignment: .leading, spacing: 14) {
            // どの本を編集しているのかは、この画面のどこにも出ていなかった ―― コレクションの
            // 一覧はカバーだけを並べていて名前を出さないので、右クリックで開いた先にも
            // 名前が無いと対象を取り違える。
            VStack(alignment: .leading, spacing: 2) {
                Text("Edit Metadata")
                    .font(.headline)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(title)
            }

            Divider()

            if let item, let library {
                HStack(alignment: .top, spacing: 16) {
                    cover(for: item, in: library)
                    VStack(alignment: .leading, spacing: 10) {
                        fields
                        Text("Drop an image file on the cover, or right-click it to choose a page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else if let fileBrowserEntry {
                HStack(alignment: .top, spacing: 16) {
                    if let coverController {
                        FileBrowserCoverArea(
                            controller: coverController, entry: fileBrowserEntry, bookID: bookID,
                            width: Self.coverWidth, locale: locale,
                            smartLibraryCrop: fromSmartLibrary
                                ? .init(shape: preferences.smartLibraryCoverShape,
                                        fit: preferences.smartLibraryCoverFit,
                                        defaultAnchor: preferences.smartLibraryCoverCropAnchor)
                                : nil
                        )
                    } else {
                        Color.clear.frame(
                            width: Self.coverWidth,
                            height: Self.coverWidth * (fromSmartLibrary ? preferences.smartLibraryCoverShape.heightRatio
                                                                        : FileBrowserCoverArea.heightRatio)
                        )
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fields
                        Text("Drop an image file on the cover, or right-click it to choose a page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                fields
            }

            HStack(spacing: 12) {
                if rulesStore.isExcluded(bookID: bookID) {
                    Label("This book is in a folder excluded from metadata registration.", systemImage: "folder.badge.minus")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // 鍵(メタデータの編集ウインドウの鍵の列と同じ意味)。押しただけでは書かず、「保存」で書く。
                    Button { isLocked.toggle() } label: {
                        Label(isLocked ? "Unlock" : "Lock", systemImage: isLocked ? "lock.fill" : "lock.open")
                    }
                    .disabled(!isLocked && !canLock)
                    .help(isLocked ? "Locked: the fields can’t be changed. Unlock to edit them. The change is saved with Save".ui
                          : canLock ? "Lock the values in the fields. The change is saved with Save".ui
                          : "There is nothing to lock".ui)
                }
                Spacer(minLength: 0)
                Button(role: .cancel) { dismiss() } label: {
                    Text("Cancel").frame(width: labelWidth)
                }
                .keyboardShortcut(.cancelAction)
                Button { register(bookID: bookID) } label: {
                    Text("Save").frame(width: labelWidth)
                }
                .keyboardShortcut(.defaultAction)
                // ロックしたままの本は変えない(メタデータの編集ウインドウの鍵。2026-09-21)。鍵を掛け外ししたときは押せる。
                .disabled(rulesStore.isExcluded(bookID: bookID) || (isLocked && openedIsLocked) || isVolumeSortInvalid)
            }
        }
        .padding(20)
        .frame(width: 460)
        // 別のウインドウ(「メタデータの編集」ウインドウ・書き出しウインドウ)から同じ本の
        // カバーを変えられたときも追いつく。契機はコントローラの`revision`に一本化してある
        // (CoverOverrideController.revisionのコメント参照)。
        .onReceive(NotificationCenter.default.publisher(for: .layoutDataDidChange)) { _ in
            coverController?.noteCoverDidChange()
        }
        .onAppear {
            // 登録済みならDBの値、未登録なら qooMeta で 1 冊だけ読んだ提案(同じ書き手のほかの本とは見比べないので、
            // 番号の無いシリーズは見つからない。一覧の窓なら見つかる)。
            let row = metadataStore.metadata(forBookID: bookID)
            draft = row?.values
                ?? BookMetadataValues(MetadataRulesStore.singleProposal(forBookID: bookID, rules: rulesStore.rules))
            openedValues = draft
            isLocked = row?.isLocked == true
            openedIsLocked = isLocked
            authorsText = draft.authors.joined(separator: "、")
            openedVolume = draft.volume
            volumeSortText = draft.volumeSort.map(MetadataWorkspace.volumeSortText) ?? ""
            openedVolumeSortText = volumeSortText
            // カバーの面を出さない版では、カバーの指定の口も作らない。
            guard item != nil || fileBrowserEntry != nil, coverController == nil else { return }
            coverController = CoverOverrideController(
                target: .collectionCover, layoutStore: layoutStore, preferences: preferences,
                // この画面は対象の本を1冊しか扱わないので、URLの解決は済んだものを返すだけ。
                resolveURL: { _ in sourceURL }
            )
        }
    }

    // MARK: - メタデータの欄

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
            // 欄そのものにラベルは持たせない(左の見出しが名前になる)。読み上げのために
            // アクセシビリティ用の名前だけ同じ文字列で与える。
            row("Title", text: $draft.title)
            GridRow {
                Text("Authors")
                    .gridColumnAlignment(.trailing)
                TextField("", text: $authorsText, prompt: Text("Separate several authors with 、"))
                    .accessibilityLabel(Text("Authors"))
            }
            row("Genre", text: $draft.genre)
            row("Source work", text: $draft.source)
            row("Event", text: $draft.event)
            row("Info", text: $draft.info)
            row("Series", text: $draft.series)
            // 巻はシリーズの中の番号なので、シリーズ名の無い間は入れさせない(メタデータの編集ウインドウの列と同じ。
            // 利用者の指示 2026-09-22: シリーズの無い本の巻は概念としておかしい)。以前に登録した「シリーズの無い巻」は、
            // シリーズを空にしない限り消さずに残す。
            GridRow {
                Text("Volume")
                    .gridColumnAlignment(.trailing)
                TextField("", text: $draft.volume)
                    .accessibilityLabel(Text("Volume"))
                    .disabled(!hasSeries)
                    .help(hasSeries ? "" : "Give the book a series name first".ui)
            }
            // 巻数(並べ替え用)は、シリーズ名のある本だけ(メタデータの編集ウインドウの列と同じ条件。巻の表記は空でもよい)。
            // 空にすると、巻の表記から読んだ数に戻る。
            GridRow {
                Text("Volume (for sorting)")
                    .gridColumnAlignment(.trailing)
                TextField("", text: $volumeSortText, prompt: Text(verbatim: "1.5"))
                    .accessibilityLabel(Text("Volume (for sorting)"))
                    .disabled(!canEditVolumeSort)
                    .help(canEditVolumeSort ? "Empty goes back to the number read from the volume".ui
                          : "Give the book a series name first".ui)
            }
            if isVolumeSortInvalid {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    Text("Enter a number for the volume for sorting.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .textFieldStyle(.roundedBorder)
        .disabled(isLocked)
    }

    /// 鍵を掛けられるか(全欄が空なら行を作れないので掛けられない ―― `BookMetadataStore.applyUpsert`。メタデータの編集
    /// ウインドウの `setLocked` と同じ)。
    private var canLock: Bool {
        var values = draft
        values.authors = authorsText.split(whereSeparator: { "、,，".contains($0) }).map(String.init)
        return !values.trimmed.isEmpty && !isVolumeSortInvalid
    }

    private var hasSeries: Bool { !draft.series.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 巻数(並べ替え用)はシリーズの中の位置なので、シリーズ名のある本だけ(巻数(表示)は空でもよい)。
    private var canEditVolumeSort: Bool { hasSeries }

    /// 直した巻数(並べ替え用)が数に読めない(保存させない)。
    private var isVolumeSortInvalid: Bool {
        canEditVolumeSort && volumeSortText != openedVolumeSortText
            && !volumeSortText.trimmingCharacters(in: .whitespaces).isEmpty
            && MetadataWorkspace.volumeSortNumber(volumeSortText) == nil
    }

    private func row(_ label: LocalizedStringKey, text: Binding<String>) -> some View {
        GridRow {
            Text(label)
                .gridColumnAlignment(.trailing)
            TextField("", text: text)
                .accessibilityLabel(Text(label))
        }
    }

    // MARK: - カバー画像

    /// カバーの絵と、その右クリックメニュー。
    ///
    /// **コントローラができるまでは出さない。** カバーの指定を読み書きする口がすべて
    /// コントローラにあるため、無い状態で描いても「未指定」としか出せず、しかもその状態で
    /// 組まれたメニューがそのまま残ることがある(下のCoverAreaのコメント参照)。
    @ViewBuilder
    private func cover(for item: CollectionItem, in library: BookLibrary) -> some View {
        if let coverController {
            CoverArea(
                controller: coverController, item: item, library: library,
                width: Self.coverWidth,
                coverStore: collectionStore.coverStore, locale: locale
            )
        } else {
            // 高さを合わせるためだけの場所取り(一瞬で入れ替わる)。
            Color.clear
                .frame(width: Self.coverWidth, height: Self.coverWidth / library.coverAspectRatio.value)
        }
    }

    // MARK: - 保存

    /// 欄を DB へ書く。**変えた欄だけを「直した欄」にする**(ほかの欄はファイル名の読みに付いていく。メタデータの編集
    /// ウインドウで直したときと同じ。利用者の指示 2026-09-22)。行が無ければロックせずに作る。
    /// 鍵: 掛けたら欄の値をすべて確定してロックする。外したら、ファイル名の読みと違う欄だけを直した欄にする(ウインドウの
    /// `MetadataWorkspace.unlock` と同じ考え。ただしこのシートは 1 冊だけを読むので、ほかの本を錨にしたシリーズは見つからず、
    /// そのシリーズ名は直した欄に残る)。
    /// すべての欄が空のまま押すと、既存仕様どおり行そのものを消す。
    private func register(bookID: String) {
        let storedLocked = metadataStore.metadata(forBookID: bookID)?.isLocked == true
        // 開いたあとにほかの画面で鍵が変わっていたら書かない(その画面の操作を上書きしない)。
        guard storedLocked == openedIsLocked else { return dismiss() }
        guard !(storedLocked && isLocked) else { return dismiss() }
        var values = draft
        values.authors = authorsText.split(whereSeparator: { "、,，".contains($0) }).map(String.init)
        // シリーズ名を空にしたら、巻も外す(シリーズの無い巻は持たせない。欄は入れられなくなっているが値は残っているので)。
        // シリーズ名を別の名前に変えたら、巻は新しいシリーズ名で読み直す(巻はシリーズの中の番号。2026-09-22、利用者の指示。
        // 表記だけを直したときは残す ―― `MetadataWorkspace.sameSeriesName`)。同じ保存で巻も入れ直していたら、入れた巻を使う。
        // 読み直しはメタデータ生成が行う(直した欄の巻の確定を外す。下の `reproposingVolume`)。
        let newSeries = values.series.trimmingCharacters(in: .whitespaces)
        let oldSeries = openedValues.series.trimmingCharacters(in: .whitespaces)
        let reproposesVolume = !newSeries.isEmpty && !oldSeries.isEmpty
            && !MetadataWorkspace.sameSeriesName(newSeries, oldSeries)
            && values.volume.trimmingCharacters(in: .whitespaces) == openedVolume
            && volumeSortText == openedVolumeSortText
        // 巻数(並べ替え用)を手で変えたら、その数(空なら無し ―― 表記から数として読み直される)。変えずに巻の表記だけを
        // 変えたら、qooMeta が導いた並べ替え用の数は捨てる(表記と食い違った数を残さない)。
        if volumeSortText != openedVolumeSortText, canEditVolumeSort {
            values.volumeSort = MetadataWorkspace.volumeSortNumber(volumeSortText)
        } else if values.volume.trimmingCharacters(in: .whitespaces) != openedVolume {
            values.volumeSort = nil
        }
        values = values.trimmed
        let current = metadataStore.metadata(forBookID: bookID)?.rowState ?? BookMetadataRowState(isLocked: false)
        var state = current
        var narrowsEditsAfterUnlock = false
        if isLocked {
            // 掛ける: 値そのものが確定する(ロックした行は直した欄を持たない)。
            state = BookMetadataRowState(isLocked: true, ruleSet: current.ruleSet)
        } else if storedLocked {
            // 外す: まず全部の欄を直した欄にして値を変えず、メタデータ生成の読み(ほかの本と見比べた読み)と同じ欄だけを後で外す
            // (`narrowEditsAfterUnlock`。メタデータの編集ウインドウの `unlock` と同じ)。2026-09-23 の 3 回目の監査の低: 以前は
            // この本だけを読んだ値と比べていたので、シリーズや巻数(並べ替え用)のように見比べで決まる欄が「読みと同じ」として外れ、
            // 生成がすぐ見比べた読みで書き直した ―― 鍵を外しただけで値が変わった。
            state = MetadataWorkspace.unlockedStateKeepingValues(values, ruleSet: current.ruleSet)
            narrowsEditsAfterUnlock = true
        } else {
            state.edits = MetadataParsing.edits(changing: openedValues.trimmed, to: values, in: current.edits)
        }
        if reproposesVolume, !state.isLocked {
            state.edits = MetadataParsing.reproposingVolume(state.edits)
            // 書く値の巻は、この本だけを読んだ提案で埋めておく(ほかの本と見比べた読みは、メタデータ生成がすぐ書き直す)。
            let proposed = MetadataParsing.values(forBookID: bookID, edits: state.edits, ruleSet: state.ruleSet,
                                                  rules: rulesStore.rules)
            values.volume = proposed.volume
            values.volumeSort = proposed.volumeSort
            values = values.trimmed
        }
        // ウインドウ版と違い、この画面は本のURLを持てている(ブックマークとinodeも入る)。
        metadataStore.upsertAll([BookMetadataStore.BatchEntry(bookID: bookID, values: values, sourceURL: sourceURL,
                                                              state: state)])
        if narrowsEditsAfterUnlock {
            MetadataWorkspace.narrowEditsAfterUnlock(bookID: bookID, values: values, written: state, store: metadataStore)
        }
        dismiss()
    }
}

/// カバーの絵と、その右クリックメニュー(BookMetadataSheetから切り出したもの)。
///
/// ■ なぜ別のビューにしたのか(ユーザー報告 2026-09-09)
/// 元はシートの中の計算プロパティで、`CoverOverrideController`はシートが`@State`で持っていた。
/// **`@State`に入れた`ObservableObject`は購読されない**ので、カバーの指定を変えても画面が
/// 描き直される保証が無く、シート側は`@State`のカウンタ(`coverRevision`)を自分で増やして
/// 描き直しを促していた。
///
/// これが「切り取るときに残す位置を変えても、カバーもチェックマークも変わらない(閉じて開き直すと
/// 反映済み)」の正体だった。DBへの書き込みと読み戻しは毎回成功していることを実測で確認済みで、
/// 古いのは表示だけ。**`.contextMenu`の中身は`@State`の変化だけでは組み直されないことがある** ――
/// macOSのSwiftUIではメニュー系(MenuBarExtra・ToolbarItem・contextMenu)が`@State`に追随しない
/// 事例が知られていて、案内されている回避策も「`@State`ではなく観測対象から描く」ことだった。
/// 計測用のログを挟むと再現しなくなる(タイミング依存)ことも、この筋と符合する。
///
/// そこで、契機をコントローラの`@Published var revision`へ一本化し、こちらは
/// `@ObservedObject`で購読する。カウンタを手で回す必要は無くなった。
private struct CoverArea: View {
    @ObservedObject var controller: CoverOverrideController
    let item: CollectionItem
    let library: BookLibrary
    let width: CGFloat
    let coverStore: CollectionCoverStore
    let locale: Locale

    @State private var isPickingPage = false
    @State private var isCoverDropTargeted = false

    var body: some View {
        // **`.id`はカバーとメニューにだけ掛ける。** `@ObservedObject`の購読だけでもbodyは
        // 組み直されるが、`.contextMenu`が実際に組み直される保証はそこには無い(型コメント参照)。
        // 作り直しを明示するのがいちばん確実で、これは他の箇所で見開き一覧に対して採った手と
        // 同じ(画面外のセルが解放されない件で、`.id(epoch)`だけが効いた)。
        //
        // `@State`(ページを選ぶ画面を出しているか、ドロップの当たり判定)は**このビューが持つ**
        // ので、中身を作り直しても消えない ―― ページを選ぶ画面の中でカバーを差し替えても、
        // その画面が閉じてしまうことは無い。
        thumbnailWithMenu
            .id(controller.revision)
            .popover(isPresented: $isPickingPage) {
                ExportCoverPickerContent(
                    bookID: item.bookID, controller: controller,
                    showsCropAnchor: true
                )
            }
            .accessibilityLabel(Text("Collection Cover"))
    }

    private var thumbnailWithMenu: some View {
        CollectionCoverThumbnail(
            item: item, coverStore: coverStore,
            aspectRatio: library.coverAspectRatio,
            anchor: controller.cropAnchor(forBookID: item.bookID) ?? library.coverCropAnchor,
            fit: library.coverFit,
            displayWidth: width
        )
        .frame(width: width)
        .overlay {
            if isCoverDropTargeted {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        // シートは別のNSWindowなので、ウインドウ本体に付けた受け口では拾えない
        // (BookFileDropTarget参照)。ここで受けるのは画像1枚だけ ―― 本ではないので
        // bookFileDropTargetは通さない。
        .fileURLDropTarget(isTargeted: $isCoverDropTargeted) { urls in
            guard let imageURL = urls.first(where: { isImageFile($0.lastPathComponent) }) else { return }
            Task { await controller.setCoverFile(forBookID: item.bookID, fileURL: imageURL) }
        }
        .contextMenu { coverMenu }
    }

    @ViewBuilder
    private var coverMenu: some View {
        // ページを選ぶ画面(ExportCoverPickerContent)には「Choose File…」も
        // 「Reset to Default (First Page)」も入っているが、要望どおりここにも並べておく
        // ―― カバーを1枚だけ差し替えるのに、いちいちページ一覧を開かせない。
        Button("Choose Page in This Book…") { isPickingPage = true }
        Button("Choose File…") { chooseExternalFile() }
        Button("Reset to Default (First Page)") {
            controller.resetCover(forBookID: item.bookID)
        }

        Divider()

        // カバーの比が枠の比と違うぶんを、どこで切るか(ユーザー要望 2026-09-09)。切る軸は
        // 画像ごとに決まるのでラベルは両方の軸を併記する(CoverCropAnchor参照)。4 択は `coverCropAnchorMenuItems`。
        Menu("Keep When Cropping") {
            coverCropAnchorMenuItems(controller: controller, bookID: item.bookID)
        }
    }


    private func chooseExternalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(
            localized: "Choose an image file to use as the cover.", language: locale
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.setCoverFile(forBookID: item.bookID, fileURL: url) }
    }
}

/// 表紙の右クリックの「切り取るときに残す位置」の 4 択(CoverArea と FileBrowserCoverArea が使う)。
///
/// **「設定なし」+ 3 つの位置**(2026-09-23、利用者の指示)。本ごとの指定(`BookLayoutSettings.coverCropAnchor`)は
/// ライブラリとスマートライブラリで**共有**で、「設定なし」(nil)ならそれぞれの設定(ライブラリの歯車 / 環境設定
/// 「スマートライブラリ」)に従う。以前は開いた場所に合わせて「ライブラリの設定に従う」「スマートライブラリの設定に従う」と
/// 書き分けていたが、同じ値がもう一方にも効くので、どちらか一方の名前で呼ぶと意味を取り違える。
/// 「メタデータの編集」ウインドウのカバー列の同じ選択(ExportCoverPickerContent)も同じ文言。
///
/// **いつでも選べる**(以前はライブラリの版で、比が枠とぴったりのカバーには押せなかった)。この画面で切らなくても、
/// もう一方の画面では切ることがあるため。
///
/// **Toggle で描く**(2026-09-23 の実機検証)。以前は Button のラベルを `Label(…, systemImage: "checkmark")` にして自分で印を
/// 添えていたが、macOS 27 SDK でリンクするとメニューの項目の画像は既定で出なくなり(CLAUDE.md「Build & run」)、印が消えて
/// どれを選んでいるか分からなかった。メニューの中の Toggle は AppKit のチェックマーク(画像ではない)で描かれる。
/// 選んでいる項目をもう一度選んでも同じ値を書くだけ(外す操作にはならない ―― 4 択の 1 つを選ぶもの)。
@ViewBuilder
private func coverCropAnchorMenuItems(controller: CoverOverrideController, bookID: String) -> some View {
    let options: [(LocalizedStringKey, CoverCropAnchor?)] = [
        ("No Setting", nil), ("Top / Left", .start), ("Center", .center), ("Bottom / Right", .end),
    ]
    ForEach(options.indices, id: \.self) { index in
        let (titleKey, anchor) = options[index]
        Toggle(isOn: Binding(
            get: { controller.cropAnchor(forBookID: bookID) == anchor },
            set: { _ in controller.setCropAnchor(forBookID: bookID, anchor) }
        )) {
            Text(titleKey)
        }
    }
}

/// ファイルブラウザから開いた、コレクションに入っていない本のカバーの面(BookMetadataSheet の型コメント)。
///
/// 絵は**アイコン表示と同じ提供役**(FileBrowserThumbnailProvider)から引く。指定を変えると、提供役がその本の指定の変化を
/// 見て `revision` を進め、アイコン表示のセルとこの面が同じ絵に描き直される。コントローラの `revision` も鍵に入れる
/// (指定の書き込みと同じ流れで進むので、通知の順番に頼らない)。ライブラリの比が無いので**切らずに**枠へ収める。
///
/// スマートライブラリから開いた版(`smartLibraryCrop`)は、スマートライブラリのカバーの形の枠に、本ごとの指定 ?? 環境設定の
/// 所を残して切って出す(BookMetadataSheet の型コメント)。右クリックの「切り取るときに残す位置」はどちらの版にも出す。
private struct FileBrowserCoverArea: View {
    /// スマートライブラリの表紙の見せ方(環境設定「スマートライブラリ」の値)。
    struct SmartLibraryCrop {
        let shape: SmartLibraryCoverShape
        /// 形の合わせ方(余白を付けるなら切らない)。
        let fit: CoverFit
        /// 本ごとの指定が無いときに残す位置。
        let defaultAnchor: CoverCropAnchor
    }

    @ObservedObject var controller: CoverOverrideController
    let entry: FileBrowserEntry
    let bookID: String
    let width: CGFloat
    let locale: Locale
    var smartLibraryCrop: SmartLibraryCrop?

    @EnvironmentObject private var thumbnails: FileBrowserThumbnailProvider
    /// 余白を付けるときの余白の色(スマートライブラリの版。環境設定「外観」→「ホーム」→「スマートライブラリ」)。
    @EnvironmentObject private var appearance: AppearanceSettings
    @State private var image: CGImage?
    /// 絵を作れなかった(読めない本・画像の無い本)。読み込み中の印を出し続けないため。
    @State private var didFail = false
    @State private var isPickingPage = false
    @State private var isCoverDropTargeted = false

    /// 枠の高さ(幅に対する比)。既定のライブラリと同じ 2:3。
    static let heightRatio: CGFloat = 1.5

    private var kind: BookThumbnailer.Kind? {
        BookThumbnailer.kind(
            forName: entry.url.lastPathComponent, isNavigableFolder: entry.isNavigableFolder,
            isPackage: entry.isPackage, isSymbolicLink: entry.isSymbolicLink
        )
    }

    /// 切る比(スマートライブラリの版で、形が切る形・合わせ方が切るときだけ)。
    private var cropAspect: CGFloat? { smartLibraryCrop.flatMap { $0.shape.cropAspect(fit: $0.fit) } }

    /// 枠の高さ(幅に対する比)。スマートライブラリの版はその形の比。
    private var frameHeightRatio: CGFloat { smartLibraryCrop?.shape.heightRatio ?? Self.heightRatio }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            if let image {
                if let cropAspect, let smartLibraryCrop {
                    // 本ごとの指定 ?? 環境設定の所を残して切る(スマートライブラリのグリッドと同じ。SmartLibraryContent.cropAnchor)。
                    let anchor = controller.cropAnchor(forBookID: bookID) ?? smartLibraryCrop.defaultAnchor
                    Image(decorative: CoverImageResolver.cropped(image, to: cropAspect, anchor: anchor), scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: width, height: width * frameHeightRatio)
                        .clipShape(shape)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                } else if let smartLibraryCrop, smartLibraryCrop.fit == .pad, smartLibraryCrop.shape.cropAspect != nil {
                    // 余白を付ける形(スマートライブラリのグリッドと同じ見た目。SmartBookThumbnail.padding)。
                    ZStack {
                        appearance.effectiveSmartLibraryCoverMargin
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: width, height: width * frameHeightRatio)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                } else {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .shadow(color: .black.opacity(0.3), radius: 1.5, y: 0.5)
                }
            } else {
                shape.fill(Color.secondary.opacity(0.15))
                if !didFail { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: width, height: width * frameHeightRatio)
        .overlay {
            if isCoverDropTargeted {
                shape.strokeBorder(Color.accentColor, lineWidth: 3)
            }
        }
        .contentShape(shape)
        .task(id: "\(thumbnails.revision)|\(controller.revision)") { await load() }
        // CoverArea と同じく、シートは別の NSWindow なので自前で受ける。画像 1 枚だけ。
        .fileURLDropTarget(isTargeted: $isCoverDropTargeted) { urls in
            guard let imageURL = urls.first(where: { isImageFile($0.lastPathComponent) }) else { return }
            Task { await controller.setCoverFile(forBookID: bookID, fileURL: imageURL) }
        }
        .contextMenu {
            Button("Choose Page in This Book…") { isPickingPage = true }
            Button("Choose File…") { chooseExternalFile() }
            Button("Reset to Default (First Page)") { controller.resetCover(forBookID: bookID) }
            Divider()
            // ライブラリの版(CoverArea)と同じ 4 択(`coverCropAnchorMenuItems`)。ファイルブラウザから開いた版でも出す ―― 本ごとの
            // 指定はライブラリとスマートライブラリの両方に効くので、この面が切らずに出していても選ぶ意味がある。
            Menu("Keep When Cropping") {
                coverCropAnchorMenuItems(controller: controller, bookID: bookID)
            }
        }
        // 選んだ位置のチェックマークを確実に付け直す(`.contextMenu` は描き直しだけでは組み直されないことがある。CoverArea の
        // `.id(controller.revision)` と同じ手)。`@State`(絵・ページを選ぶ画面)はこのビュー自身が持つので消えない。
        .id(controller.revision)
        .popover(isPresented: $isPickingPage) {
            ExportCoverPickerContent(bookID: bookID, controller: controller)
        }
        .accessibilityLabel(Text("Collection Cover"))
    }


    private func load() async {
        guard let kind else {
            didFail = true
            return
        }
        let buffer = await thumbnails.thumbnail(for: entry, kind: kind, pixelSize: 512)
        guard !Task.isCancelled else { return }
        guard let made = buffer?.makeImage() else {
            didFail = image == nil
            return
        }
        didFail = false
        image = made
    }

    private func chooseExternalFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = String(localized: "Choose an image file to use as the cover.", language: locale)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.setCoverFile(forBookID: bookID, fileURL: url) }
    }
}
