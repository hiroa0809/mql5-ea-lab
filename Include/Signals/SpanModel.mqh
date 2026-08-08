//+------------------------------------------------------------------+
//| SpanModel.mqh                                                    |
//| スパンモデルの計算とルール2の判定                                |
//|                                                                  |
//| 同じ計算をインジケーターと EA の両方が使うため共通化している。   |
//| 計算定義は docs/indicator_spec.md §1.2。                         |
//|                                                                  |
//| MT5 組み込みの iIchimoku() は使わない。先行スパンのバッファは    |
//| すでに 26 本先行させた状態で格納されており、本指標が必要とする   |
//| 「先行させない現在値」は 26 本未来の位置に当たるため CopyBuffer  |
//| では取り出せない。高値・安値から直接計算する。                   |
//+------------------------------------------------------------------+
#ifndef SPANMODEL_MQH
#define SPANMODEL_MQH

//+------------------------------------------------------------------+
//| 配列の並びについて                                               |
//|                                                                  |
//| SuperBollinger.mqh と同じく、高値・安値・終値の配列が「時系列順」|
//| （添字 0 = 最新足）であることを前提にする。呼ぶ側が             |
//| ArraySetAsSeries(arr, true) を済ませること。並びを逆にすると    |
//| 添字 shift+i が過去ではなく未来を指し、エラーは出ないまま値だけ  |
//| が狂う。                                                         |
//|                                                                  |
//| shift は判定する足。確定足で判定するので通常は 1。               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| period 本の高値の最大値                                          |
//+------------------------------------------------------------------+
double SM_HighestHigh(const double &high[], const int shift, const int period)
{
   double v = high[shift];
   for(int i = 1; i < period; i++)
      if(high[shift + i] > v)
         v = high[shift + i];
   return v;
}

//+------------------------------------------------------------------+
//| period 本の安値の最小値                                          |
//+------------------------------------------------------------------+
double SM_LowestLow(const double &low[], const int shift, const int period)
{
   double v = low[shift];
   for(int i = 1; i < period; i++)
      if(low[shift + i] < v)
         v = low[shift + i];
   return v;
}

//+------------------------------------------------------------------+
//| period 本の中値 ＝ (最高値 + 最安値) / 2                         |
//+------------------------------------------------------------------+
double SM_Midpoint(const double &high[], const double &low[], const int shift, const int period)
{
   return (SM_HighestHigh(high, shift, period) + SM_LowestLow(low, shift, period)) / 2.0;
}

//+------------------------------------------------------------------+
//| 1本ぶんの計算結果                                                |
//+------------------------------------------------------------------+
struct SMValues
{
   double tenkan;   // 転換線（既定 9 本の中値）
   double kijun;    // 基準線（既定 26 本の中値）
   double spanA;    // 青いスパン ＝ (転換線 + 基準線) / 2
   double spanB;    // 赤いスパン（既定 52 本の中値）
};

//+------------------------------------------------------------------+
//| shift の足の全値をまとめて求める                                 |
//|                                                                  |
//| 転換線と基準線は青いスパンを出すための途中の値だが、Matrix       |
//| Trader の凡例と突き合わせるときに個別に要るため構造体に残す。    |
//|                                                                  |
//| ここで求めるのは「先行させない現在値」。未来方向へずらす処理は   |
//| 一切行わない（docs/indicator_spec.md §1.3）。ずらすと一目均衡表  |
//| の雲になり、別物になる。                                         |
//|                                                                  |
//| 戻り値 false は「計算できない」。呼ぶ側は必ず確認すること。      |
//+------------------------------------------------------------------+
bool SM_Calc(const double &high[],
             const double &low[],
             const int shift,
             const int tenkanPeriod,
             const int kijunPeriod,
             const int spanBPeriod,
             SMValues &out)
{
   if(shift < 0)                                             return false;
   if(tenkanPeriod < 1 || kijunPeriod < 1 || spanBPeriod < 1) return false;

   const int longest = MathMax(tenkanPeriod, MathMax(kijunPeriod, spanBPeriod));
   const int need    = shift + longest;
   if(ArraySize(high) < need || ArraySize(low) < need)       return false;

   out.tenkan = SM_Midpoint(high, low, shift, tenkanPeriod);
   out.kijun  = SM_Midpoint(high, low, shift, kijunPeriod);
   out.spanA  = (out.tenkan + out.kijun) / 2.0;
   out.spanB  = SM_Midpoint(high, low, shift, spanBPeriod);

   return true;
}

//+------------------------------------------------------------------+
//| 遅行線 — shift の足に描く値                                      |
//|                                                                  |
//| 定義は「終値を lagBars 本前へずらして描画」。SuperBollinger.mqh  |
//| の SB_LagValue と同じ考え方で、時系列順の配列では                |
//| shift − lagBars を引く。本数だけが違う（スパンモデルは既定 26、  |
//| スーパーボリンジャーは既定 21）。                                |
//|                                                                  |
//| 向きを誤っても値は返るためエラーでは気づけない。線が最新足まで   |
//| 伸びていたら逆向き（正しくは lagBars 本手前で切れる）。          |
//+------------------------------------------------------------------+
bool SM_LagValue(const double &close[], const int shift, const int lagBars, double &out)
{
   const int src = shift - lagBars;
   if(src < 0 || src >= ArraySize(close)) return false;
   out = close[src];
   return true;
}

//+------------------------------------------------------------------+
//| ルール2が必要とする最小の履歴本数                                |
//|                                                                  |
//| 固定値を書かない。期間はすべて入力項目なので、書いた瞬間から     |
//| 入力を変えるたびに嘘になる。末尾の +2 は判定足（shift = 1）と    |
//| その1本前（遷移の判定に使う）ぶん。                              |
//|                                                                  |
//| 転換線の期間も必ず含める。既定値では 9 < 52 なので赤スパンが最大 |
//| になるが、3つとも入力項目である以上「転換線が一番小さい」は前提  |
//| にできない。SM_Calc は3つすべての履歴を読むため、外すと足りない  |
//| 状態で「足りている」と判定してしまう。                           |
//+------------------------------------------------------------------+
int SM_RequiredBars(const int tenkanPeriod,
                    const int kijunPeriod,
                    const int spanBPeriod,
                    const int lagBars,
                    const int slopeBars)
{
   return MathMax(tenkanPeriod, MathMax(kijunPeriod, spanBPeriod)) + lagBars + slopeBars + 2;
}

#endif // SPANMODEL_MQH
