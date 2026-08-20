//+------------------------------------------------------------------+
//| EaSpanModel.mq5                                                  |
//| スパンモデル単体の自動売買（ルール2）                            |
//|                                                                  |
//| エントリー条件は Indicators\SpanModel.mq5 が矢印を出す条件と      |
//| **完全に同じ**。判定は共通ファイル Include\Signals\SpanModel.mqh  |
//| の SM_Rule2 を呼ぶだけで、本ファイルは条件式を一切持たない。      |
//| 式を二重に書くと、片方だけ直したときに「チャートの矢印と EA の    |
//| 発注が合わない」という切り分け困難な状態になる。                  |
//|                                                                  |
//| 執行を1本ずらしている点だけが指標と違う（下記）。                 |
//|                                                                  |
//| ■ エントリー                                                     |
//|   条件が揃った足の **2本後の始値**で成行。通常の自動売買は「条件  |
//|   が揃った足の次の足の始値」だが、スパンモデルはレンジ相場で雲の  |
//|   色と値動きが逆に動くことがあるため、1本遅らせて入る。           |
//|   遅らせる本数は入力項目（1 にすると通常の次の足）。              |
//|                                                                  |
//| ■ 決済                                                           |
//|   雲の色が建玉と反対になった足の **2本後の始値**で成行。          |
//|   エントリーと同じ考え方で1本遅らせている。                       |
//|                                                                  |
//| 建玉は常に1つまで。雲の色が反転した足で反対のエントリー条件も     |
//| 揃っていれば、決済と新規建てが同じ足で起きる（ドテン）。          |
//|                                                                  |
//| 損切りは持たない。手仕舞いは雲の色の反転だけ                      |
//| （docs/implementation_design.md「損切りは既定 OFF」）。           |
//|                                                                  |
//| ■ テスターでの目視                                               |
//|   入力「チャートにスパンモデルを表示する」を入れておくと、視覚   |
//|   モードのテストで同じ設定の指標がチャートに出る。矢印と約定位置 |
//|   を並べて確かめられる（矢印は約定より手前に立つ）。             |
//|                                                                  |
//| 銘柄・時間足は入力にせず _Symbol / _Period を使う。テスターの     |
//| 設定がそのまま反映される（docs/implementation_design.md §1）。    |
//+------------------------------------------------------------------+
#property version   "1.00"
#property description "スパンモデル単体（ルール2）。指標の矢印と同じ条件で売買する"

#include <Trade\Trade.mqh>
#include <Signals\SpanModel.mqh>

//--- 指標 SpanModel.mq5 と同じ並び・同じ表示名。設定画面を見比べたときに
//--- 1行ずつ対応が取れるようにしてある。値も指標側と同じにすること。
input int  InpTenkan        = 9;      // 転換線の期間
input int  InpKijun         = 26;     // 基準線の期間
input int  InpSpanB         = 52;     // 赤スパンの期間
input int  InpLagBars       = 26;     // 遅行線の本数
input bool InpUseLagClose   = false;  // ②a 遅行スパンが重なる足の終値を抜けている
input bool InpUseLagHighLow = true;   // ②b 遅行スパンが重なる足の高値安値を抜けている
input bool InpUseLagCloud   = true;   // ②c 遅行スパンが重なる足の雲を抜けている
input bool InpUseClosePos   = true;   // ③終値と青スパンの位置関係を条件に入れる
input bool InpUseSlope      = false;  // ④長期スパンの傾きを条件に入れる
input int  InpSlopeBars     = 5;      // ④傾きを見る本数

//--- ここから下は EA だけが持つ項目（指標には無い）
//--- 「何本後」は条件が揃った足を 0 本目として数える。1 = 次の足の始値
//--- （通常の自動売買）、2 = そのさらに1本後の始値（既定）。
input int    InpEntryDelayBars = 2;          // エントリーを何本後の足の始値で出すか
input int    InpExitDelayBars  = 2;          // 決済を何本後の足の始値で出すか
input double InpLots           = 0.10;       // ロット
input long   InpMagic          = 20260819;   // マジックナンバー
input bool   InpPrintCounters  = true;       // 条件別の成立回数を出力する
input bool   InpShowIndicator  = true;       // チャートにスパンモデルを表示する

CTrade        g_trade;
SMRule2Params g_params;
int           g_needBars = 0;   // 1回の判定に必要な履歴の本数
datetime      g_lastBar  = 0;   // 最後に判定した足の時刻
int           g_smHandle = INVALID_HANDLE;   // 表示用に読み込んだ指標

//--- 診断用の計数。取引ゼロで終わったときに、どの条件で止まったのかを
//--- 切り分けるためだけのもの（docs/implementation_design.md §4）。
//--- ②③④は**雲が転換した足だけ**、その転換の向きについて数える。
//--- 転換しない足には向きが無く、「買いの②」も「売りの②」も定義でき
//--- ないため。設計書は「各条件を単独で数える」としているが、ルール2は
//--- ①が向きを決める引き金なので、ここだけは①の成立足に限る。
long g_cntFlip = 0, g_cntLag = 0, g_cntClosePos = 0, g_cntSlope = 0;
long g_cntBuySignal = 0, g_cntSellSignal = 0;
long g_cntEntry = 0, g_cntExit = 0, g_cntOrderFailed = 0;

//+------------------------------------------------------------------+
//| テスターのチャートに同じ設定のスパンモデルを載せる               |
//|                                                                  |
//| 矢印が出た足と、実際に建てた位置を目で突き合わせるため。指標へ渡 |
//| す引数は EA の入力と同じ順・同じ値にする。ずれると、EA が売買し  |
//| た条件とは違う条件の矢印を見比べることになる。                   |
//|                                                                  |
//| **矢印は約定より手前に立つ。** 指標は条件が揃った足に印を出し、   |
//| EA はその InpEntryDelayBars 本後の始値で建てるため。ずれて見える |
//| のが正常。                                                       |
//|                                                                  |
//| 視覚モードでないテスト（最適化を含む）では読み込まない。使わない |
//| 指標を毎足計算させると、そのぶんテストが遅くなるだけのため。      |
//+------------------------------------------------------------------+
void ShowIndicator()
{
   if(!InpShowIndicator) return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE)) return;

   // 本リポジトリは MT5 のデータフォルダへジャンクションで繋いでいるため
   // 指標は Indicators\mql5-ea-lab\ にある（.claude/rules/mql5-build.md）。
   // 標準の Indicators 直下へ置いた環境でも動くよう、両方を試す。
   string paths[2] = {"mql5-ea-lab\\SpanModel", "SpanModel"};

   for(int i = 0; i < 2; i++)
   {
      g_smHandle = iCustom(_Symbol, _Period, paths[i],
                           InpTenkan, InpKijun, InpSpanB, InpLagBars,
                           InpUseLagClose, InpUseLagHighLow, InpUseLagCloud,
                           InpUseClosePos, InpUseSlope, InpSlopeBars);
      if(g_smHandle == INVALID_HANDLE)
      {
         ResetLastError();
         continue;
      }

      // 視覚モードでは、EA が読み込んだ指標は MT5 が自動でチャートへ出す。
      // ここで明示的に足すのは、実口座のチャートへ EA を載せたときにも
      // 同じ絵を出すため。失敗しても指標そのものは表示される。
      if(!ChartIndicatorAdd(0, 0, g_smHandle))
         PrintFormat("チャートへの追加に失敗しました（エラー %d）。視覚モードなら自動で表示されます",
                     GetLastError());

      PrintFormat("チャートにスパンモデルを表示します（%s）", paths[i]);
      return;
   }

   Print("スパンモデルの指標が見つかりません。チャートへの表示は行いません");
}

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
   if(InpEntryDelayBars < 1 || InpExitDelayBars < 1)
   {
      Print("エントリー・決済を出す本数は 1 以上にしてください（1 = 次の足の始値）");
      return INIT_PARAMETERS_INCORRECT;
   }

   // ロットが刻みに合っていないと、発注は全て拒否されて取引ゼロで終わる。
   // 結果だけ見ると「条件が一度も揃わなかった」と区別が付かないため、
   // 起動時に弾く。
   const double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpLots < minLot || InpLots > maxLot)
   {
      PrintFormat("ロットが範囲外です（指定 %.2f / この銘柄は %.2f〜%.2f）",
                  InpLots, minLot, maxLot);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(lotStep > 0.0 && MathAbs(MathRound(InpLots / lotStep) * lotStep - InpLots) > 0.0000001)
   {
      PrintFormat("ロットが刻みに合っていません（指定 %.2f / 刻み %.2f）", InpLots, lotStep);
      return INIT_PARAMETERS_INCORRECT;
   }

   // ②は3つとも切りにすると「②を使わない」になる。設定画面を見返さ
   // なくても気づけるよう、起動のたびにログへ出す（指標と同じ扱い）。
   if(!InpUseLagClose && !InpUseLagHighLow && !InpUseLagCloud)
      Print("②遅行スパンは3つとも切りのため、条件に入れません（①③④だけで判定します）");

   g_params.tenkanPeriod  = InpTenkan;
   g_params.kijunPeriod   = InpKijun;
   g_params.spanBPeriod   = InpSpanB;
   g_params.lagBars       = InpLagBars;
   g_params.useLagClose   = InpUseLagClose;
   g_params.useLagHighLow = InpUseLagHighLow;
   g_params.useLagCloud   = InpUseLagCloud;
   g_params.useClosePos   = InpUseClosePos;
   g_params.useSlope      = InpUseSlope;
   g_params.slopeBars     = InpSlopeBars;

   // 必要本数は入力値から求める（固定値を書くと入力を変えた瞬間に嘘に
   // なる）。SM_RequiredBars は判定足を1本前とした本数なので、判定を
   // さらに手前へずらすぶんを足す。
   g_needBars = SM_RequiredBars(InpTenkan, InpKijun, InpSpanB, InpLagBars, InpSlopeBars)
                + MathMax(InpEntryDelayBars, InpExitDelayBars);

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetDeviationInPoints(10);

   // 起動した時点の足は途中まで出来ている。ここで時刻を控えておくと、
   // 最初の判定が次の足の始値になり、以後の足と条件が揃う。
   g_lastBar = iTime(_Symbol, _Period, 0);

   ShowIndicator();

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_smHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_smHandle);
      g_smHandle = INVALID_HANDLE;
   }

   if(!InpPrintCounters) return;

   PrintFormat("[ルール2] ①雲の転換 %I64d   （うち②を通った %I64d / ③ %I64d / ④ %I64d）",
               g_cntFlip, g_cntLag, g_cntClosePos, g_cntSlope);
   PrintFormat("          サイン 買い %I64d / 売り %I64d   建玉 %I64d / 決済 %I64d   発注失敗 %I64d",
               g_cntBuySignal, g_cntSellSignal, g_cntEntry, g_cntExit, g_cntOrderFailed);
   PrintFormat("          執行: エントリー %d 本後 / 決済 %d 本後（1 = 次の足の始値）",
               InpEntryDelayBars, InpExitDelayBars);
}

//+------------------------------------------------------------------+
//| 足が変わった最初のティックだけ true                              |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime t = iTime(_Symbol, _Period, 0);
   if(t == 0 || t == g_lastBar) return false;
   g_lastBar = t;
   return true;
}

//+------------------------------------------------------------------+
//| 判定に使う足を時系列順（添字 0 = 最新足）で取り出す              |
//+------------------------------------------------------------------+
bool CopyBars(double &high[], double &low[], double &close[])
{
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);

   if(CopyHigh (_Symbol, _Period, 0, g_needBars, high)  < g_needBars) return false;
   if(CopyLow  (_Symbol, _Period, 0, g_needBars, low)   < g_needBars) return false;
   if(CopyClose(_Symbol, _Period, 0, g_needBars, close) < g_needBars) return false;
   return true;
}

//+------------------------------------------------------------------+
//| 雲の色 — 1 = 青（青スパンが上）／ -1 = 赤 ／ 0 = どちらでもない  |
//|                                                                  |
//| 0 は「青スパンと赤スパンが同値」と「履歴が足りず計算できない」の  |
//| 両方。どちらも手仕舞いの引き金にはしない（反転していないため）。  |
//+------------------------------------------------------------------+
int CloudColor(const double &high[], const double &low[], const int shift)
{
   SMValues v;
   if(!SM_Calc(high, low, shift, InpTenkan, InpKijun, InpSpanB, v)) return 0;
   if(v.spanA > v.spanB) return  1;
   if(v.spanB > v.spanA) return -1;
   return 0;
}

//+------------------------------------------------------------------+
//| この EA が建てた建玉を探す                                       |
//|                                                                  |
//| 銘柄とマジックナンバーの両方で絞る。ヘッジ口座では同じ銘柄に他の  |
//| 建玉が同時に存在しうるため、銘柄だけで決済すると無関係な建玉を    |
//| 閉じてしまう（.claude/CLAUDE.md・PR #1 の指摘）。                 |
//+------------------------------------------------------------------+
bool FindPosition(ulong &ticket, ENUM_POSITION_TYPE &type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      ticket = t;
      type   = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| 判定と執行 — 足が確定したときだけ動く                            |
//|                                                                  |
//| 「条件が揃った足の N 本後の始値で執行する」を、足が変わった時点で |
//| **N 本前の足を判定する**形で実現している。待ち行列を持たなくて済 |
//| み、同じ足を二度判定することもない。                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsNewBar()) return;

   double high[], low[], close[];
   if(!CopyBars(high, low, close)) return;   // 履歴が足りない期間は何もしない

   // ── 決済 ─────────────────────────────────────────────
   // 建玉と反対の色になっていれば閉じる。「反転した瞬間」ではなく
   // 「反転した後の状態」で見る。エントリーを遅らせている都合で、建て
   // る前に反転が起きることがあり、瞬間だけを追うとその1回を取り逃す。
   ulong ticket = 0;
   ENUM_POSITION_TYPE type = POSITION_TYPE_BUY;
   if(FindPosition(ticket, type))
   {
      const int cloud = CloudColor(high, low, InpExitDelayBars);
      const bool flipped = (type == POSITION_TYPE_BUY  && cloud == -1)
                        || (type == POSITION_TYPE_SELL && cloud ==  1);
      if(flipped)
      {
         if(g_trade.PositionClose(ticket))
            g_cntExit++;
         else
         {
            g_cntOrderFailed++;
            PrintFormat("決済に失敗しました（チケット %I64u / 結果 %u %s）",
                        ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         }
      }
   }

   // ── エントリー ───────────────────────────────────────
   SMRule2Signal s;
   if(!SM_Rule2(high, low, close, InpEntryDelayBars, g_params, s)) return;

   if(s.flipBlue || s.flipRed)
   {
      g_cntFlip++;
      if(s.flipBlue)
      {
         if(s.lag.closeAbove || s.lag.highAbove || s.lag.cloudAbove) g_cntLag++;
         if(s.closeAbove) g_cntClosePos++;
         if(s.spanBUp)    g_cntSlope++;
      }
      else
      {
         if(s.lag.closeBelow || s.lag.lowBelow || s.lag.cloudBelow) g_cntLag++;
         if(s.closeBelow) g_cntClosePos++;
         if(s.spanBDown)  g_cntSlope++;
      }
   }
   if(s.buy)  g_cntBuySignal++;
   if(s.sell) g_cntSellSignal++;

   if(!s.buy && !s.sell) return;

   // 建玉は常に1つまで。決済が成立していればここでは見つからないので、
   // 同じ足で決済と反対建てが起きる（ドテン）。
   if(FindPosition(ticket, type)) return;

   const bool ok = s.buy
                   ? g_trade.Buy (InpLots, _Symbol)
                   : g_trade.Sell(InpLots, _Symbol);
   if(ok)
      g_cntEntry++;
   else
   {
      g_cntOrderFailed++;
      PrintFormat("発注に失敗しました（%s / 結果 %u %s）",
                  s.buy ? "買い" : "売り",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}
