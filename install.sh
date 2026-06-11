#!/usr/bin/env bash
# ===================================================================
# wifemaker-comfy-addons -- one-shot installer
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/install.sh | bash
#
# With explicit ComfyUI directory:
#   COMFY_DIR=/workspace/ComfyUI curl ... | bash
#
# Or after `git clone`:
#   cd wifemaker-comfy-addons && bash install.sh
#
# What it does:
#   1. Auto-detects ComfyUI/ (honours $COMFY_DIR override)
#   2. Clones this repo to /tmp if running via curl|bash
#   3. Copies comfy_model_uploader/ and comfy_lora_cleaner/ -> custom_nodes/
#   4. Installs any requirements.txt
#   5. Prints what to do next (restart ComfyUI)
# ===================================================================
set -euo pipefail

# Config (edit this after fork)
REPO_URL="${REPO_URL:-https://github.com/liuyi530975719/wifemaker-comfy-addons}"
BRANCH="${BRANCH:-main}"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${C}[install]${N} $*"; }
ok()   { echo -e "${G}[install]${N} $*"; }
warn() { echo -e "${Y}[install]${N} $*"; }
err()  { echo -e "${R}[install]${N} $*" >&2; }

# 1. Locate the source dir
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]:-$0}" 2>/dev/null || echo . )" && pwd )"
if [ -d "$SCRIPT_DIR/comfy_model_uploader" ] && [ -d "$SCRIPT_DIR/comfy_lora_cleaner" ]; then
  SRC_DIR="$SCRIPT_DIR"
  log "running from local checkout: $SRC_DIR"
else
  SRC_DIR=$(mktemp -d)
  log "cloning $REPO_URL into $SRC_DIR"
  git clone --depth 1 --branch "$BRANCH" "$REPO_URL" "$SRC_DIR"
fi

# 2. Find ComfyUI dir
detect_comfy_dir() {
  if [ -n "${COMFY_DIR:-}" ] && [ -d "$COMFY_DIR" ]; then echo "$COMFY_DIR"; return; fi
  for candidate in \
    "/workspace/ComfyUI" \
    "$HOME/ComfyUI" \
    "/opt/ComfyUI" \
    "$HOME/stable-diffusion-webui/extensions/ComfyUI" \
    "/srv/ComfyUI" \
    "$HOME/comfy/ComfyUI"
  do
    if [ -d "$candidate" ] && [ -d "$candidate/custom_nodes" ]; then
      echo "$candidate"; return
    fi
  done
}
COMFY_DIR=$(detect_comfy_dir)
if [ -z "$COMFY_DIR" ]; then
  err "ComfyUI directory not found. Set COMFY_DIR explicitly:"
  err "  COMFY_DIR=/path/to/ComfyUI bash install.sh"
  exit 1
fi
ok "ComfyUI: $COMFY_DIR"
CUSTOM_NODES="$COMFY_DIR/custom_nodes"
mkdir -p "$CUSTOM_NODES"

# 3. Drop in the two addons
for addon in comfy_model_uploader comfy_lora_cleaner; do
  if [ ! -d "$SRC_DIR/$addon" ]; then
    err "missing source: $SRC_DIR/$addon"; exit 1
  fi
  target="$CUSTOM_NODES/$addon"
  if [ -d "$target" ]; then
    warn "$addon already present -- overwriting"
    rm -rf "$target"
  fi
  cp -r "$SRC_DIR/$addon" "$CUSTOM_NODES/"
  ok "installed $addon -> $target"

  if [ -f "$target/requirements.txt" ]; then
    log "installing $addon requirements..."
    python3 -m pip install -q -r "$target/requirements.txt" \
      || warn "some packages failed -- check log"
  fi
done

# 4. Done
echo
ok "All custom nodes installed."
echo
log "Next: restart ComfyUI so it picks up the new nodes."
log "  - systemd:        sudo systemctl restart comfyui"
log "  - dual-vast.ai:   bash /workspace/start_dual_comfy.sh"
log "  - bare process:   kill the python running main.py and re-launch"
echo
log "Verify after restart with:"
log "  curl -s http://localhost:8188/upload/model/info"
log "  curl -s http://localhost:8188/lora_cleaner/info"
