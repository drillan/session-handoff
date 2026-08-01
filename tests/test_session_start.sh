#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/helper.sh"
SCRIPT="$HERE/../hooks/scripts/session-start.sh"

workspace=$(mktemp -d)
trap 'rm -rf "$workspace"' EXIT
export CLAUDE_PLUGIN_DATA="$workspace/plugindata"

cwd="$workspace/proj"
mkdir -p "$cwd"
slug=$(printf '%s' "$cwd" | sed 's#[^a-zA-Z0-9_-]#-#g')
datadir="$CLAUDE_PLUGIN_DATA/$slug"
mkdir -p "$datadir"

# session_id は handoff_path の契約（16進数字とハイフンのみ）に合わせる。
# ブリーフ原文の "nope"/"sess1"/"sess2" は非16進文字（n,o,p,s）を含み、
# Task 2/3 で確定したこの契約に反するため、16進のみの ID に差し替える。

# --- ケース1: 引き継ぎファイルが無い ---
out=$(printf '{"session_id":"0bad0000","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT"); rc=$?
assert_status "$rc" 0 "ファイルが無くても exit 0"
assert_contains "$out" "引き継ぎファイルなし" "無いことを明示して出力する（無言で終わらない）"

# --- ケース2: 通常の引き継ぎファイル ---
two_hours_ago=$(date -d '-2 hours -14 minutes' --iso-8601=seconds)
cat > "$datadir/abc00001.md" <<MD
---
session_id: abc00001
updated: $two_hours_ago
updated_by: handoff-skill
---

## 背景・目的
定時バッチが 429 で落ちる件への対処。

## いま何をしているか
再試行処理を実装中。

## 完了したこと
- 型注釈を整えた

## 未完了・次の一手
- [ ] 429 のテストを追加

## 決定と根拠
- 固定 5 秒。理由は固定窓のため。

## 試して駄目だったこと
- HTTPAdapter(max_retries=) はステータス別の分岐ができない

## 恒久知見の候補
- レート制限は固定窓（未検証）

## 注意
- uv run python を使うこと

---

## 自動追記ログ

### 2026-08-01T14:31:02+09:00 compact(auto)
branch: main
MD

out=$(printf '{"session_id":"abc00001","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")

assert_contains "$out" "[session-handoff] 引き継ぎあり" "ヘッダ行を出す"
assert_contains "$out" "2時間14分前" "最終更新からの経過時間を出す"
assert_contains "$out" "handoff-skill" "updated_by を出す"

assert_contains "$out" "## いま何をしているか" "compact プロファイル: いま何をしているか を注入"
assert_contains "$out" "## 未完了・次の一手" "compact プロファイル: 未完了・次の一手 を注入"
assert_contains "$out" "## 試して駄目だったこと" "compact プロファイル: 試して駄目だったこと を注入"

assert_not_contains "$out" "定時バッチが 429 で落ちる件への対処。" "compact プロファイル: 背景・目的 の本文は注入しない"
assert_not_contains "$out" "型注釈を整えた" "compact プロファイル: 完了したこと の本文は注入しない"
assert_not_contains "$out" "固定 5 秒。理由は固定窓のため。" "compact プロファイル: 決定と根拠 の本文は注入しない"
assert_not_contains "$out" "uv run python を使うこと" "compact プロファイル: 注意 の本文は注入しない"

assert_contains "$out" "$datadir/abc00001.md" "全文パスを案内する"
assert_contains "$out" "背景・目的" "省いたセクション名を案内に含める"

# --- ケース3: 予算超過ならセクション単位で落とす ---
# tr はバイト単位で写像するため `tr '\0' 'あ'` は不正な UTF-8 を作る。
# wc -m が 0 を返して予算判定が素通りするので、printf で組み立てる。
long=$(printf 'あ%.0s' $(seq 3000))
cat > "$datadir/abc00002.md" <<MD
---
session_id: abc00002
updated: $(date --iso-8601=seconds)
updated_by: handoff-skill
---

## いま何をしているか
短い現在地。

## 未完了・次の一手
$long

## 試して駄目だったこと
これは落とされるはず。
MD

out=$(printf '{"session_id":"abc00002","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
chars=$(printf '%s' "$out" | wc -m)
assert_eq "$([ "$chars" -le 1500 ] && echo ok || echo "over:$chars")" "ok" "出力が 1500 文字以内に収まる"
assert_contains "$out" "短い現在地。" "予算内のセクションは残る"
assert_not_contains "$out" "あああ" "予算を超えるセクションの本文は入らない"
assert_contains "$out" "省略: 未完了・次の一手" "落としたセクション名を明示する"
assert_contains "$out" "これは落とされるはず。" "予算超過セクションの後ろでも、収まるセクションは残る（貪欲に詰める）"

# --- ケース4: 必須項目の欠落 ---
out=$(printf '{"cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT" 2>&1); rc=$?
assert_status "$rc" 1 "session_id 欠落で exit 1"
assert_contains "$out" "session_id" "欠落した項目名を stderr に出す"

# --- ケース5: session_id がパス構成要素として不正（handoff_path が拒否する経路） ---
# test_pre_compact.sh のケース7と同じ観点。file=$(handoff_path ...) は単独の
# 代入文なので、handoff_path が return 1 すれば set -e で exit 1 になり、
# exit 2（compact ブロック）には化けない。
out=$(printf '{"session_id":"../etc/passwd","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT" 2>&1); rc=$?
assert_status "$rc" 1 "session_id がパス脱出を試みても exit 1"
assert_contains "$out" "session_id" "拒否理由が session_id であることを stderr に出す"

# --- ケース6: 予算のぎりぎりでも 1500 文字を超えない（境界の回帰テスト） ---
# 2 セクションを大きくして、両方が「収まる／落ちる」の境界近くを通るようにする。
# 予算計算が省略通知の文字数を差し引き忘れると、この形（大きな本文＋通知）で
# 1500 文字を超えうる。header/footer の実長は環境（一時ディレクトリのパス長）に
# 依存するため、固定の文字数ではなく不変条件（1500 文字以内）だけを検証する。
big1=$(printf 'あ%.0s' $(seq 1300))
big2=$(printf 'あ%.0s' $(seq 300))
cat > "$datadir/abc00003.md" <<MD
---
session_id: abc00003
updated: $(date --iso-8601=seconds)
updated_by: handoff-skill
---

## いま何をしているか
$big1

## 未完了・次の一手
$big2

## 試して駄目だったこと
短い。
MD

out=$(printf '{"session_id":"abc00003","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
chars=$(printf '%s' "$out" | wc -m)
assert_eq "$([ "$chars" -le 1500 ] && echo ok || echo "over:$chars")" "ok" "2セクションが境界付近でも 1500 文字を超えない"

finish
