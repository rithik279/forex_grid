import streamlit as st
import pandas as pd
import plotly.express as px
import os
import subprocess
from datetime import datetime

# --- Configuration ---
REPO_DIR = r"C:\Users\manmi\GitHub\forex_grid"
RESULTS_PATH = r"C:\Users\manmi\GitHub\forex_grid\data\results.csv"

st.set_page_config(page_title="MT5 Strategy Analytics", layout="wide", page_icon="📈")

st.title("📈 MT5 Strategy Analytics: Single Test Batch")

# --- Auto Git Pull ---
def git_pull():
    try:
        result = subprocess.run(
            ["git", "pull"],
            cwd=REPO_DIR,
            capture_output=True, text=True, timeout=30
        )
        return result.stdout.strip() or result.stderr.strip()
    except Exception as e:
        return f"Git pull failed: {e}"

import json

# --- Sidebar ---

# 1. Batch Manager (Optimization Dashboard)
st.sidebar.header("Optimization Batch Manager")
with st.sidebar.form("batch_config_form"):
    # Default to current project XMLs if nothing set
    default_xml_path = r"C:\Users\manmi\Antigravity\XMLs"
    bc_path = st.text_input("Batch Folder Path", value=default_xml_path)
    bc_submit = st.form_submit_button("Update Batch Path")

if bc_submit:
    batch_config = {"batch_folder": bc_path.strip()}
    config_file = r"C:\Users\manmi\Antigravity\batch_config.json"
    try:
        with open(config_file, "w") as f:
            json.dump(batch_config, f, indent=4)
        st.sidebar.success(f"Batch Path Updated!\n{bc_path}")
    except Exception as e:
        st.sidebar.error(f"Failed to save batch config: {e}")

st.sidebar.markdown("---")

# 2. Single Test Runner (Remote Runner)
st.sidebar.header("Remote Runner Configuration")

# Load existing config for defaults
onedrive_config_path = os.path.expanduser(r"~\OneDrive\RD_MT5_Sharing\remote_config.json")
current_conf = {}

if os.path.exists(onedrive_config_path):
    try:
        with open(onedrive_config_path, "r") as f:
            current_conf = json.load(f)
    except: pass

# Helper to parse date or return default
def get_date(key, default_date):
    if key in current_conf:
        try:
            return datetime.strptime(current_conf[key], "%Y.%m.%d").date()
        except: return default_date.date() if isinstance(default_date, datetime) else default_date
    return default_date

with st.sidebar.form("remote_config_form"):
    # Defaults
    def_symbol = current_conf.get("Symbol", "NAS100ft.s")
    def_deposit = float(current_conf.get("Deposit", 50000))
    
    rc_symbol = st.text_input("Symbol", value=def_symbol)
    rc_deposit = st.number_input("Deposit", value=def_deposit)
    
    # Date Defaults
    d_from = datetime(2025, 9, 12)
    d_split = datetime(2025, 11, 12)
    d_to = datetime(2025, 12, 12)
    
    rc_from = st.date_input("Backtest Start", value=get_date("FromDate", d_from))
    rc_split = st.date_input("Split Date", value=get_date("SplitDate", d_split))
    rc_to = st.date_input("Forward End", value=get_date("ToDate", d_to))
    
    # Results Management
    st.markdown("### Results Management")
    rc_action = st.radio("Previous Results Action", ["Accumulate", "Clear"], index=0, help="Clear will delete results.csv before starting.")
    
    rc_submit = st.form_submit_button("Update Remote Config")

if rc_submit:
    config_data = {
        "Symbol": rc_symbol if rc_symbol else "NAS100ft.s",
        "Deposit": str(rc_deposit),
        "FromDate": rc_from.strftime("%Y.%m.%d"),
        "SplitDate": rc_split.strftime("%Y.%m.%d"),
        "ToDate": rc_to.strftime("%Y.%m.%d"),
        "ClearResults": True if rc_action == "Clear" else False
    }
    
    try:
        with open(onedrive_config_path, "w") as f:
            json.dump(config_data, f, indent=4)
        
        msg = "Config updated!"
        if config_data["ClearResults"]:
            msg += " (Results will be CLEARED on next run)"
        st.sidebar.success(msg)
            
    except Exception as e:
        st.sidebar.error(f"Failed to save config: {e}")

st.sidebar.markdown("---")
st.sidebar.header("Data Source")
# Allow user to override if needed
csv_path = st.sidebar.text_input("Path to results.csv", value=RESULTS_PATH)

if st.sidebar.button("🔄 Pull & Refresh"):
    with st.sidebar:
        with st.spinner("Pulling from GitHub..."):
            msg = git_pull()
    st.sidebar.success(msg[:200])
    st.rerun()

# Auto-pull on every page load
_pull_msg = git_pull()
st.sidebar.caption(f"Last pull: {_pull_msg[:80]}")

# --- Data Loading ---
if not os.path.exists(csv_path):
    st.error(f"Results file not found at: {csv_path}")
    st.info("Please run the `remote_runner.exe` to generate results first.")
    st.stop()

try:
    df = pd.read_csv(csv_path)
except Exception as e:
    st.error(f"Failed to read CSV: {e}")
    st.stop()

if df.empty:
    st.warning("Results CSV is empty.")
    st.stop()

# Ensure Pass is string for categorical plotting
if "Pass" in df.columns:
    df["Pass"] = df["Pass"].astype(str)

# --- Overview Metrics ---
st.subheader("Results Overview")

# Calculate Aggregates
total_bt_profit = df["BT_Profit"].sum() if "BT_Profit" in df.columns else 0
total_ft_profit = df["FT_Profit"].sum() if "FT_Profit" in df.columns else 0
avg_bt_pf = df["BT_ProfitFactor"].mean() if "BT_ProfitFactor" in df.columns else 0
avg_ft_pf = df["FT_ProfitFactor"].mean() if "FT_ProfitFactor" in df.columns else 0

col1, col2, col3, col4 = st.columns(4)
col1.metric("Total BT Profit", f"${total_bt_profit:,.2f}")
col2.metric("Total FT Profit", f"${total_ft_profit:,.2f}", delta=f"{total_ft_profit-total_bt_profit:,.2f} vs BT")
col3.metric("Avg BT Profit Factor", f"{avg_bt_pf:.2f}")
col4.metric("Avg FT Profit Factor", f"{avg_ft_pf:.2f}")

# --- Detailed Data View ---
with st.expander("📄 View Raw Data", expanded=True):
    # Dynamic gradient for all numeric columns
    numeric_cols = df.select_dtypes(include=['float', 'int']).columns
    st.dataframe(
        df.style.format(precision=2).background_gradient(subset=numeric_cols, cmap='RdYlGn'), 
        use_container_width=True
    )

# --- Charts ---
st.markdown("---")
st.subheader("Performance Visualization")

tab1, tab2, tab3 = st.tabs(["Profit Analysis", "Risk Analysis", "Win Rate & Reliability"])

with tab1:
    st.markdown("#### Backtest vs Forward Test Profit")
    if "BT_Profit" in df.columns and "FT_Profit" in df.columns:
        # Melt for side-by-side bar chart
        df_melt = df.melt(id_vars=["SetFile", "Pass"], value_vars=["BT_Profit", "FT_Profit"], var_name="Type", value_name="Profit")
        fig_profit = px.bar(df_melt, x="SetFile", y="Profit", color="Type", barmode="group",
                            hover_data=["Pass"], title="Profit Comparison per Set File")
        st.plotly_chart(fig_profit, use_container_width=True)
    else:
        st.warning("Profit columns missing.")

with tab2:
    col_risk1, col_risk2 = st.columns(2)
    with col_risk1:
        st.markdown("#### Drawdown % Comparison")
        if "BT_DrawdownPct" in df.columns and "FT_DrawdownPct" in df.columns:
            fig_dd = px.scatter(df, x="BT_DrawdownPct", y="FT_DrawdownPct", color="SetFile", 
                                title="Risk Correlation (BT vs FT Drawdown %)",
                                hover_data=["Pass"])
            # Add y=x line
            fig_dd.add_shape(type="line", line=dict(dash="dash", color="gray"),
                            x0=0, y0=0, x1=max(df["BT_DrawdownPct"].max(), df["FT_DrawdownPct"].max()),
                            y1=max(df["BT_DrawdownPct"].max(), df["FT_DrawdownPct"].max()))
            st.plotly_chart(fig_dd, use_container_width=True)
            
    with col_risk2:
        st.markdown("#### Max Consecutive Losses")
        if "BT_MaxConsecLosses" in df.columns and "FT_MaxConsecLosses" in df.columns:
             df_loss = df.melt(id_vars=["SetFile"], value_vars=["BT_MaxConsecLosses", "FT_MaxConsecLosses"], var_name="Type", value_name="Count")
             fig_loss = px.bar(df_loss, x="SetFile", y="Count", color="Type", barmode="group", title="Max Consecutive Losses")
             st.plotly_chart(fig_loss, use_container_width=True)

with tab3:
    st.markdown("#### Win Rate Stability")
    if "BT_WinRate" in df.columns and "FT_WinRate" in df.columns:
        fig_wr = px.bar(df.melt(id_vars=["SetFile"], value_vars=["BT_WinRate", "FT_WinRate"], var_name="Type", value_name="WinRate %"),
                        x="SetFile", y="WinRate %", color="Type", barmode="group", title="Win Rate Comparison")
        fig_wr.update_yaxes(range=[0, 100])
        st.plotly_chart(fig_wr, use_container_width=True)

# --- Manual Export Section ---
# Replaces previous "Deployment Pipeline" automation
st.sidebar.markdown("---")
st.sidebar.header("📂 Export Deploy-Ready Files")

with st.sidebar.form("export_form"):
    deploy_pass_ids = st.text_input("Pass IDs (comma separated)", placeholder="e.g. 1019, 2123")
    deploy_symbol = st.text_input("Symbol", value="NAS100ft.s")
    
    st.markdown("### Override Parameters")
    d_max_loss = st.number_input("Max Daily Loss", value=500.0)
    d_profit_target = st.number_input("Daily Profit Target", value=800.0)
    d_max_dd = st.number_input("Max Drawdown", value=1000.0)
    d_comment = st.text_input("Comment", value="Manual_Deploy")
    # License: Blank by default for privacy. Uses hardcoded default if empty.
    d_license_input = st.text_input("License Key", value="")
    
    export_btn = st.form_submit_button("Export Setfiles")

if export_btn and deploy_pass_ids:
    import setfile_exporter
    
    # Resolve License Key
    DEFAULT_LICENSE = "e1e582fb-0d37-4f65-ba71-a8d694a5d942"
    final_license = d_license_input.strip() if d_license_input.strip() else DEFAULT_LICENSE
    
    # Configuration
    processed_dir = r"C:\Users\manmi\OneDrive\RD_MT5_Sharing\Processed"
    output_dir = r"C:\Users\manmi\OneDrive\RD_MT5_Sharing\deploy_ready_setfiles"
    
    # Parse IDs
    pass_list = [p.strip() for p in deploy_pass_ids.split(",") if p.strip()]
    
    # Build Config List
    selected_configs = []
    
    # We need to find the base filename for each pass.
    # We scan processed_dir once.
    if os.path.exists(processed_dir):
        all_files = os.listdir(processed_dir)
        for pid in pass_list:
            # Find matching file
            match = next((f for f in all_files if f.lower().endswith(".set") and str(pid) in f), None)
            if match:
                selected_configs.append({
                    "pass_id": pid,
                    "symbol": deploy_symbol,
                    "base_filename": match
                })
            else:
                st.error(f"❌ Pass {pid}: Base setfile not found in {processed_dir}")
    
    # Overrides
    overrides = {
        "inpMaxRunningLoss": str(d_max_loss),
        "inpDailyProfitTarget": str(d_profit_target),
        "inpGlobalStop": str(d_max_dd),
        "inpTradeComment": d_comment,
        "inpLicenseKey": final_license
    }
    
    # Execute Export
    if selected_configs:
        st.info(f"Generating files for {len(selected_configs)} configs...")
        try:
            generated = setfile_exporter.export_setfiles(
                selected_configs, 
                overrides, 
                datetime.now().strftime("%Y%m%d"), 
                processed_dir, 
                output_dir
            )
            
            if generated:
                st.success(f"✅ Export Complete! {len(generated)} files created.")
                st.code(f"Output Folder: {output_dir}")
                with st.expander("View Generated Files"):
                    for g in generated:
                        st.write(os.path.basename(g))
            else:
                st.warning("No files were generated.")
                
        except Exception as e:
            st.error(f"Export Failed: {e}")
    else:
        st.warning("No valid configs found to export.")
