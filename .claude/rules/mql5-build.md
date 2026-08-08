---
paths:
  - "**/*.mq5"
  - "**/*.mqh"
---

# MQL5 ビルド（コンパイル検証）

> `.claude/CLAUDE.md` から 2026-08-08 に移動。MQL5 のファイルを扱うときだけ読み込まれるようにするため（公式の path-scoped rules）。

MT5 同梱の MetaEditor を CLI で呼ぶ。VSCode 拡張は不要。**使用ブローカーは XM** なので XM の MetaEditor を使う。

```powershell
& "C:\Program Files\XM Trading MT5\MetaEditor64.exe" /compile:"<.mq5 または .mqh のパス>" /log:"<ログ出力パス>"
```

- **終了コードは当てにならない**（成功／失敗どちらでも同じ）。判定は必ずログ末尾の `Result: N errors, M warnings` 行を読む。
- ログは **UTF-16LE** で出力される。読む際は `Get-Content <log> -Encoding Unicode`。
- コンパイラは非同期で走るため、ログ読み取り前に `Start-Sleep -Milliseconds 800` 程度を挟む。

## インクルード解決（ジャンクション構成）

`#include <Signals\...>` は MT5 データフォルダ配下の `MQL5/Include/` から解決される。本リポジトリは MT5 データフォルダ外にあるため、**ジャンクションで繋いでいる**（ファイル実体はリポジトリ側に残り、Git 管理下のまま）。

```text
%APPDATA%\MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\MQL5\   ← XM のデータフォルダ
  Include\Signals         → d:\repository\mql5-ea-lab\Include\Signals
  Experts\mql5-ea-lab     → d:\repository\mql5-ea-lab\Experts
  Indicators\mql5-ea-lab  → d:\repository\mql5-ea-lab\Indicators
```

- コンパイルは**ジャンクション側のパス**を指定する（リポジトリの生パスを直接指定すると標準ライブラリか自作ライブラリのどちらかが解決できない）。
- `/inc:` オプションは標準 Include パスを**置き換えてしまう**ため使わない（`Trade.mqh` 等が見つからなくなる）。
- ジャンクションが失われた場合は再作成する:
  ```powershell
  $mq = "$env:APPDATA\MetaQuotes\Terminal\C4171FD2B38378D6406D5C84412B5F20\MQL5"
  New-Item -ItemType Junction -Path "$mq\Include\Signals" -Target "d:\repository\mql5-ea-lab\Include\Signals"
  New-Item -ItemType Junction -Path "$mq\Experts\mql5-ea-lab" -Target "d:\repository\mql5-ea-lab\Experts"
  New-Item -ItemType Junction -Path "$mq\Indicators\mql5-ea-lab" -Target "d:\repository\mql5-ea-lab\Indicators"
  ```

他ブローカー（FXGT / OANDA）のデータフォルダ ID は `docs/lessons_learned.md`。本プロジェクトでは XM しか使わない。

## 報告のルール

コンパイルを**実際に走らせていない**のに「検証済み」と書かない。走らせた場合は `Result:` 行の実数値（例: `0 errors, 0 warnings`）を報告に含める。
