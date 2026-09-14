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
/// | `COPYFILE_QUIT` を返す | 中断。**1 ファイルなら書きかけは copyfile が消す**(フォルダは残す ―― ここで消す) |
///
/// ■ 一時名へ写してから置く(2026-09-14 の 2 回目の監査 8)
/// `COPYFILE_EXCL | COPYFILE_RECURSIVE` は、宛先に**同名のフォルダがあると失敗せず、その中へ合流して書く**(実測)。
/// 衝突を確かめてから写し始めるまでの間に誰かが同じ名前のフォルダを作ると、写しはその中へ混ざり、後の片付け(元の変化・失敗)が
/// **他人のフォルダごと**消していた。いまは同じフォルダの隠れた一時名(`stagingPrefix`)へ写し、写し終えて元の変化も確かめてから
/// `RENAME_EXCL` で宛先の名前へ置く。**宛先の名前には、完成した自分の写しか、他人の項目のどちらかしか現れない**ので、
/// 失敗・中止の片付けは一時名だけを消せばよく、宛先の名前にあるものには決して触らない。
///
/// nonisolated: FileIO のスレッドの上で同期に走る。
nonisolated enum FileCopyEngine {
    enum Outcome: Equatable {
        /// 運び終えた。`bytes` は実際に書いたバイト数(クローンなら 0)。
        case completed(bytes: Int64)
        /// **別ボリュームへの移動で、写し終えたが元を消せなかった**(`FileOperationService.moveItem` だけが返す)。
        /// 宛先の完全なコピーは残してあり、元は途中まで消えているかもしれない。`reason` は表示言語の文。
        /// 失敗(throw)にしないのは、途中の catch がどれも「書きかけを片付ける」ので、宛先の**唯一の完全な写し**を
        /// 消してしまうから(2026-09-14 の監査で実測: `uappnd` の子を含むフォルダの移動で 6 ファイルが元にも宛先にも無くなった)。
        case copiedButSourceRemains(bytes: Int64, reason: String)
        case cancelled

        /// 宛先に完全な写しがある(受領書を返す)。
        var hasCompleteCopy: Bool {
            switch self {
            case .completed, .copiedButSourceRemains: true
            case .cancelled: false
            }
        }
    }

    /// 一時名の頭。クラッシュで残ったときに、利用者がアプリの残したものだと分かる名前にする。
    static let stagingPrefix = ".qooViewer-copy-"
    /// 一時名が宛先の名前より長くなりうるバイト数(パス長の事前検査で足す)。
    static let stagingNameBytes = stagingPrefix.utf8.count + 12

    /// `source` を `destination` へ複製する。`destination` は無い前提(衝突は呼び出し側が解決済み)。
    /// 一時名へ写してから置く(型コメント)。宛先の名前が埋まっていたら一時名を消して `alreadyExists` を投げる。
    ///
    /// **写し終えたら、置く前に元が運ぶ間に変わっていないかを確かめる**(`MoveVerification`。変わっていたら一時名を消して
    /// `sourceChangedDuringOperation`)。以前は呼び出し側が宛先の名前に置いてから確かめて消していたので、その名前にあるものを
    /// 自分の写しと決めつけていた。
    ///
    /// - Parameter allowsCloning: false で必ず実コピーにする。**テストのための逃げ道**
    ///   (進捗と中断が働くのはクローンできない経路だけなので)。本番は指定しない。
    /// - Parameter onBytesCopied: 実コピーのときだけ、増分のバイト数で呼ばれる。
    ///
    /// **失敗・中止したら、自分が作った書きかけ(一時名)を消してから返る**(2026-09-14 の監査で実測: フォルダの再帰コピーが途中で
    /// 失敗すると、copyfile は作りかけの木をその名前のまま残していた。受領書が無いので Undo でも誰も片付けない)。
    static func copy(
        from source: URL,
        to destination: URL,
        allowsCloning: Bool = true,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(stagingPrefix + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased())
        let before = MoveVerification.stamp(of: source)
        let outcome = try copyRetryingWithoutCloning(
            from: source, to: staging, allowsCloning: allowsCloning, onBytesCopied: onBytesCopied
        )
        guard case .completed = outcome else {
            FileOperationService.removePartialWrite(at: staging)
            return outcome
        }
        let trustsModificationDate = MountTable.current().isLocal(source)
        if MoveVerification.sourceWasModified(
            before: before, source: source, destination: staging, trustsModificationDate: trustsModificationDate
        ) {
            FileOperationService.removePartialWrite(at: staging)
            throw FileOperationError.sourceChangedDuringOperation(source)
        }
        let code = renameLiftingProtection(from: staging, to: destination)
        guard code == 0 else {
            FileOperationService.removePartialWrite(at: staging)
            if code == EEXIST { throw FileOperationError.alreadyExists(destination) }
            throw FileOperationError.posixFailure(item: source, errnoCode: code)
        }
        return outcome
    }

    /// 一時名から宛先の名前へ `RENAME_EXCL` で置く。**写ったロック・追記のみのフラグは rename(2) を EPERM で断る**ので、
    /// 外して置き、置いた先(失敗なら一時名)で掛け直す。リンクは辿らない。
    private static func renameLiftingProtection(from staging: URL, to destination: URL) -> Int32 {
        let blocking = UInt32(UF_IMMUTABLE | UF_APPEND)
        var info = stat()
        let flags = lstat(staging.path, &info) == 0 ? info.st_flags : 0
        let lifted = flags & blocking != 0 && lchflags(staging.path, flags & ~blocking) == 0
        let code = FileOperationService.exclusiveRename(from: staging, to: destination)
        if lifted { lchflags((code == 0 ? destination : staging).path, flags) }
        return code
    }

    private static func copyRetryingWithoutCloning(
        from source: URL,
        to destination: URL,
        allowsCloning: Bool,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> Outcome {
        do {
            return try copyOnce(from: source, to: destination, allowsCloning: allowsCloning, onBytesCopied: onBytesCopied)
        } catch let retry as RetryWithoutCloning {
            // **中身のある 0555 のサブフォルダを含む木は、CLONE 付きの再帰コピーが EACCES で必ず失敗する**(同じボリュームでも
            // 別のボリュームでも。CLONE 無しなら同じ木が 0555 ごと写る。2026-09-14 実測)。読み取り専用のメディアから
            // 戻したフォルダで普通に起きる。**ロックされたフォルダ(`uchg`。空でも)を含む木も、CLONE 付きは EPERM で必ず失敗する**
            // (CLONE 無しならロックごと写る。ロックされたファイル・`uappnd` のフォルダは CLONE でも写る。2026-09-14 の 2 回目の監査で実測)。
            // 書きかけは消してあるので、CLONE 無しで最初からやり直す。
            // 1 回目で報告したバイト数は 2 回目で報告し直さない(進捗が 100% を超えて張り付く)。
            var remainingToSkip = retry.bytesAlreadyReported
            return try copyOnce(from: source, to: destination, allowsCloning: false) { delta in
                let skipped = min(delta, remainingToSkip)
                remainingToSkip -= skipped
                if delta > skipped { onBytesCopied(delta - skipped) }
            }
        }
    }

    /// `copy` の 1 回ぶん。CLONE 無しでやり直すべき失敗なら `RetryWithoutCloning` を投げる(書きかけは消してある)。
    private static func copyOnce(
        from source: URL,
        to destination: URL,
        allowsCloning: Bool,
        onBytesCopied: @escaping (Int64) -> Void
    ) throws -> Outcome {
        let context = CallbackContext(onBytesCopied: onBytesCopied, sourcePath: source.path)
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
        // EEXIST でも、中の項目まで進んでいたなら頂点は自分が作ったもの(大文字小文字だけが違う 2 つの名前を、区別しない
        // ボリュームへ写したときなど)。頂点で断られたときだけ、そこにあるのは他人の項目なので触らない
        // (いまの頂点は一意な一時名なので、ほぼ起きない)。
        if failure != EEXIST || context.reachedChild {
            FileOperationService.removePartialWrite(at: destination)
        }
        // やり直すのは**書きかけが本当に消えたときだけ**。残っていると、copyfile は宛先の既存のフォルダの中へ合流して書く
        // (`宛先/名前/…`。2026-09-14 の 2 回目の監査で実測)ので、2 回目が「成功」しても中身の違う木ができる。
        // errno で絞らない(EACCES・EPERM のほか、状態 callback を挟んで別の値が残ることがあった)。木を歩くのは失敗したときだけ。
        if allowsCloning, failure != EEXIST, !FileOperationService.itemExists(at: destination),
           containsDirectoryBlockingClone(source) {
            throw RetryWithoutCloning(bytesAlreadyReported: context.totalCopied)
        }
        // 木を歩いている間に中止された(`containsDirectoryBlockingClone` は中止で false を返す)なら、失敗ではなく中止として返す
        // (2026-09-15 の 3 回目の監査。以前は利用者の中止が「権限がありません」などの失敗として出た)。書きかけは上で消してある。
        if Cancellation.isRequestedInCurrentScope { return .cancelled }
        throw FileOperationError.posixFailure(item: source, errnoCode: failure)
    }

    private struct RetryWithoutCloning: Error {
        let bytesAlreadyReported: Int64
    }

    /// 木の中に、CLONE 付きの再帰コピーを必ず失敗させるフォルダ(持ち主に書き込み権が無い / ロックされている)があるか。
    /// **リンクの先へは入らない。** 失敗したあとにだけ歩くので、成功する普通のコピーには費用が掛からない。
    private static func containsDirectoryBlockingClone(_ root: URL) -> Bool {
        func blocks(_ info: stat) -> Bool {
            info.st_mode & S_IWUSR == 0 || info.st_flags & UInt32(UF_IMMUTABLE) != 0
        }
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
        if blocks(info) { return true }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: []) else { return false }
        for case let child as URL in enumerator {
            if Cancellation.isRequestedInCurrentScope { return false }
            guard lstat(child.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            if blocks(info) { return true }
        }
        return false
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
        let sourcePath: String
        /// 頂点より下の項目の callback が届いた(= 頂点の宛先は自分が作った)。
        var reachedChild = false

        init(onBytesCopied: @escaping (Int64) -> Void, sourcePath: String) {
            self.onBytesCopied = onBytesCopied
            self.sourcePath = sourcePath
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
        if let sourcePath, !context.reachedChild, strcmp(sourcePath, context.sourcePath) != 0 {
            context.reachedChild = true
        }
        if stage == COPYFILE_ERR { return COPYFILE_QUIT }

        guard what == COPYFILE_COPY_DATA, stage == COPYFILE_PROGRESS else { return COPYFILE_CONTINUE }
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        context.note(path: sourcePath.map { String(cString: $0) } ?? "", copiedSoFar: Int64(copied))
        return COPYFILE_CONTINUE
    }
}
