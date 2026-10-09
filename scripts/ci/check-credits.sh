#!/bin/bash
# 「qooViewer について」に出す第三者のライセンス(qooViewer/Resources/Credits.rtf)が、Package.resolved の依存を
# すべて今の版で載せていることを確かめる(2026-10-10)。配る .app には依存ライブラリが入るので、ライセンスが求める表記を
# 配布物そのものに持たせている。依存を足した・版を動かしたら scripts/dev/build-credits.py で作り直す(手元。checkout が要る)。
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if python3 -I scripts/dev/build-credits.py --check; then
    ok "Credits.rtf は Package.resolved の依存と版に一致"
else
    fail "Credits.rtf が Package.resolved と食い違う(python3 -I scripts/dev/build-credits.py で作り直す)"
fi

finish
