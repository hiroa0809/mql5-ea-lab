---
name: coderabbit-review
description: >
  PR に付いた CodeRabbit のレビューを取得してトリアージ（妥当な指摘 / 意図的な設計 / 誤検知 を実コードと照合して判定）し、修正方針を提示する。
  「レビュー来た」「CodeRabbitレビュー取得」「レビュー確認」「レビュー反映」「コードラビット見て」で発火。/coderabbit-review でも起動。
  修正の実行・同PRへのpush、およびトリアージ結果のPR返信（🟡/❌はインラインスレッド＋要約コメント）まで行う。マージは明示指示がない限り行わない。
---

# CodeRabbit レビュー取得 → トリアージ → 反映

PR に CodeRabbit が自動で付けたレビューを取り込み、機械的に鵜呑みにせず**実コードと照合して判定**し、妥当な指摘だけを直す。

設計根拠: `.claude/CLAUDE.md`「Git運用ルール」。Claude が自作コードを自己レビューする盲点を、別系統の CodeRabbit で補う目的。

**本スキルは mql5-ea-lab ローカル限定**。対象リポジトリは `hiroa0809/mql5-ea-lab` 固定、ローカルパスは `d:/repository/mql5-ea-lab` 固定とし、他プロジェクトには触れない。

> **前提**: gh のアクティブアカウントが `hiroa0809` であること（リポジトリ所有者）。`miyatahiroaki0809` になっていると push/API が 403 になる。`gh auth status` で確認し、違えば `gh auth switch --user hiroa0809`。

## MQL5 プロジェクト特有の注意（重要）

CodeRabbit は MQL5 専用の Lint ルールを持たない（言語横断の汎用レビューになる）。そのためトリアージでは以下を意識する:

- **MQL5 固有仕様を知らないことに起因する誤検知が出やすい**。例: `input` 変数、`#property`、`OnTick`/`OnInit` のライフサイクル、`CopyBuffer` の shift 規約、`PositionGetTicket` 後の暗黙の選択状態、`datetime`/`ulong` 等の型。C++ や C# の常識で指摘してくる場合は ❌誤検知 を疑う。
- **逆に、言語非依存の指摘（ゼロ除算、境界条件、リソース解放漏れ、ロジック矛盾）は妥当なことが多い**。
- 判定に迷う MQL5 仕様は `docs/` の仕様書と実コードで裏を取る。CodeRabbit の要約だけで結論しない。

## 対象PRの特定

引数でPR番号が渡されればそれを使う。無ければ現在ブランチのPRを特定する。

```
rtk gh pr view --json number,title,headRefName   # 現在ブランチのPR
# 出てこなければ: rtk gh pr list --state open
```

## Step 0.5: レビュー完了の確定判定（必須・推測禁止）

「数分待って眺める」をしない。CodeRabbit は PR に **commit status チェック**を出すので、その状態で完了を機械判定する:

```
rtk gh pr checks <PR#> --repo hiroa0809/mql5-ea-lab --json name,state,bucket,description
```

CodeRabbit 行の読み方:

| state / description | 意味 | 行動 |
|---|---|---|
| `PENDING` / "Review in progress" | レビュー中（まだ書いている） | **自動ポーリングで完了を待つ**（下記「PENDING 時の自動待機」）。完了後に Step 1 へ |
| `SUCCESS` / "Review completed" | レビュー**完了** | Step 1 へ進む |
| `FAILURE` / fail 系 | 完了（要対応扱い） | Step 1 へ進む |

**重要**: `SUCCESS`（Review completed）は「**レビューを書き終えた**」の意味であって「指摘ゼロ」ではない。完了後に Step 1 で指摘本体（インライン／レビュー本文）を取得してトリアージする。完了していれば「新規レビューがまだ」と誤認して待つ必要はない（push直後でチェックが消えている/未生成の場合のみ未完了＝待つ）。

### PENDING 時の自動待機

PENDING の間は**手動で何度も確認させない**。代わりに**バックグラウンドのループで数分間隔ポーリング**して完了を待ち、完了したら自動で再開して Step 1 へ進む（この環境では foreground の `sleep` がブロックされるため、必ず `run_in_background: true` で起動する。detached で走り、終了時に再呼び出しされる）:

```bash
# CodeRabbit の state が SUCCESS/FAILURE（=完了）になるまで 150秒間隔でポーリング。
# 必ず run_in_background: true で起動すること（完了通知で再開→Step 1 へ）。
while true; do
  s=$(rtk gh pr checks <PR#> --repo hiroa0809/mql5-ea-lab --json name,state --jq '.[] | select(.name=="CodeRabbit") | .state')
  echo "CodeRabbit: $s"
  case "$s" in SUCCESS|FAILURE) exit 0;; esac
  sleep 150
done
```

- ポーリング間隔は 120〜180 秒（CodeRabbit のレビューは通常数分で終わる）。
- push 直後でチェックがまだ生成されていない（CodeRabbit 行が空）場合も、ループ内で `s` が空のまま回り続けるので、行が現れて SUCCESS/FAILURE になった時点で抜ける。
- 完了通知で再開したら Step 1（指摘取得）へ。`SUCCESS` で新規指摘が無ければ「合格・新規指摘なし」で確定。
- 万一ハングしてもユーザーはいつでも割り込める。

## Step 1: レビュー取得（出力は context-mode で処理）

CodeRabbit はPRに対し ①サマリーコメント ②インライン指摘（行コメント）を付ける。両方取る。**生のコメントは長くなりがちなので、`ctx_execute` で取得→必要部分だけ抽出**しコンテキストを節約する。

```
# 会話コメント（サマリー等）
rtk gh pr view <PR#> --comments

# インライン指摘（ファイル・行付き）— gh api をそのまま読まず ctx で集約する
#   ctx_execute(language="shell", code="gh api repos/hiroa0809/mql5-ea-lab/pulls/<PR#>/comments --paginate") 等
#   ※ 各指摘の .id（コメントID）も必ず控える。Step 4 のインライン返信に使う。
#     例: --jq '.[] | {id, path, line, body}'
```

> 大きな出力は Bash で直に受けず、`mcp__plugin_context-mode_context-mode__ctx_execute` でコマンドを実行し、指摘の「ファイル/行/種別/本文」だけを console.log して取り込む。レビュー本文はサンドボックスに留める。

完了判定は Step 0.5 のチェック状態で行う（コメントの有無で推測しない）。`SUCCESS`=完了なら、指摘本体が無くても「合格・新規指摘なし」と確定してよい。`PENDING`=レビュー中のときだけ待つ。

## Step 2: トリアージ（必須・実コード照合）

CodeRabbit の各指摘を**そのまま信じない**。指摘が指すファイル・行を Read し、以下の3分類で判定して一覧化する:

| 判定 | 意味 | 対応 |
|------|------|------|
| ✅ 妥当 | 実バグ/明確な改善。直すべき | 修正する |
| 🟡 意図的な設計 | 仕様・方針上わざとそうしている | 直さない（理由を明記。Step 4 でスレッド返信） |
| ❌ 誤検知 | 前提誤り/文脈無視で的外れ | 直さない（根拠を明記。Step 4 でスレッド返信） |

判定の根拠は**必ず実コードに当てる**（CodeRabbit の要約だけで判断しない）。nitpick（軽微）と actionable（要対応）を区別し、actionable を優先。

MQL5 では前掲「MQL5 プロジェクト特有の注意」の観点を必ず通す。特に「損切りを入れるべき」等の**仕様に属する指摘**は、`docs/` の仕様書の記述と照らして 🟡意図的 か ✅妥当 かを判断する（仕様が未確定な項目は、その旨を返信に明記する）。

### 出力フォーマット（毎回この形・定番）

トリアージ結果は**必ず次の表**で提示する:

| # | 指摘 | 箇所 | 重要度 | 判定 | 理由 |
|---|------|------|--------|------|------|

- **重要度**は CodeRabbit の表記をそのまま（🟠 Major / 🟡 Minor / 🧹 Nitpick / 💤 Low value 等）。
- **判定**は ✅妥当 / 🟡意図的(見送り) / ❌誤検知 の3分類。
- 表の直後に**「提案」**として「✅で直すもの／見送るもの」を明示し、修正候補を提示してユーザーの承認を取る。

## Step 3: 修正の反映（同PRへ push・マージはしない）

ユーザーが修正対象を承認したら:

1. ✅ 妥当 の指摘をメインセッションで直接 Edit/Write で修正する。
2. **コンパイル検証を通す**（手順は `.claude/CLAUDE.md`「MQL5 ビルド」）。XM の MetaEditor を CLI で呼び、`Result: N errors, M warnings` 行で判定する。エラーが残る状態で push しない。走らせていないのに「検証済み」と書かない。
3. **同じPRブランチに** commit & push（日本語メッセージ＋ `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`）。
   ```
   rtk git -C d:/repository/mql5-ea-lab add <修正ファイル>
   rtk git -C d:/repository/mql5-ea-lab commit -m "..."   # heredoc で trailer 付き
   rtk git -C d:/repository/mql5-ea-lab push              # 既存の upstream へ
   ```
4. push で **CodeRabbit が自動的に再レビュー**する。新たな指摘があれば Step 1 から繰り返す。

## Step 4: トリアージ結果を CodeRabbit に返信（標準・必須）

**タイミング注意**: 返信は「PR作成と同時」にはできない。CodeRabbit はPR作成/更新の**後**にレビューを書くため、返信できるのはレビューが付いた後＝この工程内。

トリアージの結論を**毎回PRに残す**（口頭・チャットだけで終わらせない）。理由は ①🟡/❌ を放置すると再レビューで蒸し返される ②判断の監査証跡が残る ③将来の自分／レビュアーが経緯を追える。

1. **🟡意図的・❌誤検知 は各インラインスレッドに返信**（最も再フラグを防げる。CodeRabbit はスレッド単位で解決を追跡するため）。Step 1 で控えた**コメントID**を使う:
   ```
   rtk gh api repos/hiroa0809/mql5-ea-lab/pulls/<PR#>/comments/<comment_id>/replies -f body="<判定と理由（日本語）。例: 🟡見送り — 損切りを設けないのは docs/entry_signal_spec.md の仕様通りで、RSI 50 回帰のみで手仕舞う設計>"
   ```
2. **✅妥当 で直したものは**、修正コミットのSHAを添えて簡潔に返信（任意だが推奨）。スレッドに `<判定> 対応済み（commit <sha>）` を返す。
3. 最後に**トリアージ表（Step 2 と同じ列）を1つの要約コメント**としてPRに投稿し、全体像を残す:
   ```
   rtk gh pr comment <PR#> --body "$(cat <<'EOF'
   ## CodeRabbit トリアージ結果
   | # | 指摘 | 箇所 | 重要度 | 判定 | 対応 |
   |---|------|------|--------|------|------|
   | 1 | ... | ... | 🟠 | ✅妥当 | commit <sha> で修正 |
   | 2 | ... | ... | 🟠 | 🟡見送り | <理由> |
   EOF
   )"
   ```

返信本文は**日本語**。誤検知・見送りは「なぜそう判断したか」を実コード根拠つきで書く（CodeRabbit の要約の否定だけにしない）。

## マージ（このスキルの範囲外・明示指示でのみ）

全指摘が解消・説明済みになったら、**ユーザーが「マージして」と明示したときだけ** main へマージする:

```
rtk gh pr merge <PR#> --merge --delete-branch
```

明示指示が無ければマージしない。スキルは「トリアージ → 反映（✅push）→ 返信（Step 4）」までで完了とする。

## 注意事項

- **本スキルは mql5-ea-lab ローカル限定**。リポジトリは `hiroa0809/mql5-ea-lab`、ローカルパスは `d:/repository/mql5-ea-lab` 固定。他プロジェクトには触れない。
- `&&` でコマンドをチェーンしない。`cd` ではなく `git -C d:/repository/mql5-ea-lab`。
- レビュー本文など大きな出力は `ctx_execute` 経由でコンテキストを節約する。
- CodeRabbit の指摘でも**誤検知はある**。実コード照合のトリアージを飛ばさない。MQL5 は CodeRabbit に専用ルールが無いため、特に言語仕様由来の誤検知に注意する。
- **コンパイル検証は可能**（XM の MetaEditor CLI・ジャンクション構成）。修正後は必ず通す。ただしバックテスト等の未実施項目を「動作確認した」と偽らない。未検証は未検証と報告する。
