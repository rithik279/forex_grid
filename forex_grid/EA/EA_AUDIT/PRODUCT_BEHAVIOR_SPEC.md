# PRODUCT_BEHAVIOR_SPEC — ArchAngelX → Triton

Source hierarchy used: `ArchAngel_Product_Input_Specs.txt` (primary) → `Angel_settings/*.png` screenshots (labels, defaults, enum order) → task acceptance rules → `Triton_v1.1_CURRENT.mq5` → `ArchAngelX_Rebuilt_OLD.mq5` (reference only).
PDFs in `Docs/` could not be text-extracted in this environment; the specs txt is treated as their extraction. Marked where this matters.

Conventions: "pips" = points × pip multiplier (10 on 3/5-digit symbols). Negative pip inputs = ATR multiplier mode (`ATRUsageInfo` line in product UI). All times are broker server time.

---

## General Trade Settings

| Setting | Intended behavior |
|---|---|
| `AllowNewSequence` | TRUE: trade normally. FALSE: stop opening **new** sequences; existing sequence managed to close. |
| `StrategyDescription` | Free text, display only. No behavior. |
| `TradeComment` | Appended to every order comment. |
| `MagicNumber` | Per-setfile/EA-instance identity. Tags orders, filters management, distinguishes setfiles on same symbol/account. Never weakened. Product warns: don't change while trades open. |
| `UseRandomEntryDelay` | Real delayed execution, not a skip: valid signal → schedule deterministic seeded random delay → at scheduled time re-check all permissions/filters → proceed if still valid, cancel otherwise. **Runs BEFORE DelayTradeSequence**: signal → random delay → re-check → virtual delay sequence (if enabled) → first trade / LiveDelay path. |
| `RandomSeed`, `RandomEntryDelayMin/MaxSeconds`, `LogLevel` | Triton additions (not in ArchAngelX UI). Needed for determinism. Documented as additions; appended without disturbing product input order. |
| `LicenseKey` | Product UI artifact. No behavior in Triton. |

## Sequence Settings

| Setting | Intended behavior |
|---|---|
| ATR mode | Negative value on any pip input → value × ATR(ATRPeriod). Positive → raw pips. (Triton convention replacing product's `Use ATR for pips` bool; preserves one-input-per-distance.) |
| `ATRPeriod` | ATR indicator period (chart TF). |
| `PipStep` | Distance between grid trades. |
| `PipStepExponent` | step(level) = PipStep × PipStepExponent^(level−1) for grid add level ≥ 1. Example: 10/1.5 → 10, 15, 22.5. |
| `MaxPipStep` | Cap applied **after** exponent. 0 = no limit. |
| `DelayTradeSequence` | Skips **virtual sequence levels**, not chart bars. N=3: levels 1–3 tracked virtually (anchor at signal price, advance per grid-step distances), 4th level = first REAL trade, placed at the price where trade 4 would have been. 0 = off. Before the first real trade, only `DoubleCheckEMA/ADX` re-validation applies (see Indicators). Virtual sequences carry **zero** real exposure and must be cancelled if a no-new-risk state (news/session/weekend/equity stop) arrives. |
| `LiveDelay` | N=3: levels 1–3 are deferred (lots accumulated virtually); when level 4's grid distance is reached, all delayed lots execute together with level 4. |
| `CombineLiveDelayTrades` | TRUE: one combined order = delayed lots + current level lot. FALSE: individual orders per level. **AMBIGUITY**: product doc's multiplier example implies burst = 3 lots for LD=3 (delayed only), but its own LiveDelay section says "execute all 4 trades at the same time". Task acceptance rule 6.5 (delayed + current) is implemented: burst = LD+1 levels of lots. |
| `LotMultiplierFirstTradeAfterLD` | Multiplies lot of the single trade placed **after** the LD burst. Never multiplies the burst itself. 1 = off. |
| `TradeDirection` | Both / Long only / Short only (enum order 0/1/2 confirmed by screenshot). Applied to the **signal** direction. **AMBIGUITY** with Reverse (below). |
| `MaxOrdersPerDirection` | Max **open real orders** in one direction. Virtual (delayed/LD) levels are not orders. |
| `ReverseSequenceDirection` | Flips executed direction of everything: buy signal → SELL sequence, sell signal → BUY. **AMBIGUITY**: product doesn't state whether TradeDirection constrains signal or executed direction when combined with Reverse. Implemented: TradeDirection filters the signal; Reverse then flips execution (LONG_ONLY + Reverse ⇒ only SELLs). Documented, deterministic. |

## Money Management

| Setting | Intended behavior |
|---|---|
| `TakeProfit` | **Sequence-level**, from lot-weighted average (basket breakeven). BUY: Bid − avg ≥ TP distance. SELL: avg − Ask ≥ TP distance. No per-trade TP. |
| `StopLoss` | **Per individual trade**, from that trade's own entry. 0 = off. |
| `LockProfitMinTrades` | Minimum open trade count before lock profit may trigger. |
| `LockProfit` | Sequence-level. When price is `LockProfit` distance beyond weighted average, trailing logic arms. 0 = off. |
| `LockProfitCheckMode` | On Bar Close (chart TF) / On Bar Close (M1) / Every tick. Bar events are **non-destructive**: BUY and SELL, lock and trailing, all observe the same new-bar event. |
| `TrailingStop` | Basket-level. After lock triggers, track favorable extreme; close entire sequence when price reverses by trailing distance from extreme. |
| `TrailingCheckMode` | Same three modes, same non-destructive rule. |
| `AllowSamePairDirectionTrades` | FALSE = protection mode: scan positions of **other** magic numbers on same symbol; same direction open elsewhere blocks a new sequence (opposite direction still allowed). TRUE = no blocking. (Product text phrases the flag inversely in one sentence; the label + example mean TRUE allows, FALSE blocks — matches default FALSE in screenshot with blocking described as the protective behavior. Implemented: `AllowSamePairDirectionTrades=true` ⇒ allow overlap; `false` ⇒ block. AMBIGUITY noted.) |

## Compounding

| Setting | Intended behavior |
|---|---|
| `UseCompounding` | LotSize, MaxLots, MaxRunningLoss become relative to `InitialAccountBalanceThreshold`. CompoundScale = Balance / Threshold. **No double scaling by balance.** |
| `InitialAccountBalanceThreshold` | Reference balance (e.g. 100k). |
| `RiskPercentForCompounding`, `RiskInPips` | Initial lot per sequence = (Risk% × Balance) / (RiskInPips × pip value) — equals threshold-based risk × CompoundScale, single balance factor. |
| `MaxLotSizeForCompounding` | Lot cap while compounding (replaces `MaxLotSize` as cap). **AMBIGUITY**: whether this cap itself scales; implemented as absolute cap (safest). |
| MaxRunningLoss scaling | When compounding: effective MaxRunningLoss = MaxRunningLoss × CompoundScale (per product: "Max Running Loss will be per threshold"). |

Note: screenshot of this ArchAngelX build shows only info-line + UseCompounding + Threshold; the risk inputs come from the specs txt (different product build). All five kept.

## Lot Size

| Setting | Intended behavior |
|---|---|
| `LotSize` | Base lot of first trade (non-compounding). |
| `RiskPercent` | If >0 **and** StopLoss>0: base lot = (Risk% × balance)/(SL pips × pip value). |
| `LotSizeExponent` | lot(level) = base × LSE^level (level 0 = first trade). 1.0 = flat. |
| `MaxLotSize` | Absolute per-order cap. Once hit, orders continue at the cap. 0 = no limit. |

## Weekend Closure

| Setting | Intended behavior |
|---|---|
| `CloseForWeekend` | TRUE: at Day/TimeToClose close all positions and disable trading; re-enable at Day/TimeToRestart. The closed window spans the weekend wrap (e.g. Fri 21:00 → Mon 01:00). |
| `DayToClose/DayToRestart` | Day-of-week (product UI: Sunday..Saturday enum). |
| `TimeToClose/TimeToRestart` | "HH:MM" server time. |

## Session

| Setting | Intended behavior |
|---|---|
| `TradeCustomTimes` | Enables per-weekday windows "HH:MM-HH:MM". "0" (or empty) = no trading that day. Sat/Sun: no trading. |
| `ActionAtEndOfSession` | Product enum order: 0 = Close all trades, 1 = Complete the sequence (default), 2 = Pause the sequence. Close-all: close everything, disable until next session. Complete: keep managing open positions **normally** (including grid adds) until basket closes; no new sequences. Pause: keep trades open, EA off (exits still honored defensively — AMBIGUITY: product says "turn off"; safety-biased implementation keeps TP/trailing exits active, documented). Virtual-only sequences (no positions) are cancelled when session blocks new risk. |

## Equity Protector (four DISTINCT stop states)

| Setting | Intended behavior |
|---|---|
| `MaxRunningLoss` | Floating loss (open positions, this EA instance) ≥ value → close all, stop; **restart** per `RestartEAAfterLoss` (`RestartNextDayAt` time, or after `RestartAfterHours`). Restart must be reachable. Scales with compounding. |
| `DailyProfitTarget` | Day P/L (closed+floating since daily reset) ≥ target → close all, stop new trades, **auto-restart next day** at `RestartNextDayAt`. |
| `UltimateTargetBalance` | Equity ≥ target → close all, **permanent** shutdown (mission complete). Account-wide by construction (every instance sees the same equity). |
| `GlobalEquityStopType/Value` | Product order: 0 = Absolute Equity (equity ≤ value), 1 = Risked Amount (balance − equity ≥ value), 2 = Risked Percentage ((balance−equity)/balance ≥ value%). Hard safety stop, latched. |
| `ResetGlobalEquityStop` | TRUE: equity-stop latch cleared (per new day; any input change also reinitializes the EA, clearing latches — product's "clear global variables" mechanism has no in-EA persistence in Triton; documented limitation). |
| `MinSecondsBetweenTrades` | Minimum seconds between any two orders placed by **this EA instance** (prop-firm rule), not per direction. |

## Indicators

| Setting | Intended behavior |
|---|---|
| RSI | Sell when RSI ≥ Overbought; buy level mirrors: ≤ (100 − Overbought). Timeframe/period as set. |
| EMA | Three EMAs (fast/mid/slow). Uptrend = fast>mid>slow. WITH_TREND_ONLY: buy only in uptrend, sell only in downtrend. AVOID_OPPOSITE: buys blocked only in clear downtrend, sells only in clear uptrend (flat market: both allowed). |
| `DoubleCheckEMAFirstRealTrade` | Only relevant with delay: TRUE re-checks EMA immediately before the first REAL trade; FALSE means first real trade may open against EMA. Same pattern for ADX. RSI/BB are **not** re-checked at the first real trade. |
| ADX | Threshold gates trend strength. WITH_TREND_ONLY: ADX ≥ threshold and +DI/−DI direction must agree. AVOID_OPPOSITE: per product, ranging (ADX < threshold) allows both; trending allows only with-trend. **Current code requires ADX ≥ threshold in both modes — for AVOID_OPPOSITE this contradicts the doc ("trades when ADX is below the threshold"); patched: AVOID_OPPOSITE passes when ADX < threshold, else with-trend only.** |
| Bollinger | AVOID_EXTREME: block buys at/above upper band, sells at/below lower. ONLY_EXTREME_COUNTER_TREND: only allow buys at/below lower band, sells at/above upper. |

## News

| Setting | Intended behavior |
|---|---|
| `UseHighImpactNews` | High-impact calendar events for base or profit currency of the symbol. Blocking window: from `CloseMinutesBeforeNews` before the event until `PauseMinutesAfterNews` after it. |
| `NewsTradesAction` | Product enum order 0 = Close all trades (close everything CloseMinutesBeforeNews ahead, resume after pause window), 1 = Complete the sequence / "manage open trade sequence" (default; manage existing baskets normally, no new sequences), 2 = Pause the sequence. Virtual-only sequences cancelled while blocked. |
| Calendar failure mode | MT5 economic calendar is unavailable in Strategy Tester and can fail live → EA must not crash; failure = "no news" with logged warning. Documented operational risk. |

## Cross-cutting acceptance rules

1. Determinism: seeded xorshift PRNG only; no Sleep/file-IO in tick path; same ticks + inputs + seed ⇒ same trades.
2. Risk-gate precedence: EquityGuard > weekend > news > session > entry filters > sequence engine.
3. Virtual exposure (DelayTradeSequence levels, LiveDelay accumulation) must never convert to real exposure during any no-new-risk state.
4. Basket exits always from lot-weighted average. Per-trade SL only.
5. MagicNumber + symbol filter on every position scan and order.
