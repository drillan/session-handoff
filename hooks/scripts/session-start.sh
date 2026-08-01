#!/usr/bin/env bash
# SessionStart(matcher: compact) フック。
# exit 0 時の stdout がそのままコンテキストへ入るため、平文をそのまま出す。
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib.sh"

# compact 直後はコンテキストが逼迫している。全文を注入すると圧縮で得た削減を打ち消す。
MAX_CHARS=1500

# compact プロファイルで注入する見出し（§6.4）。
INJECT_SECTIONS=("いま何をしているか" "未完了・次の一手" "試して駄目だったこと")
# 注入しない見出しの候補（§5.1 の定義順）。実際に案内するのは、このうち
# 引き継ぎファイルに実在するものだけに絞る（下記ループ）。存在しないセクションを
# 「Read すること」と案内すると、無い内容を取りに行かせるか、あるものと誤信させる
# ため（もっともらしい値で空欄を埋めない、という原則をフックの stdout にも適用する）。
DEFER_CANDIDATES=("背景・目的" "完了したこと" "決定と根拠" "恒久知見の候補" "注意" "自動追記ログ")

input=$(cat)
session_id=$(require_field "$input" session_id)
cwd=$(require_field "$input" cwd)

file=$(handoff_path "$cwd" "$session_id")

if [ ! -f "$file" ]; then
  printf '[session-handoff] 引き継ぎファイルなし\n'
  exit 0
fi

updated=$(frontmatter_value "$file" updated)
updated_by=$(frontmatter_value "$file" updated_by)
[ -n "$updated_by" ] || updated_by="不明"

# updated が欠落していても、解釈できない値でも「不明」を出して注入は続ける。
# ここで exit すると 3 セクションごと捨てることになり、鮮度が分からないという
# 小さな損失のために引き継ぎ全体を失う。§7 の「取得できなかった事実を書く」に従う。
elapsed="不明"
if [ -n "$updated" ]; then
  elapsed=$(elapsed_ja "$updated") || elapsed="不明"
fi

# 実在するかどうかは section() が空文字を返すかどうかで判定する。
# 予算超過で落ちたセクションはここでは扱わない（既存の
# 「（予算超過のため省略: <名>）」通知の役割であり、混ぜない）。
defer_present=""
for h in "${DEFER_CANDIDATES[@]}"; do
  if [ -n "$(section "$file" "$h")" ]; then
    if [ -n "$defer_present" ]; then
      defer_present="${defer_present}／${h}"
    else
      defer_present="$h"
    fi
  fi
done

# 案内すべきセクションが1つも実在しなければ、案内行自体を出さない（空の括弧を出さない）。
if [ -n "$defer_present" ]; then
  footer=$(printf '全文: %s\n（%s は上記ファイルを Read すること）\n' "$file" "$defer_present")
else
  footer=$(printf '全文: %s\n' "$file")
fi
header=$(printf '[session-handoff] 引き継ぎあり（最終更新: %s / by %s）\n' "$elapsed" "$updated_by")

# 予算は実際の出力形（各 printf の改行込み）と一致させる。
# さらに「省略しました」通知そのものの文字数も差し引く。通知は全セクションが
# 落ちた場合が最長になるため、その最悪ケースを先に予約しておく。事後に
# 通知コストを差し引くと、通知を書き足した結果 1500 字を超える恐れがある。
header_cost=$(printf '%s\n\n' "$header" | wc -m)
footer_cost=$(printf '%s\n' "$footer" | wc -m)
worst_dropped=$(IFS='、'; printf '%s' "${INJECT_SECTIONS[*]}")
notice_cost=$(printf '（予算超過のため省略: %s）\n\n' "$worst_dropped" | wc -m)

budget=$((MAX_CHARS - header_cost - footer_cost - notice_cost))

body=""
dropped=""
for h in "${INJECT_SECTIONS[@]}"; do
  s=$(section "$file" "$h")
  if [ -z "$s" ]; then
    continue
  fi
  cost=$(printf '%s\n\n' "$s" | wc -m)
  # 文字数で切ると日本語のマルチバイト境界を割るため、セクション単位で落とす。
  if [ "$cost" -gt "$budget" ]; then
    if [ -n "$dropped" ]; then
      dropped="${dropped}、${h}"
    else
      dropped="$h"
    fi
    continue
  fi
  budget=$((budget - cost))
  # コマンド置換は末尾の改行を必ず削るため、body=$(printf ...) で連結してはいけない。
  # セクション間の空行が消えて見出しが前の行に貼り付く。
  body+="$s"$'\n\n'
done

printf '%s\n\n' "$header"
# set -e の下で `[ -n "$x" ] && cmd` を使うと空のときに終了コード 1 で落ちるため if で書く。
if [ -n "$body" ]; then
  printf '%s' "$body"
fi
if [ -n "$dropped" ]; then
  printf '（予算超過のため省略: %s）\n\n' "$dropped"
fi
printf '%s\n' "$footer"
