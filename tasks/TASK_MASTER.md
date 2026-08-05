# マスタータスクリスト

## 現在地: ロジック全破棄・次のロジック未定（2026-08-05）

3指標（CCI/CMO/RSI）＋プライスアクションの構成は**全て破棄した**。RSI の売買反転・銘柄変更でもプラス収益に届かなかったため、ロジックの手直しではなく作り直しに切り替える。

- [ ] **N1: 次に試すロジックを決める**
  - **着手前に確定事実を読む・再導出禁止**:
    - **破棄の理由は実装ミスではなくコスト前提の誤り**。往復スプレッドを10倍小さく見積もっていた（`USDCNH#` の実測 22 pips に対し、想定していたグロス優位性は 5.06 pips）。詳細は `docs/lessons_learned.md`
    - **新ロジックの候補を評価するときは、まず対象銘柄の往復コストを実測して優位性の予算と比較する**。これを先にやらないと同じ失敗を繰り返す（`docs/lessons_learned.md` の「破棄した試行から得た一般則」）
    - 検証の期間分割・回数制限は `docs/backtest_design.md` に独立させた。**ロジックが変わってもこの設計は変えない**
    - 旧コードは `_archive/2026-08-05-legacy/`（Git 対象外・ローカルのみ）。**部品取り場**として温存しており、消していない
  - 決めること: エントリーの着想 / 対象銘柄・時間足 / 想定する保有期間 / 優位性の予算（pips）

## 参照

| 文書 | 内容 |
|---|---|
| `docs/backtest_design.md` | 期間3層（IS / 検証用 / 最終OOS）、データ制約、通貨ペア分割。**ロジック非依存** |
| `docs/lessons_learned.md` | 破棄した試行から得た一般則、MQL5/テスターの罠、CodeRabbit 運用。**ロジック非依存** |
| `.claude/CLAUDE.md` | Git 運用ルール、MQL5 ビルド手順、ジャンクション構成 |

## 環境（維持済み・作り直し不要）

- [x] A1: MQL5 コンパイル環境（2026-07-26）— XM の MetaEditor を CLI 呼び出し。ジャンクションでリポジトリを MT5 データフォルダに接続。手順は `.claude/CLAUDE.md`「MQL5 ビルド」
- [x] A2: 開発フロー用スキル（2026-07-26）— `go` / `fin` / `commit-pr` / `coderabbit-review`
- [x] A3: CodeRabbit の MQL5 対応検証（2026-07-26 PR #1）— 対応を確認。詳細は `.claude/CLAUDE.md`

> ジャンクション3本（`Experts` / `Include\Signals` / `Indicators`）はリポジトリを指したまま有効。参照先が空になっただけで、新ロジックの実装時にそのまま使える。

## 流用候補（`_archive/2026-08-05-legacy/` に温存）

次のロジックが決まってから、必要な部分だけ引く。**先回りして汎用テンプレート化はしない**。

| 元ファイル | 流用できる部分 |
|---|---|
| `Experts/EaPriceAction.mq5` | 逆指値エントリーの予約・N本以内キャンセル、ストップレベルの最小距離丸め（`NormalizeStopLevel`）、ヘッジ口座での建玉特定（`CurrentPositionDir`）、取引要求の結果コード確認（`ReportTradeResult`）、N本タイムストップ、新規足判定、シグナル描画 |
| `Include/Signals/ISignal.mqh` | シグナル部品の共通インターフェース（`Init` / `Update` / `Entry`）、クロス判定ヘルパ |
| `Experts/EaLab.mq5` | 売買反転・片側テスト・決済方式の input 切替の作り |

破棄したロジック本体（`PriceAction.mqh` のパターン検出、`SignalRSI.mqh`、`SignalCMO.mqh`、`PriceActionViewer.mq5`、旧仕様書、バックテスト結果 xlsx、前プロジェクトの research データ）も同じ場所にあるが、**結論が無効なので流用しない**。
