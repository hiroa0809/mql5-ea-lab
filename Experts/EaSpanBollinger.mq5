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
//| 同じ理由で「ルール1を使う」の入力も置かない（2026-08-12 に削除）。|
//| 実装済みのルールが1つしかない今、false は EA を丸ごと黙らせる    |
//| だけで、エラーも警告も出ないまま取引ゼロになる。ルール2を足す    |
//| ときに InpR1_Enable / InpR2_Enable を対で用意する。              |
//|                                                                  |
//| 売買条件は docs/trading_rules.md §4、執行は                      |
//| docs/implementation_design.md §3。                               |
//+------------------------------------------------------------------+
#property description "ルール1（スーパーボリンジャー）単体の検証用"

#include <Trade\Trade.mqh>
#include <Signals\SuperBollinger.mqh>

//--- パラボリック SAR による決済。執行の話なので Signals 側には置かない
//    （SuperBollinger.mqh は指標とEAで共有する条件式だけを持つ）
enum ENUM_SAR_MODE
{
   SAR_MODE_OFF  = 0,   // 使わない（既存の決済条件のみ）
   SAR_MODE_ONLY = 1,   // SAR のみ
   SAR_MODE_BOTH = 2    // 併用（どちらか早いほう）
};

//| サーバーの逆指値は EA が止まっても効くがスプレッド拡大で刺さる。   |
//| Bid 判定は刺さらないが EA が動いている必要があり、決済は Ask で    |
//| 約定する。どちらが勝つかは学習期間で比較して決める。               |
enum ENUM_SAR_EXEC
{
   SAR_EXEC_STOP = 0,   // サーバーの逆指値
   SAR_EXEC_BID  = 1    // Bid 判定して成行決済
};

//--- 共通
input double InpLots              = 0.10;      // ロット
input long   InpMagic             = 20260808;  // マジックナンバー
input bool   InpReverseOnOpposite = true;      // 反対シグナルでドテンする

//--- ルール1: スーパーボリンジャー
input int    InpR1_Period      = 21;     // 期間（センターラインとσ）
input int    InpR1_LagBars     = 21;     // 遅行線の本数
input bool   InpR1_UseSqueeze  = true;   // ①膠着を条件に入れる
input int    InpR1_SqueezeBars = 21;     // ①膠着とみなす本数（この本数ぶん帯の内側）
input double InpR1_SigmaMult   = 3.0;    // ①③で使うσの倍数
input bool   InpR1_UseExpand   = true;   // ④バンド幅の拡大を条件に入れる
input int    InpR1_ExpandBars  = 3;      // ④拡大を見る本数
input ENUM_SB_EXIT InpR1_Exit  = SB_EXIT_CLOSE_SIGMA1;  // 決済の方式
input bool   InpR1_UseSL       = false;  // 損切りを使う
input double InpR1_SLSigma     = 2.0;    // 損切り（σの何倍）
input bool   InpR1_UseTimeStop = false;  // 保有本数で手仕舞う
input int    InpR1_HoldBars    = 24;     // 手仕舞うまでの本数

//--- 段階エントリー。既定は「使わない」＝従来どおりの動き
input ENUM_SB_STAGED InpR1_StagedMode = SB_STAGED_OFF;  // 段階エントリー
input int    InpR1_ArmBars     = 42;     // 装填が生きている本数（装填1 から数える）
input int    InpR1_RsiPeriod   = 14;     // RSI の期間（段階エントリーの見送り判定に使う）
input double InpR1_RsiUpper    = 80.0;   // 買いの発火を見送る RSI（これ以上なら入らない）
input double InpR1_RsiLower    = 20.0;   // 売りの発火を見送る RSI（これ以下なら入らない）

//--- パラボリック SAR。既定は「使わない」＝従来どおりの動き
input ENUM_SAR_MODE InpR1_SarMode = SAR_MODE_OFF;   // SAR で決済する
input ENUM_SAR_EXEC InpR1_SarExec = SAR_EXEC_STOP;  // SAR の執行方式
input double InpR1_SarStep      = 0.01;  // SAR のステップ（食いつきの刻み）
input double InpR1_SarMax       = 0.20;  // SAR の最大（食いつきの頭打ち）
input bool   InpR1_SarEntryGate = false; // ポインタが正しい側になるまで入らない

//--- 診断
input bool   InpPrintCounters = true;    // 条件別の成立回数を出力する
input string InpRunTag        = "";      // 実行の識別名（空なら CSV を書かない）

CTrade         g_trade;
SBRule1Params  g_rule1;
SBStagedParams g_staged;
SBArmState     g_arm;
int            g_rsiHandle   = INVALID_HANDLE;
int            g_sarHandle   = INVALID_HANDLE;
bool           g_needRsi     = false;   // 段階エントリーの発火を見送るかの判定に RSI を使う
bool           g_needSar     = false;
datetime       g_lastBarTime = 0;
ulong          g_posTicket   = 0;
long           g_posId       = 0;   // 決済履歴を引くための建玉ID
int            g_barsHeld    = 0;
int            g_needBars    = 0;

//--- ポインタが逆側だったときの待機。発火した向きを覚えておき、正しい側へ
//    来た足で入る。期限は装填と同じ本数を使う（新しいつまみを増やさない）
int            g_sarWaitDir  = 0;
int            g_sarWaitAge  = 0;
bool           g_sarWaitFiredNow = false;  // この足で待機から発火したか

//--- 診断カウンタ。各条件は他の条件の成否と無関係に数える
//    （docs/implementation_design.md §4）
int g_cntJudged = 0;    // 判定した足数
int g_cntSqueeze = 0, g_cntBreak = 0, g_cntExpand = 0;
int g_cntSignal  = 0, g_cntBuy = 0, g_cntSell = 0;
int g_cntWidened = 0;   // 損切りを最小距離まで広げた回数

//--- 段階エントリーの内訳。この案が使いものになるかは、装填1 がどれだけ
//    装填2・発火まで進んだか（どこで落ちたか）で判断する
int g_cntArm1 = 0, g_cntArm2 = 0, g_cntFired = 0;
int g_cntRsiBlocked = 0, g_cntExpired = 0;

//--- SAR の内訳。ユーザーの目視では「ポインタは常にエントリーの反対側」
//    だったが、100例の観察でしかない。実測して確定させる
int g_sarStopsLevel   = 0;   // ブローカーの最小距離（ポイント）。0 なら論点そのものが無い
int g_cntSarModify    = 0;   // 損切りを書き換えた回数
int g_cntSarClamped   = 0;   // 最小距離まで押し戻した回数
int g_cntSarSkipped   = 0;   // 前回より緩くなるため書き換えなかった回数
int g_cntSarBlocked   = 0;   // ポインタが逆側で発火を見送った回数
int g_cntSarWaitFired = 0;   // 待機後、ポインタが反転して実際に発注した回数
int g_cntSarWaitExp   = 0;   // 待機のまま期限切れになった回数
int g_cntSarNoValue   = 0;   // ポインタを取れず損切りを置けなかった回数

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
   if(InpR1_UseSL && InpR1_SLSigma <= 0.0)
   {
      // 0 以下でも起動できてしまうと、NormalizeStopLevel が最小距離まで
      // 黙って広げる。設定したはずの損切りと違う条件でテストが走る
      Print("損切り（σの何倍）は 0 より大きくしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMagic <= 0)
   {
      // 0 だと、識別番号を持たない建玉（手動注文など）を自分のものと
      // 見なす。決済はチケット指定で行うため、無関係の建玉を閉じうる
      Print("マジックナンバーは 1 以上にしてください（0 は識別番号なしの建玉と区別が付かない）");
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

   g_needRsi = (InpR1_StagedMode != SB_STAGED_OFF);

   if(InpR1_StagedMode != SB_STAGED_OFF && InpR1_ArmBars < 1)
   {
      Print("装填が生きている本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(g_needRsi)
   {
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

   g_needSar = (InpR1_SarMode != SAR_MODE_OFF || InpR1_SarEntryGate);

   if(g_needSar)
   {
      if(!(InpR1_SarStep > 0.0 && InpR1_SarStep <= InpR1_SarMax))
      {
         Print("SAR は 0 < ステップ <= 最大 にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }

      // 装填の本数はエントリーゲートの待機期限にも使う。段階エントリーが
      // 無効だと下の検証が効かず、0 以下でも起動する。そのとき見送った
      // 発火は次の足で必ず期限切れになり、無言で取引が減る
      if(InpR1_SarEntryGate && InpR1_ArmBars < 1)
      {
         Print("装填が生きている本数は 1 以上にしてください（ポインタの反転を待つ期限に使います）");
         return INIT_PARAMETERS_INCORRECT;
      }

      // どちらも建玉の同じ損切り価格を書くため、後から置いたほうが黙って
      // もう一方を消す。CSV には両方の設定が残るので、結果から条件を
      // 再現できなくなる。混ぜた挙動を新たに定義せず、起動時に弾く
      if(InpR1_UseSL && InpR1_SarMode != SAR_MODE_OFF && InpR1_SarExec == SAR_EXEC_STOP)
      {
         Print("σ の損切りと SAR の逆指値は同時に使えません。どちらか片方にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }

      g_sarHandle = iSAR(_Symbol, _Period, InpR1_SarStep, InpR1_SarMax);
      if(g_sarHandle == INVALID_HANDLE)
      {
         PrintFormat("パラボリック SAR を作成できませんでした (error=%d)", GetLastError());
         return INIT_FAILED;
      }

      // 最小距離は「損切りをここまで押し戻す」の基準。0 なら押し戻しは
      // 一度も起きない。推測せずに実測値を残す
      g_sarStopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
      PrintFormat("[SAR] %s の最小距離 %d ポイント / 方式 %s / 執行 %s",
                  _Symbol, g_sarStopsLevel, SarModeName(InpR1_SarMode), SarExecName(InpR1_SarExec));
   }

   g_staged.stages   = (int)InpR1_StagedMode;
   g_staged.armBars  = InpR1_ArmBars;
   g_staged.rsiUpper = InpR1_RsiUpper;
   g_staged.rsiLower = InpR1_RsiLower;
   g_arm.stage       = 0;
   g_arm.dir         = 0;
   g_arm.age         = 0;

   g_rule1.period      = InpR1_Period;
   g_rule1.lagBars     = InpR1_LagBars;
   g_rule1.useSqueeze  = InpR1_UseSqueeze;
   g_rule1.squeezeBars = InpR1_SqueezeBars;
   g_rule1.sigmaMult   = InpR1_SigmaMult;
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

   // 現在の足の時刻を先に控える。0 のままだと、足の途中で EA を貼った
   // ときや再初期化されたときに、最初の OnTick が「新しい足ができた」と
   // 判定して足の途中で発注してしまう。「発注は次の足の始値」という
   // 決まりから外れる（docs/implementation_design.md §3）
   g_lastBarTime = (datetime)SeriesInfoInteger(_Symbol, _Period, SERIES_LASTBAR_DATE);

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
   if(g_sarHandle != INVALID_HANDLE)
      IndicatorRelease(g_sarHandle);
   Comment("");

   if(!InpPrintCounters)
      return;

   // 取引ゼロで終わったときに、どの条件で止まったかを切り分けるため。
   // 各条件は単独で数えているので、他の条件の成否に影響されない。
   PrintFormat("[ルール1] 判定した足 %d", g_cntJudged);
   PrintFormat("[ルール1] ①膠着 %d / ③3σ突破 %d / ④拡大 %d",
               g_cntSqueeze, g_cntBreak, g_cntExpand);
   PrintFormat("[ルール1] 3つ揃った %d   買い %d / 売り %d",
               g_cntSignal, g_cntBuy, g_cntSell);
   PrintFormat("[ルール1] 損切りを最小距離まで広げた %d", g_cntWidened);
   PrintFormat("[ルール1] 決済の方式: %s", ExitName(InpR1_Exit));

   if(InpR1_StagedMode != SB_STAGED_OFF)
   {
      PrintFormat("[段階] 方式: %s", StagedName(InpR1_StagedMode));
      PrintFormat("[段階] 装填1 %d → 装填2 %d → 発火 %d", g_cntArm1, g_cntArm2, g_cntFired);
      PrintFormat("[段階] RSIで見送り %d / 期限切れ %d", g_cntRsiBlocked, g_cntExpired);
   }

   if(g_needSar)
   {
      PrintFormat("[SAR] 方式: %s / 執行: %s / ステップ %.2f / 最大 %.2f",
                  SarModeName(InpR1_SarMode), SarExecName(InpR1_SarExec),
                  InpR1_SarStep, InpR1_SarMax);
      PrintFormat("[SAR] 最小距離 %d ポイント（0 なら押し戻しは起きない）", g_sarStopsLevel);
      PrintFormat("[SAR] 損切りを書き換えた %d / 最小距離まで押し戻した %d / 緩くなるので据え置いた %d",
                  g_cntSarModify, g_cntSarClamped, g_cntSarSkipped);
      PrintFormat("[SAR] ポインタが逆側で見送った %d → 反転して入れた %d / 期限切れ %d",
                  g_cntSarBlocked, g_cntSarWaitFired, g_cntSarWaitExp);
      PrintFormat("[SAR] ポインタを取れず損切りを置けなかった %d", g_cntSarNoValue);
   }
}

//+------------------------------------------------------------------+
//| 判定は確定足（shift = 1）だけ。発注は次の足の始値で成行になる    |
//| （新しい足ができた直後に成行を出すため）。                       |
//+------------------------------------------------------------------+
void OnTick()
{
   // Bid 判定だけは足の途中で動く。トレーリングストップは本質的に足を
   // またぐので、「判定は確定足のみ」（trading_rules.md §2.1）が想定して
   // いなかったケースにあたる。見る値そのものは確定足のポインタなので、
   // サーバーの逆指値と完全に同じ水準を見ている
   SarTickExit();

   if(!IsNewBar())
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
   if(g_needRsi)
   {
      double rsi[];
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsiHandle, 0, 0, 2, rsi) < 2)
         return;
      rsi1 = rsi[1];
   }

   SBRule1Signal s;
   if(!SB_Rule1(close, 1, g_rule1, s))
      return;

   g_cntJudged++;
   if(s.squeezed)                 g_cntSqueeze++;
   if(s.crossUp  || s.crossDown)  g_cntBreak++;
   if(s.expanding)                g_cntExpand++;
   if(s.buy || s.sell)
   {
      g_cntSignal++;
      if(s.buy) g_cntBuy++; else g_cntSell++;
   }

   //--- 発注する足を決める。段階エントリーが有効なら「発火」、無効なら
   //    従来どおりサインそのもの
   bool entryBuy  = s.buy;
   bool entrySell = s.sell;
   if(InpR1_StagedMode != SB_STAGED_OFF)
   {
      // 装填2 へ進むかは、装填1 の向きで決済条件を見る。決済の方式は
      // 入力で選んだものをそのまま使う
      const bool stopHit =
         SB_StagedStopHit(close, 1, InpR1_Period, InpR1_LagBars, InpR1_Exit, g_staged, g_arm);

      SBStagedResult stg;
      SB_StagedStep(s, rsi1, stopHit, g_staged, g_arm, stg);
      entryBuy  = stg.fireBuy;
      entrySell = stg.fireSell;

      if(stg.arm1Now)           g_cntArm1++;
      if(stg.arm2Now)           g_cntArm2++;
      if(stg.rsiBlocked)        g_cntRsiBlocked++;
      if(stg.expired)           g_cntExpired++;
      if(entryBuy || entrySell) g_cntFired++;

      if(g_arm.stage == 0)
         Comment("装填なし");
      else
      {
         const bool waitStop = (g_arm.stage == 1 && InpR1_StagedMode == SB_STAGED_2);
         Comment(StringFormat("装填%d（%s・期限まであと %d 本）",
                              g_arm.stage,
                              waitStop ? "損切り待ち" : "3σ突破待ち",
                              InpR1_ArmBars - g_arm.age));
      }
   }

   //--- ポインタが正しい側に無ければ入らない。逆側なら向きを覚えて待機し、
   //    反転した足で入る（期限は装填と同じ本数）
   if(InpR1_SarEntryGate)
      SarEntryGate(close[1], entryBuy, entrySell);

   //--- 手仕舞いが先。抜けた足で反対の発注も出ていればドテンになる
   int dir = CurrentPositionDir(g_posTicket);

   // 自分の決済以外で建玉が消えていたら（サーバー側の損切りなど）記録を閉じる。
   // SAR をサーバーの逆指値で置く場合は決済がすべてここを通るので、履歴から
   // 実際の決済価格を引く。0 のままにすると、比べたい方式の成績が出せない
   if(dir == 0 && g_hasOpenRow)
   {
      double closePrice = 0.0;
      long   dealReason = -1;
      if(ClosingDeal(g_posId, closePrice, dealReason))
         RecordTrade(closePrice, DealReasonName(dealReason));
      else
         RecordTrade(0.0, "EA 以外の要因（決済価格を取得できず）");
   }

   if(dir != 0)
   {
      g_barsHeld++;

      string reason = "";
      if(InpR1_UseTimeStop && g_barsHeld >= InpR1_HoldBars)
         reason = StringFormat("保有 %d 本で時間切れ", g_barsHeld);

      // SAR のみを試すときは既存の決済条件を止める。併用なら両方見て、
      // 先に成立したほうで抜ける
      if(reason == "" && InpR1_SarMode != SAR_MODE_ONLY)
      {
         bool hit;
         if(SB_Rule1Exit(close, 1, InpR1_Period, InpR1_LagBars, InpR1_Exit, dir > 0, hit) && hit)
            reason = ExitName(InpR1_Exit);
      }

      // ルール1では、反対シグナルが出るころには上の手仕舞いが先に成立して
      // いるのが通常（反対側は①膠着も要求するため）。この分岐が効くのは
      // 例外的な足だけ（docs/implementation_design.md §3）
      if(reason == "" && InpReverseOnOpposite &&
         ((dir > 0 && entrySell) || (dir < 0 && entryBuy)))
         reason = "反対シグナル";

      if(reason != "" && ClosePosition(reason))
         dir = 0;

      // 決済しなかったなら、損切りをポインタの位置まで引き上げる
      if(dir != 0 && InpR1_SarMode != SAR_MODE_OFF && InpR1_SarExec == SAR_EXEC_STOP)
         SarTrailUpdate(dir);
   }

   //--- 建玉は1つまで。保有中に出た同じ向きの発注は無視する
   if(dir != 0)
      return;

   if(g_sarWaitFiredNow)
      g_cntSarWaitFired++;

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
//|                                                                  |
//| 空きが無ければ −1 を返す。ここで 999 を返すと、まさに防ぎたい    |
//| 上書きが起きる。呼ぶ側は書き込みごと中止すること。               |
//+------------------------------------------------------------------+
int FreeCsvSeq()
{
   for(int seq = 0; seq <= 999; seq++)
      if(!FileIsExist(CsvName("trades",  seq), FILE_COMMON)
         && !FileIsExist(CsvName("summary", seq), FILE_COMMON))
         return seq;

   return -1;
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
   if(seq < 0)
   {
      PrintFormat("EaSpanBollinger: 識別名 %s の連番が 0〜999 まで埋まっています。既存の結果を上書きしないため CSV を書きませんでした。共有フォルダを整理してください",
                  InpRunTag);
      return;
   }

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
   FileWrite(fs, "use_expand",    InpR1_UseExpand ? 1 : 0);
   FileWrite(fs, "use_sl",        InpR1_UseSL ? 1 : 0);
   // 売買結果を変える入力は全部残す。無いと保存した結果から条件を再現できない
   FileWrite(fs, "sl_sigma",      DoubleToString(InpR1_SLSigma, 2));
   FileWrite(fs, "use_timestop",  InpR1_UseTimeStop ? 1 : 0);
   FileWrite(fs, "hold_bars",     InpR1_HoldBars);
   FileWrite(fs, "reverse",       InpReverseOnOpposite ? 1 : 0);
   FileWrite(fs, "lots",          DoubleToString(InpLots, 2));
   FileWrite(fs, "judged_bars",   g_cntJudged);
   FileWrite(fs, "cond1_squeeze", g_cntSqueeze);
   FileWrite(fs, "cond3_break",   g_cntBreak);
   FileWrite(fs, "cond4_expand",  g_cntExpand);
   FileWrite(fs, "signals",       g_cntSignal);
   FileWrite(fs, "signals_buy",   g_cntBuy);
   FileWrite(fs, "signals_sell",  g_cntSell);
   FileWrite(fs, "sl_widened",    g_cntWidened);
   FileWrite(fs, "staged_mode",   (int)InpR1_StagedMode);
   FileWrite(fs, "staged_name",   StagedName(InpR1_StagedMode));
   FileWrite(fs, "arm_bars",      InpR1_ArmBars);
   FileWrite(fs, "rsi_period",    InpR1_RsiPeriod);
   FileWrite(fs, "rsi_upper",     DoubleToString(InpR1_RsiUpper, 1));
   FileWrite(fs, "rsi_lower",     DoubleToString(InpR1_RsiLower, 1));
   FileWrite(fs, "armed1",        g_cntArm1);
   FileWrite(fs, "armed2",        g_cntArm2);
   FileWrite(fs, "fired",         g_cntFired);
   FileWrite(fs, "rsi_blocked",   g_cntRsiBlocked);
   FileWrite(fs, "arm_expired",   g_cntExpired);
   FileWrite(fs, "sar_mode",      (int)InpR1_SarMode);
   FileWrite(fs, "sar_mode_name", SarModeName(InpR1_SarMode));
   FileWrite(fs, "sar_exec",      (int)InpR1_SarExec);
   FileWrite(fs, "sar_exec_name", SarExecName(InpR1_SarExec));
   FileWrite(fs, "sar_step",      DoubleToString(InpR1_SarStep, 3));
   FileWrite(fs, "sar_max",       DoubleToString(InpR1_SarMax, 3));
   FileWrite(fs, "sar_entry_gate", InpR1_SarEntryGate ? 1 : 0);
   FileWrite(fs, "stops_level_pt", g_sarStopsLevel);
   FileWrite(fs, "sar_modified",  g_cntSarModify);
   FileWrite(fs, "sar_clamped",   g_cntSarClamped);
   FileWrite(fs, "sar_skipped",   g_cntSarSkipped);
   FileWrite(fs, "sar_blocked",   g_cntSarBlocked);
   FileWrite(fs, "sar_wait_fired", g_cntSarWaitFired);
   FileWrite(fs, "sar_wait_expired", g_cntSarWaitExp);
   FileWrite(fs, "sar_no_value", g_cntSarNoValue);
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
//| 段階エントリーの名前。CSV とログで、どの設定の結果かを取り違え    |
//| ないようにする（数字だけだと後で見返したときに読めない）          |
//+------------------------------------------------------------------+
string StagedName(const ENUM_SB_STAGED mode)
{
   if(mode == SB_STAGED_OFF) return "使わない";
   if(mode == SB_STAGED_1)   return "装填1 → 発火";
   return "装填1 → 装填2 → 発火";
}

//+------------------------------------------------------------------+
string SarModeName(const ENUM_SAR_MODE mode)
{
   if(mode == SAR_MODE_OFF)  return "使わない";
   if(mode == SAR_MODE_ONLY) return "SAR のみ";
   return "併用（どちらか早いほう）";
}

//+------------------------------------------------------------------+
string SarExecName(const ENUM_SAR_EXEC exec)
{
   if(exec == SAR_EXEC_STOP) return "サーバーの逆指値";
   return "Bid 判定して成行決済";
}

//+------------------------------------------------------------------+
//| 確定足（shift = 1）のポインタの値                                |
//|                                                                  |
//| サーバーの逆指値と Bid 判定が同じ値を見るように、両方ここを通す。 |
//| 別々に読むと、比較で出た差が執行方式の違いなのか読み取り位置の   |
//| 違いなのか分離できない。                                         |
//+------------------------------------------------------------------+
bool SarValue(double &value)
{
   if(g_sarHandle == INVALID_HANDLE)
      return false;

   double buf[];
   if(CopyBuffer(g_sarHandle, 0, 1, 1, buf) < 1)
      return false;

   value = buf[0];
   return true;
}

//+------------------------------------------------------------------+
//| SAR から損切り価格を求める                                       |
//|                                                                  |
//| 建玉時と毎足の更新で必ずここを通す。同じ手順を2箇所に書くと、    |
//| 片方だけ直したときに建玉時と更新時で損切り水準がずれる。         |
//|                                                                  |
//| 売り建玉の逆指値は Ask で発動する。ポインタは Bid のチャートから |
//| 出た値なので、そのまま置くとローソク足がポインタに触れる前に      |
//| 切られる。スプレッドを足して、チャートの見た目と一致させる。      |
//| スプレッドは実測が不要（Ask と Bid の差）で、時間帯による変動も  |
//| そのまま追える。平均値を埋め込むと 0 時台だけ常に早く切られる。  |
//+------------------------------------------------------------------+
bool SarStopPrice(const int dir, double &price)
{
   double sar1;
   if(!SarValue(sar1))
   {
      // 無言で戻ると、損切りを持たない建玉ができたことが記録に残らない
      g_cntSarNoValue++;
      PrintFormat("EaSpanBollinger: ポインタを取れず損切りを置けませんでした（通算 %d 回）",
                  g_cntSarNoValue);
      return false;
   }

   double want = sar1;
   if(dir < 0)
      want += SymbolInfoDouble(_Symbol, SYMBOL_ASK) - SymbolInfoDouble(_Symbol, SYMBOL_BID);

   bool clamped = false;
   price = NormalizeStopLevel(dir, want, clamped);
   if(clamped)
      g_cntSarClamped++;

   return true;
}

//+------------------------------------------------------------------+
//| ポインタが正しい側に無ければ入らない                             |
//|                                                                  |
//| 買いならポインタは終値より下、売りなら上にあるのが正常。逆側だと |
//| そもそも損切りとして置けない（MT5 は買いの損切りを現在値より下に |
//| しか置かせない）。逆側なら向きを覚えて待機し、反転した足で入る。 |
//| 期限は装填が生きている本数を流用する。                           |
//+------------------------------------------------------------------+
void SarEntryGate(const double close1, bool &entryBuy, bool &entrySell)
{
   g_sarWaitFiredNow = false;

   double sar1;
   if(!SarValue(sar1))
      return;

   const bool okBuy  = (sar1 < close1);
   const bool okSell = (sar1 > close1);

   //--- 先に待機の消化。新しい発火より前に見ないと、同じ足で始めた待機を
   //    その場で判定してしまう
   if(g_sarWaitDir != 0)
   {
      g_sarWaitAge++;

      if((g_sarWaitDir > 0 && okBuy) || (g_sarWaitDir < 0 && okSell))
      {
         // 実際に発注できたかはここでは分からない（建玉保有中なら発注前に
         // 抜ける）。頻度の実測が目的なので、計上は発注の直前で行う
         if(g_sarWaitDir > 0) entryBuy = true; else entrySell = true;
         g_sarWaitFiredNow = true;
         g_sarWaitDir      = 0;
      }
      else if(g_sarWaitAge >= InpR1_ArmBars)
      {
         g_cntSarWaitExp++;
         g_sarWaitDir = 0;
      }
   }

   //--- 新しい発火。逆側なら見送って待機に入る
   if(entryBuy && !okBuy)
   {
      entryBuy     = false;
      g_sarWaitDir = +1;
      g_sarWaitAge = 0;
      g_cntSarBlocked++;
   }
   if(entrySell && !okSell)
   {
      entrySell    = false;
      g_sarWaitDir = -1;
      g_sarWaitAge = 0;
      g_cntSarBlocked++;
   }
}

//+------------------------------------------------------------------+
//| 損切りをポインタの位置まで引き上げる（サーバーの逆指値）         |
//|                                                                  |
//| 売り建玉の逆指値は Ask で発動する。ポインタは Bid のチャートから |
//| 出た値なので、そのまま置くとローソク足がポインタに触れる前に      |
//| 切られる。スプレッドを足して、チャートの見た目と一致させる。      |
//| スプレッドは実測が不要（Ask と Bid の差）で、時間帯による変動も  |
//| そのまま追える。平均値を埋め込むと 0 時台だけ常に早く切られる。  |
//|                                                                  |
//| 最小距離まで押し戻したうえで、前回より緩い位置には置かない。     |
//| 押し戻しは緩める方向なので、これが無いと価格が戻った場面で        |
//| 損切りが後退する。                                               |
//+------------------------------------------------------------------+
void SarTrailUpdate(const int dir)
{
   if(!PositionSelectByTicket(g_posTicket))
      return;

   const double curSL = PositionGetDouble(POSITION_SL);
   const double tp    = PositionGetDouble(POSITION_TP);

   double want;
   if(!SarStopPrice(dir, want))
      return;

   if(curSL > 0.0 && ((dir > 0 && want <= curSL) || (dir < 0 && want >= curSL)))
   {
      g_cntSarSkipped++;
      return;
   }

   if(g_trade.PositionModify(g_posTicket, want, tp))
      g_cntSarModify++;
   else
      PrintFormat("EaSpanBollinger: 損切りを %.*f へ動かせませんでした (retcode=%u, %s)",
                  _Digits, want, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
//| Bid がポインタに届いたら成行で決済する                           |
//|                                                                  |
//| サーバーの逆指値と違い、スプレッドが開いただけでは発動しない。   |
//| そのかわり EA が動いていないと効かず、決済は Ask で約定する。     |
//+------------------------------------------------------------------+
void SarTickExit()
{
   if(InpR1_SarMode == SAR_MODE_OFF || InpR1_SarExec != SAR_EXEC_BID)
      return;

   ulong ticket = 0;
   const int dir = CurrentPositionDir(ticket);
   if(dir == 0)
      return;

   double sar1;
   if(!SarValue(sar1))
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if((dir > 0 && bid > sar1) || (dir < 0 && bid < sar1))
      return;

   g_posTicket = ticket;
   ClosePosition("SAR（Bid 判定）");
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

   // SAR をサーバーの逆指値で使うなら、建玉と同時に置く。次の足の更新まで
   // 待つと最初の1本だけ無防備になり、Bid 判定と条件が揃わなくなる
   if(InpR1_SarMode != SAR_MODE_OFF && InpR1_SarExec == SAR_EXEC_STOP)
   {
      double sarSL;
      if(SarStopPrice(dir, sarSL))
         sl = sarSL;
   }

   const string label = (dir > 0) ? "R1 買い" : "R1 売り";
   const bool   sent  = (dir > 0)
                        ? g_trade.Buy (InpLots, _Symbol, 0.0, sl, 0.0, label)
                        : g_trade.Sell(InpLots, _Symbol, 0.0, sl, 0.0, label);

   ReportTradeResult(label, sent);

   if(!sent || !IsFilled())
      return;

   g_barsHeld = 0;

   // 建玉IDは約定履歴から引く。サーバー側で決済されたとき、決済価格を
   // 取れる唯一の手がかりになる
   g_posId = 0;
   const ulong deal = g_trade.ResultDeal();
   if(deal > 0 && HistoryDealSelect(deal))
      g_posId = HistoryDealGetInteger(deal, DEAL_POSITION_ID);

   g_openRow.dir        = dir;
   g_openRow.openTime   = TimeCurrent();
   g_openRow.openPrice  = g_trade.ResultPrice();
   g_openRow.openSpread = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_hasOpenRow         = true;
}

//+------------------------------------------------------------------+
//| 建玉を閉じた約定を履歴から探し、価格と決済理由を返す             |
//+------------------------------------------------------------------+
bool ClosingDeal(const long posId, double &price, long &reason)
{
   if(posId == 0 || !HistorySelectByPosition(posId))
      return false;

   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
   {
      const ulong d = HistoryDealGetTicket(i);
      if(d == 0)                                                continue;
      if(HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      price  = HistoryDealGetDouble(d, DEAL_PRICE);
      reason = HistoryDealGetInteger(d, DEAL_REASON);
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| 決済理由の名前。サーバー側の損切りは、SAR を使っているかで意味が |
//| 変わるので呼び分ける（集計で SAR 決済だけを抜き出せるように）    |
//+------------------------------------------------------------------+
string DealReasonName(const long reason)
{
   if(reason == DEAL_REASON_SL)
      return (InpR1_SarMode != SAR_MODE_OFF && InpR1_SarExec == SAR_EXEC_STOP)
             ? "SAR（サーバー逆指値）" : "損切り";
   if(reason == DEAL_REASON_TP) return "利確";
   if(reason == DEAL_REASON_SO) return "証拠金不足による強制決済";
   return "EA 以外の要因";
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
//| 直前の取引要求が「完全に約定した」か                             |
//|                                                                  |
//| 完全約定（DONE）だけを true にする。以下は数えない:              |
//|   PLACED       … 受け付けられただけで、まだ約定していない       |
//|   DONE_PARTIAL … 一部だけ約定し、残りが残っている               |
//|                                                                  |
//| これらを約定として扱うと、建玉が無いのに記録を作る／建玉が残る   |
//| のに記録を閉じる、といった食い違いが起きる。逆に false を返した  |
//| ときも、部分約定なら建玉自体は存在するため、気づけるようログへ   |
//| 明示的に出す（下の ReportTradeResult が retcode を書き出す）。   |
//|                                                                  |
//| ロットは固定の少量で、テスターの成行では DONE 以外はまず出ない。 |
//| 出たら手で確認する前提で、残量の自動処理までは持たない。         |
//+------------------------------------------------------------------+
bool IsFilled()
{
   return (g_trade.ResultRetcode() == TRADE_RETCODE_DONE);
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
