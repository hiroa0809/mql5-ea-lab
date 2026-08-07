//+------------------------------------------------------------------+
//| SpreadProbe.mq5                                                  |
//| N0: 往復コストの実測ツール（売買ロジックを持たない使い捨て）     |
//|                                                                  |
//| 「1トレードを完結させると実際にいくら取られるか」だけを測る。    |
//| 戦略の検証ではないため IS / 検証用 / 最終OOS の使用回数を消費    |
//| しない（docs/backtest_design.md の予算とは無関係）。             |
//|                                                                  |
//| 計測は2方式。値が一致すれば測定自体の正しさも確認できる。        |
//|   方式A … ティックごとに ask-bid を採取し分布と時間帯別を出す。  |
//|            全期間を隙間なくカバーできる。                        |
//|   方式B … 成行で建てて即座に決済し、確定した損失を読む。         |
//|            手数料込みの実額が出る（スプレッドはコストの全部      |
//|            ではない）。                                          |
//|                                                                  |
//| 銘柄・時間足・期間はストラテジーテスター側の指定に従う。         |
//|                                                                  |
//| 出力は共有フォルダ（Common\Files）へ CSV 2本。テスターの         |
//| エージェント配下だと探しにくいため共有側へ出す。                 |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- 計測方式
input bool   InpSampleTicks       = true;   // 方式A: ティック採取(分布・時間帯別)
input bool   InpProbeTrades       = true;   // 方式B: 即時オープン&クローズ(実額)

//--- 方式B の設定
input int    InpProbeIntervalBars = 137;    // 方式B: 何本ごとに1回計測するか
input int    InpMaxProbes         = 5000;   // 方式B: 計測回数の上限
input double InpLots              = 0.01;   // 方式B: ロット数
input ulong  InpMagic             = 20260807; // マジックナンバー
input ulong  InpSlippage          = 200;    // 許容スリッページ(points)

//--- 出力
input string InpCsvPrefix         = "n0_spread"; // CSV のファイル名プレフィックス

//--- スプレッドのヒストグラム。0〜1000 point を数え、超過は別途カウントする
#define SPREAD_BUCKETS 1001
#define HOUR_SLOTS     24

//--- 月別集計の枠。2000年1月〜2049年12月
#define MONTH_BASE_YEAR 2000
#define MONTH_SLOTS     600

//--- グローバル
CTrade  g_trade;
bool    g_initialized = false;   // OnInit が成功したか（OnDeinit の出力可否に使う）
double  g_point       = 0.0;
double  g_pip         = 0.0;      // 3/5桁は 10point、2/4桁は 1point
int     g_digits      = 0;

//--- 方式A
long    g_hist[HOUR_SLOTS * SPREAD_BUCKETS];  // 時間帯 × スプレッド(point)
long    g_hour_count[HOUR_SLOTS];
long    g_tick_total  = 0;
long    g_over_count  = 0;        // 1000point を超えたティック数
long    g_max_spread  = 0;
long    g_min_spread  = -1;
long    g_last_digit[10];         // bid の最下位桁の分布（見かけの桁数の検証用）

//--- 方式A（月別）
//    期間の一部にだけ実ティックが無い場合、全体の distinct_spread_values は
//    1 にならないため model_check の警告が出ない。そのまま平均すると合成
//    部分（固定スプレッド）に引きずられてコストを過小評価する。月別に見て
//    min == max の月を洗い出せば、実ティックの境界がその場で分かる。
long     g_month_count[MONTH_SLOTS];
long     g_month_sum[MONTH_SLOTS];
long     g_month_min[MONTH_SLOTS];
long     g_month_max[MONTH_SLOTS];
datetime g_first_tick = 0;
datetime g_last_tick  = 0;
string   g_run_stamp  = "";      // 実行ごとに一意。CSV の上書き事故を防ぐ

//--- 方式B
int      g_bar_count   = 0;
int      g_probe_count = 0;
int      g_probe_fail  = 0;
double   g_cost_pts_sum   = 0.0;
double   g_cost_money_sum = 0.0;
double   g_commission_sum = 0.0;
int      g_csv_trades  = INVALID_HANDLE;
datetime g_last_bar_time = 0;

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
int OnInit(void)
  {
   //--- 方式B は成行注文を出す。実口座で誤って起動すると実弾が飛ぶため
   //    テスター以外では起動させない。
   if(!MQLInfoInteger(MQL_TESTER))
     {
      Print("SpreadProbe: これは計測専用ツールです。ストラテジーテスター以外では起動できません。");
      return(INIT_FAILED);
     }

   if(!InpSampleTicks && !InpProbeTrades)
     {
      Print("SpreadProbe: 方式A・方式Bの少なくとも一方を有効にしてください。");
      return(INIT_PARAMETERS_INCORRECT);
     }

   if(InpProbeTrades && InpProbeIntervalBars <= 0)
     {
      Print("SpreadProbe: 計測間隔は1以上にしてください。");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   //--- g_pip は g_point から作るため、検査を算出より前に置く
   if(g_point <= 0.0)
     {
      Print("SpreadProbe: SYMBOL_POINT を取得できませんでした。");
      return(INIT_FAILED);
     }

   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pip    = (g_digits == 3 || g_digits == 5) ? g_point * 10.0 : g_point;

   //--- CSV 名を作る前に確定させる（trades と summary で同じ値を使う）
   g_run_stamp = MakeRunStamp();

   ArrayInitialize(g_hist, 0);
   ArrayInitialize(g_hour_count, 0);
   ArrayInitialize(g_last_digit, 0);
   ArrayInitialize(g_month_count, 0);
   ArrayInitialize(g_month_sum, 0);
   ArrayInitialize(g_month_min, -1);   // -1 は未観測を表す
   ArrayInitialize(g_month_max, -1);

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippage);
   g_trade.SetTypeFillingBySymbol(_Symbol);

   if(InpProbeTrades && !OpenTradesCsv())
      return(INIT_FAILED);

   //--- 単位換算の取り違えは前回の破棄の原因そのもの。前提を先に出す。
   PrintFormat("SpreadProbe: %s %s digits=%d point=%s 1pips=%spoint tick_size=%s tick_value=%s",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), g_digits,
               DoubleToString(g_point, 8),
               DoubleToString(g_pip / g_point, 1),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8),
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE), 5));

   g_initialized = true;
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| ティックごとの処理                                               |
//+------------------------------------------------------------------+
void OnTick(void)
  {
   if(InpSampleTicks)
      SampleSpread();

   if(!InpProbeTrades)
      return;

   if(!IsNewBar())
      return;

   g_bar_count++;

   if(g_probe_count >= InpMaxProbes)
      return;

   //--- 計測間隔に素数を勧める理由: M5 の1日は 288 本。144 のような
   //    約数にすると計測がいつも同じ時刻に落ち、時間帯の偏りが取れない。
   if(g_bar_count % InpProbeIntervalBars != 0)
      return;

   RunProbe();
  }

//+------------------------------------------------------------------+
//| 方式A: 現在のスプレッドを採取する                                |
//|                                                                  |
//| SymbolInfoInteger(SYMBOL_SPREAD) ではなく ask-bid から求める。   |
//| 実際に約定価格へ効くのは気配値そのものであり、整数化された        |
//| プロパティより直接的なため。                                     |
//+------------------------------------------------------------------+
void SampleSpread(void)
  {
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(ask <= 0.0 || bid <= 0.0)
      return;

   long pts = (long)MathRound((ask - bid) / g_point);
   if(pts < 0)
      return;

   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int hour = dt.hour;
   if(hour < 0 || hour >= HOUR_SLOTS)
      return;

   g_tick_total++;
   g_hour_count[hour]++;

   if(g_first_tick == 0)
      g_first_tick = now;
   g_last_tick = now;

   if(pts > g_max_spread)
      g_max_spread = pts;
   if(g_min_spread < 0 || pts < g_min_spread)
      g_min_spread = pts;

   //--- 月別。クランプ前の実値で集計する
   int slot = MonthSlot(dt.year, dt.mon);
   if(slot >= 0)
     {
      g_month_count[slot]++;
      g_month_sum[slot] += pts;

      if(g_month_min[slot] < 0 || pts < g_month_min[slot])
         g_month_min[slot] = pts;
      if(pts > g_month_max[slot])
         g_month_max[slot] = pts;
     }

   //--- 上限超過は最終バケットへ寄せる。分位点が僅かに歪むため
   //    超過件数と最大値を別に持ち、要約で併記する。
   if(pts >= SPREAD_BUCKETS)
     {
      g_over_count++;
      pts = SPREAD_BUCKETS - 1;
     }

   g_hist[hour * SPREAD_BUCKETS + (int)pts]++;

   //--- bid の最下位桁。digits が 3 でも常に 0 なら実質 2 桁で、
   //    pips 換算が 1 桁ずれる。前回の 10 倍誤差はここを見れば防げた。
   long units = (long)MathRound(bid / g_point);
   g_last_digit[(int)(units % 10)]++;
  }

//+------------------------------------------------------------------+
//| 年月から月別集計のスロット番号を返す（範囲外は -1）              |
//+------------------------------------------------------------------+
int MonthSlot(const int year, const int mon)
  {
   if(mon < 1 || mon > 12)
      return(-1);

   int slot = (year - MONTH_BASE_YEAR) * 12 + (mon - 1);
   if(slot < 0 || slot >= MONTH_SLOTS)
      return(-1);

   return(slot);
  }

//+------------------------------------------------------------------+
//| 方式B: 成行で建てて即座に決済し、確定した往復コストを読む        |
//+------------------------------------------------------------------+
void RunProbe(void)
  {
   //--- 既存の建玉が残っている＝前回の決済が通っていない。黙って見送ると
   //    以降の計測が全て素通りし、「なぜ件数が少ないのか」が要約から読めない
   //    （lessons_learned.md の「無言で取引0」と同じ形）。失敗として数え、
   //    再決済を試みてから戻る。
   ulong stale = FindOurPosition();
   if(stale != 0)
     {
      g_probe_fail++;
      PrintFormat("SpreadProbe: 前回の建玉 #%I64u が残っています。再決済を試みます。", stale);
      ReportTradeResult("PositionClose(残留)", g_trade.PositionClose(stale));
      return;
     }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   quoted_pts = (long)MathRound((ask - bid) / g_point);

   if(!ReportTradeResult("Buy", g_trade.Buy(InpLots, _Symbol)))
     {
      g_probe_fail++;
      return;
     }

   ulong ticket = FindOurPosition();
   if(ticket == 0)
     {
      Print("SpreadProbe: 建玉を特定できませんでした。");
      g_probe_fail++;
      return;
     }

   //--- 決済後に履歴を引くための識別子。決済すると建玉は消えるため先に取る。
   long pos_id = 0;
   if(PositionSelectByTicket(ticket))
      pos_id = PositionGetInteger(POSITION_IDENTIFIER);

   //--- ヘッジ口座では PositionClose(_Symbol) が別の建玉を閉じうる。
   //    チケット指定で閉じる（PR #1 の指摘）。
   if(!ReportTradeResult("PositionClose", g_trade.PositionClose(ticket)))
     {
      g_probe_fail++;
      return;
     }

   RecordProbeResult(pos_id, quoted_pts);
  }

//+------------------------------------------------------------------+
//| 決済済みポジションの実額を履歴から取り出して記録する             |
//|                                                                  |
//| 損益・手数料・スワップを合算する。往復スプレッドはコストの       |
//| 全部ではないため、手数料を分けて持つ。                           |
//+------------------------------------------------------------------+
void RecordProbeResult(const long pos_id, const long quoted_pts)
  {
   if(pos_id == 0 || !HistorySelectByPosition(pos_id))
     {
      Print("SpreadProbe: 約定履歴を取得できませんでした。");
      g_probe_fail++;
      return;
     }

   double profit     = 0.0;
   double commission  = 0.0;
   double swap       = 0.0;
   double price_in   = 0.0;
   double price_out  = 0.0;
   datetime time_in  = 0;

   //--- 分割約定に備えて出来高で加重する。単純に上書きすると最後の約定価格
   //    だけが残り、黙って誤った往復コストを出す。0.01 ロットではまず起きない
   //    が、InpLots は input で変えられる。
   double vol_in     = 0.0;
   double vol_out    = 0.0;
   double px_vol_in  = 0.0;
   double px_vol_out = 0.0;

   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;

      profit     += HistoryDealGetDouble(deal, DEAL_PROFIT);
      commission += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      swap       += HistoryDealGetDouble(deal, DEAL_SWAP);

      double price  = HistoryDealGetDouble(deal, DEAL_PRICE);
      double volume = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(volume <= 0.0)
         continue;

      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
        {
         px_vol_in += price * volume;
         vol_in    += volume;

         //--- 分割約定なら最初の約定時刻を計測時刻とする
         datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         if(time_in == 0 || t < time_in)
            time_in = t;
        }
      else
         if(entry == DEAL_ENTRY_OUT)
           {
            px_vol_out += price * volume;
            vol_out    += volume;
           }
     }

   if(vol_in <= 0.0 || vol_out <= 0.0)
     {
      Print("SpreadProbe: 約定履歴に出来高がありませんでした。");
      g_probe_fail++;
      return;
     }

   price_in  = px_vol_in / vol_in;
   price_out = px_vol_out / vol_out;

   if(price_in <= 0.0 || price_out <= 0.0)
     {
      Print("SpreadProbe: 約定価格を取得できませんでした。");
      g_probe_fail++;
      return;
     }

   //--- 買いは ask で建てて bid で決済するため、価格差がそのまま往復コスト
   double cost_pts   = (price_in - price_out) / g_point;
   double cost_money = -(profit + commission + swap);   // 損失を正のコストとして扱う

   g_probe_count++;
   g_cost_pts_sum   += cost_pts;
   g_cost_money_sum += cost_money;
   g_commission_sum += commission;

   if(g_csv_trades != INVALID_HANDLE)
      FileWrite(g_csv_trades,
                TimeToString(time_in, TIME_DATE | TIME_MINUTES | TIME_SECONDS),
                (string)quoted_pts,
                DoubleToString(price_in, g_digits),
                DoubleToString(price_out, g_digits),
                DoubleToString(cost_pts, 1),
                DoubleToString(cost_pts * g_point / g_pip, 2),
                DoubleToString(commission, 2),
                DoubleToString(swap, 2),
                DoubleToString(profit, 2),
                DoubleToString(cost_money, 2));
  }

//+------------------------------------------------------------------+
//| 自分の建玉のチケットを返す（無ければ 0）                         |
//+------------------------------------------------------------------+
ulong FindOurPosition(void)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;

      if(PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == (long)InpMagic)
         return(ticket);
     }
   return(0);
  }

//+------------------------------------------------------------------+
//| 取引要求の結果を確認する                                         |
//|                                                                  |
//| 戻り値は要求送信の可否のみ。約定可否は ResultRetcode() で判別    |
//| する（PR #1 の指摘）。                                           |
//+------------------------------------------------------------------+
bool ReportTradeResult(const string action, const bool sent)
  {
   uint retcode = g_trade.ResultRetcode();

   if(!sent)
     {
      PrintFormat("SpreadProbe: %s の要求送信に失敗 (retcode=%u, %s, error=%d)",
                  action, retcode, g_trade.ResultRetcodeDescription(), GetLastError());
      return(false);
     }

   if(retcode != TRADE_RETCODE_DONE && retcode != TRADE_RETCODE_PLACED)
     {
      PrintFormat("SpreadProbe: %s が約定しませんでした (retcode=%u, %s)",
                  action, retcode, g_trade.ResultRetcodeDescription());
      return(false);
     }

   return(true);
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
//| CSV のファイル名を作る                                           |
//|                                                                  |
//| 銘柄・時間足に加えて実行時刻を入れる。同じ銘柄・時間足で期間や   |
//| 遅延設定を変えて測り直すことが実際に頻発し、固定名では前の結果が |
//| 黙って消える（2026-08-07 に2度発生）。入力パラメータを毎回変える |
//| 運用に頼らず、既定で安全側にする。                               |
//|                                                                  |
//| 測定条件そのものは要約 CSV の first_tick / last_tick に入るため、|
//| ファイル名で期間を表す必要はない。                               |
//+------------------------------------------------------------------+
string CsvName(const string kind)
  {
   return(StringFormat("%s_%s_%s_%s_%s.csv", InpCsvPrefix, _Symbol,
                       EnumToString((ENUM_TIMEFRAMES)_Period), g_run_stamp, kind));
  }

//+------------------------------------------------------------------+
//| 実行ごとに一意な文字列を作る                                     |
//|                                                                  |
//| テスター内では TimeLocal() が**シミュレーション時刻**を返すため、 |
//| ここで得られるのはテスト開始日になる。期間の識別には都合が良い    |
//| 一方、同じ期間で遅延設定だけ変えて測り直すと衝突して前の結果が    |
//| 消える（2026-08-07 に実際に発生）。実時間由来の GetTickCount()   |
//| を足して一意性を担保する。                                       |
//+------------------------------------------------------------------+
string MakeRunStamp(void)
  {
   string s = TimeToString(TimeLocal(), TIME_DATE | TIME_MINUTES);
   StringReplace(s, ".", "");
   StringReplace(s, ":", "");
   StringReplace(s, " ", "_");

   return(StringFormat("%s_%06u", s, (uint)(GetTickCount() % 1000000)));
  }

//+------------------------------------------------------------------+
//| 方式B の CSV を開く                                              |
//+------------------------------------------------------------------+
bool OpenTradesCsv(void)
  {
   string name = CsvName("trades");

   g_csv_trades = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(g_csv_trades == INVALID_HANDLE)
     {
      PrintFormat("SpreadProbe: %s を開けませんでした (error=%d)", name, GetLastError());
      return(false);
     }

   FileWrite(g_csv_trades,
             "time", "quoted_spread_pts", "price_in", "price_out",
             "cost_pts", "cost_pips", "commission", "swap", "profit", "cost_money");
   return(true);
  }

//+------------------------------------------------------------------+
//| ヒストグラムから分位点を求める（hour < 0 で全時間帯）            |
//+------------------------------------------------------------------+
long Percentile(const int hour, const double q)
  {
   long total = 0;
   for(int b = 0; b < SPREAD_BUCKETS; b++)
      total += BucketCount(hour, b);

   if(total <= 0)
      return(-1);

   long threshold = (long)MathCeil(total * q);
   if(threshold < 1)
      threshold = 1;

   long cumulative = 0;
   for(int b = 0; b < SPREAD_BUCKETS; b++)
     {
      cumulative += BucketCount(hour, b);
      if(cumulative >= threshold)
         return(b);
     }

   return(SPREAD_BUCKETS - 1);
  }

//+------------------------------------------------------------------+
//| ヒストグラムの1バケットを読む（hour < 0 で全時間帯の合算）       |
//+------------------------------------------------------------------+
long BucketCount(const int hour, const int bucket)
  {
   if(hour >= 0)
      return(g_hist[hour * SPREAD_BUCKETS + bucket]);

   long sum = 0;
   for(int h = 0; h < HOUR_SLOTS; h++)
      sum += g_hist[h * SPREAD_BUCKETS + bucket];

   return(sum);
  }

//+------------------------------------------------------------------+
//| 終了処理: 要約をジャーナルと CSV へ出す                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_csv_trades != INVALID_HANDLE)
     {
      FileClose(g_csv_trades);
      g_csv_trades = INVALID_HANDLE;
     }

   //--- OnInit が INIT_FAILED を返しても OnDeinit は呼ばれる
   //    （DEINIT_REASON_INITFAILED）。素通しにすると、テスター外で
   //    誤起動しただけで前回の測定結果を空ファイルで上書きしてしまう。
   //    g_point が 0.0 のままゼロ除算にもなる。
   if(!g_initialized)
     {
      Print("SpreadProbe: 初期化に失敗したため要約を出力しません（既存の CSV は残します）。");
      return;
     }

   WriteSummary();
  }

//+------------------------------------------------------------------+
//| 要約の出力                                                       |
//+------------------------------------------------------------------+
void WriteSummary(void)
  {
   string name = CsvName("summary");
   int fh = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');

   if(fh == INVALID_HANDLE)
      PrintFormat("SpreadProbe: %s を開けませんでした (error=%d)", name, GetLastError());

   double pip_pts = g_pip / g_point;   // 1pips が何 point か

   //--- 前提
   PrintFormat("SpreadProbe [前提] %s %s digits=%d 1pips=%.0fpoint",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)_Period), g_digits, pip_pts);
   WriteRow(fh, "section", "symbol", _Symbol, "", "", "", "");
   WriteRow(fh, "section", "period", EnumToString((ENUM_TIMEFRAMES)_Period), "", "", "", "");
   WriteRow(fh, "section", "digits", (string)g_digits, "", "", "", "");
   WriteRow(fh, "section", "pips_in_points", DoubleToString(pip_pts, 0), "", "", "", "");

   //--- 観測した実データの範囲。後からファイルを見て計測期間が分かるようにする
   //    （テスターの指定期間ではなく、実際にティックが来た範囲）
   WriteRow(fh, "section", "first_tick",
            (g_first_tick == 0) ? "none" : TimeToString(g_first_tick, TIME_DATE | TIME_MINUTES),
            "", "", "", "");
   WriteRow(fh, "section", "last_tick",
            (g_last_tick == 0) ? "none" : TimeToString(g_last_tick, TIME_DATE | TIME_MINUTES),
            "", "", "", "");

   //--- 方式A
   if(InpSampleTicks && g_tick_total > 0)
     {
      long p50 = Percentile(-1, 0.50);
      long p90 = Percentile(-1, 0.90);
      long p99 = Percentile(-1, 0.99);

      PrintFormat("SpreadProbe [方式A] ticks=%I64d 中央値=%.1fpips p90=%.1fpips p99=%.1fpips 最小=%.1fpips 最大=%.1fpips 超過=%I64d",
                  g_tick_total, p50 / pip_pts, p90 / pip_pts, p99 / pip_pts,
                  g_min_spread / pip_pts, g_max_spread / pip_pts, g_over_count);

      WriteRow(fh, "tick_all", "count", (string)g_tick_total, "", "", "", "");
      WriteRow(fh, "tick_all", "median_pips", DoubleToString(p50 / pip_pts, 2), "", "", "", "");
      WriteRow(fh, "tick_all", "p90_pips",    DoubleToString(p90 / pip_pts, 2), "", "", "", "");
      WriteRow(fh, "tick_all", "p99_pips",    DoubleToString(p99 / pip_pts, 2), "", "", "", "");
      WriteRow(fh, "tick_all", "min_pips",    DoubleToString(g_min_spread / pip_pts, 2), "", "", "", "");
      WriteRow(fh, "tick_all", "max_pips",    DoubleToString(g_max_spread / pip_pts, 2), "", "", "", "");
      WriteRow(fh, "tick_all", "over_bucket_count", (string)g_over_count, "", "", "", "");

      //--- 時間帯別。R1 はボラティリティが立ち上がる瞬間に発火するため、
      //    全体平均ではなく発火しやすい時間帯の値で予算を組む。
      WriteRow(fh, "hour", "hour", "count", "median_pips", "p90_pips", "p99_pips", "");
      for(int h = 0; h < HOUR_SLOTS; h++)
        {
         if(g_hour_count[h] <= 0)
            continue;

         WriteRow(fh, "hour", (string)h, (string)g_hour_count[h],
                  DoubleToString(Percentile(h, 0.50) / pip_pts, 2),
                  DoubleToString(Percentile(h, 0.90) / pip_pts, 2),
                  DoubleToString(Percentile(h, 0.99) / pip_pts, 2), "");
        }

      //--- 月別。min == max の月は実ティックが無く合成データで埋められている。
      //    一部の月だけ合成でも全体の distinct_spread_values は 1 にならず
      //    警告が出ないため、境界はここで特定する。
      WriteRow(fh, "month", "month", "count", "mean_pips", "min_pips", "max_pips", "synthetic");
      int synthetic_months = 0;
      int observed_months  = 0;

      for(int s = 0; s < MONTH_SLOTS; s++)
        {
         if(g_month_count[s] <= 0)
            continue;

         observed_months++;

         double mean = (double)g_month_sum[s] / (double)g_month_count[s];
         bool   flat = (g_month_min[s] == g_month_max[s]);
         if(flat)
            synthetic_months++;

         WriteRow(fh, "month",
                  StringFormat("%04d-%02d", MONTH_BASE_YEAR + s / 12, (s % 12) + 1),
                  (string)g_month_count[s],
                  DoubleToString(mean / pip_pts, 2),
                  DoubleToString(g_month_min[s] / pip_pts, 2),
                  DoubleToString(g_month_max[s] / pip_pts, 2),
                  flat ? "YES" : "");
        }

      WriteRow(fh, "month_check", "observed_months",  (string)observed_months,  "", "", "", "");
      WriteRow(fh, "month_check", "synthetic_months", (string)synthetic_months, "", "", "", "");

      if(synthetic_months > 0)
         PrintFormat("SpreadProbe [警告] %d/%d ヶ月でスプレッドが一定でした。その月は実ティックが無く合成データの可能性が高いため、コストを過小評価します。要約 CSV の month 行（synthetic=YES）を確認してください。",
                     synthetic_months, observed_months);

      //--- 最下位桁の分布
      int distinct_digits = 0;
      for(int d = 0; d < 10; d++)
         if(g_last_digit[d] > 0)
            distinct_digits++;

      WriteRow(fh, "last_digit", "distinct_values", (string)distinct_digits, "", "", "", "");
      for(int d = 0; d < 10; d++)
         WriteRow(fh, "last_digit", (string)d, (string)g_last_digit[d], "", "", "", "");

      if(distinct_digits <= 1)
         Print("SpreadProbe [警告] bid の最下位桁が1種類しかありません。表示桁数より実質の刻みが粗い可能性があります（pips 換算が1桁ずれます）。");

      //--- モデルの妥当性。MQL5 にはティック生成モードを問い合わせる API が
      //    無いため、事前チェックではなく観測値から事後に判定する。
      int distinct_spreads = 0;
      for(int b = 0; b < SPREAD_BUCKETS; b++)
         if(BucketCount(-1, b) > 0)
            distinct_spreads++;

      WriteRow(fh, "model_check", "distinct_spread_values", (string)distinct_spreads, "", "", "", "");

      if(distinct_spreads <= 1)
         Print("SpreadProbe [警告] スプレッドが一定でした。固定スプレッドのモデルで走った可能性が高いため、「実際のティックに基づく全ティック」で再実行してください。");
     }

   //--- 方式B
   if(InpProbeTrades)
     {
      if(g_probe_count > 0)
        {
         double avg_pts   = g_cost_pts_sum / g_probe_count;
         double avg_money = g_cost_money_sum / g_probe_count;
         double avg_comm  = g_commission_sum / g_probe_count;

         PrintFormat("SpreadProbe [方式B] probes=%d 平均往復コスト=%.2fpips 平均実額=%.2f(通貨) うち手数料=%.2f 失敗=%d",
                     g_probe_count, avg_pts / pip_pts, avg_money, avg_comm, g_probe_fail);

         WriteRow(fh, "probe", "count", (string)g_probe_count, "", "", "", "");
         WriteRow(fh, "probe", "avg_cost_pips",  DoubleToString(avg_pts / pip_pts, 3), "", "", "", "");
         WriteRow(fh, "probe", "avg_cost_money", DoubleToString(avg_money, 4), "", "", "", "");
         WriteRow(fh, "probe", "avg_commission", DoubleToString(avg_comm, 4), "", "", "", "");
         WriteRow(fh, "probe", "fail_count",     (string)g_probe_fail, "", "", "", "");
        }
      else
         Print("SpreadProbe [方式B] 計測が1件も成立しませんでした。計測間隔・期間・約定条件を確認してください。");
     }

   if(fh != INVALID_HANDLE)
     {
      FileClose(fh);
      PrintFormat("SpreadProbe: CSV を共有フォルダ(Common\\Files)へ出力しました: %s / %s",
                  CsvName("trades"), CsvName("summary"));
     }
  }

//+------------------------------------------------------------------+
//| 要約 CSV の1行を書く                                             |
//+------------------------------------------------------------------+
void WriteRow(const int fh, const string section, const string key,
              const string v1, const string v2, const string v3,
              const string v4, const string v5)
  {
   if(fh == INVALID_HANDLE)
      return;

   FileWrite(fh, section, key, v1, v2, v3, v4, v5);
  }
//+------------------------------------------------------------------+
