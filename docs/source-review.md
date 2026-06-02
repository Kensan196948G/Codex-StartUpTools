# 移植元精査メモ

## 対象

- `ClaudeCode-StartUpTools-New`
- `Codex-StartUpTools-New-BackUp`

## 採用した設計要素

- メニューを単一入口に集約する構成
- プロジェクト一覧、最近使ったプロジェクト、起動履歴の考え方
- preflight / dashboard / cron 管理を管理メニューから呼び出す運用
- Codex バックアップ側の「Codex ネイティブを優先し、Claude 固有依存を移植しない」方針

## Linux 版で置換した要素

- PowerShell モジュール群は Bash 実装へ置換
- Windows Terminal / SSH 起動分岐は Linux ローカル Codex 起動へ集約
- Pester テストは Bash 自己完結テストへ置換
- JSON 状態管理は、最小実装として TSV の recent history と既存 nightly meta/report に分離

## 実装先

- `bin/codex_menu.sh`: CLI 管理メニュー
- `bin/codex_startup.sh`: Codex 起動ランチャー
- `bin/auto_setup.sh`: 全自動セットアップと cron 登録
- `lib/startup.sh`: プロジェクト一覧、履歴、dashboard、cron 補助

## 非移植

- Claude 専用 hook / Agent View / ClaudeOS plugin
- Windows PowerShell UI
- WebUI Mission Control
- ベンダー固有 command 体系の完全互換
