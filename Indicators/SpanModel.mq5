//+------------------------------------------------------------------+
//| SpanModel.mq5                                                    |
//| スパンモデルの描画（N4-5 の目視確認用）                          |
//|                                                                  |
//| 計算は Include\Signals\SpanModel.mqh に置き、EA と共有する。     |
//| 本ファイルは描画だけを担当し、計算式を持たない。売買判定の矢印は |
//| N5-2 で追加する。                                                |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §1.2。                         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 5
#property indicator_plots   4

// 雲。青スパンが上なら雲色1（青＝サポートゾーン）、
// 赤スパンが上なら雲色2（赤＝レジスタンスゾーン）に塗り分けられる。
#property indicator_label1  "雲"
#property indicator_type1   DRAW_FILLING
#property indicator_color1  clrDodgerBlue,clrCrimson

#property indicator_label2  "青スパン"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_width2  2

#property indicator_label3  "赤スパン"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrCrimson
#property indicator_width3  2

#property indicator_label4  "遅行線"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrMagenta

#include <Signals\SpanModel.mqh>

input int InpTenkan  = 9;   // 転換線の期間
input int InpKijun   = 26;  // 基準線の期間
input int InpSpanB   = 52;  // 赤スパンの期間
input int InpLagBars = 26;  // 遅行線の本数

// 雲は DRAW_FILLING が2本のバッファを要求するため、線として描く
// 青スパン・赤スパンとは別に持つ（同じ値を入れる）。
double BufCloudA[], BufCloudB[], BufSpanA[], BufSpanB[], BufLag[];

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

   SetIndexBuffer(0, BufCloudA, INDICATOR_DATA);
   SetIndexBuffer(1, BufCloudB, INDICATOR_DATA);
   SetIndexBuffer(2, BufSpanA,  INDICATOR_DATA);
   SetIndexBuffer(3, BufSpanB,  INDICATOR_DATA);
   SetIndexBuffer(4, BufLag,    INDICATOR_DATA);

   for(int p = 0; p < 4; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

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
   }

   return rates_total;
}
