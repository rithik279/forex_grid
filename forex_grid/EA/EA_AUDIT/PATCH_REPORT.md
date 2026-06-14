# PATCH_REPORT — Triton_v1.1_CURRENT.mq5 → Triton_v1.1_AUDITED.mq5

Compile status: **Compile not verified** — no MetaTrader/MetaEditor on this machine. Brace/paren balance verified mechanically; no duplicate functions; all removed symbols grep-verified gone. Must be compiled in MetaEditor (see Manual verification).

Patch categories used: CRITICAL_CORRECTNESS, RISK_CONTROL, PRODUCT_FIDELITY, DETERMINISM, SIMPLIFICATION.

## P1 — Restart-after-loss deadlock (CRITICAL_CORRECTNESS)
**Functions:** `OnTick`, `EquityGuardCheck`, `CanRestartAfterLoss`, new `NextDayRestartReached`, new `ReleaseStoppedSequences`.
**Was:** `EquityGuardCheck()` returned true immediately once `g_equityStopped` latched; `OnTick` returned at step 1, so step 1b (restart) was dead code. MaxRunningLoss = permanent shutdown.
**Now:** restart check runs *before* the guard's latched return; restart clears `g_lossStopped` and resets STOPPED sequences.
**Regression risk:** EA resumes trading after a loss stop — that is the product behavior; anyone relying on the accidental permanence must use GlobalEquityStop instead.
**Verify:** backtest with tiny MaxRunningLoss; confirm log "Restarting after loss stop" at the configured time.

## P2 — Separate stop latches (RISK_CONTROL)
**Functions:** globals, `EquityGuardCheck`, `CheckDailyReset`, `TradingHardStopped` (new), `ProcessPendingRandomEntry`.
**Was:** one `g_equityStopped` flag for daily target, ultimate target, global equity stop (and doubled with loss stop). DailyProfitTarget bricked the EA permanently; `ResetGlobalEquityStop` could resurrect a "permanent" ultimate-target stop. `RiskStopCount` (OnTester hard disqualifier) incremented for daily profit target hits — profitable passes scored −100000.
**Now:** four latches with their own reset rules; sequences `Reset()` before being marked STOPPED; `RiskStopCount` increments only on GlobalEquityStop.
**Regression risk:** optimization scores change (daily-target passes no longer disqualified). Intended.
**Verify:** scenario tests in TEST_PLAN §14–16.

## P3 — Product enum order for session/news actions (PRODUCT_FIDELITY)
**Enums:** `ENUM_SESSION_END_ACTION`, `ENUM_NEWS_ACTION` → Close-all=0, Complete=1, Pause=2 (matches ArchAngelX optimizer screenshots). Defaults unchanged (Complete).
**Regression risk:** setfiles written against Triton-CURRENT's order shift meaning; setfiles written for the product become correct. No Triton setfiles shipped, so net risk ≈ 0.
**Verify:** MT5 input dialog shows dropdown order Close all / Complete / Pause.

## P4 — EQUITY_RISKED_AMOUNT added (PRODUCT_FIDELITY)
**Enum + `GlobalEquityStopTriggered`:** product has 3 stop types; "Risked Amount" (index 1) was missing and Risked% sat at the wrong index. Implemented as `balance − equity ≥ value` (floating loss), same as the OLD reference build.
**Regression risk:** setfiles with stop type 1 now mean Risked Amount (product meaning).
**Verify:** type=1, value=4000 → flat at −4000 floating.

## P5 — Weekend closure rewritten (CRITICAL_CORRECTNESS)
**Functions:** `ShouldCloseForWeekend`/`ShouldRestartAfterWeekend` → `InWeekendClosure` + `MinutesOfWeek`; inputs `DayToClose/DayToRestart` int → `ENUM_DAY_OF_WEEK` (stored values identical).
**Was:** `day > DayToRestart ⇒ restart` meant Friday-after-close and all of Saturday qualified as "restart"; weekend close lasted one tick.
**Now:** minutes-of-week window [close → restart], wrapping through the weekend.
**Verify:** TEST_PLAN §19.

## P6 — Random entry delay precedes DelayTradeSequence (PRODUCT_FIDELITY)
**Functions:** `ProcessSequenceImpl` IDLE branch (deduplicated), `ProcessPendingRandomEntry`.
**Was:** with both features on, the virtual sequence started instantly at signal — random delay bypassed.
**Now:** signal → schedule seeded delay → at execute time re-check permissions/filters → start virtual sequence (or first trade). Duplicate pending-entry block removed.
**Verify:** TEST_PLAN §1–2.

## P7 — Non-destructive bar-close events (CRITICAL_CORRECTNESS)
**Functions:** `IsBarCloseCheck`, new `UpdateBarFlags` (start of `OnTick`); `IsNewBarOnChart` (dead) removed.
**Was:** first caller of `IsBarCloseCheck` consumed the new bar; BUY's lock check starved SELL's, and lock starved trailing on the same bar.
**Now:** flags computed once per tick; every consumer sees the same event.
**Verify:** TEST_PLAN §12.

## P8 — OnTrade no longer wipes virtual sequences (CRITICAL_CORRECTNESS)
**Function:** `OnTrade`.
**Was:** `count==0 ⇒ "closed externally" ⇒ Reset()` fired for DTS-virtual and LD-accumulation sequences (zero positions by design) on ANY trade event, including the opposite direction opening.
**Now:** requires `TradeCount > 0`; TradeCount only refreshed when count > 0.
**Verify:** TEST_PLAN §4 (virtual seq survives an opposite-direction open).

## P9 — News window fixed + cached + correct API use (RISK_CONTROL)
**Function:** `IsHighImpactNewsNow`.
**Was:** query window reversed (`[now−before, now+after]`); `CalendarValueHistory` (returns bool) assigned to int — at most 1 event ever inspected; called every tick.
**Now:** window `[now−PauseAfter, now+CloseBefore]`; bool API checked, `ArraySize` used; 30 s cache; failure logged and treated as no-news.
**Regression risk:** asymmetric before/after configs change blocking times to the documented ones; ticks within 30 s of a window edge may differ by ≤30 s.
**Verify:** TEST_PLAN §18.

## P10 — Compounding math (PRODUCT_FIDELITY / RISK_CONTROL)
**Functions:** `ComputeBaseLot`, `ComputeLotForLevel`, `MaxRunningLossExceeded`.
**Was:** lot = (bal/thr) × (risk%×bal)/(pips×pipVal) — balance squared; per-level cap used `MaxLotSize` even when compounding; MaxRunningLoss not scaled.
**Now:** single balance factor (≡ threshold-risk × CompoundScale); per-level cap = `MaxLotSizeForCompounding` when compounding (treated as absolute — AMBIGUOUS, documented); MaxRunningLoss × balance/threshold when compounding.
**Verify:** TEST_PLAN §15.

## P11 — MaxOrders gates real positions (PRODUCT_FIDELITY)
**Functions:** `OpenGridTrade` (count check after LD-accumulation branch; non-combined burst loop capped), `ProcessSequenceImpl` line-2000 level check removed, `StartDelayedVirtualSequenceForSignal` redundant check removed.
**Was:** gate on `seq.Level`, which DelayTradeSequence inflates (DTS=3 stole 3 slots).
**Now:** `CountPositions(posType) >= MaxOrdersPerDirection` for real placements; virtual levels unbounded by it.
**Regression risk:** grids can now reach the full configured depth — deeper exposure than the buggy version. This is the product behavior; size MaxOrders accordingly.
**Verify:** TEST_PLAN §8.

## P12 — Virtual sequences cancelled in no-new-risk states (RISK_CONTROL)
**Functions:** new `CancelFlatVirtualSequence(s)`; news COMPLETE/PAUSE branches; session COMPLETE/PAUSE branches (weekend/equity paths already reset everything). News PAUSE now also pauses BUILDING (it previously kept grid-adding through "pause").
**Was:** a DTS-virtual or LD-accumulation sequence could fire its first REAL trade inside a news/session-blocked window.
**Now:** flat virtuals reset when the window blocks new risk.
**Verify:** TEST_PLAN §17–18.

## P13 — MinSecondsBetweenTrades per instance (PRODUCT_FIDELITY)
**Functions:** `MinTimeBetweenTradesOK()` (now global, set in `SendMarketOrder`), call sites in `OpenFirstTradeImpl`/`OpenGridTrade` moved so virtual phases aren't throttled. LD burst note: individual burst orders are placed in the same tick (product executes them "at the same time"); the min-gap applies between separate placements.
**Verify:** TEST_PLAN §16.

## P14 — DTS first-real-trade re-validation uses DoubleCheck only (PRODUCT_FIDELITY)
**Function:** `ProcessSequenceImpl` BUILDING/virtual branch: `IsEntrySignalValid` → `DoubleCheckFilters`.
**Was:** all filters (RSI/EMA/ADX/BB) re-checked — product says only DoubleCheckEMA/ADX gate the first real trade; with flags false the trade may open against the indicators.
**Regression risk:** more first real trades fire (product-correct).
**Verify:** TEST_PLAN §3.

## P15 — ADX AVOID_OPPOSITE_TREND per product doc (PRODUCT_FIDELITY)
**Function:** `FilterADX`.
**Was:** ADX ≥ threshold demanded in both modes; avoid-opposite implemented as !opposite.
**Now:** WITH_TREND_ONLY unchanged in effect; AVOID_OPPOSITE passes when ADX < threshold (ranging), with-trend only when trending.
**Verify:** TEST_PLAN §6.

## P16 — Cleanups (SIMPLIFICATION / DETERMINISM)
- Dead code removed: `IsNewBarOnChart`, `g_lastEntryBarTime`, `DelayBarCounter` (struct field + writes), `g_pending*SignalTime`, `g_targetReached`, duplicate IDLE pending block.
- `FinalizeSequenceMetrics` helper replaces 3 duplicated metric blocks (also fixes MaxDepth not updated on external closes).
- `NormalizeLot` rounds to 8 digits (0.001-lot-step symbols no longer truncated to 0.01 grid).
- PAUSED branch: pointless `CheckLockProfit` call removed; trailing gated by `TrailingCheckMode`.
- Magic number logged without `(int)` truncation.
- Header/version updated.

## Not changed (deliberately)
- Input names, order, and grouping (incl. `LicenseKey`, `ATRUsageInfo` info string).
- ATR-via-negative-pips convention (Triton design choice; product used a `Use ATR for pips` bool — adapter behavior documented in spec).
- `OnTester` scoring formula (Triton-specific, not product).
- Reverse×TradeDirection interaction (AMBIGUOUS — documented, kept deterministic current behavior).
- PAUSED exits kept active (safety bias vs product "EA off" — documented AMBIGUOUS).
- No persistence of stop latches across terminal restart (product used terminal global variables; DEFERRED — see TECHNICAL_VULNERABILITY_REPORT V-9).

## Manual verification required
1. Open `Triton_v1.1_AUDITED.mq5` in MetaEditor, compile: must be 0 errors / 0 warnings. Watch for: `ENUM_DAY_OF_WEEK` input, `CalendarValueHistory` bool usage.
2. Run TEST_PLAN smoke set (EURUSD M30, 2024, every-tick-real) twice with same seed → identical results (determinism).
3. Visual check of input dialog vs `Angel_settings/*.png` for label/order parity.
