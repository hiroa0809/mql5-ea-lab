//+------------------------------------------------------------------+
//| SuperBollinger.mqh                                               |
//| スーパーボリンジャーの計算とルール1の判定                        |
//|                                                                  |
//| 同じ計算をインジケーターと EA の両方が使うため共通化している。   |
//| 2回書くと片方だけ直したときに食い違い、「チャートは合っている    |
//| のにバックテストがおかしい」という切り分け困難な状態になる。     |
//|                                                                  |
//| 計算定義は docs/indicator_spec.md §2.2。                         |
//+------------------------------------------------------------------+
#ifndef SUPERBOLLINGER_MQH
#define SUPERBOLLINGER_MQH

//+------------------------------------------------------------------+
//| 配列の並びについて                                               |
//|                                                                  |
//| 本ファイルの関数は終値配列が「時系列順」（添字 0 = 最新足）で    |
//| あることを前提にする。呼ぶ側が ArraySetAsSeries(close, true) を  |
//| 済ませること。並びを逆にすると添字 shift+i が過去ではなく未来を  |
//| 指し、エラーは出ないまま値だけが狂う。                           |
//|                                                                  |
//| shift は判定する足。確定足で判定するので通常は 1。               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| センターライン ＝ 終値の period 本 単純移動平均                   |
//+------------------------------------------------------------------+
double SB_Center(const double &close[], const int shift, const int period)
{
   double sum = 0.0;
   for(int i = 0; i < period; i++)
      sum += close[shift + i];
   return sum / period;
}

//+------------------------------------------------------------------+
//| σ ＝ 標本標準偏差（period − 1 で割る）                           |
//|                                                                  |
//| MT5 組み込みの iBands() は母標準偏差（period で割る）のため      |
//| 使わない。そのまま使うとバンド幅が 2.47% 狭くなり、しかも黙って  |
//| 違う値を返す。出典: docs/indicator_spec.md §2.2                  |
//|                                                                  |
//| center には同じ shift / period で求めたセンターラインを渡す。    |
//+------------------------------------------------------------------+
double SB_Sigma(const double &close[], const int shift, const int period, const double center)
{
   double sum = 0.0;
   for(int i = 0; i < period; i++)
   {
      const double d = close[shift + i] - center;
      sum += d * d;
   }
   return MathSqrt(sum / (period - 1));
}

//+------------------------------------------------------------------+
//| 1本ぶんの計算結果                                                |
//+------------------------------------------------------------------+
struct SBValues
{
   double center;                    // センターライン
   double sigma;                     // 標本標準偏差
   double upper1, upper2, upper3;    // センターライン + n×σ
   double lower1, lower2, lower3;    // センターライン − n×σ
};

//+------------------------------------------------------------------+
//| shift の足の全値をまとめて求める                                 |
//|                                                                  |
//| センターラインとσを2度計算しないためにまとめている。            |
//| インジケーターは6本の線の描画に、EA は判定に同じ値を使う。       |
//|                                                                  |
//| 戻り値 false は「計算できない」。呼ぶ側は必ず確認すること。      |
//|   - period が 2 未満だとσの分母 period−1 が 0 以下になる        |
//|   - 配列が足りないと添字がはみ出し実行時エラーで停止する         |
//+------------------------------------------------------------------+
bool SB_Calc(const double &close[], const int shift, const int period, SBValues &out)
{
   if(period < 2 || shift < 0)                  return false;
   if(ArraySize(close) < shift + period)        return false;

   out.center = SB_Center(close, shift, period);
   out.sigma  = SB_Sigma(close, shift, period, out.center);

   out.upper1 = out.center + out.sigma;
   out.upper2 = out.center + out.sigma * 2.0;
   out.upper3 = out.center + out.sigma * 3.0;
   out.lower1 = out.center - out.sigma;
   out.lower2 = out.center - out.sigma * 2.0;
   out.lower3 = out.center - out.sigma * 3.0;

   return true;
}

//+------------------------------------------------------------------+
//| 遅行線 — shift の足に描く値                                      |
//|                                                                  |
//| 定義は「終値を lagBars 本前へずらして描画」。つまり shift の足の |
//| 位置に置くのは、そこから lagBars 本ぶん新しい足の終値になる。    |
//| 時系列順の配列では新しい足ほど添字が小さいので shift − lagBars。 |
//|                                                                  |
//| この向きを間違えても値は返るので、エラーでは気づけない。線が     |
//| 最新足まで伸びていたら逆向き（正しくは lagBars 本手前で切れる）。|
//|                                                                  |
//| 判定に使う「陽転／陰転」は現在の終値と過去の高値・安値を比べる   |
//| 別の形になる。そちらは下の SB_Rule1 が持つ。                     |
//+------------------------------------------------------------------+
bool SB_LagValue(const double &close[], const int shift, const int lagBars, double &out)
{
   const int src = shift - lagBars;
   if(src < 0 || src >= ArraySize(close)) return false;
   out = close[src];
   return true;
}

//+------------------------------------------------------------------+
//| ルール1が必要とする最小の履歴本数                                |
//|                                                                  |
//| 固定値を書かない。期間はすべて入力項目なので、書いた瞬間から     |
//| 入力を変えるたびに嘘になる。末尾の +2 は判定足（shift = 1）と    |
//| その1本前（遷移の判定に使う）ぶん。                              |
//+------------------------------------------------------------------+
int SB_RequiredBars(const int period, const int lagBars, const int squeezeBars, const int expandBars)
{
   return period + lagBars + MathMax(squeezeBars, expandBars) + 2;
}

//+------------------------------------------------------------------+
//| ルール1（トレンド開始）の入力                                    |
//|                                                                  |
//| インジケーターと EA が同じ判定を使うため、条件の ON/OFF まで含め |
//| てここへ集める。③（遅行スパンの帯突破）だけ ON/OFF が無いのは、 |
//| これが引き金であり外すとルールが成立しないため。                 |
//| 出典: docs/implementation_design.md §2                           |
//+------------------------------------------------------------------+
struct SBRule1Params
{
   int    period;        // センターラインとσの期間
   int    lagBars;       // 遅行線の本数
   bool   useSqueeze;    // ①膠着を条件に入れる
   int    squeezeBars;   // ①膠着とみなす本数
   double sigmaMult;     // ①③で使うσの倍数
   bool   useExpand;     // ④バンド幅の拡大を条件に入れる
   int    expandBars;    // ④拡大を見る本数
};

//+------------------------------------------------------------------+
//| ルール1の判定結果                                                |
//|                                                                  |
//| 4条件は「使う」設定に関係なく必ず埋める。診断出力が条件ごとの    |
//| 成立回数を他の条件の成否と無関係に数えるため                     |
//| （docs/implementation_design.md §4）。ON/OFF を反映した最終判定  |
//| は buy / sell だけ。                                             |
//+------------------------------------------------------------------+
struct SBRule1Signal
{
   bool squeezed;      // ①遅行スパンが帯の内側にとどまっていた
   bool crossUp;       // ③遅行スパンが帯を上へ突破した（買いの引き金）
   bool crossDown;     // ③遅行スパンが帯を下へ突破した（売りの引き金）
   bool expanding;     // ④バンド幅が拡大している
   bool buy;           // 使う条件がすべて揃った（買い）
   bool sell;          // 同（売り）
};

//+------------------------------------------------------------------+
//| 遅行スパンが帯のどこにいるか — σ 何個ぶん中心線から離れているか  |
//|                                                                  |
//| 遅行線は「今の終値を lagBars 本前の位置へ置いた線」なので、その  |
//| 点の真下にある帯は lagBars 本前の時点で計算された帯になる。      |
//| したがって比べる相手は cur ではなく SB_Calc(shift + lagBars)。   |
//|                                                                  |
//| 戻す値の意味: +1.0 なら遅行スパンが +1σ の線の上に乗っている。   |
//| 21本かけて価格が正味どこへ行ったかを、当時のσで割った量になる。 |
//|                                                                  |
//| σ が 0（21本の終値が全て同値）のときは 0 を返す。動いていない   |
//| のだから帯の内側と扱うのが自然で、割り算も避けられる。           |
//+------------------------------------------------------------------+
bool SB_LagOffset(const double &close[], const int shift, const int lagBars,
                  const int period, double &out)
{
   SBValues v;
   if(!SB_Calc(close, shift + lagBars, period, v)) return false;
   out = (v.sigma > 0.0) ? (close[shift] - v.center) / v.sigma : 0.0;
   return true;
}

//+------------------------------------------------------------------+
//| ルール1 — トレンド開始の条件を判定する                           |
//|                                                                  |
//| 条件の定義は docs/trading_rules.md §3（用語の一意化）と §4.1     |
//| （エントリー）。本関数は資料の条件番号 ①③④ をそのまま持つ。   |
//|                                                                  |
//| ②遅行線の陽転/陰転は条件から外した。2026-08-12 の最適化（15分足・|
//| 学習期間・1000パス）で、同じ設定どうしの対比較 496 組すべてが     |
//| 「②を入れないほうが良い」で一致したため（平均 +0.32 pips、       |
//| 決済Cに限ると +0.53 pips）。ON/OFF の入力ごと削除している。      |
//| ②の定義そのものはルール2（スパンモデル）が使うので資料には残る。 |
//|                                                                  |
//| 終値配列は時系列順（添字 0 = 最新足）が前提。呼ぶ側が            |
//| ArraySetAsSeries を済ませること。                                |
//|                                                                  |
//| 戻り値 false は「判定できない」。履歴が足りない場合などで、この  |
//| とき out の中身は不定。**戻り値を確認せずに out を読まないこと。**|
//+------------------------------------------------------------------+
bool SB_Rule1(const double &close[], const int shift,
              const SBRule1Params &p, SBRule1Signal &out)
{
   if(shift < 0 || p.period < 2 || p.sigmaMult <= 0.0)        return false;
   if(p.lagBars < 1 || p.squeezeBars < 1 || p.expandBars < 1) return false;

   // ① 膠着 — 遅行スパンが直前 squeezeBars 本ぶん ±sigmaMult σ の内側に
   // とどまっていた。「21本かけて価格が正味どこへも行っていない」状態を
   // 見ており、帯が細いかどうかは見ていない。判定足そのものは含めない
   // （p11-① は「直前が」膠着）。docs/trading_rules.md §3.3
   out.squeezed = true;
   for(int j = shift + 1; j <= shift + p.squeezeBars; j++)
   {
      double z;
      if(!SB_LagOffset(close, j, p.lagBars, p.period, z)) return false;
      if(MathAbs(z) > p.sigmaMult)
      {
         out.squeezed = false;
         break;
      }
   }

   // ③ 遅行スパンが帯を突破（引き金）— 状態ではなく遷移として扱う。前の
   // 足では内側にいたことまで要求する。①を外した設定でも、外に居続ける
   // 間ずっと発火し続けることがない。docs/trading_rules.md §3.3
   double zNow, zPrev;
   if(!SB_LagOffset(close, shift,     p.lagBars, p.period, zNow))  return false;
   if(!SB_LagOffset(close, shift + 1, p.lagBars, p.period, zPrev)) return false;
   out.crossUp   = (zNow >  p.sigmaMult) && (zPrev <=  p.sigmaMult);
   out.crossDown = (zNow < -p.sigmaMult) && (zPrev >= -p.sigmaMult);

   // ④ バンド幅の拡大 — バンド幅は σ の2倍なので、σ どうしの比較と同値。
   // 1本前と比べるとノイズで成立するため既定は3本前。
   // docs/trading_rules.md §3.2
   SBValues cur, past;
   if(!SB_Calc(close, shift,                p.period, cur))  return false;
   if(!SB_Calc(close, shift + p.expandBars, p.period, past)) return false;
   out.expanding = (cur.sigma > past.sigma);

   out.buy  = out.crossUp   && (!p.useSqueeze || out.squeezed)
                            && (!p.useExpand  || out.expanding);
   out.sell = out.crossDown && (!p.useSqueeze || out.squeezed)
                            && (!p.useExpand  || out.expanding);
   return true;
}

//+------------------------------------------------------------------+
//| ルール1の手仕舞い方式                                            |
//|                                                                  |
//| A は資料 p13 のとおり。B と C は【一意化】で、エントリーと同じ   |
//| 物差し（遅行スパンと帯の距離）を使う。                           |
//|                                                                  |
//| A を分けてある理由: エントリーは④で「バンド幅が拡大している」   |
//| ことを要求するので、発火を起こした値動きがそのまま今のσを膨らま |
//| せる。A は「今の帯」を基準にするため、**エントリーの勢いが強い   |
//| ほど決済のハードルが下がる**。B・C にはこの反応が無い。          |
//|                                                                  |
//| どれが良いかは学習期間の平均グロス損益で決める（回数制限なし）。 |
//+------------------------------------------------------------------+
enum ENUM_SB_EXIT
{
   SB_EXIT_CLOSE_SIGMA1 = 0,   // A 終値が 1σ の内側へ戻る（資料 p13）
   SB_EXIT_LAG_SIGMA1   = 1,   // B 遅行スパンが 1σ の内側へ戻る
   SB_EXIT_LAG_FLIP     = 2    // C 遅行スパンが反対側へ陰転する
};

//+------------------------------------------------------------------+
//| ルール1の手仕舞い — 抜けるべき足かどうか                         |
//|                                                                  |
//| エントリー側（③）が遷移なのに対し、こちらは**状態**として扱う。 |
//| 保有中に毎足チェックする条件なので、遷移として書くと取り逃した   |
//| とき決済されないまま走り続ける。docs/trading_rules.md §3.3b・§4.2|
//|                                                                  |
//| A について: p13 は「バンド幅が収束傾向」「遅行スパンが絡む」も   |
//| 併記しているが、3つ揃うのを待つと調整が進んだ後の決済になる。    |
//|                                                                  |
//| B の 1σ は固定。つまみにすると学習期間の成績が実力以上に出る。   |
//+------------------------------------------------------------------+
bool SB_Rule1Exit(const double &close[], const int shift, const int period,
                  const int lagBars, const ENUM_SB_EXIT method,
                  const bool isLong, bool &out)
{
   if(method == SB_EXIT_CLOSE_SIGMA1)
   {
      SBValues v;
      if(!SB_Calc(close, shift, period, v)) return false;
      out = isLong ? (close[shift] < v.upper1) : (close[shift] > v.lower1);
      return true;
   }

   double z;
   if(!SB_LagOffset(close, shift, lagBars, period, z)) return false;

   if(method == SB_EXIT_LAG_SIGMA1)
      out = isLong ? (z <= 1.0) : (z >= -1.0);
   else
      out = isLong ? (z < 0.0) : (z > 0.0);

   return true;
}

//+------------------------------------------------------------------+
//| 段階エントリー（装填1 → 装填2 → 発火）                           |
//|                                                                  |
//| 狙い: 膠着から拡大へ向かう場面の1回目のサインは、逆へ振られて     |
//| 損切りにされることが多い。その「ダマシで振られて切られる」ひと     |
//| 続きを丸ごと通過してから入る。                                    |
//|                                                                  |
//|   装填1 … ルール1のサインが出た（ダマシが発生した想定）          |
//|   装填2 … 装填1 の向きで建てた想定の建玉に、選んでいる決済方式    |
//|            と同じ条件が成立した（損切りにされた想定）            |
//|   発火  … 装填2 のあとに③突破が起きた足で発注する               |
//|                                                                  |
//| 装填2 を挟むかは設定で選ぶ。挟む設定では、装填1 のまま③突破が    |
//| 起きても入らない。挟まない設定では装填1 の次の③突破で発火する。   |
//|                                                                  |
//| 発火の向きは③突破が抜けた向きで決める。装填1 の向きは引き継が    |
//| ない（振られた側の動きをそのまま取るため）。装填1 の向きを覚えて  |
//| いるのは、装填2 の判定に使う決済条件が向きを要るからだけ。        |
//|                                                                  |
//| 発火が見るのは③突破だけで①②④は問わない。①膠着は「直前       |
//| squeezeBars 本のあいだ帯の内側」を要求するので、2度目のサインは  |
//| 構造上 squeezeBars 本より後にしか出ない。それを待つと「振られた   |
//| 直後の動きを取る」という狙いから外れる。                          |
//|                                                                  |
//| 既定は無効。有効にしないかぎり従来と同じ動きになる。              |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| 段階の数                                                         |
//|                                                                  |
//| 装填2 を挟むかどうかで成績がどう変わるかを比べるための選択肢。    |
//| EA を2本に分けると同じ判定が2箇所に散り、片方だけ直したときに     |
//| 食い違う。設定1つで切り替えれば、比較も同じバイナリで行える。     |
//+------------------------------------------------------------------+
enum ENUM_SB_STAGED
{
   SB_STAGED_OFF = 0,   // 使わない（サインで即エントリー）
   SB_STAGED_1   = 1,   // 装填1 → 発火
   SB_STAGED_2   = 2    // 装填1 → 装填2（損切り）→ 発火
};

struct SBStagedParams
{
   int    stages;      // ENUM_SB_STAGED の値。0 なら段階エントリーを使わない
   int    armBars;     // 装填が生きている本数（装填1 した足の次から数える）
   double rsiUpper;    // 買いの発火を見送る RSI（これ以上なら入らない）
   double rsiLower;    // 売りの発火を見送る RSI（これ以下なら入らない）
};

//+------------------------------------------------------------------+
//| 装填の状態 — 足をまたいで持ち越す                                |
//|                                                                  |
//| age は装填1 した足を 0 として数えた経過本数。装填2 へ進んでも     |
//| 数え直さない。期限は「装填1 から armBars 本」のひと続きで、       |
//| 装填2 に別枠を与えない（枠を2つにすると最長で倍待つことになり、   |
//| 振られた直後を取るという狙いから外れる）。                        |
//|                                                                  |
//| 装填1 した足そのものは装填2 に数えない。その足は建てた足に当たる  |
//| ので、同じ足で決済条件を見ると建てた瞬間に切られた扱いになる。    |
//+------------------------------------------------------------------+
struct SBArmState
{
   int stage;   // 0 = 装填なし / 1 = 装填1 / 2 = 装填2
   int dir;     // 装填1 の向き（+1 買い / −1 売り）。装填2 の判定に使う
   int age;
};

//+------------------------------------------------------------------+
//| 1本ぶんの結果。fireBuy / fireSell 以外は診断と表示に使う          |
//+------------------------------------------------------------------+
struct SBStagedResult
{
   bool fireBuy;      // 発火（買い）
   bool fireSell;     // 発火（売り）
   bool arm1Now;      // この足で装填1（ダマシが発生した）
   bool arm2Now;      // この足で装填2（損切りにされた）
   bool rsiBlocked;   // 3σ を抜けたが RSI が行きすぎで見送った
   bool expired;      // 期限切れで装填を解除した
};

//+------------------------------------------------------------------+
//| RSI が行きすぎ側にあるか                                         |
//|                                                                  |
//| 買い側は上限以上、売り側は下限以下。エントリーの見送りと、保有中  |
//| の決済の両方が同じ判定を使う。「行きすぎているなら入らない・      |
//| 持っているなら降りる」で向きがそろう。                            |
//+------------------------------------------------------------------+
bool SB_RsiExtreme(const double rsi, const bool isLong, const SBStagedParams &p)
{
   return isLong ? (rsi >= p.rsiUpper) : (rsi <= p.rsiLower);
}

//+------------------------------------------------------------------+
//| 装填1 の向きで決済条件を評価する — 装填2 へ進むかどうか          |
//|                                                                  |
//| 装填2 を挟む設定で、装填1 のときだけ意味を持つ。向きは装填1 の    |
//| もの（ダマシで建てた想定の建玉が、選んでいる決済方式で切られたか）。|
//+------------------------------------------------------------------+
bool SB_StagedStopHit(const double &close[], const int shift, const int period,
                      const int lagBars, const ENUM_SB_EXIT method,
                      const SBStagedParams &p, const SBArmState &st)
{
   if(p.stages < 2 || st.stage != 1) return false;

   bool hit;
   if(!SB_Rule1Exit(close, shift, period, lagBars, method, st.dir > 0, hit)) return false;
   return hit;
}

//+------------------------------------------------------------------+
//| 装填の状態を1本ぶん進める                                        |
//|                                                                  |
//| stopHit には SB_StagedStopHit の結果を渡す。決済条件の評価に      |
//| 終値配列と決済方式が要り、それを本関数へ持ち込むと引数が増える    |
//| だけなので、呼ぶ側で求めてから渡す形にしている。                  |
//|                                                                  |
//| st は入出力。呼ぶ側が古い足から新しい足へ順に呼ぶこと。逆順や     |
//| 飛ばし呼びをすると経過本数が狂うが、エラーにはならない。          |
//|                                                                  |
//| 1本で進む段階は1つまで。損切りと③突破が同じ足で揃っても、その足  |
//| は装填2 で止め、発火は次の足以降に見る（装填2「を経てから」発火   |
//| という決まりをそのまま書いている）。                              |
//|                                                                  |
//| 建玉の有無は見ない。保有中に発火しても、発注するかどうかを決める  |
//| のは呼ぶ側（建玉は1つまで、という決まりは従来どおり呼ぶ側が持つ）。|
//+------------------------------------------------------------------+
void SB_StagedStep(const SBRule1Signal &s, const double rsi, const bool stopHit,
                   const SBStagedParams &p, SBArmState &st, SBStagedResult &out)
{
   out.fireBuy    = false;
   out.fireSell   = false;
   out.arm1Now    = false;
   out.arm2Now    = false;
   out.rsiBlocked = false;
   out.expired    = false;

   // 発火・見送りで装填を使い切った足では、同じ足で装填1 をやり直さない。
   // 期限切れは使い切りに含めない（その足に新しいサインが出ていれば
   // 装填してよい。古い装填が終わっただけなので）
   bool consumed = false;

   if(st.stage != 0)
   {
      st.age++;

      if(st.age > p.armBars)
      {
         st.stage    = 0;
         out.expired = true;
      }
      else if(st.stage == 1 && p.stages >= 2)
      {
         // 装填1 のあいだは新しいサインを見ない。想定の建玉を持っている
         // 状態なので「建玉は1つまで」と同じ扱いにする
         if(stopHit)
         {
            st.stage    = 2;
            out.arm2Now = true;
         }
      }
      else if(s.crossUp || s.crossDown)   // 装填2、または装填2 を挟まない設定の装填1
      {
         const bool isLong = s.crossUp;
         st.stage = 0;
         consumed = true;

         if(SB_RsiExtreme(rsi, isLong, p))
            out.rsiBlocked = true;      // 見送り。装填も解除する
         else if(isLong)
            out.fireBuy  = true;
         else
            out.fireSell = true;
      }
   }

   if(!consumed && st.stage == 0 && (s.buy || s.sell))
   {
      st.stage    = 1;
      st.dir      = s.buy ? +1 : -1;
      st.age      = 0;
      out.arm1Now = true;
   }
}

#endif // SUPERBOLLINGER_MQH
