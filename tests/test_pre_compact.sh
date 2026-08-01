#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/helper.sh"
SCRIPT="$HERE/../hooks/scripts/pre-compact.sh"

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
export CLAUDE_PLUGIN_DATA="$workspace/plugindata"

# git リポジトリを 1 つ用意する
repo="$workspace/repo"
mkdir -p "$repo"
# 既定ブランチ名は環境依存（master のことがある）。テストを安定させるため明示する。
git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
printf 'hello\n' > "$repo/a.txt"
git -C "$repo" add a.txt
git -C "$repo" commit -q -m "初期"
printf 'changed\n' > "$repo/a.txt"

slug=$(printf '%s' "$repo" | sed 's#[^a-zA-Z0-9_-]#-#g')
datadir="$CLAUDE_PLUGIN_DATA/$slug"

# --- ケース1: 引き継ぎファイルが無い状態で発火する ---
printf '{"session_id":"sess1","cwd":"%s","trigger":"auto"}' "$repo" | bash "$SCRIPT"
rc=$?
assert_status "$rc" 0 "ファイル未作成でも exit 0"

file="$datadir/sess1.md"
assert_eq "$([ -f "$file" ] && echo yes || echo no)" "yes" "引き継ぎファイルが新規作成される"

body=$(cat "$file")
assert_contains "$body" "⚠ /handoff 未実行のまま compact が発火" "未実行の警告が入る"
assert_contains "$body" "session_id: sess1" "frontmatter に session_id が入る"
assert_contains "$body" "updated_by: pre-compact-hook" "updated_by が hook になる"
assert_contains "$body" "## 自動追記ログ" "自動追記ログの見出しが作られる"
assert_contains "$body" "compact(auto)" "trigger が記録される"
assert_contains "$body" "branch: main" "ブランチ名が記録される"
assert_contains "$body" "a.txt" "git status の内容が記録される"
assert_eq "$(cat "$datadir/latest")" "sess1" "latest に session_id が書かれる"

# --- ケース2: 同じセッションで 2 回目が発火する ---
printf '{"session_id":"sess1","cwd":"%s","trigger":"manual"}' "$repo" | bash "$SCRIPT"
body=$(cat "$file")
assert_contains "$body" "compact(manual)" "2 回目の trigger も記録される"
assert_eq "$(grep -c '^### ' "$file")" "2" "エントリが 2 件になる"
assert_eq "$(grep -c '^## 自動追記ログ' "$file")" "1" "自動追記ログの見出しは増えない"

# --- ケース3: /handoff が書いたファイルがある状態 ---
mkdir -p "$datadir"
cat > "$datadir/sess2.md" <<'MD'
---
session_id: sess2
updated: 2026-08-01T10:00:00+09:00
updated_by: handoff-skill
---

## いま何をしているか
実装中。

---

## 自動追記ログ
MD
printf '{"session_id":"sess2","cwd":"%s","trigger":"auto"}' "$repo" | bash "$SCRIPT"
body=$(cat "$datadir/sess2.md")
assert_contains "$body" "## いま何をしているか" "既存の意味情報が消えない"
assert_contains "$body" "実装中。" "既存の本文が消えない"
assert_not_contains "$body" "⚠ /handoff 未実行" "既存ファイルには警告を足さない"
assert_contains "$body" "compact(auto)" "既存ファイルにも追記される"

# --- ケース4: git リポジトリでないディレクトリ ---
plain="$workspace/plain"
mkdir -p "$plain"
printf '{"session_id":"sess3","cwd":"%s","trigger":"auto"}' "$plain" | bash "$SCRIPT"
plainslug=$(printf '%s' "$plain" | sed 's#[^a-zA-Z0-9_-]#-#g')
body=$(cat "$CLAUDE_PLUGIN_DATA/$plainslug/sess3.md")
assert_contains "$body" "not a git repository" "git でない場合はその事実を書く"

# --- ケース5: 必須項目の欠落 ---
out=$(printf '{"cwd":"%s","trigger":"auto"}' "$repo" | bash "$SCRIPT" 2>&1); rc=$?
assert_status "$rc" 1 "session_id 欠落で exit 1（exit 2 ではない）"
assert_contains "$out" "session_id" "欠落した項目名を stderr に出す"

out=$(printf '{"session_id":"x","cwd":"%s"}' "$repo" | bash "$SCRIPT" 2>&1); rc=$?
assert_status "$rc" 1 "trigger 欠落で exit 1"

# --- ケース6: 文法不正な JSON（jq 自身がパースエラーで非ゼロ終了する経路） ---
# jq のパースエラー終了コードは 1 ではない値になり得るが、require_field の呼び出しは
# 単独の代入文 `value=$(... | jq ...)` を経由するため、コマンド置換のサブシェルには
# errexit が継承されず（bash の既定挙動）、require_field 自身の `return 1` が
# 最終的な終了コードになる。pre-compact.sh は絶対に exit 2 してはならないという
# グローバル制約があるため、この経路が exit 2 に化けないことを固定する。
out=$(printf '{"session_id":"x","cwd":"%s"' "$repo" | bash "$SCRIPT" 2>&1); rc=$?
assert_status "$rc" 1 "文法不正な JSON でも exit 1（exit 2 は compact をブロックするため不可）"

finish
