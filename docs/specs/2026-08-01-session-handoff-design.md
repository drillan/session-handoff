# session-handoff プラグイン 設計

- 日付: 2026-08-01
- 状態: 設計合意済み・未実装
- 成果物: `session-handoff@skills-dir` プラグイン（skill 1 + hook 2）

## 1. 背景と課題

compact（コンテキスト圧縮）が走ると、会話の詳細が要約に置き換わる。要約は「何をしたか」を残すが、
「何を試して駄目だったか」「なぜその方針を選んだか」を落とす。結果、compact 後の Claude が
同じ袋小路へ再突入する。

自動 compact はコンテキスト逼迫時に予告なく発火するため、人間が事前に対処する余地がない。

## 2. 前提となる確定事実

公式ドキュメント（<https://code.claude.com/docs/en/hooks>, <https://code.claude.com/docs/en/plugins-reference>）で確認済み。

| 事実 | 帰結 |
| --- | --- |
| `PreCompact` は compaction をブロックできるが、コンテキストを注入できない | 書き出し専用として使う |
| `PostCompact` は decision control が None（ログ・後始末専用） | 復元経路に使えない |
| `SessionStart`（matcher `compact`）は `additionalContext` を注入できる | 唯一の復元経路 |
| `SessionStart` は exit 0 時の stdout がそのままコンテキストへ入る（大半のイベントでは stdout はデバッグログ行き） | JSON を組まず平文 print で足りる |
| exit 2 = ブロック（stderr が Claude へ）、それ以外の非ゼロ = 非ブロックエラー（transcript に `<hook name> hook error` と stderr 1 行目） | 失敗時は exit 1 |
| `command` フックの既定タイムアウトは 600 秒 | 時間制約は設計の主要因ではない |
| skills ディレクトリ配下に `.claude-plugin/plugin.json` を置くと `<name>@skills-dir` として自動読込。marketplace 不要・インストール手順不要・個人スコープ | `settings.json` を汚さずに配布できる |
| `${CLAUDE_PLUGIN_ROOT}` はプラグイン更新でパスが変わり、旧ディレクトリは約2週間で消える | 状態を置いてはいけない |
| `${CLAUDE_PLUGIN_DATA}` = `~/.claude/plugins/data/{id}/` は更新をまたいで永続。初回参照時に作成 | 状態はここへ |
| `${CLAUDE_PLUGIN_DATA}` は hook コマンドだけでなく skill 本文でも展開される | skill と hook がパス表現を共有できる |

## 3. 対象範囲

対象:

- 自動 compact および手動 `/compact` の前後で、作業状態を失わないこと
- 引き継ぎ内容の生成・保存・復元注入

非対象:

- セッションをまたぐ引き継ぎ（`--resume` 時の注入）。将来の拡張点として 10 節に記す
- 恒久知見の保存。chiso / auto-memory の管轄（9 節）
- 引き継ぎファイルの自動削除・世代管理。必要が生じてから検討する

## 4. アーキテクチャ

### 4.1 方式の選択

3 案を比較し、案 C を採用した。

| 案 | 内容 | 却下理由 |
| --- | --- | --- |
| A: compact 時一括生成 | PreCompact フックが `claude -p` で要約を生成 | 生成が失敗すると何も残らないまま compact が走る。compact のたびに追加トークンを消費する |
| B: 機械的スナップショットのみ | git 状態とトランスクリプト末尾を切り出すだけ | 意味情報が残らない。「なぜ」「何が駄目だったか」は git 状態から復元できない |
| **C: 継続更新型（採用）** | skill が意味情報を先に書き、フックは機械的差分のみ追記 | — |

案 C の核心は、**意味情報が compact 発火より前にすでにディスク上にある**こと。
フックがモデルを呼ばないため、タイムアウトも追加トークンも発生しない。

弱点は「節目で `/handoff` を呼ぶ規律」に依存すること。これは注入時に最終更新からの経過時間を
表示して鮮度を可視化することで補う（6.2 節）。

### 4.2 リポジトリ構成と配置

リポジトリ本体は `~/repo/session-handoff/`。`~/.claude/skills/session-handoff` から
シンボリックリンクを張る。既存スキル（chiso・xfetch・vault-fetch・vw-secrets）と同じ方式。

リポジトリのルートがそのままプラグインルートになる。

```text
~/repo/session-handoff/              ← git リポジトリ = プラグインルート
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── handoff/
│       └── SKILL.md
├── hooks/
│   ├── hooks.json
│   └── scripts/
│       ├── pre-compact.sh
│       └── session-start.sh
├── docs/
│   └── specs/
│       └── 2026-08-01-session-handoff-design.md
├── README.md
└── .gitignore

~/.claude/skills/session-handoff -> /home/driller/repo/session-handoff
```

`settings.json` は変更しない。

プラグイン名は `session-handoff`。読み込み名は `session-handoff@skills-dir`、
スラッシュコマンドは `/handoff`（SKILL.md の frontmatter `name` に由来し、プラグイン名とは独立）。

### 4.2.1 実装セッションの作業ディレクトリ

`~/.claude/hooks/block-external-path.sh` は、cwd・`$PROJECT_ROOT`・`/tmp`・`$HOME/.claude` 以外への
Edit / Write に確認を求める。実装は cwd を `~/repo/session-handoff` にして開始すること。
`~/.claude` を cwd にしたまま実装すると、ファイル書き込みのたびに確認が入る。

### 4.3 責任分割

| 部品 | 発火契機 | 役割 | モデル呼び出し |
| --- | --- | --- | --- |
| `/handoff` skill | 人間の指示、または Claude が節目と判断したとき | 会話全体から意味的な引き継ぎメモを作成・更新 | あり |
| `pre-compact.sh` | `PreCompact`（auto / manual 両方） | 時刻・trigger・git 状態を機械的に追記 | なし |
| `session-start.sh` | `SessionStart`（matcher `compact`） | 冒頭 2 セクション＋パスを stdout へ出力 | なし |

### 4.4 データ配置

ルート: `${CLAUDE_PLUGIN_DATA}` = `~/.claude/plugins/data/session-handoff-skills-dir/`

```text
<project-slug>/
├── <session_id>.md   引き継ぎ本体
└── latest            最終更新セッションの session_id（テキスト1行）
```

`<project-slug>` は hook 入力の `cwd` から導出する。Claude Code 内部の命名規則に依存せず、
本プラグインが自前で定義する:

```sh
project_slug=$(printf '%s' "$cwd" | sed 's#[^a-zA-Z0-9_-]#-#g')
```

session_id 単位にする理由は、worktree による並行セッションで 1 ファイルを奪い合わないため。
`latest` は将来の `--resume` 対応（10 節）で使う索引であり、現時点では書き込むのみ。

## 5. 引き継ぎファイル形式

前半を Claude が書く意味情報、後半をフックが書く機械ログとする二層構造に固定する。

```markdown
---
session_id: 0322f6d5-5cc1-495b-a0f1-72ba644d9013
project: /home/driller/foo
updated: 2026-08-01T14:22:31+09:00
updated_by: handoff-skill
---

## いま何をしているか
CSV ダウンローダの再試行処理を実装中。仕様は決まったが実装は未着手。

## 完了したこと
- `download_csv.py` の型注釈整備（mypy strict 通過を確認）
- 失敗時の挙動を合意: 例外送出、既定値での続行はしない

## 未完了・次の一手
- [ ] `test_download_csv.py` に 429 応答のテストを追加（テストファースト）
- [ ] 実装は上記テストが赤になってから

## 決定と根拠
- リトライ間隔は指数バックオフではなく固定 5 秒
  - なぜ: 対象 API のレート制限が固定窓のため、指数化しても待ち時間が伸びるだけ
  - 却下: tenacity 導入（依存を1つ増やすほどの複雑さがない）

## 試して駄目だったこと
- `requests` の `HTTPAdapter(max_retries=)` — ステータスごとの分岐ができず要件を満たせない

## 恒久知見の候補
- 対象 API のレート制限は固定窓（未検証、要出典）

## 注意
- `python3` 直接実行はフックでブロックされる。`uv run python` を使うこと

---

## 自動追記ログ

### 2026-08-01T14:31:02+09:00 compact(auto)
branch: feat/retry
status:
 M python/src/hd_station/download_csv.py
diff --stat: 2 files changed, 18 insertions(+), 3 deletions(-)
```

### 5.1 見出しの固定

`session-start.sh` が `## いま何をしているか` と `## 未完了・次の一手` を文字列一致で抽出する。
skill が見出しを言い換えると抽出が失敗するため、**見出し文字列は変更禁止**とし、
SKILL.md にその旨を明記する。

### 5.2 frontmatter の役割

`updated` は注入時に「最終更新から何時間経過」を算出するために使う。
鮮度が見えないと、古い引き継ぎを最新と誤認する。4.1 節の弱点への対処。

`updated_by` は `handoff-skill` または `pre-compact-hook` を取り、
意味情報が入っているのか機械ログだけなのかを区別する。

### 5.3 「試して駄目だったこと」を独立させる理由

compact で最も失われやすく、失うと最も高くつく情報だから。
要約は「何をしたか」を残すが「何をしなかったか」は落とす。

## 6. フック仕様

### 6.1 hooks.json

パス置換を含むため exec 形式（`args` あり）を使う。

```json
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
```

### 6.2 pre-compact.sh

入力: stdin の JSON。使用する項目は `session_id`・`cwd`・`trigger`。

処理:

1. `set -euo pipefail`
2. stdin を `jq` で解析。必要な項目が欠けていれば stderr にその項目名を出力し exit 1
3. `${CLAUDE_PLUGIN_DATA}/<project-slug>/` を作成
4. `<session_id>.md` が存在しなければ新規作成し、冒頭に
   `⚠ /handoff 未実行のまま compact が発火。以下は機械ログのみ` を記録する
5. `## 自動追記ログ` 配下に 1 エントリ追記（時刻・trigger・branch・`git status --short`・`git diff --stat`）
6. `latest` に session_id を書く
7. exit 0

`git` が使えないディレクトリでは `not a git repository` と明記して書く。項目自体を省略しない。

### 6.3 session-start.sh

入力: stdin の JSON。使用する項目は `session_id`・`cwd`。

処理:

1. `<project-slug>/<session_id>.md` を読む
2. 見つからなければ `[session-handoff] 引き継ぎファイルなし` を stdout に出力して exit 0
   （無言で終了しない）
3. frontmatter の `updated` から経過時間を算出
4. `## いま何をしているか` と `## 未完了・次の一手` を抽出
5. ヘッダ行・抽出結果・全文パス・残りセクションの案内を stdout へ出力し exit 0

出力例:

```text
[session-handoff] 引き継ぎあり（最終更新: 2時間14分前 / by handoff-skill）

## いま何をしているか
CSV ダウンローダの再試行処理を実装中。仕様は決まったが実装は未着手。

## 未完了・次の一手
- [ ] test_download_csv.py に 429 応答のテストを追加（テストファースト）
- [ ] 実装は上記テストが赤になってから

全文: ~/.claude/plugins/data/session-handoff-skills-dir/-home-driller-foo/0322f6d5-....md
（決定と根拠・試して駄目だったこと・注意 は上記ファイルを Read すること）
```

### 6.4 注入予算

上限は stdout 出力全体で 1500 文字（全角・半角を区別せず 1 文字として数える。`wc -m` 基準）。
超過時は末尾を切り詰め、`（切り詰め済み。全文はファイル参照）` を明記する。

全文を注入すると compact で得た削減を打ち消すため、要約とパスのみを注入し、
詳細は Claude が `Read` で取りに行く設計とする。

## 7. エラー方針

原則は「明示的エラー伝播」。ただし PreCompact でのブロックは有害なため、そこだけ扱いを分ける。

**PreCompact で exit 2（ブロック）してはならない。** compact が止まると、コンテキストが逼迫した
まま session が続き、引き継ぎを書く余地すら失われる。

採用する規則:

- 両スクリプトとも失敗時は **exit 1**（非ブロックエラー）。transcript に
  `<hook name> hook error` と stderr 1 行目が表示される
- これは既定値で黙って続行することではない。**エラーは必ず可視化し、compact だけは妨げない**
- 成功を装う経路を作らない。`|| true` や `2>/dev/null` で失敗を握りつぶさない
- 値が取得できない項目は空欄にせず、取得できなかった事実を書く
  （`not a git repository`、`⚠ /handoff 未実行` など）

## 8. /handoff skill 仕様

### 8.1 呼ぶべきタイミング

- 人間が「引き継いで」等と指示したとき
- 大きな作業単位が一区切りしたとき
- 長い調査・試行錯誤の直後（駄目だった選択肢の記録価値が最も高い）

### 8.2 手順

1. `${CLAUDE_PLUGIN_DATA}/<project-slug>/<session_id>.md` を `Read`（存在すれば）
2. 会話全体から各セクションを更新する。既存記述は消さず、古くなった項目のみ書き換える
3. frontmatter の `updated` と `updated_by: handoff-skill` を更新
4. `Write` で保存
5. 更新したセクション名を人間に報告する

### 8.3 制約

- 5.1 節の見出し文字列を変更しない
- 会話から確認できないことを書かない。不明なものは「不明」と明記する
- 「試して駄目だったこと」を空にしない。該当が無ければ「なし」と書く
- 確証のない事実には「未検証」を付す
- 保存の代行をしない。恒久知見は「恒久知見の候補」に列挙するだけ

### 8.4 description の書式

`skill-description-style` の規則に従う。「何を」＋「いつ」の 2 文、100〜250 字、
トリガー語の羅列を避ける。

## 9. 他レイヤとの境界

| レイヤー | 状態 | 扱うもの | 保存先 |
| --- | --- | --- | --- |
| auto-memory | 稼働中 | 恒久的な事実・好み・方針 | `~/.claude/projects/<slug>/memory/` |
| chiso | 製作中 | 再導出コストの高い検証済み知見 | chiso CLI |
| session-handoff | 本設計 | 会話スコープの作業状態 | `${CLAUDE_PLUGIN_DATA}` |

auto-memory は「この会話にだけ関係することは保存しない」と定めている。引き継ぎ情報は定義上
会話スコープなので auto-memory には入れない。これが第 3 のレイヤーを設ける根拠。

`/handoff` は chiso / auto-memory への保存を実行しない。候補を列挙するのみ。
chiso が未完成であるため、存在しないコマンドに依存する設計を避ける意図もある。
chiso 完成後もこの設計は変更不要。

## 10. 将来の拡張点

いずれも本実装の範囲外。必要になってから着手する。

- `SessionStart` の matcher に `resume` を追加し、セッションをまたぐ引き継ぎに対応する
  （`latest` はこのために書き込んでいる）
- 引き継ぎファイルの世代管理・削除
- トランスクリプト末尾の生ログ切り出し（`/handoff` から compact までの空白を埋める）

## 11. 未検証事項

実装前に確認を要する。推測のまま実装しない。

- `PreCompact` と `SessionStart` の stdin JSON の正確な項目名。公式ドキュメントは共通項目
  （`session_id`・`transcript_path`・`cwd`・`hook_event_name`）と `PreCompact` の `trigger`、
  `SessionStart` の `source` を示すが、イベントごとの完全なスキーマは未確認。
  実装時に stdin をファイルへ落として実物を確認する
- `${CLAUDE_PLUGIN_DATA}` の実際の展開値。`session-handoff@skills-dir` に対して
  `~/.claude/plugins/data/session-handoff-skills-dir/` になる想定だが、実測で確認する
- **シンボリックリンク越しに skills-dir プラグインが認識されるか。** 既存のシンボリックリンクは
  すべて素のスキルであり、`.claude-plugin/plugin.json` を持つディレクトリでの動作は
  公式ドキュメントに記載がない。最初に検証する項目。認識されない場合は、実体を
  `~/.claude/skills/session-handoff/` に置いてそこを git 管理する形へ切り替える
- `${CLAUDE_PLUGIN_ROOT}` の解決先がシンボリックリンクのパス
  （`~/.claude/skills/session-handoff/`）か実体のパス（`~/repo/session-handoff/`）か。
  hooks.json のスクリプトパスが解決できればどちらでも支障はないが、実測で確認する
