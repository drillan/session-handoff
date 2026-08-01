#!/usr/bin/env bash
set -euo pipefail
out="${HOME}/session-handoff-dump"
mkdir -p "$out"
stamp=$(date +%s%N)
event="${1:-unknown}"
cat > "${out}/${event}-${stamp}.stdin.json"
{
  printf 'CLAUDE_PLUGIN_ROOT=%s\n' "${CLAUDE_PLUGIN_ROOT:-未設定}"
  printf 'CLAUDE_PLUGIN_DATA=%s\n' "${CLAUDE_PLUGIN_DATA:-未設定}"
  printf 'CLAUDE_PROJECT_DIR=%s\n' "${CLAUDE_PROJECT_DIR:-未設定}"
  printf 'PWD=%s\n' "$PWD"
} > "${out}/${event}-${stamp}.env"
