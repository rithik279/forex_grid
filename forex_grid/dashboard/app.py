"""
Triton Trading Dashboard — Unified cloud deployment
Reads data from GitHub repo. Writes remote_config via GitHub API.
Env vars required:
  GITHUB_TOKEN   — personal access token (repo scope)
  GITHUB_REPO    — e.g. rithik279/forex_grid
  GITHUB_BRANCH  — default: main
"""

import streamlit as st
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import os
import json
import base64
import requests
from datetime import datetime
from io import StringIO

# ── Config ─────────────────────────────────────────────────────────────────
GITHUB_TOKEN  = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO   = os.environ.get("GITHUB_REPO", "rithik279/forex_grid")
GITHUB_BRANCH = os.environ.get("GITHUB_BRANCH", "main")

RESULTS_PATH        = "data/results.csv"
REMOTE_CONFIG_PATH  = "data/remote_config.json"

st.set_page_config(
    page_title="Triton Dashboard",
    layout="wide",
    page_icon="🔱",
    initial_sidebar_state="expanded",
)

# ── GitHub helpers ──────────────────────────────────────────────────────────
def gh_headers():
    if not GITHUB_TOKEN:
        return {}
    return {"Authorization": f"token {GITHUB_TOKEN}", "Accept": "application/vnd.github.v3+json"}

def gh_get_file(path):
    """Returns (content_str, sha) or (None, None)."""
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    r = requests.get(url, headers=gh_headers(), params={"ref": GITHUB_BRANCH})
    if r.status_code == 200:
        data = r.json()
        content = base64.b64decode(data["content"]).decode("utf-8")
        return content, data["sha"]
    return None, None

def gh_put_file(path, content_str, sha, message):
    """Creates or updates a file via GitHub API."""
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    body = {
        "message": message,
        "content": base64.b64encode(content_str.encode()).decode(),
        "branch": GITHUB_BRANCH,
    }
    if sha:
        body["sha"] = sha
    r = requests.put(url, headers=gh_headers(), json=body)
    return r.status_code in (200, 201), r.json()

def gh_raw(path):
    """Direct raw URL read — faster, no auth needed for public repos."""
    url = f"https://raw.githubusercontent.com/{GITHUB_REPO}/{GITHUB_BRANCH}/{path}"
    r = requests.get(url, headers=gh_headers())
    if r.status_code == 200:
        return r.text
    return None

# ── Load data ───────────────────────────────────────────────────────────────
@st.cache_data(ttl=60)
def load_results():
    raw = gh_raw(RESULTS_PATH)
    if raw:
        try:
            return pd.read_csv(StringIO(raw))
        except Exception:
            pass
    return pd.DataFrame()

@st.cache_data(ttl=30)
def load_remote_config():
    raw = gh_raw(REMOTE_CONFIG_PATH)
    if raw:
        try:
            return json.loads(raw)
        except Exception:
            pass
    return {
        "Symbol": "EURUSD.s",
        "Deposit": "50000",
        "FromDate": "2026.02.01",
        "SplitDate": "2026.04.16",
        "ToDate": "2026.05.24",
        "ClearResults": False,
        "MT5TerminalPath": "C:\\Program Files\\PU Prime MT5 Terminal 2\\terminal64.exe",
        "MT5DataFolderName": "FDFD46F1C842DA981CA8507F035DD9E0",
    }

# ── Sidebar nav ─────────────────────────────────────────────────────────────
st.sidebar.image("https://img.icons8.com/emoji/96/trident-emblem.png", width=60)
st.sidebar.title("🔱 Triton")
st.sidebar.caption(f"Repo: `{GITHUB_REPO}`")

page = st.sidebar.radio(
    "Navigate",
    ["📊 Results Analytics", "📡 Live Monitor", "⚙️ Runner Config", "📥 Queue Manager"],
    label_visibility="collapsed",
)

st.sidebar.markdown("---")
if st.sidebar.button("🔄 Refresh Data"):
    st.cache_data.clear()
    st.rerun()

no_token = not GITHUB_TOKEN
if no_token:
    st.sidebar.warning("⚠️ GITHUB_TOKEN not set — read-only mode")

# ═══════════════════════════════════════════════════════════════════════════
# PAGE 1 — RESULTS ANALYTICS
# ═══════════════════════════════════════════════════════════════════════════
if page == "📊 Results Analytics":
    st.title("📊 Results Analytics")
    st.caption("Single-test BT + FT results from remote_runner pipeline")

    df = load_results()

    if df.empty:
        st.info("No results yet. Run remote_runner and commit `data/results.csv` to see data here.")
        st.stop()

    if "Pass" in df.columns:
        df["Pass"] = df["Pass"].astype(str)

    # ── Top metrics
    col1, col2, col3, col4, col5 = st.columns(5)
    total_runs = len(df)
    bt_profit = df["BT_Profit"].sum() if "BT_Profit" in df.columns else 0
    ft_profit = df["FT_Profit"].sum() if "FT_Profit" in df.columns else 0
    avg_score = df["RegimeScore"].mean() if "RegimeScore" in df.columns else 0
    best_score = df["RegimeScore"].max() if "RegimeScore" in df.columns else 0

    col1.metric("Total Runs", total_runs)
    col2.metric("Sum BT Profit", f"${bt_profit:,.0f}")
    col3.metric("Sum FT Profit", f"${ft_profit:,.0f}", delta=f"{ft_profit - bt_profit:+,.0f}")
    col4.metric("Avg RegimeScore", f"{avg_score:,.0f}")
    col5.metric("Best RegimeScore", f"{best_score:,.0f}")

    st.markdown("---")

    # ── Filters
    with st.expander("🔍 Filters", expanded=False):
        fc1, fc2, fc3 = st.columns(3)
        min_bt = fc1.number_input("Min BT Profit", value=0.0)
        min_ft = fc2.number_input("Min FT Profit", value=0.0)
        min_score = fc3.number_input("Min RegimeScore", value=-99999.0)

        if "BT_Profit" in df.columns:
            df = df[df["BT_Profit"] >= min_bt]
        if "FT_Profit" in df.columns:
            df = df[df["FT_Profit"] >= min_ft]
        if "RegimeScore" in df.columns:
            df = df[df["RegimeScore"] >= min_score]

    # ── Data table
    st.subheader("Results Table")
    numeric_cols = df.select_dtypes(include=["float", "int"]).columns.tolist()
    st.dataframe(
        df.style.format({c: "{:.2f}" for c in numeric_cols})
          .background_gradient(subset=[c for c in ["BT_Profit", "FT_Profit", "RegimeScore"] if c in df.columns], cmap="RdYlGn"),
        use_container_width=True,
        height=300,
    )

    # ── Charts
    st.markdown("---")
    tab1, tab2, tab3, tab4 = st.tabs(["Profit", "Drawdown", "Win Rate", "RegimeScore"])

    with tab1:
        if "BT_Profit" in df.columns and "FT_Profit" in df.columns:
            melt = df.melt(id_vars=["SetFile"], value_vars=["BT_Profit", "FT_Profit"],
                           var_name="Period", value_name="Profit")
            st.plotly_chart(
                px.bar(melt, x="SetFile", y="Profit", color="Period", barmode="group",
                       title="BT vs FT Profit per Set File"),
                use_container_width=True,
            )

    with tab2:
        if "BT_Drawdown" in df.columns and "FT_Drawdown" in df.columns:
            fig = px.scatter(df, x="BT_Drawdown", y="FT_Drawdown", color="SetFile",
                             title="Drawdown Correlation (BT vs FT)", hover_data=["Pass"])
            mx = max(df["BT_Drawdown"].max(), df["FT_Drawdown"].max())
            fig.add_shape(type="line", x0=0, y0=0, x1=mx, y1=mx,
                          line=dict(dash="dash", color="gray"))
            st.plotly_chart(fig, use_container_width=True)

    with tab3:
        wr_cols = [c for c in ["BT_WinRate", "FT_WinRate"] if c in df.columns]
        if wr_cols:
            melt = df.melt(id_vars=["SetFile"], value_vars=wr_cols,
                           var_name="Period", value_name="WinRate")
            fig = px.bar(melt, x="SetFile", y="WinRate", color="Period", barmode="group",
                         title="Win Rate BT vs FT")
            fig.add_hline(y=65, line_dash="dash", line_color="orange",
                          annotation_text="65% target")
            fig.update_yaxes(range=[0, 100])
            st.plotly_chart(fig, use_container_width=True)

    with tab4:
        if "RegimeScore" in df.columns:
            df_sorted = df.sort_values("RegimeScore", ascending=True)
            st.plotly_chart(
                px.bar(df_sorted, x="SetFile", y="RegimeScore",
                       color="RegimeScore", color_continuous_scale="RdYlGn",
                       title="RegimeScore Ranking"),
                use_container_width=True,
            )


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 2 — LIVE MONITOR
# ═══════════════════════════════════════════════════════════════════════════
elif page == "📡 Live Monitor":
    st.title("📡 Live Monitor")
    st.caption("Live positions and equity from MT5 (requires fetch_live_history running on VPS)")

    # Try loading LiveHistory and LivePositions from GitHub
    hist_raw = gh_raw("data/LiveHistory.csv")
    pos_raw  = gh_raw("data/LivePositions.csv")

    if hist_raw:
        df_hist = pd.read_csv(StringIO(hist_raw))
        st.subheader("Trade History")
        st.dataframe(df_hist, use_container_width=True)

        if "Profit" in df_hist.columns:
            df_hist["CumProfit"] = df_hist["Profit"].cumsum()
            st.plotly_chart(
                px.line(df_hist, y="CumProfit", title="Cumulative P&L"),
                use_container_width=True,
            )
    else:
        st.info("No live history data. Push `data/LiveHistory.csv` to GitHub to see it here.")

    if pos_raw:
        df_pos = pd.read_csv(StringIO(pos_raw))
        st.subheader("Open Positions")
        st.dataframe(df_pos, use_container_width=True)
    else:
        st.info("No open positions data.")


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 3 — RUNNER CONFIG
# ═══════════════════════════════════════════════════════════════════════════
elif page == "⚙️ Runner Config":
    st.title("⚙️ Remote Runner Config")
    st.caption("Updates `data/remote_config.json` in GitHub → VPS picks up on next git pull")

    if no_token:
        st.error("GITHUB_TOKEN env var required to write config. Read-only mode.")

    cfg = load_remote_config()

    with st.form("config_form"):
        c1, c2 = st.columns(2)
        symbol  = c1.text_input("Symbol", value=cfg.get("Symbol", "EURUSD.s"))
        deposit = c2.number_input("Deposit", value=float(cfg.get("Deposit", 50000)))

        c3, c4, c5 = st.columns(3)
        def parse_dt(key, fallback):
            try:
                return datetime.strptime(cfg.get(key, fallback), "%Y.%m.%d").date()
            except Exception:
                return datetime.strptime(fallback, "%Y.%m.%d").date()

        from_date  = c3.date_input("BT Start",    value=parse_dt("FromDate",  "2026.02.01"))
        split_date = c4.date_input("Split Date",   value=parse_dt("SplitDate", "2026.04.16"))
        to_date    = c5.date_input("FT End",       value=parse_dt("ToDate",    "2026.05.24"))

        st.markdown("---")
        c6, c7 = st.columns(2)
        terminal_path = c6.text_input("MT5 Terminal Path", value=cfg.get("MT5TerminalPath", ""))
        data_folder   = c7.text_input("MT5 Data Folder Hash", value=cfg.get("MT5DataFolderName", ""))

        clear_results = st.checkbox("Clear results.csv before next run", value=False)

        submitted = st.form_submit_button("💾 Save to GitHub", disabled=no_token)

    if submitted and not no_token:
        new_cfg = {
            "Symbol":           symbol,
            "Deposit":          str(int(deposit)),
            "FromDate":         from_date.strftime("%Y.%m.%d"),
            "SplitDate":        split_date.strftime("%Y.%m.%d"),
            "ToDate":           to_date.strftime("%Y.%m.%d"),
            "ClearResults":     clear_results,
            "MT5TerminalPath":  terminal_path,
            "MT5DataFolderName": data_folder,
        }
        _, sha = gh_get_file(REMOTE_CONFIG_PATH)
        ok, resp = gh_put_file(
            REMOTE_CONFIG_PATH,
            json.dumps(new_cfg, indent=4),
            sha,
            f"dashboard: update remote_config {datetime.utcnow().strftime('%Y-%m-%d %H:%M')} UTC",
        )
        if ok:
            st.success("✅ Config saved to GitHub. VPS picks up on next `git pull`.")
            st.cache_data.clear()
        else:
            st.error(f"GitHub API error: {resp.get('message', resp)}")

    st.markdown("---")
    st.subheader("Current Config (live from GitHub)")
    st.json(cfg)


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 4 — QUEUE MANAGER
# ═══════════════════════════════════════════════════════════════════════════
elif page == "📥 Queue Manager":
    st.title("📥 Queue Manager")
    st.caption("View and manage .set files in the OneDrive Queue via GitHub")

    st.info(
        "Queue files live in `OneDrive/RD_MT5_Sharing/Queue/` on your local machine. "
        "Drop .set files there to trigger remote_runner on VPS. "
        "Use **Results Analytics** to see completed run results."
    )

    # Show last N results as proxy for queue status
    df = load_results()
    if not df.empty:
        st.subheader("Recent Processed Files")
        recent = df.tail(20)[["Timestamp", "SetFile", "BT_Profit", "FT_Profit", "RegimeScore"]].copy()
        st.dataframe(recent, use_container_width=True)
    else:
        st.info("No results yet.")

    st.markdown("---")
    st.subheader("RegimeScore Leaderboard")
    if not df.empty and "RegimeScore" in df.columns:
        top = df.nlargest(10, "RegimeScore")[
            ["SetFile", "BT_Profit", "FT_Profit", "BT_Drawdown", "BT_WinRate", "RegimeScore"]
        ]
        st.dataframe(
            top.style.format(precision=2).background_gradient(subset=["RegimeScore"], cmap="YlGn"),
            use_container_width=True,
        )
