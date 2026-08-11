//+------------------------------------------------------------------+
//| SuperBollinger.mq5                                               |
//| スーパーボリンジャーの描画とルール1のサイン表示（目視確認用）    |
//|                                                                  |
//| 計算も判定も Include\Signals\SuperBollinger.mqh に置き、EA と    |
//| 共有する。本ファイルは描画だけを担当し、式も条件も持たない。     |
//|                                                                  |
//| 印は**判定した足**に出す。実際の約定は次の足の始値なので、印は   |
//| 約定より1本手前に立つ。条件の数値（データウィンドウの①②③④）  |
//| と同じ足に並べたほうが目視確認しやすいため、こちらを採っている。 |
//| 取引時刻との突き合わせはバックテストの CSV（約定時刻つき）で行う。|
//|                                                                  |
//| 保有中に出た同じ向きのサインには印を出さない。建玉を1つに限る    |
//| 決まりを本ファイル側でも追っているため。ここで模しているのは     |
//| 建玉1つ・X1 での手仕舞い までで、損切りと時間切れは EA が持つ。  |
//|                                                                  |
//| 確認の相手は Matrix Trader（ドル円5分足）。                      |
//| 計算定義は docs/indicator_spec.md §2.2、                         |
//| 売買条件は docs/trading_rules.md §4.1。                          |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_buffers 23
#property indicator_plots   21

#property indicator_label1  "センターライン"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2

#property indicator_label2  "+1σ"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrLimeGreen

#property indicator_label3  "-1σ"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrLimeGreen

#property indicator_label4  "+2σ"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrCrimson

#property indicator_label5  "-2σ"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrCrimson

#property indicator_label6  "+3σ"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrDeepSkyBlue

#property indicator_label7  "-3σ"
#property indicator_type7   DRAW_LINE
#property indicator_color7  clrDeepSkyBlue

#property indicator_label8  "遅行線"
#property indicator_type8   DRAW_LINE
#property indicator_color8  clrMagenta

#property indicator_label9  "買いサイン"
#property indicator_type9   DRAW_ARROW
#property indicator_color9  clrYellow
#property indicator_width9  5

#property indicator_label10 "売りサイン"
#property indicator_type10  DRAW_ARROW
#property indicator_color10 clrOrangeRed
#property indicator_width10 5

// 以下は線を引かない。データウィンドウで足ごとに条件の成否を読むためだけの枠。
// どの条件で止まったのかを、チャートを見ながらその場で切り分けられる。
#property indicator_label11 "①膠着 (1=成立)"
#property indicator_type11  DRAW_NONE
#property indicator_label12 "②遅行線 (1=陽転 -1=陰転 0=絡む)"
#property indicator_type12  DRAW_NONE
#property indicator_label13 "③突破 (1=上抜け -1=下抜け)"
#property indicator_type13  DRAW_NONE
#property indicator_label14 "④拡大 (1=成立)"
#property indicator_type14  DRAW_NONE
#property indicator_label15 "遅行スパンの位置 (σ)"
#property indicator_type15  DRAW_NONE

// 決済は白にしない。ローソク足の実体が白く塗られる配色だと同化して見えない
// （2026-08-09 に実際そうなった）。買いに関する印は足の下、売りに関する印は
// 足の上へ揃えるので、エントリーと決済が対で追える。
#property indicator_label16 "買いの決済"
#property indicator_type16  DRAW_ARROW
#property indicator_color16 clrAqua
#property indicator_width16 5

#property indicator_label17 "売りの決済"
#property indicator_type17  DRAW_ARROW
#property indicator_color17 clrAqua
#property indicator_width17 5

// 段階エントリーが有効なときだけ出る。装填した足に売買の矢印は出ない
// （発注していないため）ので位置は競合しない。■ と ● で段階を分ける。
#property indicator_label18 "装填1（ダマシ）"
#property indicator_type18  DRAW_ARROW
#property indicator_color18 clrMediumOrchid
#property indicator_width18 5

#property indicator_label19 "装填2（損切り）"
#property indicator_type19  DRAW_ARROW
#property indicator_color19 clrHotPink
#property indicator_width19 5

#property indicator_label20 "装填 (1=装填1 2=装填2)"
#property indicator_type20  DRAW_NONE
#property indicator_label21 "装填1 からの本数"
#property indicator_type21  DRAW_NONE

#include <Signals\SuperBollinger.mqh>

input int    InpPeriod      = 21;    // 期間（センターラインとσ）
input int    InpLagBars     = 21;    // 遅行線の本数
input bool   InpUseSqueeze  = true;  // ①膠着を条件に入れる
input int    InpSqueezeBars = 21;    // ①膠着とみなす本数（この本数ぶん帯の内側）
input double InpSigmaMult   = 3.0;   // ①③で使うσの倍数
input bool   InpUseLag      = true;  // ②遅行線の陽転/陰転を条件に入れる
input bool   InpUseExpand   = true;  // ④バンド幅の拡大を条件に入れる
input int    InpExpandBars  = 3;     // ④拡大を見る本数
input ENUM_SB_EXIT InpExit  = SB_EXIT_CLOSE_SIGMA1;  // 決済の方式

//--- 段階エントリー。既定は「使わない」＝従来どおりの動き
input ENUM_SB_STAGED InpStagedMode = SB_STAGED_OFF;  // 段階エントリー
input int    InpArmBars     = 42;     // 装填が生きている本数（装填1 から数える）
input bool   InpUseRsiExit  = false;  // RSI が行きすぎたら決済する（段階エントリーとは独立）
input int    InpRsiPeriod   = 14;     // RSI の期間
input double InpRsiUpper    = 80.0;   // 買いを見送る／買いを決済する RSI
input double InpRsiLower    = 20.0;   // 売りを見送る／売りを決済する RSI

double BufCenter[], BufU1[], BufL1[], BufU2[], BufL2[], BufU3[], BufL3[], BufLag[];
double BufBuy[], BufSell[];
double BufC1[], BufC2[], BufC3[], BufC4[], BufLagZ[];
double BufExitBuy[], BufExitSell[];
double BufArm1[], BufArm2[], BufArmStage[], BufArmAge[];
double BufArmDir[]; // 装填1 の向き。差分更新で状態を引き継ぐためだけに持つ
double BufPos[];    // 各足を処理し終えた時点の建玉（+1 買い / −1 売り / 0 無し）

SBRule1Params  g_rule1;
SBStagedParams g_staged;
int            g_rsiHandle = INVALID_HANDLE;
bool           g_needRsi   = false;   // 入口の見送りか決済か、どちらかで RSI を使う

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpPeriod < 2)
   {
      Print("期間は 2 以上にしてください（σ の分母が 期間−1 のため）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpLagBars < 1)
   {
      Print("遅行線の本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSqueezeBars < 1)
   {
      Print("①膠着とみなす本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpExpandBars < 1)
   {
      Print("④拡大を見る本数は 1 以上にしてください（0 では常に不成立になる）");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSigmaMult <= 0.0)
   {
      Print("①③で使うσの倍数は 0 より大きくしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_needRsi = (InpStagedMode != SB_STAGED_OFF) || InpUseRsiExit;

   if(InpStagedMode != SB_STAGED_OFF && InpArmBars < 1)
   {
      Print("装填が生きている本数は 1 以上にしてください");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(g_needRsi)
   {
      if(InpRsiPeriod < 2)
      {
         Print("RSI の期間は 2 以上にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }
      if(!(InpRsiLower > 0.0 && InpRsiLower < InpRsiUpper && InpRsiUpper < 100.0))
      {
         Print("RSI の閾値は 0 < 売り側 < 買い側 < 100 にしてください");
         return INIT_PARAMETERS_INCORRECT;
      }

      g_rsiHandle = iRSI(_Symbol, _Period, InpRsiPeriod, PRICE_CLOSE);
      if(g_rsiHandle == INVALID_HANDLE)
      {
         PrintFormat("RSI を作成できませんでした (error=%d)", GetLastError());
         return INIT_FAILED;
      }
   }

   g_staged.stages   = (int)InpStagedMode;
   g_staged.armBars  = InpArmBars;
   g_staged.rsiUpper = InpRsiUpper;
   g_staged.rsiLower = InpRsiLower;

   g_rule1.period      = InpPeriod;
   g_rule1.lagBars     = InpLagBars;
   g_rule1.useSqueeze  = InpUseSqueeze;
   g_rule1.squeezeBars = InpSqueezeBars;
   g_rule1.sigmaMult   = InpSigmaMult;
   g_rule1.useLag      = InpUseLag;
   g_rule1.useExpand   = InpUseExpand;
   g_rule1.expandBars  = InpExpandBars;

   SetIndexBuffer(0, BufCenter, INDICATOR_DATA);
   SetIndexBuffer(1, BufU1,     INDICATOR_DATA);
   SetIndexBuffer(2, BufL1,     INDICATOR_DATA);
   SetIndexBuffer(3, BufU2,     INDICATOR_DATA);
   SetIndexBuffer(4, BufL2,     INDICATOR_DATA);
   SetIndexBuffer(5, BufU3,     INDICATOR_DATA);
   SetIndexBuffer(6, BufL3,     INDICATOR_DATA);
   SetIndexBuffer(7, BufLag,    INDICATOR_DATA);
   SetIndexBuffer(8, BufBuy,    INDICATOR_DATA);
   SetIndexBuffer(9, BufSell,   INDICATOR_DATA);
   SetIndexBuffer(10, BufC1,    INDICATOR_DATA);
   SetIndexBuffer(11, BufC2,    INDICATOR_DATA);
   SetIndexBuffer(12, BufC3,    INDICATOR_DATA);
   SetIndexBuffer(13, BufC4,    INDICATOR_DATA);
   SetIndexBuffer(14, BufLagZ,  INDICATOR_DATA);
   SetIndexBuffer(15, BufExitBuy,  INDICATOR_DATA);
   SetIndexBuffer(16, BufExitSell, INDICATOR_DATA);
   SetIndexBuffer(17, BufArm1,     INDICATOR_DATA);
   SetIndexBuffer(18, BufArm2,     INDICATOR_DATA);
   SetIndexBuffer(19, BufArmStage, INDICATOR_DATA);
   SetIndexBuffer(20, BufArmAge,   INDICATOR_DATA);
   SetIndexBuffer(21, BufArmDir,   INDICATOR_CALCULATIONS);
   SetIndexBuffer(22, BufPos,      INDICATOR_CALCULATIONS);

   for(int p = 0; p < 21; p++)
      PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

   // 印は足の外側へ逃がす。安値・高値そのものに描くとローソク足に重なって
   // 位置が読めない（負のシフトが上、正が下・単位はピクセル）。
   // 買いは下、売りは上でエントリーと決済を揃える。
   PlotIndexSetInteger(8,  PLOT_ARROW, 233);  // ↑ 買いエントリー
   PlotIndexSetInteger(8,  PLOT_ARROW_SHIFT,  16);
   PlotIndexSetInteger(9,  PLOT_ARROW, 234);  // ↓ 売りエントリー
   PlotIndexSetInteger(9,  PLOT_ARROW_SHIFT, -16);
   PlotIndexSetInteger(15, PLOT_ARROW, 251);  // ✗ 買いの決済
   PlotIndexSetInteger(15, PLOT_ARROW_SHIFT,  16);
   PlotIndexSetInteger(16, PLOT_ARROW, 251);  // ✗ 売りの決済
   PlotIndexSetInteger(16, PLOT_ARROW_SHIFT, -16);
   // 装填1 に 158（○）を使うと、同じ太さでも 159（●）より小さく描かれる。
   // 字そのものが小さいので太さでは埋められない。形の違う 110（■）にする
   PlotIndexSetInteger(17, PLOT_ARROW, 110);  // ■ 装填1
   PlotIndexSetInteger(17, PLOT_ARROW_SHIFT, -16);
   PlotIndexSetInteger(18, PLOT_ARROW, 159);  // ● 装填2
   PlotIndexSetInteger(18, PLOT_ARROW_SHIFT, -16);

   IndicatorSetInteger(INDICATOR_DIGITS, _Digits);
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("スーパーボリンジャー(%d, 遅行%d)", InpPeriod, InpLagBars));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_rsiHandle != INVALID_HANDLE)
      IndicatorRelease(g_rsiHandle);
}

//+------------------------------------------------------------------+
//| 描画                                                             |
//|                                                                  |
//| 共通ファイル側が「添字 0 = 最新足」を前提にするため、終値と全    |
//| バッファを時系列順に切り替えてから渡す。                         |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
   if(rates_total < InpPeriod)
      return 0;

   ArraySetAsSeries(close,     true);
   ArraySetAsSeries(high,      true);
   ArraySetAsSeries(low,       true);
   ArraySetAsSeries(BufCenter, true);
   ArraySetAsSeries(BufU1,     true);
   ArraySetAsSeries(BufL1,     true);
   ArraySetAsSeries(BufU2,     true);
   ArraySetAsSeries(BufL2,     true);
   ArraySetAsSeries(BufU3,     true);
   ArraySetAsSeries(BufL3,     true);
   ArraySetAsSeries(BufLag,    true);
   ArraySetAsSeries(BufBuy,    true);
   ArraySetAsSeries(BufSell,   true);
   ArraySetAsSeries(BufC1,     true);
   ArraySetAsSeries(BufC2,     true);
   ArraySetAsSeries(BufC3,     true);
   ArraySetAsSeries(BufC4,     true);
   ArraySetAsSeries(BufLagZ,   true);
   ArraySetAsSeries(BufExitBuy,  true);
   ArraySetAsSeries(BufExitSell, true);
   ArraySetAsSeries(BufArm1,     true);
   ArraySetAsSeries(BufArm2,     true);
   ArraySetAsSeries(BufArmStage, true);
   ArraySetAsSeries(BufArmAge,   true);
   ArraySetAsSeries(BufArmDir,   true);
   ArraySetAsSeries(BufPos,      true);

   // 初回は全ての足を走査する。計算に必要な本数が揃わない最も古い側にも
   // 「描かない印」を入れる必要があり、飛ばすと MT5 側の初期値のまま線が
   // 引かれてしまう（チャート左端で 0 へ落ちる）。
   int limit = rates_total - 1;

   if(prev_calculated > 0)
   {
      // 遅行線の先端は最新から InpLagBars 本手前にある。足が1本増えるたび
      // その位置は新しい足へ移るので、更新するのが直近数本だけだと先端が
      // 二度と計算されず、遅行線だけ伸びなくなる。必ず先端まで含める。
      limit = MathMax(rates_total - prev_calculated + 1, InpLagBars);
      limit = MathMin(limit, rates_total - 1);
   }

   // 建玉の有無を追う。決済条件は7割以上の足で真になるので、保有中かどうか
   // を知らないと決済アイコンの意味が無い。ループは添字の大きい側（古い足）
   // から回るので、そのまま時系列順に建玉を持ち越せる。差分更新のときは1本
   // 古い足の状態を引き継ぐ（前回の計算で BufPos に残っている）。
   int pos = 0;
   SBArmState arm;
   arm.stage = 0;
   arm.dir   = 0;
   arm.age   = 0;
   if(limit + 1 <= rates_total - 1)
   {
      pos       = (int)BufPos[limit + 1];
      arm.stage = (int)BufArmStage[limit + 1];
      arm.dir   = (int)BufArmDir[limit + 1];
      arm.age   = (int)BufArmAge[limit + 1];
   }

   // RSI は2段階エントリーのときだけ要る。無効なら一切触らないので、
   // RSI がまだ計算できない場面でも従来どおり線とサインが描かれる。
   double rsi[];
   if(g_needRsi)
   {
      ArraySetAsSeries(rsi, true);
      if(CopyBuffer(g_rsiHandle, 0, 0, limit + 1, rsi) < limit + 1)
         return 0;   // まだ揃っていない。次のティックで全て計算し直す
   }

   for(int i = limit; i >= 0; i--)
   {
      SBValues v;
      if(SB_Calc(close, i, InpPeriod, v))
      {
         BufCenter[i] = v.center;
         BufU1[i]     = v.upper1;
         BufL1[i]     = v.lower1;
         BufU2[i]     = v.upper2;
         BufL2[i]     = v.lower2;
         BufU3[i]     = v.upper3;
         BufL3[i]     = v.lower3;
      }
      else
      {
         BufCenter[i] = EMPTY_VALUE;
         BufU1[i]     = EMPTY_VALUE;
         BufL1[i]     = EMPTY_VALUE;
         BufU2[i]     = EMPTY_VALUE;
         BufL2[i]     = EMPTY_VALUE;
         BufU3[i]     = EMPTY_VALUE;
         BufL3[i]     = EMPTY_VALUE;
      }

      // 最新から InpLagBars 本ぶんは値が無い。ここで線が切れるのが正しい
      double lag;
      BufLag[i] = SB_LagValue(close, i, InpLagBars, lag) ? lag : EMPTY_VALUE;

      // 売買サインと条件の内訳。形成中の足（添字 0）には出さない。判定は
      // 確定足のみという決まりのため（docs/trading_rules.md §2.1）で、ここ
      // に出すと足の途中で現れたり消えたりする値を EA の発火と見比べてしまう。
      BufBuy[i]       = EMPTY_VALUE;
      BufSell[i]      = EMPTY_VALUE;
      BufExitBuy[i]   = EMPTY_VALUE;
      BufExitSell[i]  = EMPTY_VALUE;
      BufC1[i]   = EMPTY_VALUE;
      BufC2[i]   = EMPTY_VALUE;
      BufC3[i]   = EMPTY_VALUE;
      BufC4[i]   = EMPTY_VALUE;
      BufLagZ[i] = EMPTY_VALUE;
      BufArm1[i] = EMPTY_VALUE;
      BufArm2[i] = EMPTY_VALUE;
      if(i >= 1)
      {
         SBRule1Signal s;
         const bool haveSignal = SB_Rule1(close, high, low, i, g_rule1, s);
         if(haveSignal)
         {
            BufC1[i] = s.squeezed  ? 1.0 : 0.0;
            BufC2[i] = s.lagAbove  ? 1.0 : (s.lagBelow  ? -1.0 : 0.0);
            BufC3[i] = s.crossUp   ? 1.0 : (s.crossDown ? -1.0 : 0.0);
            BufC4[i] = s.expanding ? 1.0 : 0.0;
         }
         double z;
         if(SB_LagOffset(close, i, InpLagBars, InpPeriod, z))
            BufLagZ[i] = z;

         // 発注する足を決める。2段階エントリーが有効なら「発火」、
         // 無効なら従来どおりサインそのもの
         bool entryBuy  = false;
         bool entrySell = false;
         if(haveSignal)
         {
            if(InpStagedMode != SB_STAGED_OFF)
            {
               // 装填2 へ進むかは、装填1 の向きで決済条件を見る。決済の
               // 方式は入力で選んだものをそのまま使う
               const bool stopHit =
                  SB_StagedStopHit(close, i, InpPeriod, InpLagBars, InpExit, g_staged, arm);

               SBStagedResult stg;
               SB_StagedStep(s, rsi[i], stopHit, g_staged, arm, stg);
               entryBuy  = stg.fireBuy;
               entrySell = stg.fireSell;
               if(stg.arm1Now) BufArm1[i] = high[i];
               if(stg.arm2Now) BufArm2[i] = high[i];
            }
            else
            {
               entryBuy  = s.buy;
               entrySell = s.sell;
            }
         }

         // 手仕舞いが先。同じ足で決済と反対の発注が揃えばドテンになる
         if(pos != 0)
         {
            const bool wasLong = (pos > 0);
            bool doExit = false;
            bool hit = SB_Rule1Exit(close, i, InpPeriod, InpLagBars, InpExit, wasLong, doExit) && doExit;

            // 独立した OR 条件。買いは RSI が上限以上、売りは下限以下で降りる
            if(!hit && InpUseRsiExit && SB_RsiExtreme(rsi[i], wasLong, g_staged))
               hit = true;

            if(hit)
            {
               if(wasLong) BufExitBuy[i]  = low[i];
               else        BufExitSell[i] = high[i];
               pos = 0;
            }
         }

         // 建玉は1つまで。保有中に出た同じ向きの発注は矢印を出さない
         // （EA も無視するため。条件が揃ったかどうかは上の①②③④で読む）
         if(pos == 0)
         {
            if(entryBuy)  { BufBuy[i]  = low[i];  pos =  1; }
            if(entrySell) { BufSell[i] = high[i]; pos = -1; }
         }
      }
      BufArmStage[i] = (double)arm.stage;
      BufArmAge[i]   = (arm.stage != 0) ? (double)arm.age : 0.0;
      BufArmDir[i]   = (double)arm.dir;
      BufPos[i]      = pos;
   }

   return rates_total;
}
