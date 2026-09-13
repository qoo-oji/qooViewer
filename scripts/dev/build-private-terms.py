#!/usr/bin/env python3
"""蔵書のフォルダ名・ファイル名から「リポジトリに現れてはいけない語」の一覧を作る。

改善要望7の最重要事項: ボリューム名を除くフォルダパス・ファイル名は、GitHub へ上がるファイルにも
コミットメッセージにも一切含めない。過去に何度か蔵書のファイル名が公開リポジトリから読める状態に
なったことがある。「一般的な語だから」という理由で見逃さないために(実例: 「プロトタイプ」という
名前のフォルダが実在する)、判定は語の意味ではなく**実在する名前との一致**で行う。

この一覧は**リポジトリの外**に置く(既定は下の DEFAULT_OUTPUT)。中身そのものが個人情報なので、
リポジトリ内に置くこと自体を .gitignore と scripts/ci/check-private-terms.sh の両方で禁じている。

使い方:
    scripts/dev/build-private-terms.py /Volumes/<ボリューム>/<蔵書のフォルダ> [別のフォルダ …]
    scripts/dev/build-private-terms.py --extra "追加の語" …   # 名前以外に禁じたい語

読むだけで、蔵書には一切書き込まない。走査するのはフォルダ名とファイル名だけ(書庫の中身は開かない)。
自動で足すもの: 指定したフォルダの上位のフォルダ名(ボリューム名は除く)、ホームフォルダのユーザー名、
このリポジトリの上位のフォルダ名。除くもの: 数字と記号だけの名前、拡張子、ボリューム名、
このリポジトリ自身のフォルダ名。
"""
import argparse
import os
import sys
import unicodedata

DEFAULT_OUTPUT = os.path.expanduser("~/Library/Application Support/qooViewer-dev/private-terms.txt")
# パスの構成要素のうち、名前ではなく OS の構造そのものである語。
STRUCTURAL = {"", "/", "Volumes", "Users", "Library", "private", "var", "tmp"}


def normalized(name: str) -> str:
    return unicodedata.normalize("NFC", name).strip()


def is_meaningful(name: str) -> bool:
    # 数字と記号だけの名前(001、-、_ など)は実在しても個人を特定しない。
    return any(ch.isalpha() for ch in name)


def path_components(path: str) -> list[str]:
    parts = [normalized(p) for p in os.path.abspath(path).split(os.sep)]
    if len(parts) > 2 and parts[1] == "Volumes":
        parts = parts[3:]  # ボリューム名(parts[2])は許されている
    return [p for p in parts if p not in STRUCTURAL]


def collect(roots: list[str]) -> set[str]:
    terms: set[str] = set()
    for root in roots:
        for comp in path_components(root):
            terms.add(comp)
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for d in dirnames:
                terms.add(normalized(d))
            for f in filenames:
                if f.startswith("."):
                    continue
                base, _ext = os.path.splitext(f)
                # 語幹が数字と記号だけの名前(001.jpg など)は個人を特定しないので入れない。
                if not is_meaningful(base):
                    continue
                terms.add(normalized(base))
                terms.add(normalized(f))
    return terms


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("roots", nargs="*", help="蔵書のフォルダ(読み取りのみ)")
    parser.add_argument("--extra", action="append", default=[], help="名前以外に禁じたい語")
    parser.add_argument("--output", default=DEFAULT_OUTPUT, help=f"書き出し先(既定: {DEFAULT_OUTPUT})")
    parser.add_argument("--append", action="store_true", help="既存の一覧に足す(既定は作り直す)")
    args = parser.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if os.path.commonpath([os.path.abspath(args.output), repo_root]) == repo_root:
        print("error: 一覧をリポジトリの中へ書いてはいけない", file=sys.stderr)
        return 2

    terms = collect(args.roots)
    terms.update(normalized(t) for t in args.extra)
    # ホームフォルダのユーザー名と、このリポジトリの上位フォルダ名も個人の情報。
    terms.update(path_components(os.path.expanduser("~")))
    terms.update(path_components(os.path.dirname(repo_root)))
    repo_name = normalized(os.path.basename(repo_root))
    terms = {t for t in terms if t and is_meaningful(t) and t != repo_name and t != "qooViewer"}

    if args.append and os.path.exists(args.output):
        with open(args.output, encoding="utf-8") as f:
            terms.update(line.rstrip("\n") for line in f if line and not line.startswith("#"))

    os.makedirs(os.path.dirname(args.output), exist_ok=True)
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("# qooViewer: リポジトリに現れてはいけない語(scripts/dev/build-private-terms.py が生成)\n")
        f.write("# このファイルはリポジトリの外に置く。1 行 1 語。# で始まる行は無視される。\n")
        for term in sorted(terms):
            f.write(term + "\n")
    print(f"{len(terms)} 語を書き出した: {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
