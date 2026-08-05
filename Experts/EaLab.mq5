//+------------------------------------------------------------------+
//| EaLab.mq5                                                        |
//| オシレータ EA（エントリー方向・決済方式を input で切替可能）     |
//|                                                                  |
//| エントリー: RSI が下限を下抜け / 上限を上抜けした確定足の翌足始値 |
//|             InpReverse で売買方向を反転できる（逆張り⇔順張り）   |
//| エグジット: RSI レベル回帰クロス、または N 本タイムストップ       |
//|                                                                  |
//| 仕様: docs/entry_signal_spec.md（採用構成は §1.2）               |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>
#include <Signals\SignalRSI.mqh>

//--- 決済方式
enum ENUM_EXIT_MODE
  {
   EXIT_RSI_LEVEL = 0, // RSI レベル回帰クロスで決済
   EXIT_BARS      = 1  // N 本後に無条件決済
  };

//--- 取引する方向
enum ENUM_TRADE_SIDE
  {
   SIDE_BOTH      = 0, // 買い・売り 両方
   SIDE_BUY_ONLY  = 1, // 買いのみ
   SIDE_SELL_ONLY = 2  // 売りのみ
  };

//--- 入力パラメータ
input int    InpRsiPeriod    = 9;      // RSI 期間
input double InpRsiLower     = 30.0;   // 下限閾値
input double InpRsiUpper     = 70.0;   // 上限閾値
input bool   InpReverse      = false;  // 売買方向を反転（ON=順張り / OFF=逆張り）
input ENUM_TRADE_SIDE InpTradeSide = SIDE_BOTH;       // 取引する方向
input ENUM_EXIT_MODE  InpExitMode  = EXIT_RSI_LEVEL;  // 決済方式
input double InpRsiExitLevel = 50.0;   // 決済レベル（EXIT_RSI_LEVEL 用）
input int    InpExitBars     = 24;     // 保有本数 N（EXIT_BARS 用）
input bool   InpAllowOverlap = false;  // 保有中も新規エントリーする（重複保有）
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
   //--- 保存済み .set に想定外の値が残っていても黙って動かさない
   if(InpExitMode != EXIT_RSI_LEVEL && InpExitMode != EXIT_BARS)
     {
      PrintFormat("EaLab: InpExitMode の値が不正です (%d)", (int)InpExitMode);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpTradeSide != SIDE_BOTH && InpTradeSide != SIDE_BUY_ONLY && InpTradeSide != SIDE_SELL_ONLY)
     {
      PrintFormat("EaLab: InpTradeSide の値が不正です (%d)", (int)InpTradeSide);
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpExitMode == EXIT_BARS && InpExitBars < 1)
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

   PrintFormat("EaLab: %s / %s / 決済=%s / RSI(%d) %.1f-%.1f",
               (InpReverse ? "順張り(反転ON)" : "逆張り(反転OFF)"),
               (InpTradeSide == SIDE_BOTH ? "両方" : (InpTradeSide == SIDE_BUY_ONLY ? "買いのみ" : "売りのみ")),
               (InpExitMode == EXIT_RSI_LEVEL ? "RSIレベル回帰" : "N本タイムストップ"),
               InpRsiPeriod, InpRsiLower, InpRsiUpper);

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

   ClosePositions();

   ENUM_SIGNAL_DIR entry = g_signal.Entry();
   if(entry == SIGNAL_NONE)
      return;

   //--- 反転設定なら売買方向を入れ替える
   if(InpReverse)
      entry = (entry == SIGNAL_LONG) ? SIGNAL_SHORT : SIGNAL_LONG;

   //--- 片側のみのテスト用フィルタ
   if(InpTradeSide == SIDE_BUY_ONLY  && entry != SIGNAL_LONG)  return;
   if(InpTradeSide == SIDE_SELL_ONLY && entry != SIGNAL_SHORT) return;

   //--- 重複を許さない設定なら、保有中は新規シグナルを捨てる
   if(!InpAllowOverlap && HasOpenPosition())
      return;

   if(entry == SIGNAL_LONG)
      ReportTradeResult("Buy", g_trade.Buy(InpLots, _Symbol));
   else
      ReportTradeResult("Sell", g_trade.Sell(InpLots, _Symbol));
  }

//+------------------------------------------------------------------+
//| 決済判定                                                         |
//|                                                                  |
//| ヘッジ口座では同一シンボルに複数ポジションが並ぶため、決済は    |
//| 必ず ticket 指定で行う。                                         |
//+------------------------------------------------------------------+
void ClosePositions(void)
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

      ENUM_SIGNAL_DIR dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
                            ? SIGNAL_LONG : SIGNAL_SHORT;

      bool close = (InpExitMode == EXIT_RSI_LEVEL)
                   ? ShouldExitByLevel(dir)
                   : ShouldExitByBars((datetime)PositionGetInteger(POSITION_TIME), ticket);

      if(close)
         ReportTradeResult("PositionClose", g_trade.PositionClose(ticket));
     }
  }

//+------------------------------------------------------------------+
//| RSI レベル回帰による決済判定                                     |
//|                                                                  |
//| 決済条件は「保有方向」ではなく「どちらのゾーンから入ったか」に   |
//| 紐づける。下限ゾーン発のポジションは RSI が決済レベルを上抜け    |
//| したら、上限ゾーン発は下抜けしたら決済する。                     |
//|                                                                  |
//| 入ったゾーンは保有方向と InpReverse から一意に決まるため、       |
//| 状態を持たずに判定できる。                                       |
//|   反転OFF: Long=下限発 / Short=上限発                            |
//|   反転ON : Short=下限発 / Long=上限発                            |
//+------------------------------------------------------------------+
bool ShouldExitByLevel(const ENUM_SIGNAL_DIR position_dir)
  {
   if(!g_signal.Ready())
      return(false);

   bool from_lower = ((position_dir == SIGNAL_LONG) != InpReverse);

   if(from_lower)
      return(CrossedAbove(g_signal.Prev(), g_signal.Curr(), InpRsiExitLevel));

   return(CrossedBelow(g_signal.Prev(), g_signal.Curr(), InpRsiExitLevel));
  }

//+------------------------------------------------------------------+
//| N 本タイムストップによる決済判定                                 |
//|                                                                  |
//| エントリー足から数えて N 本後の足で決済する。経過時間ではなく    |
//| 足数で数えるため、週末やギャップで足が飛んでも本数は狂わない。   |
//+------------------------------------------------------------------+
bool ShouldExitByBars(const datetime opened, const ulong ticket)
  {
   int bars_held = iBarShift(_Symbol, _Period, opened, false);
   if(bars_held < 0)
     {
      PrintFormat("EaLab: 保有本数を取得できません (ticket=%I64u, error=%d)", ticket, GetLastError());
      return(false);
     }

   return(bars_held >= InpExitBars);
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
