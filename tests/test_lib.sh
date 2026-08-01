#!/usr/bin/env bash
# 意図的に -e を付けない: このファイルは異常系（失敗を期待する）アサートを
# 多数含み、-e があるとその失敗時点でスクリプトが打ち切られてしまう。
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/helper.sh"
. "$HERE/../hooks/scripts/lib.sh"

# --- project_slug ---
assert_eq "$(project_slug /home/driller/foo)" "-home-driller-foo" "project_slug: スラッシュをハイフンに変換する"
assert_eq "$(project_slug /home/driller/my.proj)" "-home-driller-my-proj" "project_slug: ドットもハイフンに変換する"

# --- data_dir ---
assert_eq "$(CLAUDE_PLUGIN_DATA=/tmp/pd data_dir /home/driller/foo)" "/tmp/pd/-home-driller-foo" "data_dir: PLUGIN_DATA と slug を連結する"

out=$(unset CLAUDE_PLUGIN_DATA; data_dir /home/driller/foo 2>&1); rc=$?
assert_status "$rc" 1 "data_dir: CLAUDE_PLUGIN_DATA 未設定なら失敗する"
assert_contains "$out" "CLAUDE_PLUGIN_DATA" "data_dir: 未設定の理由を stderr に出す"

# --- handoff_path ---
assert_eq "$(CLAUDE_PLUGIN_DATA=/tmp/pd handoff_path /home/driller/foo abc123)" "/tmp/pd/-home-driller-foo/abc123.md" "handoff_path: session_id.md を付ける"

out=$(unset CLAUDE_PLUGIN_DATA; handoff_path /home/driller/foo abc123 2>&1); rc=$?
assert_status "$rc" 1 "handoff_path: CLAUDE_PLUGIN_DATA 未設定なら失敗する"
assert_not_contains "$out" "abc123.md" "handoff_path: 未設定時に壊れたパスを stdout に出さない"

# CLAUDE_PLUGIN_DATA を明示的に設定した状態で検査する。未設定に起因する失敗と
# 混同しないため（未設定なら data_dir の失敗が先に立ち、検証を試したことにならない）。
out=$(CLAUDE_PLUGIN_DATA=/tmp/pd handoff_path /home/driller/foo '../etc/passwd' 2>&1); rc=$?
assert_status "$rc" 1 "handoff_path: パス脱出する session_id を拒否する"
assert_contains "$out" "session_id" "handoff_path: 拒否理由が session_id であることを示す"
assert_not_contains "$out" "passwd.md" "handoff_path: 不正時に組み立てたパスを stdout に出さない"

# --- require_field ---
json='{"session_id":"abc","cwd":"/home/driller/foo","trigger":"auto"}'
assert_eq "$(require_field "$json" session_id)" "abc" "require_field: 値を取り出す"

out=$(require_field "$json" nosuch 2>&1); rc=$?
assert_status "$rc" 1 "require_field: 欠落項目で失敗する"
assert_contains "$out" "nosuch" "require_field: 欠落した項目名を stderr に出す"

out=$(require_field '{"session_id":""}' session_id 2>&1); rc=$?
assert_status "$rc" 1 "require_field: 空文字も欠落として扱う"

# --- frontmatter_value / section ---
tmp=$(mktemp)
cat > "$tmp" <<'MD'
---
session_id: abc123
updated: 2026-08-01T14:22:31+09:00
updated_by: handoff-skill
continues_from: zzz999   # コメント付き
---

## いま何をしているか
再試行処理を実装中。

## 未完了・次の一手
- [ ] テストを追加

## 自動追記ログ

### 2026-08-01T14:31:02+09:00 compact(auto)
branch: main
MD

assert_eq "$(frontmatter_value "$tmp" session_id)" "abc123" "frontmatter_value: 値を取り出す"
assert_eq "$(frontmatter_value "$tmp" updated_by)" "handoff-skill" "frontmatter_value: 別のキーも取れる"
assert_eq "$(frontmatter_value "$tmp" continues_from)" "zzz999" "frontmatter_value: 行末コメントを落とす"
assert_eq "$(frontmatter_value "$tmp" nosuch)" "" "frontmatter_value: 無いキーは空文字"

s=$(section "$tmp" "いま何をしているか")
assert_contains "$s" "## いま何をしているか" "section: 見出しを含む"
assert_contains "$s" "再試行処理を実装中。" "section: 本文を含む"
assert_not_contains "$s" "未完了" "section: 次の見出しの手前で止まる"
assert_eq "$(section "$tmp" "存在しない見出し")" "" "section: 無い見出しは空文字"

rm -f "$tmp"

# --- elapsed_ja ---
# 基準時刻を第2引数で明示し、実時刻に一切依存しない（秒境界をまたぐ flaky を防ぐ）。
now=1735689600
assert_eq "$(elapsed_ja "@$((now - 30))" "$now")" "30秒前" "elapsed_ja: 秒"
assert_eq "$(elapsed_ja "@$((now - 300))" "$now")" "5分前" "elapsed_ja: 分"
assert_eq "$(elapsed_ja "@$((now - 8040))" "$now")" "2時間14分前" "elapsed_ja: 時間と分"
assert_eq "$(elapsed_ja "@$((now - 432000))" "$now")" "5日前" "elapsed_ja: 日"

finish
