//+------------------------------------------------------------------+
//| SuperBollinger.mq5                                               |
//| スーパーボリンジャーの描画とルール1のサイン表示（目視確認用）    |
//|                                                                  |
//| 計算も判定も Include\Signals\SuperBollinger.mqh に置き、EA と    |
//| 共有する。本ファイルは描画だけを担当し、式も条件も持たない。     |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §2.2、                         |
//| 売買条件は docs/trading_rules.md §4.1。                          |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 10
#property indicator_plots   10

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

#property indicator_label9  "買いサイン"
#property indicator_type9   DRAW_ARROW
#property indicator_color9  clrYellow
#property indicator_width9  2

#property indicator_label10 "売りサイン"
#property indicator_type10  DRAW_ARROW
#property indicator_color10 clrOrangeRed
#property indicator_width10 2

#include <Signals\SuperBollinger.mqh>

input int    InpPeriod      = 21;    // 期間（センターラインとσ）
input int    InpLagBars     = 21;    // 遅行線の本数
input bool   InpUseSqueeze  = true;  // ①膠着を条件に入れる
input int    InpSqueezeBars = 21;    // ①膠着とみなす本数（この本数ぶん帯の内側）
input double InpSigmaMult   = 3.0;   // ①③で使うσの倍数
input bool   InpUseLag      = true;  // ②遅行線の陽転/陰転を条件に入れる
input bool   InpUseExpand   = true;  // ④バンド幅の拡大を条件に入れる
input int    InpExpandBars  = 3;     // ④拡大を見る本数

double BufCenter[], BufU1[], BufL1[], BufU2[], BufL2[], BufU3[], BufL3[], BufLag[];
double BufBuy[], BufSell[];

SBRule1Params g_rule1;

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
   if(InpSqueezeBars < 1)
   {
      Print("①膠着とみなす本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpExpandBars < 1)
   {
      Print("④拡大を見る本数は 1 以上にしてください（0 では常に不成立になる）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSigmaMult <= 0.0)
   {
      Print("①③で使うσの倍数は 0 より大きくしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_rule1.period      = InpPeriod;
   g_rule1.lagBars     = InpLagBars;
   g_rule1.useSqueeze  = InpUseSqueeze;
   g_rule1.squeezeBars = InpSqueezeBars;
   g_rule1.sigmaMult   = InpSigmaMult;
   g_rule1.useLag      = InpUseLag;
   g_rule1.useExpand   = InpUseExpand;
   g_rule1.expandBars  = InpExpandBars;

   SetIndexBuffer(0, BufCenter, INDICATOR_DATA);
   SetIndexBuffer(1, BufU1,     INDICATOR_DATA);
   SetIndexBuffer(2, BufL1,     INDICATOR_DATA);
   SetIndexBuffer(3, BufU2,     INDICATOR_DATA);
   SetIndexBuffer(4, BufL2,     INDICATOR_DATA);
   SetIndexBuffer(5, BufU3,     INDICATOR_DATA);
   SetIndexBuffer(6, BufL3,     INDICATOR_DATA);
   SetIndexBuffer(7, BufLag,    INDICATOR_DATA);
   SetIndexBuffer(8, BufBuy,    INDICATOR_DATA);
   SetIndexBuffer(9, BufSell,   INDICATOR_DATA);

   for(int p = 0; p < 10; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // 矢印は足の外側へ逃がす。安値・高値そのものに描くとローソク足に
   // 重なって発火位置が読めない（負のシフトが上、正が下・単位はピクセル）
   PlotIndexSetInteger(8, PLOT_ARROW, 233);   // ↑
   PlotIndexSetInteger(8, PLOT_ARROW_SHIFT, 12);
   PlotIndexSetInteger(9, PLOT_ARROW, 234);   // ↓
   PlotIndexSetInteger(9, PLOT_ARROW_SHIFT, -12);

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
   ArraySetAsSeries(high,      true);
   ArraySetAsSeries(low,       true);
   ArraySetAsSeries(BufCenter, true);
   ArraySetAsSeries(BufU1,     true);
   ArraySetAsSeries(BufL1,     true);
   ArraySetAsSeries(BufU2,     true);
   ArraySetAsSeries(BufL2,     true);
   ArraySetAsSeries(BufU3,     true);
   ArraySetAsSeries(BufL3,     true);
   ArraySetAsSeries(BufLag,    true);
   ArraySetAsSeries(BufBuy,    true);
   ArraySetAsSeries(BufSell,   true);

   // 初回は全ての足を走査する。計算に必要な本数が揃わない最も古い側にも
   // 「描かない印」を入れる必要があり、飛ばすと MT5 側の初期値のまま線が
   // 引かれてしまう（チャート左端で 0 へ落ちる）。
   int limit = rates_total - 1;

   if(prev_calculated > 0)
   {
      // 遅行線の先端は最新から InpLagBars 本手前にある。足が1本増えるたび
      // その位置は新しい足へ移るので、更新するのが直近数本だけだと先端が
      // 二度と計算されず、遅行線だけ伸びなくなる。必ず先端まで含める。
      limit = MathMax(rates_total - prev_calculated + 1, InpLagBars);
      limit = MathMin(limit, rates_total - 1);
   }

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

      // 売買サイン。形成中の足（添字 0）には出さない。判定は確定足のみ
      // という決まりのため（docs/trading_rules.md §2.1）で、ここに出すと
      // 足の途中で現れたり消えたりする矢印を EA の発火と見比べてしまう。
      BufBuy[i]  = EMPTY_VALUE;
      BufSell[i] = EMPTY_VALUE;
      if(i >= 1)
      {
         SBRule1Signal s;
         if(SB_Rule1(close, high, low, i, g_rule1, s))
         {
            if(s.buy)  BufBuy[i]  = low[i];
            if(s.sell) BufSell[i] = high[i];
         }
      }
   }

   return rates_total;
}
