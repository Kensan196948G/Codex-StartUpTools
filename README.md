# Codex StartUpTools

Ubuntu ネイティブ環境で、夜間に Codex CLI を非対話実行し、翌朝の確認に必要なログ、差分、メタ情報、Markdown レポートを残すための CLI 運用パッケージです。

## 構成

- `bin/nightly_codex.sh`: 夜間ジョブのメイン入口。
- `bin/auto_setup.sh`: 設定生成、検証、スケジュール登録を非対話で行う全自動セットアップ。
- `bin/codex_menu.sh`: Linux 版 Codex 管理メニュー。
- `bin/codex_startup.sh`: プロジェクト選択付き Codex 起動ランチャー。
- `bin/prepare_repo.sh`: 対象 Git リポジトリと nightly ブランチの準備。
- `bin/summarize_result.sh`: 朝確認用 Markdown レポートの生成。
- `bin/cleanup.sh`: lock ディレクトリの解除。
- `config/*.example`: 設定テンプレート。
- `deploy/*.example`: systemd service/timer のテンプレート。
- `tasks/codex_goal_prompt.md`: `/goal` コマンド形式の標準プロンプト。自由に編集して nightly 実行へ反映できます。
- `tasks/default_task.md`: 短い保守用タスク例。
- `tests/run_tests.sh`: Bash ベースの自己完結テスト。
- `Makefile`: 構文チェック、lint、テストの入口。

## セットアップ

CLI 管理メニューを起動する場合:

```bash
./bin/codex_menu.sh
```

非対話で状態だけ確認する場合:

```bash
./bin/codex_menu.sh --once dashboard
```

プロジェクトを指定して Codex 起動計画を確認する場合:

```bash
./bin/codex_startup.sh --project /home/kensan/Projects/your-repo --dry-run
```

実際に Codex を起動する場合:

```bash
./bin/codex_startup.sh --project /home/kensan/Projects/your-repo
```

管理メニューの `7. nightly 今すぐバックグラウンド実行` は、`config/jobs.conf` を使って nightly ジョブを即時にバックグラウンド起動します。PID は `run/nightly-background.pid`、ログは `logs/background/` に保存されます。

全自動でセットアップする場合は、対象 Git リポジトリだけ指定します。設定ファイル生成、検証コマンド推定、`make verify`、`--dry-run`、cron 登録まで実行します。

```bash
./bin/auto_setup.sh --repo /srv/repos/your-repo --force
```

すぐに煙幕確認まで行う場合:

```bash
./bin/auto_setup.sh --repo /srv/repos/your-repo --force --smoke-run
```

cron へ登録せず、設定生成と検証だけ行う場合:

```bash
./bin/auto_setup.sh --repo /srv/repos/your-repo --schedule none --force
```

Codex 本実行まで即時に行う場合:

```bash
./bin/auto_setup.sh --repo /srv/repos/your-repo --force --run-now
```

手動で設定する場合:

```bash
cp config/jobs.conf.example config/jobs.conf
cp config/env.sh.example config/env.sh
chmod +x bin/*.sh tests/run_tests.sh
```

`config/jobs.conf` の `REPO_PATH`、`REPO_NAME`、`BASE_BRANCH`、検証コマンドを対象リポジトリに合わせて編集します。実際の API キーは `config/env.sh` またはジョブ実行ユーザーの環境変数で管理し、コミットしないでください。

標準では `TASK_FILE="${AI_NIGHTLY_ROOT}/tasks/codex_goal_prompt.md"` を使います。`/goal` の指示内容を変えたい場合は、この Markdown ファイルを直接編集してください。

## 完全自律型開発モード

標準タスク `tasks/codex_goal_prompt.md` は、設計確認、実装、検証、自己レビュー、運用報告、PR-ready までを 1 つの長時間 Goal として扱う前提です。`nightly_codex.sh` は Codex の最終応答を `logs/YYYYMMDD/*.final.md` に保存し、翌朝レビュー用に `reports/YYYYMMDD/*-pr.md` の PR ドラフトも生成します。

`config/jobs.conf` では以下を調整できます。

```bash
CODEX_AUTONOMY_LEVEL="pr-ready"
CODEX_MODEL=""
CODEX_PROFILE=""
CODEX_EXEC_ARGS=""
PR_MODE="draft-file"
PR_REMOTE="origin"
```

- `PR_MODE=off`: PR ドラフトを生成しません。
- `PR_MODE=draft-file`: ローカルに PR ドラフト Markdown を生成します。標準設定です。
- `PR_MODE=gh-draft`: `gh` CLI でブランチを push し、GitHub draft PR を作成します。リモート操作を伴うため、明示的に設定した場合だけ使ってください。

完全自律運用でも、秘密情報、本番データ、OS 設定、リモート push は安全境界として扱います。通常は `draft-file` で朝レビューし、人間が内容を確認してから push / PR 作成へ進める運用を推奨します。

## 実行方法

設定確認のみ:

```bash
./bin/nightly_codex.sh --config config/jobs.conf --dry-run
```

Codex を実行せず、ブランチ作成・検証・レポート生成だけ確認:

```bash
./bin/nightly_codex.sh --config config/jobs.conf --skip-codex
```

夜間ジョブ本実行:

```bash
source config/env.sh
./bin/nightly_codex.sh --config config/jobs.conf
```

出力は `logs/YYYYMMDD/` と `reports/YYYYMMDD/` に保存されます。

## cron 例

```cron
0 0 * * * cd /opt/ai-nightly && . config/env.sh && ./bin/nightly_codex.sh --config config/jobs.conf >> logs/cron.log 2>&1
```

## 検証

```bash
make verify
```

個別に実行する場合は `make syntax`、`make lint`、`make test` を使います。

## 運用上の注意

- `main` / `master` へ直接変更しません。`nightly/codex/...` ブランチを作成します。
- 多重起動は `run/lock/` の lock ディレクトリで防止します。
- 本番ログ、秘密情報、ローカル設定はコミット対象外です。
- 自動実行後も、人間または対話型エージェントによる朝レビューを必須としてください。

## 移植元の扱い

`ClaudeCode-StartUpTools-New` と `Codex-StartUpTools-New-BackUp` は参照元です。PowerShell / Windows Terminal / Claude 固有 hook はそのまま移植せず、Linux Bash と Codex CLI に必要な機能だけを置換実装しています。精査メモは `docs/source-review.md` を参照してください。

## systemd timer

`deploy/ai-nightly.service.example` と `deploy/ai-nightly.timer.example` を `/etc/systemd/system/` にコピーし、パスと実行ユーザーを環境に合わせて調整してください。
