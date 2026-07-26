# mql5-ea-lab プロジェクト指示

## Git運用ルール

- **PR運用**: 変更は原則としてfeatureブランチ→Pull Request経由でmainへ統合する。mainへの直接pushは避ける。
- **CodeRabbitレビュー**: PR作成時にCodeRabbitの無料レビューを利用する（MQL5への対応状況は検証中）。
- 上記により `fin` スキルのステップ3.5（trunk自動追従）はスキップ対象。mainの更新はPRマージ経由で行う。

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
