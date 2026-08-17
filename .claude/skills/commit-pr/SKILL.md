---
name: commit-pr
description: >
  作業をコミットして PR を作成する（CodeRabbit のレビューは手動起動が必要）。
  「コミットしてPR」「PR作成して」「PR出して」「コードラビットにレビュー」「レビュー依頼」「レビューしてもらう」で発火。/commit-pr でも起動。
  main 直コミットを避け feature ブランチ → コンパイル検証 → push → PR(base main) までを一括で行う。マージはしない（レビュー反映後に別途）。
---

# コミット → PR 作成（CodeRabbit レビュー起動）

本プロジェクトは **CodeRabbit の無料レビュー（PR単位）** を受ける運用。CodeRabbit は PR に対して起動するため、`main` 直コミットではレビューが効かない。このスキルは「feature ブランチで作業 → コンパイル検証 → push → PR 作成」までを安全な順序で実行する。

設計根拠: `.claude/CLAUDE.md`「Git運用ルール」。

**本スキルは mql5-ea-lab ローカル限定**。対象リポジトリは `hiroa0809/mql5-ea-lab`、ローカルパスは `d:/repository/mql5-ea-lab` 固定。他プロジェクトには触れない。

## Step 0: 安全確認（必須）

gh のアクティブアカウントが `hiroa0809`（リポジトリ所有者）であること。`miyatahiroaki0809` になっていると push が 403 になる。

```
rtk gh auth status                                    # Active account が hiroa0809 か
rtk git -C d:/repository/mql5-ea-lab remote -v        # origin が hiroa0809/mql5-ea-lab か
```

違えば `rtk gh auth switch --user hiroa0809` してから続行。remote が想定と違えば**止めてユーザーに確認**。

## Step 1: 変更内容の確認

```
rtk git -C d:/repository/mql5-ea-lab status
rtk git -C d:/repository/mql5-ea-lab diff --stat
```

- `*.ex5`（コンパイル済みバイナリ）は `.gitignore` 済み。混入していないか確認する。
- 一時ファイル・デバッグ出力・ローカル専用ファイルが含まれていないか確認する。

## Step 2: ブランチ作成

現在 `main` なら feature ブランチを切る（main 直コミット禁止）。既に feature ブランチ上ならスキップ。

```
rtk git -C d:/repository/mql5-ea-lab rev-parse --abbrev-ref HEAD   # 現在ブランチ
rtk git -C d:/repository/mql5-ea-lab switch -c feat/<topic>        # 例: feat/cmo-signal
```

ブランチ名は作業内容から簡潔に（`feat/...` / `fix/...` / `docs/...`）。**新しいブランチは現在の HEAD から切る**（`switch -c`）。`main` に切り替えてから切ると、main が最新でない場合に古い土台になる。

## Step 3: コンパイル検証（MQL5・必須）

**コミット前に必ずコンパイルを通す**。手順の詳細は `.claude/CLAUDE.md`「MQL5 ビルド」を参照。

```powershell
$src = "$env:APPDATA\MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\MQL5\Experts\mql5-ea-lab\<対象>.mq5"
$log = "<scratchpad>\build.log"
& "C:\Program Files\XM Trading MT5\MetaEditor64.exe" /compile:"$src" /log:"$log"
Start-Sleep -Milliseconds 800
Get-Content $log -Encoding Unicode | Select-String -Pattern "error|warning|Result"
```

- **終了コードは当てにならない**。判定は必ず `Result: N errors, M warnings` 行を読む。
- ソース変更が無い（ドキュメントのみ等）場合はスキップしてよい。その旨を PR 本文の「検証」に書く。
- **エラーが残る状態でコミット・PR しない**。
- 走らせていないのに「検証済み」と書かない（`.claude/CLAUDE.md`「報告のルール」）。

## Step 4: コミット（明示パス・日本語）

対象ファイルを**明示的に** add する（`git add .` で想定外のファイルを拾わない）。

```
rtk git -C d:/repository/mql5-ea-lab add <path1> <path2> ...
```

コミットメッセージは**日本語**。本文末尾に必ず以下の trailer を付ける（heredoc 推奨。`&&` チェーンは禁止）:

```
rtk git -C d:/repository/mql5-ea-lab commit -m @'
<変更の要約（日本語）>

<必要なら箇条書きで詳細>

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
'@
```

## Step 5: push

```
rtk git -C d:/repository/mql5-ea-lab push -u origin <branch>
```

## Step 6: PR 作成（base: main）

PR タイトル・本文は**日本語**。本文末尾に必ず `🤖 Generated with [Claude Code](https://claude.com/claude-code)` を付ける。

```
rtk gh pr create --repo hiroa0809/mql5-ea-lab --base main --head <branch> --title "<日本語タイトル>" --body @'
## 概要
<このPRで何をしたか>

## 変更点
- <箇条書き>

## 検証
- コンパイル: `Result: 0 errors, 0 warnings`（XM MetaEditor）
- <その他の確認事項。未実施のものは「未実施」と明記する>

🤖 Generated with [Claude Code](https://claude.com/claude-code)
'@
```

「検証」欄には**実際に走らせた結果だけ**を書く。バックテスト未実施なら「未実施」と明記する。

作成後、**PR の URL をユーザーに提示**する。

## Step 7: CodeRabbit レビュー（手動起動が必要・以降は /coderabbit-review へ）

**PR を作っただけではレビューは走らない**（2026-08-16 に判明）。CodeRabbit はスター10個未満のリポジトリで自動レビューを止めるようになり、チェックは `SUCCESS` / `Review skipped: manual review required for this OSS repository` のまま止まる。**状態が `SUCCESS` なので、説明文を読まないと「合格」と誤読する。**

起動はコメント1つ。制限は**1時間あたり1回**。

```
rtk gh pr comment <PR#> --repo hiroa0809/mql5-ea-lab --body "@coderabbitai review"
```

- 本スキルの責務は**ここまで**。起動後の完了判定・取得・トリアージ・反映・返信は `/coderabbit-review` スキルが担当する（起動コマンド自体も同スキルの Step 0.4 にある。続けて実行するなら本スキルでは投稿せず、そのまま `/coderabbit-review` へ渡してよい）。
- そのまま続けてよいかユーザーに確認し、了承があれば `/coderabbit-review` へ進む。
- マージは明示指示があるまで行わない。

## 注意事項

- **本スキルは mql5-ea-lab ローカル限定**。リポジトリは `hiroa0809/mql5-ea-lab`、ローカルパスは `d:/repository/mql5-ea-lab` 固定。
- `&&` でコマンドをチェーンしない（許可ルールのプレフィックスマッチが効かない）。独立コマンドは分ける。
- `cd` ではなく `git -C d:/repository/mql5-ea-lab` を使う。
- マージ・force push はこのスキルの範囲外。やるなら明示指示で。
- 全て日本語で記述する。
