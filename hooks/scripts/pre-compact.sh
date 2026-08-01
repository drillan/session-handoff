#!/usr/bin/env bash
# PreCompact フック。モデルを呼ばず、機械的な差分だけを追記する。
# compact を絶対に止めないため、失敗しても exit 2 は返さない（exit 1 = 非ブロックエラー）。
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib.sh"

input=$(cat)
session_id=$(require_field "$input" session_id)
cwd=$(require_field "$input" cwd)
trigger=$(require_field "$input" trigger)

dir=$(data_dir "$cwd")
mkdir -p "$dir"
file=$(handoff_path "$cwd" "$session_id")
now=$(date --iso-8601=seconds)

if [ ! -f "$file" ]; then
  # 警告は「## いま何をしているか」の中に置く。session-start.sh の compact
  # プロファイルはこの見出しを含む3見出ししか抽出しないため、素の本文に
  # 置くと compact 直後のコンテキストへ一切届かない（レビュー指摘で発覚）。
  cat > "$file" <<HEADER
---
session_id: $session_id
project: $cwd
updated: $now
updated_by: pre-compact-hook
---

## いま何をしているか

⚠ /handoff を実行しないまま compact が発火した。意味情報は記録されていない。
下記の \`## 自動追記ログ\` にある git の状態だけが手がかり。

---

## 自動追記ログ
HEADER
fi

# git リポジトリか否かの判定。失敗の抑制ではなく分岐条件なので出力を捨ててよい。
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current)
  [ -n "$branch" ] || branch="(detached HEAD)"
  status=$(git -C "$cwd" status --short)
  [ -n "$status" ] || status="(変更なし)"
  diffstat=$(git -C "$cwd" diff --stat | tail -1)
  [ -n "$diffstat" ] || diffstat="(差分なし)"
else
  branch="not a git repository"
  status="not a git repository"
  diffstat="not a git repository"
fi

{
  printf '\n### %s compact(%s)\n' "$now" "$trigger"
  printf 'branch: %s\n' "$branch"
  printf 'status:\n%s\n' "$status"
  printf 'diff --stat: %s\n' "$diffstat"
} >> "$file"

printf '%s' "$session_id" > "$dir/latest"
