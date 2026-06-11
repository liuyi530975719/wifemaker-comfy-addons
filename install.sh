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
# Pull LoRAs from R2 (manual control - explicit glob required):
#   curl ... | bash -s -- --pull-loras 'chars/asuka*'
#   curl ... | bash -s -- --pull-loras 'universal/*'
#   curl ... | bash -s -- --pull-loras 'chars/*' 'styles/*'
#
# Required env when --pull-loras is set (paste in shell first):
#   export R2_ACCESS_KEY_ID=...
#   export R2_SECRET_ACCESS_KEY=...
#
# Or after `git clone`:
#   cd wifemaker-comfy-addons && bash install.sh
#
# What it does:
#   1. Auto-detects ComfyUI/ (honours $COMFY_DIR override)
#   2. Clones this repo to /tmp if running via curl|bash
#   3. Copies comfy_model_uploader/ and comfy_lora_cleaner/ -> custom_nodes/
#   4. Installs any requirements.txt
#   5. (Optional) Downloads LoRAs from R2 matching --pull-loras globs
#   6. Prints what to do next (restart ComfyUI)
# ===================================================================
set -euo pipefail

# Config (edit after fork)
REPO_URL="${REPO_URL:-https://github.com/liuyi530975719/wifemaker-comfy-addons}"
BRANCH="${BRANCH:-main}"
R2_ENDPOINT="${R2_ENDPOINT:-https://c8efd2af5d0b88632ab3d997fca8542b.r2.cloudflarestorage.com}"
R2_BUCKET="${R2_BUCKET:-bestyiever-loras}"

C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
log()  { echo -e "${C}[install]${N} $*"; }
ok()   { echo -e "${G}[install]${N} $*"; }
warn() { echo -e "${Y}[install]${N} $*"; }
err()  { echo -e "${R}[install]${N} $*" >&2; }

# Parse args -- collect --pull-loras GLOBs
PULL_LORAS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --pull-loras)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        PULL_LORAS+=("$1")
        shift
      done
      ;;
    --r2-endpoint) R2_ENDPOINT="$2"; shift 2 ;;
    --r2-bucket)   R2_BUCKET="$2";   shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--pull-loras GLOB...] [--r2-endpoint URL] [--r2-bucket NAME]"
      echo "Env: COMFY_DIR, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY"
      exit 0
      ;;
    *) warn "unknown arg: $1"; shift ;;
  esac
done

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

# 4. (Optional) Pull LoRAs from R2 if --pull-loras was given
if [ ${#PULL_LORAS[@]} -gt 0 ]; then
  log "LoRA pull requested: ${PULL_LORAS[*]}"

  if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
    err "R2 credentials missing. Set before pulling LoRAs:"
    err "  export R2_ACCESS_KEY_ID=..."
    err "  export R2_SECRET_ACCESS_KEY=..."
    err "Skipping LoRA download (addons still installed OK)."
  else
    LORA_DIR="$COMFY_DIR/models/loras"
    mkdir -p "$LORA_DIR"

    # Detect rclone first (preferred); fall back to aws-cli
    if command -v rclone >/dev/null 2>&1; then
      # Use rclone with inline R2 config (no need for ~/.config/rclone.conf)
      export RCLONE_CONFIG_R2_TYPE=s3
      export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
      export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
      export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
      export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
      export RCLONE_CONFIG_R2_REGION=auto

      for glob in "${PULL_LORAS[@]}"; do
        log "rclone copy r2:$R2_BUCKET/loras/$glob -> $LORA_DIR/"
        rclone copy "r2:$R2_BUCKET/loras/" "$LORA_DIR/" \
          --include "$glob" \
          --progress \
          --transfers=8 \
          --checkers=16 \
          --multi-thread-streams=4 \
          || warn "some files failed for glob '$glob'"
      done
      ok "rclone pull done"
    elif command -v aws >/dev/null 2>&1; then
      export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
      export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
      for glob in "${PULL_LORAS[@]}"; do
        # aws s3 sync doesn't support globs natively; use --include + --exclude '*'
        log "aws s3 sync r2:$R2_BUCKET/loras/ (filter: $glob)"
        aws s3 sync "s3://$R2_BUCKET/loras/" "$LORA_DIR/" \
          --endpoint-url "$R2_ENDPOINT" \
          --exclude '*' --include "$glob" \
          || warn "some files failed for glob '$glob'"
      done
      ok "aws s3 sync done"
    else
      err "Neither rclone nor aws-cli found. Install one:"
      err "  curl https://rclone.org/install.sh | sudo bash"
      err "  OR: pip install awscli"
    fi

    log "LoRA dir size now: $(du -sh "$LORA_DIR" 2>/dev/null | cut -f1)"
  fi
fi

# 5. Done
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
