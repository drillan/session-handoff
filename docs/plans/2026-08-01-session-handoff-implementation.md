# session-handoff プラグイン 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** compact をまたいで、および新規セッションへ、作業状態を失わずに引き継ぐ Claude Code プラグインを実装する。

**Architecture:** skill が意味情報を書き（`/handoff`）、PreCompact フックが機械的差分のみを追記し、SessionStart(compact) フックが抜粋を注入する。新規セッションでは `/handoff-load` skill が明示的に読み込む。フックはモデルを呼ばないため、タイムアウトも追加トークンも発生しない。

**Tech Stack:** bash（フックスクリプト）、jq（JSON 解析）、awk / sed（テキスト抽出）、依存ゼロの自作 bash テストランナー。

**元仕様:** `docs/specs/2026-08-01-session-handoff-design.md`。本計画で「§N」と書いたらこの仕様の節番号を指す。

## Global Constraints

すべてのタスクに暗黙に適用される。

- **フォールバック禁止**（§7）。`|| true`・`2>/dev/null` で失敗を握りつぶさない。値が取得できない項目は空欄にせず、取得できなかった事実を書く（`not a git repository` 等）。唯一の例外は「git リポジトリか否かの判定」で、これは失敗の抑制ではなく分岐条件なので `if git ... >/dev/null 2>&1` を許す。該当箇所にはその旨のコメントを付ける
- **PreCompact で exit 2 してはならない**（§7）。compact を止めるとコンテキスト逼迫のまま詰む。失敗時は exit 1（非ブロックエラー）
- すべての bash スクリプト冒頭は `#!/usr/bin/env bash` と `set -euo pipefail`
- **見出し文字列は変更禁止**（§5.1）。`## 背景・目的` `## いま何をしているか` `## 完了したこと` `## 未完了・次の一手` `## 決定と根拠` `## 試して駄目だったこと` `## 恒久知見の候補` `## 注意` `## 自動追記ログ`
- `python3` を直接実行しない（ユーザー環境のフックがブロックする）
- コミットメッセージは日本語。末尾に `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>` を付ける
- 作業ディレクトリは `~/repo/session-handoff`。ここ以外への書き込みはユーザー環境のフックが確認を求める（§4.2.1）
- ブランチは `main`

## ファイル構成

| ファイル | 責任 | 作成タスク |
| --- | --- | --- |
| `hooks/scripts/lib.sh` | 両フックが共有する純関数（パス導出・JSON 項目取得・frontmatter 読み取り・セクション抽出・経過時間整形） | Task 2 |
| `hooks/scripts/pre-compact.sh` | PreCompact 時に機械ログを追記し `latest` を更新する | Task 3 |
| `hooks/scripts/session-start.sh` | SessionStart(compact) 時に compact プロファイルを stdout へ出す | Task 4 |
| `hooks/hooks.json` | フック登録 | Task 5 |
| `.claude-plugin/plugin.json` | プラグインマニフェスト（既存。description を実態に合わせる） | Task 5 |
| `skills/handoff/SKILL.md` | 引き継ぎを書く | Task 6 |
| `skills/handoff-load/SKILL.md` | 引き継ぎを読む | Task 7 |
| `tests/helper.sh` | assert ヘルパー | Task 2 |
| `tests/run.sh` | 全テスト実行 | Task 2 |
| `tests/test_lib.sh` | `lib.sh` のテスト | Task 2 |
| `tests/test_pre_compact.sh` | `pre-compact.sh` のテスト | Task 3 |
| `tests/test_session_start.sh` | `session-start.sh` のテスト | Task 4 |
| `README.md` | 導入手順と使い方 | Task 8 |

分割方針: フックスクリプト 2 本は発火契機も入出力も異なるので分ける。両者が共有する純関数だけを `lib.sh` に切り出す。`lib.sh` は副作用を持たない（ファイル書き込みをしない）ため単体テストが容易になる。

---

### Task 1: フック入力の実測と仕様の確定

§11 の未検証事項を潰す。推測のまま実装しない。

**Files:**
- Create: `hooks/hooks.json`（このタスク限りの暫定内容。Task 5 で書き換える）
- Create: `hooks/scripts/dump-input.sh`（このタスクで作り、末尾で削除する）
- Modify: `docs/specs/2026-08-01-session-handoff-design.md`（§11 に実測結果を反映）

**Interfaces:**
- Consumes: なし
- Produces: 実測済みの stdin JSON 項目名と `${CLAUDE_PLUGIN_DATA}` の展開値。Task 2 以降がこれに依存する

- [ ] **Step 1: ダンプ用スクリプトを作る**

```bash
mkdir -p hooks/scripts
cat > hooks/scripts/dump-input.sh <<'EOF'
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
EOF
chmod +x hooks/scripts/dump-input.sh
```

- [ ] **Step 2: 暫定 hooks.json を書く**

```bash
cat > hooks/hooks.json <<'EOF'
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/scripts/dump-input.sh", "PreCompact"]
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/scripts/dump-input.sh", "SessionStart"]
          }
        ]
      }
    ]
  }
}
EOF
```

- [ ] **Step 3: フックを読み込ませる**

Run: `/reload-plugins`（Claude Code 内で実行）
確認: `claude plugin list` で `session-handoff@skills-dir` が `✔ loaded` であること

- [ ] **Step 4: 実際に compact を起こす**

Claude Code 内で `/compact` を 1 回実行する。会話が短くて compact が走らない場合は、適当なファイルをいくつか読んで文脈を膨らませてから再実行する。

- [ ] **Step 5: 捕まえた JSON と環境変数を確認する**

Run:
```bash
ls -1 ~/session-handoff-dump/
jq -S 'keys' ~/session-handoff-dump/PreCompact-*.stdin.json
jq -S '.' ~/session-handoff-dump/PreCompact-*.stdin.json
jq -S 'keys' ~/session-handoff-dump/SessionStart-*.stdin.json
cat ~/session-handoff-dump/*.env
```

期待: `PreCompact` の JSON に `session_id`・`cwd`・`trigger` が存在する。`SessionStart` の JSON に `session_id`・`cwd`・`source` が存在する。`CLAUDE_PLUGIN_DATA` が `~/.claude/plugins/data/session-handoff-skills-dir` に展開されている。

**期待と違った場合は実装を止め、実測値を仕様に反映してから先へ進む。** 項目名が違えば Task 2 以降のコードを実測値に合わせて書き換える。

- [ ] **Step 6: 仕様の §11 を実測結果で置き換える**

`docs/specs/2026-08-01-session-handoff-design.md` の「## 11. 未検証事項」から、実測で解消した項目を削除し、`### 11.1 検証済み（2026-08-01）` に実測値を追記する。JSON の全項目名と `CLAUDE_PLUGIN_DATA` の実値を書く。

- [ ] **Step 7: 後始末とコミット**

```bash
rm -f hooks/scripts/dump-input.sh
rm -rf ~/session-handoff-dump
git add -A
git commit -m "検証: フック入力 JSON と CLAUDE_PLUGIN_DATA を実測し仕様に反映

PreCompact / SessionStart の stdin JSON 項目名と、
skills-dir プラグインにおける CLAUDE_PLUGIN_DATA の展開値を実測した。
§11 の未検証事項を解消。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

`hooks/hooks.json` は暫定内容のまま残る（Task 5 で正式版に置き換える）。この時点で参照先の `dump-input.sh` が消えているため、フックはエラーを出す。Task 5 まで `/reload-plugins` を実行しないこと。

---

### Task 2: テスト基盤と lib.sh

**Files:**
- Create: `tests/helper.sh`
- Create: `tests/run.sh`
- Create: `tests/test_lib.sh`
- Create: `hooks/scripts/lib.sh`

**Interfaces:**
- Consumes: Task 1 で確定した `${CLAUDE_PLUGIN_DATA}` の展開値
- Produces: `lib.sh` が以下の関数を提供する。Task 3・4 がこれを `source` して使う。
  - `project_slug <cwd>` → slug 文字列を stdout
  - `data_dir <cwd>` → `${CLAUDE_PLUGIN_DATA}/<slug>` を stdout。`CLAUDE_PLUGIN_DATA` 未設定なら stderr にメッセージを出し return 1
  - `handoff_path <cwd> <session_id>` → `<data_dir>/<session_id>.md` を stdout
  - `require_field <json文字列> <項目名>` → 値を stdout。空または欠落なら stderr にメッセージを出し return 1
  - `frontmatter_value <file> <key>` → frontmatter の値を stdout。無ければ空文字
  - `section <file> <見出し文字列>` → `## <見出し>` から次の `## ` 直前までを見出し込みで stdout。無ければ空文字
  - `elapsed_ja <ISO8601文字列>` → `3分前` `2時間14分前` `5日前` のような日本語を stdout

- [ ] **Step 1: assert ヘルパーを書く**

```bash
mkdir -p tests
cat > tests/helper.sh <<'EOF'
#!/usr/bin/env bash
# テスト用 assert ヘルパー。各 test_*.sh から source する。

TESTS=0
FAILED=0

assert_eq() { # <実際> <期待> <説明>
  TESTS=$((TESTS + 1))
  if [ "$1" = "$2" ]; then
    printf '  ok   %s\n' "$3"
  else
    printf '  FAIL %s\n       期待: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
    FAILED=$((FAILED + 1))
  fi
}

assert_contains() { # <全体> <含まれるべき部分文字列> <説明>
  TESTS=$((TESTS + 1))
  case "$1" in
    *"$2"*) printf '  ok   %s\n' "$3" ;;
    *)
      printf '  FAIL %s\n       含まれるべき: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
      FAILED=$((FAILED + 1))
      ;;
  esac
}

assert_not_contains() { # <全体> <含まれてはいけない部分文字列> <説明>
  TESTS=$((TESTS + 1))
  case "$1" in
    *"$2"*)
      printf '  FAIL %s\n       含まれてはいけない: [%s]\n       実際: [%s]\n' "$3" "$2" "$1"
      FAILED=$((FAILED + 1))
      ;;
    *) printf '  ok   %s\n' "$3" ;;
  esac
}

assert_status() { # <実際の終了コード> <期待する終了コード> <説明>
  assert_eq "$1" "$2" "$3"
}

finish() {
  printf '  --- %d 件中 %d 件失敗\n' "$TESTS" "$FAILED"
  [ "$FAILED" -eq 0 ]
}
EOF
```

- [ ] **Step 2: テストランナーを書く**

```bash
cat > tests/run.sh <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

rc=0
for f in test_*.sh; do
  printf '%s\n' "$f"
  if bash "$f"; then :; else rc=1; fi
done

if [ "$rc" -eq 0 ]; then
  printf '\n全テスト成功\n'
else
  printf '\n失敗あり\n'
fi
exit "$rc"
EOF
chmod +x tests/run.sh
```

- [ ] **Step 3: lib.sh の失敗するテストを書く**

```bash
cat > tests/test_lib.sh <<'EOF'
#!/usr/bin/env bash
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

# stderr の中身は直前の data_dir のテストで確認済み。ここは stdout に壊れたパスが
# 漏れないことだけを見るので stderr を捨てる（失敗の握りつぶしではない）。
out=$(unset CLAUDE_PLUGIN_DATA; handoff_path /home/driller/foo abc123 2>/dev/null); rc=$?
assert_status "$rc" 1 "handoff_path: data_dir が失敗したら失敗する"
assert_eq "$out" "" "handoff_path: 失敗時に壊れたパスを stdout へ出さない"

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
now=$(date +%s)
assert_eq "$(elapsed_ja "@$((now - 30))")" "30秒前" "elapsed_ja: 秒"
assert_eq "$(elapsed_ja "@$((now - 300))")" "5分前" "elapsed_ja: 分"
assert_eq "$(elapsed_ja "@$((now - 8040))")" "2時間14分前" "elapsed_ja: 時間と分"
assert_eq "$(elapsed_ja "@$((now - 432000))")" "5日前" "elapsed_ja: 日"

finish
EOF
```

- [ ] **Step 4: テストが失敗することを確認する**

Run: `bash tests/run.sh`
Expected: FAIL。`hooks/scripts/lib.sh` が存在しないため `source` に失敗する。

- [ ] **Step 5: lib.sh を実装する**

```bash
cat > hooks/scripts/lib.sh <<'EOF'
#!/usr/bin/env bash
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
# data_dir は引数位置のコマンド置換では呼ばない。引数位置だと内部が失敗しても
# 外側の printf が成功し、終了コード 0 のまま壊れたパスを返してしまう。
# 単独の代入文にして失敗を明示的に伝播させる。
handoff_path() {
  local d
  d=$(data_dir "$1") || return 1
  printf '%s/%s.md' "$d" "$2"
}

# stdin JSON から必須項目を取り出す。欠落・空文字はエラーにする（推測で補わない）。
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
EOF
```

- [ ] **Step 6: テストが通ることを確認する**

Run: `bash tests/run.sh`
Expected: PASS。`test_lib.sh` の全 assert が ok。

- [ ] **Step 7: コミット**

```bash
git add tests hooks/scripts/lib.sh
git commit -m "テスト基盤と共有関数 lib.sh を追加

依存ゼロの bash テストランナー（tests/run.sh）と assert ヘルパーを用意し、
両フックが共有する純関数を lib.sh に切り出した。
lib.sh は副作用を持たないため単体テストできる。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: pre-compact.sh

**Files:**
- Create: `hooks/scripts/pre-compact.sh`
- Create: `tests/test_pre_compact.sh`

**Interfaces:**
- Consumes: `lib.sh` の `data_dir`・`require_field`
- Produces: stdin に PreCompact の JSON を与えると、`<data_dir>/<session_id>.md` の `## 自動追記ログ` にエントリを 1 件追記し、`<data_dir>/latest` に session_id を書く。ファイルが無ければ警告ヘッダ付きで新規作成する。

- [ ] **Step 1: 失敗するテストを書く**

```bash
cat > tests/test_pre_compact.sh <<'EOF'
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

finish
EOF
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash tests/run.sh`
Expected: FAIL。`hooks/scripts/pre-compact.sh` が無い。

- [ ] **Step 3: pre-compact.sh を実装する**

```bash
cat > hooks/scripts/pre-compact.sh <<'EOF'
#!/usr/bin/env bash
# PreCompact フック。モデルを呼ばず、機械的な差分だけを追記する。
# compact を絶対に止めないため、失敗しても exit 2 は返さない（exit 1 = 非ブロックエラー）。
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
. "$SCRIPT_DIR/lib.sh"

input=$(cat)
session_id=$(require_field "$input" session_id)
cwd=$(require_field "$input" cwd)
trigger=$(require_field "$input" trigger)

dir=$(data_dir "$cwd")
mkdir -p "$dir"
file="$dir/$session_id.md"
now=$(date --iso-8601=seconds)

if [ ! -f "$file" ]; then
  cat > "$file" <<HEADER
---
session_id: $session_id
project: $cwd
updated: $now
updated_by: pre-compact-hook
---

⚠ /handoff 未実行のまま compact が発火。以下は機械ログのみ。

---

## 自動追記ログ
HEADER
fi

# git リポジトリか否かの判定。失敗の抑制ではなく分岐条件なので出力を捨ててよい。
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  branch=$(git -C "$cwd" branch --show-current)
  [ -n "$branch" ] || branch="(detached HEAD)"
  status=$(git -C "$cwd" status --short)
  [ -n "$status" ] || status="(変更なし)"
  diffstat=$(git -C "$cwd" diff --stat | tail -1)
  [ -n "$diffstat" ] || diffstat="(差分なし)"
else
  branch="not a git repository"
  status="not a git repository"
  diffstat="not a git repository"
fi

{
  printf '\n### %s compact(%s)\n' "$now" "$trigger"
  printf 'branch: %s\n' "$branch"
  printf 'status:\n%s\n' "$status"
  printf 'diff --stat: %s\n' "$diffstat"
} >> "$file"

printf '%s' "$session_id" > "$dir/latest"
EOF
chmod +x hooks/scripts/pre-compact.sh
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/run.sh`
Expected: PASS。`test_lib.sh` と `test_pre_compact.sh` の全 assert が ok。

- [ ] **Step 5: コミット**

```bash
git add hooks/scripts/pre-compact.sh tests/test_pre_compact.sh
git commit -m "PreCompact フックを実装

時刻・trigger・git 状態を機械的に追記し latest を更新する。
モデルを呼ばないためタイムアウトも追加トークンも発生しない。
/handoff 未実行のまま発火した場合は警告ヘッダ付きで新規作成する。
必須項目の欠落は exit 1（非ブロック）で報告し、compact は止めない。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: session-start.sh

仕様 §6.4 の切り詰め方針をここで見直す。「末尾を文字数で切る」は日本語のマルチバイト境界を割る危険があり、出力も読みにくい。**セクション単位で落とす**方式に変更し、仕様も更新する。

**Files:**
- Create: `hooks/scripts/session-start.sh`
- Create: `tests/test_session_start.sh`
- Modify: `docs/specs/2026-08-01-session-handoff-design.md`（§6.4 の切り詰め方針）

**Interfaces:**
- Consumes: `lib.sh` の `handoff_path`・`require_field`・`frontmatter_value`・`section`・`elapsed_ja`
- Produces: stdin に SessionStart の JSON を与えると、compact プロファイルを stdout へ出して exit 0。SessionStart は exit 0 時の stdout がそのままコンテキストへ入る（§2）。

- [ ] **Step 1: 失敗するテストを書く**

```bash
cat > tests/test_session_start.sh <<'EOF'
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

# --- ケース1: 引き継ぎファイルが無い ---
out=$(printf '{"session_id":"nope","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT"); rc=$?
assert_status "$rc" 0 "ファイルが無くても exit 0"
assert_contains "$out" "引き継ぎファイルなし" "無いことを明示して出力する（無言で終わらない）"

# --- ケース2: 通常の引き継ぎファイル ---
two_hours_ago=$(date -d '-2 hours -14 minutes' --iso-8601=seconds)
cat > "$datadir/sess1.md" <<MD
---
session_id: sess1
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

out=$(printf '{"session_id":"sess1","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")

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

assert_contains "$out" "$datadir/sess1.md" "全文パスを案内する"
assert_contains "$out" "背景・目的" "省いたセクション名を案内に含める"

# --- ケース3: 予算超過ならセクション単位で落とす ---
# tr はバイト単位で写像するため `tr '\0' 'あ'` は不正な UTF-8 を作る。
# wc -m が 0 を返して予算判定が素通りするので、printf で組み立てる。
long=$(printf 'あ%.0s' $(seq 3000))
cat > "$datadir/sess2.md" <<MD
---
session_id: sess2
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

out=$(printf '{"session_id":"sess2","cwd":"%s","source":"compact"}' "$cwd" | bash "$SCRIPT")
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

finish
EOF
```

- [ ] **Step 2: テストが失敗することを確認する**

Run: `bash tests/run.sh`
Expected: FAIL。`hooks/scripts/session-start.sh` が無い。

- [ ] **Step 3: session-start.sh を実装する**

```bash
cat > hooks/scripts/session-start.sh <<'EOF'
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

budget=$((MAX_CHARS - $(printf '%s\n%s' "$header" "$footer" | wc -m)))

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
EOF
chmod +x hooks/scripts/session-start.sh
```

- [ ] **Step 4: テストが通ることを確認する**

Run: `bash tests/run.sh`
Expected: PASS。3 つのテストファイル全部の assert が ok（`test_lib.sh` 22 件・`test_pre_compact.sh` 21 件・`test_session_start.sh` 21 件）。

この Task の全コードとテストは計画作成時にスクラッチパッドで実行し、64 件全通過を確認済み。
Expected と違う結果が出たら、環境差（`date` や `awk` の実装）を疑って原因を特定する。

予算超過時の挙動は**貪欲に詰める**。超過するセクションを飛ばして次のセクションを試すため、
落ちたセクションより後ろにある短いセクションは残る。最初の超過で打ち切らない。

- [ ] **Step 5: 仕様の §6.4 を更新する**

`docs/specs/2026-08-01-session-handoff-design.md` の §6.4 で、compact プロファイルの切り詰め方針を次のように書き換える。

変更前: 「超過時は末尾を切り詰め、`（切り詰め済み。全文はファイル参照）` を明記する。」

変更後:
```markdown
超過時は**セクション単位で丸ごと落とす**。文字数で末尾を切ると日本語のマルチバイト境界を
割る危険があり、途中で切れた文は読み手にとって有害でもある。落としたセクション名は
`（予算超過のため省略: <見出し>）` として明記し、パス案内から辿れるようにする。

詰め方は貪欲。超過するセクションを飛ばして次を試すため、落ちたセクションより後ろにある
短いセクションは残る。最初の超過で打ち切ると、後続の短く有用なセクションまで失われる。
```

- [ ] **Step 6: コミット**

```bash
git add hooks/scripts/session-start.sh tests/test_session_start.sh docs/specs/
git commit -m "SessionStart(compact) フックを実装、切り詰めをセクション単位に変更

compact プロファイルの3セクションを抽出し、最終更新からの経過時間とともに
stdout へ出す。SessionStart は exit 0 時の stdout がそのまま
コンテキストへ入るため JSON を組む必要がない。

予算超過時の扱いを仕様から変更した。文字数で末尾を切ると日本語の
マルチバイト境界を割るため、セクション単位で落として省略を明記する。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: プラグイン登録と実環境での結合検証

単体テストは通っても、実際のフック経路で動くかは別問題。ここで実物を動かす。

**Files:**
- Modify: `hooks/hooks.json`（Task 1 の暫定版を正式版に置き換える）
- Modify: `.claude-plugin/plugin.json`

**Interfaces:**
- Consumes: Task 3・4 のスクリプト
- Produces: 実環境で動作するフック。Task 6・7 の skill はこれが動いている前提で eval する

- [ ] **Step 1: 正式な hooks.json を書く**

```bash
cat > hooks/hooks.json <<'EOF'
{
  "hooks": {
    "PreCompact": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/scripts/pre-compact.sh"]
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "compact",
        "hooks": [
          {
            "type": "command",
            "command": "bash",
            "args": ["${CLAUDE_PLUGIN_ROOT}/hooks/scripts/session-start.sh"]
          }
        ]
      }
    ]
  }
}
EOF
```

- [ ] **Step 2: plugin.json を実態に合わせる**

```bash
cat > .claude-plugin/plugin.json <<'EOF'
{
  "name": "session-handoff",
  "description": "compact をまたいで、および新規セッションへ、作業状態を引き継ぐ",
  "author": { "name": "driller" }
}
EOF
```

`version` は設定しない。設定すると更新のたびに手で上げる必要があり、個人利用では commit SHA による版管理のほうが扱いやすい（§11.1）。

- [ ] **Step 3: マニフェストを検証する**

Run: `claude plugin validate .`
Expected: `✔ Validation passed`。`version` 未指定の警告は出るが無視してよい。

- [ ] **Step 4: フックを読み込ませる**

Run: `/reload-plugins`（Claude Code 内）
確認: `claude plugin list` で `session-handoff@skills-dir` が `✔ loaded`

- [ ] **Step 5: 実際に compact を起こして往復を確認する**

Claude Code 内で `/compact` を実行し、以下を確認する。

```bash
ls -la ~/.claude/plugins/data/session-handoff-skills-dir/
cat ~/.claude/plugins/data/session-handoff-skills-dir/*/latest
cat ~/.claude/plugins/data/session-handoff-skills-dir/*/*.md
```

期待:
- `<session_id>.md` が作られ、`⚠ /handoff 未実行` の警告と `## 自動追記ログ` のエントリが 1 件入っている
- `latest` に session_id が入っている
- compact 直後の Claude のコンテキストに `[session-handoff] 引き継ぎファイルなし` ではなく引き継ぎ内容が入っている（このケースでは意味情報が無いので、機械ログのみのファイルに対する出力になる）
- transcript に `PreCompact hook error` や `SessionStart hook error` が出ていない

**エラーが出た場合は次へ進まない。** transcript のエラー 1 行目を読み、原因を特定してから修正する。

- [ ] **Step 6: 意味情報がある状態でもう一度確認する**

引き継ぎファイルを手で編集して `## いま何をしているか` などのセクションを追加し、再度 `/compact` する。compact プロファイルの 3 セクションが注入され、残りがパス案内になることを確認する。

- [ ] **Step 7: コミット**

```bash
git add hooks/hooks.json .claude-plugin/plugin.json
git commit -m "フックを正式登録し実環境で結合検証

PreCompact と SessionStart(compact) を hooks.json に登録し、
実際に /compact を起こして書き出しと注入の往復を確認した。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: /handoff スキル

**REQUIRED SUB-SKILL:** このタスクは `skill-creator` スキルを使って進める。SKILL.md の起草・テストプロンプトによる eval・description の実測改善は skill-creator の担当範囲。

**Files:**
- Create: `skills/handoff/SKILL.md`

**Interfaces:**
- Consumes: Task 5 で動作確認済みのフック経路。`${CLAUDE_PLUGIN_DATA}` は skill 本文でも展開される（§2）
- Produces: `/handoff` スラッシュコマンド。書き出すファイルは §5 の形式に厳密に従う。Task 7 の `/handoff-load` がこの形式を読む

- [ ] **Step 1: skill-creator を起動する**

Claude Code 内で skill-creator スキルを呼び、「session-handoff プラグインに `/handoff` スキルを作る」と伝える。仕様の §5・§8.1〜§8.4・§8.7 を渡す。

- [ ] **Step 2: SKILL.md を起草する**

frontmatter:
```yaml
---
name: handoff
description: 現在のセッションの作業状態を引き継ぎファイルに記録・更新する。作業が一区切りしたとき、長い試行錯誤の直後、compact が近いと感じたとき、または「引き継いで」と指示されたときに使う。読み込みは handoff-load が担当する。
---
```

本文に必ず含める内容:

1. **保存先**: `${CLAUDE_PLUGIN_DATA}/<project-slug>/<session_id>.md`。`<project-slug>` は cwd の `[^a-zA-Z0-9_-]` を `-` に置換したもの
2. **手順**（§8.2）: 既存ファイルを `Read` → 全セクションを更新 → frontmatter の `updated`・`updated_by: handoff-skill`・（該当時のみ）`continues_from` を更新 → `Write` → 報告
3. **見出しは変更禁止**（§5.1）。9 つの見出し文字列をそのまま列挙する
4. **`## 自動追記ログ` 以降は書き換えない**（§8.2）。`Write` で全文を書き戻す際は `Read` で得たログをそのまま末尾に含める
5. **制約**（§8.4）:
   - 会話から確認できないことを書かない。不明なものは「不明」と明記する
   - 「試して駄目だったこと」を空にしない。該当が無ければ「なし」と書く
   - 確証のない事実には「未検証」を付す
   - chiso / auto-memory への保存を代行しない。恒久知見は「恒久知見の候補」に列挙するだけ
   - 場面による書き分けをしない。常に全セクションを書く
6. **報告の形**（§8.3）: 更新したセクション名と、続け方の 2 択

- [ ] **Step 3: テストプロンプトを用意する**

最低限この 4 つ。skill-creator の eval に渡す。

| # | プロンプト | 期待する挙動 |
| --- | --- | --- |
| 1 | 「引き継いで」 | `/handoff` が起動し、ファイルが作られる |
| 2 | 「そろそろコンテキストが厳しいので状態を保存して」 | `/handoff` が起動する |
| 3 | 「前の作業の続きをやりたい」 | `/handoff` は起動しない（`/handoff-load` の領域） |
| 4 | 「この知見を覚えておいて」 | `/handoff` は起動しない（chiso / auto-memory の領域） |

3 と 4 は**起動してはいけない**ケース。description の精度はここで測る。

- [ ] **Step 4: eval を実行して結果を確認する**

skill-creator の手順に従って実行する。3・4 で誤起動したら description を書き直して再実行する。

- [ ] **Step 5: 実際に使って書き出しを確認する**

Claude Code 内で `/handoff` を実行し、生成されたファイルが §5 の形式（frontmatter + 8 セクション + `## 自動追記ログ`）に一致することを確認する。

Run: `cat ~/.claude/plugins/data/session-handoff-skills-dir/*/*.md`

その後 `/compact` を実行し、`session-start.sh` が正しくセクションを抽出できることを確認する。**ここで抽出に失敗したら、見出し文字列の不一致を疑う。**

- [ ] **Step 6: コミット**

```bash
git add skills/handoff/SKILL.md
git commit -m "/handoff スキルを追加

会話全体から作業状態を読み取り、全セクションを引き継ぎファイルへ書く。
場面による書き分けはしない（記録は常に全セクション、注入だけが分岐する）。
自動追記ログはフックの領域として書き換えない。
description は誤起動テストで検証済み。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: /handoff-load スキル

**REQUIRED SUB-SKILL:** Task 6 と同じく `skill-creator` を使う。

**Files:**
- Create: `skills/handoff-load/SKILL.md`

**Interfaces:**
- Consumes: Task 6 の `/handoff` が書いたファイル形式（§5）
- Produces: `/handoff-load` スラッシュコマンド。読み込んだ session_id は、このセッションで最初に `/handoff` を呼ぶときに `continues_from` へ記録される

- [ ] **Step 1: SKILL.md を起草する**

frontmatter:
```yaml
---
name: handoff-load
description: 過去のセッションが残した引き継ぎを読み込み、作業を再開できる状態にする。新規セッションや /clear の直後に、前のセッションの続きをやりたいときに使う。記録は handoff が担当する。
---
```

本文に必ず含める内容（§8.5・§8.6）:

1. **自発的に呼ばない**。人間が明示的に呼んだときだけ動く。新規セッションで何を始めるかは未知であり、無関係な作業に古い引き継ぎを持ち込むのは害になる
2. **手順**:
   - `${CLAUDE_PLUGIN_DATA}/<project-slug>/` の `*.md` を列挙する
   - 各ファイルの frontmatter の `updated`・`continues_from` と `## いま何をしているか` の先頭 1 行を読む
   - `continues_from` で連なるファイル群は 1 件に畳み、最新のものだけを候補にする（畳んだ件数を併記する）
   - `latest` に記録された session_id を候補一覧の先頭に置く
   - ディレクトリが無い、または `*.md` が 0 件なら「このプロジェクトの引き継ぎは無い」と報告して終了する。**推測で代替物を探さない**
   - **候補が 1 件でも人間に確認する**。並行セッションがあると `latest` が意図と食い違いうる
   - 選ばれたファイルを `Read`（全文。fresh プロファイルはセクションの取捨選択をしない）
   - 「背景・目的」「いま何をしているか」「未完了・次の一手」と `updated` からの経過時間を要約して報告する
   - 読み込んだ session_id を覚えておき、このセッションで最初に `/handoff` を呼ぶときに `continues_from` へ記録する
3. **このスキルはファイルを書き換えない**

- [ ] **Step 2: テストプロンプトを用意する**

| # | プロンプト | 期待する挙動 |
| --- | --- | --- |
| 1 | 「前の作業の続きをやりたい」 | `/handoff-load` が起動し、候補一覧が出る |
| 2 | 「引き継ぎを読み込んで」 | `/handoff-load` が起動する |
| 3 | 「引き継いで」 | `/handoff-load` は起動しない（`/handoff` の領域） |
| 4 | （引き継ぎが 0 件の状態で）「前の作業の続きをやりたい」 | 「引き継ぎは無い」と報告する。他のファイルを探し始めない |

3 は `/handoff` との取り違えを測る中心的なケース（§8.7）。4 は推測で埋めない原則の検証。

- [ ] **Step 3: eval を実行して結果を確認する**

3 で `/handoff` と取り違えたら、両方の description の動詞の対比を強める。片方だけ直すと逆方向の誤起動が増えるので、必ず両方を見直して再実行する。

- [ ] **Step 4: 実際に使って動作を確認する**

引き継ぎファイルが 2 件以上ある状態を作り（Task 6 で 1 件、手で 1 件追加）、新規セッション（`/clear` の直後）で `/handoff-load` を実行する。候補一覧が出て、選択後に全文が読み込まれることを確認する。

- [ ] **Step 5: 0 件のケースを確認する**

引き継ぎが 1 件も無いプロジェクトへ `cd` して `/handoff-load` を実行し、「引き継ぎは無い」と報告して終わることを確認する。**他のファイルを探し始めたら description か本文の制約が弱い。**

- [ ] **Step 6: コミット**

```bash
git add skills/handoff-load/SKILL.md
git commit -m "/handoff-load スキルを追加

新規セッションで過去の引き継ぎを明示的に読み込む。
候補を一覧提示して人間に選ばせることで、latest の曖昧さ
（並行セッション）を解消する。
continues_from で連なるファイル群は 1 件に畳んで提示する。
handoff との取り違えを誤起動テストで検証済み。

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: README と仕上げ

**Files:**
- Create: `README.md`
- Modify: `docs/specs/2026-08-01-session-handoff-design.md`（状態を「実装済み」に）

**Interfaces:**
- Consumes: Task 1〜7 のすべて
- Produces: なし（最終成果物）

- [ ] **Step 1: README を書く**

含める項目:

- このプラグインが解くこと（compact で「試して駄目だったこと」が失われる問題）
- 導入手順:
  ```bash
  git clone <url> ~/repo/session-handoff
  ln -s ~/repo/session-handoff ~/.claude/skills/session-handoff
  # 次回セッションから session-handoff@skills-dir として読み込まれる
  ```
- 使い方: `/handoff`（書く）と `/handoff-load`（読む）の 2 コマンド
- 動作の説明: PreCompact で追記 → SessionStart(compact) で注入。自動 compact でも手動でも同じ経路
- 引き継ぎファイルの置き場所: `~/.claude/plugins/data/session-handoff-skills-dir/<project-slug>/`
- テストの走らせ方: `bash tests/run.sh`
- 設計文書へのリンク: `docs/specs/2026-08-01-session-handoff-design.md`
- 既知の制約:
  - `fork` / `resume` では自動注入しない（会話履歴が復元されるため大半が重複する）。仕切り直しは `/handoff-load` を明示的に呼ぶ
  - 引き継ぎファイルは自動削除しない
  - `/handoff` を呼ばないまま compact が走ると、機械ログだけが残る

- [ ] **Step 2: 全テストを走らせる**

Run: `bash tests/run.sh`
Expected: PASS。3 ファイル全部の assert が ok。

- [ ] **Step 3: 仕様の状態を更新する**

`docs/specs/2026-08-01-session-handoff-design.md` の冒頭を `- 状態: 設計合意済み・未実装` から `- 状態: 実装済み（2026-08-01）` に変える。

- [ ] **Step 4: コミット**

```bash
git add README.md docs/specs/
git commit -m "README を追加し仕様の状態を実装済みに更新

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: 最終確認**

```bash
bash tests/run.sh
claude plugin validate .
claude plugin list | grep -A5 session-handoff
git log --oneline
git status --short
```

Expected: テスト全成功、マニフェスト検証通過、プラグインが `✔ loaded`、作業ツリーがクリーン。

---

## 仕様との対応

| 仕様の節 | 実装タスク |
| --- | --- |
| §2 前提となる確定事実 | Task 1（実測で確定） |
| §4.2 リポジトリ構成 | 既存（検証済み） |
| §4.3 責任分割 | Task 3・4・6・7 |
| §4.4 データ配置 | Task 2（`data_dir`・`handoff_path`） |
| §5 ファイル形式 | Task 3（機械ログ部）・Task 6（意味情報部） |
| §5.1 見出しの固定 | Task 2（`section`）・Task 6・7（SKILL.md の制約） |
| §5.2 frontmatter | Task 2（`frontmatter_value`）・Task 3・6 |
| §6.1 hooks.json | Task 5 |
| §6.2 pre-compact.sh | Task 3 |
| §6.3 session-start.sh | Task 4 |
| §6.4 注入プロファイル | Task 4（切り詰め方針を変更） |
| §7 エラー方針 | Task 3・4（exit 1 のテストを含む） |
| §8.1〜8.4 /handoff | Task 6 |
| §8.5〜8.6 /handoff-load | Task 7 |
| §8.7 description の書式 | Task 6・7（eval で実測） |
| §9 他レイヤとの境界 | Task 6（SKILL.md の制約） |
| §10 将来の拡張点 | 実装対象外 |
| §11 未検証事項 | Task 1 |
