import Foundation
import CoreGraphics

/// ネットワークボリューム上の書庫を、読み込み層(`StagedFileSource`)を通して読むかどうかの判定。
///
/// ■ 判定(docs/plans/network-volume-study.md §4.1)
/// - 書庫ファイルが**ネットワーク越しのボリューム**にある(マウントの `MNT_LOCAL` が立っていない。`MountTable.isRemote`)。
///   SMB・AFP・NFS・WebDAV・macFUSE の既定などが当たる。ファイルシステムの型名の許可リストにはしない(FSKit のモジュールは
///   型名を自分で名乗る)。Apple の推奨も `MNT_LOCAL`(Q&A NW09)。マウント表は `getmntinfo` で読むので、ネットワークの
///   共有そのものには触らない(応答しない共有でも止まらない)。
/// - ローカル・外付けのディスクは今までどおり各ライブラリが直接開く(USB の HDD は遅いが、往復は短く帯域はある)。
/// - 隠し設定 `qooViewer.pref.networkVolumeStagedReading` を false にすると、ネットワーク上でも従来の読み方になる
///   (不具合のときの逃げ道。既定は true。保存データの書き出しには接頭辞で自動的に入る)。
///
/// テストは実物のネットワークボリュームを使えないので、自分の作業フォルダを `treatAsRemoteForTesting` で「ネットワーク上」に
/// 見立てる。フォルダごとの登録なので、並行して走るほかのテストには影響しない。パスは `standardizedFileURL` で揃えない
/// (先頭の `/private` を外すかどうかが実在に依存する。docs/13)。登録する側と開く側が同じ組み立て方のパスを使う。
nonisolated enum NetworkVolumeReading {
    static let preferenceKey = "qooViewer.pref.networkVolumeStagedReading"

    private static let testLock = NSLock()
    nonisolated(unsafe) private static var testRemoteFolders: Set<String> = []

    /// `url` の書庫を読み込み層で読むか。
    static func usesStagedReading(for url: URL) -> Bool {
        if isTreatedAsRemoteForTesting(url) { return true }
        if UserDefaults.standard.object(forKey: preferenceKey) as? Bool == false { return false }
        return MountTable.current().isRemote(url)
    }

    /// 読み込み層(同じファイルなら共有)。使わない・作れないなら nil(呼び出し側は従来どおり直接開く)。
    ///
    /// 作れないのは、一時ファイルを置く場所の空きが本の大きさに足りないとき(裏の取り寄せで本 1 冊ぶんを書くため)と、
    /// ファイルを開けないとき。
    static func stagedSource(for url: URL, startsBackgroundFill: Bool) -> StagedFileSource? {
        guard usesStagedReading(for: url) else { return nil }
        guard hasRoomForStaging(url) else { return nil }
        return try? StagedFileRegistry.shared.source(for: url, startsBackgroundFill: startsBackgroundFill)
    }

    /// 一時ファイルの置き場所に、本の大きさ+余裕(1GB)の空きがあるか。分からなければ「ある」とみなす
    /// (大きさの問い合わせに失敗する書庫は、どのみち開く段階で失敗する)。
    private static func hasRoomForStaging(_ url: URL) -> Bool {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return true }
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values?.volumeAvailableCapacity else { return true }
        return Int64(available) >= Int64(st.st_size) + 1 << 30
    }

    // MARK: - テスト

    /// `folder` の下の書庫を「ネットワーク上」とみなす(テスト専用)。終わったら `endTreatingAsRemoteForTesting`。
    static func treatAsRemoteForTesting(_ folder: URL) {
        testLock.lock()
        testRemoteFolders.insert(MountTable.normalized(folder.path))
        testLock.unlock()
    }

    static func endTreatingAsRemoteForTesting(_ folder: URL) {
        testLock.lock()
        testRemoteFolders.remove(MountTable.normalized(folder.path))
        testLock.unlock()
    }

    private static func isTreatedAsRemoteForTesting(_ url: URL) -> Bool {
        testLock.lock()
        defer { testLock.unlock() }
        guard !testRemoteFolders.isEmpty else { return false }
        let path = MountTable.normalized(url.path)
        return MountTable.path(path, isAtOrUnderAnyOf: testRemoteFolders)
    }
}

/// ディスク上の PDF を開く。**ネットワークボリューム上なら読み込み層を通して読む**(2026-09-25)。
///
/// `CGPDFDocument(url)` はファイルを mmap して読む(ローカルで実測。docs/plans/network-volume-study.md §1.2)。ネットワーク上の
/// ファイルを mmap すると、読むところごとにページフォルト 1 回ぶんの往復を待ち、接続が切れるとバスエラーで落ちうる
/// (Apple の「Mapping Files Into Memory」)。ネットワーク上では、読み込み層の上に `CGDataProvider` の直接読み出しを置いて
/// 開く ―― PDF は末尾の相互参照表からあちこちを読むので、書庫と同じく「一度取り寄せたところは手元から」が効く。
/// ローカルの PDF は従来どおり URL から開く。
///
/// - Parameter stagesWholeFile: 残りを裏で取り寄せ始める(ビューアで本として開くときだけ。makeArchiveReader と同じ)。
nonisolated func openPDFDocument(at url: URL, stagesWholeFile: Bool = false) -> CGPDFDocument? {
    if let source = NetworkVolumeReading.stagedSource(for: url, startsBackgroundFill: stagesWholeFile),
       let provider = stagedDataProvider(source) {
        return CGPDFDocument(provider)
    }
    return CGPDFDocument(url as CFURL)
}

/// 読み込み層を `CGDataProvider`(位置を指定して読む直接読み出し)に包む。提供役が読み込み層を保持し、手放すときに解放する。
private nonisolated func stagedDataProvider(_ source: StagedFileSource) -> CGDataProvider? {
    var callbacks = CGDataProviderDirectCallbacks(
        version: 0,
        getBytePointer: nil,
        releaseBytePointer: nil,
        getBytesAtPosition: { info, buffer, position, count in
            guard let info else { return 0 }
            let source = Unmanaged<StagedFileSource>.fromOpaque(info).takeUnretainedValue()
            // 読めなければ 0(CoreGraphics はその部分を読めなかったものとして扱う。ページが描けないだけで落ちない)。
            guard position >= 0, let data = try? source.read(at: UInt64(position), count: count) else { return 0 }
            data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
            return data.count
        },
        releaseInfo: { info in
            guard let info else { return }
            Unmanaged<StagedFileSource>.fromOpaque(info).release()
        }
    )
    let info = Unmanaged.passRetained(source).toOpaque()
    guard let provider = CGDataProvider(directInfo: info, size: off_t(source.size), callbacks: &callbacks) else {
        Unmanaged<StagedFileSource>.fromOpaque(info).release()
        return nil
    }
    return provider
}
