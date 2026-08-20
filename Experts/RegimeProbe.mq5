//+------------------------------------------------------------------+
//| RegimeProbe.mq5                                                  |
//| 相場つき（トレンド／レンジ）の実測ツール。売買はしない          |
//|                                                                  |
//| 「どの年がトレンドで、どの年がレンジだったか」を記憶や印象では  |
//| なく数字で確定させる。EA の年別成績と並べると、利益がトレンド    |
//| 相場に偏っているのかが直接読める。                               |
//|                                                                  |
//| あわせて、時間足ごとに**何年まで遡れるか**も出す。学習期間を     |
//| 延ばせるかどうかの判断に使う。                                   |
//|                                                                  |
//| 戦略の検証ではないため、docs/backtest_design.md の「検証用は     |
//| 2〜3回まで」という使用回数を消費しない。                         |
//|                                                                  |
//| ■ 走らせ方は2通り。どちらでも同じ CSV が出る                     |
//|   1) チャートに載せる … 載せた時点で測って終わる。外してよい     |
//|   2) ストラテジーテスター … テストが終わった時点で測る。         |
//|      時間足は日足、モデルは「始値のみ」で足りる（値動きの中身は  |
//|      使わないため）。コマンドラインから流すのはこちら。          |
//|                                                                  |
//| ■ トレンドとレンジをどう分けるか                                 |
//|   **効率比**（その期間の正味の値動き ÷ 日々の値動きの合計）で    |
//|   測る。1に近いほど一直線に動いた（＝トレンド）、0に近いほど     |
//|   行って戻ってを繰り返した（＝レンジ）。                         |
//|                                                                  |
//|   値幅の大きさでは分けない。**コロナのような急落と急反発は、    |
//|   値幅が大きくても行って戻っているのでトレンドではない。**       |
//|                                                                  |
//|   計算は日足の終値で行う。刻みを細かくすると値動きの合計だけが  |
//|   増えて効率比が下がるため、**年どうし・月どうしの比較にのみ    |
//|   使うこと**（絶対値に意味は無い）。                             |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property version   "1.02"
#property strict

input string InpCsvPrefix = "regime";   // CSV のファイル名プレフィックス

//--- 集計枠。1970年〜2039年
#define YEAR_BASE   1970
#define YEAR_SLOTS  70
#define MONTH_SLOTS (YEAR_SLOTS * 12)

//+------------------------------------------------------------------+
//| 1区間（1年ぶん・1ヶ月ぶん）の集計                                |
//+------------------------------------------------------------------+
struct RegimeStat
{
   int      bars;       // 日足の本数
   double   open;       // 最初の日の始値
   double   firstClose; // 最初の日の終値（効率比の起点。下記）
   double   close;      // 最後の日の終値
   double   high;       // 期間中の最高値
   double   low;        // 期間中の最安値
   double   path;       // 終値の変化の絶対値を足し上げたもの（＝歩いた距離）
   double   rangeSum;   // 日々の高安幅の合計（1日あたりの値動きを出す用）
   datetime firstTime;
   datetime lastTime;
};

RegimeStat g_year[YEAR_SLOTS];
RegimeStat g_month[MONTH_SLOTS];

//+------------------------------------------------------------------+
//| 日足1本を集計へ足す                                              |
//|                                                                  |
//| 歩いた距離は**その区間の中だけ**で数える。区間をまたぐ変化を     |
//| 入れると、1月の距離に前年12月からの動きが混ざる。                |
//+------------------------------------------------------------------+
void AddBar(RegimeStat &s, const MqlRates &r)
{
   if(s.bars == 0)
   {
      s.open       = r.open;
      s.firstClose = r.close;
      s.high       = r.high;
      s.low        = r.low;
      s.firstTime  = r.time;
   }
   else
   {
      if(r.high > s.high) s.high = r.high;
      if(r.low  < s.low)  s.low  = r.low;
      s.path += MathAbs(r.close - s.close);
   }

   s.close     = r.close;
   s.lastTime  = r.time;
   s.rangeSum += (r.high - r.low);
   s.bars++;
}

//+------------------------------------------------------------------+
//| 効率比 — 正味の値動き ÷ 歩いた距離                               |
//|                                                                  |
//| **分子の起点は最初の日の「終値」で、始値ではない。** 歩いた距離を |
//| 終値どうしの差で足し上げているため、始値を起点にすると分子だけが  |
//| 1日ぶん長い区間を測ることになり、初日の始値と終値が離れていると    |
//| 効率比が 1 を超える。日数の少ない月別の集計で特に効く。            |
//|                                                                  |
//| 歩いた距離が 0（＝日足1本しか無い）のときは求められないので -1。 |
//+------------------------------------------------------------------+
double EfficiencyRatio(const RegimeStat &s)
{
   if(s.bars < 2 || s.path <= 0.0) return -1.0;
   return MathAbs(s.close - s.firstClose) / s.path;
}

//+------------------------------------------------------------------+
//| 時間足の名前                                                     |
//+------------------------------------------------------------------+
string TfName(const ENUM_TIMEFRAMES tf)
{
   switch(tf)
   {
      case PERIOD_M1:  return "1分";
      case PERIOD_M5:  return "5分";
      case PERIOD_M15: return "15分";
      case PERIOD_M30: return "30分";
      case PERIOD_H1:  return "1時間";
      case PERIOD_H4:  return "4時間";
      case PERIOD_D1:  return "日足";
      case PERIOD_W1:  return "週足";
   }
   return EnumToString(tf);
}

//+------------------------------------------------------------------+
//| 履歴の読み込みを待つ                                             |
//|                                                                  |
//| MT5 はサーバーから非同期で落としてくるため、最初の要求はほぼ     |
//| 必ず空で返る。**空を「データ無し」と読むと、実際には遡れるのに   |
//| 遡れないと結論してしまう。** 落ち終わるまで繰り返し要求する。    |
//+------------------------------------------------------------------+
bool WaitSeries(const ENUM_TIMEFRAMES tf, const int waitSeconds)
{
   MqlRates tmp[];
   for(int i = 0; i < waitSeconds * 2; i++)
   {
      if(CopyRates(_Symbol, tf, 0, 2, tmp) > 0
         && SeriesInfoInteger(_Symbol, tf, SERIES_SYNCHRONIZED))
         return true;
      Sleep(500);
   }
   return false;
}

//+------------------------------------------------------------------+
//| 時間足ごとに何年まで遡れるか                                     |
//|                                                                  |
//| テスターの中ではテスト期間の値しか返らないため出さない。         |
//+------------------------------------------------------------------+
void ReportAvailability()
{
   ENUM_TIMEFRAMES tfs[] = {PERIOD_M1, PERIOD_M5, PERIOD_M15, PERIOD_M30,
                            PERIOD_H1, PERIOD_H4, PERIOD_D1, PERIOD_W1};

   Print("=== 時間足ごとに遡れる範囲 ===");
   Print("時間足   サーバーが持つ最古   手元にある最古     本数");

   for(int i = 0; i < ArraySize(tfs); i++)
   {
      const ENUM_TIMEFRAMES tf = tfs[i];
      WaitSeries(tf, 15);

      const datetime server = (datetime)SeriesInfoInteger(_Symbol, tf, SERIES_SERVER_FIRSTDATE);
      const datetime local  = (datetime)SeriesInfoInteger(_Symbol, tf, SERIES_FIRSTDATE);
      const long     bars   = SeriesInfoInteger(_Symbol, tf, SERIES_BARS_COUNT);

      PrintFormat("%-8s %-20s %-18s %d",
                  TfName(tf),
                  server > 0 ? TimeToString(server, TIME_DATE) : "（取得できず）",
                  local  > 0 ? TimeToString(local,  TIME_DATE) : "（取得できず）",
                  bars);
   }
   Print("「サーバーが持つ最古」がそのまま遡れる限界。手元が短い場合はチャートを");
   Print("その時間足にして左へスクロールすると落ちてくる。");
}

//+------------------------------------------------------------------+
//| CSV を1本書く                                                    |
//+------------------------------------------------------------------+
bool WriteCsv(const string name, const bool monthly)
{
   const int fh = FileOpen(name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, ',');
   if(fh == INVALID_HANDLE)
   {
      PrintFormat("CSV を開けませんでした（%s / エラー %d）", name, GetLastError());
      return false;
   }

   FileWrite(fh, "period", "bars", "first", "last", "open", "close",
             "high", "low", "net", "net_pct", "high_low", "path",
             "efficiency_ratio", "avg_daily_range");

   const int slots = monthly ? MONTH_SLOTS : YEAR_SLOTS;
   for(int i = 0; i < slots; i++)
   {
      RegimeStat s = monthly ? g_month[i] : g_year[i];
      if(s.bars == 0) continue;

      const string label = monthly
         ? StringFormat("%d-%02d", YEAR_BASE + i / 12, (i % 12) + 1)
         : StringFormat("%d", YEAR_BASE + i);

      FileWrite(fh, label, s.bars,
                TimeToString(s.firstTime, TIME_DATE),
                TimeToString(s.lastTime,  TIME_DATE),
                DoubleToString(s.open,  _Digits),
                DoubleToString(s.close, _Digits),
                DoubleToString(s.high,  _Digits),
                DoubleToString(s.low,   _Digits),
                DoubleToString(s.close - s.open, _Digits),
                DoubleToString(100.0 * (s.close - s.open) / s.open, 2),
                DoubleToString(s.high - s.low, _Digits),
                DoubleToString(s.path, _Digits),
                DoubleToString(EfficiencyRatio(s), 4),
                DoubleToString(s.rangeSum / s.bars, _Digits));
   }

   FileClose(fh);
   return true;
}

//+------------------------------------------------------------------+
//| 計測本体                                                         |
//|                                                                  |
//| 日足を丸ごと読んで年別・月別に畳む。テスターの中では**テストが   |
//| 終わった時点**で呼ぶこと。開始時点では、まだテスト期間ぶんの足が |
//| 供給されていない。                                               |
//+------------------------------------------------------------------+
void Measure()
{
   PrintFormat("=== 相場つきの実測: %s ===", _Symbol);

   // 形成中の日足は終値・高値・安値が確定していない。入れてしまうと、
   // 走らせた時刻によって当月・当年の値が変わる。現在の足の1秒手前で
   // 切って締め出す。
   const datetime current = iTime(_Symbol, PERIOD_D1, 0);
   if(current <= 0)
   {
      Print("日足の時刻を取得できませんでした");
      return;
   }

   MqlRates rates[];
   const int n = CopyRates(_Symbol, PERIOD_D1, D'1970.01.01', current - 1, rates);
   if(n <= 0)
   {
      PrintFormat("日足を読めませんでした（エラー %d）", GetLastError());
      return;
   }

   for(int i = 0; i < n; i++)
   {
      MqlDateTime dt;
      TimeToStruct(rates[i].time, dt);

      const int yi = dt.year - YEAR_BASE;
      if(yi < 0 || yi >= YEAR_SLOTS) continue;

      AddBar(g_year[yi],  rates[i]);
      AddBar(g_month[yi * 12 + (dt.mon - 1)], rates[i]);
   }

   Print("");
   PrintFormat("=== 年別（日足 %d 本 / %s 〜 %s）===",
               n, TimeToString(rates[0].time, TIME_DATE),
               TimeToString(rates[n - 1].time, TIME_DATE));
   Print("年     日数   始値    終値     変化      値幅   1日平均  効率比");

   for(int i = 0; i < YEAR_SLOTS; i++)
   {
      if(g_year[i].bars == 0) continue;
      const RegimeStat s = g_year[i];
      PrintFormat("%d %5d %8s %8s %+8s %9s %8s %7s",
                  YEAR_BASE + i, s.bars,
                  DoubleToString(s.open,  3),
                  DoubleToString(s.close, 3),
                  DoubleToString(s.close - s.open, 2),
                  DoubleToString(s.high - s.low, 2),
                  DoubleToString(s.rangeSum / s.bars, 3),
                  DoubleToString(EfficiencyRatio(s), 4));
   }
   Print("効率比が大きい年ほど一直線に動いた（トレンド）。小さい年は行って戻った（レンジ）。");

   const string yearly  = InpCsvPrefix + "_yearly.csv";
   const string monthly = InpCsvPrefix + "_monthly.csv";
   const bool okY = WriteCsv(yearly,  false);
   const bool okM = WriteCsv(monthly, true);

   if(okY && okM)
   {
      Print("");
      PrintFormat("CSV を書きました（共有フォルダ Common\\Files）: %s / %s", yearly, monthly);
   }
}

//+------------------------------------------------------------------+
int OnInit()
{
   // テスターでは、この時点ではまだ足が供給されていない。測るのは
   // テストが終わった後（OnDeinit）。
   if(MQLInfoInteger(MQL_TESTER)) return INIT_SUCCEEDED;

   if(!WaitSeries(PERIOD_D1, 30))
   {
      Print("日足の履歴を取得できませんでした。チャートを日足にして左へスクロールし、");
      Print("読み込みが終わってから載せ直してください");
      return INIT_FAILED;
   }

   ReportAvailability();
   Measure();
   Print("計測は完了しました。チャートから外して構いません。");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(MQLInfoInteger(MQL_TESTER)) Measure();
}

//+------------------------------------------------------------------+
void OnTick()
{
   // 値動きは使わない。テスターに最後まで走らせるためだけの空実装
}
