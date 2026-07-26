//+------------------------------------------------------------------+
//| PriceAction.mqh                                                  |
//| 反転系プライスアクション検出（単一足・2本足の定番3種）           |
//|                                                                  |
//| 3指標エントリーの AND 条件として使う想定。単体でのプラスは        |
//| 想定せず、トータルマイナスの回避を合格ラインとする。              |
//|                                                                  |
//| 設計:                                                            |
//|  - 確定足のみ評価（shift>=1）。未確定足は参照しない               |
//|  - 閾値は ATR 正規化（固定 pips は通貨ペア・時間足で破綻する）    |
//|  - 「当日高安更新」フィルタはその時点までの当日高安で判定し、     |
//|    未来参照（リペイント）を避ける                                |
//+------------------------------------------------------------------+
#property copyright "mql5-ea-lab"
#property strict

#include "ISignal.mqh"

//--- 検出するパターン種別
enum ENUM_PA_PATTERN
  {
   PA_NONE      = 0, // 使用しない
   PA_PINBAR    = 1, // ピンバー
   PA_ENGULFING = 2, // 包み足
   PA_HARAMI    = 3  // はらみ足
  };

//+------------------------------------------------------------------+
//| パターン検出パラメータ                                           |
//|                                                                  |
//| 既定値は一般的な定義に基づく暫定値。目視確認後に調整する。       |
//+------------------------------------------------------------------+
struct SPriceActionParams
  {
   //--- ピンバー
   double            pin_wick_ratio;      // 長ヒゲ / 全レンジ の下限
   double            pin_opposite_ratio;  // 反対ヒゲ / 全レンジ の上限
   //--- 包み足 / はらみ足
   bool              require_color_flip;  // 色の反転を必須とするか
   double            min_prev_body_atr;   // 前足実体の下限（ATR 比）
   //--- 共通
   double            min_range_atr;       // 全レンジの下限（ATR 比）
   bool              require_day_extreme; // 当日高安の更新を必須とするか

                     SPriceActionParams(void)
     {
      pin_wick_ratio      = 0.66;
      pin_opposite_ratio  = 0.15;
      require_color_flip  = true;
      min_prev_body_atr   = 0.10;
      min_range_atr       = 0.50;
      require_day_extreme = true;
     }
  };

//+------------------------------------------------------------------+
//| プライスアクション検出器                                         |
//+------------------------------------------------------------------+
class CPriceAction
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_atr_handle;
   int               m_atr_period;
   SPriceActionParams m_params;

   //--- 指定 shift の ATR を取得
   bool              GetATR(const int shift, double &atr);
   //--- 指定 shift の足が当日高安を更新しているか
   bool              IsDayExtreme(const int shift, const ENUM_SIGNAL_DIR dir);
   //--- 各パターンの形状判定（当日高安フィルタは含まない）
   ENUM_SIGNAL_DIR   DetectPinBar(const int shift, const double atr);
   ENUM_SIGNAL_DIR   DetectEngulfing(const int shift, const double atr);
   ENUM_SIGNAL_DIR   DetectHarami(const int shift, const double atr);

public:
                     CPriceAction(const int atr_period = 14);
                    ~CPriceAction(void);

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf);
   void              SetParams(const SPriceActionParams &params) { m_params = params; }

   //--- 指定 shift の足がパターンを形成しているか。方向を返す
   ENUM_SIGNAL_DIR   Detect(const ENUM_PA_PATTERN pattern, const int shift = 1);
  };

//+------------------------------------------------------------------+
//| コンストラクタ                                                   |
//+------------------------------------------------------------------+
CPriceAction::CPriceAction(const int atr_period)
  {
   m_symbol     = "";
   m_tf         = PERIOD_CURRENT;
   m_atr_handle = INVALID_HANDLE;
   m_atr_period = atr_period;
  }

//+------------------------------------------------------------------+
//| デストラクタ                                                     |
//+------------------------------------------------------------------+
CPriceAction::~CPriceAction(void)
  {
   if(m_atr_handle != INVALID_HANDLE)
      IndicatorRelease(m_atr_handle);
  }

//+------------------------------------------------------------------+
//| 初期化                                                           |
//+------------------------------------------------------------------+
bool CPriceAction::Init(const string symbol, const ENUM_TIMEFRAMES tf)
  {
   m_symbol = symbol;
   m_tf     = tf;

   m_atr_handle = iATR(symbol, tf, m_atr_period);
   if(m_atr_handle == INVALID_HANDLE)
     {
      PrintFormat("CPriceAction: iATR ハンドル取得失敗 (error=%d)", GetLastError());
      return(false);
     }
   return(true);
  }

//+------------------------------------------------------------------+
//| ATR 取得                                                         |
//+------------------------------------------------------------------+
bool CPriceAction::GetATR(const int shift, double &atr)
  {
   double buf[];
   ArraySetAsSeries(buf, true);

   if(CopyBuffer(m_atr_handle, 0, shift, 1, buf) < 1)
      return(false);

   atr = buf[0];
   return(atr > 0.0);
  }

//+------------------------------------------------------------------+
//| 当日高安の更新判定                                               |
//|                                                                  |
//| 「その時点までの当日高安」で判定する。日が終わってからの確定     |
//| 高安を使うと未来参照となりバックテストが実運用と乖離するため、    |
//| 探索範囲は当日 00:00 〜 対象足 までに限定する。                  |
//+------------------------------------------------------------------+
bool CPriceAction::IsDayExtreme(const int shift, const ENUM_SIGNAL_DIR dir)
  {
   datetime bar_time = iTime(m_symbol, m_tf, shift);
   if(bar_time == 0)
      return(false);

   //--- 対象足が属する日の 00:00 を求める
   MqlDateTime dt;
   if(!TimeToStruct(bar_time, dt))
      return(false);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   datetime day_start = StructToTime(dt);

   //--- 当日開始以降・対象足までのバー本数
   int start_shift = iBarShift(m_symbol, m_tf, day_start, false);
   if(start_shift < 0)
      return(false);

   int count = start_shift - shift + 1;
   if(count <= 0)
      return(false);

   //--- 対象足自身が当日レンジの端を作っていること
   if(dir == SIGNAL_LONG)
     {
      int idx = iLowest(m_symbol, m_tf, MODE_LOW, count, shift);
      return(idx == shift);
     }

   if(dir == SIGNAL_SHORT)
     {
      int idx = iHighest(m_symbol, m_tf, MODE_HIGH, count, shift);
      return(idx == shift);
     }

   return(false);
  }

//+------------------------------------------------------------------+
//| ピンバー判定                                                     |
//|                                                                  |
//| 下ヒゲが長い → 買い / 上ヒゲが長い → 売り                        |
//| 実体の色は問わない。                                             |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CPriceAction::DetectPinBar(const int shift, const double atr)
  {
   double h = iHigh(m_symbol, m_tf, shift);
   double l = iLow(m_symbol, m_tf, shift);
   double o = iOpen(m_symbol, m_tf, shift);
   double c = iClose(m_symbol, m_tf, shift);

   double range = h - l;
   if(range <= 0.0 || range < atr * m_params.min_range_atr)
      return(SIGNAL_NONE);

   double body_hi = MathMax(o, c);
   double body_lo = MathMin(o, c);

   double upper_wick = h - body_hi;
   double lower_wick = body_lo - l;

   //--- 下ヒゲピンバー（買い）
   if(lower_wick >= range * m_params.pin_wick_ratio &&
      upper_wick <= range * m_params.pin_opposite_ratio)
      return(SIGNAL_LONG);

   //--- 上ヒゲピンバー（売り）
   if(upper_wick >= range * m_params.pin_wick_ratio &&
      lower_wick <= range * m_params.pin_opposite_ratio)
      return(SIGNAL_SHORT);

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| 包み足判定（実体基準）                                           |
//|                                                                  |
//| 陰 → 陽 で前足の実体を包む → 買い                                |
//| 陽 → 陰 で前足の実体を包む → 売り                                |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CPriceAction::DetectEngulfing(const int shift, const double atr)
  {
   double o1 = iOpen(m_symbol,  m_tf, shift + 1);
   double c1 = iClose(m_symbol, m_tf, shift + 1);
   double o0 = iOpen(m_symbol,  m_tf, shift);
   double c0 = iClose(m_symbol, m_tf, shift);

   double range = iHigh(m_symbol, m_tf, shift) - iLow(m_symbol, m_tf, shift);
   if(range <= 0.0 || range < atr * m_params.min_range_atr)
      return(SIGNAL_NONE);

   //--- 前足の実体が極小なら包んでも意味が薄い
   double prev_body = MathAbs(c1 - o1);
   if(prev_body < atr * m_params.min_prev_body_atr)
      return(SIGNAL_NONE);

   double prev_hi = MathMax(o1, c1);
   double prev_lo = MathMin(o1, c1);
   double curr_hi = MathMax(o0, c0);
   double curr_lo = MathMin(o0, c0);

   //--- 前足の実体を完全に包含していること
   if(!(curr_hi >= prev_hi && curr_lo <= prev_lo))
      return(SIGNAL_NONE);

   bool prev_bear = (c1 < o1);
   bool curr_bull = (c0 > o0);

   //--- 陰 → 陽（買い）
   if(curr_bull && (!m_params.require_color_flip || prev_bear))
      return(SIGNAL_LONG);

   //--- 陽 → 陰（売り）
   if(!curr_bull && c0 < o0 && (!m_params.require_color_flip || !prev_bear))
      return(SIGNAL_SHORT);

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| はらみ足判定（実体基準）                                         |
//|                                                                  |
//| 前足の実体内に収まる。陰 → 陽 で買い / 陽 → 陰 で売り。          |
//| ボラティリティ縮小の示唆であり、包み足とは逆の形。               |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CPriceAction::DetectHarami(const int shift, const double atr)
  {
   double o1 = iOpen(m_symbol,  m_tf, shift + 1);
   double c1 = iClose(m_symbol, m_tf, shift + 1);
   double o0 = iOpen(m_symbol,  m_tf, shift);
   double c0 = iClose(m_symbol, m_tf, shift);

   //--- はらみは前足が大きいことが条件。前足レンジで下限を見る
   double prev_range = iHigh(m_symbol, m_tf, shift + 1) - iLow(m_symbol, m_tf, shift + 1);
   if(prev_range <= 0.0 || prev_range < atr * m_params.min_range_atr)
      return(SIGNAL_NONE);

   double prev_body = MathAbs(c1 - o1);
   if(prev_body < atr * m_params.min_prev_body_atr)
      return(SIGNAL_NONE);

   double prev_hi = MathMax(o1, c1);
   double prev_lo = MathMin(o1, c1);
   double curr_hi = MathMax(o0, c0);
   double curr_lo = MathMin(o0, c0);

   //--- 前足の実体内に収まっていること
   if(!(curr_hi <= prev_hi && curr_lo >= prev_lo))
      return(SIGNAL_NONE);

   bool prev_bear = (c1 < o1);
   bool curr_bull = (c0 > o0);

   //--- 陰 → 陽（買い）
   if(curr_bull && (!m_params.require_color_flip || prev_bear))
      return(SIGNAL_LONG);

   //--- 陽 → 陰（売り）
   if(!curr_bull && c0 < o0 && (!m_params.require_color_flip || !prev_bear))
      return(SIGNAL_SHORT);

   return(SIGNAL_NONE);
  }

//+------------------------------------------------------------------+
//| パターン検出（外部インターフェース）                             |
//|                                                                  |
//| shift=1 が直近の確定足。未確定足(shift=0)は呼ばない想定。        |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CPriceAction::Detect(const ENUM_PA_PATTERN pattern, const int shift)
  {
   if(pattern == PA_NONE || shift < 1)
      return(SIGNAL_NONE);

   //--- 2本足パターンは shift+1 まで必要
   if(Bars(m_symbol, m_tf) <= shift + 1)
      return(SIGNAL_NONE);

   double atr = 0.0;
   if(!GetATR(shift, atr))
      return(SIGNAL_NONE);

   ENUM_SIGNAL_DIR dir = SIGNAL_NONE;

   switch(pattern)
     {
      case PA_PINBAR:
         dir = DetectPinBar(shift, atr);
         break;
      case PA_ENGULFING:
         dir = DetectEngulfing(shift, atr);
         break;
      case PA_HARAMI:
         dir = DetectHarami(shift, atr);
         break;
      default:
         return(SIGNAL_NONE);
     }

   if(dir == SIGNAL_NONE)
      return(SIGNAL_NONE);

   //--- 当日高安の更新を必須とする場合はここで絞る
   if(m_params.require_day_extreme && !IsDayExtreme(shift, dir))
      return(SIGNAL_NONE);

   return(dir);
  }
//+------------------------------------------------------------------+
