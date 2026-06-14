# ArchangelX EA — Complete Technical Specification

## File: `EA/ArchangelX.mq5`

This is the primary build target. A complete, source-owned MQL5 Expert Advisor that replicates the behavior of the ArchAngelX 3.4 black-box EA, with improvements to the risk governor, optimization scoring, and regime filtering.

---

## Architecture Overview

The EA is composed of **5 layers**, executing in strict priority order:

```
Layer 5: EquityGuard (Risk Governor)        ← OVERRIDES EVERYTHING
Layer 4: RegimeFilter (Entry Permission)
Layer 3: GridEngine (Sequence Construction)
Layer 2: BasketExitEngine (Sequence Exit)
Layer 1: OptimizationReporter (OnTester)
```

**State Machine:**
```
IDLE → BUILDING → LOCKED → (exit/close)
Any state → PAUSED_BY_SESSION
Any state → PAUSED_BY_NEWS
Any state → STOPPED_BY_EQUITY (hard stop, no restart same day)
Any state → STOPPED_BY_DAILY_LOSS (reset next day)
Any state → STOPPED_BY_DAILY_TARGET (reset next day)
```

---

## Input Parameters (Complete List)

All inputs must appear in this exact order in the `input group` sections. This controls how they appear in the MT5 inputs dialog and setfile format.

### Group: GENERAL SETTINGS
```mql5
input group "═══ GENERAL SETTINGS ═══"
input bool     AllowNewSequence          = true;
input string   StrategyDescription       = "ArchangelX Grid";
input string   TradeComment              = "AAX";
input long     MagicNumber               = 123456;
input bool     UseRandomEntryDelay       = false;
input int      RandomSeed                = 42;
input int      LogLevel                  = 1;    // 0=silent, 1=major, 2=verbose, 3=debug
```

### Group: SEQUENCE SETTINGS
```mql5
input group "═══ SEQUENCE SETTINGS ═══"
input bool     UseATRForPips             = false;
input int      ATRPeriod                 = 14;
input double   PipStep                   = 10.0;
input double   PipStepExponent           = 1.2;
input double   MaxPipStep                = 0.0;  // 0 = unlimited
input int      DelayTradeSequence        = 0;    // bars to wait before first real trade
input int      LiveDelay                 = 0;    // levels to queue before executing
input double   LotMultiplierFirstTradeAfterLD = 1.0;
input bool     CombineLiveDelayTrades    = true;
input ENUM_TRADE_DIRECTION TradeDirection = BOTH;
input int      MaxOrdersPerDirection     = 20;
input bool     ReverseSequenceDirection  = false;
```

### Group: MONEY MANAGEMENT
```mql5
input group "═══ MONEY MANAGEMENT ═══"
input double   TakeProfit                = 10.0;  // pips from weighted avg entry
input double   StopLoss                  = 0.0;   // per-trade SL, 0=off
input int      LockProfitMinTrades       = 3;
input double   LockProfit                = 5.0;   // pips, 0=off
input ENUM_LOCK_CHECK_MODE LockProfitCheckMode = EVERY_TICK;
input double   TrailingStop              = 3.0;   // pips, 0=off
input ENUM_LOCK_CHECK_MODE TrailingCheckMode   = EVERY_TICK;
input bool     AllowSamePairDirectionTrades = true;
```

### Group: LOT SIZE SETTINGS
```mql5
input group "═══ LOT SIZE SETTINGS ═══"
input double   LotSize                   = 0.01;
input double   RiskPercent               = 0.0;   // 0=off, use fixed lot
input double   LotSizeExponent           = 1.5;
input double   MaxLotSize                = 0.0;   // 0=unlimited
```

### Group: COMPOUND SETTINGS
```mql5
input group "═══ COMPOUND SETTINGS ═══"
input bool     UseCompounding            = false;
input double   InitialAccountBalanceThreshold = 10000.0;
input double   RiskPercentForCompounding = 1.0;
input double   RiskInPips                = 100.0;
input double   MaxLotSizeForCompounding  = 10.0;
```

### Group: EQUITY PROTECTION
```mql5
input group "═══ EQUITY PROTECTION ═══"
input double   MaxRunningLoss            = 0.0;   // per-EA loss limit, 0=off
input ENUM_RESTART_MODE RestartEAAfterLoss = RESTART_NEXT_DAY;
input string   RestartNextDayAt          = "00:00";
input double   RestartAfterHours         = 4.0;
input double   DailyProfitTarget         = 0.0;   // 0=off; set to 1000 for prop firm
input double   UltimateTargetBalance     = 0.0;   // 0=off; "mission complete" switch
input ENUM_EQUITY_STOP_TYPE GlobalEquityStopType = EQUITY_ABSOLUTE;
input double   GlobalEquityStopValue     = 0.0;   // hard equity floor, 0=off
input bool     ResetGlobalEquityStop     = false; // reset daily
input int      MinSecondsBetweenTrades   = 0;
```

### Group: WEEKEND SETTINGS
```mql5
input group "═══ WEEKEND SETTINGS ═══"
input bool     CloseForWeekend           = false;
input int      DayToClose                = 5;     // 1=Mon..5=Fri
input string   TimeToClose               = "20:00";
input int      DayToRestart              = 1;
input string   TimeToRestart             = "01:00";
```

### Group: CUSTOM SESSION SETTINGS
```mql5
input group "═══ CUSTOM SESSION SETTINGS ═══"
input bool     TradeCustomTimes          = false;
input string   TradingSessionMonday      = "00:00-23:59";
input string   TradingSessionTuesday     = "00:00-23:59";
input string   TradingSessionWednesday   = "00:00-23:59";
input string   TradingSessionThursday    = "00:00-23:59";
input string   TradingSessionFriday      = "00:00-23:59";
input ENUM_SESSION_END_ACTION ActionAtEndOfSession = CLOSE_ALL_TRADES;
```

### Group: INDICATOR FILTERS — RSI
```mql5
input group "═══ INDICATOR FILTERS — RSI ═══"
input bool     UseRSI                    = false;
input ENUM_TIMEFRAMES RSITimeframe       = PERIOD_CURRENT;
input int      RSIPeriod                 = 14;
input double   RSIOverboughtLevel        = 70.0;
```

### Group: INDICATOR FILTERS — EMA
```mql5
input group "═══ INDICATOR FILTERS — EMA ═══"
input bool     UseEMA                    = false;
input ENUM_TIMEFRAMES EMATimeframe       = PERIOD_CURRENT;
input int      EMAFast                   = 10;
input int      EMAMid                    = 25;
input int      EMASlow                   = 50;
input ENUM_EMA_TREND_RULE EMATrendRule   = WITH_TREND_ONLY;
input bool     DoubleCheckEMAFirstRealTrade = false;
```

### Group: INDICATOR FILTERS — ADX
```mql5
input group "═══ INDICATOR FILTERS — ADX ═══"
input bool     UseADX                    = false;
input ENUM_TIMEFRAMES ADXTimeframe       = PERIOD_CURRENT;
input int      ADXPeriod                 = 14;
input double   ADXThreshold              = 25.0;
input ENUM_ADX_TREND_RULE ADXTrendRule   = ADX_WITH_TREND_ONLY;
input bool     DoubleCheckADXFirstRealTrade = false;
```

### Group: INDICATOR FILTERS — BOLLINGER BANDS
```mql5
input group "═══ INDICATOR FILTERS — BOLLINGER ═══"
input bool     UseBollinger              = false;
input ENUM_BB_MODE BBMode               = BB_AVOID_EXTREME;
input ENUM_TIMEFRAMES BBTimeframe        = PERIOD_CURRENT;
input int      BBPeriod                  = 20;
input double   BBDeviation               = 2.0;
```

### Group: NEWS FILTER
```mql5
input group "═══ NEWS FILTER ═══"
input bool     UseHighImpactNews         = false;
input ENUM_NEWS_ACTION NewsTradesAction  = NEWS_MANAGE_SEQUENCE;
input double   CloseHoursBeforeNews      = 0.5;
input double   PauseHoursAfterNews       = 0.5;
```

---

## Enumerations

```mql5
enum ENUM_TRADE_DIRECTION
{
   BOTH        = 0,  // Both Directions
   LONG_ONLY   = 1,  // Long Only
   SHORT_ONLY  = 2   // Short Only
};

enum ENUM_LOCK_CHECK_MODE
{
   BAR_CLOSE_CHART = 0,  // Bar Close (Chart TF)
   BAR_CLOSE_M1    = 1,  // Bar Close (M1)
   EVERY_TICK      = 2   // Every Tick
};

enum ENUM_SESSION_END_ACTION
{
   CLOSE_ALL_TRADES    = 0,  // Close All
   WAIT_SEQUENCE_CLOSE = 1,  // Wait Sequence Close
   PAUSE_OPEN_SEQUENCE = 2   // Pause Open Sequence
};

enum ENUM_RESTART_MODE
{
   RESTART_DISABLED    = 0,  // Disabled
   RESTART_NEXT_DAY    = 1,  // Restart Next Day
   RESTART_AFTER_HOURS = 2   // Restart After Hours
};

enum ENUM_EQUITY_STOP_TYPE
{
   EQUITY_ABSOLUTE      = 0,  // Absolute Value
   EQUITY_RISKED_AMOUNT = 1,  // Risked Amount
   EQUITY_RISKED_PERCENT = 2  // Risked Percent
};

enum ENUM_EMA_TREND_RULE
{
   WITH_TREND_ONLY      = 0,  // With Trend Only
   AVOID_OPPOSITE_TREND = 1   // Avoid Opposite Trend
};

enum ENUM_ADX_TREND_RULE
{
   ADX_WITH_TREND_ONLY      = 0,  // With Trend Only
   ADX_AVOID_OPPOSITE_TREND = 1   // Avoid Opposite Trend
};

enum ENUM_BB_MODE
{
   BB_AVOID_EXTREME              = 0,  // Avoid Extreme
   BB_ONLY_EXTREME_COUNTER_TREND = 1   // Only Extreme Counter-Trend
};

enum ENUM_NEWS_ACTION
{
   NEWS_MANAGE_SEQUENCE   = 0,  // Manage Sequence
   NEWS_CLOSE_ALL_DISABLE = 1   // Close All & Disable
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
```

---

## Structs

### SequenceInfo
Tracks one active grid sequence (one per direction: buy and sell).

```mql5
struct SequenceInfo
{
   ENUM_SEQUENCE_STATE State;
   int      Level;                 // current grid depth (0-based)
   int      TradeCount;
   double   WeightedAvgPrice;      // lot-weighted average entry price
   double   TotalLots;             // sum of all lots in sequence
   double   LockReferencePrice;    // price when lock profit triggered
   bool     LockTriggered;
   double   TrailingPrice;         // current trailing stop level
   bool     TrailingActive;
   datetime LastTradeTime;
   datetime SequenceStartTime;
   int      LiveDelayCounter;
   double   LiveDelayAccumLots;
   int      DepthHistory;          // max depth ever reached in this sequence
   bool     FirstRealTradeAfterLD;
   bool     LDMultiplierApplied;

   void Reset() { ... }
};
```

### IndicatorCache
Stores indicator handles (created in OnInit, used in OnTick).

```mql5
struct IndicatorCache
{
   int hRSI;
   int hEMAFast;
   int hEMAMid;
   int hEMASlow;
   int hADX;
   int hBBands;
   int hATR;

   void Reset() { /* set all to INVALID_HANDLE */ }
};
```

### OptimizationMetrics
Accumulated statistics for OnTester() scoring.

```mql5
struct OptimizationMetrics
{
   int    TotalSequences;
   int    MaxDepth;
   double AvgDepth;
   double AvgDuration;       // seconds
   double MaxDD;
   int    RiskStopCount;     // number of times equity/daily stops triggered
   int    DailyTargetHits;   // number of days target was reached
   int    DailyLossHits;     // number of days hard loss was hit

   void Reset() { ... }
};
```

### SessionWindow
Parsed session time.

```mql5
struct SessionWindow
{
   int  StartHour;
   int  StartMinute;
   int  EndHour;
   int  EndMinute;
   bool Active;
};
```

---

## Global State Variables

```mql5
SequenceInfo        g_seqBuy;
SequenceInfo        g_seqSell;
IndicatorCache      g_indicators;
OptimizationMetrics g_metrics;

datetime  g_lastBarTimeChart  = 0;
datetime  g_lastBarTimeM1     = 0;
datetime  g_equityStopTime    = 0;
double    g_dailyStartBalance = 0.0;
datetime  g_dailyResetTime    = 0;
bool      g_weekendClosed     = false;
bool      g_equityStopped     = false;   // hard equity stop hit
bool      g_lossStopped       = false;   // daily loss stop hit
datetime  g_lossStopTime      = 0;
bool      g_targetReached     = false;   // daily target hit
double    g_globalEquityHigh  = 0.0;
uint      g_randomState       = 0;       // deterministic PRNG state
int       g_sequenceDurationSum = 0;
```

---

## Function Architecture

### Layer 5: EquityGuard (called first on every tick)

```mql5
bool CheckEquityGuard()
// Returns true if trading is halted.
// Checks in order:
//   1. GlobalEquityStop (hard account floor)
//   2. Daily profit target reached
//   3. MaxRunningLoss (per-EA running loss)
//   4. Daily loss limit (hard: -5000, soft: -3000 warning)
// On breach:
//   - Closes all positions managed by this EA (by MagicNumber)
//   - Sets appropriate stopped flag
//   - Logs the stop reason
```

```mql5
void CloseAllPositionsByMagic(long magic, string reason)
// Closes every open position with matching MagicNumber.
// Used by equity guard and session end handler.
```

```mql5
void HandleDailyReset()
// Called when broker day changes (00:00 server time).
// Resets: g_dailyStartBalance, g_lossStopped, g_targetReached.
// Optionally restarts EA if RestartMode allows it.
```

### Layer 4: RegimeFilter (entry permission)

```mql5
bool IsWithinSession()
// Returns true if current time is inside any enabled session window.
// Parses "HH:MM-HH:MM" strings for each active weekday.
```

```mql5
bool IsNewsActive()
// Returns true if within CloseHoursBeforeNews or PauseHoursAfterNews
// of a scheduled high-impact news event.
// V1: Uses a manually-maintained news time array (no live feed).
// Future: Connect to economic calendar API.
```

```mql5
bool CheckEMAFilter(ENUM_ORDER_TYPE direction)
// Returns true if EMA alignment permits a new trade in this direction.
// EMAFast > EMAMid > EMASlow = bullish alignment → allow long
// EMAFast < EMAMid < EMASlow = bearish alignment → allow short
// EMATrendRule controls whether to require alignment or just avoid opposite.
```

```mql5
bool CheckADXFilter()
// Returns true if ADX value is within acceptable range.
// ADX > ADXThreshold = trending = allow trend trades
// ADX < ADXThreshold = ranging = allow mean reversion trades
// ADXTrendRule controls interpretation.
```

```mql5
bool CheckRSIFilter(ENUM_ORDER_TYPE direction)
// Returns true if RSI permits entry in this direction.
// RSI > OverboughtLevel = overbought → allow shorts
// RSI < (100 - OverboughtLevel) = oversold → allow longs
```

```mql5
bool CheckBollingerFilter(ENUM_ORDER_TYPE direction)
// Returns true if price position relative to Bollinger Bands permits entry.
// BB_AVOID_EXTREME: block entries near band extremes
// BB_ONLY_EXTREME_COUNTER_TREND: only enter at extremes (mean reversion)
```

```mql5
bool IsEntryAllowed(ENUM_ORDER_TYPE direction)
// Master entry permission check.
// Returns false if ANY of these are true:
//   - EquityGuard is halted
//   - Not in session
//   - News active
//   - EMA filter blocks (if enabled)
//   - ADX filter blocks (if enabled)
//   - RSI filter blocks (if enabled)
//   - Bollinger filter blocks (if enabled)
//   - MaxOrdersPerDirection reached
//   - AllowNewSequence = false
```

### Layer 3: GridEngine (sequence construction)

```mql5
double CalculatePipStep(int level)
// Returns the pip step for grid level N.
// If UseATRForPips: base = ATR(ATRPeriod) * PipStep
// Step for level N = base * PipStepExponent^level
// Capped at MaxPipStep if > 0.
```

```mql5
double CalculateLotSize(int level)
// Returns lot size for grid level N.
// level 0: LotSize (base)
// level N: LotSize * LotSizeExponent^N
// Capped at MaxLotSize if > 0.
// If UseCompounding: scales base lot by equity ratio.
```

```mql5
bool ShouldOpenNewGridTrade(SequenceInfo &seq, ENUM_ORDER_TYPE direction)
// Returns true if price has moved far enough from last trade to warrant a new one.
// Distance check: |CurrentPrice - LastTradePrice| >= CalculatePipStep(seq.Level)
// Also checks: seq.TradeCount < MaxOrdersPerDirection
// Also checks: MinSecondsBetweenTrades elapsed since seq.LastTradeTime
```

```mql5
void OpenGridTrade(SequenceInfo &seq, ENUM_ORDER_TYPE direction)
// Opens a new market order at current price.
// Lot size = CalculateLotSize(seq.Level)
// Comment = TradeComment + "_L" + seq.Level
// MagicNumber = MagicNumber
// Updates seq.Level, seq.TradeCount, seq.WeightedAvgPrice, seq.TotalLots
// Updates seq.LastTradeTime, seq.SequenceStartTime (if level 0)
```

```mql5
void UpdateWeightedAverage(SequenceInfo &seq)
// Recalculates seq.WeightedAvgPrice from all open positions.
// WeightedAvg = sum(lot_i * price_i) / sum(lot_i)
// Must iterate through all open positions with matching MagicNumber + direction.
```

### Layer 2: BasketExitEngine (sequence exit)

```mql5
bool CheckTakeProfit(SequenceInfo &seq, ENUM_ORDER_TYPE direction)
// Returns true if current price has moved TakeProfit pips
// beyond seq.WeightedAvgPrice in the profitable direction.
// TP is measured from weighted average, NOT individual entry prices.
```

```mql5
bool CheckLockProfit(SequenceInfo &seq, ENUM_ORDER_TYPE direction)
// Returns true if lock profit conditions are met:
//   - seq.TradeCount >= LockProfitMinTrades
//   - Current basket profit >= LockProfit pips from weighted avg
// On activation: sets seq.LockTriggered = true, seq.LockReferencePrice
```

```mql5
bool CheckTrailingStop(SequenceInfo &seq, ENUM_ORDER_TYPE direction)
// Returns true if trailing stop has been violated.
// Only active after LockTriggered = true.
// Trailing price moves with favorable price movement.
// If price reverses beyond TrailingStop pips from peak → close basket.
```

```mql5
void CloseSequence(SequenceInfo &seq, ENUM_ORDER_TYPE direction, string reason)
// Closes all positions in this sequence at market.
// Resets seq to STATE_IDLE.
// Updates g_metrics (TotalSequences, MaxDepth, AvgDepth, etc.)
```

```mql5
bool CheckMaxSequenceAge(SequenceInfo &seq)
// Future: close sequence if it has been open too long.
// V1: Not implemented. Placeholder for time-stop.
```

### Layer 1: OptimizationReporter

```mql5
double OnTester()
// Called by MT5 at end of each optimization pass.
// Returns the custom score used for ranking.
//
// Scoring formula:
//   score = NetProfit
//         + (DailyTargetHits * 500)          // reward days target was hit
//         + (ProfitFactor * 200)              // reward consistency
//         - (MaxDD * 2.0)                     // penalize drawdown
//         - (g_metrics.DailyLossHits * 2000)  // heavy penalty for daily loss breaches
//         - (g_metrics.RiskStopCount * 5000)  // massive penalty for equity stop triggers
//         - (g_metrics.MaxDepth * 50)         // penalize deep grids
//         - (g_metrics.AvgDuration / 3600.0 * 10) // penalize long basket holds
//
// This scoring replaces "maximize profit" with "maximize prop-firm survival probability".
```

---

## OnInit() Responsibilities

```
1. Validate all inputs (log errors, return INIT_FAILED if critical)
2. Create indicator handles (RSI, EMA x3, ADX, BB, ATR)
3. Initialize g_seqBuy, g_seqSell to STATE_IDLE
4. Reset g_metrics
5. Set g_dailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE)
6. Set g_dailyResetTime = today at 00:00
7. Parse session strings into SessionWindow structs
8. Initialize deterministic PRNG if UseRandomEntryDelay
9. Log EA parameters at LogLevel >= 1
```

## OnTick() Responsibilities

```
1. HandleDailyReset() if day has changed
2. CheckEquityGuard() → if stopped, return immediately
3. CheckWeekendClose() → if weekend close triggered, close all + return
4. IsWithinSession() → if outside session, handle ActionAtEndOfSession + return
5. IsNewsActive() → if news window, handle NewsTradesAction + return
6. For each direction (Buy, Sell):
   a. CheckTakeProfit → if hit, CloseSequence
   b. CheckLockProfit → if conditions met, activate lock
   c. CheckTrailingStop → if breached, CloseSequence
   d. If sequence is IDLE or BUILDING:
      - IsEntryAllowed(direction) → if false, skip
      - ShouldOpenNewGridTrade → if true, OpenGridTrade
7. Update g_metrics as needed
```

## OnDeinit() Responsibilities

```
1. Release all indicator handles
2. Log final metrics at LogLevel >= 1
```

---

## Critical Implementation Rules

### Determinism (Required for Optimization)
- No dynamic arrays that change unpredictably between ticks
- Random entry delay must use seeded PRNG (not MQL5's random functions)
- All calculations must produce identical results given identical tick data
- No file I/O that could differ between runs

### Weighted Average Calculation
```
WeightedAvg = sum(lot_i × open_price_i) / sum(lot_i)

Must iterate over ALL open positions with:
  - Symbol == _Symbol
  - PositionGetInteger(POSITION_MAGIC) == MagicNumber
  - PositionGetInteger(POSITION_TYPE) == direction (0=buy, 1=sell)
```

### Pip Calculation
```
1 pip = _Point × (symbol has 5 digits? 10 : 1)
For XAUUSD: 1 pip = 0.1 (it has 2 decimal places in price)
Always use SymbolInfoDouble(SYMBOL_POINT) and check digits.
```

### Live Delay Logic
```
If LiveDelay > 0:
  - First LiveDelay trades are "virtual" (tracked but not placed)
  - seq.LiveDelayCounter increments each virtual trade
  - When LiveDelayCounter >= LiveDelay:
    - If CombineLiveDelayTrades: place ONE real trade with accumulated lot
    - Else: place the real trade normally
  - FirstRealTradeAfterLD flag: apply LotMultiplierFirstTradeAfterLD once
```

### Session Parsing
```
Format: "HH:MM-HH:MM"
Example: "08:00-17:00"
Parse into SessionWindow.StartHour, StartMinute, EndHour, EndMinute
Handle midnight crossover: if EndHour < StartHour, spans midnight
```

### Position Management (Trade Server Calls)
```
All trade operations through CTrade class (MQL5 standard library).
Use MagicNumber on ALL orders.
Check return codes; log failures at LogLevel >= 1.
Never open a position if TerminalInfoInteger(TERMINAL_CONNECTED) == false.
```

---

## Compilation Requirements

- Target: MetaTrader 5, build 3800+
- Standard library includes: `Trade\Trade.mqh`, `Indicators\Indicators.mqh`
- Compile with zero warnings
- Property declarations:
  ```mql5
  #property copyright "ArchangelX"
  #property version   "1.00"
  #property strict
  ```

---

## What to Build First (V1 Scope)

Build in this order. Each item must work before moving to the next.

1. **All enums and structs** — no logic, just declarations
2. **All input parameters** — exact order and naming as above
3. **Global variables** — as listed above
4. **OnInit()** — indicator creation, variable initialization, session parsing
5. **OnDeinit()** — handle cleanup
6. **EquityGuard** — CheckEquityGuard(), CloseAllPositionsByMagic(), HandleDailyReset()
7. **Session/News filter** — IsWithinSession(), IsNewsActive()
8. **Indicator filters** — CheckEMAFilter(), CheckADXFilter(), CheckRSIFilter(), CheckBollingerFilter(), IsEntryAllowed()
9. **Grid engine** — CalculatePipStep(), CalculateLotSize(), ShouldOpenNewGridTrade(), OpenGridTrade(), UpdateWeightedAverage()
10. **Basket exit** — CheckTakeProfit(), CheckLockProfit(), CheckTrailingStop(), CloseSequence()
11. **OnTick()** — wire everything together
12. **OnTester()** — custom scoring formula
13. **Compile, fix all warnings, run single backtest on XAUUSD M1**

---

## V1 Exclusions (Build Later)

These are intentionally excluded from V1 to keep the build focused:

- Live news calendar API (use manual blackout array instead)
- Compounding (UseCompounding input exists but can return base lot always)
- Random Entry Delay (UseRandomEntryDelay input exists but can be no-op)
- CSV sequence logging
- Multi-instance correlation throttle
