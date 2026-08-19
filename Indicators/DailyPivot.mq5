//+------------------------------------------------------------------+
//| DailyPivot.mq5                                                   |
//| デイリーピボットの描画（反転のサインを目で確かめる用）           |
//|                                                                  |
//| 計算は Include\Signals\Pivot.mqh、並べ方は                        |
//| Include\Signals\PivotDraw.mqh。本ファイルが持つのは色と本数だけ。 |
//| 週足ぶん（WeeklyPivot.mq5）と中身を共有しているので、規則を直す   |
//| ときは共有ファイルを1箇所直せば両方に効く。                       |
//|                                                                  |
//| **当日の水準は前日の確定した日足から作る。** 日付の変わり目で段が |
//| 変わり、その日の中では動かない（docs/indicator_spec.md §5）。    |
//|                                                                  |
//| 色は明るい金色。週足ぶんは水色にしてあるので、同時に出しても      |
//| どちらの水準か一目で分かる。いらない線は「カラー」タブで個別に    |
//| 消せる（R3 / S3 は届くことが少ない）。                            |
//|                                                                  |
//| 入力項目は無い。前日の高値・安値・終値しか使わないため、決める    |
//| ことが何も無い。                                                 |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 7
#property indicator_plots   7

#property indicator_label1  "日ピボット"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrGold
#property indicator_width1  2

#property indicator_label2  "日R1（抵抗1）"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrGold
#property indicator_style2  STYLE_SOLID

#property indicator_label3  "日R2（抵抗2）"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrGold
#property indicator_style3  STYLE_DASH

#property indicator_label4  "日R3（抵抗3）"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrGold
#property indicator_style4  STYLE_DOT

#property indicator_label5  "日S1（支持1）"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrGold
#property indicator_style5  STYLE_SOLID

#property indicator_label6  "日S2（支持2）"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrGold
#property indicator_style6  STYLE_DASH

#property indicator_label7  "日S3（支持3）"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrGold
#property indicator_style7  STYLE_DOT

#include <Signals\PivotDraw.mqh>

double BufP[], BufR1[], BufR2[], BufR3[], BufS1[], BufS2[], BufS3[];

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
   return PV_Update(PERIOD_D1, rates_total, prev_calculated, time,
                    BufP, BufR1, BufR2, BufR3, BufS1, BufS2, BufS3);
}
//+------------------------------------------------------------------+
