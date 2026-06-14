# System Audit — Failure Points & Hardening Plan

> Senior-backend review of the Triton pipeline as it stands today. Read
> ARCHITECTURE.md first. This document is blunt about where the system will
> break and what to do about it, ranked by severity.

---

## Executive summary

The architecture is **sound for what it is**: a single-worker batch system using
GitHub as a poor-man's message queue + database. It favors simplicity over
robustness, which is the right call at this scale. But there are **three
genuine data-loss / correctness bugs** live in the code right now, plus a set of
reliability gaps that will bite as volume grows. None require a rewrite — they're
targeted fixes.

The single biggest structural weakness: **`results.csv` is used as both the
message log and the database, rewritten in full on every job, with no
concurrency control.** That is the root of most of the serious issues below.

---

## 🔴 Critical — fix now (correctness / data loss)

### C1. `results.csv` push has no conflict handling → silent data loss
`push_results_to_github()` reads the current SHA, then PUTs the whole file. If
the SHA is stale (the file changed between GET and PUT — e.g. you cleared it from
the dashboard, or a previous push is still settling), GitHub returns **409
Conflict** and the push is **silently dropped**. The response status is never
checked. That job's result is gone.

This is currently rare because there's one worker, but it *will* happen whenever
the dashboard writes results-adjacent state or a push retries.

**Fix:** check the response; on 409, re-GET the file, re-append the row to the
*remote* content, re-PUT. Retry 3× with backoff. Better: don't push the whole
CSV — see C2.

### C2. Whole-file CSV rewrite is O(n) per job and a race magnet
Every single job base64-encodes and PUTs the **entire** `results.csv`. At 50
rows it's fine; at 5,000 rows every job re-uploads the full history, and the
window for a SHA conflict grows with it. Two workers would corrupt it outright.

**Fix (incremental):** append-only. Have the runner write per-job result files
(`data/results/<pass>.json`) and let the dashboard concatenate them on read. No
SHA races, no full rewrites, naturally idempotent (same pass overwrites itself).
The flat `results.csv` becomes a derived artifact, not the source of truth.

### C3. `ClearResults` flag causes an infinite clear loop
Flow today:
1. `sync_config_from_github()` overwrites the local config with GitHub's copy
   **every loop**.
2. `load_remote_config()` sees `ClearResults: true`, wipes `results.csv`, and
   resets the flag to `false` **in the local OneDrive file only**.
3. Next loop, step 1 overwrites local again with GitHub's copy — where the flag
   is **still `true`** — so it clears again. Forever, until you manually uncheck
   it in the dashboard.

**Fix:** reset the flag **on GitHub** (via API), not just locally — or have the
dashboard write `ClearResults` as a one-shot that it clears itself after the next
results push is observed. Simplest: after acting on the flag, the runner PUTs the
config back to GitHub with `ClearResults: false`.

---

## 🟠 High — reliability gaps

### H1. MT5 subprocess has no timeout → runner can hang forever
`subprocess.run([...], check=False)` has no `timeout`. If `terminal64.exe` hangs
(bad symbol, missing history, modal dialog), the runner blocks indefinitely and
silently stops processing the queue. No one finds out until results stop
appearing.

**Fix:** `subprocess.run(..., timeout=N)`; on `TimeoutExpired`, kill the process,
mark the job failed, move on.

### H2. No heartbeat → you can't tell if the VPS runner is alive
If the runner crashes, the RDP session drops, or **OneDrive sync is paused**
(it was literally showing "Paused" in the file explorer during this audit),
nothing surfaces it. The dashboard looks the same whether the worker is humming
or dead.

**Fix:** runner writes `data/runner_heartbeat.json` (timestamp + current job)
to GitHub every loop. Dashboard shows a green/red "Worker last seen: 12s ago"
badge. Trivial to add, huge operational win.

### H3. Reprocessing → duplicate result rows
`check_github_queue()` downloads a `.set` then deletes it from GitHub. If the
runner crashes between processing and the GitHub delete, or the same pass is
pushed twice, you get **duplicate rows** for the same Pass — and there's no
dedup on read.

**Fix:** make results keyed by `(SetFile, config-hash)`. With C2's per-pass
files this is automatic. Otherwise, dedup on `Pass` in the dashboard
(`drop_duplicates(subset=["SetFile"], keep="last")`).

### H4. OneDrive as a code-deploy channel is silent when it fails
The runner-code path depends on OneDrive actually syncing. Paused sync, a
conflict copy (`remote_runner-PC.py`), or a quota stall means the VPS runs
**stale code** with no signal.

**Fix:** stamp `__version__ = "<git-sha>"` in `remote_runner.py`, have the runner
print it on boot and include it in the H2 heartbeat. Then the dashboard can warn
"VPS running an old runner build."

### H5. No structured logging / no crash visibility
All diagnostics are `print()` to a console that vanishes when the RDP window
closes. The only crash handling is `input("Press Enter to exit...")`, which
**blocks a headless restart**.

**Fix:** log to a rotating file (`logging` module) in the OneDrive folder so you
can read it from your local machine. Drop the blocking `input()` in favor of a
logged traceback + clean exit (so a supervisor can auto-restart).

---

## 🟡 Medium — robustness & scale

### M1. Single serial worker
One `.set` at a time, two MT5 runs each (minutes apiece). Fine for tens of jobs,
painful for thousands. The folder state machine already supports it — you could
run N runner instances against N MT5 data folders, each claiming files via atomic
move.

### M2. GitHub API rate limits & retries
Every loop makes 2–3 API calls; every job makes several more. Authenticated
limit is 5,000/hr — comfortable now, but there is **no retry/backoff** on any
call. A transient 502 drops a config sync or a queue check for that loop.

**Fix:** a small `gh_request()` wrapper with retry + exponential backoff used
everywhere.

### M3. Regex HTML parsing is brittle
`parse_html_report()` depends on exact MT5 report wording ("Total Net Profit",
"Equity Drawdown Maximal"). An MT5 update or locale change silently yields zeros,
which then flow into scores as if real.

**Fix:** assert that at least Profit + Trades parsed non-empty; if not, mark the
job failed rather than recording a fake all-zero row.

### M4. Two different scoring formulas
The dashboard uses `compute_archangel_score` (0–100); the runner uses
`calculate_regime_score` (unbounded, different weights). Same conceptual goal,
two implementations that can disagree. Pick one, share it.

### M5. No config schema validation
`load_remote_config()` trusts whatever JSON is on GitHub. A malformed date or
empty symbol propagates straight into the `mt5.ini` and produces a silently
broken run.

**Fix:** validate types/format on load; refuse to run on invalid config and say
so in the heartbeat.

---

## 🟢 Low — hygiene

- **L1.** Secrets: `GITHUB_TOKEN` is an env var (good). Confirm it's never
  written into any committed file; rotate the PAT used in old `archive/` scripts.
- **L2.** `Results/` folder is recreated by the runner on boot even though
  results now live on GitHub — harmless but confusing. Either remove the local
  CSV path or document it as a local cache.
- **L3.** No tests at all. At minimum, unit-test `parse_html_report` and the two
  scoring functions against fixture reports — they're pure and easy to pin.
- **L4.** `desktop.ini` / OneDrive metadata can leak into globs; the `.set` glob
  is specific enough today but worth a guard.

---

## Recommended order of work

1. **C3** (infinite clear) — one-line-ish, actively dangerous. ✅ do first.
2. **H1** (subprocess timeout) + **H5** (drop blocking `input`, add file log) —
   makes the worker self-healing instead of silently wedged.
3. **H2** (heartbeat) + **H4** (version stamp) — gives you eyes on the system.
4. **C1/C2** (results integrity) — the real fix is per-pass result files; do it
   once and C1, H3, and future multi-worker all dissolve.
5. **M2** (retry wrapper), **M3** (parse assertions), **M5** (config validation)
   — defense in depth.
6. Everything else as capacity allows.

## What "foolproof" looks like when done

- Worker can crash, be killed, lose network, or run stale — and you **see it**
  on the dashboard within seconds (heartbeat + version).
- A hung MT5 can't freeze the pipeline (timeout).
- No job can silently vanish or double-count (per-pass files + dedup).
- A bad config or unparseable report fails **loudly** as a marked job, never as
  a fake zero-row.
- Clearing results is a true one-shot, not a sticky loop.
- You can scale to N workers without changing the data model.
