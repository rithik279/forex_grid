"""
Triton Trading Dashboard — Unified cloud deployment
Pages:
  1. 🔬 Set Finder      — upload XMLs, score, generate .set files, push to queue
  2. 📊 Results Analytics — single-test results from remote_runner
  3. 📡 Live Monitor    — live positions / equity
  4. ⚙️ Runner Config   — edit remote_config.json
  5. 📥 Queue Manager   — queue status + leaderboard

Env vars required:
  GITHUB_TOKEN   — PAT with repo scope
  GITHUB_REPO    — e.g. rithik279/forex_grid
  GITHUB_BRANCH  — default: main
"""

import streamlit as st
import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import os, json, base64, requests, math, zipfile, re
from datetime import datetime
from io import StringIO, BytesIO
import xml.etree.ElementTree as ET

# ── Config ──────────────────────────────────────────────────────────────────
GITHUB_TOKEN  = os.environ.get("GITHUB_TOKEN", "")
GITHUB_REPO   = os.environ.get("GITHUB_REPO",  "rithik279/forex_grid")
GITHUB_BRANCH = os.environ.get("GITHUB_BRANCH","main")

# All paths relative to repo root (forex_grid/ subdirectory inside rithik279/forex_grid)
RESULTS_PATH        = "forex_grid/data/results.csv"
REMOTE_CONFIG_PATH  = "forex_grid/data/remote_config.json"
QUEUE_GITHUB_PATH   = "forex_grid/data/queue"
TEMPLATES_GH_PATH   = "forex_grid/optimization_templates"
LIVE_HISTORY_PATH   = "forex_grid/data/LiveHistory.csv"
LIVE_POSITIONS_PATH = "forex_grid/data/LivePositions.csv"

LOCAL_QUEUE_DIR = os.path.join(os.path.expanduser("~"), "OneDrive",
                               "RD_MT5_Sharing", "Queue")

st.set_page_config(
    page_title="Triton Dashboard",
    layout="wide",
    page_icon="🔱",
    initial_sidebar_state="expanded",
)

# ── GitHub helpers ───────────────────────────────────────────────────────────
def gh_headers():
    if not GITHUB_TOKEN:
        return {}
    return {"Authorization": f"token {GITHUB_TOKEN}",
            "Accept": "application/vnd.github.v3+json"}

def gh_get_file(path):
    url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{path}"
    r = requests.get(url, headers=gh_headers(), params={"ref": GITHUB_BRANCH})
    if r.status_code == 200:
        data = r.json()
        content = base64.b64decode(data["content"]).decode("utf-8")
        return content, data["sha"]
    return None, None

def gh_put_file(path, content_str, sha, message):
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
    url = f"https://raw.githubusercontent.com/{GITHUB_REPO}/{GITHUB_BRANCH}/{path}"
    r = requests.get(url, headers=gh_headers())
    return r.text if r.status_code == 200 else None

# ── Archangel X Score ────────────────────────────────────────────────────────
def _clamp(v, lo, hi):
    return min(hi, max(lo, v))

def compute_archangel_score(bt_profit, ft_profit, bt_dd_pct, ft_dd_pct,
                             bt_trades, ft_trades, orig_max_dd):
    t, n = float(bt_profit), float(ft_profit)
    r, o = float(bt_dd_pct), float(ft_dd_pct)
    i, s = float(bt_trades), float(ft_trades)
    a = i + s
    l = float(orig_max_dd)

    if n <= 0:
        return 0.0

    # U — profit per DD unit (weight 60%)
    u = (t / l / 5 * 100) if (l > 0 and t > 0) else 0.0
    u = _clamp(u, 0, 100)

    # D — DD consistency (weight 25%)
    d = 0.0
    if r > 0 or o > 0:
        I = abs(r - o)
        R = s / a if a > 0 else 0
        O = _clamp(R + 0.1, 0.2, 0.7)
        w = max(I - 2, 0)
        D = 1.2 * (0.5 + O)
        d = 100 - w * D
    d = _clamp(d, 0, 100)

    # H — trade volume (weight 15%)
    h = 0.0
    if a > 0:
        h = min(a, 300) / 300 * 85
        if a > 300:
            h += (1 - math.exp(-(a - 300) / 400)) * 15
    h = _clamp(h, 0, 100)

    # P — penalties (capped 30)
    p = 0.0
    if 0 < a < 300:
        p += (300 - a) / 300 * 12
    EPS = 1e-6
    if t > 0 and n > 0:
        ratio = n / (t / 3 + EPS)
        p += _clamp(abs(ratio - 1) * 15, 0, 15)
    if i > 0 and s > 0:
        ratio = s / (i / 3 + EPS)
        p += _clamp(abs(ratio - 1) * 4, 0, 4)
    p = _clamp(p, 0, 30)

    score = _clamp(0.6 * u + 0.25 * d + 0.15 * h - p, 0, 100)
    return round(score, 1)

def get_tier(score):
    s = float(score)
    if s >= 90: return "A+"
    if s >= 85: return "A"
    if s >= 80: return "A-"
    if s >= 77: return "B+"
    if s >= 73: return "B"
    if s >= 70: return "B-"
    if s >= 67: return "C+"
    if s >= 63: return "C"
    if s >= 60: return "C-"
    if s >= 57: return "D+"
    if s >= 53: return "D"
    if s >= 50: return "D-"
    return "F"

TIER_COLORS = {
    "A+": "#00C851", "A": "#28a745", "A-": "#5cb85c",
    "B+": "#9ACD32", "B": "#b8c800", "B-": "#d4e157",
    "C+": "#ffc107", "C": "#ff9800", "C-": "#ff7043",
    "D+": "#f44336", "D": "#e53935", "D-": "#c62828",
    "F":  "#880e4f",
}

# ── XML parsing ──────────────────────────────────────────────────────────────
def parse_mt5_xml(content_bytes):
    """Parse MT5 Excel 2003 XML optimization export. Returns (DataFrame, deposit)."""
    try:
        if isinstance(content_bytes, bytes):
            text = content_bytes.decode("utf-8", errors="replace")
        else:
            text = content_bytes

        root = ET.fromstring(text.encode("utf-8"))
        ns_ss = "urn:schemas-microsoft-com:office:spreadsheet"
        ns_o  = "urn:schemas-microsoft-com:office:office"

        deposit = 50000.0
        dp = root.find(f"{{{ns_o}}}DocumentProperties")
        if dp is not None:
            dep = dp.find(f"{{{ns_o}}}Deposit")
            if dep is not None and dep.text:
                try:
                    deposit = float(dep.text.split()[0])
                except Exception:
                    pass

        ns = {"ss": ns_ss}
        rows = root.findall(".//ss:Row", ns)
        if not rows:
            return pd.DataFrame(), deposit

        headers = [c.text or "" for c in rows[0].findall("ss:Cell/ss:Data", ns)]
        data = []
        for row in rows[1:]:
            cells = row.findall("ss:Cell/ss:Data", ns)
            vals = []
            for c in cells:
                t = c.get(f"{{{ns_ss}}}Type", "String")
                txt = c.text or ""
                if t == "Number":
                    try:
                        vals.append(float(txt))
                    except Exception:
                        vals.append(txt)
                else:
                    vals.append(txt)
            if vals:
                while len(vals) < len(headers):
                    vals.append("")
                data.append(vals[:len(headers)])

        return pd.DataFrame(data, columns=headers), deposit
    except Exception as e:
        st.error(f"XML parse error: {e}")
        return pd.DataFrame(), 50000.0

def process_xml_pair(bt_bytes, ft_bytes, deposit_override, target_dd):
    """Merge BT+FT XMLs, compute Archangel X scores. Returns scored DataFrame."""
    df_bt, dep_bt = parse_mt5_xml(bt_bytes)
    df_ft, _      = parse_mt5_xml(ft_bytes)

    if df_bt.empty or df_ft.empty:
        return pd.DataFrame()

    deposit = deposit_override if deposit_override > 0 else dep_bt

    pass_col_bt = next((c for c in df_bt.columns if c.lower() == "pass"), None)
    pass_col_ft = next((c for c in df_ft.columns if c.lower() == "pass"), None)
    if not pass_col_bt or not pass_col_ft:
        st.error("No 'Pass' column found in XML.")
        return pd.DataFrame()

    df_bt = df_bt.rename(columns={pass_col_bt: "Pass"})
    df_ft = df_ft.rename(columns={pass_col_ft: "Pass"})
    df_bt = df_bt.add_prefix("BT_").rename(columns={"BT_Pass": "Pass"})
    df_ft = df_ft.add_prefix("FT_").rename(columns={"FT_Pass": "Pass"})

    merged = pd.merge(df_bt, df_ft, on="Pass", how="inner")

    def fcol(prefix, pattern):
        candidates = [c for c in merged.columns
                      if c.startswith(prefix) and pattern.lower() in c.lower()]
        return candidates[0] if candidates else None

    bt_profit_col = fcol("BT_", "Profit")
    ft_profit_col = fcol("FT_", "Profit")
    bt_dd_col     = fcol("BT_", "Equity DD")
    ft_dd_col     = fcol("FT_", "Equity DD")
    bt_trades_col = fcol("BT_", "Trades")
    ft_trades_col = fcol("FT_", "Trades")

    if not bt_profit_col or not ft_profit_col:
        st.error("Could not find Profit columns in XML.")
        return pd.DataFrame()

    merged["BT_Profit"] = pd.to_numeric(merged[bt_profit_col], errors="coerce").fillna(0)
    merged["FT_Profit"] = pd.to_numeric(merged[ft_profit_col], errors="coerce").fillna(0)
    merged["BT_DD_Pct"] = pd.to_numeric(merged[bt_dd_col],     errors="coerce").fillna(0) if bt_dd_col else 0
    merged["FT_DD_Pct"] = pd.to_numeric(merged[ft_dd_col],     errors="coerce").fillna(0) if ft_dd_col else 0
    merged["BT_Trades"] = pd.to_numeric(merged[bt_trades_col], errors="coerce").fillna(0) if bt_trades_col else 0
    merged["FT_Trades"] = pd.to_numeric(merged[ft_trades_col], errors="coerce").fillna(0) if ft_trades_col else 0

    merged["Orig_Max_DD"]      = (deposit * merged[["BT_DD_Pct","FT_DD_Pct"]].max(axis=1) / 100.0).clip(lower=0.01)
    merged["Lot_Multiplier"]   = (target_dd / merged["Orig_Max_DD"]).round(2)
    merged["Total_Profit"]     = merged["BT_Profit"] + merged["FT_Profit"]
    merged["Est_Total_Profit"] = (merged["Lot_Multiplier"] * merged["Total_Profit"]).round(2)
    merged["Est_Total_DD"]     = target_dd

    merged["Score"] = merged.apply(lambda row: compute_archangel_score(
        row["BT_Profit"], row["FT_Profit"],
        row["BT_DD_Pct"], row["FT_DD_Pct"],
        row["BT_Trades"], row["FT_Trades"],
        row["Orig_Max_DD"]
    ), axis=1)
    merged["Tier"] = merged["Score"].apply(get_tier)

    return merged.sort_values("Score", ascending=False).reset_index(drop=True)

# ── .set file generation ─────────────────────────────────────────────────────
def fetch_template_from_github(strategy_name):
    path = f"{TEMPLATES_GH_PATH}/{strategy_name}.set"
    return gh_raw(path)

def generate_set_content(row, template_lines, lot_multiplier):
    new_lines = []
    for line in template_lines:
        line = line.rstrip("\r\n")
        if not line or line.startswith(";") or "=" not in line:
            new_lines.append(line)
            continue
        key, val_part = line.split("=", 1)
        key = key.strip()
        val_only = val_part.split("||")[0]

        target_col = f"BT_{key}"
        if target_col in row.index:
            val_only = str(row[target_col])

        if key == "LotSize":
            try:
                val_only = str(round(float(val_only) * lot_multiplier, 2))
            except Exception:
                pass

        new_lines.append(f"{key}={val_only}")
    return "\n".join(new_lines)

def build_set_files_zip(df_top, strategy_name, template_content, target_dd):
    template_lines = template_content.splitlines()
    buf = BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for _, row in df_top.iterrows():
            pass_num = int(row["Pass"]) if "Pass" in row.index else 0
            lot_mult = float(row.get("Lot_Multiplier", 1.0))
            content  = generate_set_content(row, template_lines, lot_mult)
            zf.writestr(f"{strategy_name}_Pass{pass_num}.set", content)
    buf.seek(0)
    return buf

def push_set_files_to_github(df_top, strategy_name, template_content, target_dd):
    template_lines = template_content.splitlines()
    pushed = 0
    for _, row in df_top.iterrows():
        pass_num = int(row["Pass"]) if "Pass" in row.index else 0
        lot_mult = float(row.get("Lot_Multiplier", 1.0))
        content  = generate_set_content(row, template_lines, lot_mult)
        fname    = f"{strategy_name}_Pass{pass_num}.set"
        path     = f"{QUEUE_GITHUB_PATH}/{fname}"
        _, sha   = gh_get_file(path)
        ok, _    = gh_put_file(path, content, sha, f"dashboard: queue {fname}")
        if ok:
            pushed += 1
    return pushed

# ── Load cached data ─────────────────────────────────────────────────────────
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
        "Symbol": "EURUSD.s", "Deposit": "50000",
        "FromDate": "2026.02.01", "SplitDate": "2026.04.16",
        "ToDate": "2026.05.24", "ClearResults": False,
        "MT5TerminalPath": "C:\\Program Files\\PU Prime MT5 Terminal 2\\terminal64.exe",
        "MT5DataFolderName": "FDFD46F1C842DA981CA8507F035DD9E0",
    }

# ── Sidebar ──────────────────────────────────────────────────────────────────
st.sidebar.image("https://img.icons8.com/emoji/96/trident-emblem.png", width=60)
st.sidebar.title("🔱 Triton")
st.sidebar.caption(f"Repo: `{GITHUB_REPO}`")

page = st.sidebar.radio(
    "Navigate",
    ["🔬 Set Finder", "📊 Results Analytics",
     "📡 Live Monitor", "⚙️ Runner Config", "📥 Queue Manager"],
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
# PAGE 1 — SET FINDER
# ═══════════════════════════════════════════════════════════════════════════
if page == "🔬 Set Finder":
    st.title("🔬 Set Finder")
    st.caption("Upload BT + FT XML → Archangel X score → generate .set files → push to queue → view results")

    with st.expander("⚙️ Settings", expanded=True):
        c1, c2, c3 = st.columns(3)
        balance   = c1.number_input("Balance ($)",          value=50000.0, step=1000.0)
        target_dd = c2.number_input("Target Drawdown ($)",  value=3000.0,  step=500.0)
        top_n     = c3.number_input("Top N to export",      value=20, min_value=1, max_value=500)

        c4, c5 = st.columns(2)
        min_score = c4.number_input("Min Score filter", value=70.0, step=1.0)
        min_tiers = c5.multiselect(
            "Tier filter",
            ["A+","A","A-","B+","B","B-","C+","C","C-","D+","D","D-","F"],
            default=["A+","A","A-","B+","B"],
        )

    col_bt, col_ft = st.columns(2)
    bt_file = col_bt.file_uploader("📂 BT Optimization XML", type=["xml"])
    ft_file = col_ft.file_uploader("📂 FT Forward XML",      type=["xml"])

    if bt_file and ft_file:
        raw_name      = bt_file.name.replace("_optimization.xml","").replace(".xml","")
        strategy_name = raw_name

        if st.button("🚀 Analyse", type="primary"):
            with st.spinner("Parsing XMLs and computing scores…"):
                df = process_xml_pair(
                    bt_file.read(), ft_file.read(),
                    deposit_override=balance, target_dd=target_dd,
                )
            if df.empty:
                st.error("Could not parse XML pair. Check file format.")
            else:
                st.session_state["sf_df"]       = df
                st.session_state["sf_strategy"] = strategy_name
                st.success(f"✅ Parsed **{len(df):,}** passes for **{strategy_name}**")

    if "sf_df" in st.session_state:
        df_all = st.session_state["sf_df"]
        sname  = st.session_state.get("sf_strategy", "strategy")

        df_filt = df_all[
            (df_all["Score"] >= min_score) &
            (df_all["Tier"].isin(min_tiers))
        ].head(int(top_n))

        mc = st.columns(5)
        mc[0].metric("Total Passes",  f"{len(df_all):,}")
        mc[1].metric("After Filters", f"{len(df_filt):,}")
        mc[2].metric("Best Score",    str(df_all["Score"].max()))
        mc[3].metric("Best Tier",     df_all["Tier"].iloc[0] if not df_all.empty else "—")
        mc[4].metric("Target DD",     f"${target_dd:,.0f}")

        st.markdown("---")

        display_cols = ["Pass","BT_Profit","FT_Profit","Total_Profit",
                        "BT_DD_Pct","BT_Trades","FT_DD_Pct","FT_Trades",
                        "Orig_Max_DD","Lot_Multiplier","Est_Total_Profit",
                        "Est_Total_DD","Score","Tier"]
        display_cols = [c for c in display_cols if c in df_filt.columns]
        df_show = df_filt[display_cols].copy()

        def tier_color(val):
            color = TIER_COLORS.get(val, "#ffffff")
            return f"background-color:{color};color:white;font-weight:bold;text-align:center"

        fmt = {c: "{:.2f}" for c in df_show.select_dtypes("float").columns}
        styled = (df_show.style
                  .format(fmt)
                  .applymap(tier_color, subset=["Tier"])
                  .background_gradient(subset=["Score"], cmap="RdYlGn", vmin=50, vmax=100)
                  .background_gradient(subset=["Est_Total_Profit"], cmap="Greens"))
        st.dataframe(styled, use_container_width=True, height=520)

        st.markdown("---")

        if not df_filt.empty:
            template_content = fetch_template_from_github(sname)
            if not template_content:
                st.warning(f"⚠️ Template `{sname}.set` not found in GitHub — .set generation disabled.")

            col_a, col_b, col_c = st.columns(3)

            if template_content:
                zip_buf = build_set_files_zip(df_filt, sname, template_content, target_dd)
                col_a.download_button(
                    "⬇️ Download .set files (ZIP)",
                    data=zip_buf,
                    file_name=f"{sname}_setfiles.zip",
                    mime="application/zip",
                )

            if col_b.button("📤 Push to GitHub Queue", disabled=(no_token or not template_content)):
                with st.spinner(f"Pushing {len(df_filt)} files to GitHub queue…"):
                    n = push_set_files_to_github(df_filt, sname, template_content, target_dd)
                st.success(f"✅ Pushed **{n}** .set files → `{QUEUE_GITHUB_PATH}/` — VPS will pick up shortly.")

            if col_c.button("💾 Push to Local OneDrive Queue"):
                if not template_content:
                    st.error("No template found.")
                elif not os.path.exists(LOCAL_QUEUE_DIR):
                    st.error(f"OneDrive Queue not found: {LOCAL_QUEUE_DIR}")
                else:
                    template_lines = template_content.splitlines()
                    count = 0
                    for _, row in df_filt.iterrows():
                        pass_num = int(row["Pass"])
                        lot_mult = float(row.get("Lot_Multiplier", 1.0))
                        content  = generate_set_content(row, template_lines, lot_mult)
                        with open(os.path.join(LOCAL_QUEUE_DIR, f"{sname}_Pass{pass_num}.set"), "w") as f:
                            f.write(content)
                        count += 1
                    st.success(f"✅ Wrote {count} .set files to {LOCAL_QUEUE_DIR}")

        st.markdown("---")
        st.subheader("Score Distribution")
        tier_order  = ["A+","A","A-","B+","B","B-","C+","C","C-","D+","D","D-","F"]
        tier_counts = df_all["Tier"].value_counts().reindex(tier_order).dropna()
        fig = px.bar(x=tier_counts.index, y=tier_counts.values,
                     color=tier_counts.index,
                     color_discrete_map=TIER_COLORS,
                     labels={"x":"Tier","y":"Count"},
                     title=f"{sname} — All Passes by Tier")
        st.plotly_chart(fig, use_container_width=True)

    else:
        st.info("Upload both XML files above and click **Analyse** to begin.")


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 2 — RESULTS ANALYTICS
# ═══════════════════════════════════════════════════════════════════════════
elif page == "📊 Results Analytics":
    st.title("📊 Results Analytics")
    st.caption("Single-test BT + FT results from remote_runner pipeline")

    df = load_results()
    if df.empty:
        st.info("No results yet. Run remote_runner and let it push `data/results.csv` to see data here.")
        st.stop()

    if "Pass" in df.columns:
        df["Pass"] = df["Pass"].astype(str)

    col1, col2, col3, col4, col5 = st.columns(5)
    bt_profit  = df["BT_Profit"].sum()    if "BT_Profit"    in df.columns else 0
    ft_profit  = df["FT_Profit"].sum()    if "FT_Profit"    in df.columns else 0
    avg_score  = df["RegimeScore"].mean() if "RegimeScore"  in df.columns else 0
    best_score = df["RegimeScore"].max()  if "RegimeScore"  in df.columns else 0

    col1.metric("Total Runs",       len(df))
    col2.metric("Sum BT Profit",    f"${bt_profit:,.0f}")
    col3.metric("Sum FT Profit",    f"${ft_profit:,.0f}", delta=f"{ft_profit-bt_profit:+,.0f}")
    col4.metric("Avg RegimeScore",  f"{avg_score:,.0f}")
    col5.metric("Best RegimeScore", f"{best_score:,.0f}")

    st.markdown("---")
    with st.expander("🔍 Filters", expanded=False):
        fc1, fc2, fc3 = st.columns(3)
        min_bt    = fc1.number_input("Min BT Profit",   value=0.0)
        min_ft    = fc2.number_input("Min FT Profit",   value=0.0)
        min_score = fc3.number_input("Min RegimeScore", value=-99999.0)
        if "BT_Profit"   in df.columns: df = df[df["BT_Profit"]   >= min_bt]
        if "FT_Profit"   in df.columns: df = df[df["FT_Profit"]   >= min_ft]
        if "RegimeScore" in df.columns: df = df[df["RegimeScore"] >= min_score]

    st.subheader("Results Table")
    numeric_cols = df.select_dtypes(include=["float","int"]).columns.tolist()
    st.dataframe(
        df.style.format({c: "{:.2f}" for c in numeric_cols})
          .background_gradient(
              subset=[c for c in ["BT_Profit","FT_Profit","RegimeScore"] if c in df.columns],
              cmap="RdYlGn"),
        use_container_width=True, height=300,
    )

    st.markdown("---")
    tab1, tab2, tab3, tab4 = st.tabs(["Profit","Drawdown","Win Rate","RegimeScore"])

    with tab1:
        if "BT_Profit" in df.columns and "FT_Profit" in df.columns:
            melt = df.melt(id_vars=["SetFile"], value_vars=["BT_Profit","FT_Profit"],
                           var_name="Period", value_name="Profit")
            st.plotly_chart(px.bar(melt, x="SetFile", y="Profit", color="Period",
                                   barmode="group", title="BT vs FT Profit per Set File"),
                            use_container_width=True)
    with tab2:
        if "BT_Drawdown" in df.columns and "FT_Drawdown" in df.columns:
            fig = px.scatter(df, x="BT_Drawdown", y="FT_Drawdown", color="SetFile",
                             title="Drawdown Correlation (BT vs FT)",
                             hover_data=["Pass"] if "Pass" in df.columns else [])
            mx = max(df["BT_Drawdown"].max(), df["FT_Drawdown"].max())
            fig.add_shape(type="line", x0=0,y0=0,x1=mx,y1=mx,
                          line=dict(dash="dash",color="gray"))
            st.plotly_chart(fig, use_container_width=True)
    with tab3:
        wr_cols = [c for c in ["BT_WinRate","FT_WinRate"] if c in df.columns]
        if wr_cols:
            melt = df.melt(id_vars=["SetFile"], value_vars=wr_cols,
                           var_name="Period", value_name="WinRate")
            fig = px.bar(melt, x="SetFile", y="WinRate", color="Period",
                         barmode="group", title="Win Rate BT vs FT")
            fig.add_hline(y=65, line_dash="dash", line_color="orange",
                          annotation_text="65% target")
            fig.update_yaxes(range=[0,100])
            st.plotly_chart(fig, use_container_width=True)
    with tab4:
        if "RegimeScore" in df.columns:
            df_s = df.sort_values("RegimeScore", ascending=True)
            st.plotly_chart(
                px.bar(df_s, x="SetFile", y="RegimeScore",
                       color="RegimeScore", color_continuous_scale="RdYlGn",
                       title="RegimeScore Ranking"),
                use_container_width=True)


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 3 — LIVE MONITOR
# ═══════════════════════════════════════════════════════════════════════════
elif page == "📡 Live Monitor":
    st.title("📡 Live Monitor")
    st.caption("Live positions and equity from MT5 (requires fetch_live_history on VPS)")

    hist_raw = gh_raw(LIVE_HISTORY_PATH)
    pos_raw  = gh_raw(LIVE_POSITIONS_PATH)

    if hist_raw:
        df_hist = pd.read_csv(StringIO(hist_raw))
        st.subheader("Trade History")
        st.dataframe(df_hist, use_container_width=True)
        if "Profit" in df_hist.columns:
            df_hist["CumProfit"] = df_hist["Profit"].cumsum()
            st.plotly_chart(px.line(df_hist, y="CumProfit", title="Cumulative P&L"),
                            use_container_width=True)
    else:
        st.info("No live history. Push `data/LiveHistory.csv` to GitHub.")

    if pos_raw:
        st.subheader("Open Positions")
        st.dataframe(pd.read_csv(StringIO(pos_raw)), use_container_width=True)
    else:
        st.info("No open positions data.")


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 4 — RUNNER CONFIG
# ═══════════════════════════════════════════════════════════════════════════
elif page == "⚙️ Runner Config":
    st.title("⚙️ Remote Runner Config")
    st.caption("Updates `data/remote_config.json` in GitHub → VPS picks up on next poll")

    if no_token:
        st.error("GITHUB_TOKEN required to write config. Read-only mode.")

    cfg = load_remote_config()

    with st.form("config_form"):
        c1, c2 = st.columns(2)
        symbol  = c1.text_input("Symbol",  value=cfg.get("Symbol","EURUSD.s"))
        deposit = c2.number_input("Deposit", value=float(cfg.get("Deposit",50000)))

        c3, c4, c5 = st.columns(3)
        def parse_dt(key, fallback):
            try:
                return datetime.strptime(cfg.get(key, fallback), "%Y.%m.%d").date()
            except Exception:
                return datetime.strptime(fallback, "%Y.%m.%d").date()

        from_date  = c3.date_input("BT Start",   value=parse_dt("FromDate","2026.02.01"))
        split_date = c4.date_input("Split Date",  value=parse_dt("SplitDate","2026.04.16"))
        to_date    = c5.date_input("FT End",      value=parse_dt("ToDate","2026.05.24"))

        st.markdown("---")
        c6, c7 = st.columns(2)
        terminal_path = c6.text_input("MT5 Terminal Path",    value=cfg.get("MT5TerminalPath",""))
        data_folder   = c7.text_input("MT5 Data Folder Hash", value=cfg.get("MT5DataFolderName",""))
        clear_results = st.checkbox("Clear results.csv before next run", value=False)
        submitted = st.form_submit_button("💾 Save to GitHub", disabled=no_token)

    if submitted and not no_token:
        new_cfg = {
            "Symbol": symbol, "Deposit": str(int(deposit)),
            "FromDate":  from_date.strftime("%Y.%m.%d"),
            "SplitDate": split_date.strftime("%Y.%m.%d"),
            "ToDate":    to_date.strftime("%Y.%m.%d"),
            "ClearResults": clear_results,
            "MT5TerminalPath": terminal_path,
            "MT5DataFolderName": data_folder,
        }
        _, sha = gh_get_file(REMOTE_CONFIG_PATH)
        ok, resp = gh_put_file(
            REMOTE_CONFIG_PATH, json.dumps(new_cfg, indent=4), sha,
            f"dashboard: update remote_config {datetime.utcnow().strftime('%Y-%m-%d %H:%M')} UTC",
        )
        if ok:
            st.success("✅ Config saved to GitHub. VPS picks up on next poll.")
            st.cache_data.clear()
        else:
            st.error(f"GitHub API error: {resp.get('message', resp)}")

    st.markdown("---")
    st.subheader("Current Config (live from GitHub)")
    st.json(cfg)


# ═══════════════════════════════════════════════════════════════════════════
# PAGE 5 — QUEUE MANAGER
# ═══════════════════════════════════════════════════════════════════════════
elif page == "📥 Queue Manager":
    st.title("📥 Queue Manager")
    st.caption("GitHub queue status + recent results + leaderboard")

    st.subheader(f"GitHub Queue (`{QUEUE_GITHUB_PATH}/`)")
    if GITHUB_TOKEN:
        url = f"https://api.github.com/repos/{GITHUB_REPO}/contents/{QUEUE_GITHUB_PATH}"
        r   = requests.get(url, headers=gh_headers(), params={"ref": GITHUB_BRANCH})
        if r.status_code == 200 and isinstance(r.json(), list):
            queue_files = [f["name"] for f in r.json() if f["name"].endswith(".set")]
            if queue_files:
                st.write(f"**{len(queue_files)} file(s) waiting:**")
                for fn in queue_files:
                    st.code(fn)
            else:
                st.success("Queue empty — all files processed.")
        elif r.status_code == 404:
            st.info("Queue folder doesn't exist yet (created when you push files).")
        else:
            st.warning(f"Could not read queue: {r.status_code}")
    else:
        st.warning("Set GITHUB_TOKEN to view queue.")

    st.markdown("---")
    df = load_results()
    if not df.empty:
        st.subheader("Recent Processed Files")
        cols = [c for c in ["Timestamp","SetFile","BT_Profit","FT_Profit","RegimeScore"]
                if c in df.columns]
        st.dataframe(df.tail(20)[cols], use_container_width=True)

        st.markdown("---")
        st.subheader("RegimeScore Leaderboard")
        if "RegimeScore" in df.columns:
            top_cols = [c for c in ["SetFile","BT_Profit","FT_Profit",
                                    "BT_Drawdown","BT_WinRate","RegimeScore"]
                        if c in df.columns]
            top = df.nlargest(10, "RegimeScore")[top_cols]
            st.dataframe(
                top.style.format(precision=2)
                   .background_gradient(subset=["RegimeScore"], cmap="YlGn"),
                use_container_width=True)
    else:
        st.info("No results yet.")
