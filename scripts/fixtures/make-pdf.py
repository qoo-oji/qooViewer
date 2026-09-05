#!/usr/bin/env python3
"""Document Catalog の項目を自分で決めた、小さな PDF を書く。

PDFStructureResolver が読む `/ViewerPreferences/Direction`・`/PageLayout`・アウトライン・Info 辞書の
「読み取り側の正解」を、生成側(PDFExporter + PDFCatalogAugmenter)に依存せずに用意するためのもの。
各ページは MediaBox 200x300 で、ページ番号を色に埋めた矩形を 1 つ塗る(make-page-image.py と同じ
R = ページ番号)。xref のオフセットは計算して書くので、そのまま CGPDFDocument / PDFKit で開ける。

    make-pdf.py OUT.pdf --pages N [--direction R2L|L2R] [--page-layout NAME]
                        [--title T] [--author A] [--keywords K] [--outline]
"""
import sys


def pdf_string(value: str) -> bytes:
    """ASCII ならリテラル文字列、そうでなければ UTF-16BE(BOM 付き)の 16 進文字列。"""
    if all(ord(c) < 128 for c in value):
        escaped = value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        return b"(" + escaped.encode("ascii") + b")"
    return b"<" + (b"\xfe\xff" + value.encode("utf-16-be")).hex().upper().encode("ascii") + b">"


def parse_args(argv):
    options = {"pages": None, "direction": None, "page_layout": None, "title": None,
               "author": None, "keywords": None, "outline": False}
    out = argv[1]
    i = 2
    while i < len(argv):
        key = argv[i]
        if key == "--outline":
            options["outline"] = True
            i += 1
            continue
        value = argv[i + 1]
        name = key[2:].replace("-", "_")
        if name not in options:
            sys.exit(f"不明なオプション: {key}")
        options[name] = int(value) if name == "pages" else value
        i += 2
    if not options["pages"]:
        sys.exit("--pages は必須")
    return out, options


def build(options) -> bytes:
    objects = {}  # 番号 -> 本体(bytes、"N 0 obj"〜"endobj" は含まない)
    page_count = options["pages"]
    catalog_number, pages_number = 1, 2
    next_number = 3
    page_numbers = []
    for index in range(page_count):
        page_number, content_number = next_number, next_number + 1
        next_number += 2
        page_numbers.append(page_number)
        color = f"{(index + 1) / 255:.6f} {0x66 / 255:.6f} {0x99 / 255:.6f}"
        content = f"q {color} rg 0 0 200 300 re f Q".encode("ascii")
        objects[content_number] = b"<< /Length %d >>\nstream\n" % len(content) + content + b"\nendstream"
        objects[page_number] = (
            b"<< /Type /Page /Parent %d 0 R /MediaBox [0 0 200 300] /Contents %d 0 R >>"
            % (pages_number, content_number)
        )
    kids = b" ".join(b"%d 0 R" % n for n in page_numbers)
    objects[pages_number] = b"<< /Type /Pages /Kids [" + kids + b"] /Count %d >>" % page_count

    catalog = [b"/Type /Catalog", b"/Pages %d 0 R" % pages_number]
    if options["direction"]:
        catalog.append(b"/ViewerPreferences << /Direction /" + options["direction"].encode("ascii") + b" >>")
    if options["page_layout"]:
        catalog.append(b"/PageLayout /" + options["page_layout"].encode("ascii"))

    if options["outline"]:
        # 第1章(→1ページ目)の下に 1.1 節(→2ページ目)、続けて第2章(→最後のページ)。
        # 入れ子と /Count の符号(閉じている親は負)を含め、読み取り側が辿る形をひととおり含める。
        outlines_number = next_number
        chapter1, section11, chapter2 = next_number + 1, next_number + 2, next_number + 3
        next_number += 4
        last_page = page_numbers[-1]
        second_page = page_numbers[min(1, page_count - 1)]
        objects[outlines_number] = (
            b"<< /Type /Outlines /First %d 0 R /Last %d 0 R /Count 3 >>" % (chapter1, chapter2)
        )
        objects[chapter1] = (
            b"<< /Title " + pdf_string("第1章") + b" /Parent %d 0 R /Next %d 0 R" % (outlines_number, chapter2)
            + b" /First %d 0 R /Last %d 0 R /Count 1 /Dest [%d 0 R /Fit] >>" % (section11, section11, page_numbers[0])
        )
        objects[section11] = (
            b"<< /Title " + pdf_string("1.1 節") + b" /Parent %d 0 R /Dest [%d 0 R /Fit] >>" % (chapter1, second_page)
        )
        objects[chapter2] = (
            b"<< /Title " + pdf_string("第2章") + b" /Parent %d 0 R /Prev %d 0 R /Dest [%d 0 R /Fit] >>"
            % (outlines_number, chapter1, last_page)
        )
        catalog.append(b"/Outlines %d 0 R /PageMode /UseOutlines" % outlines_number)
    objects[catalog_number] = b"<< " + b" ".join(catalog) + b" >>"

    info_number = None
    info = []
    for key in ("title", "author", "keywords"):
        if options[key]:
            info.append(b"/" + key.capitalize().encode("ascii") + b" " + pdf_string(options[key]))
    if info:
        info_number = next_number
        next_number += 1
        objects[info_number] = b"<< " + b" ".join(info) + b" >>"

    out = bytearray(b"%PDF-1.7\n%\xe2\xe3\xcf\xd3\n")
    offsets = {}
    for number in sorted(objects):
        offsets[number] = len(out)
        out += b"%d 0 obj\n" % number + objects[number] + b"\nendobj\n"
    size = max(objects) + 1
    xref_offset = len(out)
    out += b"xref\n0 %d\n" % size
    out += b"0000000000 65535 f \n"
    for number in range(1, size):
        out += b"%010d 00000 n \n" % offsets[number]
    trailer = b"<< /Size %d /Root %d 0 R" % (size, catalog_number)
    if info_number:
        trailer += b" /Info %d 0 R" % info_number
    trailer += b" >>"
    out += b"trailer\n" + trailer + b"\nstartxref\n%d\n%%%%EOF\n" % xref_offset
    return bytes(out)


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    out, options = parse_args(argv)
    with open(out, "wb") as f:
        f.write(build(options))


if __name__ == "__main__":
    main(sys.argv)
