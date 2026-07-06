#!/usr/bin/env bash
# memwatch installer.
# Wires the Hammerspoon menu-bar memory-pressure gauge into ~/.hammerspoon/init.lua,
# following the same load pattern this machine already uses for clipsweep.
# Idempotent. Backs up init.lua before editing. Reloads Hammerspoon if the hs CLI exists.
#
# Plain install: the deterministic sentinel only; no inference runtime, no
# model download, no config written.
# --with-lfm: additionally installs the llama.cpp runtime (via Homebrew),
# fetches the default LFM2.5 model plus its license (hash-pinned registry),
# and writes the local enable config. The model weights are licensed
# separately from this repository's MIT code; see NOTICE-LFM.
set -euo pipefail

WITH_LFM=0
for arg in "$@"; do
  case "$arg" in
    --with-lfm) WITH_LFM=1 ;;
    *) echo "install.sh: unknown option '$arg' (supported: --with-lfm)" >&2; exit 2 ;;
  esac
done

# The bake-off-promoted default; see docs/bakeoff-methodology.md.
DEFAULT_MODEL_LABEL="230M-Q4_K_M"
DEFAULT_MODEL_FILE="LFM2.5-230M-Q4_K_M.gguf"

HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

mkdir -p "$HS_DIR"
touch "$INIT"

if grep -q "BEGIN memwatch" "$INIT"; then
  echo "memwatch already wired into $INIT (no change)"
else
  cp "$INIT" "$INIT.bak.$(date +%Y%m%d-%H%M%S)"
  cat >> "$INIT" <<'LUA'

-- BEGIN memwatch
-- memwatch v0.1.0: menu-bar memory-pressure gauge (~/projects/memwatch).
-- Calibrated to the 2026-05-29 freeze. Loaded the same way as clipsweep.
do
  local home = os.getenv("HOME")
  local memwatch_lua_dir = home .. "/projects/memwatch/lua/?.lua"
  if not package.path:find(memwatch_lua_dir, 1, true) then
    package.path = package.path .. ";" .. memwatch_lua_dir
  end
  package.loaded.memwatch = nil
  package.loaded.memwatch_core = nil
  local ok, err = pcall(require, "memwatch")
  if not ok then
    hs.alert.show("memwatch: failed to load (" .. tostring(err) .. ")")
  end
end
-- END memwatch
LUA
  echo "wired memwatch into $INIT (timestamped backup created)"
fi

if [ "$WITH_LFM" = "1" ]; then
  echo ""
  echo "== LFM adjudication (opt-in) =="
  echo "The optional on-device model is licensed under the LFM Open License"
  echo "v1.0 (Apache-2.0-based with a revenue threshold; the full text is"
  echo "fetched to licenses/ and hash-verified). The weights are NOT part of"
  echo "this MIT repository. See NOTICE-LFM."
  if ! command -v brew >/dev/null 2>&1; then
    echo "install.sh: Homebrew not found; skipping the LFM setup." >&2
    echo "  Manual steps: install llama.cpp (brew install llama.cpp or from" >&2
    echo "  source), run scripts/get-model.sh $DEFAULT_MODEL_LABEL, and write" >&2
    echo "  memwatch-local.json with {\"lfm\":{\"enabled\":true,\"model\":\"$DEFAULT_MODEL_FILE\"}}." >&2
    echo "  The plain install above is complete and fully functional." >&2
  else
    if ! command -v llama-server >/dev/null 2>&1 \
       && [ ! -x "$(brew --prefix llama.cpp 2>/dev/null)/bin/llama-server" ]; then
      echo "installing llama.cpp via Homebrew..."
      brew install llama.cpp
    fi
    "$REPO_DIR/scripts/get-model.sh" "$DEFAULT_MODEL_LABEL"
    CONF="$REPO_DIR/memwatch-local.json"
    if [ -f "$CONF" ]; then
      echo "install.sh: $CONF exists; leaving it untouched (enable from the menu)."
    else
      printf '{"lfm":{"enabled":true,"model":"%s"}}\n' "$DEFAULT_MODEL_FILE" > "$CONF"
      echo "wrote $CONF (LFM adjudication enabled; toggle from the menu)"
    fi
  fi
fi

if [ -x /opt/homebrew/bin/hs ]; then
  /opt/homebrew/bin/hs -c "hs.reload()" >/dev/null 2>&1 || true
  echo "reloaded Hammerspoon"
else
  echo "reload Hammerspoon from the menu bar (Reload Config) to activate"
fi
