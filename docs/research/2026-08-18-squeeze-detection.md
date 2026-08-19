# ドル円1時間足でボリンジャーバンドの「スクイーズ（収縮）」を機械的に判定する方法：徹底調査

## TL;DR
- **結論：あなたの制約（固定pips不可・1時間足・標本標準偏差・部品最小）に最も合うのは「BandWidth のパーセンタイル/percent-rank 方式」だが、ドル円1時間足では時間帯によるボラティリティの日中季節性が最大の落とし穴になるため、単純なローリング・パーセンタイルではなく『同一曜日・同一時間帯だけを母集団にしたパーセンタイル』にすべきである。** BandWidth=(上バンド−下バンド)/中バンド はスケール不変（無次元）で、標本/母標準偏差の違いは順位を変えないため、あなたの環境に理想的。
- **統計的裏付け：「低ボラの後に高ボラが来る（ボラティリティ・クラスタリング）」は Engle(1982) 以来の確立した事実で、査読論文が多数ある。しかし「スクイーズ後のブレイクに“方向”の予測力がある」ことを示す査読済み証拠は見つからなかった。** 方向は概ね五分五分で、エッジがあるとすれば「当たったときの値幅＞外したときの損失」という非対称性に依存する（ブログのバックテスト水準の主張）。
- **John Bollinger 本人は母標準偏差（nで割る）を使うと明言。** BandWidth と The Squeeze は書籍 *Bollinger on Bollinger Bands* の別々の章（第8章＝指標、第15章＝スクイーズ）にある。「過去6ヶ月で最低」は慣習であり、統計的根拠は示されていない。

## Key Findings（要点）

1. **BandWidth の定義（一次情報確認済み）**：`BandWidth = (UpperBB − LowerBB) / MiddleBB`。Bollinger 本人のサイト（bollingerbands.us）で「上バンド−下バンド÷中バンド」と明記。StockCharts など多くは ×100 して%表示。デフォルトは20期間SMA・±2標準偏差。
2. **Bollinger は母標準偏差（population, nで割る）を使う**：bollingerbands.com/bollinger-bands の John Bollinger 本人記述で確認：「*an n period moving average with bands drawn above and below at intervals determined by a multiple of standard deviation (We use the population calculation for standard deviation). The defaults today are the same as they were 35 years ago, 20 periods for the moving average with the bands set at plus and minus two standard deviations of the same data used for the average.*」あなたが使う標本標準偏差（n−1）だと帯が √(n/(n−1)) 倍広くなる（n=21 で約2.47%増）が、**パーセンタイル方式なら単調変換なので順位は不変**。
3. **「6ヶ月で最低」は慣習で統計的根拠なし**：StockCharts の operationalization。Bollinger 本人の「簡易版」定義は「過去6ヶ月で最低のボラティリティ」だが、6ヶ月（≈125営業日）に理論的正当化はない。Bollinger 自身は統計的仮定を置くなと警告（Rule #14）。
4. **Bollinger の「厳密版」スクイーズ定義**：書籍 p.194（電子版）に、20日標準偏差そのものに対して125日・1.5σのボリンジャーバンドをかけ、20日標準偏差が下バンドにタッチしたらスクイーズ、という二段構えの定義がある。
5. **TTM Squeeze（John Carter）**：BB(20, 2σ) が KC(20, 1.5×ATR) の**内側に完全に入った**とき squeeze on（両側条件）。原典 *Mastering the Trade* 第11章。
6. **代替手法**：NR7/NR4（Crabel）、Choppiness Index（Dreiss）、Efficiency Ratio（Kaufman）、Chaikin Volatility、Historical Volatility Ratio、ADX、Parkinson/Yang-Zhang などレンジ系推定量、BBWP（percentile版）。
7. **自己言及批判**：BandWidth を「同じ期間で作った帯」と「その同じ期間」で比べる循環性の指摘はあるが、パーセンタイル方式は"現在の値 vs 過去N本"を比べるので実質的に意味がある（自己言及ではない）。
8. **真の落とし穴**：(a) FX1時間足の日中季節性、(b) ルックアヘッド/確定足遅延、(c) パラメータ過学習、(d) 方向の予測力欠如、(e) head fake（Bollinger自身が警告）。

---

## Details（手法ごとの詳細）

各手法を指定フォーマット（名前／式／既定パラメータと根拠／出典／固定値幅の有無／検証公開の有無）で示す。

### A. Bollinger BandWidth（＋パーセンタイル方式）

- **式**：`BandWidth = (UpperBB − LowerBB) / MiddleBB`（多くの実装は ×100）。ここで `MiddleBB = SMA(close, 20)`、`UpperBB = MiddleBB + 2σ`、`LowerBB = MiddleBB − 2σ`、σ は20期間の終値標準偏差。式を展開すると `BandWidth = 4σ / SMA`（±2σの場合、上下差=4σ）。Bollinger 自身は Rule #18 で「デフォルトなら BandWidth は変動係数(coefficient of variation)の4倍」と述べる。
- **パーセンタイル方式**：現在の BandWidth が過去N本の中で下位何%かを計算（percent rank）。下位10%や5%をスクイーズとする。
- **既定パラメータと根拠**：BB は 20期間・2σ（Bollinger の35年不変のデフォルト、根拠は経験則）。パーセンタイルの N は BBWP のデフォルトが**252本**（The_Caretaker のTradingView版）、日足の「6ヶ月」= **125〜126本**が慣習。閾値（下位5%/10%/20%、または期間最低値）はいずれも慣習で統計的根拠なし。
- **出典**：*Bollinger on Bollinger Bands*（McGraw-Hill, 2001／20周年版2021）第8章「Bollinger Band Indicators」（BandWidth指標）、第15章「The Squeeze」；bollingerbands.com（一次）；StockCharts ChartSchool（二次）；BBWP は The_Caretaker, TradingView。
- **固定値幅**：BandWidth 自体は**含まない**（中バンドで割るのでスケール不変）。ただし「BandWidth < 10%」のような固定閾値は含む＝あなたのケースでは不可。パーセンタイル方式は固定値幅を含まない。
- **検証公開**：Quantified Strategies, StratBase, Volatility Box などのブログ・バックテストあり（後述、査読なし）。

### B. TTM Squeeze（John Carter）

- **式／判定**：BB(20, 2σ) と KC(20, 1.5×ATR) を計算し、`upperBB < upperKC かつ lowerBB > lowerKC`（＝BBがKCの内側に完全格納）で **squeeze on**。BBがKCの外に出たら **squeeze fired（点火）**。両側条件である。
- **ケルトナーチャネル**：Carter は Chester Keltner の原型（SMAベース、True Range の平均）を使うと StockCharts は明記。ただし LazyBear 版など多くの実装は EMA/SMA と ATR(SMA平均) を使う（実装差あり）。
- **モメンタム**：Carter 原典は「15期間の終値と、その5期間線形回帰の差」。LazyBear 版は線形回帰ベースのヒストグラム。
- **既定パラメータと根拠**：BB(20,2)、KC(20,1.5×ATR)。20/2 は Bollinger 由来、1.5 は Carter の選択（経験則、根拠の明示なし）。TTM Squeeze Pro では KC倍率を複数（2.0/1.5/1.0）使う。
- **出典**：John F. Carter, *Mastering the Trade*（McGraw-Hill, 初版2005/第2版2012/第3版2019）第11章。LazyBear "Squeeze Momentum Indicator", TradingView（KC倍率1.5、線形回帰モメンタム）。
- **固定値幅**：**含まない**（BBもKCも価格から動的計算、スケール不変）。
- **検証公開**：ブログのバックテストあり。査読論文なし。

### C. NR7 / NR4 / ID-NR4（Toby Crabel）

- **式**：NR7 = 当日のレンジ(High−Low)が直近7本で最小。NR4 = 直近4本で最小。ID/NR4 = インサイドデイ かつ NR4。
- **点火**：NR日の高値上抜けで買い、安値下抜けで売り（オープニングレンジ・ブレイク）。
- **既定パラメータと根拠**：7本・4本は Crabel の経験則。7は「約1週間」の含意。
- **出典**：Toby Crabel, *Day Trading with Short Term Price Patterns and Opening Range Breakout*（Traders Press, 1990、絶版）。同書は約288–300ページで、O/H/L/C のみを使うパターンの統計表が中心。StockCharts ChartSchool（二次）。
- **固定値幅**：**含まない**（順位比較のみ、完全スケール不変）。**部品最小（高値・安値のみ）**であなたの制約に非常に合う。
- **検証公開**：Crabel の原著が pre-1990 先物の統計表を含む（一次的検証）。Quantified Strategies 等のブログ再検証あり。

### D. Choppiness Index（E.W. "Bill" Dreiss）

- **式**：`CI = 100 × log10( ΣATR(1, n) / (MaxHigh(n) − MinLow(n)) ) / log10(n)`。0–100。高い＝もみ合い、低い＝トレンド。
- **既定パラメータ**：n=14。閾値は 61.8以上＝もみ合い、38.2以下＝トレンド（フィボナッチ由来、慣習）。
- **出典**：Dreiss, "The Fractal Wave Algorithm", Commodity Traders Consumer Report, 1992。
- **固定値幅**：**含まない**（log正規化で完全にスケール不変・無次元）。
- **検証公開**：ブログのバックテストあり。査読なし。
- **注意**：CI は「もみ合い/トレンド」を測るもので、「帯が細い＝低ボラ」とは概念が違う（もみ合いでもレンジが広いことはある）。

### E. Efficiency Ratio（Perry Kaufman）

- **式**：`ER = |Close_t − Close_{t−N}| / Σ|Close_i − Close_{i−1}|`（i=t−N+1..t）。0–1。1＝完全トレンド、0＝完全ノイズ。
- **既定パラメータ**：N=10（KAMA用）。
- **出典**：Perry Kaufman, *Smarter Trading*（1995）／*New Trading Systems and Methods*。
- **固定値幅**：**含まない**（比率、無次元・スケール不変）。終値のみで計算可。
- **検証公開**：ブログのバックテストあり。
- **注意**：CI 同様「方向効率」を測る。低ボラ検出そのものではない（分母＝総移動量が小さければ低ボラと相関するが直接ではない）。

### F. Chaikin Volatility（Marc Chaikin）

- **式**：`CV = (EMA(H−L, n) − EMA(H−L, n)[n本前]) / EMA(H−L, n)[n本前] × 100`。
- **既定パラメータ**：n=10。
- **出典**：Marc Chaikin。Fidelity, TradingTechnologies 等の指標ガイド。
- **固定値幅**：**含まない**（変化率%）。ただし「レンジの絶対水準」ではなく「レンジの変化率」を測る＝スクイーズ（低い水準）の検出には不向き。ギャップを無視。
- **検証公開**：体系的バックテストは乏しい。

### G. Historical Volatility Ratio（HVR）

- **式**：`HVR = 短期HV / 長期HV`（例：6日HV / 100日HV）。低い＝短期ボラが長期比で収縮。
- **既定パラメータ**：短期6、長期100 が一例（慣習）。
- **出典**：TradingView オープンソーススクリプト等。原典の確立した書籍は特定できず＝**二次情報**。
- **固定値幅**：**含まない**（比率、スケール不変）。
- **検証公開**：体系的なものは見つからず。

### H. レンジ系ボラティリティ推定量（Parkinson / Garman-Klass / Rogers-Satchell / Yang-Zhang）

- **式（Parkinson）**：`σ_P² = (1/(4·ln2·N)) Σ (ln(H_i/L_i))²`。高値・安値のみ。Parkinson(1980) は終値法の約5倍効率的。
- **Yang-Zhang**：`σ_YZ² = σ_overnight² + k·σ_open-close² + (1−k)·σ_RS²`、k=0.34/(1.34+(N+1)/(N−1))。ギャップとドリフトに頑健で最も効率的。効率性は出典により差があり、PortfoliosLab は「終値法比で14倍効率的（14 times more efficient than the close-to-close estimator）」、FlashAlpha は「~14x Yang-Zhang」かつ「5日のYang-Zhang推定は約70日の終値法推定と同等の統計精度を持つ」と記載する一方、IWP/MetricGate は「約8倍効率的（roughly eight times more efficient）」とするなど、資料により約5〜14倍と幅がある。
- **出典**：Parkinson (1980) J. Business；Garman-Klass (1980)；Rogers-Satchell (1991)；Yang & Zhang (2000) "Drift-Independent Volatility Estimation Based on High, Low, Open, and Close Prices", Journal of Business 73(3):477–491。**査読論文（一次）**。
- **固定値幅**：**含まない**（対数リターンの標準偏差、スケール不変）。高値・安値ベースで少ない足数で安定推定。
- **検証公開**：効率性は査読論文で厳密に検証済み（ただし「スクイーズ→ブレイク」ではなく「ボラ推定精度」の検証）。
- **使い方**：短期σ_YZ を過去N本でパーセンタイル化すれば、BandWidth より統計的に効率的な収縮指標になりうる。ただし部品は増える。

### I. ADX（Wilder）

- **式**：DI+/DI− から DX を計算し、その Wilder 平滑平均。トレンド強度（0–100）。
- **既定パラメータ**：14。低ADX（<20/25）＝トレンド弱＝もみ合いの示唆。
- **出典**：J. Welles Wilder, *New Concepts in Technical Trading Systems*（1978）。
- **固定値幅**：含まない。ただし ADX は方向性の強さで、低ボラ（帯が細い）とは別概念。

### J. BBWP（Bollinger Band Width Percentile）

- **式**：BandWidth を過去 lookback 本で percent rank（現在値未満だった本数の割合%）。
- **既定パラメータ**：BBWP Length 13（BB期間）、Lookback **252**（The_Caretaker版デフォルト）。5%以下＝極端な収縮、95%以上＝極端な拡大。
- **出典**：The_Caretaker, TradingView（Eric Krown が普及）。**二次情報**（確立した書籍なし）。
- **固定値幅**：**含まない**。**あなたの制約に最も直接的に合致**。

---

## 統計的裏付け（論点6）

- **確立している事実**：ボラティリティ・クラスタリング（低ボラの後に低ボラ、高ボラの後に高ボラ）は Engle, R.F. (1982) "Autoregressive Conditional Heteroscedasticity with Estimates of the Variance of United Kingdom Inflation", *Econometrica* Vol.50, No.4, pp.987–1008（DOI:10.2307/1912773）以来、為替を含む多資産で査読論文により堅牢に確認されている。同論文は要旨で「the recent past gives information about the one-period forecast variance（直近の過去は1期先の予測分散についての情報を与える）」と述べる。したがって「今が低ボラなら、近い将来も低ボラが続きやすい」「低ボラはいずれ高ボラに転じる」という平均回帰的性質には統計的根拠がある。
- **見つからなかったもの**：「ボリンジャー・スクイーズ後のブレイクに“方向”の予測力がある」ことを示す**査読済み**証拠は見つからなかった。学術的コンセンサスは「ボラの大きさ(amplitude)は予測可能だが、符号(方向)は無相関に近い」（例：ボラクラスタリング論文が明言）。
- **ブログ水準の検証（査読なし、体験談とは区別）**：
  - Quantified Strategies：スクイーズ・ブレイク戦略を検証し、明確なエッジは限定的と報告。
  - Superalgos（Medium, Thomas Huault）：Keltner/Bollinger スクイーズを Superalgos でバックテスト→「55トレード、勝率55%、初期資本を全損」という否定的結果。
  - Quant-signals.com：6市場12バックテストで7勝（58%）。**D1がH1に優り、暗号資産が良好、FX(EURUSD/GBPUSD)は最弱**。スプレッド未計上で「H1の薄いエッジはコスト後にマイナスになりうる」と自認。
  - Volatility Box：S&P500構成銘柄でスクイーズ・ブレイク（BBW<4%＋出来高確認）は5–10バーで正の期待値。方向的中率は55–60%程度で「勝ちが負けより大きい」非対称性がエッジ源と主張。
- **要するに**：スクイーズは「ボラ拡大が近い」ことのシグナルとしては理論的裏付けがあるが、「どちらに動くか」は教えてくれない。エッジは方向当てではなく損益非対称性とリスク管理に依存する。

## 為替・1時間足での使用（論点7）＆最大の落とし穴（論点8）

- **FX1時間足の日中季節性（最重要）**：USDJPY のイントラデイ・ボラティリティは時間帯で体系的に異なる。Ito & Hashimoto (2006)（NBER Working Paper No. 12413；*Journal of the Japanese and International Economies* Vol.20, Issue 4, Dec 2006, pp.637–664 に掲載）は、SSRN 要旨で「*The U-shape of intra-day activities (deals and price changes) and return volatility is confirmed for Tokyo and London participants, but not for New York participants.*」と述べ、別研究の要約では「*Ito and Hashimoto [2006] observes a U-shaped pattern for both the Japanese Yen and the Euro quoted in US Dollars starting at 8:00 GMT going up to 15:00 GMT.*」とされる。アジア時間（日本の昼〜夕方に相当する静かな時間帯）は恒常的に低ボラ。したがって**単純な過去N本ローリング・パーセンタイルは、アジア時間を常にスクイーズと誤判定する**。この日中季節性の存在自体は査読論文で確立しているが、「ローリング BandWidth パーセンタイルにこの特定のバイアスがかかる」ことを名指しで論じた文献は見つからなかった（推論として提示）。
- **対策**：時間帯ダミー（session）で正規化する、または「同一時間帯（＋できれば同一曜日）だけを母集団にしたパーセンタイル」を使う。週末ギャップ・ロンドンフィックス（16:00 London）・主要指標（NFP, FOMC, 日銀）時刻も体系的スパイク源。
- **株式・日足の話の流用問題**：Bollinger の「6ヶ月＝125営業日」や NR7 の「7日」、BBWP の「252」は**日足の慣習**。1時間足に無反省に持ち込むと lookback の意味（カバーする実時間）が全く変わる。lookback は時間足に合わせて再設計が必要。
- **自己言及/循環の批判**：「同じ20期間から作った帯を、同じ20期間のデータと比べている」形は確かに情報がない（BandWidth の瞬間値と現在の σ は同一情報）。しかし**パーセンタイル方式は「現在の BandWidth」を「過去N本（N≫20）の BandWidth 分布」と比べる**ので、循環ではなく「現在のボラが過去の自分と比べて低いか」を測っており、情報がある。BandWidth 単体を固定閾値で見るのが循環的批判の対象。
- **その他の落とし穴**：(a) ルックアヘッド・バイアス（確定足のみ使えば回避できるが1本分の遅延が生じる）、(b) パラメータ最適化の過学習（N・閾値・BB期間を後知恵で選ぶ）、(c) 複数比較問題、(d) head fake（Bollinger 自身が書籍で警告した"だまし"のブレイク）。

---

## 制約適合度ランキングと推奨

あなたの制約＝(1)固定pips不可＝スケール不変必須、(2)FX1時間足、(3)標本標準偏差環境、(4)部品最小。

| 順位 | 手法 | スケール不変 | 部品の少なさ | 1時間足適性 | 総合 |
|---|---|---|---|---|---|
| 1 | **BandWidth のパーセンタイル（BBWP方式）** | ◎ | ◎（SMA+σのみ） | ○（時間帯調整必要） | 最適 |
| 2 | NR7/NR4（順位方式） | ◎ | ◎（H,Lのみ） | ○ | 高 |
| 3 | Yang-Zhang等レンジσのパーセンタイル | ◎ | △（式が複雑） | ◎ | 高（精度重視なら） |
| 4 | TTM Squeeze | ◎ | △（BB+KC+ATR） | ○ | 中 |
| 5 | Choppiness / Efficiency Ratio | ◎ | ○ | ○ | 中（概念がややズレ） |

**推奨（1つ）**：**BandWidth のパーセンタイル方式（BBWP型）を、ドル円1時間足では「同一時間帯（時刻）を母集団にしたパーセンタイル」に改造して使う。**

理由：
- BandWidth=(上−下)/中 は無次元でスケール不変＝104円でも150円でも同じ意味（固定pips不要）。
- 標本標準偏差でも順位は不変なので、あなたの環境をそのまま使える。
- 部品は SMA と標準偏差だけ＝最小。
- 唯一かつ最大の弱点である日中季節性を「時刻別パーセンタイル」で除去できる。

**疑似コード（確定足のみ・ルックアヘッドなし）**：
```
# 確定足のみ使用。t は確定済みの最新足。
sd   = stdev_sample(close[t-20+1 .. t])        # 標本標準偏差(n-1)でOK
mid  = sma(close[t-20+1 .. t])
bw   = (2*sd*2) / mid                            # = 4σ/SMA （上下差=4σ）
hour = hour_of(t)                                # 時刻（UTC等で固定）
# 同一時刻の過去BandWidthを母集団に（例：過去60営業日分の同時刻）
pool = [ bw_history[s] for s in past_bars if hour_of(s)==hour ]  # t自身は除外
pct  = count(pool < bw) / len(pool) * 100
squeeze = (pct <= 10)                            # 下位10%をスクイーズ（閾値は要検証）
# 点火：確定足の終値が上バンド超え/下バンド割れ
fired_up   = close[t] > mid + 2*sd
fired_down = close[t] < mid - 2*sd
```

**推奨を変える閾値（ベンチマーク）**：
- 時刻別パーセンタイルにしても誤検出（アジア時間偏重）が残るなら → Yang-Zhang σ の時刻別パーセンタイルに切替（精度向上、部品増）。
- スクイーズ後の実現ボラ拡大が統計的に確認できない（例：スクイーズ判定後Kバーの平均レンジが非スクイーズ時と差がない）なら → その時間足・銘柄でこの概念自体を放棄。
- 方向を当てにいく運用に発展させる場合 → 方向予測力は査読研究になく期待値は損益非対称性頼みなので、必ず「ブレイク方向にのみ乗る・逆行で即撤退・head fake 前提のストップ」を組む。

## Caveats（留意点）
- 一次資料（書籍本文）のページ番号は版により異なる。第8章＝BandWidth指標、第15章＝The Squeeze（初版でp.119前後）、「厳密版」定義はp.194（電子版、TradingViewスクリプト経由で二次的に確認、書籍原本を直接確認できず＝二次情報）。
- 「6ヶ月」「252本」「N=14/10/7」等の数値はすべて慣習であり、統計的最適化の裏付けは原典に示されていない。
- スクイーズ→ブレイクの「方向」予測力を支持する査読研究は**見つからなかった**。ブログのバックテスト（査読なし）と体験談は区別して扱うこと。
- Yang-Zhang の効率倍率は出典により約5〜14倍と幅があり、単一の確定値ではない。
- FX1時間足での日中季節性バイアスを「ローリングBandWidthパーセンタイルの問題」として名指しした文献は**見つからなかった**（日中季節性の存在自体は査読論文で確立、バイアスは論理的推論）。
- HVR・BBWP は確立した書籍原典が特定できず二次情報。