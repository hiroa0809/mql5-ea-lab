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
#property version   "1.10"
#property description "スパンモデル単体（ルール2）。指標の矢印と同じ条件で売買する"

#include <Trade\Trade.mqh>
#include <Signals\SpanModel.mqh>

//+------------------------------------------------------------------+
//| ②遅行スパンを何と比べるか                                        |
//|                                                                  |
//| **1項目にまとめてあるのは、総当たりで同じ結果を二度測らないため。**|
//| 以前は「終値」「高値安値」「雲」を別々の入り切りにしていたが、    |
//| 終値と高値安値を同時に入れた組み合わせは、高値安値だけの場合と    |
//| 結果が完全に一致する（高値を抜けていれば終値も必ず抜けている）。  |
//| 実測でも 320 組すべてが一致した（PR #18）。8通りのうち2通りが     |
//| 無駄になるため、成立しうる6通りだけを並べた。                     |
//+------------------------------------------------------------------+
enum ENUM_SM_LAG
{
   SM_LAG_NONE          = 0,   // 使わない
   SM_LAG_CLOSE         = 1,   // a 重なる足の終値を抜けている
   SM_LAG_HIGHLOW       = 2,   // b 重なる足の高値安値を抜けている
   SM_LAG_CLOUD         = 3,   // c 重なる足の雲を抜けている
   SM_LAG_CLOSE_CLOUD   = 4,   // a+c 終値と雲の両方
   SM_LAG_HIGHLOW_CLOUD = 5    // b+c 高値安値と雲の両方
};

//+------------------------------------------------------------------+
//| ④長期スパンの傾きを条件に入れるか、入れるなら何本前と比べるか    |
//|                                                                  |
//| **入り切りと本数を1項目にまとめてあるのも重複を消すため。** 別々  |
//| だと、切ったときに本数を振っても結果が変わらない組み合わせが並ぶ  |
//| （実測で 64 組すべてが一致・PR #18）。                            |
//|                                                                  |
//| 値がそのまま本数になっている（0 だけが「使わない」）。            |
//+------------------------------------------------------------------+
enum ENUM_SM_SLOPE
{
   SM_SLOPE_OFF = 0,   // 使わない
   SM_SLOPE_1   = 1,   // 1本前と比べる
   SM_SLOPE_2   = 2,   // 2本前と比べる
   SM_SLOPE_3   = 3,   // 3本前と比べる
   SM_SLOPE_4   = 4,   // 4本前と比べる
   SM_SLOPE_5   = 5    // 5本前と比べる
};

//--- 指標 SpanModel.mq5 と同じ計算をさせるための項目。
//--- ②と④は上記のとおり1項目にまとめてあるので、指標の設定画面とは
//--- 行数が違う。中身は同じで、起動時にログへ実際の設定を出す。
input int           InpTenkan      = 9;                      // 転換線の期間
input int           InpKijun       = 26;                     // 基準線の期間
input int           InpSpanB       = 52;                     // 赤スパンの期間
input int           InpLagBars     = 26;                     // 遅行線の本数
input ENUM_SM_LAG   InpLagMode     = SM_LAG_HIGHLOW_CLOUD;   // ②遅行スパンを何と比べるか
input bool          InpUseClosePos = true;                   // ③終値と青スパンの位置関係を条件に入れる
input ENUM_SM_SLOPE InpSlopeMode   = SM_SLOPE_OFF;           // ④長期スパンの傾き

//--- ここから下は EA だけが持つ項目（指標には無い）
//--- 「何本後」は条件が揃った足を 0 本目として数える。1 = 次の足の始値
//--- （通常の自動売買）、2 = そのさらに1本後の始値（既定）。
input int InpEntryDelayBars = 2;   // エントリーを何本後の足の始値で出すか
input int InpExitDelayBars  = 2;   // 決済を何本後の足の始値で出すか

//--- 売買の中身に関わらない項目。**sinput は最適化の対象にならない。**
//--- 総当たりに紛れ込ませても結果が変わらないのに実行回数だけ倍になる
//--- ため（診断ログの入り切りで 640 組すべてが一致・PR #18）。
sinput double InpLots          = 0.10;       // ロット
sinput long   InpMagic         = 20260819;   // マジックナンバー
sinput bool   InpPrintCounters = true;       // 条件別の成立回数を出力する
sinput bool   InpShowIndicator = true;       // チャートにスパンモデルを表示する

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
long g_cntEntry = 0, g_cntExit = 0, g_cntOrderFailed = 0, g_cntBlocked = 0;

//+------------------------------------------------------------------+
//| ②の選択を、共通ファイルが要求する3つの入り切りへ展開する         |
//+------------------------------------------------------------------+
void ApplyLagMode(const ENUM_SM_LAG m, SMRule2Params &p)
{
   p.useLagClose   = (m == SM_LAG_CLOSE   || m == SM_LAG_CLOSE_CLOUD);
   p.useLagHighLow = (m == SM_LAG_HIGHLOW || m == SM_LAG_HIGHLOW_CLOUD);
   p.useLagCloud   = (m == SM_LAG_CLOUD   || m == SM_LAG_CLOSE_CLOUD
                                          || m == SM_LAG_HIGHLOW_CLOUD);
}

//+------------------------------------------------------------------+
//| ②の選択を日本語にする（起動時のログ用）                          |
//+------------------------------------------------------------------+
string LagModeText(const ENUM_SM_LAG m)
{
   switch(m)
   {
      case SM_LAG_NONE:          return "使わない";
      case SM_LAG_CLOSE:         return "a 終値";
      case SM_LAG_HIGHLOW:       return "b 高値安値";
      case SM_LAG_CLOUD:         return "c 雲";
      case SM_LAG_CLOSE_CLOUD:   return "a+c 終値と雲";
      case SM_LAG_HIGHLOW_CLOUD: return "b+c 高値安値と雲";
   }
   return "不明";
}

//+------------------------------------------------------------------+
//| 取引が本当に通ったかを結果コードで確かめる                       |
//|                                                                  |
//| **CTrade の Buy / Sell / PositionClose が返す true は「要求が     |
//| サーバーへ送られた」ことしか意味しない。** 標準ライブラリの       |
//| CTrade::OrderSend は ::OrderSend() の戻り値をそのまま返しており、 |
//| 結果コードを見ていない（Trade.mqh を実際に確認・PR #18）。        |
//| 拒否された取引を成功に数えると、診断の取引回数が実態と食い違う。  |
//|                                                                  |
//| 一部だけ約定した場合（TRADE_RETCODE_DONE_PARTIAL）は成功に数え    |
//| ない。建玉が残るが、手仕舞いの判定は「雲の色が反対のあいだ」ずっと|
//| 成立するので、次の足でもう一度決済を試みる。                      |
//+------------------------------------------------------------------+
bool TradeSucceeded(const bool sent)
{
   if(!sent) return false;

   const uint rc = g_trade.ResultRetcode();
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| テスターのチャートに同じ設定のスパンモデルを載せる               |
//|                                                                  |
//| 矢印が出た足と、実際に建てた位置を目で突き合わせるため。指標へ渡 |
//| す引数は EA が実際に使う値と同じにする。②は指標側が3つの入り切り |
//| なので、展開したものを渡す。                                     |
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
                           g_params.useLagClose, g_params.useLagHighLow,
                           g_params.useLagCloud, g_params.useClosePos,
                           g_params.useSlope, g_params.slopeBars);
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

   g_params.tenkanPeriod = InpTenkan;
   g_params.kijunPeriod  = InpKijun;
   g_params.spanBPeriod  = InpSpanB;
   g_params.lagBars      = InpLagBars;
   g_params.useClosePos  = InpUseClosePos;
   ApplyLagMode(InpLagMode, g_params);

   // 「使わない」を選んだときも、傾きを求める関数は 1 以上の本数を要求
   // するため 1 を入れておく。結果は使われない。
   g_params.useSlope  = (InpSlopeMode != SM_SLOPE_OFF);
   g_params.slopeBars = (InpSlopeMode == SM_SLOPE_OFF) ? 1 : (int)InpSlopeMode;

   // **実際に効いている設定を毎回ログへ出す。** 入力項目の構成を変えた
   // ため、古い .set を読み込むと消えた項目は既定値で埋まる。黙って別の
   // 条件で走るのを防ぐには、走り出しに実物を出すしかない。
   PrintFormat("設定: ②%s ／ ③%s ／ ④%s ／ エントリー %d 本後 ／ 決済 %d 本後",
               LagModeText(InpLagMode),
               InpUseClosePos ? "使う" : "使わない",
               g_params.useSlope ? StringFormat("%d本前と比べる", g_params.slopeBars) : "使わない",
               InpEntryDelayBars, InpExitDelayBars);

   if(InpLagMode == SM_LAG_NONE)
      Print("②遅行スパンは条件に入れません（①③④だけで判定します）");

   // 必要本数は入力値から求める（固定値を書くと入力を変えた瞬間に嘘に
   // なる）。SM_RequiredBars は判定足を1本前とした本数なので、判定を
   // さらに手前へずらすぶんを足す。
   g_needBars = SM_RequiredBars(InpTenkan, InpKijun, InpSpanB, InpLagBars, g_params.slopeBars)
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
   PrintFormat("          サイン 買い %I64d / 売り %I64d   建玉 %I64d / 決済 %I64d   発注失敗 %I64d   他建玉で見送り %I64d",
               g_cntBuySignal, g_cntSellSignal, g_cntEntry, g_cntExit,
               g_cntOrderFailed, g_cntBlocked);
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
//| 他人の建玉を巻き込む恐れがあるか                                 |
//|                                                                  |
//| **ネッティング口座は銘柄ごとに建玉を1つしか持てない。** 別のEAや  |
//| 手動で建てた玉がある状態で成行を送ると、新しい建玉ができるのでは |
//| なく、その玉が増減・決済・反転する。マジックナンバーで絞っても、  |
//| 建玉そのものが共有なので防げない（PR #18 の指摘）。               |
//|                                                                  |
//| ヘッジ口座では建玉が別々に立つので、この制限は掛けない。          |
//+------------------------------------------------------------------+
bool ForeignPositionBlocks()
{
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      return false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic) continue;
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
         if(TradeSucceeded(g_trade.PositionClose(ticket)))
            g_cntExit++;
         else
         {
            g_cntOrderFailed++;
            PrintFormat("決済できませんでした（チケット %I64u / 結果 %u %s）",
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

   // ネッティング口座で他人の建玉があるときは何もしない
   if(ForeignPositionBlocks())
   {
      g_cntBlocked++;
      return;
   }

   const bool sent = s.buy
                     ? g_trade.Buy (InpLots, _Symbol)
                     : g_trade.Sell(InpLots, _Symbol);
   if(TradeSucceeded(sent))
      g_cntEntry++;
   else
   {
      g_cntOrderFailed++;
      PrintFormat("建てられませんでした（%s / 結果 %u %s）",
                  s.buy ? "買い" : "売り",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}
