# ArchangelX System — Project Overview

## What This Is

A complete, source-owned algorithmic trading system built on MetaTrader 5. The system consists of:

1. **A custom MQL5 Expert Advisor** (ArchAngelX clone) — the execution engine
2. **An automation infrastructure** (already built, in `Antigravity/`) — handles backtesting, optimization, result analysis, and deployment
3. **A regime-aware operating framework** — the human+agent workflow that decides WHAT to run, WHEN, and WHY

The edge does not come from the EA itself. The EA is the factory machine. The edge comes from **regime-aware setfile manufacturing** — identifying which market behavior exists right now, building a 3–4 week strategy for it, validating it, and retiring it when the regime changes.

---

## The Core Philosophy

> Strategies are not permanent. They are designed, deployed, monitored, and retired as regime assumptions change.

- **Reject timeless alpha** as the short-term goal
- **Adaptive regime exploitation** — calibrate to the current market environment
- **Strategy manufacturing process** — repeatable, not a one-off hunt
- **Risk framework first** — structure before logic before parameters
- **1 hour/day** operating commitment — optimizations run overnight on VPS unattended

---

## Repository Structure

```
ArchangelX/
│
├── docs/                          ← You are here — all design docs
│   ├── 00_PROJECT_OVERVIEW.md
│   ├── 01_EA_SPECIFICATION.md
│   ├── 02_ANTIGRAVITY_INFRASTRUCTURE.md
│   ├── 03_STRATEGY_FRAMEWORK.md
│   └── 04_AGENT_TASKS.md
│
├── EA/                            ← MQL5 source code
│   └── ArchangelX.mq5             ← The Expert Advisor (primary build target)
│
├── Antigravity/                   ← Existing Python automation (copied in)
│   ├── remote_runner.py           ← VPS test orchestrator
│   ├── single_test_runner.py      ← Single test executor
│   ├── optimization_dashboard.py  ← Optimization result analyzer
│   ├── app.py                     ← Main Streamlit dashboard
│   ├── setfile_exporter.py        ← Deploy-ready setfile generator
│   ├── compare_sets.py            ← Set file differ
│   ├── system_user_manual.md      ← Original system docs
│   └── ArcAngelAutomation/        ← Set files, XMLs, existing results
│
└── README.md
```

---

## Technology Stack

| Component | Tool | Purpose |
|-----------|------|---------|
| EA Engine | MQL5 / MetaTrader 5 | Trade execution and sequencing |
| Backtesting | MT5 Strategy Tester | Optimization and validation |
| Test Automation | Python (`remote_runner.py`) | Headless MT5 test queue |
| Result Analysis | Python + Streamlit | Dashboard and ranking |
| VPS Bridge | OneDrive sync | Local ↔ VPS file transfer |
| Regime Analysis | TradingView + Pine Script | Market structure observation |
| Agent Interface | Claude Code / Codex / Copilot | Code generation and iteration |

---

## Prop Firm Constraints (Non-Negotiable)

These are the hard limits the EA must respect. They cannot be violated.

| Parameter | Value |
|-----------|-------|
| Account Size | $100,000 (typical Forex prop) |
| Daily Loss Limit (Hard) | -$5,000 (5%) |
| Daily Loss Limit (Soft trigger) | -$3,000 to -$3,500 |
| Static Account Max Loss | -$10,000 (10%) |
| Daily Profit Target | +$1,000 |
| After daily target hit | Stop trading for the day |
| After hard daily loss hit | Close all, disable EA, no restart same day |
| After static loss hit | Close all, disable EA permanently until manual reset |
| News | No trading during high-impact news windows |
| Session | Instrument-specific (see EA spec) |
| Compounding | OFF for V1 (fixed lot sizing only) |

---

## Instrument Playbooks (Summary)

| Instrument | Direction | Session | Trend Tool | ADX | RSI | Entry Style |
|------------|-----------|---------|------------|-----|-----|-------------|
| XAUUSD | Long-only | London + early NY | EMA 30–60min | Often OFF | State filter (30min, period 100) | Controlled pullback grid |
| EURUSD | Both | London + NY overlap | EMA | ON | ON | Mean reversion |
| AUDJPY | Long-only | London | EMA 200 slow | ON | OFF | Pullback with Bollinger |
| NAS100 (CFD) | Long-only | New York only | EMA 1–3min fast | ON (75–100 period) | OFF | Momentum continuation |
| GBPUSD | Both | London + NY | EMA | ON | ON | Range/trend hybrid |
| USDJPY | Long-only | NY + Tokyo | EMA | ON | ON | Trend pullback |

---

## Build Priority Order

1. **`EA/ArchangelX.mq5`** — The EA. Everything depends on this.
2. **Wire EA into `Antigravity/remote_runner.py`** — Point automation at new EA
3. **Scoring upgrade in `remote_runner.py`** — Regime-aware validation scoring
4. **Claude Agent market scanner** — Automated regime hypothesis generator

Start with #1. Do not build anything else until the EA compiles and runs correctly in MT5.

---

## Key Definitions

**Sequence** — A group of related trades opened at grid intervals, tracked as a single unit, closed together when the basket hits TP or risk limits.

**Pip Step** — Minimum price displacement before adding the next trade in a sequence.

**Pip Step Exponent** — Multiplier that widens pip step with each successive trade (anti-martingale spacing).

**Lot Exponent** — Multiplier that increases lot size with each successive trade in a sequence.

**Weighted Average Entry** — `sum(lot_i × price_i) / sum(lot_i)` — the breakeven price of the entire basket.

**Lock Profit** — Mechanism that activates trailing protection once basket profit exceeds a threshold.

**Regime** — The current market behavior pattern (trending, ranging, expanding volatility, contracting volatility) that determines which strategy type is eligible to trade.

**Setfile** — A `.set` file containing all input parameter values for the EA. One setfile = one deployed strategy instance.

**Strategy Registry** — The versioned database of all setfiles: symbol, hypothesis, regime conditions, deployment date, expiry date, kill conditions, current status.
