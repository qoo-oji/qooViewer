import Combine
import SwiftData
import SwiftUI

/// QooViewerAppが起動時に1度だけ生成して持ち続ける、アプリ全体で共有するストア一式。
///
/// ■ なぜ「入れ物」にまとめるのか(メニュー描画崩れの根本対策)
/// 以前はQooViewerAppがこれらを1つずつ@StateObjectとして持っていた。@StateObjectは
/// objectWillChangeを購読するため、**どれか1つの@Publishedが発火するたびにApp全体のbody
/// (全Scene+.commands)が再評価され、AppKitのメニューが作り直されていた** ―― メニューが
/// その値をまったく読んでいなくても、である(実測: リソースモニタの毎秒の計測値の発火だけで、
/// 開いている「表示」メニューが毎秒作り直されていた。ProcessResourceSampler参照)。
/// メニューバーのメニューを開いている最中の作り直しは、macOS 26のメニュー実装では
/// 描画崩れ/NSRangeExceptionクラッシュの条件になる(MenuBarMenuGateの型コメント参照)。
///
/// この型は**何もpublishしない**。ObservableObjectに適合しているのは、@StateObjectとして
/// 保持してもらうことで生成を1回に固定するためだけで、@Publishedプロパティを持たず、
/// objectWillChangeを流す口も無い。そのため個々のストアの発火がAppのbodyへ直接届くことは
/// なくなり、メニューの再構築はMenuBarMenuRefresher(下記)がMenuBarMenuGate経由で流す
/// 1本に束ねられる。
///
/// **新しい共有ストアを追加するときは、@StateObjectをQooViewerAppへ足すのではなく、
/// 必ずここへ足し、allObjectWillChangePublishersにも並べること。** Appへ@StateObjectとして
/// 足すと、そのストアの発火がこの仕組みを素通りして、開いている最中のメニューを作り直して
/// しまう(publishersへの並べ忘れは逆に「メニューの表示が古いまま残る」という目に見える
/// 形で現れるので、壊れ方としては安全側)。
///
/// 各ウインドウ内のビューはこれまでどおり.environmentObjectで個々のストアを購読するため、
/// パネルや一覧の再描画のされ方・タイミングは何も変わらない。
@MainActor
final class AppStores: ObservableObject {
    let preferences: AppPreferences
    let keyBindingStore: KeyBindingStore
    let recentFiles: RecentFilesStore
    let folderAccess: FolderAccessStore
    /// サイドパネルのリソースモニタの計測役。CPU・メモリ・ディスクI/Oはプロセスの値なので
    /// アプリで1つ(ProcessResourceSamplerのコメント参照)。
    let resourceSampler: ProcessResourceSampler
    /// メタデータをファイル名から推測するための3種類のルール(ファイル名フォーマット・
    /// 巻数フォーマット・除外文字列)。UserDefaultsに保存するためModelContextは不要。
    let metadataFormatStore: MetadataFormatStore
    /// 複数ウインドウ/タブに対応するための調整役。詳細はLaunchCoordinator.swiftのコメント参照。
    let launchCoordinator: LaunchCoordinator
    /// お気に入り(階層フォルダ + 登録した本)。RecentFilesStore等と違いSwiftDataで永続化するため、
    /// modelContainerから作ったModelContextを渡して生成する(以下の3つも同じ)。
    let favoritesStore: FavoritesStore
    /// ブックマーク(すべての本を横断)。
    let bookmarkStore: BookmarkStore
    /// ページレイアウト設定(すべての本を横断)。
    let layoutStore: LayoutStore
    /// 書誌メタデータ(著者・タイトル・シリーズ・巻数。すべての本を横断)。
    let metadataStore: BookMetadataStore

    init() {
        // 生成の順序は、QooViewerAppが@StateObjectを個別に持っていた頃の
        // 「宣言時デフォルト値(宣言順)→ init()内のSwiftData系4つ」の順をそのまま保つ。
        preferences = AppPreferences()
        keyBindingStore = KeyBindingStore()
        recentFiles = RecentFilesStore()
        folderAccess = FolderAccessStore()
        resourceSampler = ProcessResourceSampler()
        metadataFormatStore = MetadataFormatStore()
        launchCoordinator = LaunchCoordinator()
        let context = QooViewerApp.modelContainer.mainContext
        favoritesStore = FavoritesStore(modelContext: context)
        bookmarkStore = BookmarkStore(modelContext: context)
        layoutStore = LayoutStore(modelContext: context)
        metadataStore = BookMetadataStore(modelContext: context)
    }

    /// MenuBarMenuRefresherが購読する、全ストアのobjectWillChange。
    /// ストアを増やしたら必ずここにも足すこと(型コメント参照)。
    var allObjectWillChangePublishers: [ObservableObjectPublisher] {
        [
            preferences.objectWillChange,
            keyBindingStore.objectWillChange,
            recentFiles.objectWillChange,
            folderAccess.objectWillChange,
            resourceSampler.objectWillChange,
            metadataFormatStore.objectWillChange,
            launchCoordinator.objectWillChange,
            favoritesStore.objectWillChange,
            bookmarkStore.objectWillChange,
            layoutStore.objectWillChange,
            metadataStore.objectWillChange,
        ]
    }
}

/// ストアのどれかが変わったことを、**メニューバーが安全なタイミングでだけ**Appのbodyへ
/// 伝える中継役。QooViewerAppが@StateObjectとして観測する唯一のオブジェクト。
///
/// AppStores内の全ストアのobjectWillChangeを購読し、
/// 1. 同じランループターン内の連続した発火を1回にまとめ、
/// 2. MenuBarMenuGate経由でrevisionを進める ―― メニューバーのメニューが開いている間は
///    閉じるまで保留され、閉じた1ランループ後に1回だけ反映される。
///
/// これにより「メニューの内容に影響しうる発火を、メニューを開いている最中にAppのbodyへ
/// 届けない」というMenuBarMenuGateの原則が、個々のストアの実装に頼らず**構造として**
/// 保証される。ストア側が自分の発火タイミングを気にする必要はもう無い(既存のストア内の
/// ゲート経由の発火はそのまま残してある ―― ウインドウ内の一覧の描き替えまで保留したい、
/// というそれぞれの理由が別にあるため。各ストアのコメント参照)。
///
/// revisionの値そのものは誰も読まない。@Publishedの発火だけが目的で、発火を受けた
/// SwiftUIがAppのbodyを再評価し、.commandsが各ストアの**その時点の最新値**を読み直す。
///
/// なおAppのbodyの再評価要因はこれで全てではなく、FocusedValues(qooViewerAppState /
/// qooViewerMenuCheckmarkState)の変化でも再評価される。そちらはAppState側で
/// ゲート経由の値だけを公開することで同じ原則を守っている(MenuCheckmarkStateのコメント参照)。
@MainActor
final class MenuBarMenuRefresher: ObservableObject {
    /// 「どれかのストアが変わった」ことだけを表す通し番号。値は読まれない(型コメント参照)。
    @Published private(set) var revision: UInt64 = 0
    private var subscriptions: [AnyCancellable] = []
    /// 次のランループターンでのrevision更新を予約済みか(同一ターン内の発火をまとめる)。
    private var isBumpScheduled = false

    init(observing stores: AppStores) {
        for publisher in stores.allObjectWillChangePublishers {
            publisher
                .sink { [weak self] _ in
                    // 全ストアが@MainActorなので発火は常にメインスレッド
                    // (違反していればここで即座に落ちて気付ける)。
                    MainActor.assumeIsolated {
                        self?.scheduleBump()
                    }
                }
                .store(in: &subscriptions)
        }
    }

    private func scheduleBump() {
        guard !isBumpScheduled else { return }
        isBumpScheduled = true
        // objectWillChangeは値が変わる**前**に飛ぶため、1ランループ跨いでから進める。
        // これでbodyの再評価は必ず変更後の値を読み、かつ同じターン内の複数ストアの発火が
        // 1回の再評価にまとまる。
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isBumpScheduled = false
                MenuBarMenuGate.shared.run("MenuBarMenuRefresher.revision") { [weak self] in
                    self?.revision &+= 1
                }
            }
        }
    }
}
