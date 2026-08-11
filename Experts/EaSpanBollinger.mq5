//+------------------------------------------------------------------+
//| EaSpanBollinger.mq5                                              |
//| ルール1（スーパーボリンジャーのトレンド開始）で売買する EA       |
//|                                                                  |
//| 判定も決済も Include\Signals\SuperBollinger.mqh に置き、          |
//| Indicators\SuperBollinger.mq5 と共有する。本ファイルは執行だけを  |
//| 担当し、条件式を持たない。チャートの矢印と EA の発火が食い違わ   |
//| ないのはこのため。                                               |
//|                                                                  |
//| 銘柄・時間足は input にせず、貼り付けたチャート（テスターの指定） |
//| に従う。設定の出どころを1つにして、テスターの指定と EA 側の設定  |
//| が無言で食い違う事故を防ぐ。                                     |
//|                                                                  |
//| ルール2（スパンモデル）は未実装。入力項目も置いていない。無言で  |
//| 何もしない設定が残るのを避けるため、N5-2 で同時に足す。          |
//|                                                                  |
//| 売買条件は docs/trading_rules.md §4、執行は                      |
//| docs/implementation_design.md §3。                               |
//+------------------------------------------------------------------+
#property description "ルール1（スーパーボリンジャー）単体の検証用"

#include <Trade\Trade.mqh>
#include <Signals\SuperBollinger.mqh>

//--- 共通
input double InpLots              = 0.10;      // ロット
input long   InpMagic             = 20260808;  // マジックナンバー
input bool   InpReverseOnOpposite = true;      // 反対シグナルでドテンする

//--- ルール1: スーパーボリンジャー
input bool   InpR1_Enable      = true;   // ルール1を使う
input int    InpR1_Period      = 21;     // 期間（センターラインとσ）
input int    InpR1_LagBars     = 21;     // 遅行線の本数
input bool   InpR1_UseSqueeze  = true;   // ①膠着を条件に入れる
input int    InpR1_SqueezeBars = 21;     // ①膠着とみなす本数（この本数ぶん帯の内側）
input double InpR1_SigmaMult   = 3.0;    // ①③で使うσの倍数
input bool   InpR1_UseLag      = true;   // ②遅行線の陽転/陰転を条件に入れる
input bool   InpR1_UseExpand   = true;   // ④バンド幅の拡大を条件に入れる
input int    InpR1_ExpandBars  = 3;      // ④拡大を見る本数
input ENUM_SB_EXIT InpR1_Exit  = SB_EXIT_CLOSE_SIGMA1;  // 決済の方式
input bool   InpR1_UseSL       = false;  // 損切りを使う
input double InpR1_SLSigma     = 2.0;    // 損切り（σの何倍）
input bool   InpR1_UseTimeStop = false;  // 保有本数で手仕舞う
input int    InpR1_HoldBars    = 24;     // 手仕舞うまでの本数

//--- 2段階エントリー（装填 → 発火）。既定は無効＝従来どおりの動き
input bool   InpR1_Staged      = false;  // 2段階エントリー（1回目は装填のみ）を使う
input int    InpR1_ArmBars     = 42;     // 装填が生きている本数
input int    InpR1_RsiPeriod   = 14;     // RSI の期間
input double InpR1_RsiUpper    = 80.0;   // 買いを見送る／買いを決済する RSI
input double InpR1_RsiLower    = 20.0;   // 売りを見送る／売りを決済する RSI

//--- 診断
input bool   InpPrintCounters = true;    // 条件別の成立回数を出力する
input string InpRunTag        = "";      // 実行の識別名（空なら CSV を書かない）

CTrade         g_trade;
SBRule1Params  g_rule1;
SBStagedParams g_staged;
SBArmState     g_arm;
int            g_rsiHandle   = INVALID_HANDLE;
datetime       g_lastBarTime = 0;
ulong          g_posTicket   = 0;
int            g_barsHeld    = 0;
int            g_needBars    = 0;

//--- 診断カウンタ。各条件は他の条件の成否と無関係に数える
//    （docs/implementation_design.md §4）
int g_cntJudged = 0;    // 判定した足数
int g_cntSqueeze = 0, g_cntLag = 0, g_cntBreak = 0, g_cntExpand = 0;
int g_cntSignal  = 0, g_cntBuy = 0, g_cntSell = 0;
int g_cntWidened = 0;   // 損切りを最小距離まで広げた回数

//--- 2段階エントリーの内訳。この案が使いものになるかは、装填が
//    どれだけ発火・見送り・期限切れに分かれたかで判断する
int g_cntArmed = 0, g_cntFired = 0, g_cntRsiBlocked = 0, g_cntExpired = 0;
int g_cntRsiExit = 0;   // RSI が行きすぎで決済した回数

//--- 1取引ぶんの記録。グロス損益はスプレッドを足し戻して求めるので、
//    建玉時と決済時のスプレッドを両方持つ（値の解釈は集計側で行う）
struct TradeRow
{
   int      dir;          // +1 買い / −1 売り
   datetime openTime;
   double   openPrice;
   int      openSpread;   // ポイント
   datetime closeTime;
   double   closePrice;   // 0 なら決済価格を取れていない
   int      closeSpread;
   int      barsHeld;
   string   reason;
};
TradeRow g_rows[];
TradeRow g_openRow;
bool     g_hasOpenRow = false;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpR1_Period < 2)
   {
      Print("期間は 2 以上にしてください（σ の分母が 期間−1 のため）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpR1_LagBars < 1 || InpR1_SqueezeBars < 1 || InpR1_ExpandBars < 1)
   {
      Print("遅行線の本数・①膠着とみなす本数・④拡大を見る本数は、いずれも 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpR1_SigmaMult <= 0.0)
   {
      Print("①③で使うσの倍数は 0 より大きくしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpR1_UseTimeStop && InpR1_HoldBars < 1)
   {
      Print("手仕舞うまでの本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   const double lotMin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double lotMax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLots < lotMin || InpLots > lotMax)
   {
      PrintFormat("ロットが %s の範囲外です（指定 %.2f / 最小 %.2f / 最大 %.2f）",
                  _Symbol, InpLots, lotMin, lotMax);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(lotStep > 0.0 && MathAbs(MathRound(InpLots / lotStep) * lotStep - InpLots) > 1e-8)
   {
      PrintFormat("ロットは %.2f 刻みにしてください（指定 %.2f）", lotStep, InpLots);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(InpR1_Staged)
   {
      if(InpR1_ArmBars < 1)
      {
         Print("装填が生きている本数は 1 以上にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(InpR1_RsiPeriod < 2)
      {
         Print("RSI の期間は 2 以上にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(!(InpR1_RsiLower > 0.0 && InpR1_RsiLower < InpR1_RsiUpper && InpR1_RsiUpper < 100.0))
      {
         Print("RSI の閾値は 0 < 売り側 < 買い側 < 100 にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }

      g_rsiHandle = iRSI(_Symbol, _Period, InpR1_RsiPeriod, PRICE_CLOSE);
      if(g_rsiHandle == INVALID_HANDLE)
      {
         PrintFormat("RSI を作成できませんでした (error=%d)", GetLastError());
         return INIT_FAILED;
      }
   }

   g_staged.enabled   = InpR1_Staged;
   g_staged.armBars   = InpR1_ArmBars;
   g_staged.rsiPeriod = InpR1_RsiPeriod;
   g_staged.rsiUpper  = InpR1_RsiUpper;
   g_staged.rsiLower  = InpR1_RsiLower;
   g_arm.armed        = false;
   g_arm.age          = 0;

   g_rule1.period      = InpR1_Period;
   g_rule1.lagBars     = InpR1_LagBars;
   g_rule1.useSqueeze  = InpR1_UseSqueeze;
   g_rule1.squeezeBars = InpR1_SqueezeBars;
   g_rule1.sigmaMult   = InpR1_SigmaMult;
   g_rule1.useLag      = InpR1_UseLag;
   g_rule1.useExpand   = InpR1_UseExpand;
   g_rule1.expandBars  = InpR1_ExpandBars;

   // 必要な履歴本数は入力値から計算する。固定値を書くと、期間を変えた
   // 瞬間にその値が嘘になる（docs/implementation_design.md §1）
   g_needBars = SB_RequiredBars(InpR1_Period, InpR1_LagBars, InpR1_SqueezeBars, InpR1_ExpandBars);

   const int have = Bars(_Symbol, _Period);
   if(have < g_needBars)
   {
      PrintFormat("履歴が足りません（必要 %d 本 / 現在 %d 本）。期間・遅行線の本数・①膠着とみなす本数から算出しています",
                  g_needBars, have);
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   // 保有したままテストが終わった建玉も1行として残す。取引回数が
   // 合わなくなるのを防ぐため
   if(g_hasOpenRow)
      RecordTrade(0.0, "テスト終了時に保有中");

   WriteCsv();

   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
   Comment("");

   if(!InpPrintCounters)
      return;

   // 取引ゼロで終わったときに、どの条件で止まったかを切り分けるため。
   // 各条件は単独で数えているので、他の条件の成否に影響されない。
   PrintFormat("[ルール1] 判定した足 %d", g_cntJudged);
   PrintFormat("[ルール1] ①膠着 %d / ②遅行線 %d / ③3σ突破 %d / ④拡大 %d",
               g_cntSqueeze, g_cntLag, g_cntBreak, g_cntExpand);
   PrintFormat("[ルール1] 4つ揃った %d   買い %d / 売り %d",
               g_cntSignal, g_cntBuy, g_cntSell);
   PrintFormat("[ルール1] 損切りを最小距離まで広げた %d", g_cntWidened);
   PrintFormat("[ルール1] 決済の方式: %s", ExitName(InpR1_Exit));

   if(InpR1_Staged)
   {
      PrintFormat("[2段階] 装填 %d → 発火 %d / RSIで見送り %d / 期限切れ %d",
                  g_cntArmed, g_cntFired, g_cntRsiBlocked, g_cntExpired);
      PrintFormat("[2段階] RSI が行きすぎで決済 %d", g_cntRsiExit);
   }
}

//+------------------------------------------------------------------+
//| 判定は確定足（shift = 1）だけ。発注は次の足の始値で成行になる    |
//| （新しい足ができた直後に成行を出すため）。                       |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar())
      return;
   if(!InpR1_Enable)
      return;

   double close[], high[], low[];
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   if(CopyClose(_Symbol, _Period, 0, g_needBars, close) < g_needBars) return;
   if(CopyHigh (_Symbol, _Period, 0, g_needBars, high)  < g_needBars) return;
   if(CopyLow  (_Symbol, _Period, 0, g_needBars, low)   < g_needBars) return;

   // RSI は判定足のぶんだけ要る。ここで取れなければ足ごと見送る。装填の
   // 経過本数を数える処理より前に返すことで、数え落としが起きないようにする
   double rsi1 = 0.0;
   if(InpR1_Staged)
   {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsiHandle, 0, 0, 2, rsi) < 2)
         return;
      rsi1 = rsi[1];
   }

   SBRule1Signal s;
   if(!SB_Rule1(close, high, low, 1, g_rule1, s))
      return;

   g_cntJudged++;
   if(s.squeezed)                 g_cntSqueeze++;
   if(s.lagAbove || s.lagBelow)   g_cntLag++;
   if(s.crossUp  || s.crossDown)  g_cntBreak++;
   if(s.expanding)                g_cntExpand++;
   if(s.buy || s.sell)
   {
      g_cntSignal++;
      if(s.buy) g_cntBuy++; else g_cntSell++;
   }

   //--- 発注する足を決める。2段階エントリーが有効なら「発火」、無効なら
   //    従来どおりサインそのもの
   bool entryBuy  = s.buy;
   bool entrySell = s.sell;
   if(InpR1_Staged)
   {
      SBStagedResult stg;
      SB_StagedStep(s, rsi1, g_staged, g_arm, stg);
      entryBuy  = stg.fireBuy;
      entrySell = stg.fireSell;

      if(stg.armedNow)          g_cntArmed++;
      if(stg.rsiBlocked)        g_cntRsiBlocked++;
      if(stg.expired)           g_cntExpired++;
      if(entryBuy || entrySell) g_cntFired++;

      if(g_arm.armed)
         Comment(StringFormat("装填中（発火まであと %d 本）", InpR1_ArmBars - g_arm.age));
      else
         Comment("装填なし");
   }

   //--- 手仕舞いが先。抜けた足で反対の発注も出ていればドテンになる
   int dir = CurrentPositionDir(g_posTicket);

   // 自分の決済以外で建玉が消えていたら（サーバー側の損切りなど）記録を閉じる。
   // 決済価格は取れないので 0 のままにし、集計側で除外できるようにする
   if(dir == 0 && g_hasOpenRow)
      RecordTrade(0.0, "EA 以外の要因（損切りなど）");

   if(dir != 0)
   {
      g_barsHeld++;

      string reason = "";
      if(InpR1_UseTimeStop && g_barsHeld >= InpR1_HoldBars)
         reason = StringFormat("保有 %d 本で時間切れ", g_barsHeld);

      if(reason == "")
      {
         bool hit;
         if(SB_Rule1Exit(close, 1, InpR1_Period, InpR1_LagBars, InpR1_Exit, dir > 0, hit) && hit)
            reason = ExitName(InpR1_Exit);
      }

      // 2段階エントリーが有効なときだけ足す OR 条件。買いは RSI が上限
      // 以上、売りは下限以下で降りる
      if(reason == "" && InpR1_Staged && SB_RsiExtreme(rsi1, dir > 0, g_staged))
      {
         reason = "RSI が行きすぎ";
         g_cntRsiExit++;
      }

      // ルール1では、反対シグナルが出るころには上の手仕舞いが先に成立して
      // いるのが通常（反対側は①膠着も要求するため）。この分岐が効くのは
      // 例外的な足だけ（docs/implementation_design.md §3）
      if(reason == "" && InpReverseOnOpposite &&
         ((dir > 0 && entrySell) || (dir < 0 && entryBuy)))
         reason = "反対シグナル";

      if(reason != "" && ClosePosition(reason))
         dir = 0;
   }

   //--- 建玉は1つまで。保有中に出た同じ向きの発注は無視する
   if(dir != 0)
      return;

   if(entryBuy)  OpenMarket(+1, close);
   if(entrySell) OpenMarket(-1, close);
}

//+------------------------------------------------------------------+
//| CSV のファイル名                                                 |
//+------------------------------------------------------------------+
string CsvName(const string kind, const int seq)
{
   if(seq <= 0)
      return StringFormat("r1_%s_%s.csv", InpRunTag, kind);
   return StringFormat("r1_%s_%s_%03d.csv", InpRunTag, kind, seq);
}

//+------------------------------------------------------------------+
//| trades / summary の両方が空いている連番を返す                    |
//|                                                                  |
//| FILE_WRITE は既存ファイルを即座に空にするため、名前が衝突すると  |
//| 前回の測定結果が消える。実在確認で防ぐ（SpreadProbe と同じ）。   |
//+------------------------------------------------------------------+
int FreeCsvSeq()
{
   for(int seq = 0; seq <= 999; seq++)
      if(!FileIsExist(CsvName("trades",  seq), FILE_COMMON)
         && !FileIsExist(CsvName("summary", seq), FILE_COMMON))
         return seq;

   return 999;
}

//+------------------------------------------------------------------+
//| 取引ごとの明細と、実行条件・カウンタを共有フォルダへ書く         |
//|                                                                  |
//| テスターの標準レポートは口座通貨での純損益しか出さない。判定に   |
//| 使うのはスプレッドを除いたグロス損益なので、建値・決済値と両端の |
//| スプレッドを残し、換算は集計側で行う。                           |
//+------------------------------------------------------------------+
void WriteCsv()
{
   if(InpRunTag == "")
      return;

   const int seq = FreeCsvSeq();
   const int rows = ArraySize(g_rows);

   const string tradesName = CsvName("trades", seq);
   const int ft = FileOpen(tradesName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(ft == INVALID_HANDLE)
      PrintFormat("EaSpanBollinger: %s を開けませんでした (error=%d)", tradesName, GetLastError());
   else
   {
      FileWrite(ft, "no", "dir", "open_time", "open_price", "open_spread_pt",
                "close_time", "close_price", "close_spread_pt", "bars_held", "reason");
      for(int i = 0; i < rows; i++)
         FileWrite(ft, i + 1, g_rows[i].dir,
                   TimeToString(g_rows[i].openTime,  TIME_DATE | TIME_SECONDS),
                   DoubleToString(g_rows[i].openPrice, _Digits), g_rows[i].openSpread,
                   TimeToString(g_rows[i].closeTime, TIME_DATE | TIME_SECONDS),
                   DoubleToString(g_rows[i].closePrice, _Digits), g_rows[i].closeSpread,
                   g_rows[i].barsHeld, g_rows[i].reason);
      FileClose(ft);
   }

   const string sumName = CsvName("summary", seq);
   const int fs = FileOpen(sumName, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fs == INVALID_HANDLE)
   {
      PrintFormat("EaSpanBollinger: %s を開けませんでした (error=%d)", sumName, GetLastError());
      return;
   }

   FileWrite(fs, "key", "value");
   FileWrite(fs, "run_tag",       InpRunTag);
   FileWrite(fs, "symbol",        _Symbol);
   FileWrite(fs, "period",        EnumToString((ENUM_TIMEFRAMES)_Period));
   FileWrite(fs, "digits",        _Digits);
   FileWrite(fs, "point",         DoubleToString(_Point, 8));
   FileWrite(fs, "exit_method",   (int)InpR1_Exit);
   FileWrite(fs, "exit_name",     ExitName(InpR1_Exit));
   FileWrite(fs, "period_bars",   InpR1_Period);
   FileWrite(fs, "lag_bars",      InpR1_LagBars);
   FileWrite(fs, "squeeze_bars",  InpR1_SqueezeBars);
   FileWrite(fs, "sigma_mult",    DoubleToString(InpR1_SigmaMult, 2));
   FileWrite(fs, "expand_bars",   InpR1_ExpandBars);
   FileWrite(fs, "use_squeeze",   InpR1_UseSqueeze ? 1 : 0);
   FileWrite(fs, "use_lag",       InpR1_UseLag ? 1 : 0);
   FileWrite(fs, "use_expand",    InpR1_UseExpand ? 1 : 0);
   FileWrite(fs, "use_sl",        InpR1_UseSL ? 1 : 0);
   FileWrite(fs, "judged_bars",   g_cntJudged);
   FileWrite(fs, "cond1_squeeze", g_cntSqueeze);
   FileWrite(fs, "cond2_lag",     g_cntLag);
   FileWrite(fs, "cond3_break",   g_cntBreak);
   FileWrite(fs, "cond4_expand",  g_cntExpand);
   FileWrite(fs, "signals",       g_cntSignal);
   FileWrite(fs, "signals_buy",   g_cntBuy);
   FileWrite(fs, "signals_sell",  g_cntSell);
   FileWrite(fs, "sl_widened",    g_cntWidened);
   FileWrite(fs, "staged",        InpR1_Staged ? 1 : 0);
   FileWrite(fs, "arm_bars",      InpR1_ArmBars);
   FileWrite(fs, "rsi_period",    InpR1_RsiPeriod);
   FileWrite(fs, "rsi_upper",     DoubleToString(InpR1_RsiUpper, 1));
   FileWrite(fs, "rsi_lower",     DoubleToString(InpR1_RsiLower, 1));
   FileWrite(fs, "armed",         g_cntArmed);
   FileWrite(fs, "fired",         g_cntFired);
   FileWrite(fs, "rsi_blocked",   g_cntRsiBlocked);
   FileWrite(fs, "arm_expired",   g_cntExpired);
   FileWrite(fs, "rsi_exits",     g_cntRsiExit);
   FileWrite(fs, "trades",        rows);
   FileClose(fs);

   PrintFormat("EaSpanBollinger: %s を書きました（%d 取引）", tradesName, rows);
}

//+------------------------------------------------------------------+
//| 決済方式の名前。ログで決済理由をそのまま読めるようにする          |
//+------------------------------------------------------------------+
string ExitName(const ENUM_SB_EXIT method)
{
   if(method == SB_EXIT_CLOSE_SIGMA1) return "終値が 1σ の内側へ戻った";
   if(method == SB_EXIT_LAG_SIGMA1)   return "遅行スパンが 1σ の内側へ戻った";
   return "遅行スパンが反対側へ陰転した";
}

//+------------------------------------------------------------------+
//| 新しい足が生成されたか                                           |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime current = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);
   if(current == g_lastBarTime)
      return false;

   g_lastBarTime = current;
   return true;
}

//+------------------------------------------------------------------+
//| 自 EA が保有中の建玉の向きを返す（+1 買い / −1 売り / 0 無し）   |
//|                                                                  |
//| ticket は out 引数で返す。ヘッジ口座では同一シンボルに複数の建玉 |
//| が並びうるため、決済は必ず ticket 指定で行う。銘柄だけを渡すと   |
//| 他の建玉を巻き込む。                                             |
//+------------------------------------------------------------------+
int CurrentPositionDir(ulong &ticket)
{
   ticket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0)                                             continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)      continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)     continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)  { ticket = t; return +1; }
      if(type == POSITION_TYPE_SELL) { ticket = t; return -1; }
   }

   return 0;
}

//+------------------------------------------------------------------+
//| 損切り価格をブローカーの最小距離に合わせる                       |
//|                                                                  |
//| 最小距離を下回ると発注ごと拒否される。見送りにすると σ が小さい |
//| 場面（＝ルール1が狙う膠着明け）の取引だけが抜け落ち、成績が実態 |
//| とずれるため、広げて建てる。広げた回数は診断に出す。             |
//|                                                                  |
//| 買い建玉は売って閉じるので Bid、売り建玉は買って閉じるので Ask   |
//| と比べる（docs/implementation_design.md §3）。                   |
//+------------------------------------------------------------------+
double NormalizeStopLevel(const int dir, const double sl, bool &widened)
{
   widened = false;

   const int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double minD   = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   const double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double adjusted = sl;

   if(dir > 0 && bid - adjusted < minD) { adjusted = bid - minD; widened = true; }
   if(dir < 0 && adjusted - ask < minD) { adjusted = ask + minD; widened = true; }

   return NormalizeDouble(adjusted, digits);
}

//+------------------------------------------------------------------+
//| 成行で建てる                                                     |
//|                                                                  |
//| 損切りは注文に付ける（サーバー側）。EA がティックを監視せずに済み|
//| 「判定は確定足のみ」と整合し、EA が止まっても効く。σ は建玉時の |
//| 値で固定する（変動する σ で動かすとトレーリングになり別のルール |
//| になってしまう）。                                               |
//+------------------------------------------------------------------+
void OpenMarket(const int dir, const double &close[])
{
   double sl = 0.0;

   if(InpR1_UseSL)
   {
      SBValues v;
      if(!SB_Calc(close, 1, InpR1_Period, v))
      {
         Print("損切り幅を出せなかったため見送りました（σ が計算できない）");
         return;
      }

      const double entry = (dir > 0) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                     : SymbolInfoDouble(_Symbol, SYMBOL_BID);
      const double dist  = InpR1_SLSigma * v.sigma;

      bool widened = false;
      sl = NormalizeStopLevel(dir, (dir > 0) ? entry - dist : entry + dist, widened);
      if(widened)
         g_cntWidened++;
   }

   const string label = (dir > 0) ? "R1 買い" : "R1 売り";
   const bool   sent  = (dir > 0)
                        ? g_trade.Buy (InpLots, _Symbol, 0.0, sl, 0.0, label)
                        : g_trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, label);

   ReportTradeResult(label, sent);

   if(!sent || !IsFilled())
      return;

   g_barsHeld = 0;

   g_openRow.dir        = dir;
   g_openRow.openTime   = TimeCurrent();
   g_openRow.openPrice  = g_trade.ResultPrice();
   g_openRow.openSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_hasOpenRow         = true;
}

//+------------------------------------------------------------------+
//| 1取引ぶんの記録を確定させる                                      |
//+------------------------------------------------------------------+
void RecordTrade(const double closePrice, const string reason)
{
   if(!g_hasOpenRow)
      return;

   g_openRow.closeTime   = TimeCurrent();
   g_openRow.closePrice  = closePrice;
   g_openRow.closeSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_openRow.barsHeld    = g_barsHeld;
   g_openRow.reason      = reason;

   const int n = ArraySize(g_rows);
   ArrayResize(g_rows, n + 1);
   g_rows[n] = g_openRow;

   g_hasOpenRow = false;
}

//+------------------------------------------------------------------+
//| 決済する。約定できたときだけ true                                |
//|                                                                  |
//| 失敗時に状態をリセットすると、建玉が残ったまま保有本数の数えが   |
//| 途切れる。成功したときだけ戻す。                                 |
//+------------------------------------------------------------------+
bool ClosePosition(const string reason)
{
   const bool sent = g_trade.PositionClose(g_posTicket);
   ReportTradeResult(StringFormat("決済（%s・保有 %d 本）", reason, g_barsHeld), sent);

   if(!sent || !IsFilled())
      return false;

   RecordTrade(g_trade.ResultPrice(), reason);

   g_posTicket = 0;
   g_barsHeld  = 0;
   return true;
}

//+------------------------------------------------------------------+
//| 直前の取引要求が約定したか                                       |
//+------------------------------------------------------------------+
bool IsFilled()
{
   const uint retcode = g_trade.ResultRetcode();
   return (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| 取引要求の結果を記録する                                         |
//|                                                                  |
//| CTrade の戻り値は「要求をサーバーへ送れたか」しか示さない。実際の|
//| 約定可否は ResultRetcode() で判別する必要がある。ここを見ないと  |
//| 「注文したつもりで1件も建っていない」状態に気づけない。          |
//+------------------------------------------------------------------+
void ReportTradeResult(const string action, const bool sent)
{
   const uint retcode = g_trade.ResultRetcode();

   if(!sent)
   {
      PrintFormat("EaSpanBollinger: %s の要求送信に失敗 (retcode=%u, %s, error=%d)",
                  action, retcode, g_trade.ResultRetcodeDescription(), GetLastError());
      return;
   }

   if(!IsFilled())
   {
      PrintFormat("EaSpanBollinger: %s が約定しませんでした (retcode=%u, %s)",
                  action, retcode, g_trade.ResultRetcodeDescription());
      return;
   }

   PrintFormat("EaSpanBollinger: %s (価格 %.*f)",
               action, _Digits, g_trade.ResultPrice());
}
//+------------------------------------------------------------------+
