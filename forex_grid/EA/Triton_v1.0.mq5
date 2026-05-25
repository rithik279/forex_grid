//+------------------------------------------------------------------+
//|                                                  Triton_v1.0.mq5  |
//|                           Regime-Aware Grid Sequencing EA        |
//|                                          Version 1.0 — May 2026  |
//+------------------------------------------------------------------+
//
// SERAPHIM — Grid-based basket mean reversion system for MT5.
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
#property version   "1.00"
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

enum ENUM_SESSION_END_ACTION
{
   COMPLETE_SEQUENCE  = 0, // Complete the sequence
   CLOSE_ALL_TRADES   = 1, // Close all trades
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
   EQUITY_RISKED_PERCENT  = 1  // Risked Percentage
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

enum ENUM_NEWS_ACTION
{
   NEWS_COMPLETE_SEQUENCE = 0, // Complete the sequence
   NEWS_CLOSE_ALL         = 1, // Close all trades
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
input int      DayToClose               = 5;               // Day to Close (1=Mon..5=Fri)
input string   TimeToClose              = "21:00";         // Time to Close
input int      DayToRestart             = 1;               // Day to Restart (1=Mon)
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
input bool     ResetGlobalEquityStop    = false;           // Reset Global Equity Stop Daily
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
   int      DepthHistory;
   bool     FirstRealTradeAfterLD;
   bool     LDMultiplierApplied;
   int      DelayBarCounter;

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
      DepthHistory        = 0;
      FirstRealTradeAfterLD = false;
      LDMultiplierApplied   = false;
      DelayBarCounter     = 0;
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
datetime  g_lastEntryBarTime  = 0;    // for DelayTradeSequence
double    g_dailyStartBalance = 0.0;
datetime  g_dailyResetTime    = 0;
bool      g_weekendClosed     = false;
bool      g_equityStopped     = false;
bool      g_lossStopped       = false;
datetime  g_lossStopTime      = 0;
bool      g_targetReached     = false;
double    g_globalEquityHigh  = 0.0;
uint      g_randomState       = 0;
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
   return NormalizeDouble(lots, 2);
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
   double rawStep = MathAbs(PipStep) * MathPow(PipStepExponent, (double)level);
   if(MaxPipStep > 0 && rawStep > MaxPipStep)
      rawStep = MaxPipStep;
   // Preserve sign so ResolveDistance knows ATR mode
   double signedStep = (PipStep < 0) ? -rawStep : rawStep;
   return ResolveDistance(signedStep);
}

bool GridShouldOpenNext(ENUM_POSITION_TYPE posType, SequenceInfo &seq)
{
   if(seq.Level <= 0) return false;
   double worstPrice = GetWorstPrice(posType);
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
      double baseLot = (balance / InitialAccountBalanceThreshold) *
                       ((RiskPercentForCompounding / 100.0 * balance) / (RiskInPips * pipVal));
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
   if(MaxLotSize > 0) lot = MathMin(lot, MaxLotSize);
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

   if(adxMain[0] < ADXThreshold) return false;

   bool bullTrend = (adxPlus[0] > adxMinus[0]);
   bool bearTrend = (adxMinus[0] > adxPlus[0]);

   if(ADXTrendRule == ADX_WITH_TREND_ONLY)
   {
      return isBuy ? bullTrend : bearTrend;
   }
   else
   {
      return isBuy ? !bearTrend : !bullTrend;
   }
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

bool IsNewBarOnChart()
{
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime != g_lastEntryBarTime)
   {
      g_lastEntryBarTime = barTime;
      return true;
   }
   return false;
}


// =====================================================================
// MODULE: NEWS MANAGER
// =====================================================================

bool IsHighImpactNewsNow()
{
   if(!UseHighImpactNews) return false;

   datetime now  = TimeCurrent();
   datetime from = now - (datetime)(CloseMinutesBeforeNews * 60);
   datetime to   = now + (datetime)(PauseMinutesAfterNews  * 60);

   MqlCalendarValue values[];
   string currency  = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string currency2 = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   int count = CalendarValueHistory(values, from, to, NULL, NULL);
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent   event;
      MqlCalendarCountry country;
      if(!CalendarEventById(values[i].event_id, event))   continue;
      if(!CalendarCountryById(event.country_id, country)) continue;
      if(event.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         if(country.currency == currency || country.currency == currency2)
            return true;
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
   return (GetTotalFloatingProfit() <= -MaxRunningLoss);
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
      case EQUITY_RISKED_PERCENT:
      {
         if(balance == 0) return false;
         double pctLoss = ((balance - equity) / balance) * 100.0;
         return (pctLoss >= GlobalEquityStopValue);
      }
   }
   return false;
}

bool EquityGuardCheck()
{
   if(g_equityStopped) return true;

   bool   stopped = false;
   string reason  = "";

   if(DailyProfitTargetReached())
   {
      stopped = true;
      reason  = "Daily profit target reached";
      g_metrics.DailyTargetHits++;
   }
   else if(UltimateTargetReached())
   {
      stopped = true;
      reason  = "Ultimate target balance reached";
   }
   else if(MaxRunningLossExceeded())
   {
      stopped       = true;
      reason        = "Max running loss exceeded";
      g_lossStopped = true;
      g_lossStopTime = TimeCurrent();
      g_metrics.DailyLossHits++;
   }
   else if(GlobalEquityStopTriggered())
   {
      stopped = true;
      reason  = "Global equity stop triggered";
   }

   if(stopped)
   {
      LogMajor("EQUITY GUARD: " + reason);
      CloseAllPositionsBothDirections();
      g_equityStopped   = true;
      g_seqBuy.State    = STATE_STOPPED_BY_EQUITY;
      g_seqSell.State   = STATE_STOPPED_BY_EQUITY;
      g_metrics.RiskStopCount++;
      return true;
   }
   return false;
}

bool CanRestartAfterLoss()
{
   if(!g_lossStopped) return false;

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
      g_targetReached     = false;

      if(ResetGlobalEquityStop && g_equityStopped)
      {
         g_equityStopped = false;
         LogMajor("Global equity stop reset for new day");
      }
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

bool MinTimeBetweenTradesOK(SequenceInfo &seq)
{
   if(MinSecondsBetweenTrades <= 0) return true;
   if(seq.LastTradeTime == 0) return true;
   return ((int)(TimeCurrent() - seq.LastTradeTime) >= MinSecondsBetweenTrades);
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
   // V1 stub: UseRandomEntryDelay captured but not implemented
   if(UseRandomEntryDelay)
   {
      uint rnd = RandomNext();
      if((rnd % 100) < 30) return false;
   }
   return AllFiltersPass(isBuy);
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
   if(!MinTimeBetweenTradesOK(seq)) return false;

   if(LiveDelay > 0)
   {
      seq.LiveDelayCounter   = 1;
      seq.LiveDelayAccumLots = ComputeLotForLevel(0);
      seq.State              = STATE_BUILDING;
      seq.Level              = 1;
      seq.SequenceStartTime  = TimeCurrent();
      seq.FirstRealTradeAfterLD = false;
      LogMajor("Seq started (LiveDelay): " + (actualBuy ? "BUY" : "SELL") + " delay lvl 1");
      return true;
   }

   double lot     = ComputeLotForLevel(0);
   string comment = TradeComment + (actualBuy ? "_B" : "_S") + "_L0";
   ulong  ticket  = SendMarketOrder(posType, lot, comment);
   if(ticket == 0) return false;

   Sleep(100);
   ApplyStopLossToLatest(posType);

   seq.State            = STATE_BUILDING;
   seq.Level            = 1;
   seq.TradeCount       = 1;
   seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
   seq.TotalLots        = lot;
   seq.LastTradeTime    = TimeCurrent();
   seq.SequenceStartTime = TimeCurrent();
   seq.DepthHistory     = 1;
   seq.DelayBarCounter  = 0;

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
   if(seq.Level >= MaxOrdersPerDirection) return false;
   if(!MinTimeBetweenTradesOK(seq)) return false;

   bool isBuy = (posType == POSITION_TYPE_BUY);

   // LiveDelay accumulation phase
   if(LiveDelay > 0 && seq.LiveDelayCounter < LiveDelay)
   {
      double lot = ComputeLotForLevel(seq.Level);
      seq.LiveDelayAccumLots += lot;
      seq.LiveDelayCounter++;
      seq.Level++;
      LogVerbose("LD accumulate lvl=" + IntegerToString(seq.Level) +
                 " accum=" + DoubleToString(seq.LiveDelayAccumLots, 2));
      return true;
   }

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
         Sleep(100);
         ApplyStopLossToLatest(posType);
      }
      else
      {
         for(int lvl = 0; lvl <= seq.Level; lvl++)
         {
            double lvlLot  = ComputeLotForLevel(lvl);
            string comment = TradeComment + (isBuy ? "_B" : "_S") + "_L" + IntegerToString(lvl);
            ulong  ticket  = SendMarketOrder(posType, lvlLot, comment);
            if(ticket > 0) { Sleep(100); ApplyStopLossToLatest(posType); }
         }
      }

      seq.FirstRealTradeAfterLD = true;
      seq.TradeCount       = CountPositions(posType);
      seq.WeightedAvgPrice = ComputeWeightedAverage(posType);
      seq.TotalLots        = GetTotalLots(posType);
      seq.LastTradeTime    = TimeCurrent();
      seq.Level++;
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
      Sleep(100);
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
   Sleep(100);
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

   // === IDLE ===
   if(seq.State == STATE_IDLE)
   {
      if(!AllowNewSequence) return;
      if(actualCount > 0)
      {
         ReconstructSequence(posType, seq);
         return;
      }
      if(TradeDirection == LONG_ONLY  && !isBuyDirection) return;
      if(TradeDirection == SHORT_ONLY && isBuyDirection)  return;

      // DelayTradeSequence: require N bars between new sequences
      if(DelayTradeSequence > 0)
      {
         if(!IsNewBarOnChart()) return;
         seq.DelayBarCounter++;
         if(seq.DelayBarCounter < DelayTradeSequence) return;
         seq.DelayBarCounter = 0;
      }

      if(IsEntrySignalValid(isBuyDirection))
         OpenFirstTrade(isBuyDirection);
      return;
   }

   // === BUILDING ===
   if(seq.State == STATE_BUILDING)
   {
      // All positions closed externally (SL hit etc.)
      if(actualCount == 0 && seq.TradeCount > 0 &&
         (LiveDelay == 0 || seq.LiveDelayCounter >= LiveDelay))
      {
         LogMajor("Seq cleared externally: " + (isBuyDirection ? "BUY" : "SELL"));
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

      // Grid expansion
      if(GridShouldOpenNext(posType, seq) && seq.Level < MaxOrdersPerDirection)
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
   if(seq.State == STATE_PAUSED_BY_SESSION || seq.State == STATE_PAUSED_BY_NEWS)
   {
      if(actualCount == 0) { seq.Reset(); return; }
      if(CheckSequenceTP(posType, seq)) { CloseSequence(posType, seq, "TakeProfit(paused)"); return; }
      if(seq.LockTriggered)
      {
         CheckLockProfit(posType, seq);
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

   g_weekendClosed    = false;
   g_equityStopped    = false;
   g_lossStopped      = false;
   g_targetReached    = false;
   g_lastBarTimeChart = 0;
   g_lastBarTimeM1    = 0;
   g_lastEntryBarTime = 0;

   LogMajor("Triton v1.0 initialized: " + _Symbol +
            " magic=" + IntegerToString((int)MagicNumber) +
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
   // 0. Daily reset
   CheckDailyReset();

   // 1. Equity guard — highest priority
   if(EquityGuardCheck()) return;

   // 1b. Restart after loss stop
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
      else return;
   }

   // 2. Weekend close
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
         { g_weekendClosed = false; LogMajor("Weekend restart"); }
         else return;
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
                  g_seqBuy.Reset();  g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
                  g_seqSell.Reset(); g_seqSell.State = STATE_PAUSED_BY_NEWS;
               }
               return;

            case NEWS_PAUSE_SEQUENCE:
               if(g_seqBuy.State  == STATE_IDLE) g_seqBuy.State  = STATE_PAUSED_BY_NEWS;
               if(g_seqSell.State == STATE_IDLE) g_seqSell.State = STATE_PAUSED_BY_NEWS;
               ProcessSequence(true);
               ProcessSequence(false);
               return;

            default: // NEWS_COMPLETE_SEQUENCE — manage exits only, no new entries
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
                  g_seqBuy.Reset(); g_seqBuy.State = STATE_PAUSED_BY_SESSION;
               }
               if(g_seqSell.State != STATE_PAUSED_BY_SESSION)
               {
                  CloseAllPositions(POSITION_TYPE_SELL);
                  g_seqSell.Reset(); g_seqSell.State = STATE_PAUSED_BY_SESSION;
               }
               return;

            case PAUSE_SEQUENCE:
               if(g_seqBuy.State  == STATE_BUILDING) g_seqBuy.State  = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_BUILDING) g_seqSell.State = STATE_PAUSED_BY_SESSION;
               if(g_seqBuy.State  == STATE_IDLE)     g_seqBuy.State  = STATE_PAUSED_BY_SESSION;
               if(g_seqSell.State == STATE_IDLE)     g_seqSell.State = STATE_PAUSED_BY_SESSION;
               if(g_seqBuy.State  == STATE_LOCKED) ProcessSequence(true);
               if(g_seqSell.State == STATE_LOCKED) ProcessSequence(false);
               return;

            default: // COMPLETE_SEQUENCE — manage exits, block new
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
   int buyCount  = CountPositions(POSITION_TYPE_BUY);
   int sellCount = CountPositions(POSITION_TYPE_SELL);

   if(g_seqBuy.State == STATE_BUILDING || g_seqBuy.State == STATE_LOCKED)
   {
      if(buyCount == 0)
      {
         LogMajor("BUY seq closed externally");
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
      else g_seqBuy.TradeCount = buyCount;
   }

   if(g_seqSell.State == STATE_BUILDING || g_seqSell.State == STATE_LOCKED)
   {
      if(sellCount == 0)
      {
         LogMajor("SELL seq closed externally");
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
      else g_seqSell.TradeCount = sellCount;
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
   double ddPct     = TesterStatistics(STAT_EQUITY_DDPERCENT);   // 0–100
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
