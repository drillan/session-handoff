#!/usr/bin/env bash
set -uo pipefail
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
