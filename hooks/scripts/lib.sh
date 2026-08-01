#!/usr/bin/env bash
# 意図的に set -euo pipefail を置かない: source される純関数ライブラリであり、
# 呼び出し元のシェルオプションを書き換えてはならない。特に -e を入れると
# tests/test_lib.sh の「失敗を期待するアサート」の実行が途中で打ち切られる。
# session-handoff の両フックが共有する純関数。副作用を持たない。

# cwd から一意なディレクトリ名を作る。
# Claude Code 内部の命名規則には依存せず、本プラグインが自前で定義する。
project_slug() {
  printf '%s' "$1" | sed 's#[^a-zA-Z0-9_-]#-#g'
}

# このプロジェクトの引き継ぎを置くディレクトリ。
data_dir() {
  if [ -z "${CLAUDE_PLUGIN_DATA:-}" ]; then
    printf 'CLAUDE_PLUGIN_DATA が設定されていません\n' >&2
    return 1
  fi
  printf '%s/%s' "$CLAUDE_PLUGIN_DATA" "$(project_slug "$1")"
}

# 引き継ぎファイルのパス。
handoff_path() { # <cwd> <session_id>
  local d
  d=$(data_dir "$1") || return 1
  printf '%s/%s.md' "$d" "$2"
}

# stdin JSON から必須項目を取り出す。欠落・空文字はエラーにする（推測で補わない）。
# 注意: 引数の JSON 自体が構文的に不正な場合は、この関数のメッセージではなく
# jq 自身のパースエラーが stderr に出て非ゼロ終了する（値を握りつぶして
# 処理を続けることはないため、これは許容する）。
require_field() {
  local value
  value=$(printf '%s' "$1" | jq -r --arg f "$2" '.[$f] // empty')
  if [ -z "$value" ]; then
    printf '必須項目が入力 JSON にありません: %s\n' "$2" >&2
    return 1
  fi
  printf '%s' "$value"
}

# frontmatter から値を取り出す。無ければ空文字を返す。
frontmatter_value() {
  awk -v key="$2" '
    NR == 1 && $0 == "---" { inside = 1; next }
    inside && $0 == "---" { exit }
    inside {
      idx = index($0, ":")
      if (idx > 0 && substr($0, 1, idx - 1) == key) {
        v = substr($0, idx + 1)
        sub(/^[ \t]+/, "", v)
        sub(/[ \t]+#.*$/, "", v)
        sub(/[ \t]+$/, "", v)
        print v
        exit
      }
    }
  ' "$1"
}

# 「## <見出し>」から次の「## 」直前までを見出し込みで返す。
section() {
  awk -v h="## $2" '
    $0 == h { found = 1; print; next }
    found && /^## / { exit }
    found { print }
  ' "$1"
}

# ISO8601 または @エポック秒 を受け取り、現在との差を日本語で返す。
elapsed_ja() {
  local then now diff
  then=$(date -d "$1" +%s)
  now=$(date +%s)
  diff=$((now - then))
  if [ "$diff" -lt 60 ]; then
    printf '%d秒前' "$diff"
  elif [ "$diff" -lt 3600 ]; then
    printf '%d分前' "$((diff / 60))"
  elif [ "$diff" -lt 86400 ]; then
    printf '%d時間%d分前' "$((diff / 3600))" "$((diff % 3600 / 60))"
  else
    printf '%d日前' "$((diff / 86400))"
  fi
}
