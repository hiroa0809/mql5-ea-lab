//+------------------------------------------------------------------+
//| Squeeze.mqh                                                      |
//| 膠着（スクイーズ）の測り方 — 5通り                               |
//|                                                                  |
//| どれを採るかは目視とバックテストで決める（2026-08-18 ユーザー    |
//| 判断）。膠着はエントリーの AND 条件の1つになる予定。             |
//|                                                                  |
//| **どの方法も固定の値幅（何 pips 以下）を使わない。** ドル円は    |
//| 2018年に104円、2022年に150円まで動いており、同じ pips は同じ意味 |
//| にならない。価格で割るか、順位で決めるかのどちらかにしてある。   |
//|                                                                  |
//| **廃止済みの定義を復活させないこと。**「直前21本の終値が ±1σ の |
//| 内側」は、同じ21本から作った帯と自分を比べる形で何も測っていな   |
//| かった（値動きを20倍にしても成立率 45.7% のまま）。ここの順位方式|
//| は「今の値」を「過去N本の分布」と比べるので別物。N は期間より    |
//| ずっと長く取る。出典: docs/trading_rules.md §3.3 /              |
//| docs/research/2026-08-18-squeeze-detection.md                    |
//|                                                                  |
//| 注意: **膠着は「そろそろ動く」しか教えない。** 上か下かの予測力を|
//| 示した査読研究は見つかっていない。向きは別の条件で決めること。   |
//+------------------------------------------------------------------+
#ifndef SQUEEZE_MQH
#define SQUEEZE_MQH

#include <Signals\SuperBollinger.mqh>

//+------------------------------------------------------------------+
//| 膠着の測り方                                                     |
//|                                                                  |
//| ケルトナー以外は「過去N本の中で下から何%か」を返すので、相場全体 |
//| が静かな時期でも必ず一定割合で成立する。ケルトナーだけは過去の   |
//| 分布を使わず、ばらつきと値幅の比だけで決まるのでこの性質が無い。 |
//+------------------------------------------------------------------+
enum ENUM_SQUEEZE_METHOD
{
   SQZ_BW_RANK      = 0,   // ①帯の幅の順位
   SQZ_BW_RANK_HOUR = 1,   // ②帯の幅の順位（時刻別）
   SQZ_KELTNER      = 2,   // ③ケルトナーの内側
   SQZ_RANGE_SIGMA  = 3,   // ④高値安値のばらつきの順位
   SQZ_RANGE_RANK   = 4    // ⑤値幅の順位
};

bool SQZ_UsesRank(const ENUM_SQUEEZE_METHOD method) { return method != SQZ_KELTNER; }
bool SQZ_UsesHour(const ENUM_SQUEEZE_METHOD method) { return method == SQZ_BW_RANK_HOUR; }

//+------------------------------------------------------------------+
//| 測り方の日本語名                                                 |
//+------------------------------------------------------------------+
string SQZ_MethodLabel(const ENUM_SQUEEZE_METHOD method)
{
   switch(method)
   {
      case SQZ_BW_RANK:      return "①帯の幅の順位";
      case SQZ_BW_RANK_HOUR: return "②帯の幅の順位（時刻別）";
      case SQZ_KELTNER:      return "③ケルトナーの内側";
      case SQZ_RANGE_SIGMA:  return "④高値安値のばらつきの順位";
      case SQZ_RANGE_RANK:   return "⑤値幅の順位";
   }
   return "不明";
}

//+------------------------------------------------------------------+
//| 帯の幅 ＝ (+2σ − −2σ) ÷ センターライン                          |
//|                                                                  |
//| 上下の差は 4σ。センターラインで割るので単位が消え、価格水準が    |
//| 変わっても同じ尺度になる。ボリンジャー本人の BandWidth と同じ式。|
//|                                                                  |
//| 本人は母標準偏差（n で割る）を使うが、本プロジェクトは Matrix    |
//| Trader に合わせて標本標準偏差（n−1）。**順位方式なら定数倍の違い |
//| は順位を変えない**ので、そのままで良い。                          |
//+------------------------------------------------------------------+
bool SQZ_BandWidth(const double &close[], const int shift, const int period, double &out)
{
   SBValues v;
   if(!SB_Calc(close, shift, period, v)) return false;
   if(v.center == 0.0) return false;

   out = (4.0 * v.sigma) / v.center;
   return true;
}

//+------------------------------------------------------------------+
//| 高値と安値だけから求めるばらつき（Parkinson 1980）               |
//|                                                                  |
//| 終値だけを見る方法より少ない本数で安定する。調査で3位だった      |
//| Yang-Zhang ではなくこちらを使う理由は、Yang-Zhang の強みが       |
//| 窓開けの処理にあり、**為替の1時間足は週末以外ほとんど窓が開かない**|
//| ため。強みが効かない場面で式だけが複雑になる。                    |
//+------------------------------------------------------------------+
bool SQZ_ParkinsonSigma(const double &high[], const double &low[], const int shift,
                        const int period, double &out)
{
   if(period < 1 || shift < 0)                   return false;
   if(ArraySize(high) < shift + period)          return false;
   if(ArraySize(low)  < shift + period)          return false;

   double sum = 0.0;
   for(int i = 0; i < period; i++)
   {
      if(low[shift + i] <= 0.0) return false;
      const double r = MathLog(high[shift + i] / low[shift + i]);
      sum += r * r;
   }

   out = MathSqrt(sum / (4.0 * MathLog(2.0) * period));
   return true;
}

//+------------------------------------------------------------------+
//| その足の値幅（高値 − 安値）                                      |
//|                                                                  |
//| 順位を見る本数を 6 にすると、Crabel の NR7（その足を含む7本で    |
//| 最小の値幅）そのものになる。順位は判定する足を母集団から外して   |
//| 数えるので、7本ぶんを見るには手前の6本を指定する。               |
//+------------------------------------------------------------------+
bool SQZ_BarRange(const double &high[], const double &low[], const int shift, double &out)
{
   if(shift < 0)                    return false;
   if(ArraySize(high) <= shift)     return false;
   if(ArraySize(low)  <= shift)     return false;

   out = high[shift] - low[shift];
   return true;
}

//+------------------------------------------------------------------+
//| 値幅の平均（ATR）                                                |
//|                                                                  |
//| 1本前の終値を使うので、必要な本数が period より1本多い。         |
//+------------------------------------------------------------------+
bool SQZ_Atr(const double &high[], const double &low[], const double &close[],
             const int shift, const int period, double &out)
{
   if(period < 1 || shift < 0)                        return false;
   if(ArraySize(close) < shift + period + 1)          return false;
   if(ArraySize(high)  < shift + period)              return false;
   if(ArraySize(low)   < shift + period)              return false;

   double sum = 0.0;
   for(int i = 0; i < period; i++)
   {
      const int k = shift + i;
      const double tr = MathMax(high[k] - low[k],
                        MathMax(MathAbs(high[k] - close[k + 1]),
                                MathAbs(low[k]  - close[k + 1])));
      sum += tr;
   }

   out = sum / period;
   return true;
}

//+------------------------------------------------------------------+
//| ケルトナーの内側に入っているか（TTMスクイーズ）                  |
//|                                                                  |
//| 元の条件は「帯の上端がケルトナーの上端より下、かつ帯の下端が     |
//| ケルトナーの下端より上」。どちらもセンターラインを挟んで対称に    |
//| 書けるので、センターラインが打ち消し合って                        |
//|     2σ ＜ 倍率 × ATR                                            |
//| だけが残る。100 を境目にした比率で返す（100 未満が膠着）。       |
//|                                                                  |
//| 出典: John Carter, Mastering the Trade 第11章。倍率 1.5 は本人の |
//| 選択で、根拠は示されていない。                                    |
//+------------------------------------------------------------------+
bool SQZ_KeltnerRatio(const double &close[], const double &high[], const double &low[],
                      const int shift, const int period, const double kcMult, double &out)
{
   if(kcMult <= 0.0) return false;

   SBValues v;
   if(!SB_Calc(close, shift, period, v)) return false;

   double atr;
   if(!SQZ_Atr(high, low, close, shift, period, atr)) return false;
   if(atr <= 0.0) return false;

   out = 100.0 * (2.0 * v.sigma) / (kcMult * atr);
   return true;
}

//+------------------------------------------------------------------+
//| 順位 — 過去N本の中で下から何%の位置にいるか                      |
//|                                                                  |
//| 判定する足そのものは母集団に入れない（shift+1 から遡る）。       |
//|                                                                  |
//| sameHour を立てると、同じ時刻の足だけを母集団にする。為替は時間 |
//| 帯によって静けさが体系的に違い（アジア時間は恒常的に静か）、区別 |
//| しないと静かな時間帯が常に膠着と判定される。U字型の日中変動は    |
//| Ito & Hashimoto (2006) で確認されている。                        |
//|                                                                  |
//| 母集団が本数に満たない足では false を返す。足りない母集団で順位 |
//| を出すと、履歴の端だけ別の尺度になる。                            |
//+------------------------------------------------------------------+
bool SQZ_Rank(const double &values[], const datetime &time[], const int shift,
              const int lookback, const bool sameHour, double &pct)
{
   if(lookback < 2 || shift < 0) return false;

   const int size = ArraySize(values);
   if(shift >= size)                  return false;
   if(ArraySize(time) < size)         return false;
   if(values[shift] == EMPTY_VALUE)   return false;

   MqlDateTime cur;
   TimeToStruct(time[shift], cur);

   int taken = 0;
   int below = 0;

   for(int j = shift + 1; j < size && taken < lookback; j++)
   {
      if(values[j] == EMPTY_VALUE) continue;

      if(sameHour)
      {
         MqlDateTime t;
         TimeToStruct(time[j], t);
         if(t.hour != cur.hour) continue;
      }

      taken++;
      if(values[j] < values[shift]) below++;
   }

   if(taken < lookback) return false;

   pct = 100.0 * below / taken;
   return true;
}

//+------------------------------------------------------------------+
//| 測り方ごとの、膠着とみなす既定の水準                             |
//|                                                                  |
//| 順位方式は「下位10%」。ケルトナーは比率なので境目が 100。        |
//| ⑤は7本で最小のときだけ成立させたいので 0。                      |
//| いずれも慣習で、統計的な最適化の裏付けは原典に無い。             |
//+------------------------------------------------------------------+
double SQZ_DefaultThreshold(const ENUM_SQUEEZE_METHOD method)
{
   if(method == SQZ_KELTNER)     return 100.0;
   if(method == SQZ_RANGE_RANK)  return 0.0;
   return 10.0;
}

//+------------------------------------------------------------------+
//| 実際に使う水準                                                   |
//|                                                                  |
//| **ケルトナーには調整する水準が無い。** 境目は「帯がケルトナーの  |
//| 内側に入ったか」という定義そのものに埋まっており、比率で表すと   |
//| 必ず 100 になる。動かせるつまみは倍率のほうだけ。                |
//|                                                                  |
//| ここを入力任せにすると、測り方を切り替えた瞬間に「水準が順位用の |
//| ままで一度も成立しない」という状態になる。実際に 2026-08-18 に   |
//| そうなった。つまみが2つに割れないよう、ここで吸収する。          |
//+------------------------------------------------------------------+
double SQZ_EffectiveThreshold(const ENUM_SQUEEZE_METHOD method, const double inputThreshold)
{
   if(method == SQZ_KELTNER) return 100.0;

   return inputThreshold;
}

//+------------------------------------------------------------------+
//| 必要とする最小の履歴本数                                         |
//|                                                                  |
//| 時刻別は同じ時刻が24本に1度しか来ないので、遡る範囲が24倍要る。  |
//| 週末で並びが飛ぶぶんは余裕を見ず、足りなければ順位を出さない。   |
//+------------------------------------------------------------------+
int SQZ_RequiredBars(const ENUM_SQUEEZE_METHOD method, const int period, const int lookback)
{
   if(method == SQZ_KELTNER) return period + 2;

   const int span = SQZ_UsesHour(method) ? lookback * 24 : lookback;
   return period + span + 2;
}

#endif
