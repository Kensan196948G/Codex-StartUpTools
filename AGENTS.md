# リポジトリガイドライン

## プロジェクト構成とモジュール配置

このリポジトリは、Ubuntu ネイティブ環境で夜間 Codex CLI ジョブを実行し、翌朝レビュー用の成果物を残す CLI 運用パッケージです。

- `Ubuntuネイティブ版CLIベース AI支援開発システム 要件定義・詳細設計仕様書.md`: Ubuntu ネイティブ環境で CLI ベースの AI 支援開発を運用するための要件定義・詳細設計。
- `bin/`: `nightly_codex.sh`、`prepare_repo.sh`、`summarize_result.sh`、`cleanup.sh` などの実行スクリプト。
- `bin/auto_setup.sh`: 非対話の全自動セットアップ入口。
- `bin/codex_menu.sh`: Linux 版 Codex 管理メニュー。
- `bin/codex_startup.sh`: Codex 起動ランチャー。
- `lib/`: 共通 Bash 関数。
- `config/`: `jobs.conf.example`、`env.sh.example` などの設定テンプレート。
- `docs/source-review.md`: 参照元サブフォルダの精査結果と移植判断。
- `deploy/`: systemd service/timer のテンプレート。
- `tasks/`: Codex に渡す Markdown タスク雛形。標準は `codex_goal_prompt.md`。
- `tests/`: Bash ベースの自己完結テスト。
- `logs/`、`reports/`: 日付単位で出力される実行ログと Markdown レポート。
- `run/lock/`: 多重起動を防ぐためのロックファイル。

生成ログ、レポート、ローカル環境設定は、サンプルとして明示的に追加する場合を除きコミットしないでください。

## ビルド・テスト・開発コマンド

標準確認手順は `Makefile` に集約しています。

- `make syntax`: Bash 構文を確認します。
- `make lint`: `shellcheck` で lint します。
- `make test`: 一時 Git リポジトリを使った自己完結テストを実行します。
- `make verify`: 上記すべてを実行します。
- `./bin/auto_setup.sh --repo /path/to/repo --force`: 設定生成、検証、cron 登録を全自動で行います。
- `./bin/codex_menu.sh`: 管理メニューを起動します。
- `./bin/codex_startup.sh --project /path/to/repo --dry-run`: Codex 起動計画を確認します。
- `./bin/nightly_codex.sh --config config/jobs.conf --dry-run`: 対象設定を安全に検証します。

## コーディングスタイルと命名規則

Markdown は見出し階層を保ち、要件文は短く具体的に書いてください。シェルスクリプトは Bash 前提とし、インデントは 2 スペース、`set -euo pipefail`、変数のクォートを基本とします。

環境変数と設定キーは `REPO_PATH`、`MAX_RUNTIME`、`REPORT_DIR` のように大文字スネークケースを使います。スクリプト名は `summarize_result.sh` のように「動作 + 対象」が分かる名前にしてください。

## テスト方針

ドキュメント変更では Markdown のレンダリング確認を行います。シェルコードでは `make verify` を通してください。テストは一時ディレクトリとテスト用 Git リポジトリを使い、実リポジトリや本番設定に依存させません。

自動テストで Codex の本実行や実リポジトリの変更を行ってはいけません。fixture と一時ディレクトリを使って再現可能なテストにします。

## コミットとプルリクエスト

このディレクトリは現在 Git リポジトリとして初期化されていないため、既存のコミット規約は確認できません。コミットメッセージは `Add nightly job design guide`、`Implement lock handling` のように短い命令形を推奨します。

プルリクエストには、変更概要、影響ファイル、実行した確認コマンド、運用上の注意点を記載してください。ワークフローやレポート出力を変更する場合は、必要に応じて出力例も添えてください。

## セキュリティと設定

API キー、`.env`、個人環境の絶対パス、本番ログはコミットしないでください。認証情報は環境変数または権限を制限したローカル設定ファイルで管理します。スケジュールジョブは限定権限ユーザーで実行し、設定された対象リポジトリ、ログ、レポート、ロック領域の外へ書き込まない設計にしてください。
