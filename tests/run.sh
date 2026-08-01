#!/usr/bin/env bash
# -e を付けても安全: 各 test_*.sh の実行は if 条件配下（`if bash "$f"; then`）
# にあり、-e はここでは発火しないため付けない理由がない。
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

rc=0
for f in test_*.sh; do
  printf '%s\n' "$f"
  if bash "$f"; then :; else rc=1; fi
done

if [ "$rc" -eq 0 ]; then
  printf '\n全テスト成功\n'
else
  printf '\n失敗あり\n'
fi
exit "$rc"
