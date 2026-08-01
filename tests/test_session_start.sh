#!/usr/bin/env bash
set -uo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$HERE/helper.sh"
SCRIPT="$HERE/../hooks/scripts/session-start.sh"
PRE_COMPACT_SCRIPT="$HERE/../hooks/scripts/pre-compact.sh"

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
# 経過時間の厳密な文字列（"2時間14分前" 等）は実時刻依存であり、テスト実行のタイミングに
# よって境界をまたぎうる（Task 3 の elapsed_ja flaky と同じ欠陥パターン）。
# session-start.sh は elapsed_ja を内部で1引数呼び出ししており、結合テストの外から
# 基準時刻を注入する経路が無いため、ここでは形（"時間"+数字+"分前"）だけをパターンで
# 確認し、実時刻に依存する厳密な数値の一致は求めない。
assert_eq "$(printf '%s' "$out" | grep -Eq '[0-9]+時間[0-9]+分前' && echo ok || echo "no-match")" "ok" "最終更新からの経過時間（時間+分前の形）を出す"
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
# 9セクション全部を持つファイルなら、注入した3つを除く6つ全部が §5.1 の定義順で
# 並ぶはず（レビュー指摘: 実在しないセクションを案内してはいけないが、実在するものは
# 定義順のまま欠けずに出ること）。
assert_contains "$out" "背景・目的／完了したこと／決定と根拠／恒久知見の候補／注意／自動追記ログ は上記ファイルを Read すること" "実在する6セクションが定義順で案内に並ぶ"

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
$long

## 未完了・次の一手
短い次の一手。

## 試して駄目だったこと
短い失敗談。
MD

# 巨大なセクションは INJECT_SECTIONS の 2 番目に置く。最後に置くと「落ちたセクションの
# 後ろにある短いセクションが残る」ことを確かめられず、貪欲さのテストが空振りする。
out=$(printf '{"session_id":"abc00002","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
chars=$(printf '%s' "$out" | wc -m)
assert_eq "$([ "$chars" -le 1500 ] && echo ok || echo "over:$chars")" "ok" "出力が 1500 文字以内に収まる"
assert_contains "$out" "短い失敗談。" "予算内のセクションは残る"
assert_not_contains "$out" "あああ" "予算を超えるセクションの本文は入らない"
assert_contains "$out" "省略: いま何をしているか" "落としたセクション名を明示する"
assert_contains "$out" "短い次の一手。" "予算超過セクションの後ろでも、収まるセクションは残る（貪欲に詰める）"

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

# --- ケース7: /handoff 未実行のスタブに対する結合テスト ---
# pre-compact.sh が /handoff 未実行のまま作るスタブは、警告を「## いま何をしているか」の
# 中に置く（レビュー指摘の修正）。session-start.sh の注入対象3見出しに属していれば
# compact 直後のコンテキストへ届くはずなので、実際に pre-compact.sh を発火させてから
# session-start.sh へ渡し、stdout に警告が現れることを結合の形で確認する。
printf '{"session_id":"cad00000","cwd":"%s","trigger":"auto"}' "$cwd" | bash "$PRE_COMPACT_SCRIPT" >/dev/null
out=$(printf '{"session_id":"cad00000","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
assert_contains "$out" "⚠ /handoff を実行しないまま compact が発火した" "/handoff 未実行スタブの警告が session-start.sh の stdout に現れる"

# このスタブは「## いま何をしているか」と「## 自動追記ログ」しか持たない。
# footer の案内は「実在し、かつ注入しなかったセクション」だけを列挙すべきで、
# 存在しない「背景・目的」「決定と根拠」等を Read せよと案内してはいけない
# （もっともらしい値で空欄を埋めない、という原則をフック自身の stdout にも適用する）。
assert_not_contains "$out" "背景・目的" "スタブに無いセクションを案内しない（背景・目的）"
assert_not_contains "$out" "完了したこと" "スタブに無いセクションを案内しない（完了したこと）"
assert_not_contains "$out" "決定と根拠" "スタブに無いセクションを案内しない（決定と根拠）"
assert_not_contains "$out" "恒久知見の候補" "スタブに無いセクションを案内しない（恒久知見の候補）"
assert_not_contains "$out" "注意" "スタブに無いセクションを案内しない（注意）"
assert_contains "$out" "自動追記ログ は上記ファイルを Read すること" "スタブに実在する自動追記ログは案内に出る"

# --- ケース8: 注入しなかったセクションが1つも実在しない場合、案内行自体を出さない ---
cat > "$datadir/abc00004.md" <<MD
---
session_id: abc00004
updated: $(date --iso-8601=seconds)
updated_by: handoff-skill
---

## いま何をしているか
現在地のみ。

## 未完了・次の一手
- [ ] 次の一手のみ。

## 試して駄目だったこと
- 失敗のみ。
MD

out=$(printf '{"session_id":"abc00004","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
assert_not_contains "$out" "は上記ファイルを Read すること" "案内すべきセクションが無ければ案内行自体を出さない（空の括弧を出さない）"
assert_contains "$out" "全文: $datadir/abc00004.md" "案内行が無くてもパス自体は出る"

# --- ケース9: 予算が1セクション分しかないとき、残るのは「試して駄目だったこと」 ---
# INJECT_SECTIONS の並びは §5.1 の定義順ではなく優先順位である（§6.4）。
# 定義順に戻すと、3 つのうち失うと最も高くつくこのセクションが真っ先に落ちる。
# 実際に 2026-08-01 の compact でそれが起きたので、回帰として固定する。
# 3 セクションとも同程度に大きくし、貪欲な詰め方で 1 つしか入らない状況を作る。
fill=$(printf 'あ%.0s' $(seq 900))
cat > "$datadir/abc00005.md" <<MD
---
session_id: abc00005
updated: $(date --iso-8601=seconds)
updated_by: handoff-skill
---

## いま何をしているか
現在地マーカー $fill

## 未完了・次の一手
次の一手マーカー $fill

## 試して駄目だったこと
失敗マーカー $fill
MD

out=$(printf '{"session_id":"abc00005","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
assert_contains "$out" "失敗マーカー" "予算が1つ分しか無ければ「試して駄目だったこと」が残る"
assert_not_contains "$out" "現在地マーカー" "同条件で「いま何をしているか」は落ちる"
assert_not_contains "$out" "次の一手マーカー" "同条件で「未完了・次の一手」は落ちる"
assert_contains "$out" "省略: いま何をしているか、未完了・次の一手" "落とした2つを優先順位の並びで列挙する"

finish
