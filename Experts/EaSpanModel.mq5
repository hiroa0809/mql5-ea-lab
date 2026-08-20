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
//| ■ 膠着（スーパーボリンジャーの帯が細くなっている状態）           |
//|   エントリーの追加条件。**条件が揃った足そのものが膠着している    |
//|   ときだけ建てる**（2026-08-20 ユーザー判断）。「直前に膠着が     |
//|   あって今は解けている」形は取らない。                            |
//|                                                                  |
//|   **エントリーのきっかけは2通りあり、入力で選ぶ。**               |
//|   ・雲の色が変わったとき … 膠着の最中に色が変わるのを待つ         |
//|   ・膠着が始まったとき   … 色の変化を待たず、膠着に入った足で、   |
//|                            そのときの雲の色に従って建てる         |
//|   どちらでも、建てるには膠着していることが要る。                  |
//|                                                                  |
//|   **決済には掛けない。** 雲の色が反対になったら、膠着が解けて     |
//|   いても閉じる。膠着中にしか手仕舞いできないと、建てたまま        |
//|   出られない状態が起こりうるため。                                |
//|                                                                  |
//|   測り方は5通りあり、どれを採るかは未確定。入力で切り替えて       |
//|   バックテストの数字で決める（docs/trading_rules.md §6.1）。      |
//|   計算そのものは Include\Signals\Squeeze.mqh にあり、膠着メーター |
//|   のインジケーターと共有している。                                |
//|                                                                  |
//| ■ テスターでの目視                                               |
//|   入力「チャートにスパンモデルを表示する」を入れておくと、視覚   |
//|   モードのテストで同じ設定の指標がチャートに出る。矢印と約定位置 |
//|   を並べて確かめられる（矢印は約定より手前に立つ）。膠着を使う   |
//|   設定なら膠着メーターも一緒に出る。                              |
//|                                                                  |
//| 銘柄・時間足は入力にせず _Symbol / _Period を使う。テスターの     |
//| 設定がそのまま反映される（docs/implementation_design.md §1）。    |
//+------------------------------------------------------------------+
#property version   "1.20"
#property description "スパンモデル（ルール2）。膠着を AND 条件に足せる"

#include <Trade\Trade.mqh>
#include <Signals\SpanModel.mqh>
#include <Signals\Squeeze.mqh>

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

//+------------------------------------------------------------------+
//| 何をきっかけにエントリーするか                                   |
//|                                                                  |
//| **どちらのきっかけでも、建てるには膠着していることが要る。** 違う |
//| のは「いつ建てるか」だけ。                                        |
//|                                                                  |
//| ・雲の色が変わったとき … 膠着が続いている最中に色が変わるのを待つ。|
//|   向きは転換した先の色。                                          |
//| ・膠着が始まったとき   … 色の変化を待たず、膠着に入った足で建てる。|
//|   向きはそのときの雲の色。膠着の途中で色が変わっても建て直さない。|
//|                                                                  |
//| 「どちらでも」は両方を引き金にする。同じ足で両方成立した場合、    |
//| 転換した先の色と現在の色は必ず一致するので向きは食い違わない。    |
//+------------------------------------------------------------------+
enum ENUM_ENTRY_TRIGGER
{
   TRIG_CLOUD_FLIP    = 0,   // 雲の色が変わったとき
   TRIG_SQUEEZE_START = 1,   // 膠着が始まったとき
   TRIG_BOTH          = 2    // どちらでも
};

//+------------------------------------------------------------------+
//| 膠着を条件に入れるか、入れるならどの測り方か                     |
//|                                                                  |
//| Squeeze.mqh の5通りに「使わない」を足しただけ。**入り切りを別の   |
//| 項目にしないのは、切ったときに測り方・時間足・本数を振っても結果  |
//| が変わらない組み合わせが総当たりに並ぶため**（PR #18 で②④に対し  |
//| て同じ整理をした）。                                              |
//|                                                                  |
//| 値は Squeeze.mqh の並びに 1 を足したもの。0 だけが「使わない」。  |
//+------------------------------------------------------------------+
enum ENUM_SQZ_USE
{
   SQZ_USE_OFF          = 0,   // 使わない
   SQZ_USE_BW_RANK      = 1,   // ①帯の幅の順位
   SQZ_USE_BW_RANK_HOUR = 2,   // ②帯の幅の順位（時刻別）
   SQZ_USE_KELTNER      = 3,   // ③ケルトナーの内側
   SQZ_USE_RANGE_SIGMA  = 4,   // ④高値安値のばらつきの順位
   SQZ_USE_RANGE_RANK   = 5    // ⑤値幅の順位
};

//+------------------------------------------------------------------+
//| 膠着をどの時間足で測るか                                         |
//|                                                                  |
//| 売買ルールの資料は上位足で相場の状態を見る前提だが、その根拠は    |
//| 慣習どまりで実測の裏付けが無い。売買する足そのもので測る案も残し、|
//| バックテストの数字で決める（2026-08-20 ユーザー判断）。          |
//|                                                                  |
//| **値は 0 から続く連番にしてある。** MT5 が時間足に振っている番号   |
//| （1時間足 16385・4時間足 16388・日足 16408）をそのまま選択肢の値に |
//| すると飛び飛びになり、総当たりで刻み幅を指定したときに何が試され  |
//| るかが読めなくなる。時間足への読み替えは下の関数で行う。          |
//+------------------------------------------------------------------+
enum ENUM_SQZ_TF
{
   SQZ_TF_SAME = 0,   // 売買する足と同じ
   SQZ_TF_H1   = 1,   // 1時間足
   SQZ_TF_H4   = 2,   // 4時間足
   SQZ_TF_D1   = 3    // 日足
};

//+------------------------------------------------------------------+
//| 選択肢を実際の時間足へ読み替える                                 |
//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SqueezeTimeframe(const ENUM_SQZ_TF m)
{
   switch(m)
   {
      case SQZ_TF_H1: return PERIOD_H1;
      case SQZ_TF_H4: return PERIOD_H4;
      case SQZ_TF_D1: return PERIOD_D1;
   }
   return (ENUM_TIMEFRAMES)_Period;   // 売買する足と同じ
}

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

//--- 膠着（エントリーの追加条件）。決済には掛からない。
//--- 水準は既定の 10（下から10%）のまま振らない。⑤値幅の順位は本数を
//--- 6 にすれば「下から10%」が「7本で最小」と同じ意味になり、慣習の
//--- NR7 をこの水準のまま表せる（6本のうち自分より小さい足が 0.6 本
//--- 以下 ＝ 0 本、つまり最小）。
input ENUM_ENTRY_TRIGGER InpEntryTrigger = TRIG_CLOUD_FLIP;   // エントリーのきっかけ
input ENUM_SQZ_USE InpSqueezeUse       = SQZ_USE_OFF;   // 膠着の測り方（エントリーの追加条件）
input ENUM_SQZ_TF  InpSqueezeTF        = SQZ_TF_SAME;   // 膠着を測る時間足
input int          InpSqueezePeriod    = 21;            // 膠着: 期間（センターラインとσ）
input int          InpSqueezeLookback  = 120;           // 膠着: 順位を見る本数
input double       InpSqueezeThreshold = 10.0;          // 膠着とみなす水準（順位方式のみ）
input double       InpSqueezeKcMult    = 1.5;           // 膠着: ケルトナーの倍率

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
int           g_smHandle = INVALID_HANDLE;   // 表示用に読み込んだスパンモデル
int           g_sqHandle = INVALID_HANDLE;   // 表示用に読み込んだ膠着メーター

//--- 膠着まわり。使わない設定のときは触らない。
ENUM_SQUEEZE_METHOD g_sqzMethod    = SQZ_BW_RANK;
ENUM_TIMEFRAMES     g_sqzTf        = PERIOD_CURRENT;
double              g_sqzThreshold = 0.0;   // 実際に使う水準（③は入力を使わない）
int                 g_sqzNeedBars  = 0;     // 1回の判定に必要な膠着側の本数

//--- 膠着の状態。足が変わるたびに SqueezeUpdate で更新する。
datetime g_sqzBar     = 0;       // 直前に判定した、膠着を測る足の時刻
bool     g_sqzHaveBar = false;   // 一度でも判定できたか
bool     g_sqzActive  = false;   // その足が膠着しているか
bool     g_sqzStarted = false;   // その足で膠着が始まったか
bool     g_sqzKnown   = false;   // 今の足の膠着を判定できているか

//--- 診断用の計数。取引ゼロで終わったときに、どの条件で止まったのかを
//--- 切り分けるためだけのもの（docs/implementation_design.md §4）。
//--- ②③④は**雲が転換した足だけ**、その転換の向きについて数える。
//--- 転換しない足には向きが無く、「買いの②」も「売りの②」も定義でき
//--- ないため。設計書は「各条件を単独で数える」としているが、ルール2は
//--- ①が向きを決める引き金なので、ここだけは①の成立足に限る。
long g_cntFlip = 0, g_cntLag = 0, g_cntClosePos = 0, g_cntSlope = 0;
long g_cntBuySignal = 0, g_cntSellSignal = 0;
long g_cntEntry = 0, g_cntExit = 0, g_cntOrderFailed = 0, g_cntBlocked = 0;

//--- 膠着で止めた回数。**「膠着していなかった」と「膠着を計算できな
//--- かった」を分けて数える。** 履歴が足りずに一度も計算できていない
//--- 状態は、条件が厳しくて建たない状態と結果が同じになるため、合算
//--- すると取引ゼロの原因を切り分けられない。
long g_cntSqzPass = 0, g_cntSqzReject = 0, g_cntSqzNoData = 0;

//--- 膠着が始まった足の数。「膠着が始まったとき」をきっかけに選んだのに
//--- 取引が出ないとき、引き金が一度も引かれていないのか、引かれたが雲の
//--- 色が付かなかったのかを分けるため。
long g_cntSqzStart = 0;

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
//| エントリーのきっかけを日本語にする（起動時のログ用）             |
//+------------------------------------------------------------------+
string EntryTriggerText(const ENUM_ENTRY_TRIGGER t)
{
   switch(t)
   {
      case TRIG_CLOUD_FLIP:    return "雲の色が変わったとき";
      case TRIG_SQUEEZE_START: return "膠着が始まったとき（雲の色に従う）";
      case TRIG_BOTH:          return "どちらでも";
   }
   return "不明";
}

//+------------------------------------------------------------------+
//| 膠着を測る足のうち、判定する足の時点で確定していた1本を探す      |
//|                                                                  |
//| **判定した足が閉じた時点で終値が決まっていた足しか使わない。**    |
//| 判定足をまだ含んでいる最中の上位足を使うと、これから起きる値動き  |
//| を先に見てしまい、バックテストだけが良く見える。                  |
//|                                                                  |
//| 「売買する足と同じ」を選んだときは、判定足そのものが過去の確定足  |
//| なのでその足がそのまま返る。下の式は上位足と同じ足を区別せずに    |
//| 扱える（同じ足なら終了時刻がちょうど一致し、1本前へは下がらない）。|
//|                                                                  |
//| 戻り値 false は「時刻が取れない」。呼ぶ側は判定を見送ること。     |
//+------------------------------------------------------------------+
bool SqueezeBarShift(const int shift, int &sqzShift, datetime &sqzBarTime)
{
   const datetime tOpen = iTime(_Symbol, _Period, shift);
   if(tOpen == 0) return false;

   const datetime tClose = tOpen + PeriodSeconds(_Period);   // 判定足が閉じる時刻

   int h = iBarShift(_Symbol, g_sqzTf, tClose - 1, false);
   if(h < 0) return false;

   datetime hOpen = iTime(_Symbol, g_sqzTf, h);
   if(hOpen == 0) return false;

   if(hOpen + PeriodSeconds(g_sqzTf) > tClose)   // まだ動いている最中
   {
      h++;
      hOpen = iTime(_Symbol, g_sqzTf, h);
      if(hOpen == 0) return false;
   }

   sqzShift   = h;
   sqzBarTime = hOpen;
   return true;
}

//+------------------------------------------------------------------+
//| その足が膠着しているかを求める                                   |
//|                                                                  |
//| 順位方式は「測る値」を必要な本数ぶん並べてから順位を取る。並べる  |
//| 対象は Squeeze.mqh の測り方ごとに違う（帯の幅／高値安値のばらつき |
//| ／その足の値幅）。ケルトナーだけは過去の分布を使わないので、その  |
//| 足1本で決まる。                                                  |
//|                                                                  |
//| 戻り値 false は「まだ計算できない」（履歴が足りない）。**条件を   |
//| 満たさなかったのとは別に数える。**                                |
//+------------------------------------------------------------------+
bool SqueezeCalc(const int sqzShift, bool &active)
{
   const int need = sqzShift + g_sqzNeedBars;

   double high[], low[], close[];
   datetime time[];
   ArraySetAsSeries(high,  true);
   ArraySetAsSeries(low,   true);
   ArraySetAsSeries(close, true);
   ArraySetAsSeries(time,  true);

   if(CopyHigh (_Symbol, g_sqzTf, 0, need, high)  < need) return false;
   if(CopyLow  (_Symbol, g_sqzTf, 0, need, low)   < need) return false;
   if(CopyClose(_Symbol, g_sqzTf, 0, need, close) < need) return false;
   if(CopyTime (_Symbol, g_sqzTf, 0, need, time)  < need) return false;

   if(g_sqzMethod == SQZ_KELTNER)
   {
      double ratio;
      if(!SQZ_KeltnerRatio(close, high, low, sqzShift, InpSqueezePeriod,
                           InpSqueezeKcMult, ratio)) return false;

      active = SQZ_IsSqueezed(g_sqzMethod, ratio, g_sqzThreshold);
      return true;
   }

   double raw[];
   if(ArrayResize(raw, need) < need) return false;

   // 時刻別は同じ時刻の足しか母集団に入らない（24本に1本）。**入らない
   // 足の値は最初から計算しない。** 遡る範囲が本数の32倍あるので、全部
   // 求めると23/24を捨てるためだけに作ることになり、売買する足と同じ足で
   // 測る設定では毎足それが走って5分足のテストが桁で延びる。
   const bool sameHour = SQZ_UsesHour(g_sqzMethod);
   const int  curHour  = sameHour ? SQZ_HourOf(time[sqzShift]) : 0;

   for(int i = 0; i < need; i++)
   {
      if(sameHour && SQZ_HourOf(time[i]) != curHour)
      {
         raw[i] = EMPTY_VALUE;
         continue;
      }

      double v = 0.0;
      bool   ok = false;

      if(g_sqzMethod == SQZ_BW_RANK || g_sqzMethod == SQZ_BW_RANK_HOUR)
         ok = SQZ_BandWidth(close, i, InpSqueezePeriod, v);
      else if(g_sqzMethod == SQZ_RANGE_SIGMA)
         ok = SQZ_ParkinsonSigma(high, low, i, InpSqueezePeriod, v);
      else
         ok = SQZ_BarRange(high, low, i, v);

      raw[i] = ok ? v : EMPTY_VALUE;   // 求まらない足は母集団から外れる
   }

   double pct;
   if(!SQZ_Rank(raw, time, sqzShift, InpSqueezeLookback, sameHour, pct)) return false;

   active = SQZ_IsSqueezed(g_sqzMethod, pct, g_sqzThreshold);
   return true;
}

//+------------------------------------------------------------------+
//| 膠着の状態を更新する — **足が変わるたびに必ず呼ぶ**              |
//|                                                                  |
//| 「膠着が始まった」は前の足との差なので、建てたい足だけ調べたので |
//| では始まりを取り逃す。                                            |
//|                                                                  |
//| 膠着を測る足が売買する足より長いときは、下位足が何本進んでも同じ |
//| 上位足を指す。**同じ足なら計算し直さない。** 遡る範囲が本数の32倍 |
//| になる②時刻別では1本あたり数万回の掛け算になり、これが無いと     |
//| 5分足のテストが何十分も延びる。                                   |
//+------------------------------------------------------------------+
void SqueezeUpdate(const int shift)
{
   g_sqzStarted = false;

   if(InpSqueezeUse == SQZ_USE_OFF)
   {
      g_sqzActive = true;    // 使わないときは常に通す
      g_sqzKnown  = true;
      return;
   }

   g_sqzKnown = false;

   int      sqzShift = 0;
   datetime sqzBar   = 0;
   if(!SqueezeBarShift(shift, sqzShift, sqzBar))
   {
      g_cntSqzNoData++;
      g_sqzHaveBar = false;   // 下の「始まり」の判定を参照
      return;
   }

   if(g_sqzHaveBar && sqzBar == g_sqzBar)   // 同じ足 → 前回の結果を使う
   {
      g_sqzKnown = true;
      return;
   }

   bool active = false;
   if(!SqueezeCalc(sqzShift, active))
   {
      g_cntSqzNoData++;

      // **判定できなかったら印を下げる。** 下げないと、判定が数本飛んだ
      // 後で膠着していたときに、その間ずっと続いていたかもしれない膠着を
      // 「始まった」と数えてしまう。飛んだ区間は分からないのだから、
      // 分からないままにして始まりとは数えない。
      g_sqzHaveBar = false;
      return;
   }

   // 始まりと言えるのは、**前の足を判定できていたときだけ**。履歴が
   // 足りずに飛んだ直後を「始まった」と数えると、実際には続いていた
   // 膠着が何度も始まったことになる。
   g_sqzStarted = active && g_sqzHaveBar && !g_sqzActive;
   if(g_sqzStarted) g_cntSqzStart++;

   g_sqzActive  = active;
   g_sqzBar     = sqzBar;
   g_sqzHaveBar = true;
   g_sqzKnown   = true;
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

   ShowSpanModel();
   ShowSqueezeGauge();
}

//+------------------------------------------------------------------+
//| 読み込んだ指標をチャートへ載せる                                 |
//|                                                                  |
//| 視覚モードでは、EA が読み込んだ指標を MT5 が自動でチャートへ出す。|
//| ここで明示的に足すのは、実口座のチャートへ EA を載せたときにも    |
//| 同じ絵を出すため。失敗しても指標そのものは表示される。            |
//+------------------------------------------------------------------+
void AttachIndicator(const int handle, const int window, const string label)
{
   if(!ChartIndicatorAdd(0, window, handle))
      PrintFormat("%s をチャートへ追加できませんでした（エラー %d）。視覚モードなら自動で表示されます",
                  label, GetLastError());
   else
      PrintFormat("チャートに%sを表示します", label);
}

//+------------------------------------------------------------------+
//| スパンモデルをチャートへ出す                                     |
//|                                                                  |
//| 本リポジトリは MT5 のデータフォルダへジャンクションで繋いでいる   |
//| ため指標は Indicators\mql5-ea-lab\ にある（.claude/rules/         |
//| mql5-build.md）。標準の Indicators 直下へ置いた環境でも動くよう、 |
//| 両方を試す。渡す引数は EA が実際に使う値と同じにする。②は指標側が|
//| 3つの入り切りなので、展開したものを渡す。                        |
//+------------------------------------------------------------------+
void ShowSpanModel()
{
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

      AttachIndicator(g_smHandle, 0, "スパンモデル");
      return;
   }

   Print("スパンモデルの指標が見つかりません。チャートへの表示は行いません");
}

//+------------------------------------------------------------------+
//| 膠着メーターをチャートへ出す                                     |
//|                                                                  |
//| **建玉が膠着している所で起きているかを目で確かめるための表示。**  |
//| 膠着メーターは別ウィンドウに 0〜100 で出て、点線より下にいる間だけ|
//| 棒が金色になる。金色の所にだけ約定が並んでいれば条件どおり。      |
//|                                                                  |
//| 渡す引数は EA が実際に使う値と同じにする。膠着とみなす水準だけは  |
//| 入力の生値を渡す（③のときに 100 へ読み替えるのは指標側も同じ関数 |
//| で行うので、読み替え済みの値を渡すと二重にならないが、入力画面と  |
//| 見比べたときに食い違って見える）。                                |
//+------------------------------------------------------------------+
void ShowSqueezeGauge()
{
   if(InpSqueezeUse == SQZ_USE_OFF) return;

   string paths[2] = {"mql5-ea-lab\\SqueezeGauge", "SqueezeGauge"};

   for(int i = 0; i < 2; i++)
   {
      g_sqHandle = iCustom(_Symbol, _Period, paths[i],
                           g_sqzTf, g_sqzMethod, InpSqueezePeriod,
                           InpSqueezeLookback, InpSqueezeThreshold, InpSqueezeKcMult);
      if(g_sqHandle == INVALID_HANDLE)
      {
         ResetLastError();
         continue;
      }

      AttachIndicator(g_sqHandle, (int)ChartGetInteger(0, CHART_WINDOWS_TOTAL), "膠着メーター");
      return;
   }

   Print("膠着メーターの指標が見つかりません。チャートへの表示は行いません");
}

//+------------------------------------------------------------------+
//| 膠着まわりの設定を組み立て、成り立たない指定を弾く               |
//|                                                                  |
//| **弾くのは、成り立たない設定が「取引ゼロ」という同じ見た目に      |
//| なるため。** 起動できてしまうと、条件が厳しかったのか設定が壊れて |
//| いたのかを結果から区別できない。総当たりでは弾かれた組み合わせが  |
//| 除外され、そのぶん実行回数も減る。                                |
//+------------------------------------------------------------------+
bool SetupSqueeze()
{
   if(InpSqueezeUse == SQZ_USE_OFF)
   {
      if(InpEntryTrigger != TRIG_CLOUD_FLIP)
      {
         // 膠着を使わない設定では膠着が始まることも無い。この組み合わせ
         // は必ず取引ゼロで終わり、条件が厳しいのと見分けが付かない。
         Print("エントリーのきっかけに「膠着が始まったとき」を含めるなら、膠着の測り方も選んでください（使わない設定では一度も始まりません）");
         return false;
      }

      Print("膠着は条件に入れません（雲の色の変化だけで判定します）");
      return true;
   }

   g_sqzMethod = (ENUM_SQUEEZE_METHOD)(InpSqueezeUse - 1);
   g_sqzTf     = SqueezeTimeframe(InpSqueezeTF);

   if(InpSqueezeTF != SQZ_TF_SAME && PeriodSeconds(g_sqzTf) <= PeriodSeconds(_Period))
   {
      // 売買する足より短い足で測っても上位足を見たことにならない。
      // ちょうど同じ足になる指定は「売買する足と同じ」と結果が完全に
      // 一致するので、総当たりで二度測らないようここで落とす。
      PrintFormat("膠着を測る足（%s）は売買する足（%s）より長くしてください。同じ足で測るなら「売買する足と同じ」を選びます",
                  EnumToString(g_sqzTf), EnumToString((ENUM_TIMEFRAMES)_Period));
      return false;
   }

   if(InpSqueezePeriod < 2)
   {
      Print("膠着の期間は 2 以上にしてください（σ の分母が 期間−1 のため）");
      return false;
   }
   if(SQZ_UsesRank(g_sqzMethod) && InpSqueezeLookback < 2)
   {
      Print("膠着で順位を見る本数は 2 以上にしてください");
      return false;
   }
   if(g_sqzMethod == SQZ_KELTNER && InpSqueezeKcMult <= 0.0)
   {
      Print("ケルトナーの倍率は 0 より大きくしてください");
      return false;
   }

   if(SQZ_UsesHour(g_sqzMethod) && g_sqzTf == PERIOD_D1)
   {
      // 日足はどの足も同じ時刻なので、時刻で母集団を絞っても①と同じに
      // なる。しかも必要な本数だけが24倍になり、履歴が届かず一度も
      // 成立しないまま取引ゼロで終わる。
      Print("②帯の幅の順位（時刻別）は日足では使えません。日足はどの足も同じ時刻で、①と同じ結果になります");
      return false;
   }

   g_sqzThreshold = SQZ_EffectiveThreshold(g_sqzMethod, InpSqueezeThreshold);
   g_sqzNeedBars  = SQZ_RequiredBars(g_sqzMethod, InpSqueezePeriod, InpSqueezeLookback);

   PrintFormat("エントリーのきっかけ: %s", EntryTriggerText(InpEntryTrigger));

   PrintFormat("膠着: %s ／ 測る足 %s ／ 期間 %d ／ 順位を見る本数 %d ／ 水準 %.1f ／ ケルトナー倍率 %.2f",
               SQZ_MethodLabel(g_sqzMethod),
               (InpSqueezeTF == SQZ_TF_SAME) ? "売買する足と同じ" : EnumToString(g_sqzTf),
               InpSqueezePeriod, InpSqueezeLookback, g_sqzThreshold, InpSqueezeKcMult);

   if(g_sqzMethod == SQZ_KELTNER && InpSqueezeThreshold != g_sqzThreshold)
      PrintFormat("ケルトナーの水準は入力（%.1f）ではなく %.1f を使います。境目は定義に埋まっており動かせません",
                  InpSqueezeThreshold, g_sqzThreshold);

   return true;
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

   if(!SetupSqueeze()) return INIT_PARAMETERS_INCORRECT;

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
   if(g_sqHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_sqHandle);
      g_sqHandle = INVALID_HANDLE;
   }

   if(!InpPrintCounters) return;

   PrintFormat("[ルール2] ①雲の転換 %I64d   （うち②を通った %I64d / ③ %I64d / ④ %I64d）",
               g_cntFlip, g_cntLag, g_cntClosePos, g_cntSlope);
   PrintFormat("          サイン 買い %I64d / 売り %I64d   建玉 %I64d / 決済 %I64d   発注失敗 %I64d   他建玉で見送り %I64d",
               g_cntBuySignal, g_cntSellSignal, g_cntEntry, g_cntExit,
               g_cntOrderFailed, g_cntBlocked);
   PrintFormat("          執行: エントリー %d 本後 / 決済 %d 本後（1 = 次の足の始値）",
               InpEntryDelayBars, InpExitDelayBars);

   PrintFormat("          きっかけ: %s", EntryTriggerText(InpEntryTrigger));

   if(InpSqueezeUse == SQZ_USE_OFF)
   {
      Print("          膠着: 使わない");
      return;
   }

   PrintFormat("          膠着(%s): 引き金が引かれたうち 膠着していた %I64d / していなかった %I64d   膠着が始まった足 %I64d   計算できなかった足 %I64d",
               SQZ_MethodLabel(g_sqzMethod), g_cntSqzPass, g_cntSqzReject,
               g_cntSqzStart, g_cntSqzNoData);

   // 一度も計算できていない状態は、条件が厳しくて建たない状態と結果が
   // 同じ「取引ゼロ」になる。黙って通さず名指しで出す。
   if(g_cntSqzStart == 0 && g_cntSqzPass == 0 && g_cntSqzReject == 0 && g_cntSqzNoData > 0)
      Print("          膠着を一度も計算できていません。履歴が足りない可能性があります（順位を見る本数を減らすか、測る足を短くしてください）");
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

   // 膠着の状態は**毎足**更新する。「始まった」は前の足との差なので、
   // 建てたい足だけ調べたのでは始まりを取り逃す。
   SqueezeUpdate(InpEntryDelayBars);

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

   // ── 引き金 ───────────────────────────────────────────
   bool wantBuy = false, wantSell = false;

   // 1つめ: 雲の色が変わった。向きは転換した先の色。
   if(InpEntryTrigger != TRIG_SQUEEZE_START)
   {
      wantBuy  = s.buy;
      wantSell = s.sell;
   }

   // 2つめ: 膠着が始まった。**色の変化を待たず、そのときの雲の色に
   // 従って建てる。** ②③④は色の変化を引き金にしたときと同じ形で効か
   // せる（SM_Rule2 の buyOk / sellOk が①以外をまとめたもの）。
   if(InpEntryTrigger != TRIG_CLOUD_FLIP && g_sqzStarted)
   {
      const int cloud = CloudColor(high, low, InpEntryDelayBars);
      if(cloud ==  1 && s.buyOk)  wantBuy  = true;
      if(cloud == -1 && s.sellOk) wantSell = true;
   }

   if(!wantBuy && !wantSell) return;

   // ── 膠着 ─────────────────────────────────────────────
   // **エントリーだけに掛ける。** 決済は上で済ませてあり、雲の色が
   // 反対になれば膠着が解けていても閉じる（2026-08-20 ユーザー判断）。
   // 「膠着が始まったとき」を引き金にした場合はここは必ず通るが、
   // 引き金を分けずに1箇所で見ることで、両方に確実に掛かる。
   if(InpSqueezeUse != SQZ_USE_OFF)
   {
      if(!g_sqzKnown) return;   // 計算できていない（SqueezeUpdate で計上済み）
      if(!g_sqzActive)
      {
         g_cntSqzReject++;
         return;
      }
      g_cntSqzPass++;
   }

   // 建玉は常に1つまで。決済が成立していればここでは見つからないので、
   // 同じ足で決済と反対建てが起きる（ドテン）。
   if(FindPosition(ticket, type)) return;

   // ネッティング口座で他人の建玉があるときは何もしない
   if(ForeignPositionBlocks())
   {
      g_cntBlocked++;
      return;
   }

   // 買いと売りが同時に立つことはない。色の転換は青と赤が排他で、膠着の
   // 始まりも雲の色ひとつで向きが決まる。2つの引き金が同じ足で揃った場合
   // も、転換した先の色と現在の色は必ず一致する。
   const bool sent = wantBuy
                     ? g_trade.Buy (InpLots, _Symbol)
                     : g_trade.Sell(InpLots, _Symbol);
   if(TradeSucceeded(sent))
      g_cntEntry++;
   else
   {
      g_cntOrderFailed++;
      PrintFormat("建てられませんでした（%s / 結果 %u %s）",
                  wantBuy ? "買い" : "売り",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}
