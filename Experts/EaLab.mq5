//+------------------------------------------------------------------+
//| EaLab.mq5                                                        |
//| オシレータ逆張り EA                                              |
//|                                                                  |
//| エントリー: RSI(9) が 30 を下抜け → 買い / 70 を上抜け → 売り    |
//| エグジット: エントリー足から N 本後の始値で無条件決済（既定 24） |
//| 損切り: なし（N 本タイムストップのみ）                           |
//|                                                                  |
//| 仕様: docs/entry_signal_spec.md（採用構成は §1.2）               |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "2.00"
#property strict

#include <Trade\Trade.mqh>
#include <Signals\SignalRSI.mqh>

//--- 入力パラメータ
input int    InpRsiPeriod   = 9;      // RSI 期間
input double InpRsiLower    = 30.0;   // 売られすぎ閾値（買いエントリー）
input double InpRsiUpper    = 70.0;   // 買われすぎ閾値（売りエントリー）
input int    InpExitBars    = 24;     // 決済までの保有本数 N
input bool   InpAllowOverlap = true;  // 保有中も新規エントリーする（重複保有）
input double InpLots        = 0.01;   // ロット数
input ulong  InpMagic       = 20260726; // マジックナンバー
input ulong  InpSlippage    = 10;     // 許容スリッページ(points)

//--- グローバル
CTrade      g_trade;
CSignalRSI *g_signal = NULL;
datetime    g_last_bar_time = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(InpExitBars < 1)
     {
      PrintFormat("EaLab: InpExitBars は 1 以上にしてください (現在 %d)", InpExitBars);
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- 重複保有はネッティング口座では成立しない（建玉が相殺・合算される）。
   //--- 黙って別物の結果を出すより起動時に弾く。
   if(InpAllowOverlap &&
      (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      Print("EaLab: 重複保有(InpAllowOverlap=true)にはヘッジ口座が必要です。",
            "ネッティング口座では建玉が合算され、検証条件と別物になります");
      return(INIT_FAILED);
     }

   g_signal = new CSignalRSI(InpRsiPeriod, InpRsiLower, InpRsiUpper);
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
//|                                                                  |
//| 決済はシグナルの取得可否に依存させない（先に処理する）。        |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(!IsNewBar())
      return;

   CloseExpiredPositions();

   if(!g_signal.Update())
      return;

   ENUM_SIGNAL_DIR entry = g_signal.Entry();
   if(entry == SIGNAL_NONE)
      return;

   //--- 重複を許さない設定なら、保有中は新規シグナルを捨てる
   if(!InpAllowOverlap && HasOpenPosition())
      return;

   if(entry == SIGNAL_LONG)
      ReportTradeResult("Buy", g_trade.Buy(InpLots, _Symbol));
   else
      ReportTradeResult("Sell", g_trade.Sell(InpLots, _Symbol));
  }

//+------------------------------------------------------------------+
//| N 本タイムストップ                                               |
//|                                                                  |
//| エントリー足から数えて N 本後の足で決済する。経過時間ではなく    |
//| 足数で数えるため、週末やギャップで足が飛んでも本数は狂わない。   |
//| （研究側 forward_return.py の exit_pos = entry_pos + N と同じ）  |
//|                                                                  |
//| ヘッジ口座では同一シンボルに複数ポジションが並ぶため、決済は    |
//| 必ず ticket 指定で行う。                                         |
//+------------------------------------------------------------------+
void CloseExpiredPositions(void)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) != (long)InpMagic)
         continue;

      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      int bars_held = iBarShift(_Symbol, _Period, opened, false);
      if(bars_held < 0)
        {
         PrintFormat("EaLab: 保有本数を取得できません (ticket=%I64u, error=%d)",
                     ticket, GetLastError());
         continue;
        }

      if(bars_held >= InpExitBars)
         ReportTradeResult("PositionClose", g_trade.PositionClose(ticket));
     }
  }

//+------------------------------------------------------------------+
//| 自 EA のポジションを保有しているか                               |
//+------------------------------------------------------------------+
bool HasOpenPosition(void)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;

      if(PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return(true);
     }

   return(false);
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
