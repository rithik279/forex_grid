# Triton System Architecture

> Single source of truth for how the Triton optimization → backtest → analytics
> pipeline works. Read this first.

---

## 1. What this system does

You run **parameter optimizations** in the MT5 Strategy Tester (thousands of
parameter combinations → XML export). This system takes those raw optimization
results and:

1. **Scores** every parameter set on prop-firm survivability (not raw profit).
2. **Generates** ready-to-run `.set` files for the best candidates.
3. **Re-tests** each candidate with a proper **backtest + forward-test split**
   on a remote VPS running MT5.
4. **Aggregates** the results into a dashboard for final selection.

The whole thing is operated from a **web dashboard** — you never touch the VPS
except to keep `remote_runner.py` running.

---

## 2. The three machines

| Machine | Runs | Role |
|---------|------|------|
| **Render** (cloud) | `dashboard/app.py` (Streamlit) | UI. You upload XMLs, score, push jobs, view results. |
| **GitHub** (cloud) | nothing — it's storage | Neutral data bus. The only thing Render and the VPS both can reach. |
| **VPS** (Windows RDP) | `remote_runner.py` + MT5 | Worker. Pulls jobs, runs MT5 backtests, pushes results. |

**Key constraint:** Render cannot reach the VPS, and the VPS has no inbound
access. Neither can talk directly. **GitHub is the bridge** — both poll it.

```
   ┌───────────┐         ┌────────────┐         ┌───────────┐
   │  RENDER   │  HTTPS  │   GITHUB    │  HTTPS  │    VPS    │
   │ dashboard │ ──────► │  data bus   │ ◄────── │  runner   │
   │  (UI)     │ ◄────── │  (storage)  │ ──────► │  + MT5    │
   └───────────┘         └────────────┘         └───────────┘
        writes:               holds:                writes:
     - queue/*.set         - queue/*.set          - results.csv
     - remote_config.json  - remote_config.json
        reads:             - results.csv             reads:
     - results.csv                                - queue/*.set
                                                  - remote_config.json
```

---

## 3. Two delivery channels (important)

There are **two separate channels**, and they carry different things:

| Channel | Carries | Mechanism | Latency |
|---------|---------|-----------|---------|
| **GitHub** | DATA — jobs, config, results | REST API polling | ~10 sec |
| **OneDrive** | CODE — `remote_runner.py` itself | File sync | ~30 sec |

**Why two?** Render can write to GitHub but not OneDrive. So *data* must flow
through GitHub. But *code* (the runner script) doesn't come from Render — it
comes from your local machine via Claude edits — so it rides the faster, simpler
OneDrive sync. The VPS just runs whatever `remote_runner.py` OneDrive gives it.

**This is why editing `remote_runner.py` auto-copies to OneDrive** (see §7).

---

## 4. Repository structure

```
forex_grid/
├── dashboard/
│   ├── app.py              # PRODUCTION — the Render Streamlit dashboard
│   └── requirements.txt    # Render build deps
│
├── archangel_infra/
│   ├── remote_runner.py    # PRODUCTION — the VPS worker (canonical source)
│   └── remote_runner.spec  # PyInstaller build (legacy — we run .py now, not .exe)
│
├── data/                   # The GitHub data bus (live state)
│   ├── results.csv         # runner writes  → dashboard reads
│   ├── remote_config.json  # dashboard writes → runner reads
│   └── queue/              # dashboard writes → runner consumes & deletes
│                           #   (GitHub-only; never exists on local disk)
│
├── optimization_templates/ # Base .set files — dashboard fills these per-pass
│   ├── XAUUSD_0612.set
│   ├── EURUSD_Long_Trend.set
│   └── ...
│
├── EA/                     # Expert Advisors (MT5 strategies)
│   ├── Triton_v1.1_AUDITED.mq5 / .ex5   # ACTIVE EA (source + compiled)
│   ├── Triton_v1.0.mq5 / .ex5           # previous version (still selectable)
│   └── EA_AUDIT/                        # audit reports, specs, input docs
│
├── docs/                   # All documentation (this file lives here)
│
├── .streamlit/config.toml  # Dashboard dark theme (Render reads from repo root)
├── render.yaml             # Render deploy config
├── requirements.txt        # root deps
├── .gitignore              # ignores __pycache__, build/, dist/, archive/
└── archive/                # dead/legacy files — gitignored, local only
```

**Gitignored / local-only:**
- `archive/` — all retired scripts and old result dumps. Kept locally for
  reference, never pushed.
- `__pycache__/`, `build/`, `dist/` — build artifacts.

---

## 5. End-to-end workflow

### Stage A — Optimize (manual, in MT5)
You run an optimization in the MT5 Strategy Tester over a date range, then run a
**forward** optimization over a later range. Export both as XML
(`*_optimization.xml` + `*.forward.xml`).

### Stage B — Score & queue (dashboard, "🔬 Set Finder")
1. Upload the BT XML + FT XML.
2. Dashboard parses both (`parse_mt5_xml`), merges on `Pass`, and computes the
   **Archangel X score** (`compute_archangel_score`) — a 0–100 prop-firm
   survivability metric weighting profit-per-drawdown (60%), DD consistency
   (25%), trade volume (15%), minus overfit penalties.
3. You filter by score/tier, pick the top N.
4. Click **Push to GitHub Queue**. For each pass, the dashboard takes the
   matching template from `optimization_templates/`, overwrites its parameters
   with that pass's values (`generate_set_content`), scales `LotSize` by the
   lot multiplier, and writes `data/queue/<strategy>_Pass<n>.set` to GitHub.

### Stage C — Configure the run (dashboard, "⚙️ Runner Config")
Set Symbol, Deposit, BT start / Split / FT end dates, EA version, MT5 paths.
Saved to `data/remote_config.json` on GitHub.

### Stage D — Process (VPS, `remote_runner.py`)
The runner loops forever. Each iteration:
1. `sync_config_from_github()` — pulls `remote_config.json` → OneDrive copy.
2. `check_github_queue()` — downloads any `data/queue/*.set` to local Queue,
   then **deletes them from GitHub**.
3. For each `.set` in the local Queue:
   - `load_remote_config()` — apply Symbol/dates/EA/paths.
   - Move `.set` → `Processing/`, copy into MT5's `Profiles/Tester/`.
   - **Run 1 (backtest):** build `mt5.ini` for `FromDate → SplitDate`, launch
     `terminal64.exe /config:mt5.ini`, parse the HTML report
     (`parse_html_report`) → `BT_*` metrics.
   - **Run 2 (forward):** same `.set`, dates `SplitDate → ToDate` → `FT_*`
     metrics.
   - `calculate_regime_score()` — a second, simpler survivability score.
   - Append one row (`BT_*`, `FT_*`, `RegimeScore`) to local `results.csv`.
   - `push_results_to_github()` — base64 the whole CSV, PUT to GitHub.
   - Move `.set` → `Processed/`, delete the HTML/PNG reports.

### Stage E — Analyze (dashboard, "📊 Results Analytics" / "📥 Queue Manager")
Dashboard reads `data/results.csv` from GitHub (60-second cache), strips failed
rows, renders the metrics table, BT-vs-FT charts, and a RegimeScore leaderboard.

---

## 6. The state machine (per .set file)

```
GitHub queue/        →  download
   │
   ▼
OneDrive Queue/      →  glob picks it up
   │
   ▼
OneDrive Processing/ →  MT5 runs BT + FT (file copied into MT5 Profiles/Tester)
   │
   ▼
OneDrive Processed/  →  done; row written to results.csv → pushed to GitHub
```

Each file is in exactly one folder at a time. Atomic `shutil.move()` between
folders is the lock — a crash leaves the file in whatever folder it was in, so
you can see where it stalled.

---

## 7. Code deployment (how runner edits reach the VPS)

Editing `archangel_infra/remote_runner.py` triggers a Claude **PostToolUse hook**
(`.claude/settings.json`) that copies the file to
`C:\Users\manmi\OneDrive\RD_MT5_Sharing\remote_runner.py`. OneDrive syncs it to
the VPS in ~30 seconds. The VPS picks up the new code the next time you restart
the runner.

```
Claude edits archangel_infra/remote_runner.py
        │  (PostToolUse hook fires)
        ▼
copy → OneDrive/RD_MT5_Sharing/remote_runner.py
        │  (OneDrive auto-sync ~30s)
        ▼
VPS/OneDrive/RD_MT5_Sharing/remote_runner.py
        │  (you restart: python remote_runner.py)
        ▼
new code live
```

The repo copy in `archangel_infra/` is the **version-controlled canonical
source**; the OneDrive copy is the **live deployment artifact**. They are kept
identical by the hook.

> ⚠️ A running Python process does **not** hot-reload. After an edit syncs, you
> must restart `remote_runner.py` on the VPS for changes to take effect.

---

## 8. How to operate it (quick reference)

**Normal run:**
1. Optimize in MT5 → export BT + FT XML.
2. Dashboard → Set Finder → upload, analyse, push top N to queue.
3. Dashboard → Runner Config → set symbol/dates/EA → save.
4. Make sure `python remote_runner.py` is running on the VPS.
5. Watch results land in Dashboard → Results Analytics.

**Change runner code:**
1. Edit `archangel_infra/remote_runner.py` (auto-syncs to OneDrive).
2. On VPS: stop the runner (Ctrl-C), `python remote_runner.py` again.

**Clear old results:**
Runner Config → check "Clear results.csv before next run" → save. *(See the
infinite-clear caveat in SYSTEM_AUDIT.md.)*
