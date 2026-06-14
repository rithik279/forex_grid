# Strategy Operating Framework — The Human Workflow

## Purpose

This document describes how to OPERATE the ArchangelX system, not how to build it. The EA and infrastructure are just tools. This framework is the process that turns those tools into consistent profit.

**Commitment:** 1 hour per day for 90 days. Optimizations run overnight on the VPS unattended.

---

## Core Philosophy

```
Risk framework first.
Strategy structure second.
Parameters last.

Strategies are consumables, not permanent systems.
Design → Deploy → Monitor → Retire → Repeat.
```

**You are not searching for the perfect strategy.** You are manufacturing short-horizon strategies calibrated to the current 3–4 week market regime, deploying the ones that survive validation, and retiring them when assumptions change.

---

## Step 0: Non-Negotiables (Set Once, Never Change)

Before any research begins, these guardrails are fixed. They cannot be adjusted based on performance, drawdown, or emotional state.

### Prop Firm Hard Limits (Per Account)
```
Daily loss hard stop:        -$5,000
Daily loss soft trigger:     -$3,000 (EA starts defensive actions)
Static account max loss:     -$10,000 (EA disables permanently until manual reset)
Daily profit target:         +$1,000 (EA stops trading for the day)
After target hit:            No new sequences. Existing sequences can close.
After hard daily stop:       Close all. No restart same day. Full stop.
After static stop:           Close all. Manual intervention required.
```

### News Rules
```
Disable trading:  X hours before any high-impact news event
Re-enable:        Y hours after news event resolves
CPI, NFP, FOMC:  Mandatory closure. No exceptions.
Gold:             200–280 min buffer before, 100–120 min after (strictest of all instruments)
```

### EA-Level Rules
```
No override policy:           If kill switch triggers, it cannot be re-enabled same day.
No revenge automation:        EA cannot restart after a hard stop within the same trading day.
Lot sizing:                   Fixed. No compounding in V1.
Weekend:                      Close all before Friday close. Restart Monday.
```

---

## Step 1: Market Structure Observation (5–10 min, daily)

Open TradingView. For each instrument you are considering, answer these 4 questions:

### Regime Checklist
```
Instrument: ___________
Date: ___________

1. ATR percentile vs 1-year history:
   [ ] Low (compressed volatility)
   [ ] Normal
   [ ] High (expanded volatility)
   ATR value: _______

2. ADX reading:
   [ ] < 18 = Range / chop
   [ ] 18–25 = Mixed / transitional
   [ ] > 25 = Trending
   ADX value: _______

3. EMA slope (H1 or H4):
   [ ] Rising (bullish)
   [ ] Flat (neutral)
   [ ] Falling (bearish)

4. Recent structure (last 3 months):
   [ ] Clean swings and trends
   [ ] Choppy / no clear direction
   [ ] Range with defined boundaries
   [ ] Volatility expansion (widening moves)

Regime label: _________________ (e.g. "Gold: Trending Bullish, High ATR")
```

**Log this daily.** Over 90 days, you build a dataset of regime labels that will tell you which strategies worked in which environments.

---

## Step 2: Form a 3–4 Week Hypothesis (5 min)

Based on Step 1, write ONE sentence:

**Template:**
```
"[Instrument] is likely in [regime type] over the next [timeframe],
 unless [specific macro event] causes a regime change,
 which would be signaled by [measurable condition]."
```

**Examples:**
```
"Gold is likely in an upward-trending regime over the next 4 weeks,
 unless a strong USD rally on Fed hawkishness reverses momentum,
 which would be signaled by ADX dropping below 25 and EMA crossover."

"EURUSD is likely to remain range-bound between 1.07–1.10 for the next 3 weeks,
 unless ECB or Fed meeting breaks the range,
 which would be signaled by price closing outside the range on H4."
```

**This hypothesis determines which strategy TYPE is eligible to trade:**
```
Clean uptrend → Trend-following grid (long-only, tight steps, momentum)
Range-bound  → Mean-reversion grid (both directions, wider steps)
No clear regime → Do not trade. Wait.
```

**Assumption break conditions (define BEFORE deploying):**
```
If [measurable condition] → strategy is automatically disabled.
```

This converts "turn it off when it feels wrong" into "turn it off when the regime definition fails."

---

## Step 3: Micro-Signal Validation (Pine Script) — 15 min, when building new strategy

Before running MT5 optimization, do a quick visual sanity check in TradingView:

1. Write a small Pine indicator with the signal logic (EMA alignment, BB entry, RSI filter, etc.)
2. Apply to last 3 months of the target instrument
3. Check:
   - Do entries cluster at sensible locations?
   - Does the signal align with the regime you identified?
   - Is it triggering randomly, or only in specific conditions?
4. Record:
   - Signal frequency: ___ per week
   - Visual win rate proxy: ___% (rough estimate from chart)
   - Average excursion after signal: ___

**Goal:** Confirm "this signal has behavioral validity in the current regime." Not optimization. Just confirmation that the logic is not nonsense.

---

## Step 4: MT5 Optimization (Fire and Forget — runs overnight)

Once Step 3 passes, configure and launch MT5 optimization.

### Optimization Configuration Rules
```
Structure: FIXED (before optimization begins)
  - Risk limits (MaxRunningLoss, GlobalEquityStop, DailyProfitTarget)
  - Session windows
  - News buffers
  - Direction (Long-only or Both)
  - Instrument and timeframe

Optimizable: BEHAVIORAL
  - PipStep
  - PipStepExponent
  - TakeProfit
  - LockProfit
  - TrailingStop
  - MaxOrdersPerDirection
  - EMA periods
  - ADX threshold
  - RSI thresholds

Narrow ranges only (dangerous settings):
  - LotSizeExponent: 1.0–1.3 max
  - MaxLotSize: fixed cap, not optimized
  - LotSize: fixed or very narrow range
```

### Optimization Scoring (Custom OnTester)
The EA uses a custom scoring formula (see `01_EA_SPECIFICATION.md`). This means "Custom Max" must be selected in MT5 Strategy Tester → Optimization Criterion.

### Backtest Date Selection
```
Optimization period:   Last 3 months (aligns with your regime hypothesis)
Forward period:        Most recent 4–6 weeks (unseen data for validation)
Split ratio:           ~70% backtest, ~30% forward

Example for May 2026:
  FromDate:    2026.02.01
  SplitDate:   2026.04.01
  ToDate:      2026.05.23
```

### Stability Zone Rule
Do not take the #1 result from optimization. Instead:
1. Look at the top 20–50 results
2. Find a **cluster** of parameter sets that all perform well
3. Pick a parameter set from the CENTER of that cluster
4. If one specific EMA length only works at exactly 47 but nothing nearby works → reject it

"Good across a range" beats "best at one point."

---

## Step 5: Behavior Explanation Loop (Return to TradingView) — 10 min

Take the optimized parameter set. Go back to TradingView. Write 3 bullets:

```
1. What market behavior is being exploited?
   Example: "Gold's tendency to pull back 15–25 pips after a momentum spike, then recover"

2. When does this strategy fail?
   Example: "When a strong macro catalyst (CPI shock, FOMC) creates a one-directional move 
             that doesn't reverse"

3. What protection shuts it down before catastrophic loss?
   Example: "MaxRunningLoss = $800/sequence + GlobalEquityStop = $91,000"
```

**If you cannot write these 3 bullets, you cannot deploy the strategy. Go back to Step 2.**

---

## Step 6: Regime Eligibility Gate

Check the measurable conditions defined in Step 2:

```
Gate checklist:
[ ] ADX is above/below threshold: YES / NO
[ ] EMA alignment confirms direction: YES / NO
[ ] ATR is within normal range (not extreme): YES / NO
[ ] No high-impact news in next 24 hours: YES / NO
[ ] Spread is normal (not news-widened): YES / NO

If ALL = YES → Strategy is eligible to deploy
If ANY = NO  → Do not deploy. Wait for conditions to align.
```

This is not a judgment call. It is a checklist. If any box is unchecked, the strategy does not go live.

---

## Step 7: Risk Sizing and Survivability Testing (Antigravity Workflow B)

Before live deployment:

1. Run the setfile through `remote_runner.py` (Antigravity Workflow B)
2. Review the BT and FT results:
   - Is max drawdown within prop firm limits at the chosen lot size?
   - Is FT/BT trade ratio between 2.2:1 and 3.7:1?
   - Does the strategy make money in BOTH the BT and FT period?
   - Is the worst-case drawdown survivable on the prop account?
3. If drawdown too high → reduce lot size via the lot multiplier
4. If strategy only works in one period → reject it

**Worst-case exposure report (mental check):**
```
Maximum simultaneous open positions: ___
Maximum basket floating loss at that depth: $___
Maximum lot exposure at that depth: ___
Can the account survive this without hitting the static stop? YES / NO
```

---

## Step 8: Setfile Versioning (Strategy Registry)

Every deployed setfile is saved with a card:

```
Strategy Card Template:
-----------------------------------------
Name:           XAUUSD_LongPullback_May2026
Symbol:         XAUUSD
Timeframe:      M1
EA Version:     ArchangelX v1.0
Deploy Date:    2026-05-20
Expiry Date:    2026-06-20 (30-day review)

Regime Hypothesis:
  Gold trending bullish on macro uncertainty and weak USD.
  Targeting pullback entries during London session.

Assumption Break Conditions:
  - ADX drops below 20 for 3 consecutive days
  - Price violates 2026-04-01 swing low
  - Strong USD rally on Fed hawkishness

Key Parameters:
  Direction:    Long Only
  PipStep:      15
  PipStepExp:   1.8
  MaxOrders:    12
  TP:           0 (lock + trail)
  LockProfit:   20
  TrailStop:    8
  Session:      London + early NY
  EMA TF:       H1
  EMA Periods:  10/50/100

Kill Switch Conditions (hard):
  - Daily loss hits -$5,000
  - Account equity hits $90,000

Status:         ACTIVE / MONITORING / RETIRED
Last Review:    2026-05-20
Notes:          
-----------------------------------------
```

Save all strategy cards in `ArchangelX/StrategyRegistry/` as markdown files.

---

## Step 9: Daily Operating Routine (1 Hour)

```
MORNING (30 min):
□ Check overnight results in app.py
□ Check any EA alerts or unexpected closures
□ Run Step 1 Regime Checklist for active instruments
□ Review active strategy cards — are assumption break conditions still holding?
□ Log regime snapshot (instrument, ADX, ATR, EMA slope)

MIDDAY/EVENING (20 min):
□ If running optimization: review queue, check VPS status
□ If reviewing optimization results: run optimization_dashboard.py
□ Select top pass IDs for Workflow B validation if needed
□ Note anything unusual in market behavior

QUEUE NEXT OPTIMIZATION (10 min):
□ If current strategy approaching expiry or assumption break triggered:
  - Update remote_config.json (symbol, dates)
  - Generate optimization setfile with parameter ranges
  - Launch MT5 optimization (or queue via OneDrive)
  - Set next review date
```

---

## Step 10: Promotion to Live Capital

A strategy is promoted from demo to live when:

```
Promotion criteria (ALL must be met):
[ ] Profitable in demo for minimum 5 trading days
[ ] Maximum drawdown did not exceed 40% of prop firm daily limit
[ ] No kill switch violations during demo
[ ] FT/BT trade ratio is 2.2:1 to 3.7:1
[ ] The strategy thesis (Step 5 bullets) still holds
[ ] Regime conditions (Step 6 gate) still pass
```

A strategy is killed immediately when:

```
Live kill criteria (ANY triggers immediate shutdown):
[ ] Regime label changes (ADX drops below threshold for 3 days)
[ ] Any equity stop trigger
[ ] Assumption break conditions from Step 2 are met
[ ] Correlation spike risk (other strategies also losing simultaneously)
[ ] Expiry date reached without renewal review
```

---

## Step 11: Prop Firm Scaling

```
EVALUATION PHASE:
  - Slightly more aggressive lot sizing (pass faster)
  - Same kill switches — non-negotiable
  
FUNDED PHASE:
  - Reduce lot size to 70% of eval sizing
  - Priority: preserve capital and consistency rule

MULTI-ACCOUNT SCALING:
  - Use different setfiles on different accounts where possible
  - Stagger entry times (not all accounts trade same signal simultaneously)
  - Portfolio-level throttle: if total drawdown across accounts exceeds threshold, 
    reduce exposure everywhere
  - Goal: consistent, boring returns across many accounts

PROFITS:
  - Use prop firm payouts to buy more evaluations
  - Target 3–5 accounts simultaneously
  - Reinvest at least 50% back into evaluations for 90 days
```

---

## Instrument Selection Guide

When choosing which instrument to trade next, score each on:

```
1. Is the current regime clear and readable? (1=muddy, 5=crystal clear)
2. Is the hypothesis strong and specific? (1=vague, 5=precise)
3. Does the instrument have a validated playbook? (see 00_PROJECT_OVERVIEW.md)
4. Is news risk manageable this week? (1=CPI/FOMC week, 5=quiet week)
5. Has this instrument performed well in similar regimes before?

Trade the instrument with the highest confidence score.
Do not trade if top score < 3 across all instruments.
"No trade" is a valid and often correct decision.
```

---

## Common Failure Modes to Avoid

| Failure | How It Happens | Prevention |
|---------|---------------|------------|
| Regime mismatch | Deploying a trend file in a chop regime | Step 6 eligibility gate |
| Overfit parameter | Optimizing on too short a window | Stability zone rule (Step 4) |
| Over-trading | Running too many strategies simultaneously | Portfolio-level position cap |
| Emotional override | Manually re-enabling after kill switch | No-override policy (non-negotiable) |
| Revenge optimization | Running more tests after a loss to "fix" it | 24-hour loss review rule |
| Strategy never retired | Running the same file past its regime | 30-day expiry + renewal review |
| FT/BT mismatch | Forward test very different from backtest | Reject files with ratio < 2.2 or > 3.7 |
| Hidden tail risk | Grid runs uncontrolled in trending market | MaxRunningLoss + GlobalEquityStop |
