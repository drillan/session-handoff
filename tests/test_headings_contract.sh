#!/usr/bin/env bash
# 見出し契約のテスト（最終レビュー I-3）。
#
# §5.1 の 9 見出しは、書く側（skills/handoff/SKILL.md）と読む側
# （hooks/scripts/session-start.sh、skills/handoff-load/SKILL.md）が
# 文字列一致で共有している唯一の契約。片方だけ言い換えると抽出が静かに失敗し、
# 引き継ぎが空になったことに誰も気づかない。
#
# 他のテストは 9 セクションの fixture を手書きしているので、SKILL.md 側で
# 見出しが変わってもすべて緑のまま通る。この契約だけは実ファイル同士を
# 突き合わせないと守れない。
set -uo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/helper.sh"

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skill="$root/skills/handoff/SKILL.md"
loader="$root/skills/handoff-load/SKILL.md"
hook="$root/hooks/scripts/session-start.sh"

# SKILL.md の ```markdown フェンスから 9 見出しを取り出す。
mapfile -t skill_headings < <(
  sed -n '/^```markdown$/,/^```$/p' "$skill" | sed -n 's/^## //p'
)

assert_eq "${#skill_headings[@]}" "9" "handoff/SKILL.md のフェンスに見出しが 9 つある"

# session-start.sh が持つ 2 配列の和集合が、その 9 つと順不同で一致すること。
# shellcheck disable=SC1090
INJECT_SECTIONS=() DEFER_CANDIDATES=()
eval "$(grep -E '^(INJECT_SECTIONS|DEFER_CANDIDATES)=' "$hook")"

hook_all=("${INJECT_SECTIONS[@]}" "${DEFER_CANDIDATES[@]}")
assert_eq "${#hook_all[@]}" "9" "session-start.sh の 2 配列は合計 9 見出し"

skill_sorted=$(printf '%s\n' "${skill_headings[@]}" | LC_ALL=C sort)
hook_sorted=$(printf '%s\n' "${hook_all[@]}" | LC_ALL=C sort)
assert_eq "$hook_sorted" "$skill_sorted" \
  "session-start.sh の見出しが handoff/SKILL.md と一致する"

# 注入対象 3 つは §6.4 が名指ししている固定の集合。
inject_sorted=$(printf '%s\n' "${INJECT_SECTIONS[@]}" | LC_ALL=C sort)
expected_inject=$(printf '%s\n' "いま何をしているか" "未完了・次の一手" "試して駄目だったこと" | LC_ALL=C sort)
assert_eq "$inject_sorted" "$expected_inject" "注入対象は §6.4 の 3 セクション"

# 2 配列は重複してはならない。重複すると同じセクションが注入と案内の両方に出る。
dup=$(printf '%s\n' "${hook_all[@]}" | LC_ALL=C sort | uniq -d)
assert_eq "$dup" "" "INJECT_SECTIONS と DEFER_CANDIDATES に重複が無い"

# handoff-load が候補一覧の抽出に使う見出しも、同じ文字列でなければならない。
if grep -qF '## いま何をしているか' "$loader"; then
  assert_eq "ok" "ok" "handoff-load/SKILL.md が「## いま何をしているか」を使う"
else
  assert_eq "見つからない" "ok" "handoff-load/SKILL.md が「## いま何をしているか」を使う"
fi

# pre-compact.sh がスタブに書く見出しも注入対象でなければ、警告が context に届かない。
# 行頭一致で数える。説明コメント中の「## いま何をしているか」を巻き込まないため。
assert_eq \
  "$(grep -c '^## いま何をしているか$' "$root/hooks/scripts/pre-compact.sh")" "1" \
  "pre-compact.sh のスタブが注入対象の見出しの下に警告を置く"

# スタブ末尾の `## 自動追記ログ` 見出し。これが無いと以降の追記が
# `## いま何をしているか` の内側に入り、git のノイズが警告と一緒に注入される。
assert_eq \
  "$(grep -c '^## 自動追記ログ$' "$root/hooks/scripts/pre-compact.sh")" "1" \
  "pre-compact.sh のスタブが `## 自動追記ログ` 見出しを置く"

finish
