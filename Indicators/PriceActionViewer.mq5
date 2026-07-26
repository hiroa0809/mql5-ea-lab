//+------------------------------------------------------------------+
//| PriceActionViewer.mq5                                            |
//| プライスアクション検出結果をチャート上に矢印表示する             |
//|                                                                  |
//| 目的は目視での認識合わせ。「ピンバー」等の定義が利用者の認識と   |
//| 一致しているかを確認するためのもので、売買は行わない。           |
//|                                                                  |
//| 買いシグナル: 安値の下に上向き矢印                               |
//| 売りシグナル: 高値の上に下向き矢印                               |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property strict

#property indicator_chart_window
#property indicator_buffers 2
#property indicator_plots   2

//--- 買いシグナル
#property indicator_label1  "PA Long"
#property indicator_type1   DRAW_ARROW
#property indicator_color1  clrDodgerBlue
#property indicator_width1  3

//--- 売りシグナル
#property indicator_label2  "PA Short"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrOrangeRed
#property indicator_width2  3

#include <Signals\PriceAction.mqh>

//--- 検出パターン
input ENUM_PA_PATTERN InpPattern           = PA_PINBAR; // パターン

//--- ピンバー
input double InpPinWickRatio               = 0.66;  // ピンバー: 長ヒゲ/レンジ の下限
input double InpPinOppositeRatio           = 0.15;  // ピンバー: 反対ヒゲ/レンジ の上限

//--- 包み足 / はらみ足
input bool   InpRequireColorFlip           = true;  // 包み/はらみ: 色の反転を必須

//--- 共通
input double InpMinRangeATR                = 0.50;  // 共通: レンジの下限(ATR比)
input bool   InpRequireDayExtreme          = true;  // 共通: 当日高安の更新を必須
input int    InpATRPeriod                  = 14;    // ATR 期間

//--- 矢印を高安からどれだけ離すか(ATR比)
input double InpArrowOffsetATR             = 0.30;  // 矢印のオフセット(ATR比)

double g_long_buf[];
double g_short_buf[];

CPriceAction *g_pa = NULL;
int           g_atr_handle = INVALID_HANDLE;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   SetIndexBuffer(0, g_long_buf,  INDICATOR_DATA);
   SetIndexBuffer(1, g_short_buf, INDICATOR_DATA);

   PlotIndexSetInteger(0, PLOT_ARROW, 233); // 上向き矢印
   PlotIndexSetInteger(1, PLOT_ARROW, 234); // 下向き矢印

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   ArraySetAsSeries(g_long_buf,  true);
   ArraySetAsSeries(g_short_buf, true);

   //--- 検出器
   g_pa = new CPriceAction(InpATRPeriod);
   if(g_pa == NULL)
      return(INIT_FAILED);

   if(!g_pa.Init(_Symbol, (ENUM_TIMEFRAMES)_Period))
      return(INIT_FAILED);

   SPriceActionParams params;
   params.pin_wick_ratio      = InpPinWickRatio;
   params.pin_opposite_ratio  = InpPinOppositeRatio;
   params.require_color_flip  = InpRequireColorFlip;
   params.min_range_atr       = InpMinRangeATR;
   params.require_day_extreme = InpRequireDayExtreme;
   g_pa.SetParams(params);

   //--- 矢印のオフセット用
   g_atr_handle = iATR(_Symbol, (ENUM_TIMEFRAMES)_Period, InpATRPeriod);
   if(g_atr_handle == INVALID_HANDLE)
      return(INIT_FAILED);

   IndicatorSetString(INDICATOR_SHORTNAME, "PriceActionViewer");
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_pa != NULL)
     {
      delete g_pa;
      g_pa = NULL;
     }
   if(g_atr_handle != INVALID_HANDLE)
      IndicatorRelease(g_atr_handle);
  }

//+------------------------------------------------------------------+
//| 計算                                                             |
//|                                                                  |
//| 確定足のみ評価する。未確定足(shift=0)は描画しない。              |
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
   //--- ATR 期間 + 2本足分の余裕
   int min_bars = InpATRPeriod + 3;
   if(rates_total < min_bars)
      return(0);

   double atr_buf[];
   ArraySetAsSeries(atr_buf, true);

   //--- 評価可能な最も古い shift。これより古い足は ATR / 前足が揃わない
   int max_shift = rates_total - min_bars;

   //--- 再計算範囲。未確定足は評価しないので shift=1 から
   int limit;
   if(prev_calculated == 0)
      limit = max_shift;
   else
     {
      //--- 新規に確定した本数 + 直近の確定足の塗り直し
      limit = rates_total - prev_calculated + 1;
      if(limit > max_shift)
         limit = max_shift;
     }

   for(int shift = 1; shift <= limit; shift++)
     {
      g_long_buf[shift]  = EMPTY_VALUE;
      g_short_buf[shift] = EMPTY_VALUE;

      ENUM_SIGNAL_DIR dir = g_pa.Detect(InpPattern, shift);
      if(dir == SIGNAL_NONE)
         continue;

      double atr = 0.0;
      if(CopyBuffer(g_atr_handle, 0, shift, 1, atr_buf) > 0)
         atr = atr_buf[0];

      double offset = atr * InpArrowOffsetATR;

      if(dir == SIGNAL_LONG)
         g_long_buf[shift]  = iLow(_Symbol, (ENUM_TIMEFRAMES)_Period, shift)  - offset;
      else
         if(dir == SIGNAL_SHORT)
            g_short_buf[shift] = iHigh(_Symbol, (ENUM_TIMEFRAMES)_Period, shift) + offset;
     }

   //--- 未確定足はクリア
   g_long_buf[0]  = EMPTY_VALUE;
   g_short_buf[0] = EMPTY_VALUE;

   return(rates_total);
  }
//+------------------------------------------------------------------+
