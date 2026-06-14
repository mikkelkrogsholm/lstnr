#!/usr/bin/env bash
#
# setup-hviske.sh — out-of-app installer for Vara's optional local Danish STT
# engine (Hviske v5.3). Run this ONCE in Terminal; Vara then detects the result
# and lets you pick "Local Hviske" in Settings > Advanced.
#
# WHY THIS LIVES OUTSIDE THE APP:
#   The shipped, notarized Vara app must NOT download and execute a Python
#   installer from inside itself — that was the one thing blocking notarization.
#   So the install moves here, and the app only DETECTS what you set up.
#
# WHAT IT DOES (idempotent — safe to re-run):
#   1. Finds a bootstrap python3 (same search order the app used to use).
#   2. Creates a venv at:
#        ~/Library/Application Support/vara/hviske-venv
#   3. Installs torch / transformers==5.4.0 / soundfile / huggingface_hub.
#   4. Downloads the model syvai/hviske-v5.3 @ a pinned revision into:
#        ~/Library/Application Support/vara/models/huggingface
#   5. Verifies both paths exist, then prints the next step.
#
# These are the EXACT paths LocalHviskeBackend.runtimeStatus() checks, so after
# this completes Vara shows Hviske as "ready" with no further configuration.
#
# ALTERNATIVE (advanced): if you already have a working python + model elsewhere,
# you can skip this script and instead point Vara at them with environment
# variables before launching it:
#     export VARA_HVISKE_PYTHON=/path/to/python
#     export VARA_HVISKE_HF_HOME=/path/to/huggingface
#   NOTE: with the env-var route, Vara transcribes correctly but Settings may
#   still show "not installed" — runtimeStatus() does not consult those vars.
#   That is a known cosmetic gap; transcription still works.

set -euo pipefail

# ---- Constants (mirror Sources/VaraCore/Backends/LocalHviskeBackend.swift) ----
MODEL_ID="syvai/hviske-v5.3"
MODEL_REVISION="574bc158f3e8ce91af7995be2928f529a05c24b6"
TRANSFORMERS_PIN="transformers==5.4.0"

APP_SUPPORT="$HOME/Library/Application Support/vara"
VENV_DIR="$APP_SUPPORT/hviske-venv"
HF_HOME="$APP_SUPPORT/models/huggingface"
VENV_PYTHON="$VENV_DIR/bin/python"
SNAPSHOT_DIR="$HF_HOME/hub/models--syvai--hviske-v5.3/snapshots/$MODEL_REVISION"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
ok()   { printf '\033[32m  ✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$1"; }
err()  { printf '\033[31m  ✗ %s\033[0m\n' "$1" >&2; }

bold "Vara · Local Hviske (Danish on-device STT) setup"
echo
info "Venv:     $VENV_DIR"
info "HF_HOME:  $HF_HOME"
info "Model:    $MODEL_ID @ $MODEL_REVISION"
echo

# ---- 1. Find a bootstrap python3 ----------------------------------------------
# Search order matches the (now removed) in-app resolveBootstrapPythonURL:
#   $VARA_HVISKE_BOOTSTRAP_PYTHON, /opt/miniconda3, /usr/local, /opt/homebrew,
#   /usr/bin, then whatever python3 is on PATH.
find_bootstrap_python() {
    local candidates=(
        "${VARA_HVISKE_BOOTSTRAP_PYTHON:-}"
        "/opt/miniconda3/bin/python3"
        "/usr/local/bin/python3"
        "/opt/homebrew/bin/python3"
        "/usr/bin/python3"
    )
    local candidate
    for candidate in "${candidates[@]}"; do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi
    return 1
}

if ! BOOTSTRAP_PYTHON="$(find_bootstrap_python)"; then
    err "No python3 found. Install Python 3 (e.g. 'brew install python') and re-run."
    err "Or set VARA_HVISKE_BOOTSTRAP_PYTHON to a python3 you trust, then re-run."
    exit 1
fi
ok "Bootstrap python: $BOOTSTRAP_PYTHON"
info "$("$BOOTSTRAP_PYTHON" --version 2>&1)"
echo

# ---- 2. Create the venv -------------------------------------------------------
mkdir -p "$APP_SUPPORT"
if [ -x "$VENV_PYTHON" ]; then
    ok "Venv already exists — reusing it."
else
    bold "Creating virtual environment..."
    "$BOOTSTRAP_PYTHON" -m venv "$VENV_DIR"
    ok "Venv created."
fi
echo

# ---- 3. Install Python packages ----------------------------------------------
bold "Installing Python packages (this can take a few minutes)..."
"$VENV_PYTHON" -m pip install --upgrade pip >/dev/null
# transformers is pinned to match the runner script the app feeds to python.
"$VENV_PYTHON" -m pip install \
    "$TRANSFORMERS_PIN" \
    torch \
    soundfile \
    "huggingface_hub[cli]"
ok "Packages installed (transformers pinned to ${TRANSFORMERS_PIN#transformers==})."
echo

# ---- 4. Download the model snapshot ------------------------------------------
mkdir -p "$HF_HOME"
if [ -d "$SNAPSHOT_DIR" ]; then
    ok "Model snapshot already present — skipping download."
else
    bold "Downloading model $MODEL_ID @ $MODEL_REVISION..."
    HF_HOME="$HF_HOME" "$VENV_PYTHON" - "$MODEL_ID" "$MODEL_REVISION" <<'PY'
import sys
from huggingface_hub import snapshot_download

model_id, revision = sys.argv[1], sys.argv[2]
path = snapshot_download(repo_id=model_id, revision=revision)
print(f"Downloaded to: {path}")
PY
    ok "Model downloaded."
fi
echo

# ---- 5. Verify the exact paths the app detects -------------------------------
bold "Verifying..."
verify_ok=1
if [ -x "$VENV_PYTHON" ]; then
    ok "Python runtime: $VENV_PYTHON"
else
    err "Missing python runtime at $VENV_PYTHON"
    verify_ok=0
fi
if [ -d "$SNAPSHOT_DIR" ]; then
    ok "Model snapshot: $SNAPSHOT_DIR"
else
    err "Missing model snapshot at $SNAPSHOT_DIR"
    verify_ok=0
fi
echo

if [ "$verify_ok" -ne 1 ]; then
    err "Setup did not complete cleanly. Re-run this script; it is safe to repeat."
    exit 1
fi

bold "Done. Local Hviske is ready."
info "Next: open Vara → Settings → Advanced → re-check, then pick \"Local Hviske\""
info "as your engine. Danish speech is now transcribed entirely on this Mac."
