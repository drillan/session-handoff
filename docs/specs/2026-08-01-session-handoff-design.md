# session-handoff プラグイン 設計

- 日付: 2026-08-01
- 状態: 設計合意済み・未実装
- 成果物: `session-handoff@skills-dir` プラグイン（skill 2 + hook 2）

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

`${CLAUDE_PLUGIN_DATA}` を skill 本文でも使えるかは、当初この表に「確認済み」として
含めていたが、実測していなかったため §11 へ移した。skill が使う経路については §11.1 の
「skill から見た環境」を参照。

hook 側の「展開」については実測で補足がある。子プロセスに環境変数として export される
ことは確認したが、`command` 文字列を Claude Code が展開しているかは判定できていない
（単一引用符内では展開されなかった）。`command` 内では二重引用符で参照する。§11.1 を参照。

## 3. 対象範囲

想定する使い方は 2 つ。どちらも運ぶものは同じ「作業状態」であり、違いは注入の場面と量だけ。

1. **継続**: 作業を続けたいが compact が走る。圧縮をまたいで状態を保つ
2. **仕切り直し**: 同じ作業を、汚れていないコンテキストの新規セッションで続ける

対象:

- 自動 compact および手動 `/compact` の前後で、作業状態を失わないこと（使い方 1）
- 新規セッションから過去の引き継ぎを明示的に読み込めること（使い方 2）
- 引き継ぎ内容の生成・保存・注入

非対象:

- 手順の再利用・テンプレート化（「似た作業を別の対象へ」）。運ぶものが状態ではなく手順になり、
  必要なセクションが入れ替わる。別機能として扱う
- `SessionStart` の `fork` / `resume` への自動注入。10 節に判断理由とともに記す
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
表示して鮮度を可視化することで補う（6.3 節・8.6 節）。

### 4.2 リポジトリ構成と配置

リポジトリ本体は `~/repo/session-handoff/`。`~/.claude/skills/session-handoff` から
シンボリックリンクを張る。既存スキル（chiso・xfetch・vault-fetch・vw-secrets）と同じ方式。

リポジトリのルートがそのままプラグインルートになる。

```text
~/repo/session-handoff/              ← git リポジトリ = プラグインルート
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   ├── handoff/
│   │   └── SKILL.md
│   └── handoff-load/
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

プラグイン名は `session-handoff`。読み込み名は `session-handoff@skills-dir`。
スラッシュコマンドは `/handoff` と `/handoff-load`
（いずれも SKILL.md の frontmatter `name` に由来し、プラグイン名とは独立）。

### 4.2.1 実装セッションの作業ディレクトリ

`~/.claude/hooks/block-external-path.sh` は、cwd・`$PROJECT_ROOT`・`/tmp`・`$HOME/.claude` 以外への
Edit / Write に確認を求める。実装は cwd を `~/repo/session-handoff` にして開始すること。
`~/.claude` を cwd にしたまま実装すると、ファイル書き込みのたびに確認が入る。

### 4.3 責任分割

| 部品 | 発火契機 | 役割 | モデル呼び出し |
| --- | --- | --- | --- |
| `/handoff` skill | 人間の指示、または Claude が節目と判断したとき | 会話全体から意味的な引き継ぎメモを作成・更新 | あり |
| `/handoff-load` skill | 人間が新規セッションで明示的に呼ぶ | 引き継ぎ候補を一覧提示し、選ばれたものを読む | あり |
| `pre-compact.sh` | `PreCompact`（auto / manual 両方） | 時刻・trigger・git 状態を機械的に追記 | なし |
| `session-start.sh` | `SessionStart`（matcher `compact`） | compact プロファイルを stdout へ出力 | なし |

**記録と注入の分離** — `/handoff` は場面を問わず常に全セクションを書く。書く時点では
compact が走るのか新規セッションへ移るのか決められないため、書き分けは書き手の予測に依存する
脆い構造になる。一方、読む側は何が起きたかを確定的に知っている（フックが動いた＝compact、
人間が `/handoff-load` を呼んだ＝仕切り直し）。**判断材料を持つ側に判断させる**。
差異が現れるのは注入の量であって、記録の内容ではない（6.4 節）。

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

`latest` は `/handoff-load` が候補一覧を出すときの並び順の先頭を決めるために使う。
新規セッションでは自分の session_id で引き当てられないため、この索引が必要になる。
`pre-compact.sh`（6.2 節）と `/handoff`（8.2 節）の両方が書く。引き継ぎを更新しうる
経路はこの 2 つだけで、どちらかが書き漏らすと索引が古い値を指したまま先頭に並ぶ。
ただし並行セッションがあると「最後に更新されたもの」が意図と食い違いうるので、
`/handoff-load` は `latest` を自動採用せず、候補として提示して人間に選ばせる（8.6 節）。

## 5. 引き継ぎファイル形式

前半を Claude が書く意味情報、後半をフックが書く機械ログとする二層構造に固定する。

```markdown
---
session_id: 0322f6d5-5cc1-495b-a0f1-72ba644d9013
project: /home/driller/foo
updated: 2026-08-01T14:22:31+09:00
updated_by: handoff-skill
continues_from: 9f1c2ab4-...   # /handoff-load 経由で再開した場合のみ。無ければ項目ごと省く
---

## 背景・目的
定時バッチが対象 API の 429 で落ちる事象への対処。再試行を入れて完走させるのが目的。
対象は `python/src/hd_station/download_csv.py` と対応するテスト。

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

`session-start.sh` と `/handoff-load` が見出しを文字列一致で抽出する。
skill が見出しを言い換えると抽出が失敗するため、**見出し文字列は変更禁止**とし、
両 SKILL.md にその旨を明記する。

### 5.1.1 「背景・目的」を設ける理由

compact 後は Claude Code の要約がこの情報を保持しているため不要だが、新規セッションでは
完全に欠落する。使い方 2（仕切り直し）では、なぜこの作業をしているのかが引き継ぎファイル内に
自己完結していなければならない。

### 5.2 frontmatter の役割

`updated` は注入時に「最終更新から何時間経過」を算出するために使う。
鮮度が見えないと、古い引き継ぎを最新と誤認する。4.1 節の弱点への対処。

`updated_by` は `handoff-skill` または `pre-compact-hook` を取り、
意味情報が入っているのか機械ログだけなのかを区別する。

`continues_from` は、`/handoff-load` で読み込んだ引き継ぎの session_id を記録する。
仕切り直しを繰り返すと、同じ作業に対する引き継ぎファイルが session_id 分だけ増える。
この項目が無いと、`/handoff-load` の候補一覧に「いま何をしているか」がほぼ同じ項目が
並び、どれが最新の続きか判別できなくなる。項目があれば、生きている連鎖ごとに
1 件へ畳める（畳み方は 8.6 節。並行セッションで連鎖が枝分かれしうるため、
全体を 1 件にするのではない）。

`/handoff-load` を経由していないセッションでは**項目ごと省く**。値を空にしたり
`null` を書いたりしない。

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
4. compact プロファイル（6.4 節）のセクションを抽出
5. ヘッダ行・抽出結果・全文パス・残りセクションの案内を stdout へ出力し exit 0

出力例:

```text
[session-handoff] 引き継ぎあり（最終更新: 2時間14分前 / by handoff-skill）

## いま何をしているか
CSV ダウンローダの再試行処理を実装中。仕様は決まったが実装は未着手。

## 未完了・次の一手
- [ ] test_download_csv.py に 429 応答のテストを追加（テストファースト）
- [ ] 実装は上記テストが赤になってから

## 試して駄目だったこと
- requests の HTTPAdapter(max_retries=) — ステータスごとの分岐ができず要件を満たせない

全文: ~/.claude/plugins/data/session-handoff-skills-dir/-home-driller-foo/0322f6d5-....md
（背景・目的／完了したこと／決定と根拠／恒久知見の候補／注意／自動追記ログ は上記ファイルを Read すること）
```

案内に並ぶのは、注入しなかった見出しのうち引き継ぎファイルに実在するものだけ（6.4節）。
`/handoff` 未実行のスタブのように一部の見出ししか無いファイルでは、実在するものだけが
並び、無いものは案内されない。1つも実在しなければ案内行自体が出ない。

### 6.4 注入プロファイル

記録は常に全セクション。注入だけが場面ごとに変わる。

2 つのプロファイルは**そもそも仕組みが違う**。compact 側はフックがファイルを機械的に切り出して
stdout へ出す（ファイル全体は Claude のコンテキストに載らない）。fresh 側はスキルが `Read` する
ため、その時点でファイル全体がコンテキストに載る。したがって fresh 側で一部を「出力しない」と
定めても意味がない。

| | compact プロファイル | fresh プロファイル |
| --- | --- | --- |
| 実行主体 | `session-start.sh`（フック） | `/handoff-load`（スキル） |
| 取得方法 | `grep`/`sed` で抜粋 | `Read` で全文 |
| コンテキストに載る範囲 | 抜粋した分のみ | ファイル全体 |
| 上限 | 1500 文字 | なし |

**compact プロファイル** — 注入するセクション:

| セクション | 扱い |
| --- | --- |
| いま何をしているか | 注入する |
| 未完了・次の一手 | 注入する |
| 試して駄目だったこと | 注入する |
| 背景・目的 | パス案内のみ |
| 完了したこと | パス案内のみ |
| 決定と根拠 | パス案内のみ |
| 恒久知見の候補 | パス案内のみ |
| 注意 | パス案内のみ |
| 自動追記ログ | パス案内のみ |

compact 直後はコンテキストが逼迫している。全文を注入すると圧縮で得た削減を打ち消すため、
上限は stdout 出力全体で 1500 文字（全角・半角を区別せず 1 文字として数える。`wc -m` 基準）。

この文字数計算は実行環境のロケールに依存する。UTF-8 ロケールを前提としており、
`C`/`POSIX` ロケールなど `wc -m` がバイト数を返す環境ではマルチバイト文字がより
多くカウントされ、結果として本来より保守的に（多めに）セクションが省略される。

超過時は**セクション単位で丸ごと落とす**。文字数で末尾を切ると日本語のマルチバイト境界を
割る危険があり、途中で切れた文は読み手にとって有害でもある。落としたセクション名は
`（予算超過のため省略: <見出し>）` として明記し、パス案内から辿れるようにする。

詰め方は貪欲。超過するセクションを飛ばして次を試すため、落ちたセクションより後ろにある
短いセクションは残る。最初の超過で打ち切ると、後続の短く有用なセクションまで失われる。

「背景・目的」を省くのは、compact が生成する要約がその情報を保持しているため。
「試して駄目だったこと」を入れるのは、要約が最も確実に落とす情報であり、かつ同一セッションの
続きなので直後に同じ袋小路へ再突入する危険が高いため。

**パス案内のみ** の意味: 情報を失うのではなく、取得を遅延させる。省いたセクション名と
ファイルパスを明示し、必要と判断すれば Claude が `Read` で取りに行けるようにする。

上表の6セクションは「注入しない候補」であって「常に案内する固定リスト」ではない。
実際に案内するのは、そのうち**引き継ぎファイルに実在するものだけ**（§5.1 の定義順）。
`/handoff` 未実行のまま compact が発火したスタブ（`## いま何をしているか` と
`## 自動追記ログ` しか持たない）のような場合、存在しない5セクションまで
「Read すること」と案内すると、無い内容を Claude に取りに行かせるか、あると誤信させる
ことになる（もっともらしい値で空欄を埋めない、という本プロジェクトの原則に反する）。
案内すべきセクションが1つも実在しない場合は、案内行自体を出さない（空の括弧
`（ は上記ファイルを Read すること）` を出さない）。全文パスの案内はこれと独立に
常に出す。

**fresh プロファイル** — 全文を `Read` する。セクションの取捨選択はしない。
新規セッションはコンテキストが空であり、削る動機がない。
人間への提示は「背景・目的」「いま何をしているか」「未完了・次の一手」を要約して行うが、
これは表示の都合であって、Claude のコンテキストには全セクションが載っている。

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

## 8. skill 仕様

書く `/handoff` と読む `/handoff-load` に分ける。目的が正反対のため、description を 1 つに
まとめると起動判定が濁る。

### 8.1 /handoff — 呼ぶべきタイミング

- 人間が「引き継いで」等と指示したとき
- 大きな作業単位が一区切りしたとき
- 長い調査・試行錯誤の直後（駄目だった選択肢の記録価値が最も高い）

### 8.2 /handoff — 手順

1. `${CLAUDE_PLUGIN_DATA}/<project-slug>/<session_id>.md` を `Read`（存在すれば）
2. 会話全体から**全セクションを**更新する。場面による書き分けはしない（4.3 節）。
   既存記述は消さず、古くなった項目のみ書き換える。
   **`## 自動追記ログ` 以降はフックの領域であり、スキルは一切書き換えない**（読むのは可）。
   `Write` で全文を書き戻す際は、`Read` で得た自動追記ログをそのまま末尾に含める
3. frontmatter の `updated` と `updated_by: handoff-skill` を更新。
   このセッションが `/handoff-load` で始まっていれば `continues_from` を記録する（5.2 節）
4. `Write` で保存し、同じディレクトリの `latest` に session_id を書く。
   `latest` はフックだけでなくこのスキルも更新する。書かないと、`/handoff` 後に
   compact を経ず新規セッションへ移った場合、`latest` が古いセッションを指したまま
   8.6 節の候補一覧の先頭に並び、古い引き継ぎが最新に見える
5. 更新したセクション名と、続け方の 2 択を人間に報告する（8.3 節）

skill は stdin を持たないため、session_id は `CLAUDE_CODE_SESSION_ID`、
`<project-slug>` は `pwd` から得る（11.1 節「skill から見た環境」）。

### 8.3 /handoff — 報告の形

書き終えたら続け方を提示する。使い方 1 と 2 の選択はここで行われる。

```text
引き継ぎを更新しました: 背景・目的 / いま何をしているか / 未完了・次の一手 / 試して駄目だったこと

続け方:
  a) このセッションで続行 — compact が走れば自動で復元されます
  b) 新規セッションで仕切り直し — 新しいセッションで /handoff-load を呼んでください
```

### 8.4 /handoff — 制約

- 5.1 節の見出し文字列を変更しない
- 会話から確認できないことを書かない。不明なものは「不明」と明記する
- 「試して駄目だったこと」を空にしない。該当が無ければ「なし」と書く
- 確証のない事実には「未検証」を付す
- 保存の代行をしない。恒久知見は「恒久知見の候補」に列挙するだけ

### 8.5 /handoff-load — 呼ぶべきタイミング

- 人間が新規セッション（新規起動・`/clear` 後）で明示的に呼んだとき

自発的に呼ばない。新規セッションで何を始めるかは未知であり、無関係な作業に古い引き継ぎを
持ち込むのは害になる。

### 8.6 /handoff-load — 手順

1. `${CLAUDE_PLUGIN_DATA}/<project-slug>/` の `*.md` を列挙する
2. 各ファイルの frontmatter の `updated`・`continues_from` と `## いま何をしているか` の
   先頭 1 行を読み、候補一覧を人間に提示する。`continues_from` で連なるファイル群は、
   **生きているものごとに 1 件へ畳む**（畳んだ件数は併記する）。「生きている」は 2 つ:
   連鎖の**葉**（他のどのファイルからも `continues_from` で参照されていないもの）と、
   **葉より `updated` が新しい非葉**（開いたままのセッションが後継の作成後も
   自分のファイルを更新している状態）。`updated` が最大のものを選ぶのではなく、
   葉を基準にそれより新しい非葉を足す。
   **生きているものが複数あるときは 1 件に畳まない。それぞれを 1 件として出す。**
   同じ引き継ぎを 2 つのセッションが読み込むと連鎖は枝分かれし、どちらも生きている
   作業になる。1 件に畳むと片方が候補一覧から消える。葉より新しい非葉も、
   まだ枝が生えていないだけで位相的にはこれと同じ。session_id 単位でファイルを
   分けているのは（4.4 節）まさにこの並行セッションのためで、
   ここで畳み潰すと分けた意味が消える。
   `latest` に記録された session_id を含む行を先頭に置き、印を付ける。
   `latest` がその行の代表と一致しないときは、印に `latest` の session_id を併記する。
   該当する行が複数あるときは全部に付ける。印だけを貼ると、`latest` が指すものとは
   中身の違う行を「これが latest」と表示することになる
3. ディレクトリが存在しない、または `*.md` が 1 件も無い場合は
   「このプロジェクトの引き継ぎは無い」と報告して終了する。推測で代替物を探さない
4. 候補が 1 件だけでも人間に確認する。並行セッションがあると `latest` が意図と食い違いうる
5. 選ばれたファイルを `Read` する（全文。6.4 節の fresh プロファイル）
6. 人間には「背景・目的」「いま何をしているか」「未完了・次の一手」と、`updated` からの
   経過時間を要約して報告する。古い引き継ぎを最新と誤認させない
7. 読み込んだファイルの session_id を覚えておき、このセッションで最初に `/handoff` を
   呼ぶときに `continues_from` へ記録する（5.2 節）

このスキルはファイルを書き換えない。読み込み後に作業を再開し、節目で `/handoff` を呼ぶと、
**新しい session_id で新しいファイルが作られる**。元のファイルは変更されない。

### 8.7 description の書式

両スキルとも `skill-description-style` の規則に従う。「何を」＋「いつ」の 2 文、100〜250 字、
トリガー語の羅列を避ける。`/handoff`（書く）と `/handoff-load`（読む）が取り違えられないよう、
動詞を対比させる。

ただし**境界を示す文は字数制限に優先する**。`/handoff` の description は上限を超えるが、
超過分は隣接するスキルとの境界を書いた次の 2 文である:

- 「読み込んで再開する側は handoff-load が担当する」
- 「揮発性の作業状況であって、会話を超えて残す恒久知見の記憶ではない」（§9 の
  auto-memory / chiso との境界そのもの）

この 2 文が「前の作業の続きをやりたい」「この知見を覚えておいて」での誤起動を防ぐ、
というのは**設計意図であって、実測ではない**。誤起動テストは実施できていない（§11）。
字数上限は簡潔さのための目安であり、境界の記述より優先しない、という判断だけがここの裁定。

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

- **`SessionStart` の matcher への `fork` / `resume` 追加。** 検討したうえで見送った。
  `--resume` と `--fork-session` はどちらも会話履歴を復元するため、そこへ引き継ぎを注入しても
  大半が重複する。逆に文脈が本当に空になるのは新規起動と `/clear` だが、そこは無関係な作業を
  始める場面と区別できないため自動注入に向かない。仕切り直しは `/handoff-load` の
  明示呼び出しで満たす。追加が必要になった場合は matcher の追記だけで済む
- 引き継ぎファイルの世代管理・削除
- トランスクリプト末尾の生ログ切り出し（`/handoff` から compact までの空白を埋める）
- 手順の再利用（3 節の非対象）。「似た作業を別の対象へ」を扱うなら、状態ではなく手順を運ぶ
  ことになり、「再現手順」「可変部分の明示」というセクションが要る。別機能として設計する

## 11. 未検証事項

実装前に確認を要する。推測のまま実装しない。

- **`PreCompact` の `trigger` が自動 compact のとき何になるか。** 実測できたのは `manual` のみ。
  自動 compact は任意に起こせない。ただし実装はこの値を分岐に使わず stdin の値をそのまま
  ログへ書くだけなので、未実測でも誤りは生じない（§6.2）
- **`command` 文字列に対する Claude Code 側のトークン展開の有無。** 単一引用符で囲んで渡した
  `'${CLAUDE_PLUGIN_ROOT}'` は展開されずリテラルのまま届いた。二重引用符での展開は shell に
  よるものと区別がつかないため、Claude Code が展開しているかは未判定。
  設計は shell 展開のみに依存させるため、この判定は不要（11.1 の運用規則を参照）
- **`/handoff` の description の誤起動判定。** `skill-creator` の `run_eval.py` で 20 件の
  trigger eval を回したが、1 件も起動を検出できなかった。原因は 11.1 に記録したとおり、
  本物の skill が子プロセスから見えていてハーネスの合成スキルと名前が一致しないため。
  **陽性が全滅する一方で陰性は自動的に全部「合格」になる**ので、
  「前の作業の続きをやりたい」「この知見を覚えておいて」を弾けたという観測は存在しない。
  誤起動しない証拠も、誤起動する証拠も無い。§8.7 の裁定はこの未測定を前提としている。
  加えて、eval にかけた文字列と最終的に出荷した description は同一ではない。
  レビュー対応で書き換えたため、出荷版はこの無効な測定にすら通していない
- **`/handoff-load` の description の誤起動判定。** 実装済みだが、`/handoff` と同じ
  ハーネス欠陥で測定できない。「引き継いで」で `/handoff-load` が起動しないこと、
  および `/handoff` との取り違えが起きないことは、いずれも未測定
- **SKILL.md 本文に書いた `${CLAUDE_PLUGIN_DATA}` が、skill 読み込み時に絶対パスへ
  展開されるか。** 当初 §2 に「確認済み」として書いていたが実測していなかった。
  公式プラグイン `project-artifact` の SKILL.md が同じトークンを本文中でパスとして
  使っており、書式としては正統である（弱い傍証であって実測ではない）。
  `/handoff` はこのトークンを本文に書いたうえで、**展開されずリテラルのまま見えた場合は
  停止して報告する**よう指示している。推測でパスを組み立てるとフックが読む場所と
  別の場所に書き込み、引き継ぎが成立しないのに成功したように見えるため

### 11.1 検証済み（2026-08-01）

#### フック入力の実測値

`/compact`（手動）を 2 回起こして採取した実物。以下は 1 回目のもの。

`PreCompact` の stdin JSON:

```json
{
  "session_id": "0322f6d5-5cc1-495b-a0f1-72ba644d9013",
  "transcript_path": "/home/driller/.claude/projects/-home-driller-repo-session-handoff/0322f6d5-....jsonl",
  "cwd": "/home/driller/repo/session-handoff",
  "prompt_id": "1b7b08b2-81c2-47e2-9870-e179517837ac",
  "hook_event_name": "PreCompact",
  "trigger": "manual",
  "custom_instructions": null
}
```

`SessionStart`（`matcher: compact`）の stdin JSON:

```json
{
  "session_id": "0322f6d5-5cc1-495b-a0f1-72ba644d9013",
  "transcript_path": "/home/driller/.claude/projects/-home-driller-repo-session-handoff/0322f6d5-....jsonl",
  "cwd": "/home/driller/repo/session-handoff",
  "prompt_id": "1b7b08b2-81c2-47e2-9870-e179517837ac",
  "hook_event_name": "SessionStart",
  "source": "compact",
  "model": "claude-opus-5"
}
```

読み取れること:

- **`session_id` は compact をまたいで変わらない。** §6.3 が `latest` を経由せず stdin の
  `session_id` で引き当てる設計は、この事実に支えられている。並行セッションがあっても
  他セッションの引き継ぎを掴む余地がない
- `custom_instructions` は `null` になりうる。`jq -r` は文字列 `"null"` を返すので、
  この項目を使うなら `// empty` で潰す。ただし §6.2 は使わない
- `permission_mode` は両イベントとも存在しない。あるものとして書かない
- `PreCompact` に `trigger`／`custom_instructions`、`SessionStart` に `source`／`model` があり、
  共通項目は `session_id`・`transcript_path`・`cwd`・`prompt_id`・`hook_event_name` の 5 つ
- `matcher: "compact"` は意図どおり `SessionStart` を絞り込む
- `prompt_id` は compact ごとに変わる（2 回目は `f54acd95-...`）。同じ compact の
  `PreCompact` と `SessionStart` では一致する。セッションの同一性判定に使ってはならない

#### skill から見た環境

skill は stdin を受け取らないので、フックとは別の経路で session_id とパスを得る必要がある。
Bash ツールの環境変数を実測した結果:

| 変数 | 値 | 帰結 |
| --- | --- | --- |
| `CLAUDE_CODE_SESSION_ID` | `0322f6d5-...`（同時刻のフック stdin の `session_id` と一致） | skill はここから session_id を得る |
| `CLAUDE_PLUGIN_DATA` | **未設定** | シェル経由では解決できない。`lib.sh` の `data_dir` は skill から使えない |
| `CLAUDE_PLUGIN_ROOT` | **未設定** | 同上 |
| `CLAUDE_PROJECT_DIR` | **未設定** | cwd は `pwd` で得る |

`CLAUDE_CODE_CHILD_SESSION=1` も同時に設定されていた。この値が何を意味するかは未判定。
`CLAUDE_CODE_SESSION_ID` の一致は**このセッションのメインループでの観測**であり、
dispatch した subagent 内で同じ値になるかは確認していない。

`<project-slug>` は `pwd | sed 's#[^a-zA-Z0-9_-]#-#g'` で得る。`lib.sh` の `project_slug`
と同一の置換規則で、同じディレクトリを指すために一致させる必要がある。

#### `/handoff` の実動作（2026-08-01・別セッションでの観測）

description の誤起動テストを回した際、ハーネスが起動した `claude -p`（cwd は
`/home/driller`）が `/handoff` を実際に実行し、成果物が残った。ハーネス自身は
「起動しなかった」と記録したが、これは合成した別名スキルとの名前一致しか見ない
判定によるもので、実際には本物の `handoff` が呼ばれていた。

観測できたこと:

- 「引き継いで」で `/handoff` が起動した。空のセッションでも起動する
- 書き込み先は `~/.claude/plugins/data/session-handoff-skills-dir/-home-driller/` で、
  slug 規則もプラグイン id も正しい
- frontmatter（`updated_by: handoff-skill`）と見出し 9 つは §5 のとおり、
  `latest` は §4.4 のとおり生成された。
  ただし `## 注意` と `## 自動追記ログ` の間の `---` 区切りは**欠けていた**。
  当時の SKILL.md がこの区切りを指示していなかったためで、レビュー指摘 I-2 として
  明文化した
- 材料が無い項目に「不明」と明記しており、§8.4 の制約が守られた

これは起動したという観測であって、**起動すべきでない場面で起動しないことの観測ではない**。

`${CLAUDE_PLUGIN_DATA}` が SKILL.md 本文で展開されたことの**実測とは見なさない**。
モデルが `~/.claude/plugins/data/` を自分で列挙して id を見つけた経路を排除できないため。
決着には、展開結果を直接観測できる実行が要る（§11 に残す）。

#### stdout 注入（§6.3 の前提）

2 回目の `/compact` で、`SessionStart` フックが exit 0 で書いた stdout が
compact 直後のコンテキストに現れることを直接観測した。現れた形はこう:

```text
SessionStart:compact hook success: SESSION_HANDOFF_INJECTION_PROBE_7Q2 stdout 注入の計測用。…
```

- **§6.3 の復元経路は成立する。** `PostCompact` が注入できない以上、
  `PreCompact`（書き出し）→ `SessionStart(compact)`（読み込み・注入）が唯一の経路であり、
  その後半がこれで裏付けられた
- 注入本文には `SessionStart:compact hook success: ` という接頭辞が付く。
  したがって注入文は、それ自体が何であるかを名乗る本文にする（§6.3 の見出し行がその役割を負う）
- 同じイベントに登録された他プラグインのフックも各々独立に注入されていた。
  1 フック 1 メッセージであり、他フックの成否に影響されない

フックの子プロセスへ export される値（両イベントで同一）:

```text
CLAUDE_PLUGIN_ROOT=/home/driller/.claude/skills/session-handoff
CLAUDE_PLUGIN_DATA=/home/driller/.claude/plugins/data/session-handoff-skills-dir
CLAUDE_PROJECT_DIR=/home/driller/repo/session-handoff
CLAUDE_CODE_SESSION_ID=0322f6d5-5cc1-495b-a0f1-72ba644d9013
```

- `${CLAUDE_PLUGIN_DATA}` は §4.4 の想定どおり `session-handoff-skills-dir`。
  識別子は `<プラグイン名>-<供給元>` であって、プラグイン名そのものではない
- **このディレクトリは Claude Code が自動生成する。** フック発火時刻に作られていた。
  ただし中身は空なので、`<project-slug>/` は各フックが `mkdir -p` する（§6.2）
- **運用規則: `hooks.json` の `command` 内でこれらを参照するときは二重引用符か無引用符にする。**
  単一引用符では展開されない。展開しているのが shell なのか Claude Code なのかは
  区別できていないが（§11）、二重引用符なら少なくとも shell が展開するので確実に動く
- `PWD` はフック実行時 `cwd` と一致した。ただし依存せず stdin の `cwd` を使う（§6.2）

#### プラグインの読み込み

- **skills-dir 経由のプラグインでも `hooks/hooks.json` は読み込まれる。**
  `/hooks` が `PreCompact (1)` を表示し、`~/.claude/settings.json` に `PreCompact` の登録は無く、
  プラグイン・スキル配下の `hooks.json` 全件で `PreCompact` を持つのは本リポジトリの
  1 ファイルのみだった。§4.2・§6.1 の前提は成立する
- **フック設定はセッション起動時に確定する。** セッション途中で `hooks/hooks.json` を
  新規作成しても、その走行中のセッションには登録されない。`/reload-skills` は
  skill 一覧を再読み込みするだけでフックを再登録しない。反映には `claude --continue` などの
  再起動を要する。開発中はこれを踏むので手順に含める（§6.1）
- **`command` は単一のシェル文字列で書く。** `{"command": "bash", "args": [...]}` の形は
  検証していない。インストール済みの実プラグイン 3 種（superpowers 6.2.0・codex 1.0.2・
  learning-output-style 1.0.0）はいずれも `args` を持たず単一文字列を使う。
  `claude plugin validate` が通ることは `args` 形式が動く証拠にならない

#### 配置・登録（先行検証分）

- **シンボリックリンク越しの skills-dir プラグイン認識は動作する。**
  `~/.claude/skills/session-handoff -> ~/repo/session-handoff` を張った状態で
  `claude plugin list` が `session-handoff@skills-dir / Scope: user / Status: ✔ loaded` を返した。
  §4.2 の配置は確定
- `${CLAUDE_PLUGIN_ROOT}` はシンボリックリンク側のパス（`~/.claude/skills/session-handoff`）
  として表示される。実体パスへの解決は行われない
- `claude plugin validate` は `version` 未指定を警告する。commit SHA による版管理を
  意図するなら無視してよい（公式ドキュメントが内部利用向けに推奨する形）
- `.claude-plugin/plugin.json` だけでコンポーネントが 1 つも無くてもプラグインは
  `✔ loaded` になる。実装前の現在、リポジトリには skill もフックも存在しない
