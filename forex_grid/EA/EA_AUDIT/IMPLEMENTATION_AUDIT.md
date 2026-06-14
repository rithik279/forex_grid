# IMPLEMENTATION_AUDIT — Triton_v1.1_CURRENT.mq5 vs product spec

Verdicts: EXACT / MOSTLY_CORRECT / WRONG / MISSING / AMBIGUOUS.
"Patched" column refers to `Triton_v1.1_AUDITED.mq5`. Line refs are to CURRENT.

## General Trade Settings

| Setting | Product behavior | Current behavior | Code | Verdict | Patch | Regression risk | Deterministic test |
|---|---|---|---|---|---|---|---|
| AllowNewSequence | FALSE stops new sequences after current closes | IDLE branch returns when false; pending entries cancelled | ProcessSequenceImpl:1846 | EXACT | none | — | Set false mid-sequence: basket closes at TP, no new seq |
| StrategyDescription | display only | unused input | :126 | EXACT | none | — | n/a |
| TradeComment | prefix on orders | comment built per order | :1662,1731 | EXACT | none | — | inspect order comments |
| MagicNumber | instance identity, tag+filter all ops | all scans/orders filter magic+symbol | CountPositions etc. | EXACT | none | — | 2 instances same symbol, different magics: no cross-management |
| UseRandomEntryDelay | delay then re-check, runs BEFORE DelayTradeSequence | re-check implemented; **bypassed when DelayTradeSequence>0** (virtual seq started immediately on signal) | :1882-1893 | WRONG | P6: schedule delay first; at execute time route to virtual seq or first trade | Entry timing changes when both features on | seed=42, DTS=3: virtual anchor price = price at (signal+delay), not at signal |
| RandomSeed / Min/Max seconds | (Triton additions) deterministic PRNG | xorshift32, seeded, min==max handled | :420,1371 | EXACT | none | — | same seed twice ⇒ identical delays |
| LogLevel | (Triton addition) | leveled logger | :405 | EXACT | none | — | n/a |
| LicenseKey | UI artifact | unused | :137 | EXACT | none | — | n/a |

## Sequence Settings

| Setting | Product behavior | Current behavior | Code | Verdict | Patch | Regression risk | Test |
|---|---|---|---|---|---|---|---|
| ATR mode (negative pips) | negative input ⇒ ATR multiplier | ResolveDistance handles sign; GridStepDistance preserves sign | :451,662 | EXACT | none | — | PipStep=-1.5: step = 1.5×ATR |
| ATRPeriod | ATR period | iATR(chart TF) | :832 | EXACT | none | — | n/a |
| PipStep / PipStepExponent | step = PipStep×exp^(level−1) | `MathPow(exp, level-1)` via exponentIndex | :662-672 | EXACT | none | — | 10/1.5 ⇒ 10,15,22.5 |
| MaxPipStep | cap after exponent | capped post-pow | :667 | EXACT | none | — | 10/1.5/cap12 ⇒ 10,12,12 |
| DelayTradeSequence | skip N virtual levels; 4th = first real; only DoubleCheck filters re-validated before first real trade | virtual machine correct count; **re-validates ALL filters** before first real trade; Level (inflated by virtual skips) gates MaxOrders | :1930-1958 | MOSTLY_CORRECT→WRONG details | P11 (MaxOrders on real count), P12 (cancel when blocked), DoubleCheckFilters instead of AllFiltersPass | First real trade may now open against RSI (product-correct) | DTS=3: real trade fires at anchor−(10+15+22.5) pips; with DoubleCheckEMA=false and EMA now opposite ⇒ still opens |
| LiveDelay | N delayed, burst at level N+1 with delayed lots | counter/accum logic correct; burst = delayed + current | :1710-1756 | EXACT (per task rule 6.5) | doc ambiguity noted | — | LD=3,LSE=1,lot=1,combine ⇒ one 4-lot order |
| CombineLiveDelayTrades | one combined vs individual orders | both paths present; non-combined loop unbounded by MaxOrders | :1728-1745 | MOSTLY_CORRECT | P11: cap loop at MaxOrders | none practical | LD=3 non-combined ⇒ 4 orders, lots LSE^0..^3 |
| LotMultiplierFirstTradeAfterLD | multiplies only the trade after burst | dedicated post-LD branch, one-shot flag | :1759-1781 | EXACT | none | — | mult=2 ⇒ trade after burst = 2×level lot, next trade normal |
| TradeDirection | both/long/short on signal | checked in IDLE + OpenFirstTrade | :1685,1857 | EXACT | none | — | SHORT_ONLY: buy signals ignored |
| MaxOrdersPerDirection | max OPEN orders per direction | **gates on seq.Level (includes virtual skips)** → with DTS=3, 10 means 7 real orders | :1704,2000 | WRONG | P11: gate on CountPositions | deeper grids now possible (product-correct) | DTS=3, Max=5 ⇒ 5 real orders open |
| ReverseSequenceDirection | flips executed direction | flip in OpenFirstTrade + virtual start | :1688,744 | AMBIGUOUS (interaction w/ TradeDirection) | documented | — | Reverse=true: buy signal ⇒ SELL order |

## Money Management

| Setting | Product | Current | Code | Verdict | Patch | Risk | Test |
|---|---|---|---|---|---|---|---|
| TakeProfit | sequence-level from weighted avg | weighted avg vs Bid/Ask | :1507-1521 | EXACT | none | — | 2 trades, avg known ⇒ closes at avg+TP |
| StopLoss | per-trade from own entry | SL set on latest position after each open | :1250,1342 | EXACT | none | — | each position has own SL |
| LockProfitMinTrades | min open trades to arm lock | `TradeCount < min` early-out | :1526 | EXACT | none | — | min=2: 1 trade never locks |
| LockProfit | arm trailing at avg+lock | sets LockTriggered/refs | :1523-1551 | EXACT | none | — | lock at avg+30p |
| LockProfitCheckMode | 3 modes; non-destructive bar events | **destructive**: first IsBarCloseCheck consumes new bar; SELL/trailing miss same-bar events; lock+trail share globals | :1033-1057 | WRONG | P7: per-tick new-bar flags | both directions now evaluated same bar (product-correct) | BUY & SELL both locked on same M1 close |
| TrailingStop | basket trail after lock | peak-tracking, close on reversal ≥ dist | :1553-1594 | EXACT | none | — | peak−10p closes basket |
| TrailingCheckMode | 3 modes non-destructive | same destructive bug; PAUSED branch ungated | :1994,2029 | WRONG | P7 + gate paused branch | — | as above |
| AllowSamePairDirectionTrades | FALSE blocks same symbol+direction from other magics | scans other magics, same symbol+dir blocks; TRUE allows | :1286-1299 | EXACT (semantics doc'd AMBIGUOUS) | none | — | other-magic BUY open ⇒ our BUY blocked, SELL allowed |

## Compounding

| Setting | Product | Current | Code | Verdict | Patch | Risk | Test |
|---|---|---|---|---|---|---|---|
| UseCompounding | lot/MaxLots/MaxRunningLoss per threshold; CompoundScale=balance/threshold, no double scaling | **lot = (bal/thr)×((risk%×bal)/(pips×pipVal)) — balance applied twice** | :796-800 | WRONG | P10: single balance factor | lots shrink/grow correctly vs quadratically | bal=200k thr=100k risk1% pips100: lot = 2×(1000/100/pipVal), not 2×(2000/100/pipVal) |
| InitialAccountBalanceThreshold | reference | denominator | :796 | EXACT | — | — | above |
| RiskPercentForCompounding / RiskInPips | initial lot risk calc | in formula | :797 | MOSTLY_CORRECT | P10 | — | above |
| MaxLotSizeForCompounding | lot cap when compounding | caps base lot only; per-level exponent then capped by **MaxLotSize** not compounding cap | :798,819 | WRONG | P10: level cap uses compounding cap when compounding | — | LSE growth capped at MaxLotSizeForCompounding |
| MaxRunningLoss scaling | scales with threshold when compounding | not scaled | :1122 | MISSING | P10 | risk limit doubles at 2× balance (product-intended) | bal=200k thr=100k MRL=1000 ⇒ stop at −2000 |

## Lot Size

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| LotSize | base lot | fallback base | :812 | EXACT | none | first trade = LotSize |
| RiskPercent | needs SL; risk-based base | `RiskPercent>0 && StopLoss>0` | :803 | EXACT | none | risk1%/SL100p sizes correctly |
| LotSizeExponent | lot=base×LSE^level | level 0-based pow | :815-821 | EXACT | none | 0.1/1.2 ⇒ 0.10,0.12,0.14 |
| MaxLotSize | absolute cap, continue at cap | MathMin per level | :819 | EXACT | none | 2/2/cap5 ⇒ 2,4,5,5 |

## Weekend Closure

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| CloseForWeekend + days/times | closed window Fri close → Mon restart (wraps weekend) | **ShouldRestartAfterWeekend: `day > DayToRestart` ⇒ true → restarts immediately Friday after close; Saturday also "restart"** | :1019-1031 | WRONG | P5: minutes-of-week window | weekend close now actually works | Fri 21:00 close; ticks Sat/Sun/Mon 00:59 closed; Mon 01:00 open |
| Day inputs typed int | product UI: day-of-week enum | int 1..5 comment | :183-186 | MOSTLY_CORRECT | P5: ENUM_DAY_OF_WEEK (values identical) | none (int values preserved) | setfile DayToClose=5 still Friday |

## Session

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| TradeCustomTimes + windows | per-day HH:MM-HH:MM, "0"=off day, Sat/Sun off | parse + overnight wrap handled | :973-1004 | EXACT | none | "08:00-15:00" gates entries |
| ActionAtEndOfSession | **enum order 0=Close all, 1=Complete, 2=Pause** (screenshot) | enum 0=Complete,1=Close,2=Pause → setfile/optimizer values shifted | :63-68 | WRONG (enum order) | P3: reorder to product; default stays Complete | old Triton setfiles (if any) shift meaning — none shipped | optimizer Start/Stop shows Close all…Pause |
| Session COMPLETE behavior | manage normally until basket closes; no new sequences | manages BUILDING/LOCKED; **virtual sequences can fire first real trade during blocked session** | :2267-2272 | WRONG | P12: cancel flat virtuals when blocked | virtual seq cancelled instead of converting (product-correct) | DTS virtual active, session ends ⇒ no real trade fires |
| Session PAUSE | keep trades, EA off | pauses, exits still managed (safety bias) | :2257-2265 | AMBIGUOUS | documented | — | trades kept open, no adds |

## Equity Protector

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| MaxRunningLoss | close+stop, restart per mode; restart reachable | flag set; **EquityGuardCheck early-returns once latched → OnTick 1b restart NEVER reached (deadlock)**; also latched via shared g_equityStopped | :1147-1190, 2141-2163 | WRONG (critical) | P1+P2: restart check before guard; separate latches | restart now actually happens | MRL hit 14:00, RestartAfterHours=3 ⇒ trading resumes 17:00 |
| RestartEAAfterLoss/NextDayAt/AfterHours | two modes | CanRestartAfterLoss logic correct but unreachable | :1192-1221 | WRONG (unreachable) | P1 | — | above |
| DailyProfitTarget | close, stop, **auto-restart next day** | sets permanent g_equityStopped; resumes only if ResetGlobalEquityStop | :1154 | WRONG | P2: own latch, auto-clears next day at RestartNextDayAt | EA no longer dead after first target hit | target hit Tue ⇒ trades again Wed 01:00 |
| UltimateTargetBalance | permanent shutdown | shared flag (could be daily-reset by ResetGlobalEquityStop) | :1161 | WRONG | P2: own permanent latch | — | target hit ⇒ never trades again incl. next day |
| GlobalEquityStopType | 0=Absolute, 1=**Risked Amount**, 2=Risked % | only Absolute=0, Risked%=1 — **missing member, wrong index** | :76-80 | MISSING/WRONG | P4: 3-member enum, product order; implement balance−equity≥value | setfiles using Risked% shift index (product-correct now) | type=1 value=4000: stop at floating −4000 |
| ResetGlobalEquityStop | reset latch, resume | daily reset only when stopped | :1237 | MOSTLY_CORRECT | P2: applies to global-equity latch only (not ultimate) | — | stop hit, flag true ⇒ next day resumes |
| MinSecondsBetweenTrades | min gap between ANY trades of instance | per-direction seq.LastTradeTime | :1279-1284 | WRONG | P13: instance-global last-trade time | slower stacking across directions (prop-correct) | 60s: BUY then SELL 30s later blocked |

## Indicators

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| RSI use/TF/period/level mirror | sell ≥ OB, buy ≤ 100−OB | mirrored | :871-880 | EXACT | none | OB=80 ⇒ buy at RSI≤20 |
| EMA use/TF/periods/rule | trend stack; avoid-opposite allows flat | matches | :882-901 | EXACT | none | flat market avoid-opposite ⇒ both pass |
| DoubleCheckEMA/ADX first real trade | only these re-checked before first real trade | helper exists, used by LD burst; **virtual-delay path re-checks ALL filters** | :960,1939 | WRONG | use DoubleCheckFilters on virtual completion | first real trade can open against RSI (product-documented behavior) | DTS=3 DoubleCheckEMA=false, RSI no longer valid ⇒ trade still opens |
| ADX rule | AVOID_OPPOSITE trades when ADX<threshold (ranging) | **requires ADX≥threshold in both modes** | :911 | WRONG | AVOID_OPPOSITE: pass when ADX<threshold else with-trend | more entries in ranging mkts (product-correct) | ADX 20<30, avoid-opposite ⇒ entry allowed |
| Bollinger mode/TF/period/dev | avoid-extreme / only-extreme-counter | matches | :926-948 | EXACT | none | price>upper blocks buy (avoid) |

## News

| Setting | Product | Current | Code | Verdict | Patch | Test |
|---|---|---|---|---|---|---|
| UseHighImpactNews | block [event−before, event+after], base/profit ccy, high impact | window **reversed** (`from=now−before, to=now+after`); queried EVERY TICK; tester: calendar empty (silent no-news) | :1075-1101 | WRONG | P9: correct window, 30s cache, failure log | asymmetric before/after now honored | before=120,after=30: blocks 2h ahead, 30m behind |
| NewsTradesAction | enum order 0=Close all,1=Complete,2=Pause (screenshot); manage-normally on Complete | enum 0=Complete,1=Close,2=Pause; virtual leak same as session | :100-105, 2191-2232 | WRONG (order) | P3 + P12 | as session | optimizer enum order; virtual cancelled during news |
| CloseMinutesBefore/PauseMinutesAfter | window edges | used (swapped) | :1080-1081 | WRONG | P9 | — | above |

## Cross-cutting defects (no single input)

| Issue | Code | Verdict | Patch |
|---|---|---|---|
| OnTrade resets BUILDING sequences with 0 positions — kills DTS-virtual and LD-accumulation state on ANY trade event (incl. other direction) | :2302-2318 | WRONG (critical) | P8: require `TradeCount>0` |
| Duplicate pending-entry block in IDLE | :1868-1881 | dead/dup | P14 remove |
| Redundant CountPositions checks in StartDelayedVirtualSequenceForSignal | :749-750 | dup | P14 |
| Dead code: IsNewBarOnChart, g_lastEntryBarTime, DelayBarCounter, g_pending*SignalTime | :1059,380,277 | dead | P14 remove |
| NormalizeLot rounds to 2 decimals — breaks 0.001-step symbols | :471 | WRONG (minor) | round to volume step digits |
| g_targetReached written, never read | :387 | dead | replaced by P2 latches |

## Setfile-compatibility notes

- Input names and order: unchanged.
- Enum **value** reordering (P3, P4) intentionally matches the PRODUCT, per source hierarchy. Any setfiles built against Triton v1.1-CURRENT's wrong order must be re-checked (repo queue setfiles were built for ArchAngel/product order, so they become MORE correct).
- `DayToClose/DayToRestart` int→ENUM_DAY_OF_WEEK: stored integer values identical; no setfile impact.
