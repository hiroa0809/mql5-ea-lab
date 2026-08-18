//+------------------------------------------------------------------+
//| SqueezeGauge.mq5                                                 |
//| 膠着メーター — 上位足が静かかどうかを別ウィンドウに出す          |
//|                                                                  |
//| 測り方は Include\Signals\Squeeze.mqh に置き、EA と共有する。      |
//| 本ファイルは描画と、上位足を下位足へ並べる部分だけを担当する。   |
//|                                                                  |
//| **どれが人の感覚に近いかを目で見比べるための道具**（2026-08-18   |
//| ユーザー判断）。最終的な絞り込みはバックテストで行う。膠着は     |
//| エントリーの AND 条件の1つになる予定。                           |
//|                                                                  |
//| 縦軸は 0 から。**低いほど静か**。点線より下にいる間が膠着で、その|
//| 間だけ棒の色が変わる。数値を読まなくても目で分かるようにしてある。|
//|                                                                  |
//| 上位足の値をどの位置に並べるかは docs/indicator_spec.md §2.4。   |
//| 測り方の出典は docs/research/2026-08-18-squeeze-detection.md。   |
//+------------------------------------------------------------------+
#property indicator_separate_window
#property indicator_buffers 3
#property indicator_plots   2

// 膠着中だけ色が変わる。金色はスパンモデルの雲（青・赤）とも
// スーパーボリンジャーの帯とも重ならない。
#property indicator_label1  "膠着メーター"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrSlateGray,clrGold
#property indicator_width1  2

// 線は引かない。データウィンドウで足ごとに成否を読むための枠。
#property indicator_label2  "膠着 (1=成立)"
#property indicator_type2   DRAW_NONE

#include <Signals\HigherTf.mqh>
#include <Signals\Squeeze.mqh>

input ENUM_HIGHER_TF      InpHigherTF   = HTF_H1;      // 重ねる上位足
input ENUM_SQUEEZE_METHOD InpMethod     = SQZ_BW_RANK; // 膠着の測り方
input int                 InpPeriod     = 21;          // 期間（センターラインとσ）
input int                 InpLookback   = 120;         // 順位を見る本数
input double              InpThreshold  = 10.0;        // 膠着とみなす水準（順位方式のみ）
input double              InpKcMult     = 1.5;         // ケルトナーの倍率

double BufMeter[], BufColor[], BufSqueezed[];

ENUM_TIMEFRAMES g_tf        = PERIOD_H1;
int             g_needBars  = 0;
double          g_threshold = 0.0;   // 実際に使う水準（③は入力を使わない）

// 上位足1本につき1回だけ求めた結果。添字は上位足の shift（0 = 形成中）。
double   g_meter[];
double   g_raw[];
datetime g_htfTime[];
int      g_htfBars = 0;   // 前回この本数で組み立てた

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriod < 2)
   {
      Print("期間は 2 以上にしてください（σ の分母が 期間−1 のため）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(SQZ_UsesRank(InpMethod) && InpLookback < 2)
   {
      Print("順位を見る本数は 2 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMethod == SQZ_KELTNER && InpKcMult <= 0.0)
   {
      Print("ケルトナーの倍率は 0 より大きくしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_tf = (ENUM_TIMEFRAMES)InpHigherTF;

   if(PeriodSeconds(_Period) >= PeriodSeconds(g_tf))
   {
      PrintFormat("このチャートの時間足では使えません。%s より短い時間足のチャートに貼ってください",
                  HigherTfLabel(g_tf));
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufMeter,    INDICATOR_DATA);
   SetIndexBuffer(1, BufColor,    INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2, BufSqueezed, INDICATOR_DATA);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("膠着 %s %s (%d,%d)",
                                   HigherTfLabel(g_tf), SQZ_MethodLabel(InpMethod),
                                   InpPeriod, InpLookback));
   IndicatorSetInteger(INDICATOR_DIGITS, 1);

   g_threshold = SQZ_EffectiveThreshold(InpMethod, InpThreshold);

   IndicatorSetInteger(INDICATOR_LEVELS, 1);
   IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, g_threshold);
   IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
   IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrDimGray);

   // 順位方式は必ず 0〜100 に収まる。目盛りを固定しておくと、測り方を
   // 切り替えても点線の位置が動かず見比べやすい。
   if(SQZ_UsesRank(InpMethod))
   {
      IndicatorSetDouble(INDICATOR_MINIMUM, 0.0);
      IndicatorSetDouble(INDICATOR_MAXIMUM, 100.0);
   }

   if(SQZ_UsesRank(InpMethod))
      PrintFormat("膠着の測り方: %s ／ 水準は %.1f（この方法の目安は %.1f）",
                  SQZ_MethodLabel(InpMethod), g_threshold, SQZ_DefaultThreshold(InpMethod));
   else
      PrintFormat("膠着の測り方: %s ／ 境目は定義で決まるため「膠着とみなす水準」は使いません。"
                  "調整するのはケルトナーの倍率（今は %.2f）のほうです",
                  SQZ_MethodLabel(InpMethod), InpKcMult);

   if(InpMethod == SQZ_RANGE_RANK)
      Print("⑤は順位を見る本数を 6 にすると、Crabel の NR7（その足を含む7本で最小の値幅）そのものになります。順位は判定する足を母集団から外して数えるので、7本ぶんを見るには 6 を指定します");

   if(InpMethod == SQZ_BW_RANK_HOUR && g_tf == PERIOD_D1)
      Print("日足はどの足も同じ時刻なので、②は①と同じ結果になります");

   g_needBars = SQZ_RequiredBars(InpMethod, InpPeriod, InpLookback);
   g_htfBars  = 0;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 上位足の値を1本につき1回だけ求めて溜める                         |
//|                                                                  |
//| 添字 0（形成中の足）は埋めない。そこから作った値を下位足へ描くと、|
//| その1時間が終わるまで分からないはずの終値を先に見ることになる。   |
//|                                                                  |
//| 順位は生の値を全部並べてから取る。順位を取るたびに元の値を計算し |
//| 直すと、同じ計算を本数ぶん繰り返すことになり桁違いに遅くなる。   |
//+------------------------------------------------------------------+
bool BuildHigherTf(const int wantBars)
{
   double close[], high[], low[];
   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(high,      true);
   ArraySetAsSeries(low,       true);
   ArraySetAsSeries(g_htfTime, true);

   const int copied = CopyClose(_Symbol, g_tf, 0, wantBars, close);
   if(copied < g_needBars) return false;
   if(CopyHigh(_Symbol, g_tf, 0, copied, high)      != copied) return false;
   if(CopyLow(_Symbol,  g_tf, 0, copied, low)       != copied) return false;
   if(CopyTime(_Symbol, g_tf, 0, copied, g_htfTime) != copied) return false;

   ArrayResize(g_raw,   copied);
   ArrayResize(g_meter, copied);

   for(int s = 0; s < copied; s++)
   {
      double value;
      bool ok = false;

      if(s >= 1)
      {
         switch(InpMethod)
         {
            case SQZ_BW_RANK:
            case SQZ_BW_RANK_HOUR:
               ok = SQZ_BandWidth(close, s, InpPeriod, value);
               break;
            case SQZ_KELTNER:
               ok = SQZ_KeltnerRatio(close, high, low, s, InpPeriod, InpKcMult, value);
               break;
            case SQZ_RANGE_SIGMA:
               ok = SQZ_ParkinsonSigma(high, low, s, InpPeriod, value);
               break;
            case SQZ_RANGE_RANK:
               ok = SQZ_BarRange(high, low, s, value);
               break;
         }
      }

      g_raw[s] = ok ? value : EMPTY_VALUE;
   }

   if(!SQZ_UsesRank(InpMethod))
   {
      // ケルトナーは比率がそのままメーターになる。過去の分布を使わない
      ArrayCopy(g_meter, g_raw);
      return true;
   }

   const bool sameHour = SQZ_UsesHour(InpMethod);
   for(int s = 0; s < copied; s++)
   {
      double pct;
      g_meter[s] = SQZ_Rank(g_raw, g_htfTime, s, InpLookback, sameHour, pct) ? pct : EMPTY_VALUE;
   }

   return true;
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 下位足の1本ずつについて、その足が属する上位足の1本前（＝すでに   |
//| 確定している足）の値を写す。写す先が同じ値のまま続くので、棒は   |
//| 上位足1本ぶんの本数だけ同じ高さで並ぶ。                          |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   const int htfBars = Bars(_Symbol, g_tf);
   if(htfBars < g_needBars) return 0;   // 上位足がまだ届いていない。次のティックで再挑戦

   const int ratio    = (int)(PeriodSeconds(g_tf) / PeriodSeconds(_Period));
   const int wantBars = MathMin(htfBars, rates_total / ratio + g_needBars + 2);

   // 上位足が1本増えると全ての添字がずれる。組み直したら下位足も全部描き直す。
   bool rebuilt = false;
   if(htfBars != g_htfBars)
   {
      if(!BuildHigherTf(wantBars)) return 0;
      g_htfBars = htfBars;
      rebuilt   = true;
   }

   ArraySetAsSeries(time,        true);
   ArraySetAsSeries(BufMeter,    true);
   ArraySetAsSeries(BufColor,    true);
   ArraySetAsSeries(BufSqueezed, true);

   int limit = rates_total - 1;
   if(prev_calculated > 0 && !rebuilt)
      limit = MathMin(rates_total - prev_calculated + 1, rates_total - 1);

   const int htfSize = ArraySize(g_meter);

   int cursor;
   if(!HTF_StartCursor(_Symbol, g_tf, time[limit], htfSize, cursor)) return 0;

   for(int i = limit; i >= 0; i--)
   {
      const int s = HTF_ConfirmedShift(time[i], g_htfTime, cursor);

      if(s >= htfSize || g_meter[s] == EMPTY_VALUE)
      {
         BufMeter[i]    = EMPTY_VALUE;
         BufColor[i]    = 0;
         BufSqueezed[i] = EMPTY_VALUE;
         continue;
      }

      const bool squeezed = (g_meter[s] <= g_threshold);

      BufMeter[i]    = g_meter[s];
      BufColor[i]    = squeezed ? 1 : 0;
      BufSqueezed[i] = squeezed ? 1.0 : 0.0;
   }

   return rates_total;
}
//+------------------------------------------------------------------+
