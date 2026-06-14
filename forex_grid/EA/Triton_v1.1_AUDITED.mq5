//+------------------------------------------------------------------+
//|                                          Triton_v1.1_AUDITED.mq5  |
//|                           Regime-Aware Grid Sequencing EA        |
//|                       Version 1.1 (audited) — June 2026          |
//+------------------------------------------------------------------+
//
// TRITON — Grid-based basket mean reversion system for MT5.
// Product-faithful reconstruction of ArchAngelX behavior.
// See PRODUCT_BEHAVIOR_SPEC.md / IMPLEMENTATION_AUDIT.md / PATCH_REPORT.md.
//
// Sequences orders at exponentially expanding pip steps with
// exponentially increasing lot sizes, then closes the entire basket
// based on weighted-average TP, lock profit + trailing stop,
// or equity/risk guardrails.
//
// ARCHITECTURE (5 layers, strict priority):
//   Layer 5: EquityGuard      — overrides everything
//   Layer 4: RegimeFilter     — session, news, indicator gates
//   Layer 3: GridEngine       — sequence construction
//   Layer 2: BasketExitEngine — TP, lock profit, trailing
//   Layer 1: OnTester         — prop-firm survival scoring
//
// STATE MACHINE:
//   IDLE → BUILDING → LOCKED → (exit/close)
//   Any → PAUSED_BY_SESSION | PAUSED_BY_NEWS
//   Any → STOPPED_BY_EQUITY | STOPPED_BY_LOSS
//
// DETERMINISM GUARANTEES (required for MT5 optimization):
//   - No dynamic arrays that resize unpredictably
//   - Seeded PRNG only (xorshift32)
//   - No file I/O between ticks
//   - Identical tick data → identical results
//
// ATR MODE: Enter negative pip values to use ATR multiplier.
//   e.g. PipStep = -1.5  →  step = 1.5 × ATR(ATRPeriod)
//   Positive values are raw pips.
//
//+------------------------------------------------------------------+

#property copyright "Triton"
#property link      ""
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>

// =====================================================================
// ENUMERATIONS
// =====================================================================

enum ENUM_TRADE_DIRECTION
{
   BOTH        = 0, // Long & Short
   LONG_ONLY   = 1, // Long Only
   SHORT_ONLY  = 2  // Short Only
};

enum ENUM_LOCK_CHECK_MODE
{
   BAR_CLOSE_CHART = 0, // On Bar Close (Chart TimeFr
   BAR_CLOSE_M1    = 1, // On Bar Close (M1)
   EVERY_TICK      = 2  // Every Tick
};

// Product enum order (confirmed by ArchAngelX optimizer screenshots):
// Close all trades = 0, Complete the sequence = 1, Pause the sequence = 2
enum ENUM_SESSION_END_ACTION
{
   CLOSE_ALL_TRADES   = 0, // Close all trades
   COMPLETE_SEQUENCE  = 1, // Complete the sequence
   PAUSE_SEQUENCE     = 2  // Pause the sequence
};

enum ENUM_RESTART_MODE
{
   RESTART_NEXT_DAY    = 0, // Restart Next Day
   RESTART_AFTER_HOURS = 1  // Restart In Hours
};

enum ENUM_EQUITY_STOP_TYPE
{
   EQUITY_ABSOLUTE        = 0, // Absolute Equity
   EQUITY_RISKED_AMOUNT   = 1, // Risked Amount
   EQUITY_RISKED_PERCENT  = 2  // Risked Percentage
};

enum ENUM_EMA_TREND_RULE
{
   WITH_TREND_ONLY      = 0, // Trade trend only
   AVOID_OPPOSITE_TREND = 1  // Trade against trend only
};

enum ENUM_ADX_TREND_RULE
{
   ADX_WITH_TREND_ONLY      = 0, // Trade trend only
   ADX_AVOID_OPPOSITE_TREND = 1  // Trade against trend only
};

enum ENUM_BB_MODE
{
   BB_AVOID_EXTREME              = 0, // Avoid Extreme
   BB_ONLY_EXTREME_COUNTER_TREND = 1  // Only Extreme Counter Trend
};

// Product enum order (confirmed by ArchAngelX optimizer screenshots):
// Close all trades = 0, Complete the sequence = 1, Pause the sequence = 2
enum ENUM_NEWS_ACTION
{
   NEWS_CLOSE_ALL         = 0, // Close all trades
   NEWS_COMPLETE_SEQUENCE = 1, // Complete the sequence
   NEWS_PAUSE_SEQUENCE    = 2  // Pause the sequence
};

enum ENUM_SEQUENCE_STATE
{
   STATE_IDLE              = 0,
   STATE_BUILDING          = 1,
   STATE_LOCKED            = 2,
   STATE_PAUSED_BY_SESSION = 3,
   STATE_PAUSED_BY_NEWS    = 4,
   STATE_STOPPED_BY_EQUITY = 5,
   STATE_STOPPED_BY_LOSS   = 6
};


// =====================================================================
// INPUT PARAMETERS
// =====================================================================

//--- General Trade Settings
input group "═══ GENERAL TRADE SETTINGS ═══"
input bool     AllowNewSequence          = true;           // Allow New Sequence?
input string   StrategyDescription       = "";             // Strategy Description (Comments about strategy you are using)
input string   TradeComment              = "";             // Trade Comment
input long     MagicNumber               = 26062023;       // Magic Number
input bool     UseRandomEntryDelay       = false;          // Use Random Entry Delay?
input int      RandomSeed                = 42;             // Random Seed (deterministic PRNG)
input int      RandomEntryDelayMinSeconds = 1;             // Random Entry Delay Min Seconds
input int      RandomEntryDelayMaxSeconds = 30;            // Random Entry Delay Max Seconds
input int      LogLevel                  = 1;              // Log Level (0=silent 1=major 2=verbose 3=debug)

//--- EA Licensing Settings
input group "═══ EA LICENSING SETTINGS ═══"
input string   LicenseKey               = "";              // License Key

//--- Sequence Settings
input group "═══ SEQUENCE SETTINGS ═══"
input string   ATRUsageInfo             = "[Only values entered in negative will be treated as ATR multiplier]"; // ATR Usage Info
input int      ATRPeriod                = 14;              // ATR Period
input double   PipStep                  = 15.0;            // Pip Step
input double   PipStepExponent          = 1.5;             // Pip Step Exponent
input double   MaxPipStep               = 0.0;             // Max Pip Step (0 = No limit)
input int      DelayTradeSequence       = 3;               // Delay Trade Sequence (0 = Off)
input int      LiveDelay                = 0;               // Live Delay (0 = Off)
input double   LotMultiplierFirstTradeAfterLD = 1.0;       // Lot Multiplier for 1st Trade after LD (1= Off)
input bool     CombineLiveDelayTrades   = true;            // Combine Live Delay Trades?
input ENUM_TRADE_DIRECTION TradeDirection = BOTH;          // Trade Direction
input int      MaxOrdersPerDirection    = 10;              // Max Orders (Per Direction)
input bool     ReverseSequenceDirection = false;           // Reverse Sequence Direction?

//--- Money Management Settings
input group "═══ MONEY MANAGEMENT SETTINGS ═══"
input double   TakeProfit               = 50.0;            // TakeProfit (Pips)
input double   StopLoss                 = 0.0;             // StopLoss (Pips)
input int      LockProfitMinTrades      = 0;               // Lock Profit Min Trades
input double   LockProfit               = 30.0;            // Lock Profit (Pips)
input ENUM_LOCK_CHECK_MODE LockProfitCheckMode = BAR_CLOSE_CHART; // Lock Profit - When to check
input double   TrailingStop             = 10.0;            // Trailing Stoploss (Pips)
input ENUM_LOCK_CHECK_MODE TrailingCheckMode   = BAR_CLOSE_CHART; // Trailing Stoploss - When to check
input bool     AllowSamePairDirectionTrades = false;       // Allow Same (Pair & Direction) Trades?

//--- Compound Settings
input group "═══ COMPOUND SETTINGS ═══"
input bool     UseCompounding           = false;           // Use Compounding?
input double   InitialAccountBalanceThreshold = 100000.0;  // Initial Account Balance Threshold
input double   RiskPercentForCompounding = 1.0;            // Risk % for Compounding
input double   RiskInPips               = 100.0;           // Risk In Pips (Compounding)
input double   MaxLotSizeForCompounding = 10.0;            // Max Lot Size (Compounding)

//--- Lotsize Settings
input group "═══ LOTSIZE SETTINGS ═══"
input double   LotSize                  = 0.1;             // Lot Size
input double   RiskPercent              = 0.0;             // Risk % (0 = Off, Requires Stoploss)
input double   LotSizeExponent          = 1.2;             // Lot Size Exponent
input double   MaxLotSize               = 1.0;             // Max Lot Size (0 = No Limit)

//--- Weekend Closure Settings
input group "═══ WEEKEND CLOSURE SETTINGS ═══"
input bool     CloseForWeekend          = false;           // Close for Weekend
input ENUM_DAY_OF_WEEK DayToClose       = FRIDAY;          // Day to Close
input string   TimeToClose              = "21:00";         // Time to Close
input ENUM_DAY_OF_WEEK DayToRestart     = MONDAY;          // Day to Restart
input string   TimeToRestart            = "01:00";         // Time to Restart

//--- Trading Session Settings
input group "═══ TRADING SESSION SETTINGS ═══"
input bool     TradeCustomTimes         = false;           // Trade Custom Times
input string   TradingSessionMonday     = "00:00-23:59";   // Trading Session (Monday)
input string   TradingSessionTuesday    = "00:00-23:59";   // Trading Session (Tuesday)
input string   TradingSessionWednesday  = "00:00-23:59";   // Trading Session (Wednesday)
input string   TradingSessionThursday   = "00:00-23:59";   // Trading Session (Thursday)
input string   TradingSessionFriday     = "00:00-23:59";   // Trading Session (Friday)
input ENUM_SESSION_END_ACTION ActionAtEndOfSession = COMPLETE_SEQUENCE; // Action at the end of Session

//--- Equity Protector Settings
input group "═══ EQUITY PROTECTOR SETTINGS ═══"
input double   MaxRunningLoss           = 0.0;             // Max Running Loss ($) (0 = Off)
input ENUM_RESTART_MODE RestartEAAfterLoss = RESTART_NEXT_DAY; // Restart EA After Loss
input string   RestartNextDayAt         = "01:00";         // Restart Next Day At
input double   RestartAfterHours        = 3.0;             // Restart After Hours
input double   DailyProfitTarget        = 0.0;             // Daily Profit Target ($) (0 = Off)
input double   UltimateTargetBalance    = 0.0;             // Ultimate Target Balance (0 = Off)
input ENUM_EQUITY_STOP_TYPE GlobalEquityStopType = EQUITY_ABSOLUTE; // Global Equity Stop Type
input double   GlobalEquityStopValue    = 0.0;             // Global Equity Stop (In $ or %, 0 = Off)
input bool     ResetGlobalEquityStop    = false;           // Reset Global Equity Stop?
input int      MinSecondsBetweenTrades  = 0;               // Min Seconds Between Trades

//--- Indicators Settings — RSI
input group "═══ INDICATORS SETTINGS — RSI ═══"
input bool     UseRSI                   = false;           // Use RSI?
input ENUM_TIMEFRAMES RSITimeframe      = PERIOD_CURRENT;  // RSI Timeframe
input int      RSIPeriod                = 14;              // RSI Period
input double   RSIOverboughtLevel       = 70.0;            // RSI Overbought Level

//--- EMA Settings
input group "═══ EMA SETTINGS ═══"
input bool     UseEMA                   = false;           // Use EMA?
input ENUM_TIMEFRAMES EMATimeframe      = PERIOD_M30;      // EMA Timeframe
input int      EMAFast                  = 4;               // EMA Period (Fast)
input int      EMAMid                   = 8;               // EMA Period (Mid)
input int      EMASlow                  = 60;              // EMA Period (Slow)
input ENUM_EMA_TREND_RULE EMATrendRule  = WITH_TREND_ONLY; // EMA Trend Rule
input bool     DoubleCheckEMAFirstRealTrade = false;       // Double Check EMA for first Real Trade

//--- ADX Settings
input group "═══ ADX SETTINGS ═══"
input bool     UseADX                   = false;           // Use ADX?
input ENUM_TIMEFRAMES ADXTimeframe      = PERIOD_M30;      // ADX Timeframe
input int      ADXPeriod                = 14;              // ADX Period
input double   ADXThreshold             = 30.0;            // ADX Threshold
input ENUM_ADX_TREND_RULE ADXTrendRule  = ADX_WITH_TREND_ONLY; // ADX Trend Rule
input bool     DoubleCheckADXFirstRealTrade = false;       // Double Check ADX for first Real Trade

//--- Bollinger Bands Settings
input group "═══ BOLLINGER BANDS SETTINGS ═══"
input bool     UseBollinger             = false;           // Use Bollinger Bands?
input ENUM_BB_MODE BBMode               = BB_AVOID_EXTREME; // Bollinger Bands Mode
input ENUM_TIMEFRAMES BBTimeframe       = PERIOD_M30;      // Bollinger Bands Timeframe
input int      BBPeriod                 = 20;              // Bollinger Bands Period
input double   BBDeviation              = 1.5;             // Bollinger Bands Deviation

//--- News Filter Settings
input group "═══ NEWS FILTER SETTINGS ═══"
input bool     UseHighImpactNews        = true;            // Use High Impact News Filter?
input ENUM_NEWS_ACTION NewsTradesAction = NEWS_COMPLETE_SEQUENCE; // News Trades Action
input int      CloseMinutesBeforeNews   = 60;              // Close Trade (X)Amount of Minutes before news
input int      PauseMinutesAfterNews    = 60;              // Pause EA (X)Amount of Minutes after news


// =====================================================================
// STRUCTS
// =====================================================================

struct SequenceInfo
{
   ENUM_SEQUENCE_STATE State;
   int      Level;
   int      TradeCount;
   double   WeightedAvgPrice;
   double   TotalLots;
   double   LockReferencePrice;
   bool     LockTriggered;
   double   TrailingPrice;
   bool     TrailingActive;
   datetime LastTradeTime;
   datetime SequenceStartTime;
   int      LiveDelayCounter;
   double   LiveDelayAccumLots;
   int      LiveDelayStartLevel;
   int      DepthHistory;
   bool     FirstRealTradeAfterLD;
   bool     LDMultiplierApplied;
   bool     DelaySequenceActive;
   int      DelayVirtualLevel;
   double   DelayAnchorPrice;
   double   DelayWorstPrice;
   datetime DelaySequenceStartTime;
   bool     DelaySignalIsBuy;

   void Reset()
   {
      State               = STATE_IDLE;
      Level               = 0;
      TradeCount          = 0;
      WeightedAvgPrice    = 0.0;
      TotalLots           = 0.0;
      LockReferencePrice  = 0.0;
      LockTriggered       = false;
      TrailingPrice       = 0.0;
      TrailingActive      = false;
      LastTradeTime       = 0;
      SequenceStartTime   = 0;
      LiveDelayCounter    = 0;
      LiveDelayAccumLots  = 0.0;
      LiveDelayStartLevel = 0;
      DepthHistory        = 0;
      FirstRealTradeAfterLD = false;
      LDMultiplierApplied   = false;
      DelaySequenceActive = false;
      DelayVirtualLevel = 0;
      DelayAnchorPrice = 0.0;
      DelayWorstPrice = 0.0;
      DelaySequenceStartTime = 0;
      DelaySignalIsBuy = true;
   }
};

struct IndicatorCache
{
   int hRSI;
   int hEMAFast;
   int hEMAMid;
   int hEMASlow;
   int hADX;
   int hBBands;
   int hATR;

   void Reset()
   {
      hRSI     = INVALID_HANDLE;
      hEMAFast = INVALID_HANDLE;
      hEMAMid  = INVALID_HANDLE;
      hEMASlow = INVALID_HANDLE;
      hADX     = INVALID_HANDLE;
      hBBands  = INVALID_HANDLE;
      hATR     = INVALID_HANDLE;
   }
};

struct OptimizationMetrics
{
   int    TotalSequences;
   int    MaxDepth;
   double AvgDepth;
   double AvgDuration;
   double MaxDD;
   int    RiskStopCount;
   int    DailyTargetHits;
   int    DailyLossHits;

   void Reset()
   {
      TotalSequences = 0;
      MaxDepth       = 0;
      AvgDepth       = 0.0;
      AvgDuration    = 0.0;
      MaxDD          = 0.0;
      RiskStopCount  = 0;
      DailyTargetHits = 0;
      DailyLossHits   = 0;
   }
};

struct SessionWindow
{
   int  StartHour;
   int  StartMinute;
   int  EndHour;
   int  EndMinute;
   bool Active;
};


// =====================================================================
// GLOBAL STATE
// =====================================================================

SequenceInfo      g_seqBuy;
SequenceInfo      g_seqSell;
IndicatorCache    g_indicators;
OptimizationMetrics g_metrics;

datetime  g_lastBarTimeChart  = 0;
datetime  g_lastBarTimeM1     = 0;
bool      g_isNewBarChart     = false;
bool      g_isNewBarM1        = false;
double    g_dailyStartBalance = 0.0;
datetime  g_dailyResetTime    = 0;
bool      g_weekendClosed     = false;

// Distinct hard-stop latches (never collapse — they have different reset rules)
bool      g_lossStopped         = false;  // MaxRunningLoss     — restart per RestartEAAfterLoss
datetime  g_lossStopTime        = 0;
bool      g_dailyTargetStopped  = false;  // DailyProfitTarget  — auto-restart next day
datetime  g_dailyTargetStopTime = 0;
bool      g_ultimateStopped     = false;  // UltimateTargetBalance — permanent
bool      g_globalEquityStopped = false;  // GlobalEquityStop   — reset only via ResetGlobalEquityStop

double    g_globalEquityHigh  = 0.0;
uint      g_randomState       = 0;
bool      g_pendingBuyEntry   = false;
bool      g_pendingSellEntry  = false;
datetime  g_pendingBuyEntryTime = 0;
datetime  g_pendingSellEntryTime = 0;
datetime  g_lastGlobalTradeTime = 0;      // MinSecondsBetweenTrades (per EA instance)
datetime  g_lastNewsCheckTime = 0;
bool      g_newsActiveCache   = false;
int       g_sequenceDurationSum = 0;
int       g_sequenceDepthSum    = 0;
int       g_pipMultiplier       = 1;


// =====================================================================
// MODULE: LOGGER
// =====================================================================

void Log(int level, string message)
{
   if(level <= LogLevel)
      Print("[SRP L", level, "] ", message);
}

void LogDebug(string msg)   { Log(3, msg); }
void LogVerbose(string msg) { Log(2, msg); }
void LogMajor(string msg)   { Log(1, msg); }


// =====================================================================
// MODULE: UTILITY HELPERS
// =====================================================================

uint RandomNext()
{
   g_randomState ^= (g_randomState << 13);
   g_randomState ^= (g_randomState >> 17);
   g_randomState ^= (g_randomState << 5);
   return g_randomState;
}

double PipsToPrice(double pips)
{
   return pips * g_pipMultiplier * _Point;
}

double GetPipValue(double lots)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0) return 0;
   return (g_pipMultiplier * _Point / tickSize) * tickValue * lots;
}

double GetATRValue()
{
   if(g_indicators.hATR == INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(g_indicators.hATR, 0, 0, 1, buf) == 1)
      return buf[0];
   return 0;
}

// Negative pip input = ATR multiplier mode. Positive = raw pips.
double ResolveDistance(double pipInput)
{
   if(pipInput < 0)
   {
      double atr = GetATRValue();
      if(atr == 0) return PipsToPrice(-pipInput);
      return (-pipInput) * atr;
   }
   return PipsToPrice(pipInput);
}

double NormalizeLot(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep == 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 8); // 8 digits: supports 0.001-step symbols
}

bool ParseTime(string timeStr, int &hour, int &minute)
{
   string parts[];
   int count = StringSplit(timeStr, ':', parts);
   if(count < 2) return false;
   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);
   return true;
}

bool ParseSession(string sessionStr, SessionWindow &win)
{
   string parts[];
   int count = StringSplit(sessionStr, '-', parts);
   if(count < 2) { win.Active = false; return false; }
   int sh, sm, eh, em;
   if(!ParseTime(parts[0], sh, sm) || !ParseTime(parts[1], eh, em))
   { win.Active = false; return false; }
   win.StartHour   = sh;
   win.StartMinute = sm;
   win.EndHour     = eh;
   win.EndMinute   = em;
   win.Active      = true;
   return true;
}

int CountPositions(ENUM_POSITION_TYPE posType)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         count++;
   }
   return count;
}

double GetTotalLots(ENUM_POSITION_TYPE posType)
{
   double total = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         total += PositionGetDouble(POSITION_VOLUME);
   }
   return total;
}

double ComputeWeightedAverage(ENUM_POSITION_TYPE posType)
{
   double sumLotPrice = 0, sumLots = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
      {
         double vol   = PositionGetDouble(POSITION_VOLUME);
         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         sumLotPrice += vol * price;
         sumLots     += vol;
      }
   }
   if(sumLots == 0) return 0;
   return sumLotPrice / sumLots;
}

double GetFloatingProfit(ENUM_POSITION_TYPE posType)
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

double GetTotalFloatingProfit()
{
   double profit = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

double GetWorstPrice(ENUM_POSITION_TYPE posType)
{
   double worst = 0;
   bool   first = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
      {
         double price = PositionGetDouble(POSITION_PRICE_OPEN);
         if(first) { worst = price; first = false; }
         else
         {
            if(posType == POSITION_TYPE_BUY)  worst = MathMin(worst, price);
            else                               worst = MathMax(worst, price);
         }
      }
   }
   return worst;
}

bool CloseAllPositions(ENUM_POSITION_TYPE posType)
{
   bool allClosed = true;
   MqlTradeRequest req;
   MqlTradeResult  res;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

      ZeroMemory(req); ZeroMemory(res);
      req.action    = TRADE_ACTION_DEAL;
      req.position  = ticket;
      req.symbol    = _Symbol;
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.type      = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
      req.price     = (posType == POSITION_TYPE_BUY) ?
                      SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                      SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation = 30;
      req.magic     = MagicNumber;
      req.comment   = TradeComment + "_close";

      long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
      if((fillMode & SYMBOL_FILLING_IOC) != 0)
         req.type_filling = ORDER_FILLING_IOC;
      else if((fillMode & SYMBOL_FILLING_FOK) != 0)
         req.type_filling = ORDER_FILLING_FOK;
      else
         req.type_filling = ORDER_FILLING_RETURN;

      if(!OrderSend(req, res))
      {
         Log(1, "Close failed ticket=" + IntegerToString((int)ticket) +
             " err=" + IntegerToString(res.retcode));
         allClosed = false;
      }
   }
   return allClosed;
}

bool CloseAllPositionsBothDirections()
{
   bool a = CloseAllPositions(POSITION_TYPE_BUY);
   bool b = CloseAllPositions(POSITION_TYPE_SELL);
   return a && b;
}


// =====================================================================
// MODULE: GRID ENGINE
// =====================================================================

// Step for grid level N. Negative PipStep triggers ATR mode.
double GridStepDistance(int level)
{
   if(level <= 0) return 0;
   int exponentIndex = (int)MathMax(level - 1, 0);
   double rawStep = MathAbs(PipStep) * MathPow(PipStepExponent, (double)exponentIndex);
   if(MaxPipStep > 0 && rawStep > MaxPipStep)
      rawStep = MaxPipStep;
   // Preserve sign so ResolveDistance knows ATR mode
   double signedStep = (PipStep < 0) ? -rawStep : rawStep;
   return ResolveDistance(signedStep);
}

double CurrentEntryPrice(ENUM_POSITION_TYPE posType)
{
   return (posType == POSITION_TYPE_BUY) ?
          SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
          SymbolInfoDouble(_Symbol, SYMBOL_BID);
}

void StartDelayedVirtualSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq, bool signalIsBuy)
{
   double anchorPrice = CurrentEntryPrice(posType);
   seq.State = STATE_BUILDING;
   seq.Level = 1;
   seq.TradeCount = 0;
   seq.TotalLots = 0.0;
   seq.WeightedAvgPrice = 0.0;
   seq.DelaySequenceActive = true;
   seq.DelayVirtualLevel = 1;
   seq.DelayAnchorPrice = anchorPrice;
   seq.DelayWorstPrice = anchorPrice;
   seq.DelaySequenceStartTime = TimeCurrent();
   seq.DelaySignalIsBuy = signalIsBuy;
   seq.SequenceStartTime = TimeCurrent();
   seq.DepthHistory = 1;

   LogMajor("Seq started (DelayTradeSequence virtual): " +
            (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
            " virtual lvl 1 anchor=" +
            DoubleToString(anchorPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

bool DelayedVirtualStepReached(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(!seq.DelaySequenceActive || seq.DelayVirtualLevel <= 0) return false;

   double currentPrice = CurrentEntryPrice(posType);
   double stepDist = GridStepDistance(seq.DelayVirtualLevel);

   if(posType == POSITION_TYPE_BUY)
      return (seq.DelayWorstPrice - currentPrice) >= stepDist;

   return (currentPrice - seq.DelayWorstPrice) >= stepDist;
}

void AdvanceDelayedVirtualSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   double currentPrice = CurrentEntryPrice(posType);
   seq.DelayVirtualLevel++;
   seq.Level = seq.DelayVirtualLevel;
   seq.DelayWorstPrice = currentPrice;

   if(seq.Level > seq.DepthHistory)
      seq.DepthHistory = seq.Level;

   LogVerbose("DelayTradeSequence virtual advance: " +
              (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
              " virtual lvl=" + IntegerToString(seq.DelayVirtualLevel));
}

void ClearDelayedVirtualSequence(SequenceInfo &seq)
{
   seq.DelaySequenceActive = false;
   seq.DelayVirtualLevel = 0;
   seq.DelayAnchorPrice = 0.0;
   seq.DelayWorstPrice = 0.0;
   seq.DelaySequenceStartTime = 0;
   seq.DelaySignalIsBuy = true;
}

bool StartDelayedVirtualSequenceForSignal(bool signalIsBuy)
{
   bool actualBuy = signalIsBuy;
   if(ReverseSequenceDirection) actualBuy = !actualBuy;

   if(actualBuy)
   {
      if(g_seqBuy.State != STATE_IDLE || CountPositions(POSITION_TYPE_BUY) > 0) return false;
      if(!DirectionAllowedGlobally(POSITION_TYPE_BUY)) return false;
      StartDelayedVirtualSequence(POSITION_TYPE_BUY, g_seqBuy, signalIsBuy);
      return true;
   }

   if(g_seqSell.State != STATE_IDLE || CountPositions(POSITION_TYPE_SELL) > 0) return false;
   if(!DirectionAllowedGlobally(POSITION_TYPE_SELL)) return false;
   StartDelayedVirtualSequence(POSITION_TYPE_SELL, g_seqSell, signalIsBuy);
   return true;
}

bool GridShouldOpenNext(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(seq.Level <= 0) return false;
   double worstPrice = GetWorstPrice(posType);
   if(worstPrice == 0 && LiveDelay > 0 && seq.LiveDelayCounter > 0 && !seq.FirstRealTradeAfterLD)
      worstPrice = seq.DelayWorstPrice;
   if(worstPrice == 0) return false;

   double stepDist    = GridStepDistance(seq.Level);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(posType == POSITION_TYPE_BUY)
      return (worstPrice - currentPrice) >= stepDist;
   else
      return (currentPrice - worstPrice) >= stepDist;
}


// =====================================================================
// MODULE: LOT ENGINE
// =====================================================================

double ComputeBaseLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   if(UseCompounding)
   {
      if(InitialAccountBalanceThreshold <= 0) return NormalizeLot(LotSize);
      double pipVal = GetPipValue(1.0);
      if(pipVal == 0 || RiskInPips == 0) return NormalizeLot(LotSize);
      // Threshold-relative risk lot × CompoundScale(balance/threshold)
      // collapses to a SINGLE balance factor — never multiply balance twice
      double baseLot = (RiskPercentForCompounding / 100.0 * balance) / (RiskInPips * pipVal);
      if(MaxLotSizeForCompounding > 0)
         baseLot = MathMin(baseLot, MaxLotSizeForCompounding);
      return NormalizeLot(baseLot);
   }

   if(RiskPercent > 0 && StopLoss > 0)
   {
      double pipVal = GetPipValue(1.0);
      if(pipVal == 0) return NormalizeLot(LotSize);
      double riskLot = (RiskPercent / 100.0 * balance) / (StopLoss * pipVal);
      if(MaxLotSize > 0) riskLot = MathMin(riskLot, MaxLotSize);
      return NormalizeLot(riskLot);
   }

   return NormalizeLot(LotSize);
}

double ComputeLotForLevel(int level)
{
   double base = ComputeBaseLot();
   double lot  = base * MathPow(LotSizeExponent, (double)level);
   double cap  = UseCompounding ? MaxLotSizeForCompounding : MaxLotSize;
   if(cap > 0) lot = MathMin(lot, cap);
   return NormalizeLot(lot);
}


// =====================================================================
// MODULE: INDICATOR FILTERS
// =====================================================================

bool IndicatorFiltersInit()
{
   g_indicators.Reset();

   g_indicators.hATR = iATR(_Symbol, PERIOD_CURRENT, ATRPeriod);

   if(UseRSI)
      g_indicators.hRSI = iRSI(_Symbol, RSITimeframe, RSIPeriod, PRICE_CLOSE);

   if(UseEMA)
   {
      g_indicators.hEMAFast = iMA(_Symbol, EMATimeframe, EMAFast, 0, MODE_EMA, PRICE_CLOSE);
      g_indicators.hEMAMid  = iMA(_Symbol, EMATimeframe, EMAMid,  0, MODE_EMA, PRICE_CLOSE);
      g_indicators.hEMASlow = iMA(_Symbol, EMATimeframe, EMASlow, 0, MODE_EMA, PRICE_CLOSE);
   }

   if(UseADX)
      g_indicators.hADX = iADX(_Symbol, ADXTimeframe, ADXPeriod);

   if(UseBollinger)
      g_indicators.hBBands = iBands(_Symbol, BBTimeframe, BBPeriod, 0, BBDeviation, PRICE_CLOSE);

   if(UseRSI      && g_indicators.hRSI     == INVALID_HANDLE) { Log(1, "RSI handle failed");    return false; }
   if(UseEMA      && g_indicators.hEMAFast == INVALID_HANDLE) { Log(1, "EMA handle failed");    return false; }
   if(UseADX      && g_indicators.hADX     == INVALID_HANDLE) { Log(1, "ADX handle failed");    return false; }
   if(UseBollinger && g_indicators.hBBands == INVALID_HANDLE) { Log(1, "BB handle failed");     return false; }
   if(g_indicators.hATR == INVALID_HANDLE)                    { Log(1, "ATR handle failed");    return false; }

   return true;
}

void IndicatorFiltersDeInit()
{
   if(g_indicators.hRSI     != INVALID_HANDLE) IndicatorRelease(g_indicators.hRSI);
   if(g_indicators.hEMAFast != INVALID_HANDLE) IndicatorRelease(g_indicators.hEMAFast);
   if(g_indicators.hEMAMid  != INVALID_HANDLE) IndicatorRelease(g_indicators.hEMAMid);
   if(g_indicators.hEMASlow != INVALID_HANDLE) IndicatorRelease(g_indicators.hEMASlow);
   if(g_indicators.hADX     != INVALID_HANDLE) IndicatorRelease(g_indicators.hADX);
   if(g_indicators.hBBands  != INVALID_HANDLE) IndicatorRelease(g_indicators.hBBands);
   if(g_indicators.hATR     != INVALID_HANDLE) IndicatorRelease(g_indicators.hATR);
   g_indicators.Reset();
}

bool FilterRSI(bool isBuy)
{
   if(!UseRSI) return true;
   double buf[1];
   if(CopyBuffer(g_indicators.hRSI, 0, 0, 1, buf) != 1) return true;
   double rsi = buf[0];
   double oversoldLevel = 100.0 - RSIOverboughtLevel;
   if(isBuy)  return (rsi <= oversoldLevel);
   else       return (rsi >= RSIOverboughtLevel);
}

bool FilterEMA(bool isBuy)
{
   if(!UseEMA) return true;
   double fast[1], mid[1], slow[1];
   if(CopyBuffer(g_indicators.hEMAFast, 0, 0, 1, fast) != 1) return true;
   if(CopyBuffer(g_indicators.hEMAMid,  0, 0, 1, mid)  != 1) return true;
   if(CopyBuffer(g_indicators.hEMASlow, 0, 0, 1, slow) != 1) return true;

   bool upTrend   = (fast[0] > mid[0] && mid[0] > slow[0]);
   bool downTrend = (fast[0] < mid[0] && mid[0] < slow[0]);

   if(EMATrendRule == WITH_TREND_ONLY)
   {
      return isBuy ? upTrend : downTrend;
   }
   else // AVOID_OPPOSITE_TREND
   {
      return isBuy ? !downTrend : !upTrend;
   }
}

bool FilterADX(bool isBuy)
{
   if(!UseADX) return true;
   double adxMain[1], adxPlus[1], adxMinus[1];
   if(CopyBuffer(g_indicators.hADX, 0, 0, 1, adxMain)  != 1) return true;
   if(CopyBuffer(g_indicators.hADX, 1, 0, 1, adxPlus)  != 1) return true;
   if(CopyBuffer(g_indicators.hADX, 2, 0, 1, adxMinus) != 1) return true;

   bool trending  = (adxMain[0] >= ADXThreshold);
   bool bullTrend = (adxPlus[0] > adxMinus[0]);
   bool bearTrend = (adxMinus[0] > adxPlus[0]);

   if(ADXTrendRule == ADX_WITH_TREND_ONLY)
   {
      // No trades in flat market; with-trend only when trending
      if(!trending) return false;
      return isBuy ? bullTrend : bearTrend;
   }

   // ADX_AVOID_OPPOSITE_TREND (product: "trades when the ADX is below the
   // threshold (ranging)"; when trending, with-trend only)
   if(!trending) return true;
   return isBuy ? bullTrend : bearTrend;
}

bool FilterBollinger(bool isBuy)
{
   if(!UseBollinger) return true;
   double upper[1], lower[1], middle[1];
   if(CopyBuffer(g_indicators.hBBands, 1, 0, 1, upper)  != 1) return true;
   if(CopyBuffer(g_indicators.hBBands, 2, 0, 1, lower)  != 1) return true;
   if(CopyBuffer(g_indicators.hBBands, 0, 0, 1, middle) != 1) return true;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(BBMode == BB_AVOID_EXTREME)
   {
      if(isBuy  && ask >= upper[0]) return false;
      if(!isBuy && bid <= lower[0]) return false;
      return true;
   }
   else // BB_ONLY_EXTREME_COUNTER_TREND
   {
      if(isBuy  && bid <= lower[0]) return true;
      if(!isBuy && ask >= upper[0]) return true;
      return false;
   }
}

bool AllFiltersPass(bool isBuy)
{
   if(!FilterRSI(isBuy))       return false;
   if(!FilterEMA(isBuy))       return false;
   if(!FilterADX(isBuy))       return false;
   if(!FilterBollinger(isBuy)) return false;
   return true;
}

bool DoubleCheckFilters(bool isBuy)
{
   bool pass = true;
   if(DoubleCheckEMAFirstRealTrade && UseEMA) pass = pass && FilterEMA(isBuy);
   if(DoubleCheckADXFirstRealTrade && UseADX) pass = pass && FilterADX(isBuy);
   return pass;
}


// =====================================================================
// MODULE: SESSION MANAGER
// =====================================================================

bool IsInSession()
{
   if(!TradeCustomTimes) return true;

   MqlDateTime dt;
   TimeCurrent(dt);

   string sessionStr = "";
   switch(dt.day_of_week)
   {
      case 1: sessionStr = TradingSessionMonday;    break;
      case 2: sessionStr = TradingSessionTuesday;   break;
      case 3: sessionStr = TradingSessionWednesday; break;
      case 4: sessionStr = TradingSessionThursday;  break;
      case 5: sessionStr = TradingSessionFriday;    break;
      default: return false; // Sat/Sun
   }

   if(sessionStr == "0" || sessionStr == "") return false; // day disabled

   SessionWindow win;
   if(!ParseSession(sessionStr, win) || !win.Active) return false;

   int nowMin   = dt.hour * 60 + dt.min;
   int startMin = win.StartHour * 60 + win.StartMinute;
   int endMin   = win.EndHour * 60 + win.EndMinute;

   if(startMin <= endMin)
      return (nowMin >= startMin && nowMin <= endMin);
   else // overnight
      return (nowMin >= startMin || nowMin <= endMin);
}

int MinutesOfWeek(int dayOfWeek, int hour, int minute)
{
   return dayOfWeek * 1440 + hour * 60 + minute;
}

// True while inside the weekend-closure window: from DayToClose/TimeToClose
// to DayToRestart/TimeToRestart, wrapping through the weekend.
bool InWeekendClosure()
{
   if(!CloseForWeekend) return false;
   int closeH, closeM, restH, restM;
   if(!ParseTime(TimeToClose,   closeH, closeM)) return false;
   if(!ParseTime(TimeToRestart, restH,  restM))  return false;

   MqlDateTime dt;
   TimeCurrent(dt);
   int nowMin   = MinutesOfWeek(dt.day_of_week, dt.hour, dt.min);
   int closeMin = MinutesOfWeek((int)DayToClose,   closeH, closeM);
   int restMin  = MinutesOfWeek((int)DayToRestart, restH,  restM);

   if(closeMin == restMin) return false;
   if(closeMin < restMin)  return (nowMin >= closeMin && nowMin < restMin);
   return (nowMin >= closeMin || nowMin < restMin); // window wraps Sat/Sun
}

// New-bar events are computed ONCE per tick (UpdateBarFlags) so that BUY/SELL
// and lock/trailing checks all observe the same event — a destructive
// "first caller consumes the bar" pattern broke bar-close modes before.
void UpdateBarFlags()
{
   datetime chartBar = iTime(_Symbol, PERIOD_CURRENT, 0);
   g_isNewBarChart = (chartBar != g_lastBarTimeChart);
   if(g_isNewBarChart) g_lastBarTimeChart = chartBar;

   datetime m1Bar = iTime(_Symbol, PERIOD_M1, 0);
   g_isNewBarM1 = (m1Bar != g_lastBarTimeM1);
   if(g_isNewBarM1) g_lastBarTimeM1 = m1Bar;
}

bool IsBarCloseCheck(ENUM_LOCK_CHECK_MODE mode)
{
   if(mode == EVERY_TICK)      return true;
   if(mode == BAR_CLOSE_CHART) return g_isNewBarChart;
   return g_isNewBarM1; // BAR_CLOSE_M1
}


// =====================================================================
// MODULE: NEWS MANAGER
// =====================================================================

bool IsHighImpactNewsNow()
{
   if(!UseHighImpactNews) return false;

   datetime now = TimeCurrent();

   // Throttle: calendar queries are expensive; 30s cache is far finer than
   // the minutes-scale news windows and remains deterministic per tick stream
   if(g_lastNewsCheckTime != 0 && (now - g_lastNewsCheckTime) < 30)
      return g_newsActiveCache;
   g_lastNewsCheckTime = now;
   g_newsActiveCache   = false;

   // Block when an event falls in [now - PauseAfter, now + CloseBefore]:
   // i.e. it is at most CloseMinutesBeforeNews ahead, or at most
   // PauseMinutesAfterNews behind
   datetime from = now - (datetime)(PauseMinutesAfterNews  * 60);
   datetime to   = now + (datetime)(CloseMinutesBeforeNews * 60);

   MqlCalendarValue values[];
   string currency  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string currency2 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   if(!CalendarValueHistory(values, from, to, NULL, NULL))
   {
      // Calendar unavailable (Strategy Tester, disabled terminal feed, or
      // broker without calendar): fail open as "no news", but say so
      Log(2, "News calendar query failed err=" + IntegerToString(GetLastError()) +
          " — treating as no news");
      return false;
   }

   int count = ArraySize(values);
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent   event;
      MqlCalendarCountry country;
      if(!CalendarEventById(values[i].event_id, event))   continue;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         if(country.currency == currency || country.currency == currency2)
         {
            g_newsActiveCache = true;
            return true;
         }
      }
   }
   return false;
}


// =====================================================================
// MODULE: EQUITY GUARD
// =====================================================================

bool DailyProfitTargetReached()
{
   if(DailyProfitTarget <= 0) return false;
   double dayProfit = (AccountInfoDouble(ACCOUNT_BALANCE) - g_dailyStartBalance)
                      + GetTotalFloatingProfit();
   return (dayProfit >= DailyProfitTarget);
}

bool UltimateTargetReached()
{
   if(UltimateTargetBalance <= 0) return false;
   return (AccountInfoDouble(ACCOUNT_EQUITY) >= UltimateTargetBalance);
}

bool MaxRunningLossExceeded()
{
   if(MaxRunningLoss <= 0) return false;
   double limit = MaxRunningLoss;
   // Product: with compounding, Max Running Loss is per threshold → scale it
   if(UseCompounding && InitialAccountBalanceThreshold > 0)
      limit *= AccountInfoDouble(ACCOUNT_BALANCE) / InitialAccountBalanceThreshold;
   return (GetTotalFloatingProfit() <= -limit);
}

bool GlobalEquityStopTriggered()
{
   if(GlobalEquityStopValue <= 0) return false;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   switch(GlobalEquityStopType)
   {
      case EQUITY_ABSOLUTE:
         return (equity <= GlobalEquityStopValue);
      case EQUITY_RISKED_AMOUNT:
         return ((balance - equity) >= GlobalEquityStopValue);
      case EQUITY_RISKED_PERCENT:
      {
         if(balance == 0) return false;
         double pctLoss = ((balance - equity) / balance) * 100.0;
         return (pctLoss >= GlobalEquityStopValue);
      }
   }
   return false;
}

bool TradingHardStopped()
{
   return g_lossStopped || g_dailyTargetStopped || g_ultimateStopped || g_globalEquityStopped;
}

// Each stop condition latches its OWN flag — they have different reset rules:
//   MaxRunningLoss     → restart per RestartEAAfterLoss
//   DailyProfitTarget  → auto-restart next day at RestartNextDayAt
//   UltimateTarget     → permanent (mission complete)
//   GlobalEquityStop   → permanent unless ResetGlobalEquityStop
bool EquityGuardCheck()
{
   if(TradingHardStopped()) return true;

   string reason = "";
   bool   isLossStop = false;

   if(DailyProfitTargetReached())
   {
      reason = "Daily profit target reached";
      g_dailyTargetStopped  = true;
      g_dailyTargetStopTime = TimeCurrent();
      g_metrics.DailyTargetHits++;
   }
   else if(UltimateTargetReached())
   {
      reason = "Ultimate target balance reached — permanent shutdown";
      g_ultimateStopped = true;
   }
   else if(MaxRunningLossExceeded())
   {
      reason = "Max running loss exceeded";
      g_lossStopped  = true;
      g_lossStopTime = TimeCurrent();
      isLossStop     = true;
      g_metrics.DailyLossHits++;
   }
   else if(GlobalEquityStopTriggered())
   {
      reason = "Global equity stop triggered";
      g_globalEquityStopped = true;
      g_metrics.RiskStopCount++; // hard-stop disqualifier for OnTester
   }

   if(reason != "")
   {
      LogMajor("EQUITY GUARD: " + reason);
      CloseAllPositionsBothDirections();
      CancelAllPendingRandomEntries("equity_guard_triggered");
      g_seqBuy.Reset();
      g_seqSell.Reset();
      g_seqBuy.State  = isLossStop ? STATE_STOPPED_BY_LOSS : STATE_STOPPED_BY_EQUITY;
      g_seqSell.State = isLossStop ? STATE_STOPPED_BY_LOSS : STATE_STOPPED_BY_EQUITY;
      return true;
   }
   return false;
}

// Shared "next calendar day at HH:MM" restart test
bool NextDayRestartReached(datetime stopTime, string restartAt)
{
   MqlDateTime dtNow, dtStop;
   TimeToStruct(TimeCurrent(), dtNow);
   TimeToStruct(stopTime, dtStop);
   if(dtNow.year == dtStop.year && dtNow.mon == dtStop.mon && dtNow.day == dtStop.day)
      return false;
   int restH, restM;
   if(!ParseTime(restartAt, restH, restM)) return false;
   return (dtNow.hour > restH || (dtNow.hour == restH && dtNow.min >= restM));
}

bool CanRestartAfterLoss()
{
   if(!g_lossStopped) return false;

   if(RestartEAAfterLoss == RESTART_NEXT_DAY)
      return NextDayRestartReached(g_lossStopTime, RestartNextDayAt);

   // RESTART_AFTER_HOURS
   double hoursPassed = (double)(TimeCurrent() - g_lossStopTime) / 3600.0;
   return (hoursPassed >= RestartAfterHours);
}

// Release sequences out of STOPPED state once no hard stop remains latched
void ReleaseStoppedSequences()
{
   if(TradingHardStopped()) return;
   if(g_seqBuy.State == STATE_STOPPED_BY_EQUITY || g_seqBuy.State == STATE_STOPPED_BY_LOSS)
      g_seqBuy.Reset();
   if(g_seqSell.State == STATE_STOPPED_BY_EQUITY || g_seqSell.State == STATE_STOPPED_BY_LOSS)
      g_seqSell.Reset();
}

void CheckDailyReset()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   datetime dayStart = StringToTime(IntegerToString(dt.year) + "." +
                       IntegerToString(dt.mon) + "." +
                       IntegerToString(dt.day));

   if(dayStart > g_dailyResetTime)
   {
      g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_dailyResetTime    = dayStart;

      if(ResetGlobalEquityStop && g_globalEquityStopped)
      {
         g_globalEquityStopped = false;
         LogMajor("Global equity stop reset for new day");
         ReleaseStoppedSequences();
      }
   }

   // Daily profit target stop auto-clears the next day at RestartNextDayAt
   if(g_dailyTargetStopped && NextDayRestartReached(g_dailyTargetStopTime, RestartNextDayAt))
   {
      g_dailyTargetStopped = false;
      LogMajor("Daily profit target stop cleared — new trading day");
      ReleaseStoppedSequences();
   }
}


// =====================================================================
// MODULE: RISK MANAGER
// =====================================================================

void ApplyStopLoss(ulong ticket, ENUM_POSITION_TYPE posType)
{
   if(StopLoss <= 0) return;
   double slDist = ResolveDistance(StopLoss);
   if(slDist == 0) return;
   if(!PositionSelectByTicket(ticket)) return;

   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double slPrice   = (posType == POSITION_TYPE_BUY) ?
                      openPrice - slDist : openPrice + slDist;
   slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   if(MathAbs(currentSL - slPrice) < _Point) return;

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req); ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = slPrice;
   req.tp       = 0;

   if(!OrderSend(req, res))
      Log(2, "SL modify failed ticket=" + IntegerToString((int)ticket) +
          " err=" + IntegerToString(res.retcode));
}

// Prop-firm rule: minimum gap between ANY two orders of this EA instance
// (not per direction — two directions 1s apart would still violate the rule)
bool MinTimeBetweenTradesOK()
{
   if(MinSecondsBetweenTrades <= 0) return true;
   if(g_lastGlobalTradeTime == 0) return true;
   return ((int)(TimeCurrent() - g_lastGlobalTradeTime) >= MinSecondsBetweenTrades);
}

bool DirectionAllowedGlobally(ENUM_POSITION_TYPE posType)
{
   if(AllowSamePairDirectionTrades) return true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         return false;
   }
   return true;
}


// =====================================================================
// MODULE: ENTRY ENGINE
// =====================================================================

ulong SendMarketOrder(ENUM_POSITION_TYPE posType, double lots, string comment)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req); ZeroMemory(res);

   req.action    = TRADE_ACTION_DEAL;
   req.symbol    = _Symbol;
   req.volume    = NormalizeLot(lots);
   req.type      = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price     = (posType == POSITION_TYPE_BUY) ?
                   SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                   SymbolInfoDouble(_Symbol, SYMBOL_BID);
   req.deviation = 30;
   req.magic     = MagicNumber;
   req.comment   = comment;

   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_IOC) != 0)
      req.type_filling = ORDER_FILLING_IOC;
   else if((fillMode & SYMBOL_FILLING_FOK) != 0)
      req.type_filling = ORDER_FILLING_FOK;
   else
      req.type_filling = ORDER_FILLING_RETURN;

   if(!OrderSend(req, res))
   {
      Log(1, "Order failed: " + comment + " err=" + IntegerToString(res.retcode));
      return 0;
   }

   g_lastGlobalTradeTime = TimeCurrent();
   Log(1, "Order placed: " + comment + " deal=" + IntegerToString((int)res.deal) +
       " lots=" + DoubleToString(lots, 2));
   return res.deal;
}

void ApplyStopLossToLatest(ENUM_POSITION_TYPE posType)
{
   if(StopLoss <= 0) return;
   datetime latest      = 0;
   ulong    latestTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;
      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > latest) { latest = openTime; latestTicket = ticket; }
   }
   if(latestTicket > 0) ApplyStopLoss(latestTicket, posType);
}

bool IsEntrySignalValid(bool isBuy)
{
   return AllFiltersPass(isBuy);
}

string DirectionLabel(bool isBuy)
{
   return isBuy ? "BUY" : "SELL";
}

int GetRandomDelaySeconds()
{
   if(RandomEntryDelayMinSeconds == RandomEntryDelayMaxSeconds)
      return RandomEntryDelayMinSeconds;

   int range = RandomEntryDelayMaxSeconds - RandomEntryDelayMinSeconds + 1;
   return RandomEntryDelayMinSeconds + (int)(RandomNext() % (uint)range);
}

bool HasPendingRandomEntry(bool isBuy)
{
   return isBuy ? g_pendingBuyEntry : g_pendingSellEntry;
}

datetime PendingRandomEntryTime(bool isBuy)
{
   return isBuy ? g_pendingBuyEntryTime : g_pendingSellEntryTime;
}

void ScheduleRandomEntry(bool isBuy)
{
   if(HasPendingRandomEntry(isBuy)) return;

   int delaySeconds = GetRandomDelaySeconds();
   datetime executeTime = TimeCurrent() + delaySeconds;

   if(isBuy)
   {
      g_pendingBuyEntry = true;
      g_pendingBuyEntryTime = executeTime;
   }
   else
   {
      g_pendingSellEntry = true;
      g_pendingSellEntryTime = executeTime;
   }

   LogMajor("Random entry delay scheduled: " + DirectionLabel(isBuy) +
            " executes at " + TimeToString(executeTime, TIME_DATE|TIME_SECONDS) +
            " after " + IntegerToString(delaySeconds) + " seconds");
}

void CancelPendingRandomEntry(bool isBuy, string reason)
{
   if(!HasPendingRandomEntry(isBuy)) return;

   if(isBuy)
   {
      g_pendingBuyEntry = false;
      g_pendingBuyEntryTime = 0;
   }
   else
   {
      g_pendingSellEntry = false;
      g_pendingSellEntryTime = 0;
   }

   LogVerbose("Random entry delay cancelled: " + DirectionLabel(isBuy) +
              " reason=" + reason);
}

void CancelAllPendingRandomEntries(string reason)
{
   CancelPendingRandomEntry(true, reason);
   CancelPendingRandomEntry(false, reason);
}

bool ProcessPendingRandomEntry(bool isBuy)
{
   if(!HasPendingRandomEntry(isBuy)) return false;

   datetime executeTime = PendingRandomEntryTime(isBuy);
   if(TimeCurrent() < executeTime)
   {
      LogDebug("Random entry delay pending: " + DirectionLabel(isBuy) +
               " executes at " + TimeToString(executeTime, TIME_DATE|TIME_SECONDS));
      return true;
   }

   ENUM_SEQUENCE_STATE seqState = isBuy ? g_seqBuy.State : g_seqSell.State;
   if(seqState != STATE_IDLE)
   {
      CancelPendingRandomEntry(isBuy, "sequence_not_idle");
      return true;
   }

   if(!AllowNewSequence)
   {
      CancelPendingRandomEntry(isBuy, "new_sequences_disabled");
      return true;
   }

   if(TradingHardStopped() || g_weekendClosed)
   {
      CancelPendingRandomEntry(isBuy, "risk_or_global_stop_active");
      return true;
   }

   if(TradeCustomTimes && !IsInSession())
   {
      CancelPendingRandomEntry(isBuy, "outside_session");
      return true;
   }

   if(UseHighImpactNews && IsHighImpactNewsNow())
   {
      CancelPendingRandomEntry(isBuy, "news_filter_active");
      return true;
   }

   if(!IsEntrySignalValid(isBuy))
   {
      CancelPendingRandomEntry(isBuy, "entry_filters_no_longer_valid");
      return true;
   }

   CancelPendingRandomEntry(isBuy, "executing");

   // Product order: random entry delay FIRST, then DelayTradeSequence.
   // The virtual sequence is anchored only now, after the delay elapsed
   // and filters re-validated.
   if(DelayTradeSequence > 0)
   {
      if(StartDelayedVirtualSequenceForSignal(isBuy))
         LogMajor("Random delayed entry → virtual sequence started: " + DirectionLabel(isBuy));
      else
         LogVerbose("Random delayed entry: virtual sequence blocked: " + DirectionLabel(isBuy));
      return true;
   }

   bool opened = OpenFirstTrade(isBuy);
   if(opened)
      LogMajor("Random delayed entry executed: " + DirectionLabel(isBuy));
   else
      LogVerbose("Random delayed entry failed to open: " + DirectionLabel(isBuy));

   return true;
}


// =====================================================================
// MODULE: EXIT ENGINE
// =====================================================================

bool CheckSequenceTP(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(TakeProfit <= 0) return false;
   if(seq.TradeCount <= 0) return false;

   double avgPrice = ComputeWeightedAverage(posType);
   if(avgPrice == 0) return false;

   double tpDist = ResolveDistance(TakeProfit);

   if(posType == POSITION_TYPE_BUY)
      return ((SymbolInfoDouble(_Symbol, SYMBOL_BID) - avgPrice) >= tpDist);
   else
      return ((avgPrice - SymbolInfoDouble(_Symbol, SYMBOL_ASK)) >= tpDist);
}

void CheckLockProfit(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(LockProfit <= 0) return;
   if(seq.LockTriggered) return;
   if(seq.TradeCount < LockProfitMinTrades) return;

   double avgPrice = ComputeWeightedAverage(posType);
   if(avgPrice == 0) return;

   double lockDist = ResolveDistance(LockProfit);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitDist = (posType == POSITION_TYPE_BUY) ?
                       (currentPrice - avgPrice) : (avgPrice - currentPrice);

   if(profitDist >= lockDist)
   {
      seq.LockTriggered      = true;
      seq.LockReferencePrice = currentPrice;
      seq.TrailingPrice      = currentPrice;
      seq.TrailingActive     = true;
      seq.State              = STATE_LOCKED;
      LogMajor("Lock profit triggered " +
               (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
               " ref=" + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
   }
}

bool CheckTrailingStop(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(TrailingStop <= 0) return false;
   if(!seq.LockTriggered || !seq.TrailingActive) return false;

   double trailDist    = ResolveDistance(TrailingStop);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_BID) :
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(posType == POSITION_TYPE_BUY)
   {
      if(currentPrice > seq.TrailingPrice)
      {
         seq.TrailingPrice = currentPrice;
         LogDebug("Trail updated BUY: " + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      }
      if((seq.TrailingPrice - currentPrice) >= trailDist)
      {
         LogMajor("Trailing stop hit BUY: trail=" +
                  DoubleToString(seq.TrailingPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
                  " now=" + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
         return true;
      }
   }
   else
   {
      if(currentPrice < seq.TrailingPrice)
      {
         seq.TrailingPrice = currentPrice;
         LogDebug("Trail updated SELL: " + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      }
      if((currentPrice - seq.TrailingPrice) >= trailDist)
      {
         LogMajor("Trailing stop hit SELL: trail=" +
                  DoubleToString(seq.TrailingPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)) +
                  " now=" + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
         return true;
      }
   }
   return false;
}


// =====================================================================
// MODULE: SEQUENCE MANAGER
// =====================================================================

// Single place where a finished sequence updates optimization metrics
// (previously duplicated in three call sites, and MaxDepth was missed in two)
void FinalizeSequenceMetrics(SequenceInfo &seq)
{
   g_metrics.TotalSequences++;
   if(seq.DepthHistory > g_metrics.MaxDepth)
      g_metrics.MaxDepth = seq.DepthHistory;
   g_sequenceDepthSum += seq.DepthHistory;
   if(seq.SequenceStartTime > 0)
      g_sequenceDurationSum += (int)(TimeCurrent() - seq.SequenceStartTime);
   g_metrics.AvgDepth    = (double)g_sequenceDepthSum / g_metrics.TotalSequences;
   g_metrics.AvgDuration = (double)g_sequenceDurationSum / g_metrics.TotalSequences;
}

// A virtual/delayed phase (DelayTradeSequence levels, or LiveDelay
// accumulation) holds ZERO real positions. It must never convert into real
// exposure while new risk is blocked (news/session/weekend), so cancel it.
void CancelFlatVirtualSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq, string reason)
{
   bool virtualPhase = seq.DelaySequenceActive ||
                       (LiveDelay > 0 && seq.LiveDelayCounter > 0 && seq.TradeCount == 0);
   if(!virtualPhase) return;
   if(CountPositions(posType) > 0) return;
   LogVerbose("Virtual sequence cancelled: " + reason);
   seq.Reset();
}

void CancelFlatVirtualSequences(string reason)
{
   CancelFlatVirtualSequence(POSITION_TYPE_BUY,  g_seqBuy,  reason);
   CancelFlatVirtualSequence(POSITION_TYPE_SELL, g_seqSell, reason);
}

void ReconstructSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   seq.Reset();
   int count = CountPositions(posType);
   if(count == 0) { seq.State = STATE_IDLE; return; }

   seq.TradeCount       = count;
   seq.Level            = count;
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots        = GetTotalLots(posType);
   seq.State            = STATE_BUILDING;
   seq.DepthHistory     = count;

   datetime earliest = D'2099.01.01';
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
      {
         datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
         if(openTime < earliest) earliest = openTime;
         if(openTime > seq.LastTradeTime) seq.LastTradeTime = openTime;
      }
   }
   seq.SequenceStartTime = earliest;

   LogMajor("Reconstructed " + (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
            " seq: " + IntegerToString(count) + " trades avg=" +
            DoubleToString(seq.WeightedAvgPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

bool OpenFirstTradeImpl(ENUM_POSITION_TYPE posType, SequenceInfo &seq, bool actualBuy)
{
   int firstRealLevel = seq.DelaySequenceActive ? seq.DelayVirtualLevel : 0;
   datetime sequenceStart = seq.DelaySequenceActive ? seq.DelaySequenceStartTime : TimeCurrent();
   int startingDepth = seq.DelaySequenceActive ? seq.DepthHistory : 0;

   if(LiveDelay > 0)
   {
      double liveDelayAnchor = CurrentEntryPrice(posType);
      seq.LiveDelayCounter   = 1;
      seq.LiveDelayAccumLots = ComputeLotForLevel(firstRealLevel);
      seq.LiveDelayStartLevel = firstRealLevel;
      seq.State              = STATE_BUILDING;
      seq.Level              = firstRealLevel + 1;
      seq.SequenceStartTime  = sequenceStart;
      seq.FirstRealTradeAfterLD = false;
      seq.DepthHistory       = (int)MathMax(startingDepth, seq.Level);
      ClearDelayedVirtualSequence(seq);
      seq.DelayWorstPrice    = liveDelayAnchor;
      LogMajor("Seq started (LiveDelay): " + (actualBuy ? "BUY" : "SELL") +
               " delay lvl " + IntegerToString(firstRealLevel + 1));
      return true;
   }

   if(!MinTimeBetweenTradesOK()) return false;

   double lot     = ComputeLotForLevel(firstRealLevel);
   string comment = TradeComment + (actualBuy ? "_B" : "_S") + "_L" + IntegerToString(firstRealLevel);
   ulong  ticket  = SendMarketOrder(posType, lot, comment);
   if(ticket == 0) return false;

   ApplyStopLossToLatest(posType);

   seq.State            = STATE_BUILDING;
   seq.Level            = firstRealLevel + 1;
   seq.TradeCount       = 1;
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots        = lot;
   seq.LastTradeTime    = TimeCurrent();
   seq.SequenceStartTime = sequenceStart;
   seq.DepthHistory     = (int)MathMax(startingDepth, seq.Level);
   ClearDelayedVirtualSequence(seq);

   LogMajor("New seq: " + (actualBuy ? "BUY" : "SELL") + " lots=" + DoubleToString(lot, 2));
   return true;
}

bool OpenFirstTrade(bool isBuy)
{
   if(TradeDirection == LONG_ONLY  && !isBuy) return false;
   if(TradeDirection == SHORT_ONLY && isBuy)  return false;

   bool actualBuy = isBuy;
   if(ReverseSequenceDirection) actualBuy = !actualBuy;
   ENUM_POSITION_TYPE posType = actualBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(CountPositions(posType) >= MaxOrdersPerDirection) return false;
   if(!DirectionAllowedGlobally(posType)) return false;

   if(actualBuy)
      return OpenFirstTradeImpl(posType, g_seqBuy,  actualBuy);
   else
      return OpenFirstTradeImpl(posType, g_seqSell, actualBuy);
}

bool OpenGridTrade(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(seq.State != STATE_BUILDING) return false;

   bool isBuy = (posType == POSITION_TYPE_BUY);

   // LiveDelay accumulation phase — virtual: no order is placed, so neither
   // MaxOrders (counts real orders) nor MinSecondsBetweenTrades applies here
   if(LiveDelay > 0 && seq.LiveDelayCounter < LiveDelay)
   {
      double lot = ComputeLotForLevel(seq.Level);
      seq.LiveDelayAccumLots += lot;
      seq.LiveDelayCounter++;
      seq.Level++;
      seq.DelayWorstPrice = CurrentEntryPrice(posType);
      if(seq.Level > seq.DepthHistory) seq.DepthHistory = seq.Level;
      LogVerbose("LD accumulate lvl=" + IntegerToString(seq.Level) +
                 " accum=" + DoubleToString(seq.LiveDelayAccumLots, 2));
      return true;
   }

   // From here on real orders are placed.
   // MaxOrders bounds REAL open positions (virtual levels are not orders)
   if(CountPositions(posType) >= MaxOrdersPerDirection) return false;
   if(!MinTimeBetweenTradesOK()) return false;

   // LiveDelay burst point
   if(LiveDelay > 0 && seq.LiveDelayCounter == LiveDelay && !seq.FirstRealTradeAfterLD)
   {
      if(!DoubleCheckFilters(isBuy)) { LogVerbose("LD double-check failed"); return false; }

      if(CombineLiveDelayTrades)
      {
         double totalLots = seq.LiveDelayAccumLots + ComputeLotForLevel(seq.Level);
         string comment   = TradeComment + (isBuy ? "_B" : "_S") + "_LD_combined";
         ulong  ticket    = SendMarketOrder(posType, totalLots, comment);
         if(ticket == 0) return false;
         ApplyStopLossToLatest(posType);
      }
      else
      {
         for(int lvl = seq.LiveDelayStartLevel; lvl <= seq.Level; lvl++)
         {
            if(CountPositions(posType) >= MaxOrdersPerDirection) break;
            double lvlLot  = ComputeLotForLevel(lvl);
            string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(lvl);
            ulong  ticket  = SendMarketOrder(posType, lvlLot, comment);
            if(ticket > 0) { ApplyStopLossToLatest(posType); }
         }
      }

      seq.FirstRealTradeAfterLD = true;
      seq.TradeCount       = CountPositions(posType);
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots        = GetTotalLots(posType);
      seq.LastTradeTime    = TimeCurrent();
      seq.Level++;
      seq.DelayWorstPrice  = 0.0;
      LogMajor("LD burst: " + (isBuy ? "BUY" : "SELL") + " trades=" + IntegerToString(seq.TradeCount));
      return true;
   }

   // Post-LD multiplier phase
   if(LiveDelay > 0 && seq.FirstRealTradeAfterLD && !seq.LDMultiplierApplied)
   {
      double lot = ComputeLotForLevel(seq.Level);
      if(LotMultiplierFirstTradeAfterLD != 1.0)
      {
         lot = NormalizeLot(lot * LotMultiplierFirstTradeAfterLD);
         if(MaxLotSize > 0) lot = MathMin(lot, MaxLotSize);
         LogVerbose("LD multiplier: " + DoubleToString(lot, 2));
      }
      string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(seq.Level);
      ulong  ticket  = SendMarketOrder(posType, lot, comment);
      if(ticket == 0) return false;
      ApplyStopLossToLatest(posType);
      seq.LDMultiplierApplied  = true;
      seq.FirstRealTradeAfterLD = false;
      seq.TradeCount       = CountPositions(posType);
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots        = GetTotalLots(posType);
      seq.LastTradeTime    = TimeCurrent();
      seq.Level++;
      if(seq.Level > seq.DepthHistory) seq.DepthHistory = seq.Level;
      return true;
   }

   // Normal grid trade
   double lot     = ComputeLotForLevel(seq.Level);
   string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(seq.Level);
   ulong  ticket  = SendMarketOrder(posType, lot, comment);
   if(ticket == 0) return false;
   ApplyStopLossToLatest(posType);

   seq.TradeCount       = CountPositions(posType);
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots        = GetTotalLots(posType);
   seq.LastTradeTime    = TimeCurrent();
   seq.Level++;
   if(seq.Level > seq.DepthHistory) seq.DepthHistory = seq.Level;

   LogVerbose("Grid trade: " + (isBuy ? "BUY" : "SELL") +
              " lvl=" + IntegerToString(seq.Level) +
              " lots=" + DoubleToString(lot, 2));
   return true;
}

void CloseSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq, string reason)
{
   LogMajor("Closing " + (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
            " reason=" + reason + " depth=" + IntegerToString(seq.Level) +
            " trades=" + IntegerToString(seq.TradeCount));

   CloseAllPositions(posType);

   FinalizeSequenceMetrics(seq);

   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = balance - equity;
   if(dd > g_metrics.MaxDD) g_metrics.MaxDD = dd;

   seq.Reset();
}


// =====================================================================
// MODULE: MAIN STATE MACHINE
// =====================================================================

void ProcessSequenceImpl(ENUM_POSITION_TYPE posType, SequenceInfo &seq, bool isBuyDirection)
{
   int actualCount = CountPositions(posType);

   if(seq.State != STATE_IDLE && HasPendingRandomEntry(isBuyDirection))
      CancelPendingRandomEntry(isBuyDirection, "sequence_no_longer_idle");

   // === IDLE ===
   if(seq.State == STATE_IDLE)
   {
      if(!AllowNewSequence)
      {
         CancelPendingRandomEntry(isBuyDirection, "new_sequences_disabled");
         return;
      }
      if(actualCount > 0)
      {
         CancelPendingRandomEntry(isBuyDirection, "sequence_opened_elsewhere");
         ReconstructSequence(posType, seq);
         return;
      }
      if(TradeDirection == LONG_ONLY  && !isBuyDirection)
      {
         CancelPendingRandomEntry(isBuyDirection, "direction_disabled");
         return;
      }
      if(TradeDirection == SHORT_ONLY && isBuyDirection)
      {
         CancelPendingRandomEntry(isBuyDirection, "direction_disabled");
         return;
      }

      if(UseRandomEntryDelay)
      {
         if(HasPendingRandomEntry(isBuyDirection))
         {
            ProcessPendingRandomEntry(isBuyDirection);
            return;
         }

         // Random delay always runs FIRST; ProcessPendingRandomEntry routes
         // to the DelayTradeSequence virtual path after the delay elapses
         if(IsEntrySignalValid(isBuyDirection))
         {
            LogVerbose("Random entry signal detected: " + DirectionLabel(isBuyDirection));
            ScheduleRandomEntry(isBuyDirection);
         }
         return;
      }

      if(IsEntrySignalValid(isBuyDirection))
      {
         if(DelayTradeSequence > 0)
         {
            StartDelayedVirtualSequenceForSignal(isBuyDirection);
            return;
         }

         OpenFirstTrade(isBuyDirection);
      }
      return;
   }

   // === BUILDING ===
   if(seq.State == STATE_BUILDING)
   {
      if(seq.DelaySequenceActive)
      {
         if(!AllowNewSequence)
         {
            LogVerbose("DelayTradeSequence cancelled: new_sequences_disabled");
            seq.Reset();
            return;
         }

         if(actualCount > 0)
         {
            ClearDelayedVirtualSequence(seq);
            ReconstructSequence(posType, seq);
            return;
         }

         if(!DelayedVirtualStepReached(posType, seq))
            return;

         if(seq.DelayVirtualLevel < DelayTradeSequence)
         {
            AdvanceDelayedVirtualSequence(posType, seq);
            return;
         }

         // Product: before the first REAL trade only the DoubleCheck EMA/ADX
         // inputs are re-validated. RSI/BB are NOT re-checked — with
         // DoubleCheck flags false, the first real trade may open against
         // the original filters (documented product behavior).
         if(!DoubleCheckFilters(seq.DelaySignalIsBuy))
         {
            LogVerbose("DelayTradeSequence cancelled: double_check_filters_failed");
            seq.Reset();
            return;
         }

         if(CountPositions(posType) >= MaxOrdersPerDirection || !DirectionAllowedGlobally(posType))
         {
            LogVerbose("DelayTradeSequence cancelled: direction_or_exposure_blocked");
            seq.Reset();
            return;
         }

         bool actualBuy = (posType == POSITION_TYPE_BUY);
         if(OpenFirstTradeImpl(posType, seq, actualBuy))
            LogMajor("DelayTradeSequence completed: first real " +
                     (actualBuy ? "BUY" : "SELL") +
                     " at lvl " + IntegerToString(seq.Level));
         return;
      }

      // All positions closed externally (SL hit etc.)
      if(actualCount == 0 && seq.TradeCount > 0 &&
         (LiveDelay == 0 || seq.LiveDelayCounter >= LiveDelay))
      {
         LogMajor("Seq cleared externally: " + (isBuyDirection ? "BUY" : "SELL"));
         FinalizeSequenceMetrics(seq);
         seq.Reset();
         return;
      }

      if(actualCount > 0)
      {
         seq.TradeCount       = actualCount;
         seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
         seq.TotalLots        = GetTotalLots(posType);
      }

      // TP
      if(CheckSequenceTP(posType, seq)) { CloseSequence(posType, seq, "TakeProfit"); return; }

      // Lock profit (bar-gated)
      if(IsBarCloseCheck(LockProfitCheckMode))
         CheckLockProfit(posType, seq);

      // Trailing (bar-gated)
      if(seq.LockTriggered && IsBarCloseCheck(TrailingCheckMode))
      {
         if(CheckTrailingStop(posType, seq)) { CloseSequence(posType, seq, "TrailingStop"); return; }
      }

      // Grid expansion (MaxOrders enforced on real position count inside)
      if(GridShouldOpenNext(posType, seq))
         OpenGridTrade(posType, seq);
      return;
   }

   // === LOCKED ===
   if(seq.State == STATE_LOCKED)
   {
      if(actualCount == 0) { seq.Reset(); return; }
      seq.TradeCount       = actualCount;
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots        = GetTotalLots(posType);

      if(CheckSequenceTP(posType, seq)) { CloseSequence(posType, seq, "TakeProfit"); return; }
      if(IsBarCloseCheck(TrailingCheckMode))
      {
         if(CheckTrailingStop(posType, seq)) { CloseSequence(posType, seq, "TrailingStop"); return; }
      }
      return;
   }

   // === PAUSED (session/news) ===
   // Product says "EA turns off but keeps trades open"; exits (TP / armed
   // trailing) are still honored as a safety bias — documented AMBIGUOUS.
   if(seq.State == STATE_PAUSED_BY_SESSION || seq.State == STATE_PAUSED_BY_NEWS)
   {
      if(actualCount == 0) { seq.Reset(); return; }
      if(CheckSequenceTP(posType, seq)) { CloseSequence(posType, seq, "TakeProfit(paused)"); return; }
      if(seq.LockTriggered && IsBarCloseCheck(TrailingCheckMode))
      {
         if(CheckTrailingStop(posType, seq)) { CloseSequence(posType, seq, "TrailingStop(paused)"); return; }
      }
      return;
   }

   // === STOPPED — do nothing ===
}

void ProcessSequence(bool isBuy)
{
   if(isBuy)
      ProcessSequenceImpl(POSITION_TYPE_BUY,  g_seqBuy,  true);
   else
      ProcessSequenceImpl(POSITION_TYPE_SELL, g_seqSell, false);
}


// =====================================================================
// EA LIFECYCLE
// =====================================================================

int OnInit()
{
   if(MagicNumber <= 0)
   {
      Print("ERROR: MagicNumber must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(RandomEntryDelayMinSeconds < 0)
   {
      Print("ERROR: RandomEntryDelayMinSeconds must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(RandomEntryDelayMaxSeconds < RandomEntryDelayMinSeconds)
   {
      Print("ERROR: RandomEntryDelayMaxSeconds must be >= RandomEntryDelayMinSeconds");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(DelayTradeSequence < 0)
   {
      Print("ERROR: DelayTradeSequence must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   if(LiveDelay < 0)
   {
      Print("ERROR: LiveDelay must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_pipMultiplier = (digits == 3 || digits == 5) ? 10 : 1;

   if(!IndicatorFiltersInit())
   {
      Print("ERROR: Indicator init failed");
      return INIT_FAILED;
   }

   g_randomState = (uint)(RandomSeed != 0 ? RandomSeed : 1);

   g_metrics.Reset();
   g_sequenceDurationSum = 0;
   g_sequenceDepthSum    = 0;

   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyResetTime    = 0;
   g_globalEquityHigh  = AccountInfoDouble(ACCOUNT_EQUITY);

   g_seqBuy.Reset();
   g_seqSell.Reset();

   ReconstructSequence(POSITION_TYPE_BUY,  g_seqBuy);
   ReconstructSequence(POSITION_TYPE_SELL, g_seqSell);

   g_weekendClosed       = false;
   g_lossStopped         = false;
   g_lossStopTime        = 0;
   g_dailyTargetStopped  = false;
   g_dailyTargetStopTime = 0;
   g_ultimateStopped     = false;
   g_globalEquityStopped = false;
   g_lastBarTimeChart    = 0;
   g_lastBarTimeM1       = 0;
   g_isNewBarChart       = false;
   g_isNewBarM1          = false;
   g_pendingBuyEntry     = false;
   g_pendingSellEntry    = false;
   g_pendingBuyEntryTime = 0;
   g_pendingSellEntryTime = 0;
   g_lastGlobalTradeTime = 0;
   g_lastNewsCheckTime   = 0;
   g_newsActiveCache     = false;

   LogMajor("Triton v1.1 initialized: " + _Symbol +
            " magic=" + (string)MagicNumber +
            " pipMult=" + IntegerToString(g_pipMultiplier));

   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   IndicatorFiltersDeInit();
   LogMajor("Triton deinitialized reason=" + IntegerToString(reason) +
            " seqs=" + IntegerToString(g_metrics.TotalSequences));
}

void OnTick()
{
   // 0. New-bar flags (single non-destructive computation per tick)
   UpdateBarFlags();

   // 1. Daily reset — clears daily-target stop / optional equity-stop reset
   CheckDailyReset();

   // 2. Restart after MaxRunningLoss stop. MUST run before the guard's
   //    latched-stop early return, otherwise restart is unreachable.
   if(g_lossStopped && CanRestartAfterLoss())
   {
      g_lossStopped = false;
      ReleaseStoppedSequences();
      LogMajor("Restarting after loss stop");
   }

   // 3. Equity guard — highest priority
   if(EquityGuardCheck())
   {
      CancelAllPendingRandomEntries("equity_guard_active");
      return;
   }

   // 4. Weekend close window
   if(CloseForWeekend)
   {
      if(InWeekendClosure())
      {
         if(!g_weekendClosed)
         {
            LogMajor("Weekend close triggered");
            CloseAllPositionsBothDirections();
            g_seqBuy.Reset();
            g_seqSell.Reset();
            CancelAllPendingRandomEntries("weekend_close");
            g_weekendClosed = true;
         }
         return;
      }
      if(g_weekendClosed)
      {
         g_weekendClosed = false;
         LogMajor("Weekend restart");
      }
   }

   // 3. News filter
   if(UseHighImpactNews)
   {
      if(IsHighImpactNewsNow())
      {
         switch(NewsTradesAction)
         {
            case NEWS_CLOSE_ALL:
               if(g_seqBuy.State != STATE_PAUSED_BY_NEWS)
               {
                  LogMajor("News: close all");
                  CloseAllPositionsBothDirections();
                  CancelAllPendingRandomEntries("news_close_all");
                  g_seqBuy.Reset();  g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
                  g_seqSell.Reset(); g_seqSell.State = STATE_PAUSED_BY_NEWS;
               }
               return;

            case NEWS_PAUSE_SEQUENCE:
               CancelAllPendingRandomEntries("news_pause_sequence");
               CancelFlatVirtualSequences("news_pause_sequence");
               if(g_seqBuy.State  == STATE_IDLE) g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
               if(g_seqSell.State == STATE_IDLE) g_seqSell.State = STATE_PAUSED_BY_NEWS;
               if(g_seqBuy.State  == STATE_BUILDING) g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
               if(g_seqSell.State == STATE_BUILDING) g_seqSell.State = STATE_PAUSED_BY_NEWS;
               ProcessSequence(true);
               ProcessSequence(false);
               return;

            default: // NEWS_COMPLETE_SEQUENCE — manage open baskets, no NEW risk
               CancelAllPendingRandomEntries("news_blocks_new_entries");
               // Virtual sequences hold zero positions — they must not turn
               // into real exposure during the news window
               CancelFlatVirtualSequences("news_blocks_new_entries");
               if(g_seqBuy.State  == STATE_IDLE) g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
               if(g_seqSell.State == STATE_IDLE) g_seqSell.State = STATE_PAUSED_BY_NEWS;
               if(g_seqBuy.State  == STATE_BUILDING || g_seqBuy.State  == STATE_LOCKED) ProcessSequence(true);
               if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED) ProcessSequence(false);
               return;
         }
      }
      else
      {
         if(g_seqBuy.State  == STATE_PAUSED_BY_NEWS)
            g_seqBuy.State  = (CountPositions(POSITION_TYPE_BUY)  > 0) ? STATE_BUILDING : STATE_IDLE;
         if(g_seqSell.State == STATE_PAUSED_BY_NEWS)
            g_seqSell.State = (CountPositions(POSITION_TYPE_SELL) > 0) ? STATE_BUILDING : STATE_IDLE;
      }
   }

   // 4. Session filter
   if(TradeCustomTimes)
   {
      if(!IsInSession())
      {
         switch(ActionAtEndOfSession)
         {
            case CLOSE_ALL_TRADES:
               if(g_seqBuy.State != STATE_PAUSED_BY_SESSION)
               {
                  LogMajor("Session end: close all");
                  CloseAllPositions(POSITION_TYPE_BUY);
                  CancelPendingRandomEntry(true, "session_close_all");
                  g_seqBuy.Reset(); g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               }
               if(g_seqSell.State != STATE_PAUSED_BY_SESSION)
               {
                  CloseAllPositions(POSITION_TYPE_SELL);
                  CancelPendingRandomEntry(false, "session_close_all");
                  g_seqSell.Reset(); g_seqSell.State = STATE_PAUSED_BY_SESSION;
               }
               return;

            case PAUSE_SEQUENCE:
               CancelAllPendingRandomEntries("session_pause_sequence");
               CancelFlatVirtualSequences("session_pause_sequence");
               if(g_seqBuy.State  == STATE_BUILDING) g_seqBuy.State  = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_BUILDING) g_seqSell.State = STATE_PAUSED_BY_SESSION;
               if(g_seqBuy.State  == STATE_IDLE)     g_seqBuy.State  = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_IDLE)     g_seqSell.State = STATE_PAUSED_BY_SESSION;
               if(g_seqBuy.State  == STATE_LOCKED) ProcessSequence(true);
               if(g_seqSell.State == STATE_LOCKED) ProcessSequence(false);
               return;

            default: // COMPLETE_SEQUENCE — manage open baskets, block new risk
               CancelAllPendingRandomEntries("session_blocks_new_entries");
               // Virtual sequences hold zero positions — they must not turn
               // into real exposure outside the session
               CancelFlatVirtualSequences("session_blocks_new_entries");
               if(g_seqBuy.State  == STATE_BUILDING || g_seqBuy.State  == STATE_LOCKED) ProcessSequence(true);
               if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED) ProcessSequence(false);
               if(g_seqBuy.State  == STATE_IDLE) g_seqBuy.State  = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_IDLE) g_seqSell.State = STATE_PAUSED_BY_SESSION;
               return;
         }
      }
      else
      {
         if(g_seqBuy.State  == STATE_PAUSED_BY_SESSION)
         { g_seqBuy.State  = (CountPositions(POSITION_TYPE_BUY)  > 0) ? STATE_BUILDING : STATE_IDLE; LogVerbose("BUY resumed from session pause"); }
         if(g_seqSell.State == STATE_PAUSED_BY_SESSION)
         { g_seqSell.State = (CountPositions(POSITION_TYPE_SELL) > 0) ? STATE_BUILDING : STATE_IDLE; LogVerbose("SELL resumed from session pause"); }
      }
   }

   // 5. Track drawdown peak
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_globalEquityHigh) g_globalEquityHigh = equity;
   double currentDD = g_globalEquityHigh - equity;
   if(currentDD > g_metrics.MaxDD) g_metrics.MaxDD = currentDD;

   // 6. Process both directions
   ProcessSequence(true);
   ProcessSequence(false);
}

void OnTrade()
{
   // Sync sequence states when positions close externally (SL hits etc.)
   // TradeCount > 0 guard: virtual phases (DelayTradeSequence levels,
   // LiveDelay accumulation) hold zero positions BY DESIGN — without the
   // guard any trade event (even opposite direction) wiped their state.
   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);

   if(g_seqBuy.State == STATE_BUILDING || g_seqBuy.State == STATE_LOCKED)
   {
      if(buyCount == 0 && g_seqBuy.TradeCount > 0)
      {
         LogMajor("BUY seq closed externally");
         FinalizeSequenceMetrics(g_seqBuy);
         g_seqBuy.Reset();
      }
      else if(buyCount > 0)
         g_seqBuy.TradeCount = buyCount;
   }

   if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED)
   {
      if(sellCount == 0 && g_seqSell.TradeCount > 0)
      {
         LogMajor("SELL seq closed externally");
         FinalizeSequenceMetrics(g_seqSell);
         g_seqSell.Reset();
      }
      else if(sellCount > 0)
         g_seqSell.TradeCount = sellCount;
   }
}

double OnTester()
{
   // Prop-firm survival scoring (replaces raw profit maximization)
   double netProfit  = TesterStatistics(STAT_PROFIT);
   double profitFactor = TesterStatistics(STAT_PROFIT_FACTOR);
   double maxDD      = TesterStatistics(STAT_EQUITY_DD);

   Print("=== Triton Optimization Metrics ===");
   Print("TotalSequences:  ", g_metrics.TotalSequences);
   Print("MaxDepth:        ", g_metrics.MaxDepth);
   Print("AvgDepth:        ", DoubleToString(g_metrics.AvgDepth, 2));
   Print("AvgDuration(s):  ", DoubleToString(g_metrics.AvgDuration, 1));
   Print("MaxDD($):        ", DoubleToString(g_metrics.MaxDD, 2));
   Print("RiskStopCount:   ", g_metrics.RiskStopCount);
   Print("DailyTargetHits: ", g_metrics.DailyTargetHits);
   Print("DailyLossHits:   ", g_metrics.DailyLossHits);
   Print("=====================================");

   double sharpe    = TesterStatistics(STAT_SHARPE_RATIO);
   double deposit   = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double ddPct     = (deposit > 0) ? (maxDD / deposit * 100.0) : 0.0;  // 0–100
   int    trades    = (int)TesterStatistics(STAT_TRADES);

   // --- Hard disqualifiers (prop-firm killers) ---
   if(g_metrics.RiskStopCount > 0) return -100000.0;  // equity stop hit = instant fail
   if(trades < 10)                 return  -50000.0;  // too few trades = overfit

   // --- Composite prop-firm survival score ---
   // Rewards: profit, Sharpe (risk-adjusted consistency), profit quality (PF above breakeven)
   // Penalises: DD%, daily loss rule hits, deep grid exposure
   double score = netProfit
                + (sharpe * 1000.0)                        // consistency: Sharpe 1.5 → +1500
                + ((profitFactor - 1.0) * 500.0)           // quality: PF 2.0 → +500, PF 1.0 → 0
                - (ddPct * 500.0)                          // DD%: 10% → -5000, 5% → -2500
                - (g_metrics.DailyLossHits  * 1500.0)      // prop rule violation
                - (g_metrics.MaxDepth       * 30.0)        // grid depth risk
                - (g_metrics.AvgDuration / 3600.0 * 5.0);  // long holds risk

   return score;
}

//+------------------------------------------------------------------+
