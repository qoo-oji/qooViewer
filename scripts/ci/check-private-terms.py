#!/usr/bin/env python3
"""蔵書の名前・個人のパスがリポジトリに入っていないことを確かめる(check-private-terms.sh の本体)。

2 層で見る:
  1. **手元の一覧**(scripts/dev/build-private-terms.py が作る。リポジトリの外にある)。
     実在するフォルダ名・ファイル名との一致。無ければこの層は飛ばす(CI にはこの一覧が無い)。
  2. **一般的な形**(どこでも動く)。`/Users/<名前>/…` と `/Volumes/<ボリューム>/<フォルダ>…` の
     実在しそうな絶対パス。説明に使う置き場所(`/Users/nobody`、`/Volumes/X/A/B`、`<名前>` など)は
     PLACEHOLDER_* で許す。

見る対象は引数で選ぶ: 追跡ファイル全部+全コミットメッセージ+ref 名(既定)、ステージされた中身(--staged)、
コミットメッセージのファイル(--message)、コミットの範囲のメッセージ(--commits)。

**一致した語そのものは出力しない**(既定)。検査の出力もまた漏洩経路になる ―― ターミナルの記録や
AI との会話へ写った語は、そこからコピーされうる(qooLibrary では「除去の説明の中へ秘密を写す」事故が
3 度あった)。既定は「N 文字の語」とだけ言い、どの語か知りたいときだけ --reveal を付ける。
一般的な形の一致(パス)は、置き場所の判断に要るのでそのまま出す。

hook からは --require-terms で呼ぶ: 手元の一覧が無ければ**検査できなかった**として失敗させる
(「検査できなかった」を「問題なし」と読み替えない。qooLibrary の漏洩事故の根本原因がこれだった)。
"""
import argparse
import os
import re
import subprocess
import sys
import unicodedata

DEFAULT_TERMS = os.path.expanduser("~/Library/Application Support/qooViewer-dev/private-terms.txt")
DEFAULT_ALLOW = os.path.expanduser("~/Library/Application Support/qooViewer-dev/private-terms-allow.txt")

# 説明用のパスに使ってよい名前(実在しない・特定の人を指さない)。
PLACEHOLDER_USERS = {"nobody", "foo", "foobar", "user", "username", "you", "name", "someone", "<user>", "<name>", "…"}
PLACEHOLDER_VOLUME_PREFIXES = ("X", "<", "\\(", "NoSuchVolume", "落ちた共有", "名前", "…")

# 名前の部分は英数と `._-` が続く範囲だけを取る(`/Users/foo」が`のように和文の引用符が続いても
# 置き場所の名前 `foo` だけで判定できるように)。
USERS_PATH = re.compile(r"/Users/([A-Za-z0-9._-]+)/")
VOLUMES_PATH = re.compile(r"/Volumes/([^/\s'\"`)」]+)/([^/\s'\"`)」]+)")

# 一致を見ないファイル(中身が名前ではないバイナリ、または自分自身)。
SKIP_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".avif", ".heic", ".icns", ".pdf", ".zip", ".cbz",
                 ".rar", ".cbr", ".7z", ".cb7", ".epub", ".bmp", ".tif", ".tiff")
SELF = {"scripts/ci/check-private-terms.py", "scripts/ci/check-private-terms.sh", "scripts/dev/build-private-terms.py"}


def git(*args: str) -> str:
    return subprocess.run(["git", *args], capture_output=True, text=True, errors="replace", check=True).stdout


def fold(text: str) -> str:
    return unicodedata.normalize("NFC", text).casefold()


def load_terms(path: str) -> list[str]:
    if not os.path.exists(path):
        return []
    with open(path, encoding="utf-8") as f:
        return [line.rstrip("\n") for line in f if line.strip() and not line.startswith("#")]


def script_class(ch: str) -> str:
    """文字種(ひらがな / カタカナ / 漢字 / 英数 / その他)。前後が同じ文字種の一致は採らない
    (「ブロッカー」の中の「ロッカー」のような、語の一部への一致を落とす。qooLibrary の実測に倣う)。"""
    o = ord(ch)
    if 0x3040 <= o <= 0x309F:
        return "hira"
    if 0x30A0 <= o <= 0x30FF or 0xFF66 <= o <= 0xFF9F:
        return "kata"
    if 0x4E00 <= o <= 0x9FFF or 0x3400 <= o <= 0x4DBF:
        return "han"
    if ch.isalnum():
        return "alnum"
    return "other"


class TermMatcher:
    """一覧の語との一致。ASCII だけの語は単語の境界で、それ以外は文字種の境界で見る。

    ASCII の短い語("Comic"、"Image" のような名前)を部分一致にすると `ComicInfo` のような
    識別子に当たりすぎるため。非 ASCII の語は、一致の直前・直後が語の端と同じ文字種なら
    語の一部と見なして採らない(script_class 参照)。

    **語ごとに全文を探索しない。** 語数 × ファイル数になり、2 万語で全ツリーが 2 分を超えた(実測)。
    語を先頭 2 文字で引く辞書に入れ、本文を 1 文字ずつ進めながら辞書に当たった位置だけ語を照合する
    (qooLibrary の同じ検査が「先頭 2 スカラーのバケット索引で 1 パス」にしたのと同じ考え方。
    1 本の正規表現の選択肢に並べる形も試したが、選択肢が 1 万を超えると位置ごとに全部を試すので遅かった)。
    """

    def __init__(self, terms: list[str], allowed: list[str]):
        allow = {fold(t) for t in allowed}
        self.buckets: dict[str, list[tuple[str, bool]]] = {}
        self.count = 0
        for term in terms:
            folded = fold(term)
            if folded in allow:
                continue
            is_ascii = folded.isascii()
            if len(folded) < (4 if is_ascii else 3):
                continue
            self.buckets.setdefault(folded[:2], []).append((folded, is_ascii))
            self.count += 1
        for bucket in self.buckets.values():
            bucket.sort(key=lambda t: len(t[0]), reverse=True)

    @staticmethod
    def _is_whole(text: str, start: int, end: int, is_ascii: bool) -> bool:
        if is_ascii:
            before = text[start - 1] if start > 0 else " "
            after = text[end] if end < len(text) else " "
            return not (before.isascii() and before.isalnum()) and not (after.isascii() and after.isalnum())
        if start > 0 and script_class(text[start - 1]) == script_class(text[start]):
            return False
        if end < len(text) and script_class(text[end]) == script_class(text[end - 1]):
            return False
        return True

    def find(self, text: str) -> list[tuple[str, int]]:
        folded = fold(text)
        hits: dict[str, int] = {}
        buckets = self.buckets
        for i in range(len(folded) - 1):
            bucket = buckets.get(folded[i:i + 2])
            if not bucket:
                continue
            for term, is_ascii in bucket:
                if term in hits:
                    continue
                end = i + len(term)
                if folded.startswith(term, i) and self._is_whole(folded, i, end, is_ascii):
                    hits[term] = folded.count("\n", 0, i) + 1
        return list(hits.items())


def generic_hits(text: str) -> list[tuple[str, int]]:
    hits = []
    for m in USERS_PATH.finditer(text):
        if m.group(1) not in PLACEHOLDER_USERS:
            hits.append((f"/Users/<…>/ のパス: {m.group(0)}", text.count("\n", 0, m.start()) + 1))
    for m in VOLUMES_PATH.finditer(text):
        if not m.group(1).startswith(PLACEHOLDER_VOLUME_PREFIXES):
            hits.append((f"/Volumes/<…>/<…> のパス: {m.group(0)}", text.count("\n", 0, m.start()) + 1))
    return hits


def is_text(data: bytes) -> bool:
    return b"\0" not in data[:8192]


def tracked_sources() -> list[tuple[str, str]]:
    sources = []
    for path in git("ls-files", "-z").split("\0"):
        if not path or path in SELF or path.lower().endswith(SKIP_SUFFIXES):
            continue
        try:
            with open(path, "rb") as f:
                data = f.read()
        except OSError:
            continue
        if is_text(data):
            sources.append((path, data.decode("utf-8", errors="replace")))
    # 追跡ファイルの**名前**も見る(フィクスチャに蔵書の名前を付けてしまう事故)。
    sources.append(("<追跡ファイルの名前一覧>", git("ls-files")))
    return sources


def staged_sources() -> list[tuple[str, str]]:
    sources = []
    out = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z")
    for path in out.split("\0"):
        if not path or path in SELF or path.lower().endswith(SKIP_SUFFIXES):
            continue
        data = subprocess.run(["git", "show", f":{path}"], capture_output=True, check=True).stdout
        if is_text(data):
            sources.append((path, data.decode("utf-8", errors="replace")))
    sources.append(("<ステージされたファイルの名前一覧>", out.replace("\0", "\n")))
    return sources


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--staged", action="store_true", help="ステージされた中身だけを見る(pre-commit)")
    parser.add_argument("--message", help="コミットメッセージのファイル(commit-msg)")
    parser.add_argument("--commits", help="この範囲のコミットメッセージを見る(例: origin/main..HEAD)")
    parser.add_argument("--terms", default=os.environ.get("QOO_PRIVATE_TERMS", DEFAULT_TERMS))
    parser.add_argument("--allow", default=os.environ.get("QOO_PRIVATE_TERMS_ALLOW", DEFAULT_ALLOW))
    parser.add_argument("--require-terms", action="store_true", help="手元の一覧が無ければ失敗させる(hook 用)")
    parser.add_argument("--reveal", action="store_true", help="一致した語そのものを出す(手元で見直すときだけ)")
    args = parser.parse_args()

    sources: list[tuple[str, str]] = []
    if args.staged:
        sources += staged_sources()
    if args.message:
        with open(args.message, encoding="utf-8", errors="replace") as f:
            sources.append(("<コミットメッセージ>", f.read()))
    if args.commits:
        sources.append((f"<コミットメッセージ {args.commits}>", git("log", "--format=%H%n%B", args.commits)))
    if not (args.staged or args.message or args.commits):
        sources += tracked_sources()
        sources.append(("<全コミットメッセージ>", git("log", "--all", "--format=%H%n%B")))
        sources.append(("<ブランチ・タグの名前>", git("for-each-ref", "--format=%(refname)")))

    terms = load_terms(args.terms)
    if not terms and args.require_terms:
        print(f"FAIL: 手元の一覧が無いので検査できない: {args.terms}"
              "(scripts/dev/build-private-terms.py で作る)", file=sys.stderr)
        return 1
    matcher = TermMatcher(terms, load_terms(args.allow)) if terms else None
    if matcher:
        print(f"note: 手元の一覧 {matcher.count} 語で照合する")
    else:
        print("note: 手元の一覧が無いので、一般的な形だけを見る")

    failures = 0
    for name, text in sources:
        for what, line in generic_hits(text):
            print(f"FAIL: {name}:{line}: {what}", file=sys.stderr)
            failures += 1
        if matcher:
            for term, line in matcher.find(text):
                shown = term if args.reveal else f"{len(term)} 文字の語(--reveal で表示)"
                print(f"FAIL: {name}:{line}: 一覧の語と一致: {shown}", file=sys.stderr)
                failures += 1
    if failures:
        print(f"FAIL: 個人の名前・パスが {failures} 箇所見つかった", file=sys.stderr)
        return 1
    print(f"ok:   {len(sources)} 件の対象に個人の名前・パスは無い")
    return 0


if __name__ == "__main__":
    sys.exit(main())
