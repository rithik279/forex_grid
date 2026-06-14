# TEST_PLAN — Triton_v1.1_AUDITED.mq5

All tests deterministic: Strategy Tester, "Every tick based on real ticks", fixed date range, fixed `RandomSeed`. Unless stated: EURUSD M30, 2024-01-02→2024-06-28, deposit 100k, defaults + `UseRSI=true RSIOverboughtLevel=70` as the signal source, `DelayTradeSequence=0`, `LiveDelay=0`, `UseHighImpactNews=false`, `TradeCustomTimes=false`. "Run twice" = same inputs+seed must produce byte-identical trade lists (determinism gate for every test below).

## 1. Random entry delay
Inputs: `UseRandomEntryDelay=true, RandomSeed=42, Min=5, Max=30`.
Expect: log "Random entry delay scheduled … after N seconds" with 5≤N≤30; order timestamp ≥ signal+N; re-run with seed 42 → same N sequence; seed 43 → different sequence; no order when filters invalidate during the delay (log "entry_filters_no_longer_valid").

## 2. Random delay + DelayTradeSequence ordering
Inputs: §1 + `DelayTradeSequence=3`.
Expect: at signal, NO virtual sequence; after N seconds, log "Random delayed entry → virtual sequence started"; virtual anchor = price at signal+N, not at signal.

## 3. DelayTradeSequence level skipping + DoubleCheck
Inputs: `DelayTradeSequence=3, PipStep=10, PipStepExponent=1.0, DoubleCheckEMAFirstRealTrade=false, UseEMA=true (trend rule with-trend)`.
Expect: first REAL trade ≈ 30 pips adverse from anchor (3 × 10-pip virtual levels); comment `_L3`; trade opens even if EMA flipped (DoubleCheck=false). With `DoubleCheckEMAFirstRealTrade=true` and EMA flipped: log "double_check_filters_failed", sequence reset, no trade.

## 4. Virtual sequence survives opposite-direction trade events
Inputs: §3 + TradeDirection=BOTH, signals both sides.
Expect: SELL order opening (OnTrade event) does NOT reset an active BUY virtual sequence — BUY virtual still completes at its own level (pre-patch it was wiped).

## 5. PipStepExponent / MaxPipStep
Inputs: `PipStep=10, PipStepExponent=1.5, MaxPipStep=0`, LSE=1.
Expect adverse spacing between consecutive entries: 10, 15, 22.5 pips (±spread). With `MaxPipStep=12`: 10, 12, 12.
ATR mode: `PipStep=-1.5` → spacing = 1.5×ATR(14) at the time of each add.

## 6. Indicator filters
RSI: OB=70 → sells only at RSI≥70, buys only at RSI≤30 (verify against indicator values at entry bars).
ADX WITH_TREND_ONLY thr=30: no entries while ADX<30.
ADX AVOID_OPPOSITE thr=30: entries occur while ADX<30 (ranging); while ADX≥30 only with-trend entries.
BB AVOID_EXTREME: no buy entries with Ask ≥ upper band.

## 7. LiveDelay / Combine / LotMultiplier
Inputs: `LiveDelay=3, LotSize=1.0, LotSizeExponent=1.0, CombineLiveDelayTrades=true, LotMultiplierFirstTradeAfterLD=2`.
Expect: no orders for levels 1–3; at level 4 ONE order of 4.0 lots, comment `_LD_combined`; next grid trade 2.0 lots (multiplier, once); following trade 1.0 lots.
`CombineLiveDelayTrades=false`: four 1.0-lot orders in the same tick (comments `_L0…_L3`), then 2.0, then 1.0.
Note product-doc ambiguity (3 vs 4 lots) recorded in spec — acceptance rule = delayed + current = 4.0.

## 8. MaxOrdersPerDirection
Inputs: `MaxOrdersPerDirection=5, DelayTradeSequence=3`, trending adverse market.
Expect: 5 REAL positions reachable (pre-patch: 2); never 6. Non-combined LD burst also never exceeds 5 positions.

## 9. TradeDirection / ReverseSequenceDirection
SHORT_ONLY: zero buy positions all run. Reverse=true: every RSI-overbought (sell) signal produces BUY positions. Documented: LONG_ONLY+Reverse ⇒ only SELLs (signal-side filtering).

## 10. TakeProfit (basket)
Two-trade sequence, entries known: basket closes when Bid ≥ weighted-avg + 50 pips (BUY). Assert no per-position TP field set (TP=0 on positions).

## 11. StopLoss (per trade)
`StopLoss=100`: every position has SL = own open price ∓ 100 pips; SL hit closes only that position; remaining sequence keeps managing (OnTrade sync keeps TradeCount).

## 12. LockProfit + Trailing + check modes (non-destructive bars)
`LockProfit=30, LockProfitMinTrades=2, TrailingStop=10, both modes=BAR_CLOSE_M1`.
Expect: lock never triggers with 1 trade; with ≥2 trades, lock arms when M1 close has price 30 pips beyond weighted avg; trailing closes basket at peak−10 pips, evaluated on M1 closes only. Cross-check: run with simultaneous BUY and SELL baskets — both must arm/trail on the SAME M1 bar (pre-patch only the first evaluated).

## 13. AllowSamePairDirectionTrades
Second EA instance (different magic) holds BUY: with `false`, our buy-signal sequence blocked (no order); sell sequence still opens. With `true`, both open.

## 14. Equity protector — separation of stops
a) `DailyProfitTarget=200`: target hit → all closed, no trades rest of day → trading resumes next day ≥ RestartNextDayAt (01:00). EA must trade on day 2 (pre-patch: dead forever).
b) `UltimateTargetBalance=100500`: hit → closed, NO trades for the remainder of the entire test, even with ResetGlobalEquityStop=true.
c) `GlobalEquityStopType=Risked Amount, Value=1000`: stop at balance−equity ≥ 1000; with `ResetGlobalEquityStop=true` resumes next day, with `false` stays stopped.

## 15. Compounding
`UseCompounding=true, Threshold=100000, Risk%=1, RiskInPips=100, MaxLotCompounding=10`, deposit 200k.
Expect first lot = (1%×200k)/(100p×pipValue) — exactly 2× the 100k-deposit lot (pre-patch 4×). `MaxRunningLoss=1000` → stop at −2000 floating. Level lots capped at 10.0 regardless of LSE.

## 16. MaxRunningLoss restart + MinSecondsBetweenTrades
a) `MaxRunningLoss=500, RestartEAAfterLoss=Restart In Hours, RestartAfterHours=3`: stop at −500, log restart exactly ≥3h later, new sequences after. With Restart Next Day + RestartNextDayAt=01:00: resumes next day ≥01:00.
b) `MinSecondsBetweenTrades=60`: minimum 60 s between ANY two order placements of the instance (check BUY then SELL timestamps; pre-patch they could be simultaneous).

## 17. Session handling
`TradeCustomTimes=on, Monday="08:00-15:00"`, others "0".
COMPLETE: no first trades outside window; open basket continues grid+exits until it closes; virtual sequence active at 15:00 is cancelled (log "session_blocks_new_entries"), no real trade after 15:00 from it.
CLOSE_ALL: flat at 15:00:00 ±1 tick.
PAUSE: positions kept, no adds, TP/armed-trailing exits still honored (documented bias).
"0" day: zero entries that day. Tuesday "0" with Monday basket open: basket still managed (COMPLETE).

## 18. News handling (live/demo only — calendar absent in tester)
`UseHighImpactNews=true, CloseBefore=120, PauseAfter=30`, action=Complete.
Expect: new sequences blocked from 2h before to 30 min after a high-impact base/profit-currency event (pre-patch window was mirrored); virtual sequences cancelled at window start; open baskets managed throughout. CLOSE_ALL: flat at window start, resumes after. Tester run must log "News calendar query failed … treating as no news" at most once per 30 s and trade as if no news.

## 19. Weekend close/restart
`CloseForWeekend=true, Friday 21:00 → Monday 01:00`.
Expect: flat from Fri 21:00; ZERO activity Sat/Sun (pre-patch: restarted instantly); first activity Mon ≥01:00. Also test wrap config Sunday 23:00 → Friday 22:00 sanity.

## 20. Reconstruction after restart
Mid-sequence (3 BUY positions), remove EA / re-attach (or change a comment input to force reinit).
Expect: log "Reconstructed BUY seq: 3 trades avg=…"; TP/lock computed from the same weighted average; grid adds continue at correct spacing.
KNOWN LIMITS (documented, not bugs to assert): virtual DTS progress, LD accumulation lots, lock/trailing armed state, and stop latches do NOT survive reinit — sequence resumes as a plain basket. Combined-LD sequences reconstruct as a single position with correct weighted avg.

## 21. Determinism master test
Full-feature config (random delay + DTS + LD + lock/trail + compounding), seed 42: run 3×. Trade list, OnTester score, and metrics print must be identical. Change only seed → different entries, same structural behavior.
