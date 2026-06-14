# Agent Task Instructions — ArchangelX Build

## How to Use This Document

This document contains specific, self-contained tasks for any coding agent (Claude Code, Codex, Copilot, etc.) to execute. Each task references the relevant spec docs and has clear acceptance criteria.

**Before starting any task:**
1. Read `00_PROJECT_OVERVIEW.md` — understand the big picture
2. Read `01_EA_SPECIFICATION.md` — understand the EA architecture
3. Read `02_ANTIGRAVITY_INFRASTRUCTURE.md` — understand the existing automation

---

## TASK 1: Build ArchangelX.mq5 (Primary Task)

**File to create:** `EA/ArchangelX.mq5`

**Reference docs:** `01_EA_SPECIFICATION.md` (complete specification)

**What to build:**
A complete, compilable MQL5 Expert Advisor that implements all 5 layers described in the spec:
- Layer 5: EquityGuard
- Layer 4: RegimeFilter  
- Layer 3: GridEngine
- Layer 2: BasketExitEngine
- Layer 1: OptimizationReporter (OnTester)

**Build order (follow exactly):**
1. Property declarations, includes, enums, structs (all from spec)
2. All input parameters in exact order (all from spec)
3. Global state variables
4. OnInit() — indicator creation, variable init, session parsing, input validation
5. OnDeinit() — handle cleanup
6. EquityGuard functions: `CheckEquityGuard()`, `CloseAllPositionsByMagic()`, `HandleDailyReset()`
7. Session/News filters: `IsWithinSession()`, `IsNewsActive()`
8. Indicator filters: `CheckEMAFilter()`, `CheckADXFilter()`, `CheckRSIFilter()`, `CheckBollingerFilter()`, `IsEntryAllowed()`
9. Grid engine: `CalculatePipStep()`, `CalculateLotSize()`, `ShouldOpenNewGridTrade()`, `OpenGridTrade()`, `UpdateWeightedAverage()`
10. Basket exit: `CheckTakeProfit()`, `CheckLockProfit()`, `CheckTrailingStop()`, `CloseSequence()`
11. OnTick() — wire all layers together
12. OnTester() — custom scoring formula

**Acceptance criteria:**
- [ ] Compiles with zero errors and zero warnings in MT5 build 3800+
- [ ] All input parameters match the spec exactly (names, types, defaults, groups)
- [ ] All enums and structs match the spec exactly
- [ ] OnTester() returns a custom score (not 0)
- [ ] Runs a single backtest on XAUUSD M1 without crashing

**V1 Exclusions (implement as no-ops or stubs):**
- `UseCompounding` — input exists, but always use fixed LotSize (ignore compounding logic)
- `UseRandomEntryDelay` — input exists, but disable (no random delay)
- `IsNewsActive()` — return false always (stub, no live calendar)
- CSV sequence logging — not needed

**Critical implementation notes from spec:**
- Weighted average: `sum(lot_i × price_i) / sum(lot_i)` across all positions with matching MagicNumber + direction
- Pip step for level N: `base_step × PipStepExponent^level` (capped at MaxPipStep if > 0)
- Lot size for level N: `LotSize × LotSizeExponent^level` (capped at MaxLotSize if > 0)
- TP measured from `WeightedAvgPrice`, NOT from individual trade entry
- Lock profit only activates when `TradeCount >= LockProfitMinTrades`
- All trade operations through `CTrade` class
- All positions must use `MagicNumber` for identification
- Session parsing: "HH:MM-HH:MM" strings per weekday

---

## TASK 2: Update remote_runner.py to Use New EA

**File to modify:** `Antigravity/remote_runner.py`

**Reference doc:** `02_ANTIGRAVITY_INFRASTRUCTURE.md`

**What to change:**
Update the EA path constant to point to the new EA:

```python
# Change this line:
EA_NAME = r"Advisors\Archangel_X-v3.4.ex5"

# To:
EA_NAME = r"Advisors\ArchangelX.ex5"
```

Also verify these constants are correct for the VPS:
```python
MT5_TERMINAL_PATH = r"C:\Program Files\PU Prime MT5 Terminal-1\terminal64.exe"
MT5_DATA_FOLDER_NAME = "CB73EB447A09F27F5775C81FBB987ED5"
```

**No other changes to `remote_runner.py` in V1.**

**Acceptance criteria:**
- [ ] `EA_NAME` points to `ArchangelX.ex5`
- [ ] Constants are correct for the VPS environment
- [ ] No other logic changes

---

## TASK 3: Add Regime Score to remote_runner.py

**File to modify:** `Antigravity/remote_runner.py`

**Reference doc:** `02_ANTIGRAVITY_INFRASTRUCTURE.md` (section: "Adding Regime-Aware Scoring")

**What to add:**
Add a `calculate_regime_score(bt_metrics, ft_metrics)` function and call it after parsing both reports. Save the score as an additional `RegimeScore` column in `results.csv`.

**Function to add:**
```python
def calculate_regime_score(bt_metrics, ft_metrics):
    """
    Score a setfile on prop-firm survival probability, not raw profit.
    Higher score = better candidate for deployment.
    """
    score = bt_metrics.get('BT_Profit', 0) + ft_metrics.get('FT_Profit', 0)
    
    # Reward both periods profitable
    if ft_metrics.get('FT_Profit', 0) > 0 and bt_metrics.get('BT_Profit', 0) > 0:
        score += 300
    
    # Penalize drawdown (FT weighted more heavily)
    score -= bt_metrics.get('BT_Drawdown', 0) * 1.5
    score -= ft_metrics.get('FT_Drawdown', 0) * 2.0
    
    # Penalize too few trades (over-filtered)
    if bt_metrics.get('BT_Trades', 0) < 5:
        score -= 500
    
    # Reward good FT/BT trade ratio (2.2:1 to 3.7:1)
    bt_trades = bt_metrics.get('BT_Trades', 1)
    ft_trades = ft_metrics.get('FT_Trades', 0)
    if bt_trades > 0:
        ratio = ft_trades / bt_trades
        if 2.2 <= ratio <= 3.7:
            score += 200
        elif ratio < 1.0:
            score -= 300  # FT far worse than BT = likely overfit
    
    return round(score, 2)
```

**Where to call it:**
After `ft_metrics` is built, before writing the row:
```python
regime_score = calculate_regime_score(bt_metrics, ft_metrics)
row['RegimeScore'] = regime_score
```

**Update headers:**
Add `"RegimeScore"` to the `headers` list after the FT metric columns.

**Acceptance criteria:**
- [ ] `RegimeScore` column appears in `results.csv`
- [ ] Score is calculated correctly for sample metrics
- [ ] No existing functionality broken

---

## TASK 4: Create Strategy Registry Tool

**File to create:** `Antigravity/strategy_registry.py`

**Reference doc:** `03_STRATEGY_FRAMEWORK.md` (Step 8: Setfile Versioning)

**What to build:**
A simple CLI tool for managing the Strategy Registry. The registry is a directory of markdown files (`StrategyRegistry/*.md`) plus a JSON index (`StrategyRegistry/registry.json`).

**Commands:**
```
python strategy_registry.py list                     # Show all strategies (name, symbol, status, expiry)
python strategy_registry.py add                      # Interactive prompt to create new strategy card
python strategy_registry.py retire <name>            # Mark strategy as RETIRED
python strategy_registry.py review <name>            # Show full strategy card
python strategy_registry.py expiring                 # Show strategies expiring within 7 days
```

**registry.json format:**
```json
[
  {
    "name": "XAUUSD_LongPullback_May2026",
    "symbol": "XAUUSD",
    "status": "ACTIVE",
    "deploy_date": "2026-05-20",
    "expiry_date": "2026-06-20",
    "regime": "Trending Bullish",
    "file": "StrategyRegistry/XAUUSD_LongPullback_May2026.md"
  }
]
```

**`add` command prompts:**
- Name (auto-generate from symbol + direction + month)
- Symbol
- Timeframe
- Regime Hypothesis (free text)
- Assumption Break Conditions (free text)
- Direction (Long/Short/Both)
- Key Parameters (PipStep, MaxOrders, TP/Lock/Trail, Session, EMA TF, EMA periods)
- Kill Switch Conditions
- Notes

**Acceptance criteria:**
- [ ] `list` shows all strategies in tabular format
- [ ] `add` creates both the `.md` file and updates `registry.json`
- [ ] `retire` updates status to RETIRED in both `.md` and `registry.json`
- [ ] `expiring` correctly identifies strategies within 7 days of expiry date

---

## TASK 5: Create README.md

**File to create:** `README.md` (project root)

**What to write:**
A clean project README that covers:
1. What the project is (2 sentences)
2. Repository structure
3. Quick start for the EA (compile and run steps)
4. Quick start for the automation (how to run `remote_runner.py`)
5. Link to the docs folder
6. Prerequisites (Python version, MT5 version, required packages)

**Acceptance criteria:**
- [ ] A new developer can understand the project in under 5 minutes
- [ ] All file paths are accurate
- [ ] Prerequisites are complete

---

## TASK 6: Create requirements.txt

**File to create:** `requirements.txt`

**What to include:**
All Python packages used across the Antigravity codebase. Scan all `.py` files for imports and list them with minimum version constraints.

Known packages from existing code:
```
streamlit>=1.28
pandas>=2.0
plotly>=5.0
openpyxl>=3.1
```

**Acceptance criteria:**
- [ ] All packages from all `.py` files are included
- [ ] `pip install -r requirements.txt` succeeds cleanly
- [ ] No unnecessary packages included

---

## TASK 7 (Future): Claude Agent Market Scanner

**Status:** Not started. Build after EA is working in backtests.

**File to create:** `Antigravity/market_scanner.py`

**What it does:**
A Claude API-powered agent that:
1. Fetches OHLCV data for a list of target instruments
2. Calculates regime indicators (ADX, ATR percentile, EMA slopes)
3. Classifies each instrument's current regime
4. Generates a hypothesis for the next 3–4 weeks for each
5. Outputs a ranked list: "Trade X (high confidence trending bullish) > Watch Y > Skip Z"
6. Optionally generates the `remote_config.json` for the top candidate

**Inputs required:**
- List of instruments to scan
- Lookback period for ATR percentile (default: 252 days)
- API key for market data (or MT5 Python API connection)

**Output format:**
```json
{
  "scan_date": "2026-05-23",
  "top_candidate": {
    "symbol": "XAUUSD",
    "regime": "Trending Bullish",
    "confidence": 4,
    "hypothesis": "Gold likely trending bullish for next 3-4 weeks...",
    "assumption_break": "ADX < 20 for 3 days or price breaks 3200",
    "suggested_direction": "Long Only",
    "suggested_session": "London + NY"
  },
  "all_candidates": [...]
}
```

**Reference:** `03_STRATEGY_FRAMEWORK.md` Steps 1 and 2

---

## TASK 8 (Future): Backtest Validator Enhancement

**Status:** Not started. Build after Task 3 is complete.

**File to modify:** `Antigravity/remote_runner.py` (or create `Antigravity/validator.py`)

**What to add:**
A more sophisticated validation layer that:
1. Checks parameter stability (runs nearby parameter sets and verifies consistent performance)
2. Monthly breakdown of performance (not just aggregate BT + FT)
3. Worst-day drawdown analysis
4. Consistency rule check (no single day > 30% of total profit)

**Reference:** `03_STRATEGY_FRAMEWORK.md` Step 4 (Stability Zone Rule)

---

## General Coding Standards

These apply to ALL tasks:

### Python
- Python 3.10+
- Type hints on all function signatures
- Docstrings on all public functions
- No hardcoded paths — use `os.path.join`, `os.path.expanduser`, or constants at the top of the file
- Handle exceptions gracefully — never let the runner crash silently
- Log meaningful messages with timestamps

### MQL5
- Compile with zero warnings
- Use CTrade class for all order operations
- All positions identified by MagicNumber
- Log at appropriate LogLevel (0=silent, 1=major events, 2=verbose, 3=debug every tick)
- No `Sleep()` calls in OnTick
- No `Print()` calls in the inner loop (use only at LogLevel >= 2)
- Deterministic: identical tick data must produce identical results

### Git
- One commit per task
- Commit message format: `[TaskN] Brief description of what was done`
- Never commit `.ex5` files (compiled EA binary) — source `.mq5` only
- Never commit `results.csv` — it is data, not code
- `.gitignore` should exclude: `*.ex5`, `results.csv`, `__pycache__/`, `*.pyc`

---

## Environment Setup

### Local Machine
```bash
# Clone or initialize repo
git init ArchangelX
cd ArchangelX

# Copy Antigravity folder into repo
# (copy existing C:\Users\manmi\Antigravity\ contents here)

# Install Python dependencies
pip install -r requirements.txt

# Run dashboard
streamlit run Antigravity/app.py
```

### VPS
```
1. Copy ArchangelX.mq5 to:
   C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\<HASH>\MQL5\Experts\Advisors\

2. Compile in MT5:
   MetaEditor → Open ArchangelX.mq5 → Compile (F7)
   
3. Verify: ArchangelX.ex5 appears in Experts\Advisors\

4. Update remote_runner.py:
   EA_NAME = r"Advisors\ArchangelX.ex5"
   
5. Run:
   python remote_runner.py
```

### MT5 Strategy Tester Settings for Optimization
```
Expert Advisor: ArchangelX
Symbol: (per instrument playbook)
Timeframe: M1
Model: Every tick based on real ticks (Model=4)
Optimization criterion: Custom max
Deposit: 100000
Currency: USD
Leverage: 1:100
Forward: Custom (set SplitDate in remote_config.json)
```
