//+------------------------------------------------------------------+
//| SuperBollinger.mqh                                               |
//| スーパーボリンジャーの計算                                       |
//|                                                                  |
//| 同じ計算をインジケーターと EA の両方が使うため共通化している。   |
//| 2回書くと片方だけ直したときに食い違い、「チャートは合っている    |
//| のにバックテストがおかしい」という切り分け困難な状態になる。     |
//|                                                                  |
//| **ルール1（スーパーボリンジャー単体の売買）は 2026-08-14 に打ち  |
//| 切った。** 4条件の判定・決済（陰転 / SAR / 併用）・段階エントリー |
//| はすべてここから削除してある。実装はコミット 1629436 までの履歴に|
//| 残っており、EA 本体は _archive/2026-08-14-rule1/ にある。        |
//|                                                                  |
//| 本ファイルが受け持つのは R3（統合）で使う分だけ。上位足で大局を  |
//| 把握する用途に絞り、**帯の計算と拡大の判定**を持つ。             |
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
//+------------------------------------------------------------------+
bool SB_LagValue(const double &close[], const int shift, const int lagBars, double &out)
{
   const int src = shift - lagBars;
   if(src < 0 || src >= ArraySize(close)) return false;
   out = close[src];
   return true;
}

//+------------------------------------------------------------------+
//| バンド幅が拡大しているか（エクスパンション）                     |
//|                                                                  |
//| expandBars 本前のσと比べて広がっていれば true。R3 では上位足の  |
//| 大局把握にこれだけを使う（docs/trading_rules.md §6）。           |
//|                                                                  |
//| **expandBars = 8 は M15 のルール1で決めた値**（tasks/            |
//| TASK_MASTER.md N6-1b）。上位足で妥当かは未検証。                  |
//+------------------------------------------------------------------+
bool SB_Expanding(const double &close[], const int shift, const int period,
                  const int expandBars, bool &out)
{
   if(expandBars < 1) return false;

   SBValues cur, past;
   if(!SB_Calc(close, shift,              period, cur))  return false;
   if(!SB_Calc(close, shift + expandBars, period, past)) return false;

   out = (cur.sigma > past.sigma);
   return true;
}

//+------------------------------------------------------------------+
//| 必要とする最小の履歴本数                                         |
//|                                                                  |
//| 固定値を書かない。期間はすべて入力項目なので、書いた瞬間から     |
//| 入力を変えるたびに嘘になる。末尾の +2 は判定足（shift = 1）と    |
//| 余裕ぶん。                                                       |
//+------------------------------------------------------------------+
int SB_RequiredBars(const int period, const int lagBars, const int expandBars)
{
   return period + lagBars + expandBars + 2;
}

#endif
