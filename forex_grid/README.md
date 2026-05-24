# Seraphim — Regime-Aware Grid Trading System

Seraphim is a grid-based basket EA for MetaTrader 5, paired with a Python automation layer (Antigravity) that runs overnight backtests, ranks parameter sets, and manages deployments on a remote VPS — all synced through OneDrive.

---

## Repository Structure

```
forex_grid/
├── EA/
│   └── Seraphim.mq5              ← MQL5 Expert Advisor (compile this)
│
├── archangel_infra/
│   ├── remote_runner.py          ← VPS backtest orchestrator (run on VPS)
│   ├── single_test_runner.py     ← Single backtest executor
│   ├── optimization_dashboard.py ← MT5 XML parser & ranker
│   ├── app.py                    ← Streamlit dashboard (run locally)
│   ├── setfile_exporter.py       ← Generate deploy-ready .set files
│   ├── compare_sets.py           ← Diff two .set files
│   ├── strategy_registry.py      ← CLI for managing deployed strategies
│   └── StrategyRegistry/         ← Strategy cards + registry.json
│
├── docs/
│   ├── 00_PROJECT_OVERVIEW.md    ← System philosophy and constraints
│   ├── 01_EA_SPECIFICATION.md    ← Full EA technical spec
│   ├── 02_ANTIGRAVITY_INFRASTRUCTURE.md ← Automation layer spec
│   ├── 03_STRATEGY_FRAMEWORK.md  ← Human 1hr/day operating workflow
│   ├── 04_AGENT_TASKS.md         ← Build task list for agents
│   ├── SERAPHIM_BUILD_LOG.md     ← EA build decisions and rationale
│   └── SETUP.md                  ← Project initialization checklist
│
└── Angel_settings/               ← Reference screenshots of original EA settings
```

---

## Prerequisites

| Requirement | Version | Notes |
|-------------|---------|-------|
| MetaTrader 5 | Build 3800+ | Strategy Tester required |
| Python | 3.10+ | For automation layer |
| OneDrive | Any | Sync bridge between local ↔ VPS |

```
pip install -r requirements.txt
```

---

## Quick Start: EA

1. Copy `EA/Seraphim.mq5` to your MT5 `MQL5/Experts/Advisors/` folder
2. Open MetaEditor → compile → verify 0 errors, 0 warnings
3. In MT5 Strategy Tester, select `Seraphim`, set symbol + dates, run backtest
4. Check Journal tab for `"Seraphim v1.0 initialized"` and optimization metrics at end

**Default parameters match the original ArchangelX 3.4 settings:**
- PipStep = 15.0, PipStepExponent = 1.5
- LotSize = 0.1, LotSizeExponent = 1.2, MaxLotSize = 1.0
- TakeProfit = 50 pips, LockProfit = 30 pips, TrailingStop = 10 pips
- MaxOrders = 10 per direction
- News filter ON (uses MT5 Economic Calendar, 60 min pre/post buffer)

---

## Quick Start: Automation (VPS)

On the VPS, `remote_runner.py` watches a OneDrive queue folder for `.set` files, runs BT + FT split backtests, and saves results to `results.csv`.

**Setup on VPS:**
1. Install Python 3.10+, OneDrive, and compile `Seraphim.ex5` in MT5
2. Verify constants in `remote_runner.py`:
   ```python
   MT5_TERMINAL_PATH = r"C:\Program Files\PU Prime MT5 Terminal-1\terminal64.exe"
   MT5_DATA_FOLDER_NAME = "CB73EB447A09F27F5775C81FBB987ED5"
   EA_NAME = r"Advisors\Seraphim.ex5"
   ```
3. Run the worker (leave running overnight):
   ```
   python remote_runner.py
   ```
4. Drop `.set` files into `OneDrive/RD_MT5_Sharing/Queue/` from your local machine
5. Results appear in `OneDrive/RD_MT5_Sharing/Results/results.csv`

**Configure test dates via `remote_config.json`** in the OneDrive sync folder:
```json
{
  "Symbol": "XAUUSD",
  "Deposit": "100000",
  "FromDate": "2025.02.01",
  "SplitDate": "2025.04.01",
  "ToDate": "2025.06.01",
  "ClearResults": false
}
```

---

## Quick Start: Dashboard (Local)

```
cd archangel_infra
streamlit run app.py
```

The dashboard shows scatter plots of BT vs FT metrics, lets you configure remote_config.json, and exports deploy-ready setfiles.

---

## Strategy Registry

Track deployed strategies with the CLI:

```bash
python archangel_infra/strategy_registry.py list
python archangel_infra/strategy_registry.py add
python archangel_infra/strategy_registry.py retire XAUUSD_Long_May2026
python archangel_infra/strategy_registry.py review XAUUSD_Long_May2026
python archangel_infra/strategy_registry.py expiring
```

---

## Operating Workflow (1 hour/day)

See `docs/03_STRATEGY_FRAMEWORK.md` for the full 11-step process. Summary:

1. **Observe regime** — ATR%, ADX, EMA slope on TradingView (10 min)
2. **Form hypothesis** — 3-4 week directional thesis (5 min)
3. **Optimize overnight** — queue .set files to VPS via OneDrive
4. **Rank results** — use dashboard or `optimization_dashboard.py` (10 min)
5. **Validate** — run double-pass BT/FT via `remote_runner.py`
6. **Deploy** — export setfile via dashboard, attach EA to MT5 chart
7. **Monitor daily** — kill if assumptions break, retire after 30 days

**Hard limits (prop firm):**
- Daily loss hard stop: -$5,000
- Daily profit target: +$1,000 (EA stops)
- Global equity floor: -$10,000 (permanent disable)

---

## Full Documentation

→ [`docs/`](docs/) — all spec docs, build logs, and operating guides
