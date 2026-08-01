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
# 注入せず、パスだけ案内する見出し。
DEFER_SECTIONS="背景・目的／完了したこと／決定と根拠／恒久知見の候補／注意／自動追記ログ"

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

if [ -n "$updated" ]; then
  elapsed=$(elapsed_ja "$updated")
else
  elapsed="不明"
fi

# 末尾の案内文を先に組み立て、その分を予算から差し引く。
footer=$(printf '全文: %s\n（%s は上記ファイルを Read すること）\n' "$file" "$DEFER_SECTIONS")
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
