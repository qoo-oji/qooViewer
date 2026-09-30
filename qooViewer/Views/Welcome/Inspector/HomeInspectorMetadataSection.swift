import SwiftUI

/// インスペクタのメタデータの欄(2026-09-30。それまでの 1 冊ぶんのメタデータ編集シート `BookMetadataSheet` の欄と書き方を移した)。
///
/// 「メタデータの編集」ウインドウと**同じ DB の同じ行**を書く。初期値の決め方も同じ(登録済みなら DB の値、未登録なら
/// ファイル名を qooMeta で 1 冊だけ読んだ提案)。本の URL が分かっているので、行を作るときにブックマークと inode も入る。
///
/// ■ いつ書くか(シートとの違い)
/// シートは「保存」で書き、「キャンセル」で捨てた。インスペクタには閉じる区切りが無いので、**欄を離れたとき**(Return・Tab・
/// ほかをクリック)と、**欄が消えるとき**(別の本を選んだ・インスペクタを隠した・本を開いた)に書く(Finder の情報ウインドウの
/// 名前・コメントと同じ)。鍵のボタンは押したときに書く。
/// 書き方の規則はシートのまま(`commit`): 変えた欄だけを「直した欄」にし、ほかの欄はファイル名の読みに付いていく。
///
/// ■ ほかの画面で変わったとき
/// DB が変わったら(`BookMetadataStore.revision`。メタデータの生成が読み直した・ウインドウで直した)、**打ちかけの欄が無ければ**
/// 読み直す。打ちかけがあれば残す(書くときに、開いたあとで鍵が変わっていたら書かずに読み直す ―― シートと同じ)。
///
/// ■ すりガラス面
/// 見出しと欄の名前は面に直に置く文字なので輪郭を掛ける。入力欄は不透明な地を持つので掛けない。
struct HomeInspectorMetadataSection: View {
    /// 本の id(パス。BookLoader が付ける id)。
    let bookID: String
    /// 本の実体(行を作るときのブックマークと inode)。
    let sourceURL: URL
    /// 書けるか(シークレットウインドウでは false。欄は読むだけ)。
    let allowsEditing: Bool
    /// 焦点を入れる頼み(「メタデータの編集…」)の持ち主。**購読する** ―― 選んでいる本がそのまま表示されている間に頼みだけが
    /// 置かれた(同じ本をもう一度「メタデータの編集…」)とき、ほかの入力は変わらないので、購読しないとこの欄は描き直されず頼みを拾えない。
    @ObservedObject var home: WelcomeLibraryState

    @EnvironmentObject private var metadataStore: BookMetadataStore
    @Environment(MetadataRulesStore.self) private var rulesStore

    private enum Field: Hashable {
        case title, authors, genre, source, event, info, series, volume, volumeSort
    }

    @FocusState private var focusedField: Field?

    /// 編集中の欄(著者は `authorsText`、巻数(並べ替え用)は `volumeSortText` で持つ)。
    @State private var draft = BookMetadataValues()
    /// 著者の欄の文字(「、」で区切って複数。qooMeta の一覧のセルと同じ書き方)。
    @State private var authorsText = ""
    @State private var volumeSortText = ""
    /// 読み込んだ(または最後に書いた)ときの値。変えた欄だけを「直した欄」にする基準で、打ちかけかどうかの判定にも使う。
    @State private var openedValues = BookMetadataValues()
    @State private var openedAuthorsText = ""
    @State private var openedVolumeSortText = ""
    /// ロックしている本か(欄を変えさせない)。
    @State private var isLocked = false
    /// 読み込んだときにロックしていたか(書くときに、ほかの画面で鍵が変わっていないかを見る)。
    @State private var openedIsLocked = false
    @State private var didLoad = false
    /// 欄が出ているか(遅らせて焦点を入れるときに、もう消えた欄へ入れない)。
    @State private var isVisible = false

    var body: some View {
        let isExcluded = rulesStore.isExcluded(bookID: bookID)
        VStack(alignment: .leading, spacing: 8) {
            header(isExcluded: isExcluded)
            if isExcluded {
                Label("This book is in a folder excluded from metadata registration.", systemImage: "folder.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .panelOutlinedContent()
            }
            fields
                .disabled(isExcluded || isLocked || !allowsEditing)
        }
        .onAppear {
            isVisible = true
            if !didLoad { load() }
            takeFocusRequest()
        }
        .onChange(of: home.inspectorFocusRequest) { _, _ in takeFocusRequest() }
        // 欄を離れたら書く(型コメント「いつ書くか」)。欄から欄へ移ったときも、離れた欄のぶんを書く。
        .onChange(of: focusedField) { old, _ in
            if old != nil { commit() }
        }
        .onChange(of: metadataStore.revision) { _, _ in
            if !isDirty { load() }
        }
        .onDisappear {
            isVisible = false
            commit()
        }
    }

    // MARK: - 見出し

    private func header(isExcluded: Bool) -> some View {
        HStack(spacing: 6) {
            HomeInspectorSectionTitle("Metadata")
            Spacer(minLength: 0)
            // 鍵(メタデータの編集ウインドウの鍵の列と同じ意味)。押したときに書く(型コメント)。除外フォルダの本・シークレット
            // ウインドウでは出さない(除外フォルダの本は行を作れない。シークレットウインドウは書かない ―― 状態は欄の淡色で分かる)。
            if !isExcluded, allowsEditing {
                Button { toggleLock() } label: {
                    Image(systemName: isLocked ? "lock.fill" : "lock.open")
                        .panelIconButtonLabel()
                }
                .buttonStyle(.borderless)
                .disabled(!isLocked && !canLock)
                .help(isLocked ? "Locked: the fields can’t be changed. Unlock to edit them.".ui
                      : canLock ? "Lock the values in the fields.".ui
                      : "There is nothing to lock".ui)
                .accessibilityLabel(Text(isLocked ? "Unlock" : "Lock"))
            } else if isLocked {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .panelOutlinedContent()
                    .help("Locked".ui)
            }
        }
    }

    // MARK: - 欄

    private var fields: some View {
        VStack(alignment: .leading, spacing: 8) {
            field("Title", text: $draft.title, focus: .title)
            field("Authors", text: $authorsText, focus: .authors, prompt: Text("Separate several authors with 、"))
            field("Genre", text: $draft.genre, focus: .genre)
            field("Source work", text: $draft.source, focus: .source)
            field("Event", text: $draft.event, focus: .event)
            field("Info", text: $draft.info, focus: .info)
            field("Series", text: $draft.series, focus: .series)
            // 巻はシリーズの中の番号なので、シリーズ名の無い間は入れさせない(メタデータの編集ウインドウの列と同じ。
            // 利用者の指示 2026-09-22)。以前に登録した「シリーズの無い巻」は、シリーズを空にしない限り消さずに残す。
            field("Volume", text: $draft.volume, focus: .volume, isEnabled: hasSeries,
                  help: hasSeries ? "" : "Give the book a series name first".ui)
            // 巻数(並べ替え用)は、シリーズ名のある本だけ(巻の表記は空でもよい)。空にすると、巻の表記から読んだ数に戻る。
            field("Volume (for sorting)", text: $volumeSortText, focus: .volumeSort, prompt: Text(verbatim: "1.5"),
                  isEnabled: canEditVolumeSort,
                  help: canEditVolumeSort ? "Empty goes back to the number read from the volume".ui
                      : "Give the book a series name first".ui)
            if isVolumeSortInvalid {
                // 数に読めない間、この欄だけは書かない(ほかの欄は書く ―― `commit`)。
                Text("Enter a number for the volume for sorting.")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .panelOutlinedContent()
            }
        }
        // Return で確定して書く(欄を離れたときと同じ)。
        .onSubmit { commit() }
    }

    private func field(
        _ label: LocalizedStringKey, text: Binding<String>, focus: Field, prompt: Text? = nil,
        isEnabled: Bool = true, help: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            // 欄そのものにラベルは持たせない(上の見出しが名前になる)。読み上げのために同じ文字列の名前だけ与える。
            TextField("", text: text, prompt: prompt)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: focus)
                .accessibilityLabel(Text(label))
                .disabled(!isEnabled)
                .help(help)
        }
    }

    // MARK: - 状態

    /// 打ちかけの欄があるか(読み込んだ・最後に書いた値と違う)。
    private var isDirty: Bool {
        draft != openedValues || authorsText != openedAuthorsText || volumeSortText != openedVolumeSortText
    }

    /// 鍵を掛けられるか(全欄が空なら行を作れないので掛けられない ―― `BookMetadataStore.applyUpsert`。メタデータの編集
    /// ウインドウの `setLocked` と同じ)。
    private var canLock: Bool {
        var values = draft
        values.authors = Self.authors(from: authorsText)
        return !values.trimmed.isEmpty && !isVolumeSortInvalid
    }

    private var hasSeries: Bool { !draft.series.trimmingCharacters(in: .whitespaces).isEmpty }

    /// 巻数(並べ替え用)はシリーズの中の位置なので、シリーズ名のある本だけ(巻数(表示)は空でもよい)。
    private var canEditVolumeSort: Bool { hasSeries }

    /// 直した巻数(並べ替え用)が数に読めない(書かない)。
    private var isVolumeSortInvalid: Bool {
        canEditVolumeSort && volumeSortText != openedVolumeSortText
            && !volumeSortText.trimmingCharacters(in: .whitespaces).isEmpty
            && MetadataWorkspace.volumeSortNumber(volumeSortText) == nil
    }

    private static func authors(from text: String) -> [String] {
        text.split(whereSeparator: { "、,，".contains($0) }).map(String.init)
    }

    // MARK: - 読み込み

    /// 登録済みなら DB の値、未登録なら qooMeta で 1 冊だけ読んだ提案(同じ書き手のほかの本とは見比べないので、番号の無い
    /// シリーズは見つからない。一覧の窓なら見つかる)。
    private func load() {
        let row = metadataStore.metadata(forBookID: bookID)
        draft = row?.values
            ?? BookMetadataValues(MetadataRulesStore.singleProposal(forBookID: bookID, rules: rulesStore.rules))
        openedValues = draft
        isLocked = row?.isLocked == true
        openedIsLocked = isLocked
        authorsText = draft.authors.joined(separator: "、")
        openedAuthorsText = authorsText
        volumeSortText = draft.volumeSort.map(MetadataWorkspace.volumeSortText) ?? ""
        openedVolumeSortText = volumeSortText
        didLoad = true
    }

    /// 「メタデータの編集…」から来た頼みなら、題の欄へ焦点を入れる。コレクションの中のグリッドは選択が変わると焦点を自分へ移すが、
    /// 頼みがある間と拾った直後は控える(`WelcomeLibraryState.isInspectorTakingFocus`)。焦点を入れるのは次の周回 ―― 現れたばかりの
    /// 欄は、同じ更新の中ではまだ焦点を受けられない。その間に欄が消えていたら何もしない。
    private func takeFocusRequest() {
        guard allowsEditing, home.takeInspectorFocusRequest(for: bookID) else { return }
        DispatchQueue.main.async {
            guard isVisible else { return }
            focusedField = .title
        }
    }

    // MARK: - 書く

    /// 鍵の掛け外し。押したときに書く(型コメント)。
    private func toggleLock() {
        guard allowsEditing else { return }
        if isLocked {
            isLocked = false
        } else {
            guard canLock else { return }
            isLocked = true
        }
        commit()
    }

    /// 欄を DB へ書く。**変えた欄だけを「直した欄」にする**(ほかの欄はファイル名の読みに付いていく。メタデータの編集
    /// ウインドウで直したときと同じ。利用者の指示 2026-09-22)。行が無ければロックせずに作る。
    /// 鍵: 掛けたら欄の値をすべて確定してロックする。外したら、ファイル名の読みと違う欄だけを直した欄にする(ウインドウの
    /// `MetadataWorkspace.unlock` と同じ考え)。
    /// すべての欄が空のまま書くと、既存仕様どおり行そのものを消す。
    /// 1 冊ぶんのシート(`BookMetadataSheet.register`、2026-09-30 に廃止)の規則そのまま。
    ///
    /// **数に読めない巻数(並べ替え用)は書かず、ほかの欄は書く。** シートは「保存」を押せなくして何も捨てなかったが、インスペクタは
    /// 欄を離れるたび・消えるたびに書くので、その 1 欄のためにほかの直しまで黙って捨てることになる。読めない文字は欄に残し(赤い案内も
    /// 残る)、直せば次に書く。欄が消えたら捨てる(数でない値はもともと書けない)。
    private func commit() {
        guard didLoad, allowsEditing, !rulesStore.isExcluded(bookID: bookID) else { return }
        guard isDirty || isLocked != openedIsLocked else { return }
        let invalidVolumeSortText = isVolumeSortInvalid ? self.volumeSortText : nil
        // ここから先は、読めない巻数(並べ替え用)を「変えていない」として扱う。
        let volumeSortText = invalidVolumeSortText == nil ? self.volumeSortText : openedVolumeSortText
        // 読めない巻数のほかに変えたものが無ければ書かない(行の無い本に、提案の値そのままの行を作らない)。
        guard draft != openedValues || authorsText != openedAuthorsText || volumeSortText != openedVolumeSortText
                || isLocked != openedIsLocked else { return }
        let storedLocked = metadataStore.metadata(forBookID: bookID)?.isLocked == true
        // 読み込んだあとにほかの画面で鍵が変わっていたら書かない(その画面の操作を上書きしない)。読み直して合わせる。
        guard storedLocked == openedIsLocked else { return load() }
        guard !(storedLocked && isLocked) else { return }
        var values = draft
        values.authors = Self.authors(from: authorsText)
        // シリーズ名を空にしたら、巻も外す(シリーズの無い巻は持たせない。欄は入れられなくなっているが値は残っているので)。
        // シリーズ名を別の名前に変えたら、巻は新しいシリーズ名で読み直す(巻はシリーズの中の番号。2026-09-22、利用者の指示。
        // 表記だけを直したときは残す ―― `MetadataWorkspace.sameSeriesName`)。同じ書き込みで巻も入れ直していたら、入れた巻を使う。
        // 読み直しはメタデータ生成が行う(直した欄の巻の確定を外す。下の `reproposingVolume`)。
        let newSeries = values.series.trimmingCharacters(in: .whitespaces)
        let oldSeries = openedValues.series.trimmingCharacters(in: .whitespaces)
        let openedVolume = openedValues.volume
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
            // (`narrowEditsAfterUnlock`。メタデータの編集ウインドウの `unlock` と同じ ―― この本だけを読んだ値と比べると、シリーズや
            // 巻数(並べ替え用)のように見比べで決まる欄が「読みと同じ」として外れ、鍵を外しただけで値が変わる。2026-09-23 の監査)。
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
        metadataStore.upsertAll([BookMetadataStore.BatchEntry(bookID: bookID, values: values, sourceURL: sourceURL,
                                                              state: state)])
        if narrowsEditsAfterUnlock {
            MetadataWorkspace.narrowEditsAfterUnlock(bookID: bookID, values: values, written: state, store: metadataStore)
        }
        // 書いた値を新しい基準にする(DB から読み直す。行を消した・生成がすぐ読み直したときも、見えている値が DB と揃う)。
        load()
        // 書かなかった読めない巻数(並べ替え用)は欄に戻す(打ちかけとして残り、案内も出たまま)。
        if let invalidVolumeSortText { self.volumeSortText = invalidVolumeSortText }
    }
}

/// インスペクタの節の見出し(「メタデータ」「情報」)。すりガラス面に直に置く文字なので輪郭を掛ける。
struct HomeInspectorSectionTitle: View {
    let key: LocalizedStringKey

    init(_ key: LocalizedStringKey) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .panelOutlinedContent()
    }
}
