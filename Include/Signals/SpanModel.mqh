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
//| ②遅行スパンの陽転／陰転                                          |
//|                                                                  |
//| 定義は docs/trading_rules.md §3.1。遅行線の右端（= 判定足の終値） |
//| を、その1本手前から lagBars 本ぶんの足と比べる。                  |
//|                                                                  |
//| **判定足そのものは含めない。** 自分の高値は終値より必ず上なので、 |
//| 含めると陽転が絶対に成立しない。                                 |
//|                                                                  |
//| 比較先を「lagBars 本前の1本だけ」にしない。R1 の③に対して単独    |
//| 成立率 86.5%・重複 100% になり条件として働かなかった             |
//| （2026-08-09・人工データ30万本）。直近 lagBars 本の高安と比べる。 |
//|                                                                  |
//| 陽転でも陰転でもない状態（= 資料の「絡む」）は above / below が   |
//| どちらも false で表される。                                      |
//+------------------------------------------------------------------+
bool SM_LagState(const double &high[],
                 const double &low[],
                 const double &close[],
                 const int shift,
                 const int lagBars,
                 bool &above,
                 bool &below)
{
   if(shift < 0 || lagBars < 1) return false;

   const int need = shift + 1 + lagBars;
   if(ArraySize(high) < need || ArraySize(low) < need) return false;
   if(ArraySize(close) <= shift)                       return false;

   above = (close[shift] > SM_HighestHigh(high, shift + 1, lagBars));
   below = (close[shift] < SM_LowestLow(low,   shift + 1, lagBars));
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

   const double now  = SM_Midpoint(high, low, shift,             spanBPeriod);
   const double past = SM_Midpoint(high, low, shift + slopeBars, spanBPeriod);

   up   = (now >= past);
   down = (now <= past);
   return true;
}

//+------------------------------------------------------------------+
//| ルール2の入力                                                    |
//+------------------------------------------------------------------+
struct SMRule2Params
{
   int  tenkanPeriod;   // 転換線の期間
   int  kijunPeriod;    // 基準線の期間
   int  spanBPeriod;    // 赤スパンの期間
   int  lagBars;        // 遅行線の本数
   bool useLag;         // ②を条件に入れる
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
   bool lagAbove;     // ②遅行スパンが陽転
   bool lagBelow;     // ②遅行スパンが陰転
   bool closeAbove;   // ③終値が青スパンより上
   bool closeBelow;   // ③終値が青スパンより下
   bool spanBUp;      // ④赤スパンが上向き
   bool spanBDown;    // ④赤スパンが下向き
   bool buy;          // 使う条件がすべて揃った（買い）
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

   // ② 遅行スパンの陽転／陰転
   if(!SM_LagState(high, low, close, shift, p.lagBars, out.lagAbove, out.lagBelow))
      return false;

   // ③ ローソク足と青スパンの位置関係（資料 p5-3）
   out.closeAbove = (close[shift] > now.spanA);
   out.closeBelow = (close[shift] < now.spanA);

   // ④ 赤スパンの傾き（資料 p5-1）
   if(!SM_SpanBSlope(high, low, shift, p.spanBPeriod, p.slopeBars,
                     out.spanBUp, out.spanBDown))
      return false;

   out.buy = out.flipBlue
             && (!p.useLag      || out.lagAbove)
             && (!p.useClosePos || out.closeAbove)
             && (!p.useSlope    || out.spanBUp);

   out.sell = out.flipRed
              && (!p.useLag      || out.lagBelow)
              && (!p.useClosePos || out.closeBelow)
              && (!p.useSlope    || out.spanBDown);

   return true;
}

#endif // SPANMODEL_MQH
