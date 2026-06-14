# SIMPLIFICATION_AND_UX_PLAN

Goal: a non-expert can run the whole loop (compile → smoke test → optimize → validate → deploy) from one command, with nothing load-bearing living in someone's head.

## 1. What can be simpler

| Idea | Classification | Note |
|---|---|---|
| One `run.py` entry point wrapping all infra scripts | SAFE_NOW | Pure orchestration; scripts already exist |
| Single `config.yaml` for terminal paths, data dirs, EA name, magic ranges | SAFE_NOW | Kills W-1 class bugs |
| Move ~10k generated `.set`/`.xml` artifacts out of source dirs into `/outputs` (gitignored) | SAFE_NOW | No behavior change |
| Delete duplicate `remote_runner.py`, dead `__pycache__`, `(1).set` duplicates | SAFE_NOW | |
| Sidecar JSON per setfile (symbol, EA, magic, regime, validation status) instead of filename parsing | SAFE_NOW | Replaces "auto-detect symbol from filename" hack |
| EA: collapse buy/sell pending-entry globals into a 2-element struct array | GOOD_LATER | Cosmetic; touches many lines — not worth regression risk now |
| EA: replace per-direction `SequenceInfo` twin-calls with array loop | GOOD_LATER | Same |
| EA: CSV-driven news fallback for tester parity | GOOD_LATER | Useful once news-filtered setfiles matter |
| EA: stop-latch persistence via GlobalVariables (V-9) | GOOD_LATER (required before live) | Small, contained |
| Remove LiveDelay/DelayTradeSequence/Reverse features to "simplify the EA" | DO_NOT_DO | Product behavior; setfile compatibility |
| Re-derive basket state purely from positions each tick (drop SequenceInfo) | DO_NOT_DO | Loses virtual-phase semantics that ARE the product |
| Collapse 4 stop latches back into one "stopped" flag | DO_NOT_DO | That was the bug |
| Reorder/rename inputs for aesthetics | DO_NOT_DO | Breaks setfiles/optimizer configs |

## 2. One point of entry

```
python run.py
  1. Compile EA            (metaeditor64 /compile:"EA\Triton_v1.1_AUDITED.mq5" /log — parse log, fail on warnings)
  2. Smoke backtest        (generate mt5.ini from template, launch /config:, assert report exists, print 6 key stats)
  3. Run optimization      (XML/ini from /configs, queue to remote runner)
  4. Validate setfiles     (schema + sidecar check + forbidden-param rules, e.g. LSE>2 reject)
  5. Export reports        (collect to /reports/<runid>/, summarize CSV)
  6. Launch MT5 profile    (correct terminal path from config.yaml)
  7. Audit EA behavior     (run TEST_PLAN smoke subset, diff against golden trade list)
  0. Doctor                (check paths, terminal exists, calendar enabled, git clean)
```
Every step: explicit success/failure line, log to `/logs/<timestamp>_<step>.log`, non-zero exit on failure. No step depends on a human remembering a path.

## 3. Suggested folder structure

```
forex_grid/
  docs/            ← product specs, audit reports (EA_AUDIT docs move here)
  ea/              ← .mq5 source only (compiled .ex5 → outputs)
  setfiles/        ← VALIDATED, deployable sets + sidecar .json (one folder per symbol)
  configs/         ← config.yaml, mt5.ini templates, optimization XML templates
  scripts/         ← run.py + infra modules (today's archangel_infra, deduplicated)
  data/queue/      ← (existing) pending jobs
  reports/         ← per-run backtest/optimization reports
  logs/
  outputs/         ← raw optimizer dumps, candidate sets (gitignored)
```

## 4. GUI automation hardening
The ini-file `/config:` launch pattern already used by `remote_runner.py` is the correct, headless approach — standardize on it. Rules:
- No click coordinates, no window-title matching, no timing sleeps anywhere in the pipeline.
- Generated `mt5.ini` per job, kept in the report folder for provenance.
- Verify outcomes by artifact (report file exists, mtime > launch, parse summary) — never by screenshot. Screenshot only as failure diagnostics.
- Idempotency: every job has a run-id; re-running a completed job is a no-op unless `--force`.
- `--dry-run` prints the ini + command without launching.
- Check subprocess exit codes (W-2) and add a per-job timeout + orphan-terminal kill.

## 5. Logging / reporting improvements
- EA: keep `LogLevel`; add one structured line per sequence close: `SEQ,symbol,magic,dir,depth,lots,duration_s,pnl,reason` — trivially parseable by dashboards.
- Mandatory alerts (before live): every `EQUITY GUARD` line, every reinit, every failed close → `SendNotification`/webhook.
- Runner: one `status.json` (last run, last success, queue length) the Streamlit dashboard reads instead of scraping CSVs.

## 6. What NOT to simplify (product-critical)
- Input names/order/groups, enum orders (now product-matched), MagicNumber semantics.
- Virtual-sequence machinery (DTS/LD) — it's the product's signature behavior.
- Seeded PRNG + determinism guarantees.
- The 4 distinct stop states and their reset rules.
- Weighted-average basket exits / per-trade SL split.
