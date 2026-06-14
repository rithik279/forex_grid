# OVERALL_IDEA_VIABILITY_REPORT — blunt assessment

Project: source-owned ArchAngelX/Triton grid EA + regime-aware setfile manufacturing + automated MT5 optimization + prop-firm deployment.

## 8.1 Core thesis check
Thesis: "The edge is not the EA; it is regime-aware setfile manufacturing, validation, deployment discipline, and risk control."

- **Technically plausible?** Partially. The honest version: grid systems harvest mean-reversion premium and look great until a trend regime eats the cushion. "Regime-aware deployment" is a claim that you can switch the harvester off before the eating starts. That is a *forecasting* claim wearing process clothing. Process discipline is real edge against yourself; it is not market edge by itself.
- **Must be true:** (1) regimes persist longer than your detection lag + deployment lag; (2) your regime labels are decidable in real time, not hindsight; (3) per-regime expected loss in the WRONG regime is small enough that classification errors don't dominate; (4) prop-firm rules leave enough drawdown room for the grid's natural equity dips.
- **Proof it works:** a 90-day forward log where regime-labeled setfiles outperform an always-on control of the same setfiles, with classification decided BEFORE outcomes. **Disproof:** regime-switched portfolio ≈ or < always-on control, or regime labels flip-flopping faster than the weekly cycle.
- **Is the system designed to collect that evidence?** Not yet. There is a Strategy Registry concept (Full_IDEA.txt) but no control group, no pre-registered hypothesis cards in code, no label-vs-outcome database. Phase-2 "structured data layer" is actually the most important unbuilt piece.

## 8.2 Prop-firm reality check
- Grid baskets concentrate loss in rare deep sequences. Prop dailies (typically 4–5%) are exactly the constraint a deep grid violates. `MaxRunningLoss` + `GlobalEquityStop` now work (post-patch), but a 10-level LSE=1.2 grid on a vol spike can blow through a daily limit between ticks — closes are market orders with slippage.
- Trailing-drawdown firms are nearly incompatible with grid equity profiles (locked-in highwater + subsequent basket dip = breach while net profitable).
- Consistency rules: basket closes produce lumpy P/L days — check each firm's rule before deployment.
- News restrictions: many firms ban holding through red-folder news; EA's news filter is calendar-dependent and OFF in backtests (V-10) — live behavior must be verified per broker-terminal.
- Multiple accounts running similar sets: firms detect copy-trading patterns; random entry delay obfuscates fingerprints but does NOT decorrelate risk — all accounts still hold the same direction into the same news candle.
- **Verdict:** usable only on static-drawdown firms, shallow grids (MaxOrders ≤ ~5, LSE ≤ ~1.3), hard equity stop well inside the daily limit, and news-flat policies. The aggressive ArchAngel marketing presets are not prop-survivable.

## 8.3 Grid/martingale risk review
- **Where money is made:** ranging/mean-reverting regimes, low-vol drift, post-spike reversion. Lots of small basket wins.
- **Where money dies:** sustained one-directional trends (rate shocks, risk-off USD moves), weekend gaps, liquidity holes, spread blowouts at rollover/news — one deep basket can return months of gains.
- **Most likely failure:** slow bleed-to-blowup: months of +1%/week, then one −30% basket week. **Most catastrophic:** gap through all grid levels + slippage on the equity-stop close (stop executes far beyond the configured loss).
- **Mandatory guardrails before live:** per-instance MaxRunningLoss sized off worst historical adverse excursion ×2; GlobalEquityStop (risked-amount) at account level; weekend close ON; news close-all for red folders; MaxOrders cap that bounds worst-case lots; portfolio kill-switch outside MT5 (account-level monitor that flattens everything).

## 8.4 Backtesting/optimization validity
What would make our backtests deceptive, in likelihood order:
1. **News filter silently off in tester** (V-10) — live trades fewer/different sequences than backtest.
2. **Multiple-comparison mining:** thousands of optimizer passes per symbol (the repo's `_all/` folders are literally that) — the survivors are noise-fit by construction. Cluster-center selection (Full_IDEA Rule 2) helps; it is not sufficient.
3. Spread/slippage assumptions: grids add at adverse extremes where spreads widen; fixed-spread tests flatter results materially.
4. Calm-regime overfit: 2023–2024 ranges reward exactly the configs that die in 2022-style trends. Required protocol: every candidate must run through a hostile period (e.g. 2020 Mar, 2022) and merely *survive* (equity stop not hit), even if unprofitable.
5. Optimizing profit instead of survival — partially addressed: OnTester already penalizes DD/depth/duration and (post-patch) only disqualifies true equity-stop hits.
**Minimum evidence to deploy a setfile:** real-tick backtest ≥3y incl. one hostile year; walk-forward with ≥4 OOS windows, OOS PF ≥ 1.2 and DD within prop limits; parameter-neighborhood stability (±20% on PipStep/TP/LSE stays profitable); 4+ weeks demo forward matching backtest trade cadence; metrics that matter: max adverse excursion, worst basket, DD duration, depth distribution — profit last.

## 8.5 Regime-aware setfile manufacturing
- Plausible if regimes are defined by *observable* filters (ADX/ATR/EMA states — the EA's own gates) rather than narrative labels. The Type1–4 taxonomy in Full_IDEA is reasonable.
- Missing: real-time regime decision rule (exact thresholds + timeframe), transition policy (what happens to open baskets when the label flips), retirement triggers (e.g. 2× backtest max DD or hypothesis invalidation), and the registry as *data* (Postgres/Pydantic) rather than documents.
- Honest risk: weekly hand-labeling drifts into hindsight. Pre-register: label written Monday, deployment decided same day, no edits.
- Eligibility = 8.4 evidence + explicit regime fingerprint + written invalidation condition. Retirement = invalidation condition hit, OR live DD > 1.5× backtest worst, OR 30 days with trade cadence ≠ backtest.

## 8.6 Portfolio-of-setfiles risk
- Correlated USD legs and correlated grid deepening are the killers: five "different" setfiles short USD pairs in a dollar rally = one big grid. Measure exposure as net lots per currency × current grid depth, not per-account P/L.
- Needed: portfolio exposure ledger (currency-bucket net lots, sum of worst-case basket losses), portfolio kill-switch (flatten all accounts at X% combined), concurrency caps (max N baskets building simultaneously per currency), and staggered news policy.
- Account-level limits are NOT enough — ten accounts each within limits can still be one correlated catastrophic bet.
- Random entry delay: cosmetic anti-fingerprinting only.

## 8.7 Operational risk
Could lose money: wrong setfile/magic/symbol-suffix attach (O-2), VPS reboot wiping stop latches (V-9), DST session shifts (O-3), calendar feed absent (O-4), optimizer output copied by filename (W-6), unmonitored overnight runner failures (W-2/W-10).
Automate: compile→test→report pipeline, setfile validation, deployment manifests, equity-guard alerts. Human approval: anything touching a live account, setfile promotion, magic assignment. Mandatory alerts: equity-guard trigger, EA reinit, failed close, calendar-empty-at-init, daily P/L summary.

## 8.8 Simplicity / scope control
Minimum viable version: **one EA, one symbol, three setfile identities (range MR / defensive MR / event-off), one prop-style demo account, manual weekly regime call, spreadsheet registry.**
Cut from V1: AI agents, RL, dashboards beyond one status page, multi-account scaling, TradingView/Pine validation layer, automated regime detection.
Complexity that helps: deterministic test harness, setfile validation gate, exposure ledger. Complexity that is false progress: agent frameworks before there is forward-test data to feed them; HUD/monitoring polish before alerting exists; more symbols before one symbol survives 90 days.

## 8.9 AI/RL/agent integration
Useful now: LLM for doc/audit work (this task), deterministic test generation, optimization-result summarization, registry data entry. Premature: regime-labeling agents (no labeled ground truth yet), portfolio intelligence (no portfolio), RL anywhere. RL's only realistic future seat is allocation across proven strategies — years away, needs a returns database that doesn't exist yet. Keep deterministic forever: order placement, risk stops, sizing. Never delegate to an LLM in live trading: any decision inside the order path. Highest-value AI engineering project here: the Phase-2 data layer (Pydantic schemas for regimes/hypotheses/deployments/results) — it builds real skill AND is the missing scientific instrument.

## 8.10 Missing considerations

| Issue | Why it matters | Severity | Test/mitigation | Blocks live? |
|---|---|---|---|---|
| Trailing-drawdown vs grid equity profile mismatch | Breach while net profitable | CRITICAL | Only static-DD firms; simulate firm rules on backtest equity curve (MonteCarloPropFirmSimulator exists — wire it in) | YES |
| Slippage on equity-stop market closes in fast markets | Configured max loss ≠ realized | HIGH | Stress test with 5–10× spread at stop events; size MaxRunningLoss with buffer | YES |
| Broker calendar/news feed differences | News filter no-ops on some terminals | HIGH | Init-time calendar count check (O-4) | YES (for news-dependent sets) |
| Prop-firm copy-trade/anti-EA detection across accounts | Account closures | HIGH | Read each firm's EA policy; vary seeds/magics/sizes; cap simultaneous accounts | YES for scaling |
| DST/session drift | Sessions shift 1h twice yearly | MEDIUM | O-3 checklist | No |
| Swap/commission on deep multi-day baskets | Carry erodes basket math | MEDIUM | Include real swaps in backtests; cap AvgDuration | No |
| Legal/tax of running many funded accounts | Jurisdiction-dependent | MEDIUM | Professional advice before scaling | For scaling |
| Psychological override risk (deleting stops mid-drawdown) | Historically how grid traders die | HIGH | Kill-switch authority outside the trader's hot path; written playbook | YES |
| Data quality of broker tick history vs prop broker | Optimizing on wrong microstructure | MEDIUM | Optimize on target-broker data only | No |
| Model risk of OnTester score itself | Score shapes the whole pipeline | MEDIUM | Periodically re-rank by raw survival metrics; check score↔live correlation | No |

## 8.11 Viability scores

```
Technical feasibility:            8/10  (EA + headless pipeline are solid post-patch)
Trading edge plausibility:        4/10  (regime-timing claim unproven; grid premium is real but fat-tailed)
Prop-firm suitability:            4/10  (only narrow firm/config subset; trailing-DD firms ~0)
Operational complexity:           5/10  (high but being tamed; alerting/persistence gaps remain)
Risk of catastrophic failure:     7/10  (high — inherent to grid; guardrails reduce, never remove)
Time-to-first-live-test:          7/10  (demo forward test reachable in ~2–4 weeks post-compile)
Scalability if proven:            6/10  (setfile manufacturing scales; correlated risk caps the ceiling)
```

**Verdict: PURSUE BUT NARROW SCOPE.**
The engineering is worth finishing and the manufacturing process is a genuinely good skill-building project. As a business, survival depends on rejecting the product's own aggressive presets: shallow grids, hard stops, static-DD firms only, one symbol until 90 days of forward evidence exist. Do not scale accounts before the portfolio exposure ledger exists. If the 90-day regime-vs-control experiment fails, keep the infrastructure, retire the strategy family.

## 8.12 Roadmap

| Phase | Goal | Deliverables | Pass/fail | Max complexity | Don't do yet |
|---|---|---|---|---|---|
| 0 Product-faithful EA | Compile + behavior parity | AUDITED EA, 0 warn; TEST_PLAN §1–13 green | Any spec test fails ⇒ fix before proceeding | One .mq5 file | Features beyond product |
| 1 Deterministic testing | Trust the harness | run.py steps 1–2; golden trade lists; 3× identical runs | Bit-identical reruns | Scripts only | Optimization |
| 2 Single-symbol optimization | One survivable setfile per identity (EURUSD) | Walk-forward protocol from §8.4; cluster-center sets + sidecars | OOS PF≥1.2, DD inside prop limits, hostile-year survival | ≤3 identities | Multi-symbol, AI |
| 3 Demo forward | Backtest↔live parity | 4–8 wk demo; cadence/DD comparison report; regime labels pre-registered weekly | Live within 1.5× backtest DD; cadence ±30% | Spreadsheet registry | Real money |
| 4 Tiny live / prop sim | Survive real frictions + firm rules | One static-DD challenge or micro-live; firm-rule simulator wired (MonteCarloPropFirmSimulator) | No equity-stop breach; rules respected | One account | Scaling |
| 5 Multi-setfile portfolio | Correlation reality check | Exposure ledger; portfolio kill-switch; 2–3 setfiles | Combined worst-case within account limit at all times | ≤3 sets, 1 account | More accounts |
| 6 Automation hardening | Unattended safe ops | V-9 persistence, alerting, W-1/W-2 fixes, status.json | One full unattended week, zero silent failures | — | AI agents |
| 7 Scale on evidence | Only after 0–6 green | Registry DB (Pydantic/Postgres); then agents for summarization | 90-day regime-vs-control experiment positive | Add one account/symbol at a time | RL |
