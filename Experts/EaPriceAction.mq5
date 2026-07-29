//+------------------------------------------------------------------+
//| EaPriceAction.mq5                                                |
//| プライスアクション単体の優位性検証用 EA                          |
//|                                                                  |
//| 3指標との AND 条件に組み込む前段として、定番3種を1つずつ         |
//| バックテストするためのもの。単体でのプラスは想定せず、           |
//| トータルマイナスを回避できるかを見る。                           |
//|                                                                  |
//| エントリー:                                                      |
//|   成行   … パターン確定後、次足の始値で発注                      |
//|   逆指値 … 買いはパターン足の高値、売りは安値にストップ注文。    |
//|             反転が確認されてから入る形。N 本以内に約定しなければ |
//|             取消し、逆側の高安を先に更新した場合もキャンセルする |
//|             （即時エントリーしていれば損切りになっていた状況）。 |
//|                                                                  |
//| エグジット:                                                      |
//|   利確 … N 本経過後にクローズ                                    |
//|   損切 … パターン足の高値/安値に逆指値（終値判定ではない）       |
//|                                                                  |
//| 時間足はストラテジーテスター側の指定に従う（input を持たない）。 |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>
#include <Signals\PriceAction.mqh>

//--- パターン
input ENUM_PA_PATTERN InpPattern      = PA_PINBAR; // 検証するパターン

//--- ピンバー
input double InpPinWickRatio          = 0.66;  // ピンバー: 長ヒゲ/レンジ の下限
input double InpPinOppositeRatio      = 0.15;  // ピンバー: 反対ヒゲ/レンジ の上限

//--- 包み足 / はらみ足
input bool   InpRequireColorFlip      = true;  // 包み/はらみ: 色の反転を必須

//--- 共通フィルタ
input double InpMinRangeATR           = 0.50;  // 共通: レンジの下限(ATR比)
input bool   InpRequireDayExtreme     = true;  // 共通: 当日高安の更新を必須
input int    InpATRPeriod             = 14;    // ATR 期間

//--- エントリー方式
input bool   InpUseStopEntry          = true;  // 逆指値エントリーを使う(OFF=成行)
input int    InpStopEntryValidBars    = 3;     // 逆指値の有効本数(N本以内に約定しなければ取消)

//--- エグジット
input bool   InpUseHoldBars           = true;  // N本経過でクローズする
input int    InpHoldBars              = 10;    // N本経過後にクローズ
input bool   InpUseTakeProfit         = false; // 利確を使う(損切り幅のN倍)
input double InpTPRatio               = 1.0;   // 利確 = 損切り幅 × N (1.0=勝率50%で±0)
input double InpSLBufferPips          = 0.5;   // 損切りのバッファ(pips)

//--- 発注
input double InpLots                  = 0.01;  // ロット数
input ulong  InpMagic                 = 20260727; // マジックナンバー
input ulong  InpSlippage              = 10;    // 許容スリッページ(points)

//--- 可視化（ビジュアルモード確認用。本番テストでは OFF 推奨）
input bool   InpDrawSignals           = false; // シグナルをチャートに描画する
input int    InpArrowWidth            = 3;     // 矢印のサイズ

//--- デバッグ出力（原因調査用。本番テストでは OFF 推奨）
input bool   InpDebugLog              = false; // 逆指値の予約・発動・取消をログ出力する

//--- グローバル
CTrade        g_trade;
CPriceAction *g_pa = NULL;
datetime      g_last_bar_time = 0;

//--- 待機中の逆指値エントリー
struct SPendingEntry
  {
   bool              active;
   ENUM_SIGNAL_DIR   dir;
   double            trigger;   // 逆指値の発動価格（パターン足の高値/安値）
   double            invalid;   // これを超えたらキャンセル（逆側の高安）
   int               bars_left; // 残り有効本数
  };
SPendingEntry g_pending;

//--- 保有ポジションの経過本数
ulong    g_pos_ticket    = 0;
int      g_pos_bars_held = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   if(InpPattern == PA_NONE)
     {
      Print("EaPriceAction: パターンが選択されていません");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseHoldBars && InpHoldBars <= 0)
     {
      Print("EaPriceAction: InpHoldBars は 1 以上を指定してください");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpUseTakeProfit && InpTPRatio <= 0.0)
     {
      Print("EaPriceAction: InpTPRatio は 0 より大きい値を指定してください");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- 負数だと買いの損切りがパターン足の安値より上、売りは高値より下へ
   //    移動し、「損切りはパターン足の逆側」という前提が壊れる。
   //    NormalizeStopLevel は最小ストップ距離しか見ないため回復しない。
   if(InpSLBufferPips < 0.0)
     {
      Print("EaPriceAction: InpSLBufferPips は 0 以上を指定してください");
      return(INIT_PARAMETERS_INCORRECT);
     }

   //--- 両方 OFF だと決済手段が損切りだけになり、利益方向へ動いた
   //    ポジションが無期限に残る。設定ミスの可能性が高いため警告する。
   if(!InpUseHoldBars && !InpUseTakeProfit)
      Print("EaPriceAction: 警告 - N本経過も利確も無効です。決済は損切りのみになります");

   if(InpUseStopEntry && InpStopEntryValidBars <= 0)
     {
      Print("EaPriceAction: InpStopEntryValidBars は 1 以上を指定してください");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_pa = new CPriceAction(InpATRPeriod);
   if(g_pa == NULL)
     {
      Print("EaPriceAction: 検出器の生成に失敗しました");
      return(INIT_FAILED);
     }

   if(!g_pa.Init(_Symbol, (ENUM_TIMEFRAMES)_Period))
     {
      Print("EaPriceAction: 検出器の初期化に失敗しました");
      return(INIT_FAILED);
     }

   SPriceActionParams params;
   params.pin_wick_ratio      = InpPinWickRatio;
   params.pin_opposite_ratio  = InpPinOppositeRatio;
   params.require_color_flip  = InpRequireColorFlip;
   params.min_range_atr       = InpMinRangeATR;
   params.require_day_extreme = InpRequireDayExtreme;
   g_pa.SetParams(params);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   g_last_bar_time = 0;
   ClearPending();
   g_pos_ticket    = 0;
   g_pos_bars_held = 0;

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

   //--- 描画したオブジェクトを残さない（再実行時に前回分と混ざるため）
   if(InpDrawSignals)
      ObjectsDeleteAll(0, "PA_");
  }

//+------------------------------------------------------------------+
//| 待機中エントリーをクリア                                         |
//+------------------------------------------------------------------+
void ClearPending(void)
  {
   g_pending.active    = false;
   g_pending.dir       = SIGNAL_NONE;
   g_pending.trigger   = 0.0;
   g_pending.invalid   = 0.0;
   g_pending.bars_left = 0;
  }

//+------------------------------------------------------------------+
//| ティック処理                                                     |
//|                                                                  |
//| 逆指値の発動・キャンセル判定はティック単位で行う（終値判定では   |
//| ないため）。パターン検出とポジションの経過本数は確定足単位。     |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   //--- 逆指値の発動は足の途中でも起こりうるため毎ティック評価する
   if(g_pending.active)
      ProcessPending();

   if(!IsNewBar())
      return;

   //--- 保有中なら経過本数で決済判定
   ENUM_SIGNAL_DIR pos_dir = CurrentPositionDir(g_pos_ticket);
   if(pos_dir != SIGNAL_NONE)
     {
      g_pos_bars_held++;
      if(InpUseHoldBars && g_pos_bars_held >= InpHoldBars)
        {
         //--- PositionClose() の戻り値は要求送信可否のみ。約定可否は
         //    ResultRetcode() で判別する。失敗時に状態をリセットすると
         //    決済が残ったままカウントが途切れ、次の判定まで
         //    InpHoldBars 本ぶん遅れるため、成功時のみリセットする。
         bool sent = g_trade.PositionClose(g_pos_ticket);
         ReportTradeResult("PositionClose", sent);

         uint retcode = g_trade.ResultRetcode();
         if(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED))
           {
            g_pos_ticket    = 0;
            g_pos_bars_held = 0;
           }
        }
      return;
     }

   //--- ポジションが無いなら経過カウンタを戻す
   g_pos_bars_held = 0;

   //--- 待機中の逆指値がある場合は有効期限を消化する
   if(g_pending.active)
     {
      g_pending.bars_left--;
      if(g_pending.bars_left <= 0)
        {
         //--- 期限切れ（灰色の × 印）
         DebugPending("取消(期限切れ)", g_pending.trigger);
         DrawCancel(g_pending.trigger, false);
         ClearPending();
        }
      return;
     }

   //--- 新規シグナルの検出（確定足 shift=1）
   ENUM_SIGNAL_DIR dir = g_pa.Detect(InpPattern, 1);
   if(dir == SIGNAL_NONE)
      return;

   double   pat_high = iHigh(_Symbol, (ENUM_TIMEFRAMES)_Period, 1);
   double   pat_low  = iLow(_Symbol,  (ENUM_TIMEFRAMES)_Period, 1);
   datetime pat_time = iTime(_Symbol, (ENUM_TIMEFRAMES)_Period, 1);

   DrawSignal(pat_time, dir, pat_high, pat_low);

   if(!InpUseStopEntry)
     {
      //--- 成行エントリー。損切りはパターン足の逆側
      OpenMarket(dir, pat_high, pat_low);
      return;
     }

   //--- 逆指値エントリーを予約する
   //    買いは高値を上抜けたら発動、安値を割ったらキャンセル
   g_pending.active    = true;
   g_pending.dir       = dir;
   g_pending.trigger   = (dir == SIGNAL_LONG) ? pat_high : pat_low;
   g_pending.invalid   = (dir == SIGNAL_LONG) ? pat_low  : pat_high;
   g_pending.bars_left = InpStopEntryValidBars;

   DebugPending("予約", 0.0);
   DrawTrigger(pat_time, g_pending.trigger);
  }

//+------------------------------------------------------------------+
//| 待機中の逆指値エントリーを処理する                               |
//|                                                                  |
//| キャンセル判定を発動判定より先に行う。同一ティックで両方の条件が |
//| 満たされた場合、即時エントリーしていれば損切りになっていた       |
//| 状況にあたるため、エントリーしないほうを選ぶ。                   |
//+------------------------------------------------------------------+
void ProcessPending(void)
  {
   //--- 既にポジションがあるなら予約は破棄する
   ulong dummy = 0;
   if(CurrentPositionDir(dummy) != SIGNAL_NONE)
     {
      ClearPending();
      return;
     }

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return;

   if(g_pending.dir == SIGNAL_LONG)
     {
      //--- 安値を割ったらキャンセル（赤い × 印）
      if(bid <= g_pending.invalid)
        {
         DebugPending("取消(逆側ブレイク)", g_pending.invalid);
         DrawCancel(g_pending.invalid, true);
         ClearPending();
         return;
        }
      //--- 高値を上抜けたら発動
      if(ask >= g_pending.trigger)
        {
         double sl = g_pending.invalid;
         DebugPending("発動(買い)", g_pending.trigger);
         ClearPending();
         OpenMarket(SIGNAL_LONG, 0.0, sl);
        }
      return;
     }

   if(g_pending.dir == SIGNAL_SHORT)
     {
      //--- 高値を上抜けたらキャンセル（赤い × 印）
      //    判定は bid で行う。ask 基準にすると、パターン足の値幅が
      //    スプレッド以下のとき予約と同時にキャンセルが成立してしまい、
      //    エントリーの機会自体が発生しない（実測: 値幅19 / スプレッド19）。
      //    チャートは bid で描画されるため見た目とも一致する。
      if(bid >= g_pending.invalid)
        {
         DebugPending("取消(逆側ブレイク)", g_pending.invalid);
         DrawCancel(g_pending.invalid, true);
         ClearPending();
         return;
        }
      //--- 安値を割ったら発動
      if(bid <= g_pending.trigger)
        {
         double sl = g_pending.invalid;
         DebugPending("発動(売り)", g_pending.trigger);
         ClearPending();
         OpenMarket(SIGNAL_SHORT, sl, 0.0);
        }
     }
  }

//+------------------------------------------------------------------+
//| 成行発注                                                         |
//|                                                                  |
//| 損切りはパターン足の逆側。買いは pat_low、売りは pat_high。      |
//| 使わない側の引数は 0.0 を渡す。                                  |
//|                                                                  |
//| 売りの損切りにはスプレッドを加算する。パターン足の高安は bid 基準 |
//| だが、売りポジションの損切りは ask で発動するため、そのままでは   |
//| スプレッド分だけ手前で狩られる。買いは bid 基準で発動するため     |
//| 単位が揃っており加算は不要。                                     |
//| バッファは高安ちょうどで狩られるのを避けるための余裕（両側）。   |
//+------------------------------------------------------------------+
void OpenMarket(const ENUM_SIGNAL_DIR dir, const double pat_high, const double pat_low)
  {
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   //--- pips → 価格。3/5 桁は 1pips = 10point、2/4 桁は 1pips = 1point
   double pip    = (digits == 3 || digits == 5) ? point * 10.0 : point;
   double buffer = InpSLBufferPips * pip;

   double sl = 0.0;
   if(dir == SIGNAL_LONG)
      sl = pat_low - buffer;
   else
     {
      double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * point;
      sl = pat_high + spread + buffer;
     }

   sl = NormalizeStopLevel(dir, sl);

   //--- 利確は損切りと同じ幅を約定価格から反対側へ取り、その N 倍とする。
   //    損切り幅にはスプレッドとバッファが含まれているため、N=1.0 なら
   //    勝ちと負けの値幅が等しくなり、勝率 50% で収支が ±0 になる。
   //    基準はエントリー価格（買い=ask / 売り=bid）。約定前のため
   //    現在値で代用する（成行のため実約定価格とほぼ一致する）。
   double entry = (dir == SIGNAL_LONG)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tp    = 0.0;

   if(InpUseTakeProfit && InpTPRatio > 0.0)
     {
      double risk = MathAbs(entry - sl) * InpTPRatio;
      tp = (dir == SIGNAL_LONG) ? entry + risk : entry - risk;

      //--- ストップレベルは SL だけでなく TP にも適用される。InpTPRatio が
      //    小さいと最小距離を下回り、発注が Invalid stops で拒否されるため
      //    最小距離まで押し戻す。NormalizeStopLevel は bid/ask との比較方向が
      //    SL 前提のため流用できず、ここで TP 用に距離を確保する。
      double min_d = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;

      if(dir == SIGNAL_LONG && tp - entry < min_d)
         tp = entry + min_d;

      if(dir == SIGNAL_SHORT && entry - tp < min_d)
         tp = entry - min_d;

      tp = NormalizeDouble(tp, digits);
     }

   if(InpDebugLog)
      PrintFormat("[PA] 発注 dir=%s entry=%s sl=%s tp=%s buffer=%.1fpips spread=%dpoint",
                  (dir == SIGNAL_LONG) ? "買い" : "売り",
                  DoubleToString(entry, digits),
                  DoubleToString(sl, digits),
                  (tp > 0.0) ? DoubleToString(tp, digits) : "なし",
                  InpSLBufferPips,
                  (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD));

   if(dir == SIGNAL_LONG)
      ReportTradeResult("Buy", g_trade.Buy(InpLots, _Symbol, 0.0, sl, tp));
   else
      if(dir == SIGNAL_SHORT)
         ReportTradeResult("Sell", g_trade.Sell(InpLots, _Symbol, 0.0, sl, tp));

   //--- 新規建玉の経過本数を初期化
   g_pos_bars_held = 0;
  }

//+------------------------------------------------------------------+
//| 損切り価格をブローカーの最小距離に合わせる                       |
//|                                                                  |
//| ストップレベル未満だと発注が拒否される。パターン足のレンジが     |
//| 極端に狭い場合に備えて最小距離まで押し戻す。                     |
//+------------------------------------------------------------------+
double NormalizeStopLevel(const ENUM_SIGNAL_DIR dir, const double sl)
  {
   if(sl <= 0.0)
      return(0.0);

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_d  = stops * point;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double adjusted = sl;

   if(dir == SIGNAL_LONG && bid - adjusted < min_d)
      adjusted = bid - min_d;

   if(dir == SIGNAL_SHORT && adjusted - ask < min_d)
      adjusted = ask + min_d;

   return(NormalizeDouble(adjusted, digits));
  }

//+------------------------------------------------------------------+
//| シグナル検出を矢印で描画する                                     |
//|                                                                  |
//| ビジュアルモードで挙動を目視確認するためのもの。オブジェクトを   |
//| 大量に生成するとテストが遅くなるため既定では無効。               |
//+------------------------------------------------------------------+
void DrawSignal(const datetime bar_time, const ENUM_SIGNAL_DIR dir,
                const double pat_high, const double pat_low)
  {
   if(!InpDrawSignals)
      return;

   string name = StringFormat("PA_sig_%I64d", (long)bar_time);
   double price;
   int    code;
   color  clr;

   if(dir == SIGNAL_LONG)
     {
      price = pat_low;
      code  = 233;            // 上向き矢印
      clr   = clrDodgerBlue;
     }
   else
     {
      price = pat_high;
      code  = 234;            // 下向き矢印
      clr   = clrOrangeRed;
     }

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, bar_time, price))
      return;

   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, code);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpArrowWidth);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR,
                    (dir == SIGNAL_LONG) ? ANCHOR_TOP : ANCHOR_BOTTOM);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| 逆指値のトリガー価格を点線で描画する                             |
//+------------------------------------------------------------------+
void DrawTrigger(const datetime bar_time, const double trigger)
  {
   if(!InpDrawSignals)
      return;

   string   name = StringFormat("PA_trg_%I64d", (long)bar_time);
   datetime to   = bar_time + PeriodSeconds((ENUM_TIMEFRAMES)_Period)
                   * (InpStopEntryValidBars + 1);

   if(!ObjectCreate(0, name, OBJ_TREND, 0, bar_time, trigger, to, trigger))
      return;

   ObjectSetInteger(0, name, OBJPROP_COLOR, clrSilver);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| 逆指値の状態遷移をログ出力する                                   |
//|                                                                  |
//| チャート上の × 印は色でしか理由を区別できず、描画価格も呼び出し  |
//| 元によって trigger / invalid と変わるため、位置から理由を読み取る |
//| ことができない。予約・発動・取消の実数値をここで記録する。       |
//| price は判定に使った価格。予約時は該当しないため 0.0 を渡す。    |
//+------------------------------------------------------------------+
void DebugPending(const string event, const double price)
  {
   if(!InpDebugLog)
      return;

   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   string dir    = (g_pending.dir == SIGNAL_LONG) ? "買い" : "売り";

   PrintFormat("[PA] %s bar=%s dir=%s trigger=%s invalid=%s bid=%s ask=%s 残=%d 判定価格=%s",
               event,
               TimeToString(iTime(_Symbol, (ENUM_TIMEFRAMES)_Period, 0), TIME_DATE | TIME_MINUTES),
               dir,
               DoubleToString(g_pending.trigger, digits),
               DoubleToString(g_pending.invalid, digits),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), digits),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_ASK), digits),
               g_pending.bars_left,
               (price > 0.0) ? DoubleToString(price, digits) : "-");
  }

//+------------------------------------------------------------------+
//| 逆指値がキャンセルされたことを × 印で描画する                    |
//|                                                                  |
//| 逆側を先に更新した場合と期限切れの場合を色で分ける。             |
//+------------------------------------------------------------------+
void DrawCancel(const double price, const bool invalidated)
  {
   if(!InpDrawSignals)
      return;

   datetime now  = TimeCurrent();
   string   name = StringFormat("PA_cxl_%I64d", (long)now);

   if(!ObjectCreate(0, name, OBJ_ARROW, 0, now, price))
      return;

   ObjectSetInteger(0, name, OBJPROP_ARROWCODE, 251); // ×
   ObjectSetInteger(0, name, OBJPROP_COLOR, invalidated ? clrRed : clrGray);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, InpArrowWidth);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
  }

//+------------------------------------------------------------------+
//| 取引要求の結果を記録する                                         |
//|                                                                  |
//| CTrade の戻り値は「要求をサーバーへ送れたか」しか示さない。      |
//| 実際の約定可否は ResultRetcode() で判別する必要がある。          |
//+------------------------------------------------------------------+
void ReportTradeResult(const string action, const bool sent)
  {
   uint retcode = g_trade.ResultRetcode();

   if(!sent)
     {
      PrintFormat("EaPriceAction: %s の要求送信に失敗 (retcode=%u, %s, error=%d)",
                  action, retcode, g_trade.ResultRetcodeDescription(), GetLastError());
      return;
     }

   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
      PrintFormat("EaPriceAction: %s が約定しませんでした (retcode=%u, %s)",
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
