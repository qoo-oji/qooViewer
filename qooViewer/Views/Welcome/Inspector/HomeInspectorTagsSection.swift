import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// インスペクタがタグを変えた(同じ項目を見ているほかのウインドウのインスペクタが読み直す)。`object` は変えたパス。
    static let finderTagsDidChange = Notification.Name("qooViewer.finderTagsDidChange")
}

/// タグを読む相手。
nonisolated struct HomeInspectorTagTarget: Hashable, Sendable {
    var url: URL
    /// コレクションの本のブックマーク(許可したフォルダの外の本は、このスコープの中でしか読めない)。
    var bookmark: Data?
    /// ファイルブラウザの項目なら、いま見ているフォルダ。利用者が入っていない場所として、TCC の保護下は読まない(docs/15「サンドボックスと TCC の約束」)。
    /// スマートライブラリの対象フォルダとコレクションの本は利用者が選んだ場所なので nil。
    var browsed: Browsed?

    struct Browsed: Hashable, Sendable {
        var currentFolder: URL?
    }

    /// 同じ項目か(ブックマークの更新・見ているフォルダの移動では、読み込み中に戻さない・打ちかけの名前を確定しない)。
    func isSameItem(as other: HomeInspectorTagTarget) -> Bool {
        url == other.url
    }
}

/// ネットワーク越しのタグの読み(**アプリ全体で 1 度に 1 本**)。`withDeadline` は待つのをやめるだけで I/O は続き、`FileIO` は投入ごとに
/// スレッドを起こすので、眠っている NAS で選び直すたびに 1 本ずつ塞いでいた。待っている頼みは自分より新しい頼みが来たら降りる
/// (`isStillWanted`)ので、走っている 1 本が返った後に読むのは最新の頼みだけ。節は本とそれ以外で作り直される(`@StateObject` が別になる)ので、節ごとでなく共有する。
/// ローカルの項目はここを通らない(応答しない共有に待たされない)。
@MainActor
final class HomeInspectorRemoteTagReads {
    static let shared = HomeInspectorRemoteTagReads()
    private var running: Task<Void, Never>?

    /// - Returns: 読んだ結果。順番が来る前に要らなくなった・取り消されたら nil。
    func perform<T: Sendable>(
        isStillWanted: @MainActor () -> Bool, _ body: @escaping @Sendable () -> T
    ) async -> T? {
        while let running {
            await running.value
            guard !Task.isCancelled, isStillWanted() else { return nil }
        }
        // 呼び出し側の取り消し・期限は読みへ伝えない(止まらない I/O が返るまで、次を走らせないため)。
        let read = Task { await FileIO.perform(body) }
        running = Task { [weak self] in
            _ = await read.value
            self?.running = nil
        }
        return await read.value
    }
}

/// インスペクタの節の状態(2026-11-03)。読むのも書くのも `FileIO` の上で、書くのは 1 つずつ順に。
@MainActor
final class HomeInspectorTagsModel: ObservableObject {
    /// 読めなかった理由(「タグ無し」とは区別して見せる)。
    enum Unavailable: Equatable {
        case notFound, denied, corrupted, failed
        /// 利用者が入っていない TCC の保護下なので読まなかった。
        case protectedLocation
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
        /// 「ファイルブラウザを有効にする」が OFF(`refusesFileChanges` は読み取り専用と同じ扱いだが、読み取り専用の設定はそのファイルブラウザの設定にあり、
        /// 切っていても「読み取り専用モード」と出すと本当の理由が分からない)。
        case fileBrowserOff
        /// ネットワークボリューム(利用者の指定で見るだけ)。
        case networkVolume
        /// 読み取り専用のボリューム・書き込み権限が無い・ボリュームそのもの。
        case notWritable
    }

    @Published private(set) var content: Content = .loading
    @Published private(set) var location: FinderTagStore.Location?
    /// 最後の変更に失敗した理由。次に変更できるまで出しておく(相手が変わったら消える)。
    @Published private(set) var applyError: FinderTagStore.WriteError?

    /// 画面が見せている相手(最後に読み始めた相手)。
    private(set) var target: HomeInspectorTagTarget?
    /// 最後に読めた相手とその場所。相手が変わっても次が読めるまで残す(選び直す前の項目へ、打ちかけの名前を確定できるように)。
    private var lastRead: (target: HomeInspectorTagTarget, location: FinderTagStore.Location)?
    /// 読み直しの番号(古い読み込みの結果で新しい表示を上書きしない)。
    private var readGeneration = 0
    /// 変更は順に 1 つずつ(続けて足したときに、前の変更を読まないまま書かない)。
    private var lastApply: Task<Void, Never>?

    /// 標準の色のメニューに出す名前の言語(`FinderTagColor.finderLocalization`。節を作るときに 1 回だけ引く ―― 設定と言語の照合なので、
    /// 欄に 1 文字打つたびの描き直しで引かない)。
    let finderLocalization = FinderTagColor.finderLocalization()

    private let remoteReads: HomeInspectorRemoteTagReads
    /// 読む直前に `FileIO` の上で呼ばれる(**テストのための口**: 応答しない共有の代わりに待たせ、読みの本数を数える)。
    private let beforeRead: @Sendable (HomeInspectorTagTarget) -> Void
    /// 読まない場所(`DirectoryProbe`。**テストは自分の作業フォルダを渡す**: テストホストの一時フォルダは既定の一覧では保護下)。
    private let protectedPrefixes: [String]
    private let categoryPrefixes: Set<String>

    init(
        remoteReads: HomeInspectorRemoteTagReads? = nil,
        beforeRead: @escaping @Sendable (HomeInspectorTagTarget) -> Void = { _ in },
        protectedPrefixes: [String] = DirectoryProbe.protectedPrefixes,
        categoryPrefixes: Set<String> = DirectoryProbe.categoryProtectedPrefixes
    ) {
        self.remoteReads = remoteReads ?? .shared
        self.beforeRead = beforeRead
        self.protectedPrefixes = protectedPrefixes
        self.categoryPrefixes = categoryPrefixes
    }

    /// 応答しない共有で待ち続けない。
    static let readLimit: Duration = .seconds(10)

    /// `target` を読む(変わったときは読み終わるまで「読み込み中」、同じ項目の読み直しなら今の表示のまま)。
    func load(_ target: HomeInspectorTagTarget) async {
        if self.target?.isSameItem(as: target) != true {
            content = .loading
            location = nil
            applyError = nil
        }
        self.target = target
        readGeneration &+= 1
        let generation = readGeneration
        // ネットワーク越しかはリンクを辿ってから決める(`~/nas → /Volumes/NAS` の下は字面ではローカル)。ここでは共有に触らない。
        let url = target.url
        let isRemote = await FileIO.perform { FinderTagStore.leadsToNetworkVolume(url) }
        guard !Task.isCancelled, generation == readGeneration else { return }
        // ネットワーク越しは矢印キーで選び続ける間に読まない(眠っている NAS で 1 回ごとに `FileIO` のスレッドを塞ぐ)。
        if isRemote {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, generation == readGeneration else { return }
        }
        let (beforeRead, remoteReads) = (beforeRead, remoteReads)
        let (prefixes, categories) = (protectedPrefixes, categoryPrefixes)
        let read: @Sendable () -> ReadOutcome = {
            beforeRead(target)
            return Self.read(target, protectedPrefixes: prefixes, categoryPrefixes: categories)
        }
        let outcome: ReadOutcome? = try? await FileIO.withDeadline(Self.readLimit) { [weak self] () -> ReadOutcome? in
            guard isRemote else { return await FileIO.perform(read) }
            return await remoteReads.perform(isStillWanted: { [weak self] in self?.readGeneration == generation }, read)
        }
        guard !Task.isCancelled, generation == readGeneration, self.target == target else { return }
        guard let outcome else {
            content = .unavailable(.failed)
            return
        }
        location = outcome.location
        if let location = outcome.location { lastRead = (target, location) }
        switch outcome.reading {
        case nil: content = .unavailable(.protectedLocation)
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

    /// `target` の読めている場所(読めていなければ nil)。
    func location(for target: HomeInspectorTagTarget) -> FinderTagStore.Location? {
        guard let lastRead, lastRead.target.isSameItem(as: target) else { return nil }
        return lastRead.location
    }

    /// 変更する。断る条件は入口で見て、順番が来たときにも見直す(待っている間に読み取り専用へ切り替わりうる)。
    ///
    /// **`refusal` に渡す場所は受け付けたときの `to` のもの**。順番を待つ間に別の項目を選ぶと `location` は次の項目のもの(読み終わるまでは nil)になるので、
    /// それで判定すると前の項目への変更を黙って捨てていた。
    /// - Parameters:
    ///   - to: 変更する相手(nil なら画面が見せている相手)。
    ///   - onLateFailure: 別の項目を選んだ後に失敗したとき(その項目の欄はもう無いので、呼ぶ側が別の形で知らせる)。
    /// - Returns: 書き終わるまでの Task(テストが待つ)。断ったら nil。
    @discardableResult
    func apply(
        _ edit: FinderTagEdit, to explicitTarget: HomeInspectorTagTarget? = nil,
        refusal: @escaping @MainActor (FinderTagStore.Location?) -> EditRefusal?,
        onLateFailure: @escaping @MainActor (HomeInspectorTagTarget) -> Void = { _ in }
    ) -> Task<Void, Never>? {
        guard let target = explicitTarget ?? self.target else { return nil }
        let location = self.location(for: target)
        guard refusal(location) == nil else {
            // 古い画面から押された(描き直しの前に切り替わった)。何も起きないまま黙らない。
            UserFeedback.beep()
            return nil
        }
        let previous = lastApply
        // 弱く持たない: 窓を閉じるときの確定(`onDisappear`)は、節が消えた後でも最後まで書く。
        let task = Task {
            await previous?.value
            guard refusal(location) == nil else {
                UserFeedback.beep()
                return
            }
            do {
                let tags = try await FileIO.perform { try Self.write(edit, target: target) }
                NotificationCenter.default.post(name: .finderTagsDidChange, object: target.url.path)
                guard self.target?.isSameItem(as: target) == true else { return }
                self.readGeneration &+= 1
                self.applyError = nil
                self.content = .tags(tags)
            } catch {
                guard self.target?.isSameItem(as: target) == true else {
                    UserFeedback.beep()
                    onLateFailure(target)
                    return
                }
                self.applyError = error as? FinderTagStore.WriteError ?? .failed(EIO)
                // 読めなかった・効かなかったので、ファイルの今の値を見せ直す。
                await self.reload()
            }
        }
        lastApply = task
        return task
    }

    /// 変更できない理由(できるなら nil)。読み終わるまでは断る(読めていない一覧の上に足さない)。
    /// - Parameter fileBrowserEnabled: `refusesFileChanges` の理由の読み分けにだけ使う。
    static func refusal(
        allowsEditing: Bool, refusesFileChanges: Bool, fileBrowserEnabled: Bool, location: FinderTagStore.Location?
    ) -> EditRefusal? {
        if !allowsEditing { return .privateWindow }
        guard let location else { return .notWritable }
        // 利用者の指定はボリュームの種類なので、読み取り専用モードより先に見る(モードを切っても変えられない、と分かるように)。
        if location.isOnNetworkVolume { return .networkVolume }
        if refusesFileChanges { return fileBrowserEnabled ? .readOnlyMode : .fileBrowserOff }
        if location.isMountPoint || location.isUnwritable { return .notWritable }
        return nil
    }

    // MARK: - FileIO の上

    nonisolated private struct ReadOutcome: Sendable {
        /// 読まなかった(TCC の保護下)なら nil。
        var reading: FinderTagStore.Reading?
        var location: FinderTagStore.Location?
    }

    /// **ブロッキングする。** ファイルブラウザの項目は、リンク(途中の段も)を**段ごとにパスの字面で確かめてから** lstat する
    /// (`FileBrowserLinkResolver.followSymbolicLinks`)。先に `access`・`getxattr` で触ると、触ること自体が TCC の問い合わせになりうる。
    nonisolated private static func read(
        _ target: HomeInspectorTagTarget, protectedPrefixes: [String], categoryPrefixes: Set<String>
    ) -> ReadOutcome {
        withAccess(target) { url in
            let followed = FileBrowserLinkResolver.followSymbolicLinks(url) { candidate in
                guard let browsed = target.browsed else { return true }
                return !DirectoryProbe.isOffLimitsUnentered(
                    candidate, from: browsed.currentFolder, prefixes: protectedPrefixes, categoryPrefixes: categoryPrefixes
                )
            }
            switch followed {
            case .target(let real):
                return ReadOutcome(reading: FinderTagStore.read(at: real), location: FinderTagStore.location(of: real))
            case .refused:
                return ReadOutcome(reading: nil, location: nil)
            case .unresolvable:
                return ReadOutcome(reading: .failed(ELOOP), location: nil)
            }
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
/// - ファイルブラウザの項目は TCC の保護下を読まない(`HomeInspectorTagTarget.browsed`。見ている場所と同じデスクトップ等の中を除く)
/// - 色は標準の 7 色から足す(`FinderTagColor`。Finder のタグの一覧はサンドボックスの中から読めないので、使っている名前の候補は出せない)
///
/// すりガラス面: 見出し・案内・メニューのアイコンは `.panelOutlinedContent()`。チップは不透明な地を持つので何も掛けない。
struct HomeInspectorTagsSection: View {
    let target: HomeInspectorTagTarget
    let allowsEditing: Bool
    /// 使える幅(長い名前のチップを収める)。
    let width: CGFloat

    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var appState: AppState
    @Environment(\.locale) private var locale
    @StateObject private var model = HomeInspectorTagsModel()
    @State private var newTagName = ""
    @FocusState private var isFieldFocused: Bool

    private var refusal: HomeInspectorTagsModel.EditRefusal? {
        refusal(at: model.location)
    }

    private func refusal(at location: FinderTagStore.Location?) -> HomeInspectorTagsModel.EditRefusal? {
        HomeInspectorTagsModel.refusal(
            allowsEditing: allowsEditing, refusesFileChanges: preferences.refusesFileChanges,
            fileBrowserEnabled: preferences.fileBrowserFeatureEnabled, location: location
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
        // 打ちかけの名前を、選び直し・ウインドウを閉じるときに黙って捨てない(メタデータの欄と同じ)。次の項目へは持ち越さず、**打っていた項目へ**確定する
        // (SwiftUI の一覧では、別の本を選んでも欄から焦点が外れるとは限らない)。同じ項目のブックマークが更新されただけなら打ち続けられる。
        .onChange(of: target) { old, new in
            if !old.isSameItem(as: new) { commitNewTag(to: old) }
        }
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
            // 変更できない間も消さず淡色(シークレットウインドウの約束。切り替わってもチップの幅が変わらない)。
            Button {
                apply(.remove(name: tag.name))
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(refusal == nil ? HierarchicalShapeStyle.secondary : .quaternary)
            }
            .buttonStyle(.plain)
            .disabled(refusal != nil)
            .help(removeTitle(tag.name))
            .accessibilityLabel(removeTitle(tag.name))
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
        let localization = model.finderLocalization
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

    /// - Parameter target: 確定する相手(nil なら画面が見せている相手。焦点が外れるのと選び直しが同じ更新で届いても、`self.target` はもう次の項目なので使わない)。
    private func commitNewTag(to target: HomeInspectorTagTarget? = nil) {
        let name = newTagName
        newTagName = ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        apply(.add(name: name), to: target)
    }

    private func apply(_ edit: FinderTagEdit, to target: HomeInspectorTagTarget? = nil) {
        // この節が消えた後(窓を閉じるときの確定)にも走る。節(View)は捕まえない。
        let (allowsEditing, preferences, locale, appState) = (allowsEditing, preferences, locale, appState)
        model.apply(edit, to: target) { location in
            HomeInspectorTagsModel.refusal(
                allowsEditing: allowsEditing, refusesFileChanges: preferences.refusesFileChanges,
                fileBrowserEnabled: preferences.fileBrowserFeatureEnabled, location: location
            )
        } onLateFailure: { [weak appState] failed in
            appState?.postViewerNotice(String(
                format: String(localized: "The tags of “%@” couldn’t be changed.", language: locale), failed.url.lastPathComponent
            ))
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
        case .fileBrowserOff: String(localized: "Tags can’t be changed while the file browser is turned off.", language: locale)
        case .networkVolume: String(localized: "Tags on network volumes can only be viewed.", language: locale)
        case .notWritable: String(localized: "This item’s tags can’t be changed.", language: locale)
        }
    }

    private func unavailableText(_ reason: HomeInspectorTagsModel.Unavailable) -> String {
        switch reason {
        case .denied: String(localized: "qooViewer doesn’t have access to this item’s tags.", language: locale)
        case .protectedLocation: String(localized: "Tags aren’t read for items in this protected location.", language: locale)
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

    /// Finder の色(`fileLabelColors` の位置が色番号)。チップと色の数だけ描き直しのたびに引かない。
    private static let labelColors = NSWorkspace.shared.fileLabelColors

    static func nsColor(_ color: FinderTagColor) -> NSColor? {
        labelColors.indices.contains(color.rawValue) ? labelColors[color.rawValue] : nil
    }

    /// メニューの項目の丸(メニューは SwiftUI の図形を描かないので画像にする。テンプレートにしない ―― 色が消える)。色ごとに 1 枚を使い回す。
    private static let menuImages: [FinderTagColor: NSImage] = Dictionary(
        uniqueKeysWithValues: FinderTagColor.allCases.map { color in
            let fill = nsColor(color) ?? .secondaryLabelColor
            let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
                fill.setFill()
                NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5)).fill()
                return true
            }
            image.isTemplate = false
            return (color, image)
        }
    )

    static func menuImage(for color: FinderTagColor) -> NSImage {
        menuImages[color] ?? NSImage()
    }
}
