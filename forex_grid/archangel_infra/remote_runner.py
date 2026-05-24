import os
import time
import subprocess
import glob
import shutil
import csv
import re
import json
from datetime import datetime, timedelta

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
            print("  [Init] Created results.csv with headers.")
        except Exception as e:
            print(f"  [Error] Failed to init CSV: {e}")

def load_remote_config():
    """
    Loads dynamic configuration from OneDrive if available.
    Updates global variables.
    """
    global SYMBOL, DEPOSIT, FROM_DATE, TO_DATE, FORWARD_SPLIT_DATE
    config_path = os.path.join(ONEDRIVE_ROOT, "remote_config.json")
    
    if os.path.exists(config_path):
        try:
            with open(config_path, "r") as f:
                data = json.load(f)
                
            # Check Clear Flag
            if data.get("ClearResults") is True:
                print("  [Config] 'ClearResults' detected. Clearing results.csv...")
                if os.path.exists(RESULTS_CSV):
                    try: os.remove(RESULTS_CSV)
                    except: pass
                init_results_csv()
                
                # Reset Flag immediately
                data["ClearResults"] = False
                with open(config_path, "w") as f_out:
                    json.dump(data, f_out, indent=4)
                print("  [Config] results.csv cleared and flag reset.")

            # Only update if key exists and is not empty
            if data.get("Symbol"): SYMBOL = data["Symbol"]
            if data.get("Deposit"): DEPOSIT = str(data["Deposit"])
            if data.get("FromDate"): FROM_DATE = data["FromDate"]
            if data.get("SplitDate"): FORWARD_SPLIT_DATE = data["SplitDate"]
            if data.get("ToDate"): TO_DATE = data["ToDate"]
            print(f"  [Config] Loaded: {SYMBOL}, ${DEPOSIT}, {FROM_DATE} -> {FORWARD_SPLIT_DATE} -> {TO_DATE}")
            
        except Exception as e:
            print(f"  [Warning] Failed to load remote config: {e}")

# --- CONFIGURATION (REMOTE) ---

# 1. MT5 Terminal Path (Executable)
MT5_TERMINAL_PATH = r"C:\Program Files\PU Prime MT5 Terminal-1\terminal64.exe"

# 2. MT5 Data Folder (The "Hash" folder in AppData)
# User provided: C:\Users\Administrator\AppData\Roaming\MetaQuotes\Terminal\CB73EB447A09F27F5775C81FBB987ED5
# We use os.getenv('APPDATA') to be robust (C:\Users\Administrator\AppData\Roaming)
MT5_DATA_FOLDER_NAME = "CB73EB447A09F27F5775C81FBB987ED5"
MT5_DATA_FOLDER = os.path.join(os.getenv("APPDATA"), "MetaQuotes", "Terminal", MT5_DATA_FOLDER_NAME)

# 3. Paths inside Data Folder (Strict Non-Negotiable)
# .set files go here
MQL5_PROFILES_TESTER = os.path.join(MT5_DATA_FOLDER, "MQL5", "Profiles", "Tester")
# Reports come out here (MT5 Terminal Root / reports)
# Confirmed by user: ...\Terminal\HASH\reports
MT5_REPORTS_DIR = os.path.join(MT5_DATA_FOLDER, "reports")

# 4. Config Settings
EA_NAME = r"Advisors\Seraphim.ex5" # Relative to MQL5\Experts
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
        print(f"  [ERROR] Parsing HTML {os.path.basename(report_path)}: {e}")

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
        print(f"  [Warning] Failed to parse set file {os.path.basename(filepath)}: {e}")
    return inputs

def create_ini_file(set_filename_relative, report_base_relative, from_date, to_date, inputs=None):
    """
    Generates the MT5 configuration file.
    """
    conf = f'''[Tester]
Expert={EA_NAME}
ExpertParameters={set_filename_relative}
Symbol={SYMBOL}
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

def run_worker():
    print(f"--- Remote Worker (Single Test Mode) ---")
    print(f"MT5 Terminal: {MT5_TERMINAL_PATH}")
    print(f"MT5 Data Folder: {MT5_DATA_FOLDER}")
    print(f"Watching: {QUEUE_DIR}")

    # Ensure local dirs exist
    for d in [QUEUE_DIR, PROCESSING_DIR, PROCESSED_DIR, RESULTS_DIR]:
        os.makedirs(d, exist_ok=True)

    # Ensure MT5 target dirs exist
    if not os.path.exists(MQL5_PROFILES_TESTER):
        print(f"Warning: MT5 Local Dir not found: {MQL5_PROFILES_TESTER}")
        try: os.makedirs(MQL5_PROFILES_TESTER)
        except: pass
    
    if not os.path.exists(MT5_REPORTS_DIR):
        print(f"Creating Reports Dir: {MT5_REPORTS_DIR}")
        try: os.makedirs(MT5_REPORTS_DIR)
        except: pass

    # ... (omitted CSV init) ...

    # Initialize CSV
    init_results_csv()

    while True:
        queue_files = glob.glob(os.path.join(QUEUE_DIR, "*.set"))
        if not queue_files:
            time.sleep(2)
            continue

        for set_file_source in queue_files:
            filename = os.path.basename(set_file_source)
            print(f"\nProcessing {filename}...")

            # 0. Load Dynamic Configuration
            load_remote_config()

            # 1. Move to Processing (OneDrive)
            processing_path_onedrive = os.path.join(PROCESSING_DIR, filename)
            if os.path.exists(processing_path_onedrive): os.remove(processing_path_onedrive)
            shutil.move(set_file_source, processing_path_onedrive)

            # 2. Copy to MT5 Data Folder (MQL5/Profiles/Tester)
            mt5_set_path = os.path.join(MQL5_PROFILES_TESTER, filename)
            shutil.copy2(processing_path_onedrive, mt5_set_path)
            print(f"  Copied .set to: {mt5_set_path}")

            # Parse inputs from the source file
            set_inputs = parse_set_file(processing_path_onedrive)
            
            # 3. RUN 1: Backtest Portion (Start -> Split)
            print("  [Step 1/2] Running Backtest Portion...")
            report_bt_name = f"Report_{filename.replace('.set', '')}_BT"
            report_bt_val = f"reports\\{report_bt_name}" # No extension, MT5 adds .htm
            
            ini_bt = create_ini_file(f"Profiles\\Tester\\{filename}", report_bt_val, FROM_DATE, FORWARD_SPLIT_DATE, inputs=set_inputs)
            
            # Write INI and Run
            with open(os.path.join(PROCESSING_DIR, "mt5.ini"), "w") as f: f.write(ini_bt)
            subprocess.run([MT5_TERMINAL_PATH, f"/config:{os.path.join(PROCESSING_DIR, 'mt5.ini')}"], check=False)
            
            # Check/Parse BT Report
            expected_bt = os.path.join(MT5_REPORTS_DIR, f"{report_bt_name}.htm")
            bt_metrics = {}
            if os.path.exists(expected_bt):
                print(f"  BT Report Found: {expected_bt}")
                bt_metrics = parse_html_report(expected_bt, prefix="BT_")
            else:
                print(f"  [Error] BT Report missing: {expected_bt}")

            # 4. RUN 2: Forward Portion (Split -> End)
            print("  [Step 2/2] Running Forward Portion...")
            report_ft_name = f"Report_{filename.replace('.set', '')}_FWD"
            report_ft_val = f"reports\\{report_ft_name}"
            
            ini_ft = create_ini_file(f"Profiles\\Tester\\{filename}", report_ft_val, FORWARD_SPLIT_DATE, TO_DATE, inputs=set_inputs)
            
            # Write INI and Run
            with open(os.path.join(PROCESSING_DIR, "mt5.ini"), "w") as f: f.write(ini_ft)
            subprocess.run([MT5_TERMINAL_PATH, f"/config:{os.path.join(PROCESSING_DIR, 'mt5.ini')}"], check=False)
            
            # Check/Parse FWD Report
            expected_ft = os.path.join(MT5_REPORTS_DIR, f"{report_ft_name}.htm")
            ft_metrics = {}
            if os.path.exists(expected_ft):
                print(f"  FWD Report Found: {expected_ft}")
                # Parse as "BT_" because it looks like a backtest report, but we map it to FT output
                raw_ft = parse_html_report(expected_ft, prefix="") 
                # Remap keys manually to FT_
                ft_metrics = {f"FT_{k}": v for k, v in raw_ft.items()}
            else:
                 print(f"  [Error] FWD Report missing: {expected_ft}")

            # 5. Save Combined Results
            # Extract Pass Number
            pass_match = re.search(r"Pass(\d+)", filename)
            pass_num = pass_match.group(1) if pass_match else "0"

            regime_score = calculate_regime_score(bt_metrics, ft_metrics)

            row = {
                "Timestamp": datetime.now(),
                "SetFile": filename,
                "Pass": pass_num,
                "RegimeScore": regime_score,
            }
            row.update(bt_metrics)
            row.update(ft_metrics)

            print(f"  [DEBUG] Saving Row Data: {row}") # Visual Confirmation

            row_list = [row.get(h, "") for h in RESULTS_HEADERS]
            
            with open(RESULTS_CSV, 'a', newline='') as f:
                writer = csv.writer(f)
                writer.writerow(row_list)
            print("  Combined Results Saved.")

            # 5a. Cleanup HTML Reports for this specific run
            try:
                if os.path.exists(expected_bt):
                    os.remove(expected_bt)
                if os.path.exists(expected_ft):
                    os.remove(expected_ft)
            except Exception as e:
                print(f"  [Warning] Failed to delete HTML reports: {e}")




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

import traceback

if __name__ == "__main__":
    try:
        run_worker()
    except Exception:
        traceback.print_exc()
        input("Press Enter to exit...")
