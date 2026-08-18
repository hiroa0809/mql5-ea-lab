//+------------------------------------------------------------------+
//| SuperBollingerMTF.mq5                                            |
//| 上位足のスーパーボリンジャーを下位足のチャートへ重ねる           |
//|                                                                  |
//| 計算は Include\Signals\SuperBollinger.mqh をそのまま使う。本      |
//| ファイルは「上位足の値を下位足のどこへ置くか」だけを受け持ち、    |
//| 式は持たない。                                                   |
//|                                                                  |
//| **描くのは確定した上位足の値だけ**（2026-08-18 ユーザー決定）。   |
//| 1時間足を5分足へ重ねるなら、1時間足が1本閉じるたびに、その確定    |
//| した値を次の5分足12本へ横に並べる。形成中の足の終値からは何も     |
//| 作らない。こうしておくと画面のどの時点を見ても、その時点で実際に  |
//| 知り得た値しか映らない。売買プログラムが上位足を確定足で読むのと  |
//| 同じ値になる。                                                   |
//|                                                                  |
//| 表示するσは ±1 と ±2 のみ（docs/trading_rules.md §1.7）。       |
//| 遅行線は「1画面に収まるか」を確かめるために出している。上位足     |
//| 21本ぶん過去で途切れるので、5分足＋1時間足なら現在の足から約252   |
//| 本前が右端になる。OnInit で実数を Print する。                    |
//|                                                                  |
//| 用途は N5-7（上位足で大局をどう判定するか）を目で決めること。     |
//| 計算定義は docs/indicator_spec.md §2.2。                         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 8
#property indicator_plots   8

// 色はスパンモデル側（青・赤・マゼンタ・黄・オレンジレッド）と重ならない
// ものを選ぶ。重ねて表示するのが前提なので、同系色だとどちらの線か読めない。
#property indicator_label1  "センターライン"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrOrange
#property indicator_width1  2

#property indicator_label2  "+1σ"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLimeGreen
#property indicator_width2  2

#property indicator_label3  "-1σ"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLimeGreen
#property indicator_width3  2

#property indicator_label4  "+2σ"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMediumPurple
#property indicator_width4  2

#property indicator_label5  "-2σ"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrMediumPurple
#property indicator_width5  2

#property indicator_label6  "遅行線"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrDarkTurquoise
#property indicator_width6  2

// 線は引かない。データウィンドウで足ごとに数値を読むための枠。
#property indicator_label7  "拡大 (1=成立)"
#property indicator_type7   DRAW_NONE
#property indicator_label8  "σ"
#property indicator_type8   DRAW_NONE

#include <Signals\HigherTf.mqh>
#include <Signals\SuperBollinger.mqh>

input ENUM_HIGHER_TF InpHigherTF   = HTF_H1;   // 重ねる上位足
input int            InpPeriod     = 21;       // 期間（センターラインとσ）
input int            InpLagBars    = 21;       // 遅行線の本数
input int            InpExpandBars = 8;        // 拡大を見る本数

double BufCenter[], BufU1[], BufL1[], BufU2[], BufL2[], BufLag[];
double BufExpand[], BufSigma[];

ENUM_TIMEFRAMES g_tf       = PERIOD_H1;
int             g_needBars = 0;

// 上位足1本につき1回だけ計算した結果。添字は上位足の shift（0 = 形成中）。
// 下位足の足ごとに計算し直すと、5分足12本ぶん同じ計算を繰り返すことになる。
double   g_center[], g_u1[], g_l1[], g_u2[], g_l2[], g_lag[], g_expand[], g_sigma[];
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
   if(InpLagBars < 1 || InpExpandBars < 1)
   {
      Print("遅行線の本数・拡大を見る本数は、いずれも 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_tf = (ENUM_TIMEFRAMES)InpHigherTF;

   if(PeriodSeconds(_Period) >= PeriodSeconds(g_tf))
   {
      PrintFormat("このチャートの時間足では使えません。%s より短い時間足のチャートに貼ってください",
                  HigherTfLabel(g_tf));
      return INIT_PARAMETERS_INCORRECT;
   }

   SetIndexBuffer(0, BufCenter, INDICATOR_DATA);
   SetIndexBuffer(1, BufU1,     INDICATOR_DATA);
   SetIndexBuffer(2, BufL1,     INDICATOR_DATA);
   SetIndexBuffer(3, BufU2,     INDICATOR_DATA);
   SetIndexBuffer(4, BufL2,     INDICATOR_DATA);
   SetIndexBuffer(5, BufLag,    INDICATOR_DATA);
   SetIndexBuffer(6, BufExpand, INDICATOR_DATA);
   SetIndexBuffer(7, BufSigma,  INDICATOR_DATA);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("上位足SB %s (%d,%d,%d)",
                                   HigherTfLabel(g_tf), InpPeriod, InpLagBars, InpExpandBars));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   // 遅行線は上位足の21本ぶん過去で途切れる。それが今の時間足で何本前に
   // なるかは貼ってみないと分からないので、ここで実数を出しておく。
   const int ratio = (int)(PeriodSeconds(g_tf) / PeriodSeconds(_Period));
   PrintFormat("%s 1本 ＝ このチャート %d 本ぶん。同じ値を %d 本横に並べます",
               HigherTfLabel(g_tf), ratio, ratio);
   PrintFormat("遅行線の右端は、現在の足から約 %d 本前になります（1画面に出ている本数と見比べてください）",
               InpLagBars * ratio);

   g_needBars = SB_RequiredBars(InpPeriod, InpLagBars, InpExpandBars);
   g_htfBars  = 0;

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 上位足の値を1本につき1回だけ計算して溜める                       |
//|                                                                  |
//| 添字 0（形成中の足）は埋めない。そこから作った値を下位足に描くと、|
//| その1時間が終わるまで分からないはずの終値を先に見ることになる。   |
//+------------------------------------------------------------------+
bool BuildHigherTf(const int wantBars)
{
   double close[];
   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(g_htfTime, true);

   const int copied = CopyClose(_Symbol, g_tf, 0, wantBars, close);
   if(copied < g_needBars) return false;
   if(CopyTime(_Symbol, g_tf, 0, copied, g_htfTime) != copied) return false;

   ArrayResize(g_center, copied);
   ArrayResize(g_u1,     copied);
   ArrayResize(g_l1,     copied);
   ArrayResize(g_u2,     copied);
   ArrayResize(g_l2,     copied);
   ArrayResize(g_lag,    copied);
   ArrayResize(g_expand, copied);
   ArrayResize(g_sigma,  copied);

   for(int s = 0; s < copied; s++)
   {
      SBValues v;
      if(s >= 1 && SB_Calc(close, s, InpPeriod, v))
      {
         g_center[s] = v.center;
         g_u1[s]     = v.upper1;
         g_l1[s]     = v.lower1;
         g_u2[s]     = v.upper2;
         g_l2[s]     = v.lower2;
         g_sigma[s]  = v.sigma;
      }
      else
      {
         g_center[s] = EMPTY_VALUE;
         g_u1[s]     = EMPTY_VALUE;
         g_l1[s]     = EMPTY_VALUE;
         g_u2[s]     = EMPTY_VALUE;
         g_l2[s]     = EMPTY_VALUE;
         g_sigma[s]  = EMPTY_VALUE;
      }

      // 遅行線が拾う終値は s − 本数 の位置にある（新しい足ほど添字が小さい）。
      // そこが 0 だと形成中の足の終値になるため、1 以上に限る。結果として
      // 線の右端は「本数＋1」本ぶん過去に来る。
      double lag;
      const int src = s - InpLagBars;
      g_lag[s] = (src >= 1 && SB_LagValue(close, s, InpLagBars, lag)) ? lag : EMPTY_VALUE;

      bool expanding;
      g_expand[s] = (s >= 1 && SB_Expanding(close, s, InpPeriod, InpExpandBars, expanding))
                    ? (expanding ? 1.0 : 0.0)
                    : EMPTY_VALUE;
   }

   return true;
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 下位足の1本ずつについて、その足が属する上位足の1本前（＝すでに   |
//| 確定している足）の値を写す。写す先が同じ値のまま続くので、線は   |
//| 上位足1本ぶんの本数だけ水平に伸びて階段状になる。                |
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

   // このチャートを端まで覆うのに要る上位足の本数。全部を読むと日足で数千本
   // になり、使わない範囲まで計算することになる。
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

   ArraySetAsSeries(time,      true);
   ArraySetAsSeries(BufCenter, true);
   ArraySetAsSeries(BufU1,     true);
   ArraySetAsSeries(BufL1,     true);
   ArraySetAsSeries(BufU2,     true);
   ArraySetAsSeries(BufL2,     true);
   ArraySetAsSeries(BufLag,    true);
   ArraySetAsSeries(BufExpand, true);
   ArraySetAsSeries(BufSigma,  true);

   int limit = rates_total - 1;
   if(prev_calculated > 0 && !rebuilt)
      limit = MathMin(rates_total - prev_calculated + 1, rates_total - 1);

   const int htfSize = ArraySize(g_center);

   int cursor;
   if(!HTF_StartCursor(_Symbol, g_tf, time[limit], htfSize, cursor)) return 0;

   for(int i = limit; i >= 0; i--)
   {
      const int s = HTF_ConfirmedShift(time[i], g_htfTime, cursor);

      if(s >= htfSize)
      {
         BufCenter[i] = EMPTY_VALUE;
         BufU1[i]     = EMPTY_VALUE;
         BufL1[i]     = EMPTY_VALUE;
         BufU2[i]     = EMPTY_VALUE;
         BufL2[i]     = EMPTY_VALUE;
         BufLag[i]    = EMPTY_VALUE;
         BufExpand[i] = EMPTY_VALUE;
         BufSigma[i]  = EMPTY_VALUE;
         continue;
      }

      BufCenter[i] = g_center[s];
      BufU1[i]     = g_u1[s];
      BufL1[i]     = g_l1[s];
      BufU2[i]     = g_u2[s];
      BufL2[i]     = g_l2[s];
      BufLag[i]    = g_lag[s];
      BufExpand[i] = g_expand[s];
      BufSigma[i]  = g_sigma[s];
   }

   return rates_total;
}
//+------------------------------------------------------------------+
