import Foundation
import Combine

/// メタデータ推測用の3種類のルール(ファイル名フォーマット・巻数フォーマット・除外文字列)を
/// 保持し、UserDefaultsへ永続化する。アプリ全体で1つだけのインスタンスをQooViewerAppが作り、
/// `.environmentObject`で各シーンへ渡す(AppPreferencesと同じ扱い)。
///
/// AppPreferencesへ相乗りさせずに独立したストアにしているのは、
/// - 保存する値が配列(JSONエンコードが必要)で、AppPreferencesの「1プロパティ=1キー、
///   didSetで即保存」という単純な形に収まらないこと
/// - ルールが変わるたびに正規表現へコンパイルし直したものをキャッシュする必要があり
///   (compiledRules)、その責務をAppPreferencesに持ち込みたくないこと
/// の2点による。
///
/// なお、これらは「本ごとのデータ」ではなく環境設定に近い性質のもののため、SwiftDataではなく
/// UserDefaultsに置いている(登録済みのメタデータ本体だけがSwiftData = BookMetadata)。
@MainActor
final class MetadataFormatStore: ObservableObject {
    private enum Keys {
        static let filenameFormats = "qooViewer.metadata.filenameFormats"
        static let volumeRules = "qooViewer.metadata.volumeRules"
        static let exclusionRules = "qooViewer.metadata.exclusionRules"
    }

    /// ファイル名から著者・タイトルを取り出すためのフォーマット(上にあるものが優先)。
    @Published var filenameFormats: [MetadataFilenameFormat] {
        didSet {
            persist(filenameFormats, forKey: Keys.filenameFormats)
            invalidateCompiledRules()
        }
    }
    /// タイトルをシリーズ名と巻数に分離するためのフォーマット(上にあるものが優先)。
    @Published var volumeRules: [VolumeFormatRule] {
        didSet {
            persist(volumeRules, forKey: Keys.volumeRules)
            invalidateCompiledRules()
        }
    }
    /// ファイル名から事前に削るノイズ(正規表現)。
    @Published var exclusionRules: [MetadataExclusionRule] {
        didSet {
            persist(exclusionRules, forKey: Keys.exclusionRules)
            invalidateCompiledRules()
        }
    }

    /// 3種類のルールをまとめてコンパイルしたもの。BookMetadataDeriverはこれを受け取って動く。
    ///
    /// 「メタデータの編集」ウインドウは、一覧の全行(数千件になりうる)に対して推測を走らせる。
    /// 各行ごとに正規表現をコンパイルし直すと、そのコストが行数×ルール数で効いてくるため、
    /// 一度コンパイルした結果をここへ持っておき、ルールが変わったときにだけ捨てる。
    ///
    /// @Publishedにはしていない。@Publishedにしたうえで「ルール変更を受けて再コンパイルし、
    /// 結果を代入する」形にすると、その代入自体が再びobjectWillChangeを流し、変更検知 →
    /// 再コンパイル → 変更検知…という循環になってしまうため。ルール3つがいずれも@Published
    /// なので、ルールが変わればビューは正しく再描画され、そのタイミングでこの計算プロパティが
    /// 新しい値を作り直す。
    var compiledRules: CompiledMetadataRuleSet {
        if let cachedCompiledRules { return cachedCompiledRules }
        let rebuilt = CompiledMetadataRuleSet(
            filenameFormats: filenameFormats, volumeRules: volumeRules, exclusionRules: exclusionRules
        )
        cachedCompiledRules = rebuilt
        return rebuilt
    }

    /// ルールが変わるたびに1増える通し番号。「メタデータの編集」ウインドウが、ファイル名から
    /// 推測した結果のキャッシュを捨てるべきかどうかをこれ1つで判定できるようにするためのもの
    /// (3つのルール配列それぞれの変化をビュー側で個別に監視する必要が無くなる)。
    @Published private(set) var revision = 0

    private var cachedCompiledRules: CompiledMetadataRuleSet?

    private func invalidateCompiledRules() {
        cachedCompiledRules = nil
        revision &+= 1
    }

    init() {
        let defaults = UserDefaults.standard
        // 保存済みの値が無い(初回起動)、または壊れて読めない場合は既定値から始める。
        filenameFormats = Self.load([MetadataFilenameFormat].self, forKey: Keys.filenameFormats, from: defaults)
            ?? MetadataFilenameFormat.defaults
        volumeRules = Self.load([VolumeFormatRule].self, forKey: Keys.volumeRules, from: defaults)
            ?? VolumeFormatRule.defaults
        exclusionRules = Self.load([MetadataExclusionRule].self, forKey: Keys.exclusionRules, from: defaults)
            ?? MetadataExclusionRule.defaults
    }

    // MARK: - 初期化(各編集ダイアログの左下「初期化」ボタン)

    func resetFilenameFormats() { filenameFormats = MetadataFilenameFormat.defaults }
    func resetVolumeRules() { volumeRules = VolumeFormatRule.defaults }
    func resetExclusionRules() { exclusionRules = MetadataExclusionRule.defaults }

    /// JSONインポートでフォーマット定義を丸ごと差し替える場合に使う(3種類まとめて更新する
    /// 経路でも、didSetによる保存とキャッシュ破棄がそれぞれ正しく走る)。
    func replaceAll(
        filenameFormats: [MetadataFilenameFormat],
        volumeRules: [VolumeFormatRule],
        exclusionRules: [MetadataExclusionRule]
    ) {
        self.filenameFormats = filenameFormats
        self.volumeRules = volumeRules
        self.exclusionRules = exclusionRules
    }

    // MARK: - 内部

    private func persist<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func load<T: Decodable>(_ type: T.Type, forKey key: String, from defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
