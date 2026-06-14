# ArchangelX — Project Setup Instructions

## Step 1: Create the Project Folder

On your local machine:
```bash
mkdir ArchangelX
cd ArchangelX
```

## Step 2: Initialize Git
```bash
git init
```

## Step 3: Create Folder Structure
```bash
mkdir EA
mkdir docs
mkdir StrategyRegistry
mkdir Antigravity
```

## Step 4: Copy the Antigravity Folder

Copy everything from `C:\Users\manmi\Antigravity\` into `ArchangelX\Antigravity\`:
```
ArchangelX\Antigravity\
├── app.py
├── remote_runner.py
├── single_test_runner.py
├── optimization_dashboard.py
├── setfile_exporter.py
├── compare_sets.py
├── system_user_manual.md
├── project_file_guide.md
├── ArcAngelAutomation\   (existing setfiles, XMLs, etc.)
└── XMLs\
```

## Step 5: Copy the docs Folder

Copy all 5 `.md` files from this docs output into `ArchangelX\docs\`.

## Step 6: Create .gitignore
```
# Compiled EA binaries
*.ex5

# Test results (data, not code)
results.csv

# Python cache
__pycache__/
*.pyc
*.pyo

# Streamlit cache
.streamlit/

# VS Code
.vscode/

# Excel temp files
~$*.xlsx

# Large setfile archives (too many files)
ArcAngelAutomation/nas100long_09-12_optimization_all/
ArcAngelAutomation/Generated_Sets/
```

## Step 7: Create requirements.txt
```
streamlit>=1.28
pandas>=2.0
plotly>=5.0
openpyxl>=3.1
```

## Step 8: Initial Commit
```bash
git add .
git commit -m "[Init] Project structure, docs, and Antigravity infrastructure"
```

## Step 9: Start Building the EA

Tell your coding agent:
> "Read docs/00_PROJECT_OVERVIEW.md, docs/01_EA_SPECIFICATION.md, and docs/04_AGENT_TASKS.md. 
>  Then execute TASK 1: Build EA/ArchangelX.mq5 exactly as specified."

## Step 10: After EA Compiles

1. Copy `EA/ArchangelX.mq5` to MT5 MetaEditor on the VPS
2. Compile (F7 in MetaEditor)
3. Update `EA_NAME` in `Antigravity/remote_runner.py`
4. Run a single backtest on XAUUSD M1 to verify
