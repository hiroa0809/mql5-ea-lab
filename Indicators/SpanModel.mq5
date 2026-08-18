//+------------------------------------------------------------------+
//| SpanModel.mq5                                                    |
//| スパンモデルの描画とルール2のサイン表示（目視確認用）            |
//|                                                                  |
//| 計算も判定も Include\Signals\SpanModel.mqh に置き、EA と共有する。|
//| 本ファイルは描画だけを担当し、式も条件も持たない。               |
//|                                                                  |
//| 印は**判定した足**に出す。実際の約定は次の足の始値なので、印は   |
//| 約定より1本手前に立つ。条件の数値（データウィンドウの①②③④）  |
//| と同じ足に並べたほうが目視確認しやすいため、こちらを採っている。 |
//|                                                                  |
//| **手仕舞いの印は出さない。** ルール2の決済は EA を作るときに      |
//| 実装する（docs/trading_rules.md §5.3）。ここに出ているのは        |
//| エントリー条件だけ。                                             |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §1.2、                         |
//| 売買条件は docs/trading_rules.md §5.2。                          |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 13
#property indicator_plots   12

// 雲。青スパンが上なら雲色1（青＝サポートゾーン）、
// 赤スパンが上なら雲色2（赤＝レジスタンスゾーン）に塗り分けられる。
#property indicator_label1  "雲"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  clrDodgerBlue,clrCrimson

// 線は太くする。雲の塗りつぶしと同系色なので、細いと帯の中に埋もれて
// どこが青スパンでどこが赤スパンか読めない（2026-08-16 に実際そうなった）。
#property indicator_label2  "青スパン"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_width2  5

#property indicator_label3  "赤スパン"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrCrimson
#property indicator_width3  5

#property indicator_label4  "遅行線"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta
#property indicator_width4  3

// 印に白は使わない。ローソク足の実体が白く塗られる配色だと同化して見えない
// （2026-08-09 にルール1で実際そうなった）。雲が青と赤で塗られているので、
// サインはそれと重ならない色にする。
#property indicator_label5  "買いサイン"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrYellow
#property indicator_width5  5

#property indicator_label6  "売りサイン"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrOrangeRed
#property indicator_width6  5

// 以下は線を引かない。データウィンドウで足ごとに条件の成否を読むためだけの
// 枠。矢印が出ない足でも、どの条件で止まったのかをその場で切り分けられる。
// ②③④は入力で外していても中身は埋まる（外した条件が実際にはどうだった
// かを見るため）。矢印に反映されるのは「条件に入れる」と指定したものだけ。
#property indicator_label7  "①雲の転換 (1=青へ -1=赤へ)"
#property indicator_type7   DRAW_NONE
// ②の3行の見出しは OnInit で本数を埋めて上書きする。ここに書く本数は
// 既定値でしかなく、遅行線の本数を変えた瞬間に嘘になる。
#property indicator_label8  "②a 遅行スパンと重なる足の終値"
#property indicator_type8   DRAW_NONE
#property indicator_label9  "②b 遅行スパンと重なる足の高値安値"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "②c 遅行スパンと重なる足の雲"
#property indicator_type10  DRAW_NONE
#property indicator_label11 "③終値と青スパン (1=上 -1=下)"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "④赤スパンの傾き (1=上 -1=下 0=平ら・平らも通す)"
#property indicator_type12  DRAW_NONE

#include <Signals\SpanModel.mqh>

input int  InpTenkan       = 9;      // 転換線の期間
input int  InpKijun        = 26;     // 基準線の期間
input int  InpSpanB        = 52;     // 赤スパンの期間
input int  InpLagBars      = 26;     // 遅行線の本数
// 設定項目の表示名は起動時に書き換えられないため、本数を書かない。
// 「重なる足」＝遅行スパンの右端が乗っている足（遅行線の本数ぶん前）。
input bool InpUseLagClose  = false;  // ②a 遅行スパンが重なる足の終値を抜けている
input bool InpUseLagHighLow= true;   // ②b 遅行スパンが重なる足の高値安値を抜けている
input bool InpUseLagCloud  = false;  // ②c 遅行スパンが重なる足の雲を抜けている
input bool InpUseClosePos  = true;   // ③終値と青スパンの位置関係を条件に入れる
input bool InpUseSlope     = true;   // ④長期スパンの傾きを条件に入れる
input int  InpSlopeBars    = 5;      // ④傾きを見る本数

// 雲は DRAW_FILLING が2本のバッファを要求するため、線として描く
// 青スパン・赤スパンとは別に持つ（同じ値を入れる）。
double BufCloudA[], BufCloudB[], BufSpanA[], BufSpanB[], BufLag[];
double BufBuy[], BufSell[];
double BufC1[], BufC2a[], BufC2b[], BufC2c[], BufC3[], BufC4[];

SMRule2Params g_rule2;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpTenkan < 1 || InpKijun < 1 || InpSpanB < 1)
   {
      Print("転換線・基準線・赤スパンの期間は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLagBars < 1)
   {
      Print("遅行線の本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSlopeBars < 1)
   {
      Print("④傾きを見る本数は 1 以上にしてください（0 では常に平らになる）");
      return INIT_PARAMETERS_INCORRECT;
   }

   // ②は3つとも切りにすると「②を使わない」になる。設定画面を見返さ
   // なくても気づけるよう、起動のたびにログへ出す。
   if(!InpUseLagClose && !InpUseLagHighLow && !InpUseLagCloud)
      Print("②遅行スパンは3つとも切りのため、条件に入れません（①③④だけで判定します）");

   g_rule2.tenkanPeriod  = InpTenkan;
   g_rule2.kijunPeriod   = InpKijun;
   g_rule2.spanBPeriod   = InpSpanB;
   g_rule2.lagBars       = InpLagBars;
   g_rule2.useLagClose   = InpUseLagClose;
   g_rule2.useLagHighLow = InpUseLagHighLow;
   g_rule2.useLagCloud   = InpUseLagCloud;
   g_rule2.useClosePos   = InpUseClosePos;
   g_rule2.useSlope      = InpUseSlope;
   g_rule2.slopeBars     = InpSlopeBars;

   SetIndexBuffer(0,  BufCloudA, INDICATOR_DATA);
   SetIndexBuffer(1,  BufCloudB, INDICATOR_DATA);
   SetIndexBuffer(2,  BufSpanA,  INDICATOR_DATA);
   SetIndexBuffer(3,  BufSpanB,  INDICATOR_DATA);
   SetIndexBuffer(4,  BufLag,    INDICATOR_DATA);
   SetIndexBuffer(5,  BufBuy,    INDICATOR_DATA);
   SetIndexBuffer(6,  BufSell,   INDICATOR_DATA);
   SetIndexBuffer(7,  BufC1,     INDICATOR_DATA);
   SetIndexBuffer(8,  BufC2a,    INDICATOR_DATA);
   SetIndexBuffer(9,  BufC2b,    INDICATOR_DATA);
   SetIndexBuffer(10, BufC2c,    INDICATOR_DATA);
   SetIndexBuffer(11, BufC3,     INDICATOR_DATA);
   SetIndexBuffer(12, BufC4,     INDICATOR_DATA);

   for(int p = 0; p < 12; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // ②の見出しに実際の本数を埋める。#property の文言は固定なので、遅行線の
   // 本数を既定から変えると表示だけ嘘になる（設定の食い違いを色の問題と
   // 誤診した前例がある・docs/lessons_learned.md）。
   PlotIndexSetString(7, PLOT_LABEL,
      StringFormat("②a 遅行スパンと%d本前の終値 (1=上 -1=下)", InpLagBars));
   PlotIndexSetString(8, PLOT_LABEL,
      StringFormat("②b 遅行スパンと%d本前の高値安値 (1=上抜け -1=下抜け)", InpLagBars));
   PlotIndexSetString(9, PLOT_LABEL,
      StringFormat("②c 遅行スパンと%d本前の雲 (1=上抜け -1=下抜け 0=雲の中)", InpLagBars));

   // 印は足の外側へ逃がす。安値・高値そのものに描くとローソク足に重なって
   // 位置が読めない（負のシフトが上、正が下・単位はピクセル）。
   // 買いは足の下、売りは足の上でルール1と揃える。
   PlotIndexSetInteger(4, PLOT_ARROW, 233);        // ↑ 買い
   PlotIndexSetInteger(4, PLOT_ARROW_SHIFT,  16);
   PlotIndexSetInteger(5, PLOT_ARROW, 234);        // ↓ 売り
   PlotIndexSetInteger(5, PLOT_ARROW_SHIFT, -16);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("スパンモデル(%d, %d, %d, 遅行%d)",
                                   InpTenkan, InpKijun, InpSpanB, InpLagBars));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 共通ファイル側が「添字 0 = 最新足」を前提にするため、価格配列と  |
//| 全バッファを時系列順に切り替えてから渡す。                       |
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
   const int longest = MathMax(InpTenkan, MathMax(InpKijun, InpSpanB));
   if(rates_total < longest)
      return 0;

   ArraySetAsSeries(high,      true);
   ArraySetAsSeries(low,       true);
   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(BufCloudA, true);
   ArraySetAsSeries(BufCloudB, true);
   ArraySetAsSeries(BufSpanA,  true);
   ArraySetAsSeries(BufSpanB,  true);
   ArraySetAsSeries(BufLag,    true);
   ArraySetAsSeries(BufBuy,    true);
   ArraySetAsSeries(BufSell,   true);
   ArraySetAsSeries(BufC1,     true);
   ArraySetAsSeries(BufC2a,    true);
   ArraySetAsSeries(BufC2b,    true);
   ArraySetAsSeries(BufC2c,    true);
   ArraySetAsSeries(BufC3,     true);
   ArraySetAsSeries(BufC4,     true);

   // 初回は全ての足を走査する。計算に必要な本数が揃わない最も古い側にも
   // 「描かない印」を入れる必要があり、飛ばすと MT5 側の初期値のまま線が
   // 引かれてしまう。
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
      SMValues v;
      if(SM_Calc(high, low, i, InpTenkan, InpKijun, InpSpanB, v))
      {
         BufCloudA[i] = v.spanA;
         BufCloudB[i] = v.spanB;
         BufSpanA[i]  = v.spanA;
         BufSpanB[i]  = v.spanB;
      }
      else
      {
         BufCloudA[i] = EMPTY_VALUE;
         BufCloudB[i] = EMPTY_VALUE;
         BufSpanA[i]  = EMPTY_VALUE;
         BufSpanB[i]  = EMPTY_VALUE;
      }

      // 最新から InpLagBars 本ぶんは値が無い。ここで線が切れるのが正しい
      double lag;
      BufLag[i] = SM_LagValue(close, i, InpLagBars, lag) ? lag : EMPTY_VALUE;

      // 売買サインと条件の内訳。形成中の足（添字 0）には出さない。判定は
      // 確定足のみという決まりのため（docs/trading_rules.md §2.1）で、ここ
      // に出すと足の途中で現れたり消えたりする値を EA の発火と見比べてしまう。
      BufBuy[i]  = EMPTY_VALUE;
      BufSell[i] = EMPTY_VALUE;
      BufC1[i]   = EMPTY_VALUE;
      BufC2a[i]  = EMPTY_VALUE;
      BufC2b[i]  = EMPTY_VALUE;
      BufC2c[i]  = EMPTY_VALUE;
      BufC3[i]   = EMPTY_VALUE;
      BufC4[i]   = EMPTY_VALUE;

      SMRule2Signal s;
      if(i >= 1 && SM_Rule2(high, low, close, i, g_rule2, s))
      {
         BufC1[i]  = s.flipBlue ? 1.0 : (s.flipRed ? -1.0 : 0.0);
         BufC2a[i] = s.lag.closeAbove ? 1.0 : (s.lag.closeBelow ? -1.0 : 0.0);
         BufC2b[i] = s.lag.highAbove  ? 1.0 : (s.lag.lowBelow   ? -1.0 : 0.0);
         BufC2c[i] = s.lag.cloudAbove ? 1.0 : (s.lag.cloudBelow ? -1.0 : 0.0);
         BufC3[i] = s.closeAbove ? 1.0 : (s.closeBelow ? -1.0 : 0.0);
         // 平らな足は上向きと下向きが同時に立つ（どちらの向きにも通す）。
         // 表示はどちらでもない 0（＝平ら）にする
         BufC4[i] = (s.spanBUp && !s.spanBDown) ? 1.0
                    : ((s.spanBDown && !s.spanBUp) ? -1.0 : 0.0);

         if(s.buy)  BufBuy[i]  = low[i];
         if(s.sell) BufSell[i] = high[i];
      }
   }

   return rates_total;
}
