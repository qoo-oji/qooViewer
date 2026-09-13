#!/bin/bash
# scripts/git-hooks/ を git hook として有効にする(この clone だけ。core.hooksPath は .git/config に入る)。
# pre-commit / commit-msg / pre-push が蔵書の名前・個人のパスの混入を止める(check-private-terms.sh)。
set -euo pipefail
cd "$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
chmod +x scripts/git-hooks/*
git config core.hooksPath scripts/git-hooks
echo "core.hooksPath = $(git config core.hooksPath)"
