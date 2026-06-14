# Antigravity Infrastructure — Complete Reference

## Overview

The Antigravity system is the **automation layer** around the EA. It handles:
- Running batches of backtests and forward tests on the VPS headlessly
- Collecting and storing results in a structured CSV
- Analyzing and ranking optimization results
- Generating deploy-ready setfiles
- Providing a Streamlit dashboard for monitoring

**The Antigravity code already exists** in `Antigravity/`. Do not rewrite it — extend and integrate it with the new EA.

---

## Architecture: How Everything Connects

```
LOCAL MACHINE (Controller)
│
├── app.py                     ← Streamlit dashboard (UI)
├── optimization_dashboard.py  ← Optimization XML analyzer
├── remote_runner.py           ← Main orchestrator (also runs on VPS)
├── single_test_runner.py      ← Single-test runner (legacy)
├── setfile_exporter.py        ← Deploy-ready setfile generator
└── compare_sets.py            ← Set file differ

         ↕ OneDrive sync (C:\Users\manmi\OneDrive\RD_MT5_Sharing\)

VPS (Executor)
│
├── remote_runner.py           ← Same file, runs here watching the queue
├── terminal64.exe (MT5)       ← Launched headlessly by remote_runner
└── ArchangelX.mq5 (compiled) ← The EA being tested
```

---

## OneDrive Bridge — Folder Structure

```
C:\Users\manmi\OneDrive\RD_MT5_Sharing\
│
├── Queue\                     ← Drop .set files here to queue backtests
├── Processing\                ← File moves here while being tested
├── Processed\                 ← File moves here after test completes
├── Results\
│   └── results.csv            ← Master database of all test results
├── deploy_ready_setfiles\     ← Output folder for deployment setfiles
└── remote_config.json         ← Dynamic config (symbol, dates, etc.)
```

### remote_config.json Format
```json
{
  "Symbol": "XAUUSD",
  "Deposit": "100000",
  "FromDate": "2025.02.01",
  "SplitDate": "2025.04.01",
  "ToDate": "2025.05.23",
  "ClearResults": false
}
```
Changing this file on your local machine immediately affects the next test the VPS picks up. No VPS login required.

---

## File: `remote_runner.py`

**What it does:** Watches the Queue folder. For each `.set` file found:
1. Moves file to Processing
2. Copies it to MT5's `MQL5/Profiles/Tester/` folder
3. Generates an MT5 `.ini` config for the **backtest period** (FromDate → SplitDate)
4. Launches `terminal64.exe /config:mt5.ini` — runs MT5 headlessly
5. Waits for the HTML report to appear
6. Parses the HTML report for: Profit, Drawdown, DrawdownPct, Trades, WinRate, ProfitFactor, ExpectedPayoff, AvgProfitTrade, AvgLossTrade, MaxConsecLosses
7. Generates a second `.ini` for the **forward test period** (SplitDate → ToDate)
8. Repeats steps 4–6 for the forward period
9. Appends combined BT + FT metrics as one row in `results.csv`
10. Moves the `.set` file to Processed

**Key constants to update when switching to new EA:**
```python
EA_NAME = r"Advisors\ArchangelX.ex5"   # relative to MQL5\Experts
MT5_TERMINAL_PATH = r"C:\Program Files\PU Prime MT5 Terminal-1\terminal64.exe"
MT5_DATA_FOLDER_NAME = "CB73EB447A09F27F5775C81FBB987ED5"  # MT5 hash folder
```

**results.csv columns:**
```
Timestamp, SetFile, Pass,
BT_Profit, BT_Drawdown, BT_DrawdownPct, BT_Trades, BT_WinRate,
BT_ProfitFactor, BT_ExpectedPayoff, BT_AvgProfitTrade, BT_AvgLossTrade, BT_MaxConsecLosses,
FT_Profit, FT_Drawdown, FT_DrawdownPct, FT_Trades, FT_WinRate,
FT_ProfitFactor, FT_ExpectedPayoff, FT_AvgProfitTrade, FT_AvgLossTrade, FT_MaxConsecLosses
```

---

## File: `optimization_dashboard.py`

**What it does:** Parses MT5 Optimization XML exports (the bulk results from a full genetic optimization run) and produces a ranked leaderboard.

**Input:** `*.xml` and `*.forward.xml` files in the XMLs folder.

**Output:** `Dashboard_Output.csv` with:
- BT Profit, BT Equity DD%, BT Trades
- FT Profit, FT Equity DD%, FT Trades
- Original Total Profit (BT + FT sum)
- Lot Multiplier (user input: RequiredDrawdown / EstimatedMaxDD)
- Estimated Total Profit (OriginalTotalProfit × LotMultiplier)
- Estimated Drawdown (EstimatedMaxDD × LotMultiplier)

**Filter logic (hardcoded in script):**
- FT Trades / BT Trades ratio must be between 2.2:1 and 3.7:1
- Remove duplicate Pass IDs
- Round all values to 2 decimal places

**Run command:** `python optimization_dashboard.py`

---

## File: `app.py`

**What it does:** Streamlit dashboard with two main functions:
1. Visualize `results.csv` from `remote_runner.py` — scatter plots, rankings
2. Export deploy-ready setfiles for selected Pass IDs (calls `setfile_exporter.py`)

**Sidebar controls:**
- Batch folder path (for optimization XML files)
- Remote runner config (symbol, deposit, date range, clear results flag) — writes to `remote_config.json`

**Run command:** `streamlit run app.py`

---

## File: `setfile_exporter.py`

**What it does:** Takes a list of Pass IDs, finds the corresponding `.set` files, injects override values (License Key, MagicNumber, Risk settings), and saves clean deploy-ready files.

**Key behavior:**
- Reads original `.set` file
- Applies lot multiplier (RequiredDrawdown / EstimatedMaxDD) to `inpLotSize`
- Saves to `OneDrive/.../deploy_ready_setfiles/`

**Important:** When switching to the new EA, the `inpLotSize` field name must match exactly what ArchangelX.mq5 uses. Current name in setfiles: `LotSize` (without the `inp` prefix — check during EA build).

---

## File: `compare_sets.py`

**What it does:** Diffs two `.set` files and prints which parameters differ. Use this to:
- Debug why one setfile behaves differently from another
- Verify that exported setfiles match expected values
- Identify which parameters changed during optimization

**Run command:**
```bash
python compare_sets.py path/to/file1.set path/to/file2.set
```

---

## Workflow A: Optimize → Rank → Select

```
1. Run MT5 genetic optimization (manual, in MT5 Strategy Tester)
   - Export results as XML (Right-click → Export)
   - Export forward test results as .forward.xml
   
2. Place XML files in Antigravity/XMLs/
   - Naming: <symbol>_<date>.xml and <symbol>_<date>.forward.xml

3. python optimization_dashboard.py
   - Produces Dashboard_Output.csv

4. Open Dashboard_Output.csv in Excel
   - Set RequiredDrawdown in the input field
   - Review rankings (Original Total Profit + FT/BT ratio filter)
   - Note Pass IDs to investigate further

5. streamlit run app.py
   - Export selected Pass IDs as deploy-ready setfiles
```

---

## Workflow B: Validate Top Setfiles (Double-Pass Test)

```
1. From optimization ranking, take top 10–20 Pass IDs

2. Get their .set files from ArcAngelAutomation/Generated_Sets/
   (or generate them via setfile_exporter.py)

3. Copy .set files to:
   C:\Users\manmi\OneDrive\RD_MT5_Sharing\Queue\

4. Update remote_config.json if needed (symbol, dates, deposit)

5. On VPS (or locally): python remote_runner.py
   - Processes each file: runs BT + FT, saves to results.csv
   
6. streamlit run app.py
   - Review results.csv: compare BT vs FT performance
   - Look for files that perform consistently in both windows
```

---

## Workflow C: Deploy

```
1. Select surviving setfiles from Workflow B validation

2. In app.py sidebar → Export Deploy-Ready Files
   - Enter Pass IDs
   - Click Export
   
3. Files appear in: OneDrive/.../deploy_ready_setfiles/

4. On VPS:
   - Open MT5
   - Open chart for the instrument
   - Drag ArchangelX EA onto chart
   - Load inputs from the deploy-ready .set file
   - Verify EA is running (smiley face on chart)
```

---

## VPS Setup Requirements

For `remote_runner.py` to work on the VPS:

```
1. Python 3.10+ installed
2. OneDrive installed and synced (same account as local machine)
3. MT5 installed with the broker
4. ArchangelX.ex5 compiled and placed in:
   MT5_DATA_FOLDER\MQL5\Experts\Advisors\ArchangelX.ex5
5. remote_runner.py updated with correct:
   - MT5_TERMINAL_PATH
   - MT5_DATA_FOLDER_NAME (the hash)
   - EA_NAME
6. remote_runner.py running (can be set as a scheduled task or run manually)
```

**Finding the MT5 Data Folder hash:**
- Open MT5
- Tools → Options → Files tab
- Click "Open data folder" — the path shown contains the hash

---

## Integration Point: Switching to New EA

When `ArchangelX.mq5` is compiled and ready, update these in `remote_runner.py`:

```python
# OLD:
EA_NAME = r"Advisors\Archangel_X-v3.4.ex5"

# NEW:
EA_NAME = r"Advisors\ArchangelX.ex5"
```

Everything else stays the same. The automation infrastructure is EA-agnostic — it just loads setfiles into whatever EA is configured.

**Critical:** The `.set` file format must match the new EA's input parameter names exactly. If parameter names change, old setfiles will not load correctly. The `setfile_exporter.py` must be updated with new field names.

---

## Adding Regime-Aware Scoring (Future Enhancement)

The current `remote_runner.py` saves raw metrics. The planned upgrade adds a scoring column to `results.csv`:

```python
def calculate_regime_score(bt_metrics, ft_metrics):
    """
    Score a setfile on prop-firm survival probability, not raw profit.
    Higher is better.
    """
    score = bt_metrics.get('BT_Profit', 0) + ft_metrics.get('FT_Profit', 0)
    
    # Reward consistency
    if ft_metrics.get('FT_Profit', 0) > 0 and bt_metrics.get('BT_Profit', 0) > 0:
        score += 300  # both periods profitable
    
    # Penalize high drawdown
    score -= bt_metrics.get('BT_Drawdown', 0) * 1.5
    score -= ft_metrics.get('FT_Drawdown', 0) * 2.0  # forward DD weighted more
    
    # Penalize very low trade count (over-filtered)
    if bt_metrics.get('BT_Trades', 0) < 5:
        score -= 500
    
    # Reward good FT/BT trade ratio (2.2:1 to 3.7:1 is ideal)
    if bt_metrics.get('BT_Trades', 1) > 0:
        ratio = ft_metrics.get('FT_Trades', 0) / bt_metrics['BT_Trades']
        if 2.2 <= ratio <= 3.7:
            score += 200
    
    return round(score, 2)
```

This function can be added to `remote_runner.py` and called after metrics are parsed, then saved as an additional column `RegimeScore` in `results.csv`.
