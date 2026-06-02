# Ubuntuネイティブ版CLIベース AI支援開発システム 要件定義・詳細設計仕様書

## 1. 文書概要

本書は、Linux（Ubuntu）ネイティブ環境上で、夜間に OpenAI Codex をCLIベースで自律実行し、翌営業時間帯に Claude Code をローカル環境で用いて確認・修正・追加開発を行う運用システムの要件定義および詳細設計仕様を定義するものである。[1][2][3]

対象システムは WebUI を前提とせず、Ubuntu 上の CLI、cron または systemd timer、git、シェルスクリプト、ログ管理、およびローカル実行可能な AI コーディングツール群によって構成される。[4][5][6]

本システムの主目的は、夜間の無人時間帯に特定レポジトリに対する限定的な自律実装・修正・テスト実行を Codex に担当させ、日中は Claude Code を用いて差分レビュー、設計妥当性確認、追加実装、最終品質確認を実施することで、開発生産性と安全性を両立することである。[1][3][7]

## 2. 背景と目的

Codex は長時間タスク向けに、計画、コード編集、テストやビルドの実行、失敗時の修復、進捗更新を繰り返す長期実行ワークフローが案内されており、Goal モード等を通じて数時間単位の継続作業に適している。[1][8]

一方で、長時間の自律実行ではループや判断迷いが生じる可能性があり、また CLI ベースの非対話実行では確認待ちプロンプトが停止要因となるため、対象範囲の明確化、非対話設定、ログ保全、作業ブランチ隔離などの設計が重要となる。[9][10][11]

Claude Code は日中の対話的レビューやローカルなコード確認に適したワークフローが有効であり、夜間 Codex と日中 Claude Code の役割分担は、AI の強みを分離しつつ品質担保を行う運用として合理的である。[3][7][12]

## 3. システム化対象

対象は、Ubuntu ネイティブ版 Linux 上で稼働する CLI ベースの AI 支援開発システムであり、以下の運用を実現する。

- 毎日 0:00 に cron または systemd timer により夜間ジョブを起動する。[4][5]
- 指定された単一レポジトリに対して、Codex CLI を非対話モードで起動する。[2][6]
- Codex は最大 5 時間、実装、修正、テスト、Lint、成果物記録を行う。[1][8]
- 実行結果を git 差分、ログ、Markdown レポートとして保存する。[1][2]
- 翌朝、開発者が Claude Code をローカル環境で起動し、変更内容を確認、修正、補完する。[3][13]

## 4. システム構成

システム構成要素は以下のとおりである。[2][4][6]

| 構成要素 | 役割 | 備考 |
|---|---|---|
| Ubuntu ホスト | 実行基盤 | Linux ネイティブ環境[4] |
| git 管理レポジトリ | 対象ソース管理 | nightly 専用ブランチ運用推奨[2] |
| Codex CLI | 夜間自律実装エージェント | 長時間タスク実行[1][6] |
| Claude Code | 朝以降の確認・修正 | ローカル対話作業[3] |
| cron / systemd timer | 定期起動 | 0:00 起動制御[4][5] |
| bash ラッパースクリプト | 実行制御 | cd、ログ、timeout、終了処理を集約[11][6] |
| ログ保存領域 | 監査・障害解析 | stdout/stderr、テスト結果、差分保存[11] |

## 5. 業務要件

### 5.1 基本業務要件

- 指定時刻に自動でジョブが起動すること。[4][5]
- 指定レポジトリ名またはレポジトリパスをもとに対象レポジトリを一意に選択できること。
- Codex が対象レポジトリ上で自律的に作業できること。[1][2]
- 5時間以内でジョブを自動終了できること。[1][10]
- 実行内容と結果をログとして保存できること。[11][6]
- 作業後に Claude Code で確認可能な状態で成果物が残ること。[3][13]

### 5.2 運用要件

- main/master ブランチへ直接変更を加えないこと。[2]
- nightly 実行用の作業ブランチを自動生成または再利用すること。
- 実行時刻、対象ブランチ、ジョブID、対象Issueやタスク内容をログに残すこと。
- 失敗時には原因調査に必要な標準出力・標準エラー・終了コードを保全すること。[11]
- 朝の確認作業を短縮するため、差分概要と未解決事項を Markdown で残すこと。[1][3]

## 6. 機能要件

### 6.1 スケジュール起動機能

cron または systemd timer により、毎日 0:00 にジョブを自動起動できること。[4][5]

### 6.2 レポジトリ選択機能

実行対象レポジトリは、設定ファイルまたは起動スクリプト引数により、レポジトリ名・絶対パス・タスクID等から指定できること。

### 6.3 夜間 Codex 実行機能

Codex CLI は非対話モードで起動され、対象レポジトリに対して計画、コード編集、テスト実行、Lint 実行、必要な修復、成果記録を行えること。[1][8][6]

### 6.4 実行時間制御機能

ジョブは 5 時間を超えて継続しないこと。実装方法は、Codex 側の最大実行時間指定、あるいは Linux の `timeout` コマンド等による外側制御を許容する。[1][10]

### 6.5 ログ出力機能

以下をファイル出力できること。

- 実行開始時刻
- 実行終了時刻
- ホスト名
- 対象レポジトリ
- 対象ブランチ
- タスク入力内容
- Codex 標準出力
- Codex 標準エラー
- テスト実行結果
- git diff 結果概要
- 終了コード
- 未解決事項一覧

### 6.6 成果サマリ生成機能

朝の確認用に、Codex 実行結果を Markdown ファイルとして出力すること。内容には、実施内容、変更ファイル一覧、テスト結果、失敗箇所、推奨次アクションを含めること。[1][3]

### 6.7 朝間確認支援機能

Claude Code ローカル実行時に、Codex の成果物、差分、ログ、未解決事項を読み取りやすい形で残すこと。[3][13]

## 7. 非機能要件

### 7.1 可用性

毎日1回の定時実行に耐えうること。ジョブ失敗時も翌日の手動確認が可能なようにログと作業ブランチが保持されること。[11][4]

### 7.2 性能

夜間ジョブは開始後 5 時間以内に終了すること。[1][10]

### 7.3 保守性

設定値はスクリプト内ハードコードを最小化し、設定ファイルで変更可能とすること。

### 7.4 拡張性

将来的に複数レポジトリ、複数時間帯、複数ジョブ種別へ拡張可能な構成とすること。

### 7.5 監査性

ジョブごとの実行証跡、差分、標準出力、エラー、終了コードを保存すること。[11]

### 7.6 セキュリティ

- 実行ユーザは専用ユーザまたは限定権限ユーザとすること。
- API キー等の秘密情報は環境変数または `.env` 等の限定アクセス設定ファイルで管理すること。
- Codex の変更対象ディレクトリは対象レポジトリ配下に限定すること。
- 破壊的コマンドやシステム領域変更を禁止する運用ポリシーを明示すること。[11][6]

## 8. 前提条件・制約条件

- 利用プラットフォームは Ubuntu ネイティブ環境とする。
- UI は CLI ベースとし、WebUI は対象外とする。
- 実行対象は原則として単一レポジトリとする。
- Codex 実行は非対話前提とし、実行中の確認待ちを発生させない設定であることが望ましい。[11][6]
- Claude Code は朝以降にローカル端末から手動起動する。
- main/master への直接 push は行わない。[2]

## 9. ユースケース

### 9.1 ユースケースUC-01 夜間自動実装

1. スケジューラが 0:00 にジョブを起動する。[4][5]
2. ラッパースクリプトが対象レポジトリへ移動する。
3. nightly ブランチを作成またはチェックアウトする。
4. Codex CLI を指定タスクとともに起動する。[2][6]
5. Codex が実装、修正、テスト、Lint、再修復を行う。[1][8]
6. 5時間経過または処理完了でジョブを終了する。[1][10]
7. ログ、差分、Markdown サマリを保存する。

### 9.2 ユースケースUC-02 朝間レビュー

1. 開発者がローカル環境でレポジトリを開く。
2. Codex 出力済みのサマリ、ログ、差分を確認する。
3. Claude Code を用いて変更妥当性を確認する。[3][13]
4. 必要に応じて追加修正、再テスト、コミット整理を行う。

## 10. 詳細設計

### 10.1 ディレクトリ構成

```text
/opt/ai-nightly/
├── bin/
│   ├── auto_setup.sh
│   ├── codex_menu.sh
│   ├── codex_startup.sh
│   ├── nightly_codex.sh
│   ├── prepare_repo.sh
│   ├── summarize_result.sh
│   └── cleanup.sh
├── lib/
│   ├── common.sh
│   └── startup.sh
├── config/
│   ├── jobs.conf.example
│   ├── env.sh.example
│   └── startup.conf.example
├── deploy/
│   ├── ai-nightly.service.example
│   └── ai-nightly.timer.example
├── tasks/
│   ├── codex_goal_prompt.md
│   └── default_task.md
├── tests/
│   └── run_tests.sh
├── logs/
│   └── YYYYMMDD/
├── reports/
│   └── YYYYMMDD/
├── run/
│   └── lock/
├── Makefile
├── README.md
└── AGENTS.md
```

対象レポジトリは `/srv/repos/<repo_name>` 等に配置することを想定する。実運用時は `config/jobs.conf.example` を `config/jobs.conf` に、`config/env.sh.example` を `config/env.sh` にコピーして環境ごとの値を設定する。

### 10.2 設定ファイル設計

#### jobs.conf

| 項目名 | 内容 |
|---|---|
| REPO_NAME | 対象レポジトリ名 |
| REPO_PATH | 対象レポジトリ絶対パス |
| BASE_BRANCH | 基準ブランチ名 |
| NIGHTLY_BRANCH_PREFIX | nightly ブランチ接頭辞 |
| TASK_FILE | Codex へ与える指示ファイル。標準は `/goal` 形式の `tasks/codex_goal_prompt.md` |
| MAX_RUNTIME | 最大実行時間 |
| TEST_COMMAND | テストコマンド |
| LINT_COMMAND | Lint コマンド |
| BUILD_COMMAND | ビルドコマンド |
| REPORT_DIR | レポート出力先 |
| LOG_DIR | ログ出力先 |
| LOCK_DIR | lock ファイル出力先 |
| CODEX_BIN | Codex CLI コマンド名 |
| CODEX_SANDBOX | Codex 実行時の sandbox モード |
| CODEX_APPROVAL_POLICY | 非対話実行時の承認ポリシー |

#### env.sh

| 項目名 | 内容 |
|---|---|
| OPENAI_API_KEY 等 | Codex 実行に必要な認証情報 |
| PATH | codex コマンドパスを含む実行パス |
| LANG | ロケール設定 |
| TZ | タイムゾーン |

### 10.3 バッチ処理設計

#### codex_menu.sh 処理フロー

1. `config/startup.conf` を読み込み
2. ダッシュボード、プロジェクト一覧、最近の起動履歴、cron 管理項目を表示
3. 選択に応じて `codex_startup.sh`、`auto_setup.sh`、`nightly_codex.sh`、`make verify` を実行
4. `--once` 指定時は非対話で単一アクションを実行

#### codex_startup.sh 処理フロー

1. 対象プロジェクトを絶対パス、名前、または対話選択で決定
2. Codex CLI の存在を確認
3. 起動計画を表示
4. `--dry-run` であれば実行せず履歴へ記録
5. 実行時は対象ディレクトリで Codex を起動し、ログと recent history を保存

#### nightly_codex.sh 処理フロー

1. 設定ファイル読み込み
2. lock ファイル確認
3. 開始ログ出力
4. 対象レポジトリ存在確認
5. `git fetch` 実行
6. 基準ブランチ checkout
7. nightly ブランチ生成
8. タスクファイル読込
9. `timeout 5h codex ...` 実行
10. テスト/ビルド/Lint 再実行結果収集
11. `git status` / `git diff --stat` / `git diff` 保存
12. Markdown サマリ作成
13. 終了コード保存
14. lock 解放
15. 終了ログ出力

#### auto_setup.sh 処理フロー

1. 対象 Git リポジトリを `--repo`、環境変数、または現在の Git リポジトリから決定
2. 基準ブランチ、リポジトリ名、検証コマンドを自動推定
3. `config/jobs.conf` と `config/env.sh` を生成
4. `make verify` を実行
5. `nightly_codex.sh --dry-run` で設定を検証
6. 指定に応じて cron または systemd user timer を登録
7. `--smoke-run` または `--run-now` 指定時は即時実行

### 10.4 cron 設計

cron 登録例は以下とする。[4][5]

```cron
0 0 * * * cd /opt/ai-nightly && . config/env.sh && ./bin/nightly_codex.sh --config config/jobs.conf >> logs/cron.log 2>&1
```

### 10.5 systemd timer 設計

本番運用では cron に加え、再起動制御や監視性の面から systemd timer の採用も許容する。[4]

- `ai-nightly.service` : 実ジョブ起動
- `ai-nightly.timer` : 毎日 0:00 起動

テンプレートは `deploy/ai-nightly.service.example` および `deploy/ai-nightly.timer.example` として管理する。

### 10.6 ログ設計

#### 実行ログファイル

`/opt/ai-nightly/logs/YYYYMMDD/<job_id>.log`

#### 差分ログファイル

`/opt/ai-nightly/logs/YYYYMMDD/<job_id>.diff`

#### ステータスファイル

`/opt/ai-nightly/logs/YYYYMMDD/<job_id>.status`

#### 実行メタ情報

`/opt/ai-nightly/logs/YYYYMMDD/<job_id>.meta`

メタ情報には以下を記録する。

| 項目 | 内容 |
|---|---|
| job_id | ジョブ識別子 |
| started_at | 開始日時 |
| ended_at | 終了日時 |
| hostname | 実行ホスト |
| repo_name | 対象レポジトリ |
| branch_name | nightly ブランチ名 |
| exit_code | 終了コード |
| duration_sec | 実行秒数 |
| log_file | 実行ログファイルパス |
| diff_file | diff ファイルパス |
| diff_stat_file | diff stat ファイルパス |
| status_file | git status ファイルパス |
| report_file | Markdown レポートファイルパス |

### 10.7 レポート設計

Markdown レポートファイルを `/opt/ai-nightly/reports/YYYYMMDD/` 配下へ出力する。

レポート項目は以下とする。

- タスク名
- 実行日時
- 対象レポジトリ
- 対象ブランチ
- 実施概要
- 変更ファイル一覧
- テスト結果
- ビルド結果
- Lint 結果
- 未解決事項
- 朝の Claude Code 確認ポイント

### 10.8 エラー処理設計

| エラー種別 | 検知方法 | 対応 |
|---|---|---|
| レポジトリ未存在 | パス確認 | 異常終了、ログ出力 |
| lock 残存 | lock ファイル確認 | 二重起動防止、異常終了 |
| Codex 実行失敗 | 終了コード非0 | ログ保存、サマリに失敗理由記載 |
| timeout 到達 | timeout 終了コード | 強制終了、途中成果物保全 |
| テスト失敗 | テスト終了コード | サマリ記録、朝確認対象化 |
| git 競合 | checkout/merge 失敗 | 異常終了、手動対応指示 |

## 11. インターフェース仕様

### 11.1 コマンドインターフェース

想定される起動形式の例を以下に示す。

```bash
/opt/ai-nightly/bin/nightly_codex.sh --repo repoA --task /opt/ai-nightly/tasks/repoA.md
```

全自動セットアップの例を以下に示す。

```bash
/opt/ai-nightly/bin/auto_setup.sh --repo /srv/repos/repoA --force
```

CLI 管理メニューの例を以下に示す。

```bash
/opt/ai-nightly/bin/codex_menu.sh
```

### 11.2 入力仕様

- コマンド引数
- 設定ファイル
- タスク Markdown ファイル
- 環境変数

### 11.3 出力仕様

- 標準出力ログ
- 標準エラーログ
- Markdown サマリ
- diff ファイル
- diff stat ファイル
- git status ファイル
- メタ情報ファイル

## 12. 運用設計

### 12.1 日次運用

- 0:00 に夜間ジョブ起動。[4][5]
- 5:00 までにジョブ終了。[1][10]
- 朝に開発者がサマリ確認。
- Claude Code でレビュー・修正。[3][13]
- 必要に応じてテスト再実行・コミット整備。

### 12.2 障害運用

- 異常終了時はログ、diff、meta を確認する。
- lock 残存時は手動解除前に前回ジョブ状態を確認する。
- 3日以上連続失敗時はタスク粒度、Codex 指示文、権限制約を見直す。[9][10]

### 12.3 品質運用

- Codex には小〜中粒度の明確な目標のみを与えることが望ましい。[1][9]
- 朝の Claude Code 確認で設計妥当性と副作用確認を必須とする。[3][7]
- テスト、Lint、ビルドを通過しても、人間レビューを省略しないこと。[3][13]

## 13. セキュリティ設計

- 実行ユーザを限定し、sudo 権限を不要とする。
- 対象レポジトリ以外への書込み権限を持たせない。
- API キーを平文で cron に直接書かない。
- ログへ秘密情報を出力しないフィルタを設ける。
- 削除系コマンドや OS 設定変更系コマンドを禁止対象とする。[11][6]
- `config/env.sh`、`.env`、実ログ、実レポートは Git 管理対象外とする。

## 14. テスト要件

### 14.1 単体テスト

- 設定読込処理
- lock 制御処理
- ログ出力処理
- timeout 制御処理
- レポート生成処理
- レポジトリ名正規化処理

### 14.2 結合テスト

- cron からジョブが起動されること。[4][5]
- 対象レポジトリで nightly ブランチが生成されること。
- Codex 実行後に diff が保存されること。
- テスト失敗時に異常系レポートが生成されること。
- `--dry-run` で対象リポジトリを変更しないこと。
- `--skip-codex` で Codex 実行なしにレポート生成を検証できること。

### 14.3 運用テスト

- 5時間制御が有効であること。[1][10]
- ネットワーク断・API エラー時にログが保全されること。[11]
- 翌朝 Claude Code による確認に必要な情報が不足なく出力されること。[3]

### 14.4 開発時検証コマンド

実装変更時は以下を標準検証とする。

```bash
make verify
```

`make verify` は Bash 構文チェック、`shellcheck`、`tests/run_tests.sh` を順に実行する。

## 15. 今後の拡張案

- レポジトリごとのジョブ並列化
- issue tracker 連携
- Slack やメールへの結果通知
- 失敗時自動再試行
- systemd timer への全面移行
- Claude Code 側確認チェックリストの自動生成

## 16. 実装状況

本リポジトリでは、夜間ジョブの MVP 実装として以下を提供済みである。

- `nightly_codex.sh` による設定読込、lock 制御、timeout 付き Codex 実行、検証コマンド実行、ログ・diff・status・meta・report 出力
- `auto_setup.sh` による非対話の設定生成、検証コマンド推定、dry-run、cron/systemd user timer 登録
- `codex_menu.sh` による CLI 管理メニュー
- `codex_startup.sh` による Linux ローカル Codex 起動と recent history 記録
- `prepare_repo.sh` による Git リポジトリ確認、fetch、基準ブランチ checkout、nightly ブランチ生成
- `summarize_result.sh` による朝確認用 Markdown レポート生成
- `config/`、`tasks/`、`deploy/` の運用テンプレート
- `Makefile` と `tests/run_tests.sh` による開発時検証

現時点の標準検証は `make verify` で通過している。実 Codex 本実行は対象リポジトリと認証情報を設定した環境で実施する。

## 17. 採用方針

本システムでは、夜間無人時間帯の長時間自律実行には Codex CLI を用い、日中の確認・修正・対話的品質担保には Claude Code を用いる二段階運用を採用する。[1][3][7]

これは、Codex の長時間タスク適性と、Claude Code のローカル確認・レビュー適性を分離活用する方針であり、CLI ベースの Ubuntu ネイティブ環境でも十分に成立する。[1][2][3]
