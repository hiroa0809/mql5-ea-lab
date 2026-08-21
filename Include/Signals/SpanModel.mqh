//+------------------------------------------------------------------+
//| SpanModel.mqh                                                    |
//| スパンモデルの計算とルール2の判定                                |
//|                                                                  |
//| 同じ計算をインジケーターと EA の両方が使うため共通化している。   |
//| 計算定義は docs/indicator_spec.md §1.2。                         |
//|                                                                  |
//| MT5 組み込みの iIchimoku() は使わない。先行スパンのバッファは    |
//| すでに 26 本先行させた状態で格納されており、本指標が必要とする   |
//| 「先行させない現在値」は 26 本未来の位置に当たるため CopyBuffer  |
//| では取り出せない。高値・安値から直接計算する。                   |
//+------------------------------------------------------------------+
#ifndef SPANMODEL_MQH
#define SPANMODEL_MQH

//+------------------------------------------------------------------+
//| 配列の並びについて                                               |
//|                                                                  |
//| SuperBollinger.mqh と同じく、高値・安値・終値の配列が「時系列順」|
//| （添字 0 = 最新足）であることを前提にする。呼ぶ側が             |
//| ArraySetAsSeries(arr, true) を済ませること。並びを逆にすると    |
//| 添字 shift+i が過去ではなく未来を指し、エラーは出ないまま値だけ  |
//| が狂う。                                                         |
//|                                                                  |
//| shift は判定する足。確定足で判定するので通常は 1。               |
//+------------------------------------------------------------------+

//+------------------------------------------------------------------+
//| period 本の高値の最大値                                          |
//+------------------------------------------------------------------+
double SM_HighestHigh(const double &high[], const int shift, const int period)
{
   double v = high[shift];
   for(int i = 1; i < period; i++)
      if(high[shift + i] > v)
         v = high[shift + i];
   return v;
}

//+------------------------------------------------------------------+
//| period 本の安値の最小値                                          |
//+------------------------------------------------------------------+
double SM_LowestLow(const double &low[], const int shift, const int period)
{
   double v = low[shift];
   for(int i = 1; i < period; i++)
      if(low[shift + i] < v)
         v = low[shift + i];
   return v;
}

//+------------------------------------------------------------------+
//| period 本の中値 ＝ (最高値 + 最安値) / 2                         |
//+------------------------------------------------------------------+
double SM_Midpoint(const double &high[], const double &low[], const int shift, const int period)
{
   return (SM_HighestHigh(high, shift, period) + SM_LowestLow(low, shift, period)) / 2.0;
}

//+------------------------------------------------------------------+
//| 1本ぶんの計算結果                                                |
//+------------------------------------------------------------------+
struct SMValues
{
   double tenkan;   // 転換線（既定 9 本の中値）
   double kijun;    // 基準線（既定 26 本の中値）
   double spanA;    // 青いスパン ＝ (転換線 + 基準線) / 2
   double spanB;    // 赤いスパン（既定 52 本の中値）
};

//+------------------------------------------------------------------+
//| shift の足の全値をまとめて求める                                 |
//|                                                                  |
//| 転換線と基準線は青いスパンを出すための途中の値だが、Matrix       |
//| Trader の凡例と突き合わせるときに個別に要るため構造体に残す。    |
//|                                                                  |
//| ここで求めるのは「先行させない現在値」。未来方向へずらす処理は   |
//| 一切行わない（docs/indicator_spec.md §1.3）。ずらすと一目均衡表  |
//| の雲になり、別物になる。                                         |
//|                                                                  |
//| 戻り値 false は「計算できない」。呼ぶ側は必ず確認すること。      |
//+------------------------------------------------------------------+
bool SM_Calc(const double &high[],
             const double &low[],
             const int shift,
             const int tenkanPeriod,
             const int kijunPeriod,
             const int spanBPeriod,
             SMValues &out)
{
   if(shift < 0)                                             return false;
   if(tenkanPeriod < 1 || kijunPeriod < 1 || spanBPeriod < 1) return false;

   const int longest = MathMax(tenkanPeriod, MathMax(kijunPeriod, spanBPeriod));
   const int need    = shift + longest;
   if(ArraySize(high) < need || ArraySize(low) < need)       return false;

   out.tenkan = SM_Midpoint(high, low, shift, tenkanPeriod);
   out.kijun  = SM_Midpoint(high, low, shift, kijunPeriod);
   out.spanA  = (out.tenkan + out.kijun) / 2.0;
   out.spanB  = SM_Midpoint(high, low, shift, spanBPeriod);

   return true;
}

//+------------------------------------------------------------------+
//| 遅行線 — shift の足に描く値                                      |
//|                                                                  |
//| 定義は「終値を lagBars 本前へずらして描画」。SuperBollinger.mqh  |
//| の SB_LagValue と同じ考え方で、時系列順の配列では                |
//| shift − lagBars を引く。本数だけが違う（スパンモデルは既定 26、  |
//| スーパーボリンジャーは既定 21）。                                |
//|                                                                  |
//| 向きを誤っても値は返るためエラーでは気づけない。線が最新足まで   |
//| 伸びていたら逆向き（正しくは lagBars 本手前で切れる）。          |
//+------------------------------------------------------------------+
bool SM_LagValue(const double &close[], const int shift, const int lagBars, double &out)
{
   const int src = shift - lagBars;
   if(src < 0 || src >= ArraySize(close)) return false;
   out = close[src];
   return true;
}

//+------------------------------------------------------------------+
//| ルール2が必要とする最小の履歴本数                                |
//|                                                                  |
//| 固定値を書かない。期間はすべて入力項目なので、書いた瞬間から     |
//| 入力を変えるたびに嘘になる。末尾の +2 は判定足（shift = 1）と    |
//| その1本前（遷移の判定に使う）ぶん。                              |
//|                                                                  |
//| 転換線の期間も必ず含める。既定値では 9 < 52 なので赤スパンが最大 |
//| になるが、3つとも入力項目である以上「転換線が一番小さい」は前提  |
//| にできない。SM_Calc は3つすべての履歴を読むため、外すと足りない  |
//| 状態で「足りている」と判定してしまう。                           |
//+------------------------------------------------------------------+
int SM_RequiredBars(const int tenkanPeriod,
                    const int kijunPeriod,
                    const int spanBPeriod,
                    const int lagBars,
                    const int slopeBars)
{
   return MathMax(tenkanPeriod, MathMax(kijunPeriod, spanBPeriod)) + lagBars + slopeBars + 2;
}

//+------------------------------------------------------------------+
//| ②遅行スパンの位置 — 3通りの比べ方                                |
//|                                                                  |
//| 遅行線の右端は判定足の終値で、それを lagBars 本前の位置に置く。   |
//| **比較先はその1本（添字 shift + lagBars）に固定**。遅行スパンの   |
//| 定義そのものなので切り替えを持たない（2026-08-17 決定）。         |
//|                                                                  |
//| 資料が言っているのは「遅行スパンがローソク足を上抜け = 買い」     |
//| （S1）だけで、足の**どこ**と比べるかは書いていない。そこで3通り   |
//| を用意し、使う組み合わせを入力で選ぶ（docs/trading_rules.md §3.1）|
//|                                                                  |
//|   a 終値 … 比較先の足の終値と比べる（最も緩い）                  |
//|   b 高安 … 比較先の足の高値（買い）・安値（売り）と比べる        |
//|   c 雲   … 比較先の位置の雲を完全に抜けているか。買いなら雲の    |
//|            上端（青スパンと赤スパンの高いほう）より上            |
//|                                                                  |
//| c を「雲の上端」にしたのは、資料が「ローソク足が雲の中 = 勢いが   |
//| 弱まっている」と述べており、**雲の中を「抜けた」とは呼んでいない**|
//| ため（2026-08-17 決定）。                                        |
//|                                                                  |
//| 上でも下でもない状態（= 資料の「絡む」）は、その組の above /     |
//| below がどちらも false で表される。                              |
//+------------------------------------------------------------------+
struct SMLagState
{
   bool closeAbove, closeBelow;   // a 比較先の終値と比べた
   bool highAbove,  lowBelow;     // b 比較先の高値・安値と比べた
   bool cloudAbove, cloudBelow;   // c 比較先の雲と比べた
};

bool SM_LagState(const double &high[],
                 const double &low[],
                 const double &close[],
                 const int shift,
                 const int lagBars,
                 const int tenkanPeriod,
                 const int kijunPeriod,
                 const int spanBPeriod,
                 SMLagState &out)
{
   if(shift < 0 || lagBars < 1) return false;

   const int src = shift + lagBars;   // 遅行線が乗っている足
   if(ArraySize(close) <= src) return false;

   const double now = close[shift];

   out.closeAbove = (now > close[src]);
   out.closeBelow = (now < close[src]);
   out.highAbove  = (now > high[src]);
   out.lowBelow   = (now < low[src]);

   SMValues v;
   if(!SM_Calc(high, low, src, tenkanPeriod, kijunPeriod, spanBPeriod, v)) return false;

   const double cloudTop    = MathMax(v.spanA, v.spanB);
   const double cloudBottom = MathMin(v.spanA, v.spanB);
   out.cloudAbove = (now > cloudTop);
   out.cloudBelow = (now < cloudBottom);
   return true;
}

//+------------------------------------------------------------------+
//| ④赤いスパンの傾き                                                |
//|                                                                  |
//| 定義は docs/trading_rules.md §3.4。slopeBars 本前の赤スパンと     |
//| 比べ、**平らな足も通す**（「以上」「以下」で判定する）。          |
//|                                                                  |
//| 赤スパンは 52 本の高値・安値の中値なので**階段状**になる。52本の  |
//| 最高値か最安値が入れ替わるまで完全に平らで、レンジ相場では何十本  |
//| も動かない。厳密な `>` にすると、雲が転換した足の 43.3% は赤      |
//| スパンが 5 本前と同値で、④を通るのが 16.2% にとどまった（②28.8%|
//| ・③85.3% に対し突出して絞る・人工データ30万本）。資料は「傾きで  |
//| 判断」としか言っておらず、平らな足を落とす根拠が無い。            |
//|                                                                  |
//| **平らな足では up と down が同時に true になる。** ④単独では買い |
//| と売りのどちらも通すが、向きを決めるのは①雲の転換なので、両方向 |
//| のサインが同時に出ることはない。                                 |
//|                                                                  |
//| 厳密な傾きへ切り替える入力は持たない。④そのものを使うかどうかが |
//| 選べれば足りる（SMRule2Params の useSlope）。                     |
//|                                                                  |
//| 既定の 5 本に資料の根拠は無い（資料は「傾きで判断」としか書いて   |
//| いない）。階段1段の間隔より短い可能性がある。                     |
//|                                                                  |
//| **比較先は直近 slopeBars 本すべて**（2026-08-17 に変更）。今の値が |
//| そのどれよりも低くなければ上向きとする。端の1点とだけ比べる形は   |
//| やめた。途中を見ないと、**slopeBars 本前が谷なら、そこから上がっ  |
//| て下がって戻ってきた足も「上向き」になる**（チャートで実例を確認。|
//| 赤スパンが直近3本下がっているのに ④ が上向きと出た）。人工データ |
//| では全足の 0.8% で起きる。切り替えは持たない — 目で見て下降して   |
//| いる足を上向きと呼ぶ設定を残す理由が無い。                        |
//+------------------------------------------------------------------+
bool SM_SpanBSlope(const double &high[],
                   const double &low[],
                   const int shift,
                   const int spanBPeriod,
                   const int slopeBars,
                   bool &up,
                   bool &down)
{
   if(shift < 0 || spanBPeriod < 1 || slopeBars < 1) return false;

   const int need = shift + slopeBars + spanBPeriod;
   if(ArraySize(high) < need || ArraySize(low) < need) return false;

   const double now = SM_Midpoint(high, low, shift, spanBPeriod);

   // 直近 slopeBars 本の最大（上向きの判定用）と最小（下向きの判定用）
   double hi = SM_Midpoint(high, low, shift + slopeBars, spanBPeriod);
   double lo = hi;
   for(int j = 1; j < slopeBars; j++)
   {
      const double v = SM_Midpoint(high, low, shift + j, spanBPeriod);
      if(v > hi) hi = v;
      if(v < lo) lo = v;
   }

   up   = (now >= hi);
   down = (now <= lo);
   return true;
}

//+------------------------------------------------------------------+
//| ルール2の入力                                                    |
//|                                                                  |
//| **②の3つを全て false にすると②を使わない判定になる。** ②専用の |
//| 「使う／使わない」は持たない（同じことを2箇所で切り替えられると、|
//| どちらが効いているのか分からなくなるため）。呼ぶ側は3つとも      |
//| false のときに警告を出すこと。                                   |
//+------------------------------------------------------------------+
struct SMRule2Params
{
   int  tenkanPeriod;   // 転換線の期間
   int  kijunPeriod;    // 基準線の期間
   int  spanBPeriod;    // 赤スパンの期間
   int  lagBars;        // 遅行線の本数
   bool useLagClose;    // ②a 比較先の終値を超える
   bool useLagHighLow;  // ②b 比較先の高値・安値を超える
   bool useLagCloud;    // ②c 比較先の雲を完全に抜ける
   bool useClosePos;    // ③を条件に入れる
   bool useSlope;       // ④を条件に入れる
   int  slopeBars;      // ④傾きを見る本数
};

//+------------------------------------------------------------------+
//| 1本ぶんの判定結果                                                |
//|                                                                  |
//| ②③④は使う／使わないに関わらず常に埋める。外した条件が実際には |
//| どうだったかをインジケーターのデータウィンドウで読めるようにする |
//| ため（矢印が出ない足でもどこで止まったか分かる）。買い／売りに   |
//| 反映されるのは使うと指定した条件だけ。                           |
//+------------------------------------------------------------------+
struct SMRule2Signal
{
   bool flipBlue;     // ①雲が青へ転換した（買いの引き金）
   bool flipRed;      // ①雲が赤へ転換した（売りの引き金）
   SMLagState lag;    // ②3通りの比べ方の結果（a 終値 / b 高安 / c 雲）
   bool closeAbove;   // ③終値が青スパンより上
   bool closeBelow;   // ③終値が青スパンより下
   bool spanBUp;      // ④赤スパンが上向き
   bool spanBDown;    // ④赤スパンが下向き
   bool buyOk;        // ①以外の使う条件がすべて揃った（買いの向き）
   bool sellOk;       // 同（売りの向き）
   bool buy;          // ①も含めてすべて揃った（買い）
   bool sell;         // 同（売り）
};

//+------------------------------------------------------------------+
//| ルール2 — 雲転換の順張りを判定する                               |
//|                                                                  |
//| 条件の定義は docs/trading_rules.md §3.1/§3.4/§3.5（用語の一意化）|
//| と §5.2（エントリー）。資料の条件番号 ①②③④ をそのまま持つ。  |
//|                                                                  |
//| ①雲の色の転換だけが**遷移**で、残る②③④は判定足の**状態**。   |
//| 遷移する条件を2つ以上持つと同じ足で揃うことがほぼ無く取引がゼロ  |
//| になる（ルール1で経験済み・tasks/TASK_MASTER.md N5-1）。          |
//|                                                                  |
//| レンジ相場での逆張り（資料 p3「レンジ相場では逆指標」）は入れて  |
//| いない。レンジ判定はスーパーボリンジャーの仕事で、入れると        |
//| スパンモデル単体でなくなるため（docs/trading_rules.md §5.1）。    |
//|                                                                  |
//| 高値・安値・終値の配列は時系列順（添字 0 = 最新足）が前提。呼ぶ  |
//| 側が ArraySetAsSeries を済ませること。                           |
//|                                                                  |
//| 戻り値 false は「判定できない」。履歴が足りない場合などで、この  |
//| とき out の中身は不定。**戻り値を確認せずに out を読まないこと。**|
//+------------------------------------------------------------------+
bool SM_Rule2(const double &high[],
              const double &low[],
              const double &close[],
              const int shift,
              const SMRule2Params &p,
              SMRule2Signal &out)
{
   if(shift < 0) return false;

   // ① 雲の色の転換（引き金）— 判定足と1本前の色を比べる。青にも赤にも
   // ならない足（青スパンと赤スパンが同値）は「どちらでもない」で、転換の
   // 起点にはなるが転換先にはならない。docs/trading_rules.md §3.5
   SMValues now, prev;
   if(!SM_Calc(high, low, shift,     p.tenkanPeriod, p.kijunPeriod, p.spanBPeriod, now))  return false;
   if(!SM_Calc(high, low, shift + 1, p.tenkanPeriod, p.kijunPeriod, p.spanBPeriod, prev)) return false;

   out.flipBlue = (now.spanA > now.spanB) && !(prev.spanA > prev.spanB);
   out.flipRed  = (now.spanB > now.spanA) && !(prev.spanB > prev.spanA);

   // ② 遅行スパンの位置（3通り。使うものを AND で重ねる）
   if(!SM_LagState(high, low, close, shift, p.lagBars,
                   p.tenkanPeriod, p.kijunPeriod, p.spanBPeriod, out.lag))
      return false;

   // ③ ローソク足と青スパンの位置関係（資料 p5-3）
   out.closeAbove = (close[shift] > now.spanA);
   out.closeBelow = (close[shift] < now.spanA);

   // ④ 赤スパンの傾き（資料 p5-1）
   if(!SM_SpanBSlope(high, low, shift, p.spanBPeriod, p.slopeBars,
                     out.spanBUp, out.spanBDown))
      return false;

   // ①以外の条件をまとめておく。**引き金を差し替えられるようにするため。**
   // ルール2の引き金は①雲の色の転換だが、統合（R3）では「膠着が始まった
   // 足で、そのときの雲の色に従って建てる」という別の引き金も試す。その
   // ときも②③④は同じ形で効かせたいので、①と切り離してある。
   out.buyOk = (!p.useLagClose   || out.lag.closeAbove)
            && (!p.useLagHighLow || out.lag.highAbove)
            && (!p.useLagCloud   || out.lag.cloudAbove)
            && (!p.useClosePos   || out.closeAbove)
            && (!p.useSlope      || out.spanBUp);

   out.sellOk = (!p.useLagClose   || out.lag.closeBelow)
             && (!p.useLagHighLow || out.lag.lowBelow)
             && (!p.useLagCloud   || out.lag.cloudBelow)
             && (!p.useClosePos   || out.closeBelow)
             && (!p.useSlope      || out.spanBDown);

   out.buy  = out.flipBlue && out.buyOk;
   out.sell = out.flipRed  && out.sellOk;

   return true;
}

#endif // SPANMODEL_MQH
