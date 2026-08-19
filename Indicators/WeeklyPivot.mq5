//+------------------------------------------------------------------+
//| WeeklyPivot.mq5                                                  |
//| ウィークリーピボットの描画（反転のサインを目で確かめる用）       |
//|                                                                  |
//| 計算は Include\Signals\Pivot.mqh、並べ方は                        |
//| Include\Signals\PivotDraw.mqh。本ファイルが持つのは色と本数だけ。 |
//| 日足ぶん（DailyPivot.mq5）と中身を共有している。                 |
//|                                                                  |
//| **今週の水準は先週の確定した週足から作る。** 週の変わり目で段が   |
//| 変わり、その週の中では動かない（docs/indicator_spec.md §5）。    |
//|                                                                  |
//| 色は明るい水色。日足ぶんは金色にしてあるので、同時に出しても      |
//| どちらの水準か一目で分かる。加えて**週足ぶんは線を太くしてある**。|
//| 週の水準のほうが長く効くので、色を見分けるまでもなく太さで区別    |
//| できるようにした。                                               |
//|                                                                  |
//| 入力項目は無い。先週の高値・安値・終値しか使わないため、決める    |
//| ことが何も無い。                                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   7

#property indicator_label1  "週ピボット"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrAqua
#property indicator_width1  3

#property indicator_label2  "週R1（抵抗1）"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrAqua
#property indicator_width2  2

#property indicator_label3  "週R2（抵抗2）"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrAqua
#property indicator_style3  STYLE_DASH

#property indicator_label4  "週R3（抵抗3）"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrAqua
#property indicator_style4  STYLE_DOT

#property indicator_label5  "週S1（支持1）"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrAqua
#property indicator_width5  2

#property indicator_label6  "週S2（支持2）"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrAqua
#property indicator_style6  STYLE_DASH

#property indicator_label7  "週S3（支持3）"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrAqua
#property indicator_style7  STYLE_DOT

#include <Signals\PivotDraw.mqh>

double BufP[], BufR1[], BufR2[], BufR3[], BufS1[], BufS2[], BufS3[];

//+------------------------------------------------------------------+
int OnInit()
{
   if(PeriodSeconds(_Period) >= PeriodSeconds(PERIOD_W1))
   {
      Print("週足より短い時間足のチャートに貼ってください");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufP,  INDICATOR_DATA);
   SetIndexBuffer(1, BufR1, INDICATOR_DATA);
   SetIndexBuffer(2, BufR2, INDICATOR_DATA);
   SetIndexBuffer(3, BufR3, INDICATOR_DATA);
   SetIndexBuffer(4, BufS1, INDICATOR_DATA);
   SetIndexBuffer(5, BufS2, INDICATOR_DATA);
   SetIndexBuffer(6, BufS3, INDICATOR_DATA);

   IndicatorSetString(INDICATOR_SHORTNAME, "ウィークリーピボット");
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_pvBars = 0;

   return INIT_SUCCEEDED;
}

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
   return PV_Update(PERIOD_W1, rates_total, prev_calculated, time,
                    BufP, BufR1, BufR2, BufR3, BufS1, BufS2, BufS3);
}
//+------------------------------------------------------------------+
