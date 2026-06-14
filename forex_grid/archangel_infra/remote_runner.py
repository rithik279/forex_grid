import os
import time
import subprocess
import glob
import shutil
import csv
import re
import io
import json
import base64
import logging
import requests
from datetime import datetime, timedelta

# ── Version stamp (H4) ───────────────────────────────────────────────────────
# Bump on every meaningful change. Printed on boot + sent in heartbeat so the
# dashboard can detect a VPS running stale code.
__version__ = "2026-06-14.1"

# ── GitHub bridge config ────────────────────────────────────────────────────
GH_TOKEN  = os.environ.get("GITHUB_TOKEN", "")
GH_REPO   = os.environ.get("GITHUB_REPO",  "rithik279/forex_grid")
GH_BRANCH = os.environ.get("GITHUB_BRANCH","main")
GH_QUEUE_PATH     = "forex_grid/data/queue"
GH_RESULTS_PATH   = "forex_grid/data/results.csv"
GH_CONFIG_PATH    = "forex_grid/data/remote_config.json"
GH_HEARTBEAT_PATH = "forex_grid/data/runner_heartbeat.json"

# Hard ceiling on a single MT5 tester invocation (H1). Kill + fail past this.
MT5_RUN_TIMEOUT_SEC = int(os.environ.get("MT5_RUN_TIMEOUT_SEC", "900"))  # 15 min

# ── Logging (H5) ─────────────────────────────────────────────────────────────
# Logs to console AND a rotating file in the OneDrive folder so you can read the
# runner's history from your local machine without an RDP session.
log = logging.getLogger("remote_runner")


def _setup_logging(onedrive_root):
    log.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s",
                            "%Y-%m-%d %H:%M:%S")
    sh = logging.StreamHandler()
    sh.setFormatter(fmt)
    log.addHandler(sh)
    try:
        from logging.handlers import RotatingFileHandler
        fh = RotatingFileHandler(os.path.join(onedrive_root, "runner.log"),
                                 maxBytes=2_000_000, backupCount=3, encoding="utf-8")
        fh.setFormatter(fmt)
        log.addHandler(fh)
    except Exception as e:
        log.warning(f"File logging unavailable: {e}")


def _gh_headers():
    if not GH_TOKEN:
        return {}
    return {"Authorization": f"token {GH_TOKEN}",
            "Accept": "application/vnd.github.v3+json"}


def gh_request(method, url, retries=3, backoff=1.5, **kwargs):
    """
    HTTP wrapper with retry + exponential backoff (M2).
    Retries on network errors and 5xx/429. Returns the Response (caller checks
    status) or None if all attempts failed.
    """
    kwargs.setdefault("headers", _gh_headers())
    kwargs.setdefault("timeout", 20)
    delay = backoff
    for attempt in range(1, retries + 1):
        try:
            r = requests.request(method, url, **kwargs)
            if r.status_code < 500 and r.status_code != 429:
                return r
            log.warning(f"GH {method} {r.status_code} (attempt {attempt}/{retries})")
        except requests.RequestException as e:
            log.warning(f"GH {method} error: {e} (attempt {attempt}/{retries})")
        if attempt < retries:
            time.sleep(delay)
            delay *= 2
    return None

def check_github_queue(local_queue_dir):
    """Download any .set files from GitHub data/queue/ into local Queue dir."""
    if not GH_TOKEN:
        return
    url = f"https://api.github.com/repos/{GH_REPO}/contents/{GH_QUEUE_PATH}"
    try:
        r = requests.get(url, headers=_gh_headers(), params={"ref": GH_BRANCH}, timeout=15)
        if r.status_code == 404:
            return  # folder doesn't exist yet
        if r.status_code != 200:
            log.warning(f"GH Queue API error {r.status_code}")
            return
        files = r.json()
        if not isinstance(files, list):
            return
        for f in files:
            if not f.get("name", "").endswith(".set"):
                continue
            local_path = os.path.join(local_queue_dir, f["name"])
            if os.path.exists(local_path):
                continue  # already downloaded
            # Download content
            fr = requests.get(f["download_url"], timeout=15)
            if fr.status_code == 200:
                with open(local_path, "w", encoding="utf-8") as out:
                    out.write(fr.text)
                log.info(f"GH Queue downloaded: {f['name']}")
                # Delete from GitHub queue
                _gh_delete_file(GH_QUEUE_PATH + "/" + f["name"], f["sha"])
    except Exception as e:
        log.warning(f"GH Queue error: {e}")

def _gh_delete_file(path, sha):
    """Delete a file from GitHub repo."""
    url = f"https://api.github.com/repos/{GH_REPO}/contents/{path}"
    body = {"message": f"remote_runner: processed {path}",
            "sha": sha, "branch": GH_BRANCH}
    try:
        requests.delete(url, headers=_gh_headers(), json=body, timeout=15)
    except Exception as e:
        log.warning(f"GH Delete error: {e}")

def sync_config_from_github():
    """Pull remote_config.json from GitHub and overwrite local OneDrive copy."""
    if not GH_TOKEN:
        return
    url = f"https://raw.githubusercontent.com/{GH_REPO}/{GH_BRANCH}/{GH_CONFIG_PATH}"
    r = gh_request("GET", url)
    if r is not None and r.status_code == 200:
        local_path = os.path.join(ONEDRIVE_ROOT, "remote_config.json")
        with open(local_path, "w", encoding="utf-8") as f:
            f.write(r.text)
        log.info("Synced remote_config.json from GitHub.")
    elif r is not None:
        log.warning(f"Could not fetch config: {r.status_code}")


def reset_clear_flag_on_github():
    """
    Reset ClearResults:false on GitHub itself (C3).

    Without this, the flag stays true on GitHub, sync_config_from_github()
    re-pulls true every loop, and results.csv is wiped on every iteration.
    This makes 'clear' a true one-shot.
    """
    if not GH_TOKEN:
        return
    url = f"https://api.github.com/repos/{GH_REPO}/contents/{GH_CONFIG_PATH}"
    r = gh_request("GET", url, params={"ref": GH_BRANCH})
    if r is None or r.status_code != 200:
        log.warning("ClearResults reset: could not read remote config.")
        return
    meta = r.json()
    try:
        cfg = json.loads(base64.b64decode(meta["content"]).decode())
    except Exception as e:
        log.warning(f"ClearResults reset: bad remote JSON: {e}")
        return
    if not cfg.get("ClearResults"):
        return  # already false; nothing to do
    cfg["ClearResults"] = False
    body = {
        "message": "remote_runner: reset ClearResults flag (one-shot)",
        "content": base64.b64encode(json.dumps(cfg, indent=4).encode()).decode(),
        "branch": GH_BRANCH,
        "sha": meta["sha"],
    }
    pr = gh_request("PUT", url, json=body)
    if pr is not None and pr.status_code in (200, 201):
        log.info("ClearResults flag reset to false on GitHub.")
    else:
        log.warning("ClearResults reset: PUT failed.")

def _dedup_csv_text(csv_text):
    """
    Deduplicate result rows by SetFile, keeping the last occurrence (H3).
    Pure stdlib (no pandas dependency on the VPS). Preserves header + order of
    last-seen rows.
    """
    try:
        reader = list(csv.reader(io.StringIO(csv_text)))
    except Exception:
        return csv_text
    if not reader:
        return csv_text
    header = reader[0]
    if "SetFile" not in header:
        return csv_text
    key_idx = header.index("SetFile")
    seen = {}
    for row in reader[1:]:
        if not row or len(row) <= key_idx:
            continue
        seen[row[key_idx]] = row  # last write wins
    out = io.StringIO()
    w = csv.writer(out)
    w.writerow(header)
    for row in seen.values():
        w.writerow(row)
    return out.getvalue()


def push_results_to_github(results_csv_path, retries=4):
    """
    Conflict-safe results push (C1, C2, H3).

    On each attempt: re-fetch the current remote SHA, merge our local rows with
    whatever is on GitHub (union, dedup by SetFile, last-wins), and PUT with the
    fresh SHA. A 409 (someone pushed between our GET and PUT) triggers a re-fetch
    and retry with backoff instead of silently dropping the result.
    """
    if not GH_TOKEN or not os.path.exists(results_csv_path):
        return False

    with open(results_csv_path, "r", encoding="utf-8") as f:
        local_text = f.read()

    url = f"https://api.github.com/repos/{GH_REPO}/contents/{GH_RESULTS_PATH}"
    delay = 1.5
    for attempt in range(1, retries + 1):
        r = gh_request("GET", url, params={"ref": GH_BRANCH})
        sha = None
        remote_text = ""
        if r is not None and r.status_code == 200:
            sha = r.json().get("sha")
            try:
                remote_text = base64.b64decode(r.json()["content"]).decode()
            except Exception:
                remote_text = ""

        # Merge remote + local so we never clobber rows we didn't author.
        if remote_text.strip():
            merged = remote_text.rstrip("\n") + "\n"
            # append local rows minus its header
            local_lines = local_text.splitlines()
            merged += "\n".join(local_lines[1:]) + "\n"
            merged = _dedup_csv_text(merged)
        else:
            merged = _dedup_csv_text(local_text)

        body = {
            "message": f"remote_runner: update results {datetime.utcnow().strftime('%Y-%m-%d %H:%M')} UTC",
            "content": base64.b64encode(merged.encode()).decode(),
            "branch": GH_BRANCH,
        }
        if sha:
            body["sha"] = sha

        pr = gh_request("PUT", url, json=body)
        if pr is not None and pr.status_code in (200, 201):
            # Keep local file in sync with the merged truth so the next append
            # doesn't reintroduce dropped duplicates.
            try:
                with open(results_csv_path, "w", encoding="utf-8", newline="") as f:
                    f.write(merged)
            except Exception:
                pass
            log.info("Pushed results.csv to GitHub.")
            return True
        if pr is not None and pr.status_code == 409:
            log.warning(f"results push conflict (attempt {attempt}/{retries}) — retrying")
            time.sleep(delay)
            delay *= 2
            continue
        log.warning(f"results push failed: {pr.status_code if pr is not None else 'no response'}")
        time.sleep(delay)
        delay *= 2

    log.error("results push: all retries exhausted — result NOT persisted to GitHub.")
    return False


def push_heartbeat(current_job="idle"):
    """
    Write a liveness beacon to GitHub (H2). Dashboard reads this to show a
    'worker last seen' badge and detect a dead/stale runner.
    """
    if not GH_TOKEN:
        return
    url = f"https://api.github.com/repos/{GH_REPO}/contents/{GH_HEARTBEAT_PATH}"
    r = gh_request("GET", url, params={"ref": GH_BRANCH})
    sha = r.json().get("sha") if (r is not None and r.status_code == 200) else None
    beat = {
        "version": __version__,
        "utc": datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S"),
        "job": current_job,
        "symbol": SYMBOL,
    }
    body = {
        "message": "remote_runner: heartbeat",
        "content": base64.b64encode(json.dumps(beat, indent=2).encode()).decode(),
        "branch": GH_BRANCH,
    }
    if sha:
        body["sha"] = sha
    gh_request("PUT", url, json=body)

METRIC_COLS = ["Profit", "Drawdown", "DrawdownPct", "Trades", "WinRate",
               "ProfitFactor", "ExpectedPayoff", "AvgProfitTrade", "AvgLossTrade", "MaxConsecLosses"]

RESULTS_HEADERS = (
    ["Timestamp", "SetFile", "Pass"]
    + [f"BT_{m}" for m in METRIC_COLS]
    + [f"FT_{m}" for m in METRIC_COLS]
    + ["RegimeScore"]
)


def calculate_regime_score(bt_metrics: dict, ft_metrics: dict) -> float:
    """
    Score a setfile on prop-firm survival probability, not raw profit.
    Higher score = better candidate for deployment.

    Rewards:
      - Both periods profitable (+300)
      - FT/BT trade ratio in 2.2–3.7 band (+200)
    Penalises:
      - Drawdown (FT weighted 2×, BT 1.5×)
      - Fewer than 5 BT trades (-500)
      - FT trade count far below BT (overfit signal, -300)
    """
    score = bt_metrics.get("BT_Profit", 0) + ft_metrics.get("FT_Profit", 0)

    if ft_metrics.get("FT_Profit", 0) > 0 and bt_metrics.get("BT_Profit", 0) > 0:
        score += 300

    score -= bt_metrics.get("BT_Drawdown", 0) * 1.5
    score -= ft_metrics.get("FT_Drawdown", 0) * 2.0

    bt_trades = bt_metrics.get("BT_Trades", 0)
    ft_trades = ft_metrics.get("FT_Trades", 0)

    if bt_trades < 5:
        score -= 500

    if bt_trades > 0:
        ratio = ft_trades / bt_trades
        if 2.2 <= ratio <= 3.7:
            score += 200
        elif ratio < 1.0:
            score -= 300

    return round(score, 2)


def init_results_csv():
    """Ensures results.csv exists with headers."""
    metric_cols = ["Profit", "Drawdown", "DrawdownPct", "Trades", "WinRate",
                   "ProfitFactor", "ExpectedPayoff", "AvgProfitTrade", "AvgLossTrade", "MaxConsecLosses"]

    headers = ["Timestamp", "SetFile", "Pass"]
    headers.extend([f"BT_{m}" for m in metric_cols])
    headers.extend([f"FT_{m}" for m in metric_cols])
    headers.append("RegimeScore")
    
    if not os.path.exists(RESULTS_CSV):
        try:
            with open(RESULTS_CSV, 'w', newline='') as f:
                csv.writer(f).writerow(headers)
            log.info("Created results.csv with headers.")
        except Exception as e:
            log.error(f"Failed to init CSV: {e}")

def load_remote_config():
    """
    Loads dynamic configuration from OneDrive if available.
    Updates global variables.
    """
    global SYMBOL, DEPOSIT, FROM_DATE, TO_DATE, FORWARD_SPLIT_DATE, MT5_TERMINAL_PATH, MT5_DATA_FOLDER, MT5_DATA_FOLDER_NAME, MQL5_PROFILES_TESTER, MT5_REPORTS_DIR, EA_NAME
    config_path = os.path.join(ONEDRIVE_ROOT, "remote_config.json")
    
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                data = json.load(f)
                
            # Check Clear Flag (local wipe; GitHub flag reset happens in
            # reset_clear_flag_on_github() so it's a true one-shot — C3)
            if data.get("ClearResults") is True:
                log.info("'ClearResults' detected. Clearing results.csv...")
                if os.path.exists(RESULTS_CSV):
                    try: os.remove(RESULTS_CSV)
                    except: pass
                init_results_csv()
                data["ClearResults"] = False
                with open(config_path, "w") as f_out:
                    json.dump(data, f_out, indent=4)
                log.info("results.csv cleared.")

            # Only update if key exists and is not empty
            if data.get("Symbol"): SYMBOL = data["Symbol"]
            if data.get("Deposit"): DEPOSIT = str(data["Deposit"])
            if data.get("FromDate"): FROM_DATE = data["FromDate"]
            if data.get("SplitDate"): FORWARD_SPLIT_DATE = data["SplitDate"]
            if data.get("ToDate"): TO_DATE = data["ToDate"]
            # Machine-specific overrides (set per machine, not shared)
            if data.get("MT5TerminalPath"):
                MT5_TERMINAL_PATH = data["MT5TerminalPath"]
            if data.get("MT5DataFolderName"):
                MT5_DATA_FOLDER_NAME = data["MT5DataFolderName"]
                MT5_DATA_FOLDER = os.path.join(os.getenv("APPDATA"), "MetaQuotes", "Terminal", MT5_DATA_FOLDER_NAME)
                MQL5_PROFILES_TESTER = os.path.join(MT5_DATA_FOLDER, "MQL5", "Profiles", "Tester")
                MT5_REPORTS_DIR = os.path.join(MT5_DATA_FOLDER, "reports")
            if data.get("EAName"): EA_NAME = data["EAName"]

            # M5: validate before we trust it. Bad dates/symbol => broken run.
            problems = []
            for d in (FROM_DATE, FORWARD_SPLIT_DATE, TO_DATE):
                try:
                    datetime.strptime(d, "%Y.%m.%d")
                except Exception:
                    problems.append(f"bad date '{d}'")
            if not SYMBOL or not SYMBOL.strip():
                problems.append("empty Symbol")
            try:
                if float(DEPOSIT) <= 0:
                    problems.append(f"non-positive Deposit '{DEPOSIT}'")
            except Exception:
                problems.append(f"bad Deposit '{DEPOSIT}'")
            if problems:
                log.error(f"Invalid config, ignoring update: {', '.join(problems)}")
                return False

            log.info(f"Config loaded: {SYMBOL}, ${DEPOSIT}, {FROM_DATE} -> {FORWARD_SPLIT_DATE} -> {TO_DATE}, EA={EA_NAME}")
            return True

        except Exception as e:
            log.warning(f"Failed to load remote config: {e}")
            return False
    return False

# --- CONFIGURATION (REMOTE) ---

# 1. MT5 Terminal Path (Executable)
MT5_TERMINAL_PATH = r"C:\Program Files\PU Prime MT5 Terminal 2\terminal64.exe"

# 2. MT5 Data Folder (The "Hash" folder in AppData)
# VPS path: C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\FDFD46F1C842DA981CA8507F035DD9E0
MT5_DATA_FOLDER_NAME = "FDFD46F1C842DA981CA8507F035DD9E0"
MT5_DATA_FOLDER = os.path.join(os.getenv("APPDATA"), "MetaQuotes", "Terminal", MT5_DATA_FOLDER_NAME)

# 3. Paths inside Data Folder (Strict Non-Negotiable)
# .set files go here
MQL5_PROFILES_TESTER = os.path.join(MT5_DATA_FOLDER, "MQL5", "Profiles", "Tester")
# Reports come out here (MT5 Terminal Root / reports)
# Confirmed by user: ...\Terminal\HASH\reports
MT5_REPORTS_DIR = os.path.join(MT5_DATA_FOLDER, "reports")

# 4. Config Settings
EA_NAME = r"Triton_v1.0.ex5" # Relative to MQL5\Experts
SYMBOL = "NAS100ft.s"
PERIOD = "M1"
DEPOSIT = "50000"
LEVERAGE = "1:100"
MODEL = "4" # EveryTickReal
FROM_DATE = "2025.09.12"
TO_DATE = "2025.12.12"
FORWARD_SPLIT_DATE = "2025.11.12" # Split point for separate runs

# 5. OneDrive Paths
USER_HOME = os.path.expanduser("~")
ONEDRIVE_ROOT = os.path.join(USER_HOME, "OneDrive", "RD_MT5_Sharing")
QUEUE_DIR = os.path.join(ONEDRIVE_ROOT, "Queue")
PROCESSING_DIR = os.path.join(ONEDRIVE_ROOT, "Processing")
PROCESSED_DIR = os.path.join(ONEDRIVE_ROOT, "Processed")
RESULTS_DIR = os.path.join(ONEDRIVE_ROOT, "Results")
RESULTS_CSV = os.path.join(RESULTS_DIR, "results.csv")

def parse_html_report(report_path, prefix=""):
    """
    Parses an MT5 HTML report using Regex.
    Keys: Profit, Drawdown, Trades, WinRate(Calculated)
    """
    data = {}
    if not os.path.exists(report_path):
        return {}

    # Helper to clean numeric strings
    def clean_num(s):
        s = re.sub(r"[^\d\.-]", "", s)
        if not s: return "0"
        return s

    try:
        # Read content (Handle UTF-16 which MT5 uses)
        try:
            with open(report_path, "r", encoding="utf-16") as f: content = f.read()
        except UnicodeError:
            with open(report_path, "r", encoding="utf-8") as f: content = f.read()

        # Regex Patterns (Robust)
        # Profit: "Total Net Profit... <td ...>1234.56</td>"
        # Look for tag opening, optional attrs, closing >, then content, then closing tag
        
        m_profit = re.search(r"Total Net Profit.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_profit: 
            val = m_profit.group(1).strip()
            # print(f"    [DEBUG-HTML] Profit Raw: {val}")
            data["Profit"] = float(clean_num(val))
           # Profit Factor
        m_pf = re.search(r"Profit Factor.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_pf: data["ProfitFactor"] = float(clean_num(m_pf.group(1)))

        # Expected Payoff
        m_ep = re.search(r"Expected Payoff.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_ep: data["ExpectedPayoff"] = float(clean_num(m_ep.group(1)))

        # Equity Drawdown Maximal - Extract % explicitly "123.45 (10.5%)"
        m_dd = re.search(r"Equity Drawdown Maximal.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_dd: 
            val = m_dd.group(1) # e.g. "2393.97 (4.56%)"
            # Get 4.56 from inside parens
            m_pct = re.search(r"\(([\d\.]+)[%]?\)", val)
            if m_pct:
                data["DrawdownPct"] = float(m_pct.group(1))
            
            # Absolute value fallback using clean_num on the whole string (gets first number)
            data["Drawdown"] = float(clean_num(val.split("(")[0]))

        # Trades
        m_trades = re.search(r"Total Trades.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_trades: 
            data["Trades"] = int(clean_num(m_trades.group(1)))

        # Average Profit Trade
        m_avg_win = re.search(r"Average Profit Trade.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_avg_win: data["AvgProfitTrade"] = float(clean_num(m_avg_win.group(1)))

        # Average Loss Trade
        m_avg_loss = re.search(r"Average Loss Trade.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_avg_loss: data["AvgLossTrade"] = float(clean_num(m_avg_loss.group(1)))

        # Max Consecutive Losses (Count) - "Maximum consecutive losses (profit amount)" -> "5 (-120.00)"
        m_con_loss = re.search(r"Maximum consecutive losses.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_con_loss:
            val = m_con_loss.group(1).split("(")[0] # "5 "
            data["MaxConsecLosses"] = int(clean_num(val))

        # Win Rate - Extract from "Profit Trades (% of total)" -> "75 (50.33%)"
        m_prof_trades = re.search(r"Profit Trades.*?<td[^>]*>(.*?)</td>", content, re.IGNORECASE | re.DOTALL)
        if m_prof_trades:
            raw = m_prof_trades.group(1) # "75 (50.33%)"
            # Try to grab the Percentage directly first (More accurate from report)
            m_wr_pct = re.search(r"\(([\d\.]+)[%]?\)", raw)
            if m_wr_pct:
                 data["WinRate"] = float(m_wr_pct.group(1))
            else:
                # Fallback to calc
                match_num = re.search(r"^(\d+)", raw)
                profit_trades = int(match_num.group(1)) if match_num else 0
                if data.get("Trades", 0) > 0:
                    data["WinRate"] = round((profit_trades / data["Trades"]) * 100, 2)
                else: 
                     data["WinRate"] = 0.0

    except Exception as e:
        log.error(f"Parsing HTML {os.path.basename(report_path)}: {e}")

    # Prefix keys
    if prefix:
        return {f"{prefix}{k}": v for k, v in data.items()}
    return data

def parse_set_file(filepath):
    """
    Parses a .set file for 'Key=Value' inputs.
    Ignores metadata headers (e.g. Expert:, Symbol:).
    Returns a dict of inputs.
    """
    inputs = {}
    try:
        with open(filepath, "r", encoding="utf-8", errors="ignore") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith(";") or line.startswith("#"):
                    continue
                # Skip known metadata lines if they don't look like inputs
                if ":" in line and not "=" in line:
                    continue
                
                if "=" in line:
                    parts = line.split("=", 1)
                    key = parts[0].strip()
                    val = parts[1].strip()
                    # Skip empty keys or separator lines
                    if not key:
                        continue
                    inputs[key] = val
    except Exception as e:
        log.warning(f"Failed to parse set file {os.path.basename(filepath)}: {e}")
    return inputs

def detect_symbol_from_filename(filename):
    """Extract broker symbol from set filename, e.g. AUDUSD_Long_Breakout_Pass123.set -> AUDUSD.s"""
    known = ["XAUUSD", "EURUSD", "AUDUSD", "USDJPY", "GBPUSD", "USDCAD", "NAS100", "US30"]
    base = os.path.basename(filename).upper()
    for sym in known:
        if base.startswith(sym):
            # Use broker suffix from global SYMBOL (e.g. ".s" or "ft.s")
            suffix = SYMBOL[SYMBOL.find("."):]  if "." in SYMBOL else ""
            return sym + suffix
    return SYMBOL  # fallback to config

def create_ini_file(set_filename_relative, report_base_relative, from_date, to_date, inputs=None, symbol_override=None):
    """
    Generates the MT5 configuration file.
    """
    sym = symbol_override if symbol_override else SYMBOL
    conf = f'''[Tester]
Expert={EA_NAME}
ExpertParameters={set_filename_relative}
Symbol={sym}
Period={PERIOD}
Optimization=0
OptimizationCriterion=0
Model={MODEL}
ExecutionMode=0
FromDate={from_date}
ToDate={to_date}
ForwardMode=0
Deposit={DEPOSIT}
Currency=USD
Leverage={LEVERAGE}
Visual=0
ReplaceReport=1
ShutdownTerminal=1
Report={report_base_relative}

[TesterInputs]
'''
    if inputs:
        for k, v in inputs.items():
            conf += f"{k}={v}\n"
    return conf

def run_mt5(ini_path):
    """
    Launch the MT5 tester with a hard timeout (H1). Returns True on clean exit,
    False if it timed out (process killed) or failed to launch.
    """
    try:
        subprocess.run([MT5_TERMINAL_PATH, f"/config:{ini_path}"],
                       check=False, timeout=MT5_RUN_TIMEOUT_SEC)
        return True
    except subprocess.TimeoutExpired:
        log.error(f"MT5 exceeded {MT5_RUN_TIMEOUT_SEC}s — killed. Job will be marked failed.")
        # terminal64 is detached by /config; best-effort kill of stragglers.
        try:
            subprocess.run(["taskkill", "/F", "/IM", "terminal64.exe"],
                           check=False, timeout=30)
        except Exception:
            pass
        return False
    except Exception as e:
        log.error(f"MT5 launch error: {e}")
        return False


def metrics_valid(metrics, prefix):
    """
    Reject all-zero / empty parses (M3) so a broken report never lands as a fake
    real row. Require at least Profit and Trades to have parsed.
    """
    return (f"{prefix}Trades" in metrics) and (f"{prefix}Profit" in metrics)


def run_worker():
    _setup_logging(ONEDRIVE_ROOT)
    log.info(f"--- Remote Worker v{__version__} (Single Test Mode) ---")
    log.info(f"MT5 Terminal: {MT5_TERMINAL_PATH}")
    log.info(f"MT5 Data Folder: {MT5_DATA_FOLDER}")
    log.info(f"Watching: {QUEUE_DIR}")

    # Ensure local dirs exist
    for d in [QUEUE_DIR, PROCESSING_DIR, PROCESSED_DIR, RESULTS_DIR]:
        os.makedirs(d, exist_ok=True)

    # Ensure MT5 target dirs exist
    if not os.path.exists(MQL5_PROFILES_TESTER):
        log.warning(f"MT5 Local Dir not found: {MQL5_PROFILES_TESTER}")
        try: os.makedirs(MQL5_PROFILES_TESTER)
        except: pass

    if not os.path.exists(MT5_REPORTS_DIR):
        log.info(f"Creating Reports Dir: {MT5_REPORTS_DIR}")
        try: os.makedirs(MT5_REPORTS_DIR)
        except: pass

    # Initialize CSV
    init_results_csv()

    while True:
        # Sync config + queue from GitHub
        sync_config_from_github()
        load_remote_config()          # apply config (handles ClearResults locally)
        reset_clear_flag_on_github()  # C3: make ClearResults a true one-shot
        check_github_queue(QUEUE_DIR)

        queue_files = glob.glob(os.path.join(QUEUE_DIR, "*.set"))
        if not queue_files:
            push_heartbeat("idle")
            time.sleep(10)
            continue

        for set_file_source in queue_files:
            filename = os.path.basename(set_file_source)
            log.info(f"Processing {filename}...")
            push_heartbeat(filename)

            # 0. Load Dynamic Configuration
            load_remote_config()
            file_symbol = detect_symbol_from_filename(filename)

            # 1. Move to Processing (OneDrive)
            processing_path_onedrive = os.path.join(PROCESSING_DIR, filename)
            if os.path.exists(processing_path_onedrive): os.remove(processing_path_onedrive)
            shutil.move(set_file_source, processing_path_onedrive)

            # 2. Copy to MT5 Data Folder (MQL5/Profiles/Tester)
            mt5_set_path = os.path.join(MQL5_PROFILES_TESTER, filename)
            shutil.copy2(processing_path_onedrive, mt5_set_path)
            log.info(f"Copied .set to: {mt5_set_path}")

            # Parse inputs from the source file
            set_inputs = parse_set_file(processing_path_onedrive)
            
            ini_path = os.path.join(PROCESSING_DIR, "mt5.ini")

            # 3. RUN 1: Backtest Portion (Start -> Split)
            log.info("[Step 1/2] Running Backtest Portion...")
            report_bt_name = f"Report_{filename.replace('.set', '')}_BT"
            report_bt_val = f"reports\\{report_bt_name}"  # MT5 adds .htm
            ini_bt = create_ini_file(f"Profiles\\Tester\\{filename}", report_bt_val,
                                     FROM_DATE, FORWARD_SPLIT_DATE,
                                     inputs=set_inputs, symbol_override=file_symbol)
            with open(ini_path, "w") as f: f.write(ini_bt)
            bt_ok = run_mt5(ini_path)

            expected_bt = os.path.join(MT5_REPORTS_DIR, f"{report_bt_name}.htm")
            bt_metrics = {}
            if bt_ok and os.path.exists(expected_bt):
                bt_metrics = parse_html_report(expected_bt, prefix="BT_")
                if not metrics_valid(bt_metrics, "BT_"):
                    log.error(f"BT report parsed empty/zero for {filename} — marking failed.")
                    bt_metrics = {}
            else:
                log.error(f"BT report missing or run failed: {expected_bt}")

            # 4. RUN 2: Forward Portion (Split -> End)
            log.info("[Step 2/2] Running Forward Portion...")
            report_ft_name = f"Report_{filename.replace('.set', '')}_FWD"
            report_ft_val = f"reports\\{report_ft_name}"
            ini_ft = create_ini_file(f"Profiles\\Tester\\{filename}", report_ft_val,
                                     FORWARD_SPLIT_DATE, TO_DATE,
                                     inputs=set_inputs, symbol_override=file_symbol)
            with open(ini_path, "w") as f: f.write(ini_ft)
            ft_ok = run_mt5(ini_path)

            expected_ft = os.path.join(MT5_REPORTS_DIR, f"{report_ft_name}.htm")
            ft_metrics = {}
            if ft_ok and os.path.exists(expected_ft):
                raw_ft = parse_html_report(expected_ft, prefix="")
                ft_metrics = {f"FT_{k}": v for k, v in raw_ft.items()}
                if not metrics_valid(ft_metrics, "FT_"):
                    log.error(f"FT report parsed empty/zero for {filename} — marking failed.")
                    ft_metrics = {}
            else:
                log.error(f"FT report missing or run failed: {expected_ft}")

            # 5. Save Combined Results
            pass_match = re.search(r"Pass(\d+)", filename)
            pass_num = pass_match.group(1) if pass_match else "0"

            run_failed = not (metrics_valid(bt_metrics, "BT_") and metrics_valid(ft_metrics, "FT_"))
            regime_score = "FAILED" if run_failed else calculate_regime_score(bt_metrics, ft_metrics)

            row = {
                "Timestamp": datetime.now(),
                "SetFile": filename,
                "Pass": pass_num,
                "RegimeScore": regime_score,
            }
            row.update(bt_metrics)
            row.update(ft_metrics)

            row_list = [row.get(h, "") for h in RESULTS_HEADERS]
            with open(RESULTS_CSV, 'a', newline='') as f:
                csv.writer(f).writerow(row_list)
            log.info(f"Result saved ({'FAILED' if run_failed else 'ok'}): {filename}")

            # Push results to GitHub so dashboard can read them
            push_results_to_github(RESULTS_CSV)

            # 5a. Cleanup HTML Reports for this specific run
            try:
                if os.path.exists(expected_bt):
                    os.remove(expected_bt)
                if os.path.exists(expected_ft):
                    os.remove(expected_ft)
            except Exception as e:
                log.warning(f"Failed to delete HTML reports: {e}")




            # 6. Cleanup PNGs (Scanning reports dir)
            try:
                for f in os.listdir(MT5_REPORTS_DIR):
                    if f.endswith(".png"):
                        try:
                            os.remove(os.path.join(MT5_REPORTS_DIR, f))
                            # print(f"  Deleted garbage: {f}")
                        except: pass
            except: pass

            # 7. Final Cleanup (Move set file to Processed)
            final_path = os.path.join(PROCESSED_DIR, filename)
            if os.path.exists(final_path): os.remove(final_path)
            shutil.move(processing_path_onedrive, final_path)
            # Optional: Clean up MT5 side .set? Maybe keep for debugging.

if __name__ == "__main__":
    # Self-healing supervisor (H5): on crash, log the traceback and restart
    # instead of blocking on input(). Lets the worker survive transient faults
    # without a human at the RDP console.
    while True:
        try:
            run_worker()
        except KeyboardInterrupt:
            log.info("Interrupted by user — exiting.")
            break
        except Exception:
            log.exception("run_worker crashed — restarting in 30s")
            time.sleep(30)
