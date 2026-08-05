//+------------------------------------------------------------------+
//| SignalRSI.mqh                                                    |
//| RSI(9) 30/70 逆張りエントリー                                    |
//|                                                                  |
//| 決済は本部品では扱わない（N 本タイムストップを EA 本体が担当）。 |
//|                                                                  |
//| 仕様: docs/entry_signal_spec.md §2.3                             |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property strict

#include "ISignal.mqh"

//+------------------------------------------------------------------+
//| RSI シグナル部品                                                 |
//+------------------------------------------------------------------+
class CSignalRSI : public ISignal
  {
private:
   int               m_handle;        // iRSI ハンドル
   int               m_period;        // RSI 期間
   double            m_lower;         // 売られすぎ閾値
   double            m_upper;         // 買われすぎ閾値
   double            m_prev;          // 1 本前の確定足の RSI
   double            m_curr;          // 直近確定足の RSI
   bool              m_ready;         // prev/curr が揃ったか

public:
                     CSignalRSI(const int period = 9,
                                const double lower = 30.0,
                                const double upper = 70.0);
                    ~CSignalRSI(void);

   virtual bool      Init(const string symbol, const ENUM_TIMEFRAMES tf);
   virtual bool      Update(void);
   virtual ENUM_SIGNAL_DIR Entry(void);

   //--- 決済判定を EA 本体で行うための値の公開
   double            Prev(void)  const { return(m_prev); }
   double            Curr(void)  const { return(m_curr); }
   bool              Ready(void) const { return(m_ready); }
  };

//+------------------------------------------------------------------+
//| コンストラクタ                                                   |
//+------------------------------------------------------------------+
CSignalRSI::CSignalRSI(const int period,
                       const double lower,
                       const double upper)
  {
   m_handle     = INVALID_HANDLE;
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
CSignalRSI::~CSignalRSI(void)
  {
   if(m_handle != INVALID_HANDLE)
      IndicatorRelease(m_handle);
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
bool CSignalRSI::Init(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   m_handle = iRSI(symbol, tf, m_period, PRICE_CLOSE);
   if(m_handle == INVALID_HANDLE)
     {
      PrintFormat("CSignalRSI: iRSI ハンドル取得失敗 (error=%d)", GetLastError());
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| 確定足の RSI を取り込む                                          |
//|                                                                  |
//| shift=1 が直近の確定足、shift=2 がその 1 本前。                  |
//| 未確定足(shift=0)は使わない。                                    |
//+------------------------------------------------------------------+
bool CSignalRSI::Update(void)
  {
   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(m_handle, 0, 1, 2, buf) < 2)
     {
      m_ready = false;
      return(false);
     }

   m_curr  = buf[0]; // 直近の確定足
   m_prev  = buf[1]; // その 1 本前
   m_ready = true;
   return(true);
  }

//+------------------------------------------------------------------+
//| エントリー判定                                                   |
//|                                                                  |
//| 30 を下抜け → 買い / 70 を上抜け → 売り                          |
//| ゾーン滞在中は発火しない（クロスした 1 本のみ）。                |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CSignalRSI::Entry(void)
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
