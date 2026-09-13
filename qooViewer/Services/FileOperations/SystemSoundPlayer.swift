import AudioToolbox
import Foundation

/// ファイル操作が済んだときに鳴らす macOS 標準の UI サウンド(改善要望7 段階4 の追加要望、2026-09-13)。
/// qooLibrary の `SystemSoundEffect` / `SystemSoundPlayer` を写したもの。
///
/// ■ 音源は macOS 同梱のシステムサウンドをそのまま使う(自前の音源を持たない)
/// Finder と同じ音が鳴ることが目的なので、写しを持つと OS 側で音が差し替わったときに追随できない。
///
/// ■ どの音がどの操作か(qooLibrary で Finder を逆アセンブルして特定し、ユーザーが耳で確認したもの)
/// - ゴミ箱に入れる → `dock/drag to trash.aif`(SystemSoundID 16 相当)。**`finder/move to trash.aif` は
///   名前に反して Finder からは呼ばれていない** ―― ファイル名で選ぶと間違える。
/// - 完全削除 → `finder/empty trash.aif`(13 相当。Finder の「ゴミ箱を空にする」の、取り返しがつかない音)。
/// - コピー・移動の完了 → `system/Volume Mount.aif`(1 相当。Finder もペーストで鳴らす汎用の完了音)。
///
/// 列挙子は**このアプリでの意味**で名付けている(ファイル名ではない)。
nonisolated enum SystemSoundEffect: String, Sendable, CaseIterable {
    case moveToTrash
    case permanentDelete
    case operationComplete

    /// macOS が UI サウンドを置いている場所。数値の SystemSoundID を直接渡す手もあるが、その対応表は
    /// 非公開なので、自己文書化されるパスで指す(qooLibrary でのユーザー判断)。
    private static let root = URL(
        fileURLWithPath: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds",
        isDirectory: true
    )

    var fileURL: URL {
        switch self {
        case .moveToTrash:
            Self.root.appendingPathComponent("dock").appendingPathComponent("drag to trash.aif")
        case .permanentDelete:
            Self.root.appendingPathComponent("finder").appendingPathComponent("empty trash.aif")
        case .operationComplete:
            Self.root.appendingPathComponent("system").appendingPathComponent("Volume Mount.aif")
        }
    }
}

/// テストで差し替える境界。
nonisolated protocol SystemSoundPlaying: Sendable {
    func play(_ effect: SystemSoundEffect) async
}

/// `SystemSoundEffect` を実際に鳴らす。
///
/// ■ システム設定「ユーザインターフェイスのサウンドエフェクトを再生」を自動的に尊重する
/// `AudioServicesCreateSystemSoundID` で登録した音は `kAudioServicesPropertyIsUISound` が既定で 1 で、
/// 設定がオフなら AudioServices 側が鳴らさない(qooLibrary 実測)。**アプリに音のオン/オフの設定は持たない**。
///
/// App Sandbox でも追加の entitlement 無しに鳴る(qooLibrary 実測)。
///
/// ■ テスト中は鳴らさない
/// テストホストはこのアプリそのものなので、ゴミ箱のテストのたびに音が鳴る。
actor SystemSoundPlayer: SystemSoundPlaying {
    static let shared = SystemSoundPlayer()

    private let isEnabled: Bool
    /// 登録した SystemSoundID は使い回す(登録は coreaudiod への往復を伴う)。
    private var registered: [SystemSoundEffect: SystemSoundID] = [:]
    /// 登録に失敗した音。**再試行しない**(音源の場所が変わった等の恒久的な原因で、繰り返しても直らない)。
    /// 音が鳴らないだけで操作は成功しているので、利用者には知らせない。
    private var unavailable: Set<SystemSoundEffect> = []

    init(isEnabled: Bool = !RuntimeEnvironment.isRunningTests) {
        self.isEnabled = isEnabled
    }

    func play(_ effect: SystemSoundEffect) {
        guard isEnabled, let id = soundID(for: effect) else { return }
        // 完了は待たない。素の AudioServicesPlaySystemSound はヘッダで「将来非推奨」とされているので、
        // Finder と同じ WithCompletion 版を使う。
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }

    private func soundID(for effect: SystemSoundEffect) -> SystemSoundID? {
        if let id = registered[effect] { return id }
        guard !unavailable.contains(effect) else { return nil }
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(effect.fileURL as CFURL, &id) == noErr else {
            unavailable.insert(effect)
            return nil
        }
        registered[effect] = id
        return id
    }
}
