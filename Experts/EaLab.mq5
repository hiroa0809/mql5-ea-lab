//+------------------------------------------------------------------+
//| EaLab.mq5                                                        |
//| オシレータ逆張り EA（CodeRabbit 検証用の最小実装）               |
//|                                                                  |
//| エントリー: RSI(9) が 30 を下抜け → 買い / 70 を上抜け → 売り    |
//| エグジット: RSI が 50 をクロスしたら決済                         |
//| 損切り: なし（RSI 50 回帰のみで手仕舞う）                        |
//|                                                                  |
//| 仕様: docs/entry_signal_spec.md                                  |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Signals\SignalRSI.mqh>

//--- 入力パラメータ
input int    InpRsiPeriod    = 9;      // RSI 期間
input double InpRsiLower     = 30.0;   // 売られすぎ閾値（買いエントリー）
input double InpRsiUpper     = 70.0;   // 買われすぎ閾値（売りエントリー）
input double InpRsiExitLevel = 50.0;   // エグジット回帰レベル
input double InpLots         = 0.01;   // ロット数
input ulong  InpMagic        = 20260726; // マジックナンバー
input ulong  InpSlippage     = 10;     // 許容スリッページ(points)

//--- グローバル
CTrade      g_trade;
CSignalRSI *g_signal = NULL;
datetime    g_last_bar_time = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   g_signal = new CSignalRSI(InpRsiPeriod, InpRsiLower, InpRsiUpper, InpRsiExitLevel);
   if(g_signal == NULL)
     {
      Print("EaLab: シグナル部品の生成に失敗しました");
      return(INIT_FAILED);
     }

   if(!g_signal.Init(_Symbol, _Period))
     {
      Print("EaLab: シグナル部品の初期化に失敗しました");
      return(INIT_FAILED);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_last_bar_time = 0;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| 終了処理                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_signal != NULL)
     {
      delete g_signal;
      g_signal = NULL;
     }
  }

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//|                                                                  |
//| 判定は確定足単位。新しい足が生成された最初のティックでのみ      |
//| 評価し、その足の始値付近で成行発注する。                        |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!IsNewBar())
      return;

   if(!g_signal.Update())
      return;

   //--- 保有中なら決済判定を優先
   ulong pos_ticket = 0;
   ENUM_SIGNAL_DIR pos_dir = CurrentPositionDir(pos_ticket);
   if(pos_dir != SIGNAL_NONE)
     {
      if(g_signal.ShouldExit(pos_dir))
        {
         //--- ヘッジ口座で他ポジションを巻き込まないよう ticket 指定で決済
         bool sent = g_trade.PositionClose(pos_ticket);
         ReportTradeResult("PositionClose", sent);
        }
      return;
     }

   //--- ノーポジションならエントリー判定
   ENUM_SIGNAL_DIR entry = g_signal.Entry();
   if(entry == SIGNAL_LONG)
      ReportTradeResult("Buy", g_trade.Buy(InpLots, _Symbol));
   else
      if(entry == SIGNAL_SHORT)
         ReportTradeResult("Sell", g_trade.Sell(InpLots, _Symbol));
  }

//+------------------------------------------------------------------+
//| 取引要求の結果を記録する                                         |
//|                                                                  |
//| CTrade の戻り値は「要求をサーバーへ送れたか」しか示さない。      |
//| 実際の約定可否は ResultRetcode() で判別する必要がある。          |
//| 失敗しても再試行はしない（次の確定足で再判定される）。          |
//+------------------------------------------------------------------+
void ReportTradeResult(const string action, const bool sent)
  {
   uint retcode = g_trade.ResultRetcode();

   if(!sent)
     {
      PrintFormat("EaLab: %s の要求送信に失敗 (retcode=%u, %s, error=%d)",
                  action, retcode, g_trade.ResultRetcodeDescription(), GetLastError());
      return;
     }

   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
      PrintFormat("EaLab: %s が約定しませんでした (retcode=%u, %s)",
                  action, retcode, g_trade.ResultRetcodeDescription());
  }

//+------------------------------------------------------------------+
//| 新しい足が生成されたか                                           |
//+------------------------------------------------------------------+
bool IsNewBar(void)
  {
   datetime current = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(current == g_last_bar_time)
      return(false);

   g_last_bar_time = current;
   return(true);
  }

//+------------------------------------------------------------------+
//| 自 EA が保有中のポジション方向を返す                             |
//|                                                                  |
//| ticket は out 引数で返す。ヘッジ口座では同一シンボルに複数        |
//| ポジションが並びうるため、決済は必ず ticket 指定で行う。         |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CurrentPositionDir(ulong &ticket)
  {
   ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;

      long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
        {
         ticket = t;
         return(SIGNAL_LONG);
        }
      if(type == POSITION_TYPE_SELL)
        {
         ticket = t;
         return(SIGNAL_SHORT);
        }
     }

   return(SIGNAL_NONE);
  }
//+------------------------------------------------------------------+
