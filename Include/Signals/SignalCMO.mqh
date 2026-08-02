//+------------------------------------------------------------------+
//| SignalCMO.mqh                                                    |
//| CMO(14) ±50 逆張りエントリー                                     |
//|                                                                  |
//| 決済は本部品では扱わない（N 本タイムストップを EA 本体が担当）。 |
//|                                                                  |
//| 仕様: docs/entry_signal_spec.md §2.2                             |
//|                                                                  |
//| MQL5 に標準の CMO 関数はないため終値から自前計算する。            |
//| 指標ハンドルは持たない。                                         |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property strict

#include "ISignal.mqh"

//+------------------------------------------------------------------+
//| SU + SD = 0（直近 period 本が完全に不動）で返す無効値            |
//|                                                                  |
//| 仕様 §2.2 に従い NaN を返す。NaN との比較は常に false になるため |
//| CrossedBelow/CrossedAbove が発火せず、シグナル無しとなる。       |
//| IEEE754 の quiet NaN をビットパターンから直接組み立てる。        |
//| MathSqrt(-1) 等は実装依存のため使わない。                        |
//+------------------------------------------------------------------+
union CmoDoubleBits
  {
   ulong             bits;
   double            value;
  };

double CmoInvalidValue(void)
  {
   CmoDoubleBits v;
   v.bits = 0x7FF8000000000000;
   return(v.value);
  }

//+------------------------------------------------------------------+
//| CMO シグナル部品                                                 |
//+------------------------------------------------------------------+
class CSignalCMO : public ISignal
  {
private:
   string            m_symbol;        // 対象シンボル
   ENUM_TIMEFRAMES   m_tf;            // 対象時間足
   int               m_period;        // CMO 期間
   double            m_lower;         // 売られすぎ閾値
   double            m_upper;         // 買われすぎ閾値
   double            m_prev;          // 1 本前の確定足の CMO
   double            m_curr;          // 直近確定足の CMO
   bool              m_ready;         // prev/curr が揃ったか

   double            Calculate(const double &close[], const int offset);

public:
                     CSignalCMO(const int period = 14,
                                const double lower = -50.0,
                                const double upper = 50.0);
                    ~CSignalCMO(void);

   virtual bool      Init(const string symbol, const ENUM_TIMEFRAMES tf);
   virtual bool      Update(void);
   virtual ENUM_SIGNAL_DIR Entry(void);
  };

//+------------------------------------------------------------------+
//| コンストラクタ                                                   |
//+------------------------------------------------------------------+
CSignalCMO::CSignalCMO(const int period,
                       const double lower,
                       const double upper)
  {
   m_symbol     = NULL;
   m_tf         = PERIOD_CURRENT;
   m_period     = period;
   m_lower      = lower;
   m_upper      = upper;
   m_prev       = 0.0;
   m_curr       = 0.0;
   m_ready      = false;
  }

//+------------------------------------------------------------------+
//| デストラクタ                                                     |
//+------------------------------------------------------------------+
CSignalCMO::~CSignalCMO(void)
  {
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//|                                                                  |
//| 指標ハンドルを持たないため、対象の記憶と期間の検証のみ行う。     |
//+------------------------------------------------------------------+
bool CSignalCMO::Init(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   if(m_period < 1)
     {
      PrintFormat("CSignalCMO: 期間が不正です (period=%d)", m_period);
      return(false);
     }

   m_symbol = symbol;
   m_tf     = tf;
   return(true);
  }

//+------------------------------------------------------------------+
//| 確定足の CMO を取り込む                                          |
//|                                                                  |
//| shift=1 が直近の確定足、shift=2 がその 1 本前。                  |
//| 未確定足(shift=0)は使わない。                                    |
//|                                                                  |
//| shift=1 の CMO には終値が period+1 本、shift=2 の分も含めると    |
//| period+2 本必要。取得は shift=1 起点なので close[0] が shift=1。 |
//+------------------------------------------------------------------+
bool CSignalCMO::Update(void)
  {
   double close[];
   ArraySetAsSeries(close, true);

   int need = m_period + 2;
   if(CopyClose(m_symbol, m_tf, 1, need, close) < need)
     {
      m_ready = false;
      return(false);
     }

   m_curr  = Calculate(close, 0); // 直近の確定足(shift=1)
   m_prev  = Calculate(close, 1); // その 1 本前(shift=2)
   m_ready = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| CMO 本体の計算                                                   |
//|                                                                  |
//| CMO = 100 × (SU − SD) ÷ (SU + SD)                                |
//| SU/SD は直近 period 本の上昇幅・下落幅の単純合計（平滑しない）。 |
//| close は時系列順（index 0 が新しい）。offset は起点の index。    |
//+------------------------------------------------------------------+
double CSignalCMO::Calculate(const double &close[], const int offset)
  {
   double su = 0.0;
   double sd = 0.0;

   for(int i = 0; i < m_period; i++)
     {
      double diff = close[offset + i] - close[offset + i + 1];
      if(diff > 0.0)
         su += diff;
      else
         sd += -diff;
     }

   double denom = su + sd;
   if(denom == 0.0)
      return(CmoInvalidValue());

   return(100.0 * (su - sd) / denom);
  }

//+------------------------------------------------------------------+
//| エントリー判定                                                   |
//|                                                                  |
//| −50 を下抜け → 買い / +50 を上抜け → 売り                        |
//| ゾーン滞在中は発火しない（クロスした 1 本のみ）。                |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CSignalCMO::Entry(void)
  {
   if(!m_ready)
      return(SIGNAL_NONE);

   if(CrossedBelow(m_prev, m_curr, m_lower))
      return(SIGNAL_LONG);

   if(CrossedAbove(m_prev, m_curr, m_upper))
      return(SIGNAL_SHORT);

   return(SIGNAL_NONE);
  }
//+------------------------------------------------------------------+
