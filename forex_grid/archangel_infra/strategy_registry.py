"""
strategy_registry.py — CLI tool for managing deployed Seraphim strategies.

Each strategy is a markdown card in StrategyRegistry/ plus an entry in registry.json.

Commands:
  python strategy_registry.py list              Show all strategies
  python strategy_registry.py add               Interactive: create new strategy card
  python strategy_registry.py retire <name>     Mark strategy as RETIRED
  python strategy_registry.py review <name>     Print full strategy card
  python strategy_registry.py expiring          Show strategies expiring within 7 days
"""

import argparse
import json
import os
import sys
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Optional

# ── Paths ─────────────────────────────────────────────────────────────────────

SCRIPT_DIR    = Path(__file__).parent
REGISTRY_DIR  = SCRIPT_DIR / "StrategyRegistry"
REGISTRY_JSON = REGISTRY_DIR / "registry.json"

REGISTRY_DIR.mkdir(exist_ok=True)


# ── JSON helpers ──────────────────────────────────────────────────────────────

def load_registry() -> list[dict]:
    if not REGISTRY_JSON.exists():
        return []
    with open(REGISTRY_JSON, "r", encoding="utf-8") as f:
        return json.load(f)


def save_registry(entries: list[dict]) -> None:
    with open(REGISTRY_JSON, "w", encoding="utf-8") as f:
        json.dump(entries, f, indent=2, default=str)


def find_entry(entries: list[dict], name: str) -> Optional[dict]:
    name_lower = name.lower()
    for e in entries:
        if e["name"].lower() == name_lower:
            return e
    return None


# ── Card renderer ─────────────────────────────────────────────────────────────

def render_card(e: dict, params: dict) -> str:
    return f"""# Strategy Card: {e['name']}

## Identity
- **Symbol:** {e['symbol']}
- **Timeframe:** {e.get('timeframe', 'N/A')}
- **Direction:** {e.get('direction', 'N/A')}
- **Status:** {e['status']}
- **Deploy Date:** {e['deploy_date']}
- **Expiry Date:** {e['expiry_date']}  *(30-day review window)*

## Regime Hypothesis
{e.get('regime', 'N/A')}

## Assumption Break Conditions (Kill Triggers)
{e.get('assumption_break', 'N/A')}

## Key Parameters
| Parameter | Value |
|-----------|-------|
| PipStep | {params.get('PipStep', '—')} |
| MaxOrders | {params.get('MaxOrders', '—')} |
| TakeProfit | {params.get('TakeProfit', '—')} |
| LockProfit | {params.get('LockProfit', '—')} |
| TrailingStop | {params.get('TrailingStop', '—')} |
| Session | {params.get('Session', '—')} |
| EMA Timeframe | {params.get('EMATimeframe', '—')} |
| EMA Periods | {params.get('EMAPeriods', '—')} |

## Notes
{e.get('notes', '—')}
"""


# ── Commands ──────────────────────────────────────────────────────────────────

def cmd_list(args) -> None:
    entries = load_registry()
    if not entries:
        print("No strategies in registry.")
        return

    col_w = [30, 8, 10, 12, 12]
    header = (
        f"{'Name':<{col_w[0]}} {'Symbol':<{col_w[1]}} {'Status':<{col_w[2]}} "
        f"{'Deploy':<{col_w[3]}} {'Expiry':<{col_w[4]}}"
    )
    sep = "-" * sum(col_w) + "-" * 4
    print(header)
    print(sep)
    for e in entries:
        expiry   = e.get("expiry_date", "")
        expired  = ""
        if expiry:
            try:
                days_left = (date.fromisoformat(expiry) - date.today()).days
                if days_left < 0:
                    expired = f" [EXPIRED {-days_left}d ago]"
                elif days_left <= 7:
                    expired = f" [expires in {days_left}d]"
            except ValueError:
                pass
        print(
            f"{e['name']:<{col_w[0]}} {e.get('symbol',''):<{col_w[1]}} "
            f"{e['status']:<{col_w[2]}} {e.get('deploy_date',''):<{col_w[3]}} "
            f"{expiry:<{col_w[4]}}{expired}"
        )
    print(f"\n{len(entries)} strategy/strategies total.")


def cmd_add(args) -> None:
    entries = load_registry()

    print("\n── New Strategy Card ──────────────────────────────────────────")

    def prompt(label: str, default: str = "") -> str:
        suffix = f" [{default}]" if default else ""
        val = input(f"  {label}{suffix}: ").strip()
        return val if val else default

    symbol    = prompt("Symbol (e.g. XAUUSD)").upper()
    direction = prompt("Direction (Long/Short/Both)", "Long").title()
    today_str = date.today().strftime("%b%Y")
    auto_name = f"{symbol}_{direction}_{today_str}"
    name      = prompt("Name", auto_name)
    timeframe = prompt("Timeframe (e.g. M30)", "M30")
    regime    = prompt("Regime Hypothesis (what market condition are you targeting)")
    assumption_break = prompt("Assumption Break Conditions (what kills this strategy)")
    pip_step  = prompt("PipStep", "15.0")
    max_orders = prompt("MaxOrders", "10")
    take_profit = prompt("TakeProfit (pips)", "50")
    lock_profit = prompt("LockProfit (pips)", "30")
    trail_stop  = prompt("TrailingStop (pips)", "10")
    session   = prompt("Session window (e.g. London 07:00-12:00)")
    ema_tf    = prompt("EMA Timeframe", "M30")
    ema_periods = prompt("EMA Periods (Fast-Mid-Slow)", "4-8-60")
    notes     = prompt("Notes (any additional context)", "")

    deploy_date = date.today().isoformat()
    expiry_date = (date.today() + timedelta(days=30)).isoformat()

    params = {
        "PipStep": pip_step,
        "MaxOrders": max_orders,
        "TakeProfit": take_profit,
        "LockProfit": lock_profit,
        "TrailingStop": trail_stop,
        "Session": session,
        "EMATimeframe": ema_tf,
        "EMAPeriods": ema_periods,
    }

    card_filename = f"{name}.md"
    card_path     = REGISTRY_DIR / card_filename

    entry = {
        "name":           name,
        "symbol":         symbol,
        "timeframe":      timeframe,
        "direction":      direction,
        "status":         "ACTIVE",
        "deploy_date":    deploy_date,
        "expiry_date":    expiry_date,
        "regime":         regime,
        "assumption_break": assumption_break,
        "notes":          notes,
        "params":         params,
        "file":           str(card_path.relative_to(SCRIPT_DIR)),
    }

    # Check duplicate
    if find_entry(entries, name):
        print(f"\n[Error] Strategy '{name}' already exists. Use a different name.")
        sys.exit(1)

    # Write markdown card
    card_text = render_card(entry, params)
    with open(card_path, "w", encoding="utf-8") as f:
        f.write(card_text)

    entries.append(entry)
    save_registry(entries)

    print(f"\n✓ Strategy '{name}' added.")
    print(f"  Card:     {card_path}")
    print(f"  Expiry:   {expiry_date}")


def cmd_retire(args) -> None:
    name    = args.name
    entries = load_registry()
    entry   = find_entry(entries, name)

    if not entry:
        print(f"[Error] Strategy '{name}' not found.")
        sys.exit(1)

    if entry["status"] == "RETIRED":
        print(f"Strategy '{name}' is already RETIRED.")
        return

    entry["status"] = "RETIRED"
    save_registry(entries)

    # Update markdown card status line
    card_path = SCRIPT_DIR / entry["file"]
    if card_path.exists():
        text = card_path.read_text(encoding="utf-8")
        text = text.replace("**Status:** ACTIVE", "**Status:** RETIRED")
        text = text.replace("**Status:** MONITORING", "**Status:** RETIRED")
        card_path.write_text(text, encoding="utf-8")

    print(f"Strategy '{name}' marked as RETIRED.")


def cmd_review(args) -> None:
    name    = args.name
    entries = load_registry()
    entry   = find_entry(entries, name)

    if not entry:
        print(f"[Error] Strategy '{name}' not found.")
        sys.exit(1)

    card_path = SCRIPT_DIR / entry["file"]
    if card_path.exists():
        print(card_path.read_text(encoding="utf-8"))
    else:
        print(f"[Warning] Card file not found: {card_path}")
        print(json.dumps(entry, indent=2, default=str))


def cmd_expiring(args) -> None:
    entries = load_registry()
    cutoff  = date.today() + timedelta(days=7)
    soon    = []

    for e in entries:
        if e["status"] == "RETIRED":
            continue
        expiry_str = e.get("expiry_date")
        if not expiry_str:
            continue
        try:
            expiry = date.fromisoformat(expiry_str)
            if expiry <= cutoff:
                days_left = (expiry - date.today()).days
                soon.append((days_left, e))
        except ValueError:
            continue

    if not soon:
        print("No active strategies expiring within 7 days.")
        return

    soon.sort(key=lambda x: x[0])
    print(f"\n{'Strategy':<32} {'Symbol':<8} {'Expiry':<12} {'Days Left'}")
    print("-" * 64)
    for days_left, e in soon:
        label = "TODAY" if days_left == 0 else (f"OVERDUE {-days_left}d" if days_left < 0 else f"{days_left}d")
        print(f"{e['name']:<32} {e.get('symbol',''):<8} {e.get('expiry_date',''):<12} {label}")

    print(f"\n{len(soon)} strategy/strategies expiring soon.")


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(
        description="Seraphim Strategy Registry — manage deployed strategies",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    sub = parser.add_subparsers(dest="command")

    sub.add_parser("list",     help="List all strategies")
    sub.add_parser("add",      help="Add a new strategy (interactive)")

    p_retire = sub.add_parser("retire", help="Mark strategy as RETIRED")
    p_retire.add_argument("name", help="Strategy name")

    p_review = sub.add_parser("review", help="Show full strategy card")
    p_review.add_argument("name", help="Strategy name")

    sub.add_parser("expiring", help="Show strategies expiring within 7 days")

    args = parser.parse_args()

    dispatch = {
        "list":     cmd_list,
        "add":      cmd_add,
        "retire":   cmd_retire,
        "review":   cmd_review,
        "expiring": cmd_expiring,
    }

    if args.command not in dispatch:
        parser.print_help()
        sys.exit(0)

    dispatch[args.command](args)


if __name__ == "__main__":
    main()
