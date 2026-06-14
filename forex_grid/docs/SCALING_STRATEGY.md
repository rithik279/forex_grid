# Scaling Strategy — From Pipeline to a $100k/Month Prop Operation

> This is the business/ops layer above the backtest pipeline. The current repo is
> a *research engine* (find good parameter sets). A prop operation is a *capital
> deployment engine* (turn good sets into funded payouts at scale). This doc maps
> the gap and lays out the fastest path to the first payout, then the path to
> $100k/month.

---

## 1. Reframe: what business are we actually in?

We are not in the "build a profitable EA" business. We are in the
**funded-account portfolio** business. The unit of production is not a trade —
it's a **payout from a funded account**. The system's job is to manufacture
payouts repeatably.

That reframing changes everything about what to build next:

| Research mindset (today) | Operation mindset (needed) |
|--------------------------|----------------------------|
| "Is this set profitable?" | "How many funded accounts can this set safely run on?" |
| Maximize backtest profit | Maximize *probability of clearing a payout window* |
| One VPS, one EA | A fleet of accounts, each a position in a portfolio |
| Results.csv | Account ledger: balance, DD headroom, payout date, P&L |

---

## 2. Unit economics (know the numbers cold)

Prop firm challenge, typical 1-step $100k account:

- **Cost to acquire:** ~$450–550 per challenge attempt.
- **Profit target:** ~8–10% ($8–10k) to pass.
- **Max drawdown:** ~6–10% total, ~4–5% daily. **This is the real constraint.**
- **Payout:** after funding, 80–90% profit split, first withdrawal usually after
  a minimum trading period (often 5–14 days) + a payout cycle.

The two numbers that govern the whole business:

1. **Pass rate** — what fraction of challenges we clear. At $500/attempt, a 20%
   pass rate means each *funded* account costs ~$2,500 in challenge fees. At 50%
   it's $1,000. Pass rate is the single biggest lever on profitability.
2. **Payout per funded account per month** — drives how many accounts we need.

**To hit $100k/month payouts:** if each funded account nets ~$2,000/month in our
share, we need ~50 live funded accounts. If ~$5,000, we need ~20. The system must
therefore manage *dozens* of accounts simultaneously — that's the scaling target.

---

## 3. The core edge: portfolio, not prediction

A grid / mean-reversion EA on **one** account is a coin flip with a fat left
tail — grids print steady profit until they don't, then give it all back. You do
**not** beat prop drawdown rules with one grid.

The edge of this system is **diversification across uncorrelated parameter sets
and accounts**:

- Each funded account runs **one** validated set, sized small.
- Sets are chosen to be **uncorrelated** (different symbols, directions, regimes).
- When one grid blows its account, it's one position in a 30-position book — the
  fleet's aggregate equity curve stays inside payout range.

This is exactly what `RegimeScore` / Archangel X scoring is *trying* to encode
(BT+FT consistency, drawdown discipline, trade-count sanity). The scoring is the
risk model for the portfolio. **Treat it as such** — it's not a leaderboard, it's
position selection.

> Implication: we need a **correlation/portfolio view**, not just a per-set score.
> Two A+ sets that are the same trade are one position, not two.

---

## 4. The fastest path to the FIRST payout (next 2 weeks)

Goal: a real withdrawal hitting the bank inside 14 days. This is a confidence and
cash-flow milestone, not the scale milestone. Optimize purely for *speed and
certainty*, not size.

### Week 1 — clear an evaluation (or skip it)
1. **Pick the fastest-payout firm.** Filter prop firms for: low minimum trading
   days (≤5), short payout cycle (weekly or bi-weekly, not monthly), and ideally
   an **instant-funding / 1-step** product. Instant funding skips the eval
   entirely — you trade real-split capital on day one. Higher fee, but it
   collapses the timeline. **For the first win, buy speed.**
2. **Deploy the single best validated set** from the pipeline — highest
   RegimeScore with *positive FT profit* and *FT drawdown ≤ BT drawdown* (proof
   it generalized). Not the highest profit — the most *consistent*.
3. **Size for survival, not target.** Set lot size so that the worst FT drawdown
   we observed is ≤ half the account's daily DD limit. We want to clear the
   minimum, not gun for the target and risk the account.

### Week 2 — bank the payout
4. **Hit the minimum profit + minimum days**, then **request the payout at the
   first available window.** Don't compound, don't push. The objective is a
   completed payout cycle end-to-end so we know the full machine works:
   deploy → trade → withdraw → bank.
5. **Instrument the live account** (see §5 — Live Monitor is currently stubbed).
   We cannot scale what we can't watch. Getting live P&L + drawdown onto the
   dashboard is the critical-path engineering task for these two weeks.

**The first payout's value is information, not money.** It proves the full loop
and surfaces every operational gap (broker quirks, payout friction, sizing
errors) while the stakes are one account.

---

## 5. What the system needs to support $100k/month

The backtest pipeline is ~70% there as a *research* tool. The *operations* layer
barely exists. Ranked by what unblocks scale:

### Tier 1 — can't scale without these
1. **Account fleet ledger.** A record per funded account: firm, login, set
   deployed, current balance, peak balance, DD headroom (live), daily-loss
   headroom, min-days progress, next payout date, status. This is the new
   `data/accounts.json` / DB and the new primary dashboard page. *Today we have
   no idea what's live.*
2. **Live monitoring + kill switch.** `fetch_live_history` was archived — it
   needs to come back as a per-account equity/positions feed pushed to GitHub,
   exactly like results.csv. Plus an **auto-flatten** rule: if an account hits X%
   of its daily-loss limit, close everything. One blown rule = one dead account =
   ~$500 + the payout. A kill switch pays for itself the first time it fires.
3. **Capital allocation / deployment engine.** Given N validated sets and a
   budget for M new challenges, decide which sets go on which accounts to
   maximize expected payouts subject to **correlation limits**. This is the
   portfolio optimizer that turns research into deployment.

### Tier 2 — needed by ~20+ accounts
4. **Backtest throughput.** Single serial worker is the research bottleneck.
   Parallelize (multiple MT5 data folders / multiple VPS) so the validated-set
   supply keeps up with account churn.
5. **Decay detection / reconciliation.** Compare each live account's realized
   stats against its backtest expectation. When live drawdown exceeds backtest
   drawdown, the regime changed — pull the set before it kills the account. This
   is the feedback loop that keeps the portfolio honest.
6. **Payout calendar + cash management.** Track every account's payout window so
   withdrawals are requested the day they're eligible; model fee outflow
   (challenges) vs payout inflow to size how aggressively to buy new challenges.

### Tier 3 — efficiency at 50+ accounts
7. **Automated challenge purchasing + account onboarding.**
8. **Per-firm rule engine** (each firm's DD/consistency rules encoded and
   enforced pre-deploy, so we never deploy a set that violates a firm's rules).
9. **Proper datastore.** GitHub-as-DB works to ~low thousands of rows; a real DB
   (SQLite→Postgres) once the ledger and live feeds are in play.

---

## 6. The operating loop at scale

```
   RESEARCH                DEPLOY                 OPERATE              HARVEST
┌────────────┐        ┌──────────────┐       ┌──────────────┐     ┌───────────┐
│ optimize → │        │ allocator    │       │ live monitor │     │ payout    │
│ score (FT  │ ─sets→ │ picks sets,  │ ─acct→│ + kill switch│ ─►  │ calendar  │
│ consistent)│        │ sizes, buys  │       │ + decay      │     │ withdraws │
│            │ ◄──────│ challenges   │ ◄─────│ detection    │ ◄───│ recycles  │
└────────────┘ retire └──────────────┘ pull  └──────────────┘     └───────────┘
       ▲           underperformers                                      │
       └──────────────────── reinvest payout into more challenges ──────┘
```

The flywheel: payouts fund more challenges → more funded accounts → more payouts.
$100k/month is reached when the funded-account count × avg payout crosses the
line, *and the pass rate is high enough that challenge-fee outflow doesn't eat the
payouts.* Everything above exists to push pass rate up and keep accounts alive.

---

## 7. Concrete next actions

**This week (unblock the first payout):**
- [ ] Rebuild live monitoring: per-account equity + open positions → GitHub →
      dashboard Live Monitor page (un-stub it).
- [ ] Add an account ledger page: even a manual `data/accounts.json` to start.
- [ ] Select the single most *consistent* validated set (positive FT, FT DD ≤ BT
      DD), size it for survival, deploy on a fast-payout / instant-funding account.

**Next 2–4 weeks (foundation for scale):**
- [ ] Auto-flatten kill switch keyed to daily-loss headroom.
- [ ] Decay/reconciliation: live vs backtest drawdown alarm.
- [ ] Correlation view in Set Finder so we deploy *uncorrelated* sets.
- [ ] Parallelize the backtest worker to grow validated-set supply.

**The one-sentence strategy:** get one payout banked in two weeks to prove the
full loop, then spend the following month building the *fleet ledger + live
kill-switch + correlation-aware allocator* that lets us safely run the dozens of
accounts $100k/month requires.
