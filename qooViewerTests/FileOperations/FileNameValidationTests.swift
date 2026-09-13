import Foundation
import Testing

@testable import qooViewer

/// 名前の検査と、衝突しない名前の付け方(Models/FileNameValidation.swift)。
struct FileNameValidationTests {
    @Test("使えない名前は理由付きで断る")
    func rejectsUnusableNames() {
        #expect(throws: FileNameValidation.Failure.empty) { try FileNameValidation.validated("   ") }
        #expect(throws: FileNameValidation.Failure.forbiddenCharacter("/")) { try FileNameValidation.validated("a/b") }
        #expect(throws: FileNameValidation.Failure.reservedDotName) { try FileNameValidation.validated("..") }
        #expect(throws: FileNameValidation.Failure.reservedDotName) { try FileNameValidation.validated(".") }
        #expect(throws: FileNameValidation.Failure.forbiddenCharacter("\\0")) { try FileNameValidation.validated("a\u{0}b") }
    }

    @Test("どの形式でも作れる文字は断らない(qooLibrary 実測)")
    func acceptsNamesEveryFileSystemAccepts() throws {
        for name in [":colon", "back\\slash", "q?", "*star", ".hidden", "trailing.", "a|b", "<>\""] {
            #expect(try FileNameValidation.validated(name) == name)
        }
        #expect(try FileNameValidation.validated("  padded \n") == "padded")
    }

    @Test("長さは NFD 後の UTF-16 単位で数える(が は 2 単位)")
    func lengthIsCountedInDecomposedUTF16() throws {
        let fits = String(repeating: "が", count: 127)
        #expect(try FileNameValidation.validated(fits) == fits)
        let tooLong = String(repeating: "が", count: 128)
        #expect(throws: FileNameValidation.Failure.tooLong(units: 256)) { try FileNameValidation.validated(tooLong) }
        // バイト数(UTF-8)では断らない ―― あ 255 文字は 765 バイトだが APFS では作れる。
        let ascii = String(repeating: "あ", count: 255)
        #expect(FileNameValidation.isAcceptable(ascii))
    }

    @Test("衝突しない名前は Finder と同じ name 2.ext …")
    func nextAvailableNameFollowsFinder() {
        #expect(FileNameValidation.nextAvailableName(for: "a.txt", existing: []) == "a.txt")
        #expect(FileNameValidation.nextAvailableName(for: "a.txt", existing: ["a.txt"]) == "a 2.txt")
        #expect(FileNameValidation.nextAvailableName(for: "a.txt", existing: ["a.txt", "a 2.txt"]) == "a 3.txt")
        #expect(FileNameValidation.nextAvailableName(for: "book.tar.gz", existing: ["book.tar.gz"]) == "book.tar 2.gz")
        #expect(FileNameValidation.nextAvailableName(for: ".hidden", existing: [".hidden"]) == ".hidden 2")
        #expect(FileNameValidation.nextAvailableName(for: "noext", existing: ["noext"]) == "noext 2")
    }

    @Test("既存の数字は解釈しない(巻数かもしれない)")
    func existingNumbersAreNotInterpreted() {
        #expect(FileNameValidation.nextAvailableName(for: "vol 2.cbz", existing: ["vol 2.cbz"]) == "vol 2 2.cbz")
    }

    @Test("フォルダの名前にドットがあっても拡張子とみなさない")
    func folderDotsAreNotExtensions() {
        #expect(FileNameValidation.nextAvailableName(for: "v1.5", isDirectory: true, existing: ["v1.5"]) == "v1.5 2")
    }

    @Test("大文字小文字と正規化の違いは同じ名前として数える")
    func comparisonFoldsCaseAndNormalization() {
        let decomposed = "か\u{3099}.txt" // NFD の が
        #expect(FileNameValidation.nextAvailableName(for: "が.txt", existing: [decomposed]) == "が 2.txt")
        #expect(FileNameValidation.nextAvailableName(for: "A.TXT", existing: ["a.txt"]) == "A 2.TXT")
    }

    @Test("新規フォルダの名前は表示言語で、塞がっていれば番号を足す")
    func untitledFolderNameUsesTheDisplayLanguage() {
        let english = Locale(identifier: "en")
        #expect(FileNameValidation.untitledFolderName(existing: [], locale: english) == "untitled folder")
        #expect(FileNameValidation.untitledFolderName(existing: ["untitled folder"], locale: english) == "untitled folder 2")
        let japanese = Locale(identifier: "ja")
        #expect(FileNameValidation.untitledFolderName(existing: [], locale: japanese) == "名称未設定フォルダ")
    }
}
