import Foundation

/// 圧縮・展開の段取り(改善要望7 段階 6、2026-09-14)。ブロッキングする仕事は ZipCompressor / ArchiveExtractor に追い出してあり、
/// どれも `FileIO.perform` の中で走る(FileOperationService の型コメント)。
extension FileOperationService {
    /// `items`(同じフォルダの項目)を `folder` に zip で固める。中止なら nil。
    ///
    /// **1 バイトも書く前に**、書けるか・空き容量(入れるファイルの合計。無圧縮で入れるものがほとんどなので上限の見積りになる)を見る。
    func compress(
        _ items: [URL], into folder: URL, baseName: String, fileExtension: String,
        progress: ProgressSink?, cancellation: Cancellation
    ) async throws -> TransferReceipt? {
        guard !items.isEmpty else { return nil }
        let placed: URL? = try await FileIO.perform(cancellation: cancellation) {
            guard Self.itemExists(at: folder) else { throw FileOperationError.itemMissing(folder) }
            try FileOperationPreflight.checkWritable(folder)
            let sources = try ZipCompressor.collect(items)
            let total = sources.reduce(Int64(0)) { $0 + $1.size }
            // 見せる「必要な量」は余裕を足した値(FileOperationService.preflight のコメント)。
            let needed = total + FileOperationPreflight.freeSpaceMargin(at: folder)
            if let available = FileOperationPreflight.availableCapacity(at: folder), available < needed {
                throw FileOperationError.insufficientFreeSpace(required: needed, available: available, destination: folder)
            }
            let tracker = ProgressTracker(
                sink: progress, totalBytes: total, totalItems: sources.filter { $0.kind == .file }.count
            )
            tracker.begin()
            return try ZipCompressor.compress(
                sources, into: folder, baseName: baseName, fileExtension: fileExtension, tracker: tracker
            )
        }
        guard let placed else { return nil }
        let identity = await FileIO.perform { FileIdentity.of(placed) }
        return TransferReceipt(source: items[0], destination: placed, replacedItemInTrash: nil, identity: identity)
    }

    /// `archives` を 1 つずつ `folder` へ展開する。1 冊が失敗しても残りは続ける(失敗は結果に並べる)。
    ///
    /// 全部を先に開いて一覧と限度を確かめ、合計の空き容量を見てから書き始める。1 冊しか無く、それが開けなければ投げる。
    func extract(
        _ archives: [URL], into folder: URL, placement: ArchiveExtractor.Placement,
        limits: ArchiveExtractionLimits = .standard, progress: ProgressSink?, cancellation: Cancellation
    ) async throws -> ArchiveExtractionOutcome {
        var outcome = ArchiveExtractionOutcome()
        guard !archives.isEmpty else { return outcome }
        let prepared = try await FileIO.perform(cancellation: cancellation) { () -> [Result<ArchiveExtractor.Prepared, any Error>] in
            guard Self.itemExists(at: folder) else { throw FileOperationError.itemMissing(folder) }
            try FileOperationPreflight.checkWritable(folder)
            var results: [Result<ArchiveExtractor.Prepared, any Error>] = []
            for archive in archives {
                if Cancellation.isRequestedInCurrentScope { throw CancellationError() }
                results.append(Result { try ArchiveExtractor.prepare(archive, limits: limits) })
            }
            let total = results.reduce(UInt64(0)) { sum, result in
                guard case let .success(item) = result else { return sum }
                let (added, overflow) = sum.addingReportingOverflow(item.plan.declaredTotalBytes)
                return overflow ? .max : added
            }
            let needed = total &+ UInt64(FileOperationPreflight.freeSpaceMargin(at: folder))
            if limits.checksFreeSpace, let available = FileOperationPreflight.availableCapacity(at: folder),
               UInt64(max(available, 0)) < needed {
                throw FileOperationError.insufficientFreeSpace(
                    required: Int64(clamping: needed), available: available, destination: folder
                )
            }
            return results
        }
        if archives.count == 1, case let .failure(error) = prepared[0] { throw error }

        let ready = prepared.compactMap { try? $0.get() }
        let tracker = ProgressTracker(
            sink: progress,
            totalBytes: Int64(clamping: ready.reduce(UInt64(0)) { $0 &+ $1.plan.declaredTotalBytes }),
            totalItems: ready.reduce(0) { $0 + $1.plan.fileCount }
        )
        tracker.begin()
        var firstError: (any Error)?
        for (index, result) in prepared.enumerated() {
            let archive = archives[index]
            if cancellation.isRequested || Task.isCancelled {
                outcome.wasCancelled = true
                break
            }
            let item: ArchiveExtractor.Prepared
            switch result {
            case let .success(value):
                item = value
            case let .failure(error):
                firstError = firstError ?? error
                outcome.failures.append(FailedItem(url: archive, reason: error.localizedDescription))
                continue
            }
            do {
                let placed = try await FileIO.perform(cancellation: cancellation) {
                    try ArchiveExtractor.extract(item, into: folder, placement: placement, limits: limits, tracker: tracker)
                }
                guard let placed else {
                    outcome.wasCancelled = true
                    break
                }
                outcome.receipts += placed
                outcome.rejections += item.plan.rejections.map { (archive, $0) }
            } catch {
                firstError = firstError ?? error
                outcome.failures.append(FailedItem(url: archive, reason: error.localizedDescription))
            }
        }
        if outcome.receipts.isEmpty, !outcome.wasCancelled, outcome.failures.count == archives.count, let firstError {
            throw firstError
        }
        return outcome
    }
}

/// 展開の結果。**部分的な成功を捨てない**(TransferOutcome と同じ考え)。
nonisolated struct ArchiveExtractionOutcome: Sendable {
    /// 置いた項目(`source` は書庫)。
    var receipts: [TransferReceipt] = []
    /// 開けなかった・書けなかった書庫。
    var failures: [FailedItem] = []
    /// 展開しなかったエントリ(危険なパス・記号リンク)。
    var rejections: [(archive: URL, rejection: ArchiveExtractionPlan.Rejection)] = []
    var wasCancelled = false
}
