//+------------------------------------------------------------------+
//| PriceAction.mqh                                                  |
//| 反転系プライスアクション検出（包み足）                           |
//|                                                                  |
//| 3指標エントリーの AND 条件として使う想定。単体でのプラスは        |
//| 想定せず、トータルマイナスの回避を合格ラインとする。              |
//|                                                                  |
//| ピンバー・はらみ足は E4 のバックテストで優位性が無く不採用と      |
//| なったため削除した（2026-07-31）。復活させる場合は履歴を参照。    |
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
   PA_ENGULFING = 2  // 包み足
  };
//--- 値 2 は削除前から変えていない。既存の .set ファイルが整数で
//    保持しているため、詰めると過去のテスト設定が別の意味になる。

//+------------------------------------------------------------------+
//| パターン検出パラメータ                                           |
//|                                                                  |
//| 既定値は一般的な定義に基づく暫定値。目視確認後に調整する。       |
//+------------------------------------------------------------------+
struct SPriceActionParams
  {
   //--- 包み足
   bool              require_color_flip;  // 色の反転を必須とするか
   //--- 共通
   double            min_range_atr;       // 全レンジの下限（ATR 比）
   bool              require_day_extreme; // 当日高安の更新を必須とするか

                     SPriceActionParams(void)
     {
      require_color_flip  = true;
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
   //--- パターンの形状判定（当日高安フィルタは含まない）
   ENUM_SIGNAL_DIR   DetectEngulfing(const int shift, const double atr);

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

   //--- 当日最初の足は比較対象が自分しかなく、iLowest/iHighest が
   //    必ず自分を返すためフィルタが無効化される。除外する。
   if(count <= 1)
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
//| 包み足判定（アウトサイドバー）                                   |
//|                                                                  |
//| 定義（2条件とも必須・固定仕様）:                                 |
//|  ① 一本目の高値と安値を、二本目の高値と安値が完全に包む         |
//|  ② 一本目の高値(安値)を、二本目の終値が完全に超えて終えている   |
//|                                                                  |
//| 実体ではなく**全レンジ（ヒゲ含む）**で判定する。                 |
//| ② を課すのは、前足の値動きを完全に否定して終えた形だけを拾う     |
//| ため。② が無いとヒゲでは包んだが終値は前足レンジ内、という      |
//| 中途半端な足も混入する。                                         |
//|                                                                  |
//| 陰 → 陽 で包む → 買い / 陽 → 陰 で包む → 売り                    |
//+------------------------------------------------------------------+
ENUM_SIGNAL_DIR CPriceAction::DetectEngulfing(const int shift, const double atr)
  {
   double h1 = iHigh(m_symbol,  m_tf, shift + 1);
   double l1 = iLow(m_symbol,   m_tf, shift + 1);
   double o1 = iOpen(m_symbol,  m_tf, shift + 1);
   double c1 = iClose(m_symbol, m_tf, shift + 1);

   double h0 = iHigh(m_symbol,  m_tf, shift);
   double l0 = iLow(m_symbol,   m_tf, shift);
   double o0 = iOpen(m_symbol,  m_tf, shift);
   double c0 = iClose(m_symbol, m_tf, shift);

   double range = h0 - l0;
   if(range <= 0.0 || range < atr * m_params.min_range_atr)
      return(SIGNAL_NONE);

   //--- ① 一本目の高値・安値を完全に包んでいること（ヒゲ含む）
   //    同値は「超えた」と見なさないため等号を含めない
   if(!(h0 > h1 && l0 < l1))
      return(SIGNAL_NONE);

   bool prev_bear = (c1 < o1);
   bool curr_bull = (c0 > o0);
   bool curr_bear = (c0 < o0);

   //--- 陰 → 陽（買い）: ② 終値が一本目の高値を超えて終えていること
   if(curr_bull && (!m_params.require_color_flip || prev_bear) && c0 > h1)
      return(SIGNAL_LONG);

   //--- 陽 → 陰（売り）: ② 終値が一本目の安値を割って終えていること
   if(curr_bear && (!m_params.require_color_flip || !prev_bear) && c0 < l1)
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

   if(pattern != PA_ENGULFING)
      return(SIGNAL_NONE);

   ENUM_SIGNAL_DIR dir = DetectEngulfing(shift, atr);
   if(dir == SIGNAL_NONE)
      return(SIGNAL_NONE);

   //--- 当日高安の更新を必須とする場合はここで絞る
   //    判定対象はパターンを形成した足自身
   if(m_params.require_day_extreme && !IsDayExtreme(shift, dir))
      return(SIGNAL_NONE);

   return(dir);
  }
//+------------------------------------------------------------------+
