#!/usr/bin/env bash
# memwatch installer.
# Wires the Hammerspoon menu-bar memory-pressure gauge into ~/.hammerspoon/init.lua,
# following the same load pattern this machine already uses for clipsweep.
# Idempotent. Backs up init.lua before editing. Reloads Hammerspoon if the hs CLI exists.
set -euo pipefail

HS_DIR="$HOME/.hammerspoon"
INIT="$HS_DIR/init.lua"

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

if [ -x /opt/homebrew/bin/hs ]; then
  /opt/homebrew/bin/hs -c "hs.reload()" >/dev/null 2>&1 || true
  echo "reloaded Hammerspoon"
else
  echo "reload Hammerspoon from the menu bar (Reload Config) to activate"
fi
