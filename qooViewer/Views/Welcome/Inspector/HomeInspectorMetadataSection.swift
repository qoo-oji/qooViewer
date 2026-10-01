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
/// 欄を離れずにウインドウを閉じた・アプリを終えたときも書く(`.onDisappear` はウインドウごと閉じると呼ばれないことがある ――
/// `FocusReleasingField` の型コメント。2026-10-01 のレビュー: 打ちかけの題が ⌘W・⌘Q で黙って消えうるので、閉じる・終わる知らせでも書く)。
///
/// ■ ほかの画面で変わったとき
/// DB が変わったら(`BookMetadataStore.revision`。メタデータの生成が読み直した・ウインドウで直した)、**打ちかけの欄が無く、この本の
/// 行が変わっていれば**読み直す。打ちかけがあれば残す(書くときに、開いたあとで鍵が変わっていたら書かずに読み直す ―― シートと同じ)。
/// ほかの本の書き込みでは読み直さない(行の無い本は読み直すたびにファイル名をメインで解析するので、スマートライブラリの集め直しや
/// メタデータ生成が何千冊も書く間、そのたびに同じ解析を繰り返していた。2026-10-01 のレビュー)。
///
/// ■ 1 つの欄に値をいくつも(2026-10-01、利用者の指示。メタデータの編集ウインドウの一覧と同じく qooMeta 0.3.0 に合わせた)
/// 値をいくつも持てる欄(著者・原作・情報。`holdsSeveralInQooViewer`)は、**値ごとに入力欄を縦に並べる**。ほかの欄は 1 つに固定
/// (タイトル・ジャンル・イベント・シリーズ・巻数。利用者の判断 2026-10-01 ―― qooMeta の「足したシリーズ」も持たない)。
/// - 欄の名前の右の「＋」で下に入力欄を足し、そこへ焦点を入れる。空にした入力欄は、焦点が離れたときに消える(一覧で段を空にしたのと同じ)。
/// - 2 つ以上ある欄の入力欄に焦点があるあいだは、名前の右に「上へ」「下へ」が出る(⌥⌘↑ / ⌥⌘↓。一覧の帯のボタンと同じ)。
///   先頭の値が、1 つしか受けない所(表示・書き出し)へ渡る。
/// 著者の入力欄は、前からの書き方どおり「、」で区切っても何人かに分かれる。
///
/// 欄の名前はメタデータの編集ウインドウの列の見出しと同じ言葉にする(巻数は「巻数(表示)」。2026-10-01、利用者の指摘)。
///
/// ■ すりガラス面
/// 見出しと欄の名前・「＋」などのアイコンは面に直に置くので輪郭を掛ける。入力欄は不透明な地を持つので掛けない。
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

    /// 値をいくつも持てる欄(著者・原作・情報)。鍵は著者のほかは `BookMetadataValues.moreValueKeys` と同じ qooMeta の欄の名前。
    private enum LineKey: String, CaseIterable, Hashable {
        case authors, source, info

        var label: LocalizedStringKey {
            switch self {
            case .authors: "Authors"
            case .source: "Source work"
            case .info: "Info"
            }
        }
    }

    private enum Field: Hashable {
        /// 値をいくつも持てる欄の、上から `Int` 番目の入力欄。
        case line(LineKey, Int)
        case title, genre, event, series, volume, volumeSort
    }

    @FocusState private var focusedField: Field?

    /// 編集中の欄のうち、1 つに固定した欄(値をいくつも持てる欄は `lines`、巻数(並べ替え用)は `volumeSortText` で持つ)。
    @State private var draft = BookMetadataValues()
    /// 値をいくつも持てる欄の入力欄の文字(欄ごとに上から。無い欄は空の並び ―― 画面には空の入力欄を 1 つ出す)。
    @State private var lines: [LineKey: [String]] = [:]
    @State private var volumeSortText = ""
    /// 読み込んだ(または最後に書いた)ときの値。変えた欄だけを「直した欄」にする基準で、打ちかけかどうかの判定にも使う。
    @State private var openedValues = BookMetadataValues()
    @State private var openedLines: [LineKey: [String]] = [:]
    @State private var openedVolumeSortText = ""
    /// ロックしている本か(欄を変えさせない)。
    @State private var isLocked = false
    /// 読み込んだときにロックしていたか(書くときに、ほかの画面で鍵が変わっていないかを見る)。
    @State private var openedIsLocked = false
    @State private var didLoad = false
    /// 欄が出ているか(遅らせて焦点を入れるときに、もう消えた欄へ入れない)。
    @State private var isVisible = false
    /// 最後に読み込んだときのこの本の行(行が無ければ nil)。DB の変化がこの本に関わるかを見る(型コメント「ほかの画面で変わったとき」)。
    @State private var loadedRow: LoadedRow?
    /// この欄のあるウインドウ(閉じる知らせを、このウインドウのものだけ受ける)。
    @State private var hostWindow = WeakWindowBox()

    private struct LoadedRow: Equatable {
        let values: BookMetadataValues
        let isLocked: Bool

        init?(_ row: BookMetadata?) {
            guard let row else { return nil }
            values = row.values
            isLocked = row.isLocked
        }
    }

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
        // 書くと DB から読み直し、空にした入力欄が詰まる・著者が「、」で分かれるので、移った先の入力欄を書いたあとの並びで
        // 指し直す(`LineAnchor`)。
        .onChange(of: focusedField) { old, new in
            guard old != nil else { return }
            let anchor = lineAnchor(new)
            commit()
            if let anchor { refocus(anchor) }
        }
        .onChange(of: metadataStore.revision) { _, _ in
            guard didLoad, !isDirty, LoadedRow(metadataStore.metadata(forBookID: bookID)) != loadedRow else { return }
            load()
        }
        .onDisappear {
            isVisible = false
            commit()
        }
        .background(WindowAccessor { window in
            if hostWindow.window !== window { hostWindow.window = window }
        })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            guard let window = hostWindow.window, (note.object as? NSWindow) === window else { return }
            commit()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
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
            lineField(.authors)
            field("Genre", text: $draft.genre, focus: .genre)
            lineField(.source)
            field("Event", text: $draft.event, focus: .event)
            lineField(.info)
            field("Series", text: $draft.series, focus: .series)
            // 巻はシリーズの中の番号なので、シリーズ名の無い間は入れさせない(メタデータの編集ウインドウの列と同じ。
            // 利用者の指示 2026-09-22)。以前に登録した「シリーズの無い巻」は、シリーズを空にしない限り消さずに残す。
            // 名前はウインドウの列の見出しと同じ「巻数(表示)」(2026-10-01、利用者の指摘。以前は「巻数」だけで食い違っていた)。
            field("Volume (as written)", text: $draft.volume, focus: .volume, isEnabled: hasSeries,
                  help: hasSeries ? "" : "Give the book a series name first".ui)
            // 巻数(並べ替え用)は、シリーズ名のある本だけ(巻の表記は空でもよい)。空にすると、巻の表記から読んだ数に戻る。
            // 入力例(「1.5」)は出さない(2026-10-01、利用者の指摘: 巻数の無い本で値が入っているように見えた。一覧の列にも無い)。
            field("Volume (for sorting)", text: $volumeSortText, focus: .volumeSort,
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

    /// 欄の名前の行(名前と、右端に置くボタン)。
    private func labelRow(_ label: LocalizedStringKey, @ViewBuilder trailing: () -> some View = { EmptyView() }) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .panelOutlinedContent()
            Spacer(minLength: 0)
            trailing()
        }
    }

    /// 欄の名前の右の小さなアイコンのボタン(「＋」「上へ」「下へ」)。面に直に置くので輪郭を掛ける。
    private func iconButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 16, height: 14)
                .contentShape(Rectangle())
                .panelOutlinedContent()
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private func addButton(help: String, action: @escaping () -> Void) -> some View {
        iconButton("plus", help: help, action: action).accessibilityLabel(Text(verbatim: help))
    }

    /// 焦点のある入力欄を上 / 下へ動かすボタン(⌥⌘↑ / ⌥⌘↓。焦点のある欄の名前の行にだけ出すので、同じ鍵が 2 つ出ることはない)。
    @ViewBuilder
    private func moveButtons(canMoveUp: Bool, canMoveDown: Bool, move: @escaping (Bool) -> Void) -> some View {
        iconButton("chevron.up", help: "Moves the value up (Option-Command-Up Arrow)".ui) { move(true) }
            .keyboardShortcut(.upArrow, modifiers: [.option, .command])
            .disabled(!canMoveUp)
            .accessibilityLabel(Text("Move Up"))
        iconButton("chevron.down", help: "Moves the value down (Option-Command-Down Arrow)".ui) { move(false) }
            .keyboardShortcut(.downArrow, modifiers: [.option, .command])
            .disabled(!canMoveDown)
            .accessibilityLabel(Text("Move Down"))
    }

    /// 値をいくつも持てる欄: 名前の行(「＋」と、焦点があれば「上へ」「下へ」)と、値ごとの入力欄。
    private func lineField(_ key: LineKey) -> some View {
        let shown = shownLines(key)
        let focusedIndex: Int? = if case .line(key, let index)? = focusedField { index } else { nil }
        return VStack(alignment: .leading, spacing: 3) {
            labelRow(key.label) {
                if let focusedIndex, shown.count > 1 {
                    moveButtons(canMoveUp: focusedIndex > 0, canMoveDown: focusedIndex < shown.count - 1) { up in
                        moveLine(key, from: focusedIndex, up: up)
                    }
                }
                addButton(help: "Add a value".ui) { addLine(key) }
            }
            ForEach(shown.indices, id: \.self) { index in
                TextField("", text: lineBinding(key, index),
                          prompt: key == .authors && shown.count == 1 ? Text("Separate several authors with 、") : nil)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .line(key, index))
                    .accessibilityLabel(Text(key.label))
            }
        }
    }

    private func field(
        _ label: LocalizedStringKey, text: Binding<String>, focus: Field, prompt: Text? = nil,
        isEnabled: Bool = true, help: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            labelRow(label)
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

    /// 打ちかけの欄があるか(読み込んだ・最後に書いた値と違う。足しただけの空の入力欄も打ちかけ ―― その間に DB が変わって
    /// 読み直すと、足した入力欄が消えるので)。
    private var isDirty: Bool {
        draft != openedValues || lines != openedLines || volumeSortText != openedVolumeSortText
    }

    /// 入力欄から組み立てた値(巻数(並べ替え用)は `draft` のまま。`commit` が決める)。
    private var editedValues: BookMetadataValues {
        var values = draft
        for key in LineKey.allCases {
            let list = lines[key] ?? []
            if key == .authors {
                values.authors = list.flatMap { Self.authors(from: $0) }
            } else {
                values.setAllValues(key.rawValue, to: list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            }
        }
        return values
    }

    /// 鍵を掛けられるか(全欄が空なら行を作れないので掛けられない ―― `BookMetadataStore.applyUpsert`。メタデータの編集
    /// ウインドウの `setLocked` と同じ)。
    private var canLock: Bool {
        !editedValues.trimmed.isEmpty && !isVolumeSortInvalid
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

    // MARK: - 値ごとの入力欄

    /// 画面に出す入力欄(値の無い欄も空の入力欄を 1 つ)。
    private func shownLines(_ key: LineKey) -> [String] {
        let list = lines[key] ?? []
        return list.isEmpty ? [""] : list
    }

    private func lineBinding(_ key: LineKey, _ index: Int) -> Binding<String> {
        Binding(
            get: { shownLines(key).indices.contains(index) ? shownLines(key)[index] : "" },
            set: { text in
                var list = lines[key] ?? []
                while list.count <= index { list.append("") }
                list[index] = text
                lines[key] = list
            }
        )
    }

    /// 入力欄を一番下に足して焦点を入れる。先に今の打ちかけを書く(書くと読み直すので、足した入力欄が消えないように)。
    /// 値の無い欄なら、出ている空の入力欄へ焦点を入れるだけ。
    private func addLine(_ key: LineKey) {
        commit()
        var list = lines[key] ?? []
        if list.isEmpty || list.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            // 空の入力欄が既にあれば、そこへ入れる(空の入力欄を重ねない)。
            let index = list.firstIndex { $0.trimmingCharacters(in: .whitespaces).isEmpty } ?? 0
            return focusedField = .line(key, index)
        }
        list.append("")
        lines[key] = list
        // 焦点は次の周回で入れる ―― 足した入力欄は、この更新ではまだ画面に無く、焦点を受けられない(使い捨てボリュームでの実機検証
        // 2026-10-01: 値のある欄で「＋」を押すと、入力欄は増えたが焦点が入らず、打った文字がどこにも入らなかった)。その間に欄が
        // 消えていたら何もしない。
        let target = Field.line(key, list.count - 1)
        DispatchQueue.main.async {
            guard isVisible, (lines[key]?.count ?? 0) > list.count - 1 else { return }
            focusedField = target
        }
    }

    /// 入力欄を 1 つ上 / 下へ動かし、焦点も付いていく(焦点が動くので、`onChange(of: focusedField)` が書く)。
    private func moveLine(_ key: LineKey, from index: Int, up: Bool) {
        var list = shownLines(key)
        let target = index + (up ? -1 : 1)
        guard list.indices.contains(index), list.indices.contains(target) else { return }
        list.swapAt(index, target)
        lines[key] = list
        focusedField = .line(key, target)
    }

    /// 焦点が移った先の入力欄の目印: 欄と、その入力欄より上にある値の数(書いたあとの並びでの位置)。
    private struct LineAnchor {
        let key: LineKey
        /// 移った先の入力欄の、書く前の番号。
        let index: Int
        /// その入力欄より上にある値の数(空の入力欄は数えず、著者は「、」で分かれた数)。
        let valuesAbove: Int
        /// 移った先が空の入力欄か(書くと消えるので、同じ位置に空の入力欄を残す)。
        let isEmpty: Bool
    }

    private func lineAnchor(_ field: Field?) -> LineAnchor? {
        guard case .line(let key, let index)? = field else { return nil }
        let shown = shownLines(key)
        let above = shown.prefix(index).reduce(0) { $0 + valueCount(key, $1) }
        let isEmpty = !shown.indices.contains(index) || valueCount(key, shown[index]) == 0
        return LineAnchor(key: key, index: index, valuesAbove: above, isEmpty: isEmpty)
    }

    /// 1 つの入力欄が書く値の数(`editedValues` と同じ分け方)。
    private func valueCount(_ key: LineKey, _ text: String) -> Int {
        let pieces = key == .authors ? Self.authors(from: text) : [text]
        return pieces.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    /// 書いたあとの並びで、移った先の入力欄を指し直す(2026-10-01 のレビュー: 著者 [A, B, C, D] の B を空にして C を押すと、
    /// 書いて詰まった [A, C, D] の 3 番目 ―― D ―― に焦点が残り、C を直すつもりで D を書き換えていた。末尾なら焦点が消えていた)。
    private func refocus(_ anchor: LineAnchor) {
        // 書いているあいだに焦点がほかへ移っていたら触らない。
        guard focusedField == .line(anchor.key, anchor.index) else { return }
        var list = lines[anchor.key] ?? []
        let target: Int
        if anchor.isEmpty {
            target = min(anchor.valuesAbove, list.count)
            // 値の無い欄は空の入力欄を 1 つ出している(`shownLines`)。それ以外で空の入力欄が消えていたら、同じ位置に戻す
            // (足しただけの空の入力欄は打ちかけ ―― `isDirty`)。
            let isShownEmpty = list.isEmpty && target == 0
            let isKept = list.indices.contains(target) && valueCount(anchor.key, list[target]) == 0
            if !isShownEmpty, !isKept {
                list.insert("", at: target)
                lines[anchor.key] = list
            }
        } else {
            target = min(anchor.valuesAbove, max(list.count - 1, 0))
        }
        if target != anchor.index { focusedField = .line(anchor.key, target) }
    }

    /// 空の入力欄を片付ける(焦点のある所は残す ―― 足したばかりで、これから書く所なので)。
    private func pruneEmptyLines() {
        for key in LineKey.allCases {
            guard let list = lines[key] else { continue }
            let kept = list.indices.filter { index in
                !list[index].trimmingCharacters(in: .whitespaces).isEmpty || focusedField == .line(key, index)
            }.map { list[$0] }
            if kept != list { lines[key] = kept }
        }
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
        lines = Dictionary(uniqueKeysWithValues: LineKey.allCases.map { key in
            (key, key == .authors ? draft.authors : draft.allValues(key.rawValue))
        })
        openedLines = lines
        volumeSortText = draft.volumeSort.map(MetadataWorkspace.volumeSortText) ?? ""
        openedVolumeSortText = volumeSortText
        loadedRow = LoadedRow(row)
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
        var values = editedValues
        // 読めない巻数のほかに変えたものが無ければ書かない(行の無い本に、提案の値そのままの行を作らない)。足しただけの空の
        // 入力欄・入れ替えて戻しただけの並びも「変えていない」(値の並びで比べる)。その片付けだけをする。
        guard values.trimmed != openedValues.trimmed || volumeSortText != openedVolumeSortText
                || isLocked != openedIsLocked else { return pruneEmptyLines() }
        let storedLocked = metadataStore.metadata(forBookID: bookID)?.isLocked == true
        // 読み込んだあとにほかの画面で鍵が変わっていたら書かない(その画面の操作を上書きしない)。読み直して合わせる。
        guard storedLocked == openedIsLocked else { return load() }
        guard !(storedLocked && isLocked) else { return }
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
