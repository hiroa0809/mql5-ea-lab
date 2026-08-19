//+------------------------------------------------------------------+
//| PivotDraw.mqh                                                    |
//| ピボットを下位足のチャートへ並べる処理                           |
//|                                                                  |
//| 日足ぶんと週足ぶんで中身は同じで、違うのは「どの足を元にするか」  |
//| と色だけ。2ファイルに写すと片方だけ直したときに食い違い、2本の    |
//| 線が別の規則で描かれることになるのでここへ出してある。            |
//|                                                                  |
//| 各インジケーターは #property で色を決め、OnCalculate から         |
//| PV_Update を1回呼ぶだけでよい。                                  |
//|                                                                  |
//| 置き方の定義は docs/indicator_spec.md §5。                       |
//+------------------------------------------------------------------+
#ifndef PIVOTDRAW_MQH
#define PIVOTDRAW_MQH

#include <Signals\HigherTf.mqh>
#include <Signals\Pivot.mqh>

// 元にする足を1本につき1組。添字はその足の shift（0 = 進行中）。
double   g_pvP[], g_pvR1[], g_pvR2[], g_pvR3[], g_pvS1[], g_pvS2[], g_pvS3[];
datetime g_pvTime[];
int      g_pvBars = 0;   // 前回この本数で組み立てた

// 当期の水準を出すのに前期が要るので最低2本。端の判定ぶんを足しておく。
#define PV_NEED_BARS 3

//+------------------------------------------------------------------+
//| 元にする足1本につき1回だけ水準を求めて溜める                     |
//|                                                                  |
//| 添字 0（進行中の足）は埋めない。進行中の高値・安値・終値はまだ   |
//| 動いており、そこから作った水準を当期に描くと、その期間が終わる    |
//| まで分からない値を先に見ることになる。                           |
//+------------------------------------------------------------------+
bool PV_BuildInternal(const ENUM_TIMEFRAMES tf, const int wantBars)
{
   double high[], low[], close[];
   ArraySetAsSeries(high,     true);
   ArraySetAsSeries(low,      true);
   ArraySetAsSeries(close,    true);
   ArraySetAsSeries(g_pvTime, true);

   const int copied = CopyHigh(_Symbol, tf, 0, wantBars, high);
   if(copied < PV_NEED_BARS) return false;
   if(CopyLow(_Symbol,   tf, 0, copied, low)       != copied) return false;
   if(CopyClose(_Symbol, tf, 0, copied, close)     != copied) return false;
   if(CopyTime(_Symbol,  tf, 0, copied, g_pvTime)  != copied) return false;

   ArrayResize(g_pvP,  copied);
   ArrayResize(g_pvR1, copied);
   ArrayResize(g_pvR2, copied);
   ArrayResize(g_pvR3, copied);
   ArrayResize(g_pvS1, copied);
   ArrayResize(g_pvS2, copied);
   ArrayResize(g_pvS3, copied);

   for(int s = 0; s < copied; s++)
   {
      PivotLevels v;
      if(s >= 1 && PV_Calc(high[s], low[s], close[s], v))
      {
         g_pvP[s]  = v.p;
         g_pvR1[s] = v.r1;
         g_pvR2[s] = v.r2;
         g_pvR3[s] = v.r3;
         g_pvS1[s] = v.s1;
         g_pvS2[s] = v.s2;
         g_pvS3[s] = v.s3;
      }
      else
      {
         g_pvP[s]  = EMPTY_VALUE;
         g_pvR1[s] = EMPTY_VALUE;
         g_pvR2[s] = EMPTY_VALUE;
         g_pvR3[s] = EMPTY_VALUE;
         g_pvS1[s] = EMPTY_VALUE;
         g_pvS2[s] = EMPTY_VALUE;
         g_pvS3[s] = EMPTY_VALUE;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| 描画 — OnCalculate から1回呼ぶ                                   |
//|                                                                  |
//| 下位足の1本ずつについて、その足が属する期間の1つ前（＝すでに     |
//| 閉じている期間）から作った水準を写す。1期間ぶん同じ値が続くので、|
//| 線は日付（週）の変わり目でだけ段が変わる。                       |
//|                                                                  |
//| 戻り値はそのまま OnCalculate の戻り値に使う。0 は「まだ描けない、|
//| 次のティックで再挑戦」。                                          |
//+------------------------------------------------------------------+
int PV_Update(const ENUM_TIMEFRAMES tf,
              const int rates_total, const int prev_calculated,
              const datetime &time[],
              double &p[], double &r1[], double &r2[], double &r3[],
              double &s1[], double &s2[], double &s3[])
{
   const int bars = Bars(_Symbol, tf);
   if(bars < PV_NEED_BARS) return 0;   // 元にする足がまだ届いていない

   // 週末や休場で足が飛ぶぶんを見込んで余裕を足す。
   const int ratio    = (int)(PeriodSeconds(tf) / PeriodSeconds(_Period));
   const int wantBars = MathMin(bars, rates_total / ratio + PV_NEED_BARS + 5);

   // 期間が1つ進むと全ての添字がずれる。組み直したら下位足も全部描き直す。
   bool rebuilt = false;
   if(bars != g_pvBars)
   {
      if(!PV_BuildInternal(tf, wantBars)) return 0;
      g_pvBars = bars;
      rebuilt  = true;
   }

   ArraySetAsSeries(time, true);
   ArraySetAsSeries(p,    true);
   ArraySetAsSeries(r1,   true);
   ArraySetAsSeries(r2,   true);
   ArraySetAsSeries(r3,   true);
   ArraySetAsSeries(s1,   true);
   ArraySetAsSeries(s2,   true);
   ArraySetAsSeries(s3,   true);

   int limit = rates_total - 1;
   if(prev_calculated > 0 && !rebuilt)
      limit = MathMin(rates_total - prev_calculated + 1, rates_total - 1);

   const int size = ArraySize(g_pvP);

   int cursor;
   if(!HTF_StartCursor(_Symbol, tf, time[limit], size, cursor)) return 0;

   for(int i = limit; i >= 0; i--)
   {
      const int s = HTF_ConfirmedShift(time[i], g_pvTime, cursor);

      if(s >= size)
      {
         p[i]  = EMPTY_VALUE;
         r1[i] = EMPTY_VALUE;
         r2[i] = EMPTY_VALUE;
         r3[i] = EMPTY_VALUE;
         s1[i] = EMPTY_VALUE;
         s2[i] = EMPTY_VALUE;
         s3[i] = EMPTY_VALUE;
         continue;
      }

      p[i]  = g_pvP[s];
      r1[i] = g_pvR1[s];
      r2[i] = g_pvR2[s];
      r3[i] = g_pvR3[s];
      s1[i] = g_pvS1[s];
      s2[i] = g_pvS2[s];
      s3[i] = g_pvS3[s];
   }

   return rates_total;
}

#endif
