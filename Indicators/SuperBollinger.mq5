//+------------------------------------------------------------------+
//| SuperBollinger.mq5                                               |
//| スーパーボリンジャーの描画（N4-2 の目視確認用）                  |
//|                                                                  |
//| 計算は Include\Signals\SuperBollinger.mqh に置き、EA と共有する。|
//| 本ファイルは描画だけを担当し、計算式を持たない。売買判定の矢印は |
//| N5-1 で追加する。                                                |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §2.2。                         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   8

#property indicator_label1  "センターライン"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

#property indicator_label2  "+1σ"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLimeGreen

#property indicator_label3  "-1σ"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLimeGreen

#property indicator_label4  "+2σ"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrCrimson

#property indicator_label5  "-2σ"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrCrimson

#property indicator_label6  "+3σ"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrDeepSkyBlue

#property indicator_label7  "-3σ"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrDeepSkyBlue

#property indicator_label8  "遅行線"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrMagenta

#include <Signals\SuperBollinger.mqh>

input int InpPeriod  = 21;  // 期間（センターラインとσ）
input int InpLagBars = 21;  // 遅行線の本数

double BufCenter[], BufU1[], BufL1[], BufU2[], BufL2[], BufU3[], BufL3[], BufLag[];

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriod < 2)
   {
      Print("期間は 2 以上にしてください（σ の分母が 期間−1 のため）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLagBars < 1)
   {
      Print("遅行線の本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufCenter, INDICATOR_DATA);
   SetIndexBuffer(1, BufU1,     INDICATOR_DATA);
   SetIndexBuffer(2, BufL1,     INDICATOR_DATA);
   SetIndexBuffer(3, BufU2,     INDICATOR_DATA);
   SetIndexBuffer(4, BufL2,     INDICATOR_DATA);
   SetIndexBuffer(5, BufU3,     INDICATOR_DATA);
   SetIndexBuffer(6, BufL3,     INDICATOR_DATA);
   SetIndexBuffer(7, BufLag,    INDICATOR_DATA);

   for(int p = 0; p < 8; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("スーパーボリンジャー(%d, 遅行%d)", InpPeriod, InpLagBars));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 共通ファイル側が「添字 0 = 最新足」を前提にするため、終値と全    |
//| バッファを時系列順に切り替えてから渡す。                         |
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
   if(rates_total < InpPeriod)
      return 0;

   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(BufCenter, true);
   ArraySetAsSeries(BufU1,     true);
   ArraySetAsSeries(BufL1,     true);
   ArraySetAsSeries(BufU2,     true);
   ArraySetAsSeries(BufL2,     true);
   ArraySetAsSeries(BufU3,     true);
   ArraySetAsSeries(BufL3,     true);
   ArraySetAsSeries(BufLag,    true);

   // 最も古い側は計算に必要な本数が揃わないので、そこまでで止める
   int limit = rates_total - InpPeriod;
   if(prev_calculated > 0)
      limit = MathMin(limit, rates_total - prev_calculated + 1);
   if(limit < 0)
      return rates_total;

   for(int i = limit; i >= 0; i--)
   {
      SBValues v;
      if(SB_Calc(close, i, InpPeriod, v))
      {
         BufCenter[i] = v.center;
         BufU1[i]     = v.upper1;
         BufL1[i]     = v.lower1;
         BufU2[i]     = v.upper2;
         BufL2[i]     = v.lower2;
         BufU3[i]     = v.upper3;
         BufL3[i]     = v.lower3;
      }
      else
      {
         BufCenter[i] = EMPTY_VALUE;
         BufU1[i]     = EMPTY_VALUE;
         BufL1[i]     = EMPTY_VALUE;
         BufU2[i]     = EMPTY_VALUE;
         BufL2[i]     = EMPTY_VALUE;
         BufU3[i]     = EMPTY_VALUE;
         BufL3[i]     = EMPTY_VALUE;
      }

      // 最新から InpLagBars 本ぶんは値が無い。ここで線が切れるのが正しい
      double lag;
      BufLag[i] = SB_LagValue(close, i, InpLagBars, lag) ? lag : EMPTY_VALUE;
   }

   return rates_total;
}
