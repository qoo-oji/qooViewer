import Foundation

/// 実際にバイトを運ぶところ(改善要望7 段階 2、2026-09-13。qooLibrary の `FileCopyEngine` を写したもの)。
/// FileOperationService のコピーと、別ボリュームへの移動だけが使う。
///
/// ■ `FileManager.copyItem` をやめた理由
/// 進捗を報告せず中断もできない。
///
/// ■ `copyfile(3)` と `COPYFILE_CLONE`(qooLibrary 実測)
/// `FileManager.copyItem` は APFS 上でクローンしている(1GB が 3ms)。素朴に `copyfile(COPYFILE_ALL)` へ
/// 置き換えると実コピー(335ms・ディスクも消費)に退行するので、`COPYFILE_CLONE` を必ず付ける。
///
/// | 条件 | 結果 |
/// |---|---|
/// | 同一ボリューム・ファイル | クローン。コールバック 0 回、1GB が 0ms |
/// | 同一ボリューム・フォルダ(`RECURSIVE`)| クローン。2ms |
/// | 別ボリューム・ファイル | 実コピーへ自動で落ち、コールバックが届く(500MB で 477 回) |
/// | 別ボリューム・フォルダ | ファイルごとに届く(`srcPath` で見分けられる) |
/// | `COPYFILE_QUIT` を返す | 中断。**1 ファイルなら書きかけは copyfile が消す**(フォルダは残す ―― 呼び出し側が消す) |
///
/// nonisolated: FileIO のスレッドの上で同期に走る。
nonisolated enum FileCopyEngine {
    enum Outcome: Equatable {
        /// 運び終えた。`bytes` は実際に書いたバイト数(クローンなら 0)。
        case completed(bytes: Int64)
        case cancelled
    }

    /// `source` を `destination` へ複製する。`destination` は無い前提(衝突は呼び出し側が解決済み)。
    ///
    /// - Parameter allowsCloning: false で必ず実コピーにする。**テストのための逃げ道**
    ///   (進捗と中断が働くのはクローンできない経路だけなので)。本番は指定しない。
    /// - Parameter onBytesCopied: 実コピーのときだけ、増分のバイト数で呼ばれる。
    static func copy(
        from source: URL,
        to destination: URL,
        allowsCloning: Bool = true,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let context = CallbackContext(onBytesCopied: onBytesCopied)
        let state = copyfile_state_alloc()
        defer { copyfile_state_free(state) }
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB), unsafeBitCast(statusCallback, to: UnsafeRawPointer.self))
        copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), Unmanaged.passUnretained(context).toOpaque())

        // - NOFOLLOW: シンボリックリンクはリンクとして複製する(FileManager.copyItem と同じ)。
        // - EXCL: 宛先があれば失敗する。**必ず自分で付ける** ―― man page は CLONE が EXCL を含むと
        //   書くが、実際には既存の宛先を黙って上書きした(qooLibrary の回帰テストが捕まえた)。
        let base = COPYFILE_ALL | COPYFILE_EXCL | COPYFILE_NOFOLLOW | COPYFILE_RECURSIVE
        let flags = copyfile_flags_t(allowsCloning ? base | COPYFILE_CLONE : base)
        let result = copyfile(source.path, destination.path, state, flags)
        let failure = errno // 直後に読む(以降の呼び出しで壊れる)

        if result == 0 { return .completed(bytes: context.totalCopied) }
        if context.didCancel { return .cancelled }
        throw FileOperationError.posixFailure(item: source, errnoCode: failure)
    }

    /// status callback が読み書きする箱。copyfile は呼び出し元のスレッドで同期に走るので並行アクセスは無い。
    private final class CallbackContext {
        let onBytesCopied: (Int64) -> Void
        var totalCopied: Int64 = 0
        var didCancel = false
        /// フォルダの再帰コピーでは `COPYFILE_STATE_COPIED` が**今のファイルの累計**を返すので、
        /// ファイルが変わったら基準を取り直して増分を積む。
        var currentFilePath: String?
        var currentFileCopied: Int64 = 0

        init(onBytesCopied: @escaping (Int64) -> Void) {
            self.onBytesCopied = onBytesCopied
        }

        func note(path: String, copiedSoFar: Int64) {
            if path != currentFilePath {
                currentFilePath = path
                currentFileCopied = 0
            }
            let delta = copiedSoFar - currentFileCopied
            guard delta > 0 else { return }
            currentFileCopied = copiedSoFar
            totalCopied += delta
            onBytesCopied(delta)
        }
    }

    /// **アクター隔離された型の内側に置かない** ―― C の関数ポインタへ変換されるクロージャが
    /// 隔離付きとみなされ、実行アクターの表明で落ちる。nonisolated enum の static なので安全。
    private static let statusCallback: copyfile_callback_t = { what, stage, state, sourcePath, _, contextPointer in
        guard let contextPointer else { return COPYFILE_CONTINUE }
        let context = Unmanaged<CallbackContext>.fromOpaque(contextPointer).takeUnretainedValue()

        // 中断はどの段階でも受ける(大きな 1 ファイルの途中でも止まれる)。
        if Cancellation.isRequestedInCurrentScope {
            context.didCancel = true
            return COPYFILE_QUIT
        }
        // **エラー段階で COPYFILE_CONTINUE を返さない。** それは「その失敗は無視して続けろ」の指示で、
        // 戻り値まで成功になる ―― EXCL の拒否も権限エラーもディスク不足も黙って握り潰された
        // (qooLibrary の回帰テストが捕まえた)。QUIT なら -1 と errno が返る。
        if stage == COPYFILE_ERR { return COPYFILE_QUIT }

        guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else { return COPYFILE_CONTINUE }
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.note(path: sourcePath.map { String(cString: $0) } ?? "", copiedSoFar: Int64(copied))
        return COPYFILE_CONTINUE
    }
}
