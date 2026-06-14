//+------------------------------------------------------------------+
//|                                          ArchAngelX_Rebuilt.mq5  |
//|                        Production-Grade Grid Mean Reversion EA   |
//|                                                                  |
//+------------------------------------------------------------------+
//
// =====================================================================
// ARCHITECTURE OVERVIEW
// =====================================================================
//
// ArchAngelX is a grid-based sequence mean reversion system.
// It opens trades at exponentially expanding pip steps with
// exponentially increasing lot sizes, then closes the entire
// sequence based on weighted-average TP, lock profit + trailing,
// or equity/risk guardrails.
//
// MODULES (implemented as struct + function groups):
//   1.  EntryEngine        – First-trade signal validation
//   2.  GridEngine          – Pip step distance calculations
//   3.  LotEngine           – Lot size ladder & compounding
//   4.  SequenceManager     – Tracks open grid sequences per direction
//   5.  ExitEngine          – TP / SL / Lock / Trail / Weekend close
//   6.  RiskManager         – Per-trade SL, equity stops
//   7.  SessionManager      – Custom session windows & actions
//   8.  NewsManager         – High-impact news filter
//   9.  IndicatorFilters    – RSI, EMA, ADX, Bollinger entry filters
//  10.  EquityGuard         – Global equity circuit breakers
//  11.  Logger              – Multi-level logging
//
// STATE MACHINE:
//   IDLE → BUILDING → LOCKED → (exit)
//   Any state → PAUSED_BY_SESSION | PAUSED_BY_NEWS
//   Any state → STOPPED_BY_EQUITY | STOPPED_BY_LOSS
//
// GENETIC OPTIMIZATION:
//   - No dynamic arrays that change size unpredictably
//   - No random behavior unless seeded (deterministic)
//   - No time-dependent behavior except session rules
//   - Deterministic execution order
//   - OptimizationMetrics printed in OnTester()
//
// ASSUMPTIONS:
//   1. Runs on a single symbol per chart instance.
//   2. MagicNumber uniquely identifies this EA instance.
//   3. News detection via IsHighImpactNewsNow() is abstracted;
//      user must supply a news calendar or external feed.
//   4. Weekend close times are broker-server time.
//   5. Session times are broker-server time.
//   6. ATR-based pip mode replaces raw pip values with ATR multiples.
//   7. Compounding formula uses AccountInfoDouble(ACCOUNT_BALANCE).
//   8. Weighted average entry = sum(lot_i * price_i) / sum(lot_i).
//   9. "Pips" = points * _Point; 1 pip = 10 points on 5-digit.
//  10. All equity guards override all other logic.
//
// VALIDATION CHECKLIST:
//   [ ] Compile with zero warnings in MT5 build 3800+
//   [ ] Single-chart backtest matches multi-run (determinism)
//   [ ] LiveDelay + CombineLiveDelayTrades logic correct
//   [ ] Lock profit triggers only when MinTrades met
//   [ ] Trailing follows profit correctly
//   [ ] Weekend close/restart toggles sequence state
//   [ ] Session pause obeys ActionAtEndOfSession
//   [ ] EquityGuard overrides everything
//   [ ] OnTester() prints OptimizationMetrics
//   [ ] Logger respects LogLevel input
//   [ ] ReverseSequenceDirection inverts grid after entry
//   [ ] ATR mode multiplies all pip inputs by ATR value
//   [ ] Compounding formula matches spec exactly
//   [ ] MaxLotSize caps applied at every lot calculation
//   [ ] StopLoss is per individual trade; TP is per sequence
//
// =====================================================================

#property copyright "ArchAngelX"
#property link      ""
#property version   "2.00"
#property strict

// =====================================================================
// ENUMERATIONS
// =====================================================================

enum ENUM_TRADE_DIRECTION
{
   BOTH        = 0, // Both Directions
   LONG_ONLY   = 1, // Long Only
   SHORT_ONLY  = 2  // Short Only
};

enum ENUM_LOCK_CHECK_MODE
{
   BAR_CLOSE_CHART = 0, // Bar Close (Chart TF)
   BAR_CLOSE_M1    = 1, // Bar Close (M1)
   EVERY_TICK      = 2  // Every Tick
};

enum ENUM_SESSION_END_ACTION
{
   CLOSE_ALL_TRADES       = 0, // Close All
   WAIT_SEQUENCE_CLOSE    = 1, // Wait Sequence Close
   PAUSE_OPEN_SEQUENCE    = 2  // Pause Open Sequence
};

enum ENUM_RESTART_MODE
{
   RESTART_DISABLED       = 0, // Disabled
   RESTART_NEXT_DAY       = 1, // Restart Next Day
   RESTART_AFTER_HOURS    = 2  // Restart After Hours
};

enum ENUM_EQUITY_STOP_TYPE
{
   EQUITY_ABSOLUTE        = 0, // Absolute Value
   EQUITY_RISKED_AMOUNT   = 1, // Risked Amount
   EQUITY_RISKED_PERCENT  = 2  // Risked Percent
};

enum ENUM_EMA_TREND_RULE
{
   WITH_TREND_ONLY        = 0, // With Trend Only
   AVOID_OPPOSITE_TREND   = 1  // Avoid Opposite Trend
};

enum ENUM_ADX_TREND_RULE
{
   ADX_WITH_TREND_ONLY        = 0, // With Trend Only
   ADX_AVOID_OPPOSITE_TREND   = 1  // Avoid Opposite Trend
};

enum ENUM_BB_MODE
{
   BB_AVOID_EXTREME               = 0, // Avoid Extreme
   BB_ONLY_EXTREME_COUNTER_TREND  = 1  // Only Extreme Counter-Trend
};

enum ENUM_NEWS_ACTION
{
   NEWS_MANAGE_SEQUENCE   = 0, // Manage Sequence
   NEWS_CLOSE_ALL_DISABLE = 1  // Close All & Disable
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

//--- General Settings
input group "═══ GENERAL SETTINGS ═══"
input bool     AllowNewSequence          = true;                  // Allow New Sequence
input string   StrategyDescription       = "ArchAngelX Grid MR"; // Strategy Description
input string   TradeComment              = "AAX";                 // Trade Comment
input long     MagicNumber               = 123456;                // Magic Number
input bool     UseRandomEntryDelay       = false;                 // Use Random Entry Delay
input int      RandomSeed                = 42;                    // Random Seed (if random enabled)
input int      LogLevel                  = 1;                     // Log Level (0=silent,1=major,2=verbose,3=debug)

//--- Sequence Settings
input group "═══ SEQUENCE SETTINGS ═══"
input bool     UseATRForPips             = false;                 // Use ATR For Pips
input int      ATRPeriod                 = 14;                    // ATR Period
input double   PipStep                   = 10.0;                  // Pip Step
input double   PipStepExponent           = 1.2;                   // Pip Step Exponent
input double   MaxPipStep                = 0.0;                   // Max Pip Step (0=unlimited)
input int      DelayTradeSequence        = 0;                     // Delay Trade Sequence (bars)
input int      LiveDelay                 = 0;                     // Live Delay (levels)
input double   LotMultiplierFirstTradeAfterLD = 1.0;              // Lot Multiplier First Trade After LD
input bool     CombineLiveDelayTrades    = true;                  // Combine Live Delay Trades
input ENUM_TRADE_DIRECTION TradeDirection = BOTH;                 // Trade Direction
input int      MaxOrdersPerDirection     = 20;                    // Max Orders Per Direction
input bool     ReverseSequenceDirection  = false;                 // Reverse Sequence Direction

//--- Money Management
input group "═══ MONEY MANAGEMENT ═══"
input double   TakeProfit                = 10.0;                  // Take Profit (pips from weighted avg)
input double   StopLoss                  = 0.0;                   // Stop Loss Per Trade (pips, 0=off)
input int      LockProfitMinTrades       = 3;                     // Lock Profit Min Trades
input double   LockProfit                = 5.0;                   // Lock Profit (pips, 0=off)
input ENUM_LOCK_CHECK_MODE LockProfitCheckMode = EVERY_TICK;      // Lock Profit Check Mode
input double   TrailingStop              = 3.0;                   // Trailing Stop (pips, 0=off)
input ENUM_LOCK_CHECK_MODE TrailingCheckMode = EVERY_TICK;        // Trailing Check Mode
input bool     AllowSamePairDirectionTrades = true;               // Allow Same Pair Direction Trades

//--- Compound Settings
input group "═══ COMPOUND SETTINGS ═══"
input bool     UseCompounding            = false;                 // Use Compounding
input double   InitialAccountBalanceThreshold = 10000.0;          // Initial Account Balance Threshold
input double   RiskPercentForCompounding = 1.0;                   // Risk Percent For Compounding
input double   RiskInPips                = 100.0;                 // Risk In Pips
input double   MaxLotSizeForCompounding  = 10.0;                  // Max Lot Size For Compounding

//--- Lot Size Settings
input group "═══ LOT SIZE SETTINGS ═══"
input double   LotSize                   = 0.01;                  // Lot Size (fixed)
input double   RiskPercent               = 0.0;                   // Risk Percent (0=off, uses fixed)
input double   LotSizeExponent           = 1.5;                   // Lot Size Exponent
input double   MaxLotSize                = 0.0;                   // Max Lot Size (0=unlimited)

//--- Weekend Settings
input group "═══ WEEKEND SETTINGS ═══"
input bool     CloseForWeekend           = false;                 // Close For Weekend
input int      DayToClose                = 5;                     // Day To Close (1=Mon..5=Fri)
input string   TimeToClose               = "20:00";               // Time To Close
input int      DayToRestart              = 1;                     // Day To Restart (1=Mon)
input string   TimeToRestart             = "01:00";               // Time To Restart

//--- Custom Session Settings
input group "═══ CUSTOM SESSION SETTINGS ═══"
input bool     TradeCustomTimes           = false;                // Trade Custom Times
input string   TradingSessionMonday       = "00:00-23:59";       // Monday Session
input string   TradingSessionTuesday      = "00:00-23:59";       // Tuesday Session
input string   TradingSessionWednesday    = "00:00-23:59";       // Wednesday Session
input string   TradingSessionThursday     = "00:00-23:59";       // Thursday Session
input string   TradingSessionFriday       = "00:00-23:59";       // Friday Session
input ENUM_SESSION_END_ACTION ActionAtEndOfSession = CLOSE_ALL_TRADES; // Action At End Of Session

//--- Equity Protection
input group "═══ EQUITY PROTECTION ═══"
input double   MaxRunningLoss            = 0.0;                   // Max Running Loss (0=off)
input ENUM_RESTART_MODE RestartEAAfterLoss = RESTART_DISABLED;    // Restart EA After Loss
input string   RestartNextDayAt          = "00:00";               // Restart Next Day At
input double   RestartAfterHours         = 4.0;                   // Restart After Hours
input double   DailyProfitTarget         = 0.0;                   // Daily Profit Target (0=off)
input double   UltimateTargetBalance     = 0.0;                   // Ultimate Target Balance (0=off)
input ENUM_EQUITY_STOP_TYPE GlobalEquityStopType = EQUITY_ABSOLUTE; // Global Equity Stop Type
input double   GlobalEquityStopValue     = 0.0;                   // Global Equity Stop Value (0=off)
input bool     ResetGlobalEquityStop     = false;                 // Reset Global Equity Stop Daily
input int      MinSecondsBetweenTrades   = 0;                     // Min Seconds Between Trades

//--- Indicator Filters — RSI
input group "═══ INDICATOR FILTERS — RSI ═══"
input bool     UseRSI                    = false;                 // Use RSI
input ENUM_TIMEFRAMES RSITimeframe       = PERIOD_CURRENT;        // RSI Timeframe
input int      RSIPeriod                 = 14;                    // RSI Period
input double   RSIOverboughtLevel        = 70.0;                  // RSI Overbought Level

//--- Indicator Filters — EMA
input group "═══ INDICATOR FILTERS — EMA ═══"
input bool     UseEMA                    = false;                 // Use EMA
input ENUM_TIMEFRAMES EMATimeframe       = PERIOD_CURRENT;        // EMA Timeframe
input int      EMAFast                   = 10;                    // EMA Fast Period
input int      EMAMid                    = 25;                    // EMA Mid Period
input int      EMASlow                   = 50;                    // EMA Slow Period
input ENUM_EMA_TREND_RULE EMATrendRule   = WITH_TREND_ONLY;       // EMA Trend Rule
input bool     DoubleCheckEMAFirstRealTrade = false;              // Double Check EMA First Real Trade

//--- Indicator Filters — ADX
input group "═══ INDICATOR FILTERS — ADX ═══"
input bool     UseADX                    = false;                 // Use ADX
input ENUM_TIMEFRAMES ADXTimeframe       = PERIOD_CURRENT;        // ADX Timeframe
input int      ADXPeriod                 = 14;                    // ADX Period
input double   ADXThreshold              = 25.0;                  // ADX Threshold
input ENUM_ADX_TREND_RULE ADXTrendRule   = ADX_WITH_TREND_ONLY;   // ADX Trend Rule
input bool     DoubleCheckADXFirstRealTrade = false;              // Double Check ADX First Real Trade

//--- Indicator Filters — Bollinger Bands
input group "═══ INDICATOR FILTERS — BOLLINGER ═══"
input bool     UseBollinger              = false;                 // Use Bollinger Bands
input ENUM_BB_MODE BBMode                = BB_AVOID_EXTREME;      // BB Mode
input ENUM_TIMEFRAMES BBTimeframe        = PERIOD_CURRENT;        // BB Timeframe
input int      BBPeriod                  = 20;                    // BB Period
input double   BBDeviation               = 2.0;                  // BB Deviation

//--- News Filter
input group "═══ NEWS FILTER ═══"
input bool     UseHighImpactNews         = false;                 // Use High Impact News Filter
input ENUM_NEWS_ACTION NewsTradesAction  = NEWS_MANAGE_SEQUENCE;  // News Trades Action
input double   CloseHoursBeforeNews      = 0.5;                   // Close Hours Before News
input double   PauseHoursAfterNews       = 0.5;                   // Pause Hours After News


// =====================================================================
// STRUCTS
// =====================================================================

//--- Optimization Metrics (printed in OnTester)
struct OptimizationMetrics
{
   int    TotalSequences;
   int    MaxDepth;
   double AvgDepth;
   double AvgDuration;      // seconds
   double MaxDD;
   int    RiskStopCount;

   void Reset()
   {
      TotalSequences = 0;
      MaxDepth       = 0;
      AvgDepth       = 0.0;
      AvgDuration    = 0.0;
      MaxDD          = 0.0;
      RiskStopCount  = 0;
   }
};

//--- Sequence tracking per direction
struct SequenceInfo
{
   ENUM_SEQUENCE_STATE State;
   int      Level;                  // current grid level (0-based)
   int      TradeCount;             // number of open trades
   double   WeightedAvgPrice;       // lot-weighted average entry
   double   TotalLots;              // sum of lots in sequence
   double   LockReferencePrice;     // price when lock triggered
   bool     LockTriggered;          // lock profit active
   double   TrailingPrice;          // current trailing stop price
   bool     TrailingActive;         // trailing active
   datetime LastTradeTime;          // time of last trade opened
   datetime SequenceStartTime;      // when sequence began
   int      LiveDelayCounter;       // trades deferred by LiveDelay
   double   LiveDelayAccumLots;     // accumulated lots during delay
   int      DepthHistory;           // max depth reached
   bool     FirstRealTradeAfterLD;  // flag for LD lot multiplier
   bool     LDMultiplierApplied;   // LD lot multiplier already used

   void Reset()
   {
      State              = STATE_IDLE;
      Level              = 0;
      TradeCount         = 0;
      WeightedAvgPrice   = 0.0;
      TotalLots          = 0.0;
      LockReferencePrice = 0.0;
      LockTriggered      = false;
      TrailingPrice      = 0.0;
      TrailingActive     = false;
      LastTradeTime      = 0;
      SequenceStartTime  = 0;
      LiveDelayCounter   = 0;
      LiveDelayAccumLots = 0.0;
      DepthHistory       = 0;
      FirstRealTradeAfterLD = false;
      LDMultiplierApplied = false;
   }
};

//--- Indicator cache
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

//--- Session time window
struct SessionWindow
{
   int StartHour;
   int StartMinute;
   int EndHour;
   int EndMinute;
   bool Active;
};

// =====================================================================
// GLOBAL STATE (minimal — only what must persist across ticks)
// =====================================================================

SequenceInfo      g_seqBuy;
SequenceInfo      g_seqSell;
IndicatorCache    g_indicators;
OptimizationMetrics g_metrics;

datetime          g_lastBarTimeChart  = 0;
datetime          g_lastBarTimeM1     = 0;
datetime          g_equityStopTime    = 0;     // when equity stop triggered
double            g_dailyStartBalance = 0.0;
datetime          g_dailyResetTime    = 0;
bool              g_weekendClosed     = false;
bool              g_equityStopped     = false;
bool              g_lossStopped       = false;
datetime          g_lossStopTime      = 0;
double            g_globalEquityHigh  = 0.0;
uint              g_randomState       = 0;      // deterministic PRNG state
int               g_sequenceDurationSum = 0;
int               g_sequenceDepthSum    = 0;
int               g_pipMultiplier       = 1;    // 10 for 5-digit, 1 for 4-digit


// =====================================================================
// MODULE: LOGGER
// =====================================================================

void Log(int level, string message)
{
   if(level <= LogLevel)
      Print("[AAX L", level, "] ", message);
}

void LogDebug(string message)   { Log(3, message); }
void LogVerbose(string message) { Log(2, message); }
void LogMajor(string message)   { Log(1, message); }


// =====================================================================
// MODULE: UTILITY HELPERS
// =====================================================================

//--- Deterministic PRNG (xorshift32)
uint RandomNext()
{
   g_randomState ^= (g_randomState << 13);
   g_randomState ^= (g_randomState >> 17);
   g_randomState ^= (g_randomState << 5);
   return g_randomState;
}

//--- Convert pips to price distance
double PipsToPrice(double pips)
{
   return pips * g_pipMultiplier * _Point;
}

//--- Get pip value for lot size
double GetPipValue(double lots)
{
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize == 0) return 0;
   return (g_pipMultiplier * _Point / tickSize) * tickValue * lots;
}

//--- Get current ATR value
double GetATRValue()
{
   if(g_indicators.hATR == INVALID_HANDLE) return 0;
   double buf[1];
   if(CopyBuffer(g_indicators.hATR, 0, 0, 1, buf) == 1)
      return buf[0];
   return 0;
}

//--- Convert pip input to actual distance (handles ATR mode)
double ResolveDistance(double pipInput)
{
   if(UseATRForPips)
   {
      double atr = GetATRValue();
      if(atr == 0) return PipsToPrice(pipInput); // fallback
      return pipInput * atr;
   }
   return PipsToPrice(pipInput);
}

//--- Normalize lot to broker specs
double NormalizeLot(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep == 0) lotStep = 0.01;
   lots = MathFloor(lots / lotStep) * lotStep;
   lots = MathMax(lots, minLot);
   lots = MathMin(lots, maxLot);
   return NormalizeDouble(lots, 2);
}

//--- Parse time string "HH:MM" to hour and minute
bool ParseTime(string timeStr, int &hour, int &minute)
{
   string parts[];
   int count = StringSplit(timeStr, ':', parts);
   if(count < 2) return false;
   hour   = (int)StringToInteger(parts[0]);
   minute = (int)StringToInteger(parts[1]);
   return true;
}

//--- Parse session string "HH:MM-HH:MM"
bool ParseSession(string sessionStr, SessionWindow &win)
{
   string parts[];
   int count = StringSplit(sessionStr, '-', parts);
   if(count < 2)
   {
      win.Active = false;
      return false;
   }
   int sh, sm, eh, em;
   if(!ParseTime(parts[0], sh, sm) || !ParseTime(parts[1], eh, em))
   {
      win.Active = false;
      return false;
   }
   win.StartHour   = sh;
   win.StartMinute = sm;
   win.EndHour     = eh;
   win.EndMinute   = em;
   win.Active      = true;
   return true;
}

//--- Count open positions for magic + symbol + direction
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

//--- Get total lots for direction
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

//--- Compute weighted average entry for direction
double ComputeWeightedAverage(ENUM_POSITION_TYPE posType)
{
   double sumLotPrice = 0;
   double sumLots     = 0;
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

//--- Get floating profit for direction
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

//--- Get total floating profit (all directions)
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

//--- Get the worst (most adverse) open price for sequence direction
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
         if(first)
         {
            worst = price;
            first = false;
         }
         else
         {
            if(posType == POSITION_TYPE_BUY)
               worst = MathMin(worst, price);   // worst buy = lowest
            else
               worst = MathMax(worst, price);   // worst sell = highest
         }
      }
   }
   return worst;
}

//--- Close all positions for a direction
bool CloseAllPositions(ENUM_POSITION_TYPE posType)
{
   bool allClosed = true;
   MqlTradeRequest  req;
   MqlTradeResult   res;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

      ZeroMemory(req);
      ZeroMemory(res);
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

      if(!OrderSend(req, res))
      {
         Log(1, "Failed to close ticket " + IntegerToString((int)ticket) +
             " error=" + IntegerToString(res.retcode));
         allClosed = false;
      }
   }
   return allClosed;
}

//--- Close ALL positions (both directions)
bool CloseAllPositionsBothDirections()
{
   bool a = CloseAllPositions(POSITION_TYPE_BUY);
   bool b = CloseAllPositions(POSITION_TYPE_SELL);
   return a && b;
}


// =====================================================================
// MODULE: GRID ENGINE
// =====================================================================

//--- Calculate step distance for a given grid level
double GridStepDistance(int level)
{
   if(level <= 0) return 0;

   double rawStep = PipStep * MathPow(PipStepExponent, (double)level);
   if(MaxPipStep > 0 && rawStep > MaxPipStep)
      rawStep = MaxPipStep;

   return ResolveDistance(rawStep);
}

//--- Calculate cumulative distance from level 0 to level N
double GridCumulativeDistance(int level)
{
   double total = 0;
   for(int i = 1; i <= level; i++)
      total += GridStepDistance(i);
   return total;
}

//--- Check if price has moved enough for next grid level
bool GridShouldOpenNext(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(seq.Level <= 0) return false;

   double worstPrice = GetWorstPrice(posType);
   if(worstPrice == 0) return false;

   double stepDist = GridStepDistance(seq.Level);
   double currentPrice = (posType == POSITION_TYPE_BUY) ?
                         SymbolInfoDouble(_Symbol, SYMBOL_ASK) :
                         SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // For buys: price must drop below worst by stepDist
   // For sells: price must rise above worst by stepDist
   if(posType == POSITION_TYPE_BUY)
      return (worstPrice - currentPrice) >= stepDist;
   else
      return (currentPrice - worstPrice) >= stepDist;
}


// =====================================================================
// MODULE: LOT ENGINE
// =====================================================================

//--- Compute base lot (handles compounding, risk%, or fixed)
double ComputeBaseLot()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);

   //--- Compounding mode
   if(UseCompounding)
   {
      if(InitialAccountBalanceThreshold <= 0) return NormalizeLot(LotSize);
      double pipVal = GetPipValue(1.0);
      if(pipVal == 0 || RiskInPips == 0) return NormalizeLot(LotSize);

      double baseLot = (balance / InitialAccountBalanceThreshold) *
                       ((RiskPercentForCompounding / 100.0 * balance) / (RiskInPips * pipVal));
      if(MaxLotSizeForCompounding > 0)
         baseLot = MathMin(baseLot, MaxLotSizeForCompounding);
      return NormalizeLot(baseLot);
   }

   //--- Risk percent mode
   if(RiskPercent > 0 && StopLoss > 0)
   {
      double pipVal = GetPipValue(1.0);
      if(pipVal == 0) return NormalizeLot(LotSize);
      double riskLot = (RiskPercent / 100.0 * balance) / (StopLoss * pipVal);
      if(MaxLotSize > 0)
         riskLot = MathMin(riskLot, MaxLotSize);
      return NormalizeLot(riskLot);
   }

   //--- Fixed lot
   return NormalizeLot(LotSize);
}

//--- Compute lot for a given grid level
double ComputeLotForLevel(int level)
{
   double base = ComputeBaseLot();
   double lot  = base * MathPow(LotSizeExponent, (double)level);
   if(MaxLotSize > 0)
      lot = MathMin(lot, MaxLotSize);
   return NormalizeLot(lot);
}


// =====================================================================
// MODULE: INDICATOR FILTERS
// =====================================================================

//--- Initialize indicator handles
bool IndicatorFiltersInit()
{
   g_indicators.Reset();

   if(UseATRForPips || true) // always create ATR for potential use
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

   // Validate handles
   if(UseRSI     && g_indicators.hRSI     == INVALID_HANDLE) { Log(1, "RSI handle failed");     return false; }
   if(UseEMA     && g_indicators.hEMAFast  == INVALID_HANDLE) { Log(1, "EMA handle failed");     return false; }
   if(UseADX     && g_indicators.hADX      == INVALID_HANDLE) { Log(1, "ADX handle failed");     return false; }
   if(UseBollinger && g_indicators.hBBands == INVALID_HANDLE) { Log(1, "BBands handle failed");  return false; }

   return true;
}

//--- Release indicator handles
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

//--- RSI filter: returns true = allow trade
bool FilterRSI(bool isBuy)
{
   if(!UseRSI) return true;
   double buf[1];
   if(CopyBuffer(g_indicators.hRSI, 0, 0, 1, buf) != 1) return true;
   double rsi = buf[0];

   double oversoldLevel = 100.0 - RSIOverboughtLevel;

   if(isBuy)
      return (rsi <= oversoldLevel);   // buy when oversold
   else
      return (rsi >= RSIOverboughtLevel); // sell when overbought
}

//--- EMA filter: returns true = allow trade
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
      if(isBuy)  return upTrend;
      if(!isBuy) return downTrend;
   }
   else // AVOID_OPPOSITE_TREND
   {
      if(isBuy)  return !downTrend;
      if(!isBuy) return !upTrend;
   }
   return true;
}

//--- ADX filter: returns true = allow trade
bool FilterADX(bool isBuy)
{
   if(!UseADX) return true;

   double adxMain[1], adxPlus[1], adxMinus[1];
   if(CopyBuffer(g_indicators.hADX, 0, 0, 1, adxMain)  != 1) return true;
   if(CopyBuffer(g_indicators.hADX, 1, 0, 1, adxPlus)  != 1) return true;
   if(CopyBuffer(g_indicators.hADX, 2, 0, 1, adxMinus) != 1) return true;

   if(adxMain[0] < ADXThreshold) return false; // no strong trend

   bool bullTrend = (adxPlus[0] > adxMinus[0]);
   bool bearTrend = (adxMinus[0] > adxPlus[0]);

   if(ADXTrendRule == ADX_WITH_TREND_ONLY)
   {
      if(isBuy)  return bullTrend;
      if(!isBuy) return bearTrend;
   }
   else // AVOID_OPPOSITE_TREND
   {
      if(isBuy)  return !bearTrend;
      if(!isBuy) return !bullTrend;
   }
   return true;
}

//--- Bollinger filter: returns true = allow trade
bool FilterBollinger(bool isBuy)
{
   if(!UseBollinger) return true;

   double upper[1], lower[1], middle[1];
   if(CopyBuffer(g_indicators.hBBands, 1, 0, 1, upper) != 1) return true;  // upper band
   if(CopyBuffer(g_indicators.hBBands, 2, 0, 1, lower) != 1) return true;  // lower band
   if(CopyBuffer(g_indicators.hBBands, 0, 0, 1, middle) != 1) return true; // middle

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(BBMode == BB_AVOID_EXTREME)
   {
      // Avoid buying near upper, selling near lower
      if(isBuy  && ask >= upper[0]) return false;
      if(!isBuy && bid <= lower[0]) return false;
      return true;
   }
   else // BB_ONLY_EXTREME_COUNTER_TREND
   {
      // Buy only near lower (counter-trend), sell only near upper
      if(isBuy  && bid <= lower[0]) return true;
      if(!isBuy && ask >= upper[0]) return true;
      return false;
   }
}

//--- Combined entry filter for first trade signal
bool AllFiltersPass(bool isBuy)
{
   if(!FilterRSI(isBuy))        return false;
   if(!FilterEMA(isBuy))        return false;
   if(!FilterADX(isBuy))        return false;
   if(!FilterBollinger(isBuy))  return false;
   return true;
}

//--- Double-check filter for first REAL trade (after LiveDelay)
bool DoubleCheckFilters(bool isBuy)
{
   bool pass = true;
   if(DoubleCheckEMAFirstRealTrade && UseEMA)
      pass = pass && FilterEMA(isBuy);
   if(DoubleCheckADXFirstRealTrade && UseADX)
      pass = pass && FilterADX(isBuy);
   return pass;
}


// =====================================================================
// MODULE: SESSION MANAGER
// =====================================================================

//--- Check if current time is within session for today
bool IsInSession()
{
   if(!TradeCustomTimes) return true;

   MqlDateTime dt;
   TimeCurrent(dt);
   int dayOfWeek = dt.day_of_week; // 0=Sunday, 1=Monday...

   string sessionStr = "";
   switch(dayOfWeek)
   {
      case 1: sessionStr = TradingSessionMonday;    break;
      case 2: sessionStr = TradingSessionTuesday;   break;
      case 3: sessionStr = TradingSessionWednesday;  break;
      case 4: sessionStr = TradingSessionThursday;   break;
      case 5: sessionStr = TradingSessionFriday;     break;
      default: return false; // Saturday/Sunday
   }

   SessionWindow win;
   if(!ParseSession(sessionStr, win)) return false;
   if(!win.Active) return false;

   int nowMinutes = dt.hour * 60 + dt.min;
   int startMin   = win.StartHour * 60 + win.StartMinute;
   int endMin     = win.EndHour * 60 + win.EndMinute;

   if(startMin <= endMin)
      return (nowMinutes >= startMin && nowMinutes <= endMin);
   else // overnight session
      return (nowMinutes >= startMin || nowMinutes <= endMin);
}

//--- Check weekend close condition
bool ShouldCloseForWeekend()
{
   if(!CloseForWeekend) return false;

   MqlDateTime dt;
   TimeCurrent(dt);

   if(dt.day_of_week != DayToClose) return false;

   int closeH, closeM;
   if(!ParseTime(TimeToClose, closeH, closeM)) return false;

   int nowMin   = dt.hour * 60 + dt.min;
   int closeMin = closeH * 60 + closeM;

   return (nowMin >= closeMin);
}

//--- Check weekend restart condition
bool ShouldRestartAfterWeekend()
{
   if(!CloseForWeekend) return true;

   MqlDateTime dt;
   TimeCurrent(dt);

   if(dt.day_of_week < DayToRestart) return false;
   if(dt.day_of_week > DayToRestart) return true;

   int restartH, restartM;
   if(!ParseTime(TimeToRestart, restartH, restartM)) return false;

   int nowMin     = dt.hour * 60 + dt.min;
   int restartMin = restartH * 60 + restartM;

   return (nowMin >= restartMin);
}


// =====================================================================
// MODULE: NEWS MANAGER
// =====================================================================

//--- Abstract news detection (user must implement actual calendar feed)
//    This provides the hook; returns false by default if not connected.
//    In production, replace with MQL5 economic calendar API or external feed.
bool IsHighImpactNewsNow()
{
   if(!UseHighImpactNews) return false;

   //--- Check using MQL5 Economic Calendar (MT5 build 2085+)
   datetime now = TimeCurrent();
   datetime from = now - (int)(CloseHoursBeforeNews * 3600);
   datetime to   = now + (int)(PauseHoursAfterNews * 3600);

   MqlCalendarValue values[];
   string currency = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string currency2 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   int count = CalendarValueHistory(values, from, to, NULL, NULL);

   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent event;
      if(!CalendarEventById(values[i].event_id, event)) continue;

      MqlCalendarCountry country;
      if(!CalendarCountryById(event.country_id, country)) continue;

      // Check if high impact and relevant currency
      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         if(country.currency == currency || country.currency == currency2)
            return true;
      }
   }

   return false;
}

//--- News window check for trade management
bool IsInNewsWindow()
{
   return IsHighImpactNewsNow();
}


// =====================================================================
// MODULE: EQUITY GUARD
// =====================================================================

//--- Check daily profit target
bool DailyProfitTargetReached()
{
   if(DailyProfitTarget <= 0) return false;
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dayProfit = currentBalance - g_dailyStartBalance + GetTotalFloatingProfit();
   return (dayProfit >= DailyProfitTarget);
}

//--- Check ultimate target balance
bool UltimateTargetReached()
{
   if(UltimateTargetBalance <= 0) return false;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   return (equity >= UltimateTargetBalance);
}

//--- Check max running loss
bool MaxRunningLossExceeded()
{
   if(MaxRunningLoss <= 0) return false;
   double floating = GetTotalFloatingProfit();
   return (floating <= -MaxRunningLoss);
}

//--- Check global equity stop
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

//--- Master equity guard check — overrides everything
bool EquityGuardCheck()
{
   if(g_equityStopped) return true;

   bool stopped = false;
   string reason = "";

   if(DailyProfitTargetReached())
   {
      stopped = true;
      reason = "Daily profit target reached";
   }
   else if(UltimateTargetReached())
   {
      stopped = true;
      reason = "Ultimate target balance reached";
   }
   else if(MaxRunningLossExceeded())
   {
      stopped = true;
      reason = "Max running loss exceeded";
      g_lossStopped = true;
      g_lossStopTime = TimeCurrent();
   }
   else if(GlobalEquityStopTriggered())
   {
      stopped = true;
      reason = "Global equity stop triggered";
   }

   if(stopped)
   {
      LogMajor("EQUITY GUARD: " + reason);
      CloseAllPositionsBothDirections();
      g_equityStopped = true;
      g_equityStopTime = TimeCurrent();
      g_seqBuy.State  = STATE_STOPPED_BY_EQUITY;
      g_seqSell.State = STATE_STOPPED_BY_EQUITY;
      g_metrics.RiskStopCount++;
      return true;
   }
   return false;
}

//--- Check if EA can restart after loss stop
bool CanRestartAfterLoss()
{
   if(!g_lossStopped) return false;
   if(RestartEAAfterLoss == RESTART_DISABLED) return false;

   datetime now = TimeCurrent();

   if(RestartEAAfterLoss == RESTART_NEXT_DAY)
   {
      MqlDateTime dtNow, dtStop;
      TimeToStruct(now, dtNow);
      TimeToStruct(g_lossStopTime, dtStop);

      if(dtNow.day != dtStop.day || dtNow.mon != dtStop.mon || dtNow.year != dtStop.year)
      {
         int restH, restM;
         if(ParseTime(RestartNextDayAt, restH, restM))
         {
            if(dtNow.hour > restH || (dtNow.hour == restH && dtNow.min >= restM))
               return true;
         }
      }
      return false;
   }

   if(RestartEAAfterLoss == RESTART_AFTER_HOURS)
   {
      double hoursPassed = (double)(now - g_lossStopTime) / 3600.0;
      return (hoursPassed >= RestartAfterHours);
   }
   return false;
}

//--- Reset daily tracking at start of new day
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
      g_dailyResetTime = dayStart;

      if(ResetGlobalEquityStop && g_equityStopped)
      {
         g_equityStopped = false;
         g_equityStopTime = 0;
         LogMajor("Global equity stop reset for new day");
      }
   }
}


// =====================================================================
// MODULE: RISK MANAGER
// =====================================================================

//--- Apply per-trade stop loss
void ApplyStopLoss(ulong ticket, ENUM_POSITION_TYPE posType)
{
   if(StopLoss <= 0) return;

   double slDist = ResolveDistance(StopLoss);
   if(slDist == 0) return;

   if(!PositionSelectByTicket(ticket)) return;
   double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   double currentSL = PositionGetDouble(POSITION_SL);
   double slPrice;

   if(posType == POSITION_TYPE_BUY)
      slPrice = openPrice - slDist;
   else
      slPrice = openPrice + slDist;

   slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   if(MathAbs(currentSL - slPrice) < _Point) return; // already set

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action    = TRADE_ACTION_SLTP;
   req.position  = ticket;
   req.symbol    = _Symbol;
   req.sl        = slPrice;
   req.tp        = 0; // TP managed at sequence level

   if(!OrderSend(req, res))
      Log(2, "SL modify failed for " + IntegerToString((int)ticket) +
          " error=" + IntegerToString(res.retcode));
}

//--- Check min seconds between trades
bool MinTimeBetweenTradesOK(SequenceInfo &seq)
{
   if(MinSecondsBetweenTrades <= 0) return true;
   if(seq.LastTradeTime == 0) return true;
   return ((int)(TimeCurrent() - seq.LastTradeTime) >= MinSecondsBetweenTrades);
}

//--- Check AllowSamePairDirectionTrades
bool DirectionAllowedGlobally(ENUM_POSITION_TYPE posType)
{
   if(AllowSamePairDirectionTrades) return true;

   // Check if another EA on same pair/direction has positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) == MagicNumber) continue; // skip own
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         return false;
   }
   return true;
}


// =====================================================================
// MODULE: ENTRY ENGINE
// =====================================================================

//--- Send a market order
ulong SendMarketOrder(ENUM_POSITION_TYPE posType, double lots, string comment)
{
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);

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
   req.type_filling = ORDER_FILLING_IOC;

   // Try FOK if IOC not available
   long fillMode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fillMode & SYMBOL_FILLING_IOC) == 0)
   {
      if((fillMode & SYMBOL_FILLING_FOK) != 0)
         req.type_filling = ORDER_FILLING_FOK;
      else
         req.type_filling = ORDER_FILLING_RETURN;
   }

   if(!OrderSend(req, res))
   {
      Log(1, "Order failed: " + comment + " error=" + IntegerToString(res.retcode));
      return 0;
   }

   Log(1, "Order opened: " + comment + " ticket=" + IntegerToString((int)res.deal) +
       " lots=" + DoubleToString(lots, 2));
   return res.deal;
}

//--- Check if a new sequence entry signal is valid
bool IsEntrySignalValid(bool isBuy)
{
   // Random delay gate
   if(UseRandomEntryDelay)
   {
      uint rnd = RandomNext();
      if((rnd % 100) < 30) return false; // ~30% chance to delay
   }

   // All indicator filters
   if(!AllFiltersPass(isBuy)) return false;

   return true;
}


// =====================================================================
// MODULE: EXIT ENGINE
// =====================================================================

//--- Check weighted TP for sequence
bool CheckSequenceTP(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(TakeProfit <= 0) return false;
   if(seq.TradeCount <= 0) return false;

   double avgPrice = ComputeWeightedAverage(posType);
   if(avgPrice == 0) return false;

   double tpDist = ResolveDistance(TakeProfit);
   double currentPrice;

   if(posType == POSITION_TYPE_BUY)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if((currentPrice - avgPrice) >= tpDist)
         return true;
   }
   else
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if((avgPrice - currentPrice) >= tpDist)
         return true;
   }
   return false;
}

//--- Check lock profit trigger
bool CheckLockProfit(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(LockProfit <= 0) return false;
   if(seq.TradeCount < LockProfitMinTrades) return false;

   double avgPrice = ComputeWeightedAverage(posType);
   if(avgPrice == 0) return false;

   double lockDist = ResolveDistance(LockProfit);
   double currentPrice;

   if(posType == POSITION_TYPE_BUY)
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   else
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double profitDist;
   if(posType == POSITION_TYPE_BUY)
      profitDist = currentPrice - avgPrice;
   else
      profitDist = avgPrice - currentPrice;

   if(profitDist >= lockDist)
   {
      if(!seq.LockTriggered)
      {
         seq.LockTriggered = true;
         seq.LockReferencePrice = currentPrice;
         seq.TrailingPrice = currentPrice;
         seq.TrailingActive = true;
         LogMajor("Lock profit triggered: " +
                  (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
                  " ref=" + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
         return false; // don't close yet, start trailing
      }
   }
   return false;
}

//--- Check trailing stop for locked sequence
bool CheckTrailingStop(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(TrailingStop <= 0) return false;
   if(!seq.LockTriggered || !seq.TrailingActive) return false;

   double trailDist = ResolveDistance(TrailingStop);
   double currentPrice;

   if(posType == POSITION_TYPE_BUY)
   {
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      // Price moved higher — update trailing
      if(currentPrice > seq.TrailingPrice)
      {
         seq.TrailingPrice = currentPrice;
         LogDebug("Trailing updated BUY: " + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
      }

      // Price dropped below trailing by trailDist — close
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
      currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(currentPrice < seq.TrailingPrice)
      {
         seq.TrailingPrice = currentPrice;
         LogDebug("Trailing updated SELL: " + DoubleToString(currentPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
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

//--- Determine if bar-close checks are due
bool IsBarCloseCheck(ENUM_LOCK_CHECK_MODE mode)
{
   if(mode == EVERY_TICK) return true;

   if(mode == BAR_CLOSE_CHART)
   {
      datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
      if(barTime != g_lastBarTimeChart)
      {
         g_lastBarTimeChart = barTime;
         return true;
      }
      return false;
   }

   if(mode == BAR_CLOSE_M1)
   {
      datetime barTime = iTime(_Symbol, PERIOD_M1, 0);
      if(barTime != g_lastBarTimeM1)
      {
         g_lastBarTimeM1 = barTime;
         return true;
      }
      return false;
   }
   return true;
}


// =====================================================================
// MODULE: SEQUENCE MANAGER
// =====================================================================

//--- Reconstruct sequence state from open positions (for restart)
void ReconstructSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   seq.Reset();

   int count = CountPositions(posType);
   if(count == 0)
   {
      seq.State = STATE_IDLE;
      return;
   }

   seq.TradeCount       = count;
   seq.Level            = count; // approximate
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots        = GetTotalLots(posType);
   seq.State            = STATE_BUILDING;
   seq.DepthHistory     = count;

   // Find earliest trade time
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
            " sequence: " + IntegerToString(count) + " trades, avg=" +
            DoubleToString(seq.WeightedAvgPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
}

//--- Open first trade of a new sequence
bool OpenFirstTrade(bool isBuy)
{
   ENUM_POSITION_TYPE posType = isBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   // Direction checks
   if(TradeDirection == LONG_ONLY  && !isBuy) return false;
   if(TradeDirection == SHORT_ONLY && isBuy)  return false;

   // Reverse direction if enabled
   bool actualBuy = isBuy;
   if(ReverseSequenceDirection) actualBuy = !actualBuy;
   posType = actualBuy ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   // Max orders check
   if(CountPositions(posType) >= MaxOrdersPerDirection) return false;

   // Same pair direction check
   if(!DirectionAllowedGlobally(posType)) return false;

   // Use the correct direction's sequence info
   if(actualBuy)
      return OpenFirstTradeImpl(posType, g_seqBuy, actualBuy);
   else
      return OpenFirstTradeImpl(posType, g_seqSell, actualBuy);
}

//--- Implementation body for opening first trade
bool OpenFirstTradeImpl(ENUM_POSITION_TYPE posType, SequenceInfo &seq, bool actualBuy)
{
   // Min time check
   if(!MinTimeBetweenTradesOK(seq)) return false;

   // Live delay handling
   if(LiveDelay > 0)
   {
      seq.LiveDelayCounter = 1;
      seq.LiveDelayAccumLots = ComputeLotForLevel(0);
      seq.State = STATE_BUILDING;
      seq.Level = 1;
      seq.SequenceStartTime = TimeCurrent();
      seq.FirstRealTradeAfterLD = false;
      LogMajor("Sequence started (LiveDelay active): " +
               (actualBuy ? "BUY" : "SELL") + " delayed level 1");
      return true;
   }

   // Normal first trade
   double lot = ComputeLotForLevel(0);
   string comment = TradeComment + (actualBuy ? "_B" : "_S") + "_L0";
   ulong ticket = SendMarketOrder(posType, lot, comment);
   if(ticket == 0) return false;

   // Apply SL to this trade
   Sleep(100);
   ApplyStopLossToLatest(posType);

   seq.State = STATE_BUILDING;
   seq.Level = 1;
   seq.TradeCount = 1;
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots = lot;
   seq.LastTradeTime = TimeCurrent();
   seq.SequenceStartTime = TimeCurrent();
   seq.DepthHistory = 1;

   LogMajor("New sequence started: " + (actualBuy ? "BUY" : "SELL") +
            " lots=" + DoubleToString(lot, 2));
   return true;
}

//--- Apply SL to most recently opened position
void ApplyStopLossToLatest(ENUM_POSITION_TYPE posType)
{
   if(StopLoss <= 0) return;

   datetime latest = 0;
   ulong    latestTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) != posType) continue;

      datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
      if(openTime > latest)
      {
         latest = openTime;
         latestTicket = ticket;
      }
   }

   if(latestTicket > 0)
      ApplyStopLoss(latestTicket, posType);
}

//--- Open next grid trade in sequence
bool OpenGridTrade(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(seq.State != STATE_BUILDING) return false;
   if(seq.Level >= MaxOrdersPerDirection) return false;
   if(!MinTimeBetweenTradesOK(seq)) return false;

   // Live delay logic
   if(LiveDelay > 0 && seq.LiveDelayCounter < LiveDelay)
   {
      // Still in delay phase — accumulate but don't place
      double lot = ComputeLotForLevel(seq.Level);
      seq.LiveDelayAccumLots += lot;
      seq.LiveDelayCounter++;
      seq.Level++;
      LogVerbose("LiveDelay accumulate level " + IntegerToString(seq.Level) +
                 " lots=" + DoubleToString(lot, 2) + " total=" +
                 DoubleToString(seq.LiveDelayAccumLots, 2));
      return true;
   }

   // Live delay threshold reached — place accumulated + current
   if(LiveDelay > 0 && seq.LiveDelayCounter == LiveDelay && !seq.FirstRealTradeAfterLD)
   {
      double currentLot = ComputeLotForLevel(seq.Level);
      double totalLots = seq.LiveDelayAccumLots + currentLot;

      // Double-check filters if required
      bool isBuy = (posType == POSITION_TYPE_BUY);
      if(!DoubleCheckFilters(isBuy))
      {
         LogVerbose("LiveDelay double-check failed, waiting");
         return false;
      }

      if(CombineLiveDelayTrades)
      {
         // One trade with sum lots
         string comment = TradeComment + (isBuy ? "_B" : "_S") + "_LD_combined";
         ulong ticket = SendMarketOrder(posType, totalLots, comment);
         if(ticket == 0) return false;
         Sleep(100);
         ApplyStopLossToLatest(posType);
      }
      else
      {
         // Place individual trades for each delayed level
         for(int lvl = 0; lvl <= seq.Level; lvl++)
         {
            double lvlLot = ComputeLotForLevel(lvl);
            string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(lvl);
            ulong ticket = SendMarketOrder(posType, lvlLot, comment);
            if(ticket > 0)
            {
               Sleep(100);
               ApplyStopLossToLatest(posType);
            }
         }
      }

      seq.FirstRealTradeAfterLD = true;
      seq.TradeCount = CountPositions(posType);
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots = GetTotalLots(posType);
      seq.LastTradeTime = TimeCurrent();
      seq.Level++;

      LogMajor("LiveDelay burst placed: " + (isBuy ? "BUY" : "SELL") +
               " trades=" + IntegerToString(seq.TradeCount));
      return true;
   }

   // First trade after LiveDelay — apply multiplier
   if(LiveDelay > 0 && seq.FirstRealTradeAfterLD)
   {
      double lot = ComputeLotForLevel(seq.Level);

      // Apply LD multiplier to first trade after delay only once
      if(!seq.LDMultiplierApplied && LotMultiplierFirstTradeAfterLD != 1.0)
      {
         lot *= LotMultiplierFirstTradeAfterLD;
         lot = NormalizeLot(lot);
         if(MaxLotSize > 0) lot = MathMin(lot, MaxLotSize);
         seq.LDMultiplierApplied = true;
         LogVerbose("LD multiplier applied: " + DoubleToString(lot, 2));
      }

      bool isBuy = (posType == POSITION_TYPE_BUY);
      string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(seq.Level);
      ulong ticket = SendMarketOrder(posType, lot, comment);
      if(ticket == 0) return false;
      Sleep(100);
      ApplyStopLossToLatest(posType);

      seq.TradeCount = CountPositions(posType);
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots = GetTotalLots(posType);
      seq.LastTradeTime = TimeCurrent();
      seq.Level++;
      if(seq.Level > seq.DepthHistory) seq.DepthHistory = seq.Level;
      // Reset the LD flag after first post-LD trade
      seq.FirstRealTradeAfterLD = false;
      return true;
   }

   // Normal grid trade (no LiveDelay or past LD phase)
   double lot = ComputeLotForLevel(seq.Level);
   bool isBuy = (posType == POSITION_TYPE_BUY);
   string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(seq.Level);
   ulong ticket = SendMarketOrder(posType, lot, comment);
   if(ticket == 0) return false;
   Sleep(100);
   ApplyStopLossToLatest(posType);

   seq.TradeCount = CountPositions(posType);
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots = GetTotalLots(posType);
   seq.LastTradeTime = TimeCurrent();
   seq.Level++;
   if(seq.Level > seq.DepthHistory) seq.DepthHistory = seq.Level;

   LogVerbose("Grid trade opened: " + (isBuy ? "BUY" : "SELL") +
              " level=" + IntegerToString(seq.Level) +
              " lots=" + DoubleToString(lot, 2));
   return true;
}

//--- Close entire sequence
void CloseSequence(ENUM_POSITION_TYPE posType, SequenceInfo &seq, string reason)
{
   LogMajor("Closing sequence " + (posType == POSITION_TYPE_BUY ? "BUY" : "SELL") +
            " reason=" + reason + " depth=" + IntegerToString(seq.Level) +
            " trades=" + IntegerToString(seq.TradeCount));

   CloseAllPositions(posType);

   // Update metrics
   g_metrics.TotalSequences++;
   if(seq.DepthHistory > g_metrics.MaxDepth)
      g_metrics.MaxDepth = seq.DepthHistory;
   g_sequenceDepthSum += seq.DepthHistory;
   if(seq.SequenceStartTime > 0)
      g_sequenceDurationSum += (int)(TimeCurrent() - seq.SequenceStartTime);
   if(g_metrics.TotalSequences > 0)
   {
      g_metrics.AvgDepth    = (double)g_sequenceDepthSum / g_metrics.TotalSequences;
      g_metrics.AvgDuration = (double)g_sequenceDurationSum / g_metrics.TotalSequences;
   }

   // Track max DD
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = balance - equity;
   if(dd > g_metrics.MaxDD)
      g_metrics.MaxDD = dd;

   seq.Reset();
}


// =====================================================================
// MODULE: MAIN STATE MACHINE
// =====================================================================

//--- Process a single direction's sequence
void ProcessSequence(bool isBuyDirection)
{
   ENUM_POSITION_TYPE posType = isBuyDirection ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;

   if(isBuyDirection)
      ProcessSequenceImpl(posType, g_seqBuy, isBuyDirection);
   else
      ProcessSequenceImpl(posType, g_seqSell, isBuyDirection);
}

//--- Implementation body for processing a sequence
void ProcessSequenceImpl(ENUM_POSITION_TYPE posType, SequenceInfo &seq, bool isBuyDirection)
{
   // Sync trade count from actual positions (resilience)
   int actualCount = CountPositions(posType);

   // === STATE: IDLE ===
   if(seq.State == STATE_IDLE)
   {
      if(!AllowNewSequence) return;
      if(actualCount > 0)
      {
         // Positions exist but state is idle — reconstruct
         ReconstructSequence(posType, seq);
         return;
      }

      // Direction allowed?
      if(TradeDirection == LONG_ONLY  && !isBuyDirection) return;
      if(TradeDirection == SHORT_ONLY && isBuyDirection)  return;

      // Check entry signal
      if(IsEntrySignalValid(isBuyDirection))
      {
         OpenFirstTrade(isBuyDirection);
      }
      return;
   }

   // === STATE: BUILDING ===
   if(seq.State == STATE_BUILDING)
   {
      // If all positions gone unexpectedly, reset
      if(actualCount == 0 && seq.TradeCount > 0 &&
         (LiveDelay == 0 || seq.LiveDelayCounter >= LiveDelay))
      {
         LogMajor("Sequence cleared externally: " +
                  (isBuyDirection ? "BUY" : "SELL"));
         // Count this as a completed sequence
         g_metrics.TotalSequences++;
         g_sequenceDepthSum += seq.DepthHistory;
         if(seq.SequenceStartTime > 0)
            g_sequenceDurationSum += (int)(TimeCurrent() - seq.SequenceStartTime);
         if(g_metrics.TotalSequences > 0)
         {
            g_metrics.AvgDepth    = (double)g_sequenceDepthSum / g_metrics.TotalSequences;
            g_metrics.AvgDuration = (double)g_sequenceDurationSum / g_metrics.TotalSequences;
         }
         seq.Reset();
         return;
      }

      // Update sequence info from live positions
      if(actualCount > 0)
      {
         seq.TradeCount       = actualCount;
         seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
         seq.TotalLots        = GetTotalLots(posType);
      }

      //--- EXIT CHECKS (priority order) ---

      // 1. TP check
      if(CheckSequenceTP(posType, seq))
      {
         CloseSequence(posType, seq, "TakeProfit");
         return;
      }

      // 2. Lock profit check (bar-close gated)
      if(IsBarCloseCheck(LockProfitCheckMode))
         CheckLockProfit(posType, seq);

      // 3. Trailing stop check (bar-close gated)
      if(seq.LockTriggered && IsBarCloseCheck(TrailingCheckMode))
      {
         if(CheckTrailingStop(posType, seq))
         {
            CloseSequence(posType, seq, "TrailingStop");
            return;
         }
         seq.State = STATE_LOCKED; // transition to locked state
      }

      // 4. Grid expansion check
      if(GridShouldOpenNext(posType, seq))
      {
         if(seq.Level < MaxOrdersPerDirection)
         {
            OpenGridTrade(posType, seq);
         }
      }
      return;
   }

   // === STATE: LOCKED ===
   if(seq.State == STATE_LOCKED)
   {
      if(actualCount == 0)
      {
         seq.Reset();
         return;
      }

      // Update
      seq.TradeCount       = actualCount;
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots        = GetTotalLots(posType);

      // TP still applies
      if(CheckSequenceTP(posType, seq))
      {
         CloseSequence(posType, seq, "TakeProfit");
         return;
      }

      // Trailing check
      if(IsBarCloseCheck(TrailingCheckMode))
      {
         if(CheckTrailingStop(posType, seq))
         {
            CloseSequence(posType, seq, "TrailingStop");
            return;
         }
      }
      return;
   }

   // === STATE: PAUSED (session/news) ===
   if(seq.State == STATE_PAUSED_BY_SESSION || seq.State == STATE_PAUSED_BY_NEWS)
   {
      // No new trades, but manage exits
      if(actualCount == 0)
      {
         seq.Reset();
         return;
      }

      // Still check TP & trailing
      if(CheckSequenceTP(posType, seq))
      {
         CloseSequence(posType, seq, "TakeProfit(paused)");
         return;
      }
      if(seq.LockTriggered)
      {
         CheckLockProfit(posType, seq);
         if(CheckTrailingStop(posType, seq))
         {
            CloseSequence(posType, seq, "TrailingStop(paused)");
            return;
         }
      }
      return;
   }

   // === STOPPED STATES — do nothing ===
}


// =====================================================================
// EA LIFECYCLE: OnInit
// =====================================================================

int OnInit()
{
   // Validate inputs
   if(MagicNumber <= 0)
   {
      Print("ERROR: MagicNumber must be > 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   // Determine pip multiplier (5-digit vs 4-digit)
   int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      g_pipMultiplier = 10;
   else
      g_pipMultiplier = 1;

   // Initialize indicators
   if(!IndicatorFiltersInit())
   {
      Print("ERROR: Failed to initialize indicators");
      return INIT_FAILED;
   }

   // Initialize PRNG
   g_randomState = (uint)RandomSeed;
   if(g_randomState == 0) g_randomState = 1;

   // Reset metrics
   g_metrics.Reset();
   g_sequenceDurationSum = 0;
   g_sequenceDepthSum    = 0;

   // Initialize daily balance tracking
   g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_dailyResetTime    = 0;
   g_globalEquityHigh  = AccountInfoDouble(ACCOUNT_EQUITY);

   // Reset sequence states
   g_seqBuy.Reset();
   g_seqSell.Reset();

   // Reconstruct from existing positions
   ReconstructSequence(POSITION_TYPE_BUY,  g_seqBuy);
   ReconstructSequence(POSITION_TYPE_SELL, g_seqSell);

   // Reset flags
   g_weekendClosed = false;
   g_equityStopped = false;
   g_lossStopped   = false;
   g_lastBarTimeChart = 0;
   g_lastBarTimeM1    = 0;

   LogMajor("ArchAngelX initialized on " + _Symbol +
            " magic=" + IntegerToString((int)MagicNumber) +
            " pipMult=" + IntegerToString(g_pipMultiplier));

   return INIT_SUCCEEDED;
}


// =====================================================================
// EA LIFECYCLE: OnDeinit
// =====================================================================

void OnDeinit(const int reason)
{
   IndicatorFiltersDeInit();
   LogMajor("ArchAngelX deinitialized, reason=" + IntegerToString(reason));
}


// =====================================================================
// EA LIFECYCLE: OnTick — MAIN STATE MACHINE DISPATCHER
// =====================================================================

void OnTick()
{
   //--- 0. Daily reset check
   CheckDailyReset();

   //--- 1. EQUITY GUARD — overrides everything
   if(EquityGuardCheck()) return;

   //--- 1b. Check restart after loss
   if(g_lossStopped || g_equityStopped)
   {
      if(g_lossStopped && CanRestartAfterLoss())
      {
         g_lossStopped   = false;
         g_equityStopped = false;
         g_seqBuy.State  = STATE_IDLE;
         g_seqSell.State = STATE_IDLE;
         LogMajor("Restarting after loss stop");
      }
      else
         return; // stay stopped
   }

   //--- 2. WEEKEND CHECK
   if(CloseForWeekend)
   {
      if(ShouldCloseForWeekend() && !g_weekendClosed)
      {
         LogMajor("Weekend close triggered");
         CloseAllPositionsBothDirections();
         g_seqBuy.Reset();
         g_seqSell.Reset();
         g_weekendClosed = true;
         return;
      }

      if(g_weekendClosed)
      {
         if(ShouldRestartAfterWeekend())
         {
            g_weekendClosed = false;
            LogMajor("Weekend restart");
         }
         else
            return;
      }
   }

   //--- 3. NEWS CHECK
   if(UseHighImpactNews)
   {
      if(IsInNewsWindow())
      {
         if(NewsTradesAction == NEWS_CLOSE_ALL_DISABLE)
         {
            if(g_seqBuy.State != STATE_PAUSED_BY_NEWS || g_seqSell.State != STATE_PAUSED_BY_NEWS)
            {
               LogMajor("News: closing all and disabling");
               CloseAllPositionsBothDirections();
               g_seqBuy.Reset();
               g_seqSell.Reset();
               g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
               g_seqSell.State = STATE_PAUSED_BY_NEWS;
            }
            return;
         }
         else // MANAGE_SEQUENCE
         {
            // Don't open new, but manage existing
            if(g_seqBuy.State == STATE_IDLE)
               g_seqBuy.State = STATE_PAUSED_BY_NEWS;
            if(g_seqSell.State == STATE_IDLE)
               g_seqSell.State = STATE_PAUSED_BY_NEWS;

            // Still process active sequences for exits
            if(g_seqBuy.State == STATE_BUILDING || g_seqBuy.State == STATE_LOCKED)
               ProcessSequence(true);
            if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED)
               ProcessSequence(false);
            return;
         }
      }
      else
      {
         // News window cleared — resume paused
         if(g_seqBuy.State == STATE_PAUSED_BY_NEWS)
         {
            g_seqBuy.State = (CountPositions(POSITION_TYPE_BUY) > 0) ? STATE_BUILDING : STATE_IDLE;
         }
         if(g_seqSell.State == STATE_PAUSED_BY_NEWS)
         {
            g_seqSell.State = (CountPositions(POSITION_TYPE_SELL) > 0) ? STATE_BUILDING : STATE_IDLE;
         }
      }
   }

   //--- 4. SESSION CHECK
   if(TradeCustomTimes)
   {
      if(!IsInSession())
      {
         switch(ActionAtEndOfSession)
         {
            case CLOSE_ALL_TRADES:
               if(g_seqBuy.State != STATE_PAUSED_BY_SESSION)
               {
                  LogMajor("Session end: closing all");
                  if(CountPositions(POSITION_TYPE_BUY) > 0)
                     CloseAllPositions(POSITION_TYPE_BUY);
                  g_seqBuy.Reset();
                  g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               }
               if(g_seqSell.State != STATE_PAUSED_BY_SESSION)
               {
                  if(CountPositions(POSITION_TYPE_SELL) > 0)
                     CloseAllPositions(POSITION_TYPE_SELL);
                  g_seqSell.Reset();
                  g_seqSell.State = STATE_PAUSED_BY_SESSION;
               }
               return;

            case WAIT_SEQUENCE_CLOSE:
               // Process active sequences for exits only, no new
               if(g_seqBuy.State == STATE_BUILDING || g_seqBuy.State == STATE_LOCKED)
                  ProcessSequence(true);
               if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED)
                  ProcessSequence(false);
               // Block new sequences
               if(g_seqBuy.State == STATE_IDLE) g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_IDLE) g_seqSell.State = STATE_PAUSED_BY_SESSION;
               return;

            case PAUSE_OPEN_SEQUENCE:
               if(g_seqBuy.State == STATE_BUILDING)
                  g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_BUILDING)
                  g_seqSell.State = STATE_PAUSED_BY_SESSION;
               if(g_seqBuy.State == STATE_IDLE)
                  g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_IDLE)
                  g_seqSell.State = STATE_PAUSED_BY_SESSION;
               // Still manage locked sequences
               if(g_seqBuy.State == STATE_LOCKED)
                  ProcessSequence(true);
               if(g_seqSell.State == STATE_LOCKED)
                  ProcessSequence(false);
               return;
         }
      }
      else
      {
         // Session active — resume paused states
         if(g_seqBuy.State == STATE_PAUSED_BY_SESSION)
         {
            g_seqBuy.State = (CountPositions(POSITION_TYPE_BUY) > 0) ? STATE_BUILDING : STATE_IDLE;
            LogVerbose("BUY sequence resumed from session pause");
         }
         if(g_seqSell.State == STATE_PAUSED_BY_SESSION)
         {
            g_seqSell.State = (CountPositions(POSITION_TYPE_SELL) > 0) ? STATE_BUILDING : STATE_IDLE;
            LogVerbose("SELL sequence resumed from session pause");
         }
      }
   }

   //--- 5. PROCESS SEQUENCES (both directions)
   // Track max drawdown
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_globalEquityHigh)
      g_globalEquityHigh = equity;
   double currentDD = g_globalEquityHigh - equity;
   if(currentDD > g_metrics.MaxDD)
      g_metrics.MaxDD = currentDD;

   ProcessSequence(true);   // BUY direction
   ProcessSequence(false);  // SELL direction
}


// =====================================================================
// EA LIFECYCLE: OnTester — Print optimization metrics
// =====================================================================

double OnTester()
{
   Print("=== ArchAngelX Optimization Metrics ===");
   Print("TotalSequences:  ", g_metrics.TotalSequences);
   Print("MaxDepth:        ", g_metrics.MaxDepth);
   Print("AvgDepth:        ", DoubleToString(g_metrics.AvgDepth, 2));
   Print("AvgDuration(s):  ", DoubleToString(g_metrics.AvgDuration, 1));
   Print("MaxDD:           ", DoubleToString(g_metrics.MaxDD, 2));
   Print("RiskStopCount:   ", g_metrics.RiskStopCount);
   Print("==========================================");

   // Return custom metric for optimizer
   // Profit factor weighted by inverse of max DD
   double profit = TesterStatistics(STAT_PROFIT);
   double maxDD  = TesterStatistics(STAT_EQUITY_DD);
   if(maxDD == 0) maxDD = 1;

   double score = profit / maxDD;
   if(g_metrics.RiskStopCount > 0)
      score *= 0.5; // penalize risk stops

   return score;
}


// =====================================================================
// EA LIFECYCLE: OnTrade — Track position changes
// =====================================================================

void OnTrade()
{
   // Sync sequence states when trades change (SL hit externally, etc.)
   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);

   if(g_seqBuy.State == STATE_BUILDING || g_seqBuy.State == STATE_LOCKED)
   {
      if(buyCount == 0)
      {
         LogMajor("BUY sequence closed (external/SL)");
         g_metrics.TotalSequences++;
         g_sequenceDepthSum += g_seqBuy.DepthHistory;
         if(g_seqBuy.SequenceStartTime > 0)
            g_sequenceDurationSum += (int)(TimeCurrent() - g_seqBuy.SequenceStartTime);
         if(g_metrics.TotalSequences > 0)
         {
            g_metrics.AvgDepth    = (double)g_sequenceDepthSum / g_metrics.TotalSequences;
            g_metrics.AvgDuration = (double)g_sequenceDurationSum / g_metrics.TotalSequences;
         }
         g_seqBuy.Reset();
      }
      else
      {
         g_seqBuy.TradeCount = buyCount;
      }
   }

   if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED)
   {
      if(sellCount == 0)
      {
         LogMajor("SELL sequence closed (external/SL)");
         g_metrics.TotalSequences++;
         g_sequenceDepthSum += g_seqSell.DepthHistory;
         if(g_seqSell.SequenceStartTime > 0)
            g_sequenceDurationSum += (int)(TimeCurrent() - g_seqSell.SequenceStartTime);
         if(g_metrics.TotalSequences > 0)
         {
            g_metrics.AvgDepth    = (double)g_sequenceDepthSum / g_metrics.TotalSequences;
            g_metrics.AvgDuration = (double)g_sequenceDurationSum / g_metrics.TotalSequences;
         }
         g_seqSell.Reset();
      }
      else
      {
         g_seqSell.TradeCount = sellCount;
      }
   }
}

//+------------------------------------------------------------------+
