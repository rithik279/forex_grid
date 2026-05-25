# Triton — Optimization Templates & Regime Classification

**Created:** 2026-05-24  
**Templates folder:** `optimization_templates/`

---

## What This Document Covers

How to choose and use the regime-typed optimization templates.  
Each template is a `.set` file pre-configured for a specific market regime.  
Load it in MT5 Strategy Tester → Inputs tab → Load → run genetic optimization.

---

## The Core Idea: Regime Shapes the Search Space

Before running optimization, you form a **thesis** about what the market is doing.  
The thesis determines which parameters matter and which filters to turn on.

Two regime types, different EA configs:

| Regime | Filters ON | PipStep | MaxOrders | TakeProfit |
|--------|-----------|---------|-----------|-----------|
| **Mean Reversion / Range** | Bollinger Bands | Tighter | More | Shorter |
| **Trend / Breakout** | EMA + ADX | Wider | Fewer | Wider |

**Why this matters:**
- Optimizing a trending setup on a ranging pair = overfit garbage
- Optimizing a ranging setup on a trending pair = deep grids that get stopped out
- Pre-setting the regime forces MT5's genetic optimizer to search in the right space
- Fewer wasted passes = faster optimization = better results

---

## .set File Format

```
ParameterName=value||start||step||stop||Y   ← optimizer varies this
ParameterName=value                          ← fixed, not optimized
```

`Y` = optimize (genetic algorithm sweeps this range)  
`N` = fixed (locked in, not part of search)  

---

## The 4 Templates

### 1. `XAUUSD_Short_MeanReversion.set`

**Thesis:** Gold overbought at $4,500+. Rate hold (no June cut) caps upside.  
Mean reversion plays from upper range → lower range.

**Regime type:** Mean Reversion / Range  
**Direction:** Short only  
**Key config decisions:**

- **BB ON, Avoid Extreme:** Blocks new sell entries when price is already at lower band. Sells only when price has room to fall.
- **EMA OFF:** Gold is ranging. EMAs are choppy and contradictory in range. Using them blocks valid entries.
- **ADX OFF:** Range = low ADX. ADX filter would suppress most entries — wrong tool for this regime.
- **Tight PipStep range (10–80):** M1 gold moves fast. Tight grid fills quickly. Wide grid misses moves.
- **More MaxOrders (5–20):** Range-bound price will revert. Grid can go moderately deep. Natural ceiling at $4,650+.
- **Session:** 24/5 (gold trades around the clock)

**Kill condition:** Price holds above $4,700 on weekly close.

---

### 2. `EURUSD_Long_Trend.set`

**Thesis:** DXY structural weakness. Warsh/FOMC uncertainty. EUR bid. Pullbacks to 1.16–1.17 = buy zones.

**Regime type:** Trend Following  
**Direction:** Long only  
**Key config decisions:**

- **EMA ON, trend only:** Only opens longs when EMA Fast > Mid > Slow = confirmed uptrend stack. Blocks counter-trend trades.
- **ADX ON:** Confirms trend has momentum, not just drift. ADX > threshold = real move, not chop.
- **BB OFF:** Trending price legitimately reaches upper band. BB filter would block valid trend entries.
- **Wider PipStep range (8–60):** Trend = price moves away faster. Grid needs bigger spacing or it fills too quickly.
- **Fewer MaxOrders (3–12):** If thesis is correct (trend), grid shouldn't go deep. Deep grid = thesis wrong = exit.
- **Session: London + NY (07:00–17:00):** EUR is most active and directional in these hours. Avoids Asian drift.
- **DoubleCheckEMA on first trade:** Confirms trend before opening the sequence.

**Kill condition:** DXY reclaims 100, or Warsh hawkish at June FOMC.

---

### 3. `USDJPY_Short_RangeCeiling.set`

**Thesis:** BoJ intervention caps 160.00 hard. Every spike to 158–160 gets sold. Close near 154–155.

**Regime type:** Mean Reversion / Range Ceiling  
**Direction:** Short only  
**Key config decisions:**

- **BB ON, Avoid Extreme:** Blocks shorts when price at lower band (already fallen, no room). Sells only from upper range.
- **EMA OFF:** USDJPY is compressing between 155–160. EMAs cross constantly = chop signal = wrong filter.
- **ADX OFF:** Range = low ADX. Same logic as XAUUSD.
- **Medium PipStep (5–50):** JPY pairs have predictable range spacing. Not as volatile as gold.
- **Medium MaxOrders (5–18):** Hard BoJ ceiling = natural stop above. Grid can go moderately deep.
- **Session: Asian + London (00:00–15:00):** JPY most active in Asian session. US session = USD dominates, less clean range.

**Kill condition:** BoJ stands down publicly, or DXY breaks 101+.

---

### 4. `AUDUSD_Long_Breakout.set`

**Thesis:** 4-month consolidation broken. Weekly MACD bullish crossover. AUD = G10 carry proxy. Target 0.6940.

**Regime type:** Breakout / Trend Continuation  
**Direction:** Long only  
**Key config decisions:**

- **EMA ON, trend only:** Same as EURUSD. Only buy pullbacks when EMA stack confirmed bullish.
- **ADX ON:** Breakout needs momentum. ADX > threshold = real breakout, not false move. `DoubleCheckADX=true` on first trade.
- **BB OFF:** Breakout = price legitimately at extremes. BB filter blocks valid continuation entries.
- **Widest PipStep range (10–80):** Breakout moves are the biggest. Grid needs widest spacing.
- **Fewest MaxOrders (3–10):** If grid goes deep in a breakout, thesis is broken. Cut it there.
- **Widest TakeProfit (30–250):** Breakout target 0.6940 = ~335 pips from 0.6605. Wider reward target.
- **DoubleCheckEMA + DoubleCheckADX on first trade:** Double-gated entry. Breakout must be confirmed before opening.

**Kill condition:** China PMI drops hard, or risk-off shock.

---

## Optimization Workflow (Step by Step)

### Step 1: Load template in MT5
1. Open Strategy Tester → Expert = `Triton_v1.0`
2. Symbol = template pair, Chart = M1
3. Date range = `2025.12.01` → `2026.03.01` (BT period)
4. Inputs tab → Load → select template `.set` file
5. Optimization tab → Genetic algorithm, Balance+Drawdown criterion (or Custom = our OnTester score)
6. Run overnight

### Step 2: Export XML results
MT5 saves optimization results as `.xml` in `MQL5/Tester/` folder.  
Copy to `archangel_infra/XMLs/` for processing.

### Step 3: Parse and rank
```bash
cd archangel_infra
python optimization_dashboard.py
```
Opens dashboard. Sort by RegimeScore descending. Check FT/BT trade ratio column.

### Step 4: Filter results
Keep only passes where:
- `RegimeScore > 0`
- `FT/BT trade ratio` between **2.2 and 3.7** (healthy generalization)
- `FT_Profit > 0` (forward test was profitable)
- `BT_MaxDepth < 15` (grid didn't go too deep)

### Step 5: Extract best setfiles
From dashboard, export top 10 setfiles via `setfile_exporter.py`.

### Step 6: Run single BT/FT validation tests
Drop setfiles into `OneDrive/RD_MT5_Sharing/Queue/`.  
`remote_runner.py` on VPS runs split BT/FT (not optimization).  
Results populate `results.csv` with `RegimeScore` column.

### Step 7: Pick cluster center
Sort `results.csv` by `RegimeScore` desc.  
**Don't pick the top scorer.** Pick the **median parameters of top 10** = cluster center.  
Single top scorer is usually a lucky outlier. Cluster center = robust zone.

### Step 8: Deploy
Export final `.set` file → load on M1 live chart → register in strategy registry:
```bash
python archangel_infra/strategy_registry.py add
```

---

## Regime Decision Tree

When forming a new thesis, use this to pick the right template:

```
Is price in a defined range with clear support/resistance?
├── YES → Mean Reversion template
│         BB ON, EMA OFF, ADX OFF
│         Tighter PipStep, More MaxOrders
│         → Use XAUUSD or USDJPY template as base
│
└── NO → Is price breaking out or in confirmed trend?
          ├── YES (breakout, just started) → Breakout template
          │         EMA ON, ADX ON (double-check), BB OFF
          │         Widest PipStep, Fewest MaxOrders
          │         → Use AUDUSD template as base
          │
          └── YES (trend, established) → Trend template
                    EMA ON, ADX ON, BB OFF
                    Wide PipStep, Few MaxOrders
                    → Use EURUSD template as base
```

---

## Parameter Optimization Ranges — Rationale

| Parameter | Mean Reversion Range | Trend Range | Why different |
|-----------|---------------------|-------------|---------------|
| PipStep | 10–80 | 8–80 | Trending price moves away faster, wider spacing needed |
| MaxOrders | 5–20 | 3–12 | Range will revert; trend shouldn't need deep grid |
| TakeProfit | 20–150 | 30–250 | Trend targets are bigger |
| LotSizeExponent | 1.0–2.0 | 1.0–1.8 | Range grid can martingale harder (price reverts); trend grid stays lighter |
| BB | ON, optimize TF+Period+Dev | OFF | Only relevant in range regime |
| EMA | OFF | ON, optimize periods | Only relevant when trend exists |
| ADX | OFF | ON, optimize threshold | Confirms momentum; not useful in range |

---

## Adding New Templates

When you have a new thesis, copy the closest existing template and adjust:

1. Change `StrategyDescription` and `MagicNumber`
2. Set `TradeDirection` (1=Long, 2=Short)
3. Regime decision tree → toggle EMA/ADX/BB ON or OFF
4. Adjust `PipStep`, `MaxOrders`, `TakeProfit` ranges for the pair's volatility
5. Set `TradingSession` to the pair's most active hours
6. Write the thesis in the comment header (kills conditions, regime hypothesis)

Save to `optimization_templates/PAIR_Direction_RegimeType.set`

---

## Files

| File | Pair | Regime | Direction |
|------|------|--------|-----------|
| `XAUUSD_Short_MeanReversion.set` | XAUUSD | Mean Reversion | Short |
| `EURUSD_Long_Trend.set` | EURUSD | Trend Following | Long |
| `USDJPY_Short_RangeCeiling.set` | USDJPY | Mean Reversion (Range Ceiling) | Short |
| `AUDUSD_Long_Breakout.set` | AUDUSD | Breakout Continuation | Long |
