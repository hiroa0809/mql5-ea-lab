# research/ — 前プロジェクトから持ち込んだ検証データ

3 指標（CCI / CMO / RSI）の採用根拠となった IS/OOS 検証の生データとスクリプト。
出典は **`D:\Antigravity\OLS-MeanReversion_MT5\research\`**（本リポジトリ外）。

> **このディレクトリの中身は `.gitignore` 済み**（README.md を除く）。合計 4.5MB の生データで
> リポジトリに載せる必要がないため、ローカル管理とする。失った場合は上記の出典から再取得する。

## 中身

| パス | 内容 |
|---|---|
| `run_spread_regime_recheck.py` | スプレッド・レジーム再点検（2026-07-27 実行）。`phase1_combined_cells.csv` と `data/historical_15m.db` に依存 |
| `harness/spread.py` | pip / point 換算と往復スプレッド表の構築。上記スクリプトの import 先 |
| `results/phase1_combined_cells.csv` | 全 12,064 セル（29銘柄 × 11指標 × 4時間足 × N=[3,6,12,24]）の IS/OOS 期待値 |
| `results/spread_regime_*` | 銘柄別・年別の実測スプレッド、カバレッジ、ランキング |

`data/historical_*.db` は持ち込んでいないため、`run_spread_regime_recheck.py` をそのまま
再実行することはできない。CSV の参照のみ可能。

## 本リポジトリでの使いどころ

採用構成（`docs/entry_signal_spec.md` §1.2）の裏付け。とくに:

- **N24 が決済ルールである根拠** — `phase1_combined_cells.csv` を `symbol=USDCNH, tf=15m,
  indicator∈{RSI,CCI,CMO}` で絞ると、N=12 / N=24 が `oos_survivor=True`、N=3 / N=6 が
  `False` であることを確認できる
- **往復スプレッド 3.4 pips の根拠** — `spread_regime_symbols.csv` の
  `round_trip_pips_current`、および `spread_regime_yearly_15m.csv` の年別推移

なお、結論をまとめた `ea-component-edge.md` は持ち込んでいない（出典側にある）。
