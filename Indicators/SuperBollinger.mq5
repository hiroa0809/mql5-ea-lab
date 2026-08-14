//+------------------------------------------------------------------+
//| SuperBollinger.mq5                                               |
//| スーパーボリンジャーの描画（上位足で大局を見る用）               |
//|                                                                  |
//| 計算は Include\Signals\SuperBollinger.mqh に置き、EA と共有する。|
//| 本ファイルは描画だけを担当し、式を持たない。                     |
//|                                                                  |
//| **ルール1（単体の売買）の表示は 2026-08-14 に全部外した。**      |
//| 売買矢印・決済アイコン・段階エントリーの印・SAR の決済がそれで、  |
//| 実装はコミット 1629436 までの履歴にある。単体では合否ライン      |
//| 3.7 pips に届かず、資料本来の R3（上位足で大局 → 下位足の        |
//| スパンモデルでエントリー）へ戻したため。                         |
//|                                                                  |
//| 残したのは帯とσ、遅行線、そして**バンド幅が拡大しているか**。   |
//| R3 で上位足に求めるのはこれだけ（docs/trading_rules.md §6）。    |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §2.2。                         |
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

// 線は引かない。データウィンドウで足ごとに読むための枠。
// 拡大しているかを目で追うだけなら帯の見た目で足りるが、境目の足は
// 判断が割れる。数値で確定させられるようにしておく。
#property indicator_label9  "拡大 (1=成立)"
#property indicator_type9   DRAW_NONE
#property indicator_label10 "σ"
#property indicator_type10  DRAW_NONE

#include <Signals\SuperBollinger.mqh>

input int InpPeriod     = 21;   // 期間（センターラインとσ）
input int InpLagBars    = 21;   // 遅行線の本数
input int InpExpandBars = 8;    // 拡大を見る本数

double BufCenter[], BufU1[], BufL1[], BufU2[], BufL2[], BufU3[], BufL3[], BufLag[];
double BufExpand[], BufSigma[];

int g_needBars = 0;

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

   SetIndexBuffer(0, BufCenter, INDICATOR_DATA);
   SetIndexBuffer(1, BufU1,     INDICATOR_DATA);
   SetIndexBuffer(2, BufL1,     INDICATOR_DATA);
   SetIndexBuffer(3, BufU2,     INDICATOR_DATA);
   SetIndexBuffer(4, BufL2,     INDICATOR_DATA);
   SetIndexBuffer(5, BufU3,     INDICATOR_DATA);
   SetIndexBuffer(6, BufL3,     INDICATOR_DATA);
   SetIndexBuffer(7, BufLag,    INDICATOR_DATA);
   SetIndexBuffer(8, BufExpand, INDICATOR_DATA);
   SetIndexBuffer(9, BufSigma,  INDICATOR_DATA);

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("SB(%d,%d,%d)", InpPeriod, InpLagBars, InpExpandBars));
   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);

   g_needBars = SB_RequiredBars(InpPeriod, InpLagBars, InpExpandBars);

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
   if(rates_total < g_needBars)
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
   ArraySetAsSeries(BufExpand, true);
   ArraySetAsSeries(BufSigma,  true);

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
         BufSigma[i]  = v.sigma;
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
         BufSigma[i]  = EMPTY_VALUE;
      }

      // 最新から InpLagBars 本ぶんは値が無い。ここで線が切れるのが正しい
      double lag;
      BufLag[i] = SB_LagValue(close, i, InpLagBars, lag) ? lag : EMPTY_VALUE;

      // 形成中の足（添字 0）には出さない。確定足でしか判定しない決まり
      // （docs/trading_rules.md §2.1）で、ここに出すと足の途中で現れたり
      // 消えたりする値を見てしまう。
      BufExpand[i] = EMPTY_VALUE;
      if(i >= 1)
      {
         bool expanding;
         if(SB_Expanding(close, i, InpPeriod, InpExpandBars, expanding))
            BufExpand[i] = expanding ? 1.0 : 0.0;
      }
   }

   return rates_total;
}
//+------------------------------------------------------------------+
