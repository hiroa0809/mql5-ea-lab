//+------------------------------------------------------------------+
//| ISignal.mqh                                                      |
//| エントリー／エグジット判定部品の共通インターフェース             |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property strict

//--- シグナル方向
enum ENUM_SIGNAL_DIR
  {
   SIGNAL_NONE  = 0, // シグナルなし
   SIGNAL_LONG  = 1, // 買い
   SIGNAL_SHORT = -1 // 売り
  };

//+------------------------------------------------------------------+
//| シグナル部品の基底クラス                                         |
//|                                                                  |
//| 各部品は確定足ごとに Entry() を評価する。                        |
//| クロス判定は部品側が持ち、EA 本体は方向のみを受け取る。          |
//|                                                                  |
//| 決済は部品側に持たせない。採用済みの決済ルールは 3 部品に共通の  |
//| N 本タイムストップであり、EA 本体が担当する（仕様書 §1.2/§5）。  |
//+------------------------------------------------------------------+
class ISignal
  {
public:
   virtual         ~ISignal(void) {}

   //--- 指標ハンドル等の初期化。成功したら true
   virtual bool      Init(const string symbol, const ENUM_TIMEFRAMES tf) = 0;

   //--- 確定足の値を取り込む。取得失敗時は false
   virtual bool      Update(void) = 0;

   //--- エントリー方向を返す
   virtual ENUM_SIGNAL_DIR Entry(void) = 0;
  };

//+------------------------------------------------------------------+
//| クロス判定ヘルパ                                                 |
//|                                                                  |
//| 「外から中へ突入した 1 本」だけを true とする。                  |
//| ゾーン滞在中（prev もゾーン内）は false。                        |
//| prev / curr が無効値の場合は呼び出し側で除外すること。           |
//|                                                                  |
//| 境界（値が閾値ちょうど）の扱いは研究側 `band_entry_signal` に    |
//| 合わせている。すなわち prev が閾値ちょうどなら「まだ外側」、     |
//| curr は閾値を厳密に越えて初めて「突入」とみなす。EA 側で等号を   |
//| 逆に付けると検証時と判定が変わるため、変更しないこと。           |
//+------------------------------------------------------------------+

//--- 閾値を下抜けたか（研究: prev >= lower && curr < lower）
bool CrossedBelow(const double prev, const double curr, const double threshold)
  {
   return(prev >= threshold && curr < threshold);
  }

//--- 閾値を上抜けたか（研究: prev <= upper && curr > upper）
bool CrossedAbove(const double prev, const double curr, const double threshold)
  {
   return(prev <= threshold && curr > threshold);
  }
//+------------------------------------------------------------------+
