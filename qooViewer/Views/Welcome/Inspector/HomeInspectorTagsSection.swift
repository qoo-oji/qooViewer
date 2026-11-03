import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// インスペクタがタグを変えた(同じ項目を見ているほかのウインドウのインスペクタが読み直す)。`object` は変えたパス。
    static let finderTagsDidChange = Notification.Name("qooViewer.finderTagsDidChange")
}

/// タグを読む相手。
struct HomeInspectorTagTarget: Hashable, Sendable {
    var url: URL
    /// コレクションの本のブックマーク(許可したフォルダの外の本は、このスコープの中でしか読めない)。
    var bookmark: Data?
    /// 記号リンク・エイリアスの先か。利用者が入っていない場所なので、TCC の保護下は読まない(docs/15「サンドボックスと TCC の約束」)。
    var isLinkTarget = false
}

/// インスペクタのタグの節の状態(2026-11-03)。読むのも書くのも `FileIO` の上で、書くのは 1 つずつ順に。
@MainActor
final class HomeInspectorTagsModel: ObservableObject {
    /// 読めなかった理由(「タグ無し」とは区別して見せる)。
    enum Unavailable: Equatable {
        case notFound, denied, corrupted, failed
    }

    enum Content: Equatable {
        case loading
        case tags([FinderTag])
        case unavailable(Unavailable)
    }

    /// 変更できない理由。項目は消さず淡色にする(`refusal`)。
    enum EditRefusal: Equatable {
        /// シークレットウインドウ(窓ごと見るだけなので理由は出さない)。
        case privateWindow
        /// 読み取り専用モード(`AppPreferences.refusesFileChanges`。「常にこのアプリケーションで開く」と同じ扱い)。
        case readOnlyMode
        /// ネットワークボリューム(利用者の指定で見るだけ)。
        case networkVolume
        /// 読み取り専用のボリューム・書き込み権限が無い・ボリュームそのもの。
        case notWritable
    }

    @Published private(set) var content: Content = .loading
    @Published private(set) var location: FinderTagStore.Location?
    /// 最後の変更に失敗した理由。次に変更できるまで出しておく(相手が変わったら消える)。
    @Published private(set) var applyError: FinderTagStore.WriteError?

    private var target: HomeInspectorTagTarget?
    /// 読み直しの番号(古い読み込みの結果で新しい表示を上書きしない)。
    private var readGeneration = 0
    /// 変更は順に 1 つずつ(続けて足したときに、前の変更を読まないまま書かない)。
    private var lastApply: Task<Void, Never>?

    /// 応答しない共有で待ち続けない。
    static let readLimit: Duration = .seconds(10)

    /// `target` を読む(変わったときは読み終わるまで「読み込み中」、同じ相手の読み直しなら今の表示のまま)。
    func load(_ target: HomeInspectorTagTarget) async {
        if self.target != target {
            self.target = target
            content = .loading
            location = nil
            applyError = nil
        }
        readGeneration &+= 1
        let generation = readGeneration
        // ネットワーク越しは矢印キーで選び続ける間に読まない(眠っている NAS で 1 回ごとに `FileIO` のスレッドを塞ぐ)。
        if NetworkVolumeReading.isOnNetworkVolume(target.url) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
        }
        let outcome = try? await FileIO.withDeadline(Self.readLimit) {
            await FileIO.perform { Self.read(target) }
        }
        guard !Task.isCancelled, generation == readGeneration, self.target == target else { return }
        guard let outcome else {
            content = .unavailable(.failed)
            return
        }
        location = outcome.location
        switch outcome.reading {
        case .tags(let tags): content = .tags(tags)
        case .notFound: content = .unavailable(.notFound)
        case .denied: content = .unavailable(.denied)
        case .corrupted: content = .unavailable(.corrupted)
        case .failed: content = .unavailable(.failed)
        }
    }

    /// 今の相手を読み直す(アプリへ戻ったとき・ほかのウインドウが変えたとき)。
    func reload() async {
        guard let target else { return }
        await load(target)
    }

    /// 変更する。順番が来たときにも断る条件を見直す(`currentRefusal`。待っている間に読み取り専用へ切り替わりうる)。
    /// - Returns: 書き終わるまでの Task(テストが待つ)。
    @discardableResult
    func apply(_ edit: FinderTagEdit, currentRefusal: @escaping @MainActor () -> EditRefusal?) -> Task<Void, Never>? {
        guard let target else { return nil }
        let previous = lastApply
        let task = Task { [weak self] in
            await previous?.value
            guard let self, currentRefusal() == nil else { return }
            do {
                let tags = try await FileIO.perform { try Self.write(edit, target: target) }
                NotificationCenter.default.post(name: .finderTagsDidChange, object: target.url.path)
                guard self.target == target else { return }
                self.readGeneration &+= 1
                self.applyError = nil
                self.content = .tags(tags)
            } catch {
                guard self.target == target else { return }
                self.applyError = error as? FinderTagStore.WriteError ?? .failed(EIO)
                // 読めなかった・効かなかったので、ファイルの今の値を見せ直す。
                await self.reload()
            }
        }
        lastApply = task
        return task
    }

    /// 変更できない理由(できるなら nil)。読み終わるまでは断る(読めていない一覧の上に足さない)。
    static func refusal(
        allowsEditing: Bool, refusesFileChanges: Bool, location: FinderTagStore.Location?
    ) -> EditRefusal? {
        if !allowsEditing { return .privateWindow }
        guard let location else { return .notWritable }
        // 利用者の指定はボリュームの種類なので、読み取り専用モードより先に見る(モードを切っても変えられない、と分かるように)。
        if location.isOnNetworkVolume { return .networkVolume }
        if refusesFileChanges { return .readOnlyMode }
        if location.isMountPoint || location.isUnwritable { return .notWritable }
        return nil
    }

    // MARK: - FileIO の上

    nonisolated private struct ReadOutcome: Sendable {
        var reading: FinderTagStore.Reading
        var location: FinderTagStore.Location
    }

    /// **ブロッキングする。**
    nonisolated private static func read(_ target: HomeInspectorTagTarget) -> ReadOutcome {
        withAccess(target) { url in
            let location = FinderTagStore.location(of: url)
            if target.isLinkTarget, DirectoryProbe.isPrivacyProtected(url) {
                return ReadOutcome(reading: .denied, location: location)
            }
            return ReadOutcome(reading: FinderTagStore.read(at: url), location: location)
        }
    }

    /// **ブロッキングする。**
    nonisolated private static func write(_ edit: FinderTagEdit, target: HomeInspectorTagTarget) throws -> [FinderTag] {
        try withAccess(target) { url in try FinderTagStore.apply(edit, at: url) }
    }

    /// ブックマークのスコープを開けている間に読み書きする(解けなければ記録したパスのまま。裏の解決なので繋がっていない共有へ繋ぎに行かない)。
    nonisolated private static func withAccess<T>(_ target: HomeInspectorTagTarget, _ body: (URL) throws -> T) rethrows -> T {
        guard let bookmark = target.bookmark,
              let resolved = BookmarkResolution.resolve(bookmark, purpose: .background),
              !BookLocationResolver.isInTrash(resolved) else {
            return try body(target.url)
        }
        let scoped = resolved.startAccessingSecurityScopedResource()
        defer { if scoped { resolved.stopAccessingSecurityScopedResource() } }
        return try body(resolved)
    }
}

/// インスペクタの「タグ」の節(2026-11-03、利用者の要望)。名前の下に置く(Finder の「情報を見る」のタグと同じ位置付け)。
///
/// - **ネットワークボリュームは見るだけ**、ほかは足す・外すができる(利用者の指定)。読み取り専用モード(既定 ON)の間とシークレットウインドウでは
///   淡色(ファイルを変えるほかの操作と同じ)。**ビューアで開いている本でも変えられる**(名前も中身も動かさない。「常にこのアプリケーションで開く」と同じ)
/// - 「タグ無し」と「読めない」を分けて出す(`FinderTagStore` の型コメント)。節は本でない項目にも出すが、ボリュームそのものには呼ぶ側が出さない
/// - 色は標準の 7 色から足す(`FinderTagColor`。Finder のタグの一覧はサンドボックスの中から読めないので、使っている名前の候補は出せない)
///
/// すりガラス面: 見出し・案内・メニューのアイコンは `.panelOutlinedContent()`。チップは不透明な地を持つので何も掛けない。
struct HomeInspectorTagsSection: View {
    let target: HomeInspectorTagTarget
    let allowsEditing: Bool
    /// 使える幅(長い名前のチップを収める)。
    let width: CGFloat

    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.locale) private var locale
    @StateObject private var model = HomeInspectorTagsModel()
    @State private var newTagName = ""
    @FocusState private var isFieldFocused: Bool

    private var refusal: HomeInspectorTagsModel.EditRefusal? {
        HomeInspectorTagsModel.refusal(
            allowsEditing: allowsEditing, refusesFileChanges: preferences.refusesFileChanges, location: model.location
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 無いファイルの節は出さない(情報の節が「見つかりません」と言う)。外側は残す: 戻ってきたら読み直せるように。
            if model.content != .unavailable(.notFound) {
                HomeInspectorSectionTitle("Tags")
                switch model.content {
                case .loading:
                    DelayedProgressIndicator(controlSize: .small)
                case .tags(let tags):
                    tagList(tags)
                    addRow(tags)
                    note
                case .unavailable(let reason):
                    message(unavailableText(reason))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: target) { await model.load(target) }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.reload() }
        }
        // ほかのウインドウのインスペクタが同じ項目を変えた(自分の変更でも来るが、読み直しても同じ値が出るだけ)。
        .onReceive(NotificationCenter.default.publisher(for: .finderTagsDidChange)) { notification in
            guard notification.object as? String == target.url.path else { return }
            Task { await model.reload() }
        }
        .onChange(of: isFieldFocused) { _, focused in
            if !focused { commitNewTag() }
        }
        // 相手が変わったら打ちかけの名前は持ち越さない(前の項目のつもりの名前を次の項目へ付けない)。
        .onChange(of: target) { _, _ in newTagName = "" }
        // 打ちかけの名前を、選び直し・ウインドウを閉じるときに黙って捨てない(メタデータの欄と同じ)。
        .onDisappear { commitNewTag() }
    }

    // MARK: - チップ

    @ViewBuilder
    private func tagList(_ tags: [FinderTag]) -> some View {
        if tags.isEmpty {
            message(String(localized: "No Tags", language: locale))
        } else {
            FlowLayout(spacing: 4) {
                // ファイルの値なので同じ名前が 2 つあることも、名前が空のこともありうる(位置を識別子にする)。
                ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                    if !tag.name.isEmpty { chip(tag) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ tag: FinderTag) -> some View {
        HStack(spacing: 4) {
            HomeInspectorTagDot(color: tag.color)
            Text(verbatim: tag.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(tag.name)
            if refusal == nil {
                Button {
                    apply(.remove(name: tag.name))
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(removeTitle(tag.name))
                .accessibilityLabel(removeTitle(tag.name))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        // 不透明な地(すりガラスの色と同じになっても消えない)。
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        .frame(maxWidth: width, alignment: .leading)
    }

    private func removeTitle(_ name: String) -> String {
        String(format: String(localized: "Remove Tag “%@”", language: locale), name)
    }

    // MARK: - 足す

    private func addRow(_ tags: [FinderTag]) -> some View {
        HStack(spacing: 4) {
            TextField("", text: $newTagName, prompt: Text("Add Tag"))
                .textFieldStyle(.roundedBorder)
                .font(.callout)
                .focused($isFieldFocused)
                .onSubmit { commitNewTag() }
            standardTagMenu(tags)
                .panelOutlinedContent()
        }
        // 項目は消さず淡色(シークレットウインドウの約束)。
        .disabled(refusal != nil)
    }

    /// 標準の 7 色のタグを足すメニュー。**`Menu` の label に `Text` を入れない**(CLAUDE.md)。名前はタグの実体なので Finder の言語で出す。
    private func standardTagMenu(_ tags: [FinderTag]) -> some View {
        let localization = FinderTagColor.finderLocalization()
        return Menu {
            ForEach(FinderTagColor.menuOrder, id: \.self) { color in
                let name = color.name(localization: localization)
                Button {
                    apply(.add(name: name))
                } label: {
                    Label {
                        Text(verbatim: name)
                    } icon: {
                        Image(nsImage: HomeInspectorTagDot.menuImage(for: color))
                    }
                    .labelStyle(.titleAndIcon)
                }
                .disabled(tags.contains { $0.hasName(name) })
            }
        } label: {
            Image(systemName: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add Standard Tag")
    }

    private func commitNewTag() {
        let name = newTagName
        newTagName = ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        apply(.add(name: name))
    }

    private func apply(_ edit: FinderTagEdit) {
        guard refusal == nil else {
            // 古い画面から押された(描き直しの前に切り替わった)。何も起きないまま黙らない。
            UserFeedback.beep()
            return
        }
        let allowsEditing = allowsEditing
        let preferences = preferences
        let model = model
        model.apply(edit) {
            HomeInspectorTagsModel.refusal(
                allowsEditing: allowsEditing, refusesFileChanges: preferences.refusesFileChanges, location: model.location
            )
        }
    }

    // MARK: - 案内

    @ViewBuilder
    private var note: some View {
        if let failure = model.applyError {
            message(applyErrorText(failure))
        } else if let refusal, let text = refusalText(refusal) {
            message(text)
        }
    }

    private func message(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelOutlinedContent()
    }

    private func refusalText(_ refusal: HomeInspectorTagsModel.EditRefusal) -> String? {
        switch refusal {
        // 窓ごと見るだけなので、欄ごとに理由を出さない(docs/14「インスペクタ」)。
        case .privateWindow: nil
        case .readOnlyMode: String(localized: "Tags can’t be changed in read-only mode.", language: locale)
        case .networkVolume: String(localized: "Tags on network volumes can only be viewed.", language: locale)
        case .notWritable: String(localized: "This item’s tags can’t be changed.", language: locale)
        }
    }

    private func unavailableText(_ reason: HomeInspectorTagsModel.Unavailable) -> String {
        switch reason {
        case .denied: String(localized: "qooViewer doesn’t have access to this item’s tags.", language: locale)
        case .corrupted: String(localized: "This item’s tag data is damaged, so it can’t be shown.", language: locale)
        case .notFound, .failed: String(localized: "This item’s tags couldn’t be read.", language: locale)
        }
    }

    private func applyErrorText(_ failure: FinderTagStore.WriteError) -> String {
        let summary = String(localized: "The tags couldn’t be changed.", language: locale)
        if case .failed(let code) = failure {
            return "\(summary) \(String(cString: strerror(code)))"
        }
        return summary
    }
}

/// タグの色の丸。
private struct HomeInspectorTagDot: View {
    let color: FinderTagColor?

    var body: some View {
        if let color, let fill = Self.nsColor(color) {
            Circle().fill(Color(nsColor: fill)).frame(width: 9, height: 9)
        } else {
            // 色無しのタグ(Finder の一覧も輪郭だけ)。
            Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 9, height: 9)
        }
    }

    /// Finder の色(`fileLabelColors` の位置が色番号)。
    static func nsColor(_ color: FinderTagColor) -> NSColor? {
        let colors = NSWorkspace.shared.fileLabelColors
        return colors.indices.contains(color.rawValue) ? colors[color.rawValue] : nil
    }

    /// メニューの項目の丸(メニューは SwiftUI の図形を描かないので画像にする。テンプレートにしない ―― 色が消える)。
    static func menuImage(for color: FinderTagColor) -> NSImage {
        let fill = nsColor(color) ?? .secondaryLabelColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
