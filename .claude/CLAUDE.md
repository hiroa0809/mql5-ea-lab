# mql5-ea-lab プロジェクト指示

## Git運用ルール

- **`.mq5` / `.mqh` を含む変更**: featureブランチ → PR → CodeRabbitレビュー → マージ。main への直接 push はしない。
- **それ以外（`docs/` `tasks/` `.claude/` `.gitignore` 等）**: main で直接作業してよい（PR不要）。コミット前に `git status` で `.mq5`/`.mqh` の混入がないか確認する。混入していたらブランチへ退避（`git switch -c` は未コミット変更を持ち越す）。
- 手順の詳細は `/commit-pr`（PR作成）、`/fin`（セッションクローズ・ブランチ統合）が持つ。

### CodeRabbit の MQL5 対応（2026-07-26 PR #1 で検証済み）

**MQL5 に対応している。** 汎用レビューにとどまらず、MQL5 固有の仕様に踏み込んだ指摘ができる。

- PR #1 での実績: 4件の指摘のうち Major 2件が**実バグ**（`PositionClose(_Symbol)` のヘッジ口座での誤決済、取引要求の結果コード未確認）。いずれも `CTrade` / `SeriesInfoInteger` の公式ドキュメントを参照した上での指摘だった。
- 指摘・要約とも日本語で返る。
- 誤検知も出る（PR #1 では1件）。ただし MQL5 仕様の誤解ではなく、変数の初期値を見落とした状態追跡ミスだった。**実コード照合のトリアージは必須**。

### レビュー回数の制限（無料プラン）

無料プランには一定時間あたりのレビュー回数上限がある。上限に達すると `Review limit reached` が返り、次のレビューまで待たされる（PR #1 では約25分待ちが発生）。

- **短時間に何度も push して再レビューを走らせない**。複数の指摘は**まとめて1回の push** で対応する。
- 制限中に再レビューしたい場合は、時間を置いてから PR に `@coderabbitai review` とコメントする（新規 push でも起動する）。
- 従量課金（$0.25/ファイル）を有効にすれば即時レビューできるが、通常は待てばよい。

## MQL5 ビルド（コンパイル検証）

MT5 同梱の MetaEditor を CLI で呼ぶ。VSCode 拡張は不要。**使用ブローカーは XM** なので XM の MetaEditor を使う。

```powershell
& "C:\Program Files\XM Trading MT5\MetaEditor64.exe" /compile:"<.mq5 または .mqh のパス>" /log:"<ログ出力パス>"
```

- **終了コードは当てにならない**（成功／失敗どちらでも同じ）。判定は必ずログ末尾の `Result: N errors, M warnings` 行を読む。
- ログは **UTF-16LE** で出力される。読む際は `Get-Content <log> -Encoding Unicode`。
- コンパイラは非同期で走るため、ログ読み取り前に `Start-Sleep -Milliseconds 800` 程度を挟む。

### インクルード解決（ジャンクション構成）

`#include <Signals\...>` は MT5 データフォルダ配下の `MQL5/Include/` から解決される。本リポジトリは MT5 データフォルダ外にあるため、**ジャンクションで繋いでいる**（ファイル実体はリポジトリ側に残り、Git 管理下のまま）。

```
%APPDATA%\MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\MQL5\   ← XM のデータフォルダ
  Include\Signals      → d:\repository\mql5-ea-lab\Include\Signals
  Experts\mql5-ea-lab  → d:\repository\mql5-ea-lab\Experts
```

- コンパイルは**ジャンクション側のパス**を指定する（リポジトリの生パスを直接指定すると標準ライブラリか自作ライブラリのどちらかが解決できない）。
- `/inc:` オプションは標準 Include パスを**置き換えてしまう**ため使わない（`Trade.mqh` 等が見つからなくなる）。
- ジャンクションが失われた場合は再作成する:
  ```powershell
  $mq = "$env:APPDATA\MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\MQL5"
  New-Item -ItemType Junction -Path "$mq\Include\Signals" -Target "d:\repository\mql5-ea-lab\Include\Signals"
  New-Item -ItemType Junction -Path "$mq\Experts\mql5-ea-lab" -Target "d:\repository\mql5-ea-lab\Experts"
  ```

### 他ブローカーの MetaEditor（参考）

同じ手順で使えるが、本プロジェクトでは XM を使う。

| ブローカー | データフォルダ ID |
|---|---|
| XM Trading MT5 | `C4171FD2B38378D6406D5C84412B5F20` |
| FXGT MT5 Terminal | `EB299DF3DF8E2F9A1C0723943438596E` |
| OANDA MetaTrader 5 | `EE0304F13905552AE0B5EAEFB04866EB` |

### 報告のルール

コンパイルを**実際に走らせていない**のに「検証済み」と書かない。走らせた場合は `Result:` 行の実数値（例: `0 errors, 0 warnings`）を報告に含める。
