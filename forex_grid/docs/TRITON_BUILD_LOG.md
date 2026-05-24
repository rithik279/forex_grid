# Triton EA — Build Log & Decision Record

**File:** `EA/Triton.mq5`  
**Built:** 2026-05-24  
**Version:** 1.0  

---

## Why "Triton"?

Replaces ArchangelX. Triton = Greek sea god, son of Poseidon. Signals power and depth — a complete rebuild, not a patch.

---

## What This EA Does (Plain English)

Triton is a **grid sequencing EA**. It works like this:

1. When entry conditions align (regime filters pass), it opens a first trade.
2. If price moves against that trade by a set distance (PipStep), it opens another trade in the same direction — this is "averaging down."
3. It keeps adding trades as price moves against it, each trade spaced further apart (PipStepExponent) and at a larger size (LotSizeExponent).
4. The whole group of trades is a **sequence** (or basket). The EA tracks the weighted average entry price of the whole basket.
5. When price recovers enough (TakeProfit pips above the weighted average), all trades close together at a profit.
6. If the basket reaches a profit threshold (LockProfit), a trailing stop activates to protect gains.
7. Hard limits prevent runaway losses: equity stops, daily loss caps, max grid depth.

**The edge:** not the EA itself — the edge is choosing the right regime for each instrument and retiring the strategy after 30 days when the regime changes.

---

## Architecture Decisions

### Decision 1: ATR mode via negative pip values (not a separate bool)

**What the screenshots showed:**  
```
ATR Usage Info: [Only values entered in negative will be treated as ATR multiplier]
Pip Step: 15.0
```

**Decision:** No `UseATRForPips` boolean. Instead, if `PipStep < 0`, the EA uses ATR mode automatically. Negative = ATR multiplier, positive = raw pips.

**Why:** This matches the actual original EA's behavior from the settings panel. Using a negative value as a mode signal is more flexible — you can switch mode without hunting for a separate checkbox. It also lets you optimize PipStep across both modes in a single pass (negative values optimize ATR multiplier, positive optimize raw pips).

**Implementation:** `ResolveDistance()` checks sign of the input:
```mql5
if(pipInput < 0)
    return (-pipInput) * ATR(ATRPeriod);   // ATR mode
else
    return pips * pipMultiplier * _Point;  // raw pips
```

---

### Decision 2: News filter uses minutes, not hours

**What the screenshots showed:**
```
Close Trade (X)Amount of Minutes before news: 60
Pause EA (X)Amount of Minutes after news: 60
```

**Previous skeleton had:** `CloseHoursBeforeNews = 0.5` (hours as a double)

**Decision:** Changed to `CloseMinutesBeforeNews` and `PauseMinutesAfterNews` as integers. Default 60 minutes each.

**Why:** The original EA clearly uses minutes as the unit (integers, not fractions). Using hours as a double is a UX trap — operators entering "60" thinking it means 60 minutes would actually trigger 60-hour blackouts. Minutes as int matches the UI label and eliminates that risk.

---

### Decision 3: Session end action enum reordered

**What the screenshots showed:**
```
Action at the end of Session: "Complete the sequence" | "Close all trades" | "Pause the sequence"
```

**Previous skeleton had:** `CLOSE_ALL_TRADES = 0, WAIT_SEQUENCE_CLOSE = 1, PAUSE_OPEN_SEQUENCE = 2`

**Decision:** Reordered to match screenshot label order:
```mql5
COMPLETE_SEQUENCE = 0  // "Complete the sequence" — default
CLOSE_ALL_TRADES  = 1
PAUSE_SEQUENCE    = 2
```

**Why:** The default value must match what the original EA defaults to. Screenshots show "Complete the sequence" as the active value, so it's index 0.

---

### Decision 4: Trade Direction enum display strings updated

**Screenshots show:** "Long & Short", "Long Only", "Short Only"  
**Previous skeleton:** "Both Directions", "Long Only", "Short Only"

**Decision:** Changed `BOTH` display to `// Long & Short` to match MT5 UI exactly.

**Why:** When operators load a .set file from the old EA, the display must match. If the display string changes, MT5 shows the parameter correctly but the UI label looks different — confusing when comparing setfiles.

---

### Decision 5: Restart mode enum — removed RESTART_DISABLED

**Screenshots show:** "Restart Next Day" | "Restart In Hours" (only 2 options visible)

**Previous skeleton had:** `RESTART_DISABLED = 0, RESTART_NEXT_DAY = 1, RESTART_AFTER_HOURS = 2`

**Decision:** Simplified to 2 options:
```mql5
RESTART_NEXT_DAY    = 0
RESTART_AFTER_HOURS = 1
```

**Why:** If you want to disable restart-after-loss, set `MaxRunningLoss = 0` (which means the loss stop never triggers). Having a third "disabled" enum option is redundant and creates confusion.

---

### Decision 6: Global Equity Stop Type — only 2 options

**Screenshots show:** "Absolute Equity" | "Risked Percentage"  
**Previous skeleton had:** 3 options including "Risked Amount"

**Decision:** Removed `EQUITY_RISKED_AMOUNT`. Kept:
```mql5
EQUITY_ABSOLUTE       = 0  // Absolute Equity
EQUITY_RISKED_PERCENT = 1  // Risked Percentage
```

**Why:** Screenshots are authoritative. "Absolute Equity" (hard floor in $) covers most prop firm use cases. "Risked Percentage" covers drawdown % limits. The dollar-drawdown mode was redundant with the percentage mode.

---

### Decision 7: DelayTradeSequence implemented as bar counter

**What the spec says:** "bars to wait before first real trade"  
**What the screenshots show:** Default = 3

**Decision:** `DelayTradeSequence` counts bars elapsed since the EA last looked for an entry. When `DelayTradeSequence > 0`, the IDLE state only checks for new entries every N bars (counting `IsNewBarOnChart()` calls).

**Why:** This prevents rapid sequence restarts after a sequence closes. If a sequence closes at a loss and the regime is still bad, you don't want to immediately open another sequence — wait 3 bars first.

---

### Decision 8: LockProfitMinTrades = 0 means lock profit always eligible

**Screenshots show:** `Lock Profit Min Trades = 0`  
**Previous skeleton:** `LockProfitMinTrades = 3`

**Decision:** When `LockProfitMinTrades = 0`, the lock profit check runs regardless of how many trades are in the sequence (even just 1).

**Why:** Setting it to 0 makes lock profit eligible from the first trade, which is the desired default behavior for XAUUSD strategies where even a 1-trade sequence that runs up quickly should be protected.

---

### Decision 9: AllowSamePairDirectionTrades = false by default

**Screenshots show:** `false`  
**Previous skeleton:** `true`

**What this means:** If another EA on the same account already has BUY positions on XAUUSD, Triton won't open another BUY sequence on XAUUSD.

**Why the default is false:** Prevents stacking same-direction exposure across multiple EA instances on the same instrument. On a prop firm account running 3-5 simultaneous strategies, having multiple BUY sequences on the same pair multiplies both the upside and the drawdown — the latter being what kills prop accounts.

---

### Decision 10: OnTester() scoring formula

**From spec (`docs/01_EA_SPECIFICATION.md`):**
```
score = NetProfit
      + (DailyTargetHits × 500)
      + (ProfitFactor × 200)
      - (MaxDD × 2.0)
      - (DailyLossHits × 2000)
      - (RiskStopCount × 5000)
      - (MaxDepth × 50)
      - (AvgDuration / 3600 × 10)
```

**Why this formula instead of raw profit:**  
Standard MT5 optimization maximizes profit. But on a prop firm account, maximizing profit while blowing the daily loss limit is worthless — you lose the account. This formula:
- Rewards days where the $1k daily target was hit (+500 per day)
- Rewards consistency (ProfitFactor × 200)
- Punishes drawdown (MaxDD × 2)
- Severely punishes daily loss triggers (−2000 each — these are real account-threatening events)
- Massively punishes equity stop triggers (−5000 — this likely means losing the prop account)
- Penalizes deep grids (more levels = more exposure = more risk)
- Penalizes long basket holds (held overnight = uncontrolled exposure)

The genetic optimizer will find parameters that survive these constraints, not just maximize one run's profit.

---

## V1 Stubs (compile-safe, functional noop)

| Feature | Status | Why deferred |
|---------|--------|--------------|
| `UseCompounding` | Stub — reads input, computes lot normally | Compounding in grid EA compounds risk non-linearly. Need to validate base EA behavior first before adding this layer. |
| `UseRandomEntryDelay` | Stub — uses seeded PRNG but simple 30% skip | Original behavior unknown. Seeded PRNG is in place so it's deterministic if enabled. |
| `LicenseKey` | Input exists, no validation | No licensing server to check against in V1. Input preserved for setfile compatibility. |

---

## Files Modified / Created

| File | Action |
|------|--------|
| `EA/Triton.mq5` | Created — full EA |

---

## Validation Checklist (for you to complete)

- [ ] Compile in MT5 MetaEditor → 0 errors, 0 warnings
- [ ] Open Strategy Tester → confirm all parameters appear correctly in Inputs tab
- [ ] Confirm defaults match: PipStep=15.0, LotSize=0.1, MaxOrders=10, LockProfit=30.0
- [ ] Run single backtest: XAUUSD M30, 2025-01-01 to 2025-05-01, deposit $100,000
- [ ] Check Journal tab: "Triton v1.0 initialized" log line appears
- [ ] Check Journal tab: OnTester metrics print at end of backtest
- [ ] Copy `Triton.mq5` to VPS MetaTrader `MQL5/Experts/` folder
- [ ] Compile on VPS → 0 errors, 0 warnings
- [ ] Update `archangel_infra/remote_runner.py` → change `EA_NAME = "Triton"`
- [ ] Run one validation backtest via remote_runner queue on VPS
