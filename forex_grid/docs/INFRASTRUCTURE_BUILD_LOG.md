# Antigravity Infrastructure — Build Log & Decision Record

**Files modified/created:** 2026-05-24

---

## Files Changed

| File | Change |
|------|--------|
| `archangel_infra/remote_runner.py` | EA_NAME updated to Triton; RegimeScore added |
| `archangel_infra/strategy_registry.py` | Created — strategy management CLI |
| `requirements.txt` | Created — Python dependencies |
| `README.md` | Created — project documentation |

---

## Task 2: EA_NAME Update

**What changed:**
```python
# Before
EA_NAME = r"Advisors\Archangel_X-v3.4.ex5"

# After
EA_NAME = r"Advisors\Triton_v1.0.ex5"
```

**Why:** The compiled EA file on the VPS must be named `Triton_v1.0.ex5` to match the new EA file (`EA/Triton.mq5`). After you compile Triton in MetaEditor and copy the `.ex5` to the VPS, remote_runner will automatically use it for all queued backtests.

**What you need to do:**
1. Compile `EA/Triton.mq5` on your local MetaEditor
2. Copy `Triton_v1.0.ex5` from `MQL5/Experts/Advisors/` to the same folder on the VPS
3. No other changes to `remote_runner.py` needed

---

## Task 3: RegimeScore Column

### What is RegimeScore?

A single number that scores each backtest result on **prop-firm survival probability** rather than raw profit. It's stored as an extra column in `results.csv` so you can sort/filter by it in the dashboard.

### How it's calculated

```
score = BT_Profit + FT_Profit                   (base: total profit across both periods)
      + 300  (if both BT and FT are profitable)  (reward: consistent across periods)
      - BT_Drawdown × 1.5                        (penalise: BT drawdown)
      - FT_Drawdown × 2.0                        (penalise: FT drawdown, weighted more)
      - 500  (if BT_Trades < 5)                  (penalise: over-filtered, too few trades)
      + 200  (if FT/BT trade ratio is 2.2–3.7)   (reward: ideal generalisation)
      - 300  (if FT/BT trade ratio < 1.0)        (penalise: FT far worse = overfit)
```

### Why this formula

The FT/BT trade ratio (2.2:1 to 3.7:1) is the Antigravity system's core filter for identifying overfitted vs well-generalised parameter sets:
- **Ratio < 1.0:** FT has fewer trades than BT even though FT covers a longer period → EA is almost certainly overfit, triggered on memorised price patterns
- **Ratio 2.2–3.7:** Healthy. The EA traded proportionally to the time period. It's generalising to new price data.
- **Ratio > 3.7:** EA under-traded in BT, likely hitting too few setups — a different kind of misfit

By embedding this ratio check in RegimeScore, sorting by RegimeScore in the dashboard automatically surfaces the best candidates without needing to manually calculate the ratio.

### Where it's used

After sorting results.csv by RegimeScore descending, the top candidates are your "stability zone" setfiles — parameter sets that survived both BT and FT without blowing up. Pick the cluster center (median parameters of the top 10), not the single highest scorer.

### Code changes

Added to `remote_runner.py`:

1. **`METRIC_COLS` and `RESULTS_HEADERS` constants** — defined at module level so header list is single source of truth (previously duplicated in `init_results_csv()` and `run_worker()`)

2. **`calculate_regime_score(bt_metrics, ft_metrics)`** — pure function, no side effects. Returns a float.

3. **Row building** — after parsing BT and FT HTML reports, `calculate_regime_score()` is called and `RegimeScore` is added to the row dict before writing to CSV.

---

## Task 4: Strategy Registry

### What it does

Keeps a record of every strategy you've deployed, with:
- Symbol, direction, timeframe
- Regime hypothesis (what market condition you're targeting)
- Kill conditions (what would make you pull this strategy)
- Key parameters (for quick reference without opening MT5)
- 30-day expiry date (forces a review — retire or renew)

### File structure

```
archangel_infra/
└── StrategyRegistry/
    ├── registry.json              ← Index of all strategies
    └── XAUUSD_Long_May2026.md     ← One card per strategy
```

### Commands reference

```bash
# See all strategies at a glance
python strategy_registry.py list

# Add a new strategy after deployment (interactive prompts)
python strategy_registry.py add

# Retire a strategy when regime changes
python strategy_registry.py retire XAUUSD_Long_May2026

# Print full strategy card (hypothesis, kill conditions, params)
python strategy_registry.py review XAUUSD_Long_May2026

# See what's about to expire (within 7 days)
python strategy_registry.py expiring
```

### Design decisions

**30-day expiry by default:** The 30-day window forces a conscious decision to continue or retire. Without this, strategies run indefinitely even when the regime they were built for has ended — this is one of the most common failure modes in systematic retail trading.

**Markdown cards, not just JSON:** The `.md` card is human-readable. You can git blame it, share it, read it on GitHub. The `registry.json` is the machine-readable index. Both are updated together on every write operation.

**`status` field values:** `ACTIVE`, `MONITORING`, `RETIRED`. Only `ACTIVE` and `MONITORING` show in `expiring`. `RETIRED` is kept permanently (don't delete) so you have a historical record of what you deployed and when.

---

## Task 5: README.md

The README covers:
- What the system does (2 sentences)
- Full repository structure
- Prerequisites (MT5 + Python + OneDrive)
- Quick start for the EA (compile, copy, run backtest)
- Quick start for remote_runner (VPS setup)
- Quick start for dashboard (local Streamlit)
- Strategy registry commands
- 1-hour daily workflow summary
- Hard prop firm limits

**Why it's written this way:** Assumes a second operator could pick this up cold and be running within 30 minutes. Every path in the README matches the actual file structure.

---

## Task 6: requirements.txt

**Packages included:**

| Package | Why needed |
|---------|-----------|
| `streamlit>=1.28` | Dashboard (`app.py`) |
| `plotly>=5.0` | Charts in dashboard |
| `pandas>=2.0` | Data processing in dashboard and registry |
| `openpyxl>=3.1` | Excel export (`Dashboard_Output.xlsx`) |

**MetaTrader5 package:** Commented out. The MT5 Python library only works on Windows machines with MT5 installed. It's needed on the VPS for `fetch_live_history.py` but not for the dashboard or registry. Installing it on a Mac/Linux dev machine will fail. Kept as a comment so VPS setup is documented.

**Standard library modules not listed** (they come with Python):
`os`, `sys`, `json`, `csv`, `re`, `subprocess`, `shutil`, `glob`, `time`, `traceback`, `datetime`, `pathlib`, `argparse`, `typing`, `xml.etree.ElementTree`
