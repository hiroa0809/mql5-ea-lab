//+------------------------------------------------------------------+
//| SuperBollinger.mqh                                               |
//| スーパーボリンジャーの計算とルール1の判定                        |
//|                                                                  |
//| 同じ計算をインジケーターと EA の両方が使うため共通化している。   |
//| 2回書くと片方だけ直したときに食い違い、「チャートは合っている    |
//| のにバックテストがおかしい」という切り分け困難な状態になる。     |
//|                                                                  |
//| 計算定義は docs/indicator_spec.md §2.2。                         |
//+------------------------------------------------------------------+
#ifndef SUPERBOLLINGER_MQH
#define SUPERBOLLINGER_MQH

//+------------------------------------------------------------------+
//| 配列の並びについて                                               |
//|                                                                  |
//| 本ファイルの関数は終値配列が「時系列順」（添字 0 = 最新足）で    |
//| あることを前提にする。呼ぶ側が ArraySetAsSeries(close, true) を  |
//| 済ませること。並びを逆にすると添字 shift+i が過去ではなく未来を  |
//| 指し、エラーは出ないまま値だけが狂う。                           |
//|                                                                  |
//| shift は判定する足。確定足で判定するので通常は 1。               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| センターライン ＝ 終値の period 本 単純移動平均                   |
//+------------------------------------------------------------------+
double SB_Center(const double &close[], const int shift, const int period)
{
   double sum = 0.0;
   for(int i = 0; i < period; i++)
      sum += close[shift + i];
   return sum / period;
}

//+------------------------------------------------------------------+
//| σ ＝ 標本標準偏差（period − 1 で割る）                           |
//|                                                                  |
//| MT5 組み込みの iBands() は母標準偏差（period で割る）のため      |
//| 使わない。そのまま使うとバンド幅が 2.47% 狭くなり、しかも黙って  |
//| 違う値を返す。出典: docs/indicator_spec.md §2.2                  |
//|                                                                  |
//| center には同じ shift / period で求めたセンターラインを渡す。    |
//+------------------------------------------------------------------+
double SB_Sigma(const double &close[], const int shift, const int period, const double center)
{
   double sum = 0.0;
   for(int i = 0; i < period; i++)
   {
      const double d = close[shift + i] - center;
      sum += d * d;
   }
   return MathSqrt(sum / (period - 1));
}

//+------------------------------------------------------------------+
//| 1本ぶんの計算結果                                                |
//+------------------------------------------------------------------+
struct SBValues
{
   double center;                    // センターライン
   double sigma;                     // 標本標準偏差
   double upper1, upper2, upper3;    // センターライン + n×σ
   double lower1, lower2, lower3;    // センターライン − n×σ
};

//+------------------------------------------------------------------+
//| shift の足の全値をまとめて求める                                 |
//|                                                                  |
//| センターラインとσを2度計算しないためにまとめている。            |
//| インジケーターは6本の線の描画に、EA は判定に同じ値を使う。       |
//|                                                                  |
//| 戻り値 false は「計算できない」。呼ぶ側は必ず確認すること。      |
//|   - period が 2 未満だとσの分母 period−1 が 0 以下になる        |
//|   - 配列が足りないと添字がはみ出し実行時エラーで停止する         |
//+------------------------------------------------------------------+
bool SB_Calc(const double &close[], const int shift, const int period, SBValues &out)
{
   if(period < 2 || shift < 0)                  return false;
   if(ArraySize(close) < shift + period)        return false;

   out.center = SB_Center(close, shift, period);
   out.sigma  = SB_Sigma(close, shift, period, out.center);

   out.upper1 = out.center + out.sigma;
   out.upper2 = out.center + out.sigma * 2.0;
   out.upper3 = out.center + out.sigma * 3.0;
   out.lower1 = out.center - out.sigma;
   out.lower2 = out.center - out.sigma * 2.0;
   out.lower3 = out.center - out.sigma * 3.0;

   return true;
}

//+------------------------------------------------------------------+
//| 遅行線 — shift の足に描く値                                      |
//|                                                                  |
//| 定義は「終値を lagBars 本前へずらして描画」。つまり shift の足の |
//| 位置に置くのは、そこから lagBars 本ぶん新しい足の終値になる。    |
//| 時系列順の配列では新しい足ほど添字が小さいので shift − lagBars。 |
//|                                                                  |
//| この向きを間違えても値は返るので、エラーでは気づけない。線が     |
//| 最新足まで伸びていたら逆向き（正しくは lagBars 本手前で切れる）。|
//|                                                                  |
//| 判定に使う「陽転／陰転」は現在の終値と過去の高値・安値を比べる   |
//| 別の形になる。そちらは下の SB_Rule1 が持つ。                     |
//+------------------------------------------------------------------+
bool SB_LagValue(const double &close[], const int shift, const int lagBars, double &out)
{
   const int src = shift - lagBars;
   if(src < 0 || src >= ArraySize(close)) return false;
   out = close[src];
   return true;
}

//+------------------------------------------------------------------+
//| ルール1が必要とする最小の履歴本数                                |
//|                                                                  |
//| 固定値を書かない。期間はすべて入力項目なので、書いた瞬間から     |
//| 入力を変えるたびに嘘になる。末尾の +2 は判定足（shift = 1）と    |
//| その1本前（遷移の判定に使う）ぶん。                              |
//+------------------------------------------------------------------+
int SB_RequiredBars(const int period, const int lagBars, const int squeezeBars, const int expandBars)
{
   return period + lagBars + MathMax(squeezeBars, expandBars) + 2;
}

//+------------------------------------------------------------------+
//| ルール1（トレンド開始）の入力                                    |
//|                                                                  |
//| インジケーターと EA が同じ判定を使うため、条件の ON/OFF まで含め |
//| てここへ集める。③（±1σ の突破）だけ ON/OFF が無いのは、これが  |
//| 引き金であり外すとルールが成立しないため。                       |
//| 出典: docs/implementation_design.md §2                           |
//+------------------------------------------------------------------+
struct SBRule1Params
{
   int    period;        // センターラインとσの期間
   int    lagBars;       // 遅行線の本数
   bool   useSqueeze;    // ①膠着を条件に入れる
   int    squeezeBars;   // ①膠着とみなす本数
   double sigmaMult;     // ①③で使うσの倍数
   bool   useLag;        // ②遅行線の陽転/陰転を条件に入れる
   bool   useExpand;     // ④バンド幅の拡大を条件に入れる
   int    expandBars;    // ④拡大を見る本数
};

//+------------------------------------------------------------------+
//| ルール1の判定結果                                                |
//|                                                                  |
//| 4条件は「使う」設定に関係なく必ず埋める。診断出力が条件ごとの    |
//| 成立回数を他の条件の成否と無関係に数えるため                     |
//| （docs/implementation_design.md §4）。ON/OFF を反映した最終判定  |
//| は buy / sell だけ。                                             |
//+------------------------------------------------------------------+
struct SBRule1Signal
{
   bool squeezed;      // ①遅行スパンが帯の内側にとどまっていた
   bool lagAbove;      // ②遅行線が直近の高値を全て上回っている（買い側）
   bool lagBelow;      // ②遅行線が直近の安値を全て下回っている（売り側）
   bool crossUp;       // ③遅行スパンが帯を上へ突破した（買いの引き金）
   bool crossDown;     // ③遅行スパンが帯を下へ突破した（売りの引き金）
   bool expanding;     // ④バンド幅が拡大している
   bool buy;           // 使う条件がすべて揃った（買い）
   bool sell;          // 同（売り）
};

//+------------------------------------------------------------------+
//| 遅行スパンが帯のどこにいるか — σ 何個ぶん中心線から離れているか  |
//|                                                                  |
//| 遅行線は「今の終値を lagBars 本前の位置へ置いた線」なので、その  |
//| 点の真下にある帯は lagBars 本前の時点で計算された帯になる。      |
//| したがって比べる相手は cur ではなく SB_Calc(shift + lagBars)。   |
//|                                                                  |
//| 戻す値の意味: +1.0 なら遅行スパンが +1σ の線の上に乗っている。   |
//| 21本かけて価格が正味どこへ行ったかを、当時のσで割った量になる。 |
//|                                                                  |
//| σ が 0（21本の終値が全て同値）のときは 0 を返す。動いていない   |
//| のだから帯の内側と扱うのが自然で、割り算も避けられる。           |
//+------------------------------------------------------------------+
bool SB_LagOffset(const double &close[], const int shift, const int lagBars,
                  const int period, double &out)
{
   SBValues v;
   if(!SB_Calc(close, shift + lagBars, period, v)) return false;
   out = (v.sigma > 0.0) ? (close[shift] - v.center) / v.sigma : 0.0;
   return true;
}

//+------------------------------------------------------------------+
//| ルール1 — トレンド開始の4条件を判定する                          |
//|                                                                  |
//| 条件の定義は docs/trading_rules.md §3（用語の一意化）と §4.1     |
//| （エントリー）。本関数は資料の条件番号 ①②③④ をそのまま持つ。 |
//|                                                                  |
//| 終値・高値・安値の3配列とも時系列順（添字 0 = 最新足）が前提。   |
//| 呼ぶ側が ArraySetAsSeries を済ませること。                       |
//|                                                                  |
//| 戻り値 false は「判定できない」。履歴が足りない場合などで、この  |
//| とき out の中身は不定。**戻り値を確認せずに out を読まないこと。**|
//+------------------------------------------------------------------+
bool SB_Rule1(const double &close[], const double &high[], const double &low[],
              const int shift, const SBRule1Params &p, SBRule1Signal &out)
{
   if(shift < 0 || p.period < 2 || p.sigmaMult <= 0.0)        return false;
   if(p.lagBars < 1 || p.squeezeBars < 1 || p.expandBars < 1) return false;

   // ②だけは高値・安値を直接引くので、ここで長さを見る。終値配列の
   // 不足は SB_Calc が各所で弾くため、同じ計算をここで持たない。
   const int lagIdx = shift + p.lagBars;
   if(ArraySize(high) <= lagIdx || ArraySize(low) <= lagIdx) return false;

   // ① 膠着 — 遅行スパンが直前 squeezeBars 本ぶん ±sigmaMult σ の内側に
   // とどまっていた。「21本かけて価格が正味どこへも行っていない」状態を
   // 見ており、帯が細いかどうかは見ていない。判定足そのものは含めない
   // （p11-① は「直前が」膠着）。docs/trading_rules.md §3.2
   out.squeezed = true;
   for(int j = shift + 1; j <= shift + p.squeezeBars; j++)
   {
      double z;
      if(!SB_LagOffset(close, j, p.lagBars, p.period, z)) return false;
      if(MathAbs(z) > p.sigmaMult)
      {
         out.squeezed = false;
         break;
      }
   }

   // ② 遅行線の陽転・陰転 — 遅行線の右端が、そこから判定足の手前までの
   // ローソク足の山を一つ残らず上回っている（谷を一つ残らず下回っている）。
   // 判定足は含めない（自分の高値は終値より必ず上で、必ず不成立になる）。
   // docs/trading_rules.md §3.1
   double hh = high[shift + 1];
   double ll = low[shift + 1];
   for(int k = shift + 2; k <= lagIdx; k++)
   {
      if(high[k] > hh) hh = high[k];
      if(low[k]  < ll) ll = low[k];
   }
   out.lagAbove = (close[shift] > hh);
   out.lagBelow = (close[shift] < ll);

   // ③ 遅行スパンが帯を突破（引き金）— 状態ではなく遷移として扱う。前の
   // 足では内側にいたことまで要求する。①を外した設定でも、外に居続ける
   // 間ずっと発火し続けることがない。docs/trading_rules.md §3.3
   double zNow, zPrev;
   if(!SB_LagOffset(close, shift,     p.lagBars, p.period, zNow))  return false;
   if(!SB_LagOffset(close, shift + 1, p.lagBars, p.period, zPrev)) return false;
   out.crossUp   = (zNow >  p.sigmaMult) && (zPrev <=  p.sigmaMult);
   out.crossDown = (zNow < -p.sigmaMult) && (zPrev >= -p.sigmaMult);

   // ④ バンド幅の拡大 — バンド幅は σ の2倍なので、σ どうしの比較と同値。
   // 1本前と比べるとノイズで成立するため既定は3本前。
   // docs/trading_rules.md §3.2
   SBValues cur, past;
   if(!SB_Calc(close, shift,                p.period, cur))  return false;
   if(!SB_Calc(close, shift + p.expandBars, p.period, past)) return false;
   out.expanding = (cur.sigma > past.sigma);

   out.buy  = out.crossUp   && (!p.useSqueeze || out.squeezed)
                            && (!p.useLag     || out.lagAbove)
                            && (!p.useExpand  || out.expanding);
   out.sell = out.crossDown && (!p.useSqueeze || out.squeezed)
                            && (!p.useLag     || out.lagBelow)
                            && (!p.useExpand  || out.expanding);
   return true;
}

#endif // SUPERBOLLINGER_MQH
