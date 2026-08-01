#!/usr/bin/env bash
# Task 1 計測用の暫定スクリプト。実装完了時に削除する。
#
# 引数:
#   $1 イベント名（出力ファイル名に使う）
#   $2 hooks.json 側で ${CLAUDE_PLUGIN_DATA} を単一引用符で囲んで渡したもの
#   $3 hooks.json 側で ${CLAUDE_PLUGIN_ROOT} を単一引用符で囲んで渡したもの
#
# $2 / $3 は「Claude Code が command 文字列を展開するか」を判定するために存在する。
# 単一引用符なので bash 自身は展開しない。したがって受け取った値が
#   実パス                → Claude Code が展開している
#   ${CLAUDE_...} のまま  → Claude Code はこのトークンを知らない
# と読み分けられる。環境変数として export されるかは別問題なので両方記録する。
#
# stdout には何も書かない。SessionStart フックの stdout はそのまま
# コンテキストに入るため、計測が本番の挙動を汚してはならない。
set -euo pipefail

out="${HOME}/session-handoff-dump"
mkdir -p "$out"
stamp=$(date +%s%N)
event="${1:-unknown}"
base="${out}/${event}-${stamp}"

cat > "${base}.stdin.json"

{
  printf '# command 文字列に埋め込んだ値（Claude Code による展開の有無を見る）\n'
  printf 'ARG_PLUGIN_DATA=%s\n' "${2-引数なし}"
  printf 'ARG_PLUGIN_ROOT=%s\n' "${3-引数なし}"
  printf '\n# 子プロセスの環境変数として渡ってきた値\n'
  printf 'ENV_CLAUDE_PLUGIN_ROOT=%s\n' "${CLAUDE_PLUGIN_ROOT:-未設定}"
  printf 'ENV_CLAUDE_PLUGIN_DATA=%s\n' "${CLAUDE_PLUGIN_DATA:-未設定}"
  printf 'ENV_CLAUDE_PROJECT_DIR=%s\n' "${CLAUDE_PROJECT_DIR:-未設定}"
  printf 'PWD=%s\n' "$PWD"
  printf '\n# CLAUDE で始まる環境変数の全件\n'
  env | grep '^CLAUDE' | sort || printf '（なし）\n'
} > "${base}.env"
