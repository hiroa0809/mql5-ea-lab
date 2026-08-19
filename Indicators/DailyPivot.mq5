//+------------------------------------------------------------------+
//| DailyPivot.mq5                                                   |
//| デイリーピボットの描画（反転のサインを目で確かめる用）           |
//|                                                                  |
//| 計算は Include\Signals\Pivot.mqh に置き、EA と共有する。          |
//| 本ファイルは描画だけを担当し、式を持たない。                     |
//|                                                                  |
//| **当日の水準は前日の確定した日足から作る。** 日付が変わる所で段が |
//| 変わり、その日の中では動かない。上位足の値を下位足へ並べる規則は  |
//| 帯の重ね表示と共通で、Include\Signals\HigherTf.mqh に置いてある   |
//| （docs/indicator_spec.md §2.4）。                                |
//|                                                                  |
//| 7本すべて出しているが、いらない線は「カラー」タブで個別に消せる。 |
//| チャートには既に雲と帯が出ていて混みやすいため、色は1色に揃え、   |
//| 線の太さと種類だけで区別している。R は中心より上、S は下なので、  |
//| 同じ見た目でも位置で分かる。                                     |
//|                                                                  |
//| 入力項目は無い。前日の高値・安値・終値しか使わないため、決める    |
//| ことが何も無い。                                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   7

// 色は他のインジケーターと重ならないものを1色だけ使う。既に使われて
// いるのは 青・赤・マゼンタ・黄・オレンジ・黄緑・紫・青緑。
#property indicator_label1  "ピボット"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrTan
#property indicator_width1  2

#property indicator_label2  "R1（抵抗1）"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrTan
#property indicator_style2  STYLE_SOLID

#property indicator_label3  "R2（抵抗2）"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrTan
#property indicator_style3  STYLE_DASH

#property indicator_label4  "R3（抵抗3）"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrTan
#property indicator_style4  STYLE_DOT

#property indicator_label5  "S1（支持1）"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrTan
#property indicator_style5  STYLE_SOLID

#property indicator_label6  "S2（支持2）"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrTan
#property indicator_style6  STYLE_DASH

#property indicator_label7  "S3（支持3）"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrTan
#property indicator_style7  STYLE_DOT

#include <Signals\HigherTf.mqh>
#include <Signals\Pivot.mqh>

double BufP[], BufR1[], BufR2[], BufR3[], BufS1[], BufS2[], BufS3[];

// 前日から作った水準を日足1本につき1つ。添字は日足の shift（0 = 当日）。
double   g_p[], g_r1[], g_r2[], g_r3[], g_s1[], g_s2[], g_s3[];
datetime g_dayTime[];
int      g_dayBars = 0;   // 前回この本数で組み立てた

// 当日の水準を出すのに前日が要るので、最低2本。端の判定ぶんを足しておく。
const int NEED_BARS = 3;

//+------------------------------------------------------------------+
int OnInit()
{
   if(PeriodSeconds(_Period) >= PeriodSeconds(PERIOD_D1))
   {
      Print("日足より短い時間足のチャートに貼ってください");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufP,  INDICATOR_DATA);
   SetIndexBuffer(1, BufR1, INDICATOR_DATA);
   SetIndexBuffer(2, BufR2, INDICATOR_DATA);
   SetIndexBuffer(3, BufR3, INDICATOR_DATA);
   SetIndexBuffer(4, BufS1, INDICATOR_DATA);
   SetIndexBuffer(5, BufS2, INDICATOR_DATA);
   SetIndexBuffer(6, BufS3, INDICATOR_DATA);

   IndicatorSetString(INDICATOR_SHORTNAME, "デイリーピボット");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_dayBars = 0;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 日足1本につき1回だけ水準を求めて溜める                           |
//|                                                                  |
//| 添字 0（当日）は埋めない。当日の高値・安値・終値はまだ動いており、|
//| そこから作った水準を当日に描くと、その日が終わるまで分からない値を|
//| 先に見ることになる。前日ぶん（添字 1 以降）だけを埋める。        |
//+------------------------------------------------------------------+
bool BuildDays(const int wantBars)
{
   double high[], low[], close[];
   ArraySetAsSeries(high,      true);
   ArraySetAsSeries(low,       true);
   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(g_dayTime, true);

   const int copied = CopyHigh(_Symbol, PERIOD_D1, 0, wantBars, high);
   if(copied < NEED_BARS) return false;
   if(CopyLow(_Symbol,   PERIOD_D1, 0, copied, low)       != copied) return false;
   if(CopyClose(_Symbol, PERIOD_D1, 0, copied, close)     != copied) return false;
   if(CopyTime(_Symbol,  PERIOD_D1, 0, copied, g_dayTime) != copied) return false;

   ArrayResize(g_p,  copied);
   ArrayResize(g_r1, copied);
   ArrayResize(g_r2, copied);
   ArrayResize(g_r3, copied);
   ArrayResize(g_s1, copied);
   ArrayResize(g_s2, copied);
   ArrayResize(g_s3, copied);

   for(int s = 0; s < copied; s++)
   {
      PivotLevels v;
      if(s >= 1 && PV_Calc(high[s], low[s], close[s], v))
      {
         g_p[s]  = v.p;
         g_r1[s] = v.r1;
         g_r2[s] = v.r2;
         g_r3[s] = v.r3;
         g_s1[s] = v.s1;
         g_s2[s] = v.s2;
         g_s3[s] = v.s3;
      }
      else
      {
         g_p[s]  = EMPTY_VALUE;
         g_r1[s] = EMPTY_VALUE;
         g_r2[s] = EMPTY_VALUE;
         g_r3[s] = EMPTY_VALUE;
         g_s1[s] = EMPTY_VALUE;
         g_s2[s] = EMPTY_VALUE;
         g_s3[s] = EMPTY_VALUE;
      }
   }

   return true;
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 下位足の1本ずつについて、その足が属する日の1つ前（＝前日）から   |
//| 作った水準を写す。1日ぶん同じ値が続くので、線は日付の変わり目で   |
//| だけ段が変わる。                                                 |
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
   const int dayBars = Bars(_Symbol, PERIOD_D1);
   if(dayBars < NEED_BARS) return 0;   // 日足がまだ届いていない。次のティックで再挑戦

   // 週末で足が飛ぶぶんを見込んで余裕を足す。
   const int ratio    = (int)(PeriodSeconds(PERIOD_D1) / PeriodSeconds(_Period));
   const int wantBars = MathMin(dayBars, rates_total / ratio + NEED_BARS + 5);

   // 日が変わると全ての添字がずれる。組み直したら下位足も全部描き直す。
   bool rebuilt = false;
   if(dayBars != g_dayBars)
   {
      if(!BuildDays(wantBars)) return 0;
      g_dayBars = dayBars;
      rebuilt   = true;
   }

   ArraySetAsSeries(time,  true);
   ArraySetAsSeries(BufP,  true);
   ArraySetAsSeries(BufR1, true);
   ArraySetAsSeries(BufR2, true);
   ArraySetAsSeries(BufR3, true);
   ArraySetAsSeries(BufS1, true);
   ArraySetAsSeries(BufS2, true);
   ArraySetAsSeries(BufS3, true);

   int limit = rates_total - 1;
   if(prev_calculated > 0 && !rebuilt)
      limit = MathMin(rates_total - prev_calculated + 1, rates_total - 1);

   const int daySize = ArraySize(g_p);

   int cursor;
   if(!HTF_StartCursor(_Symbol, PERIOD_D1, time[limit], daySize, cursor)) return 0;

   for(int i = limit; i >= 0; i--)
   {
      const int s = HTF_ConfirmedShift(time[i], g_dayTime, cursor);

      if(s >= daySize)
      {
         BufP[i]  = EMPTY_VALUE;
         BufR1[i] = EMPTY_VALUE;
         BufR2[i] = EMPTY_VALUE;
         BufR3[i] = EMPTY_VALUE;
         BufS1[i] = EMPTY_VALUE;
         BufS2[i] = EMPTY_VALUE;
         BufS3[i] = EMPTY_VALUE;
         continue;
      }

      BufP[i]  = g_p[s];
      BufR1[i] = g_r1[s];
      BufR2[i] = g_r2[s];
      BufR3[i] = g_r3[s];
      BufS1[i] = g_s1[s];
      BufS2[i] = g_s2[s];
      BufS3[i] = g_s3[s];
   }

   return rates_total;
}
//+------------------------------------------------------------------+
