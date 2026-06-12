#!/usr/bin/env bash
# ===================================================================
# deploy.sh -- one-shot new ComfyUI server bootstrap
#
# Usage on a fresh Linux box with GPU(s):
#
#   curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/deploy.sh \
#     | bash -s -- \
#       --tunnel-name mynew5090 \
#       --subdomain mynew5090a.bestyiever.vip \
#       --subdomain-b mynew5090b.bestyiever.vip \
#       --pull-loras '*' \
#       --pull-checkpoint 'unholyDesireMixSinister_v80.safetensors'
#
# All args optional -- when omitted, the script just installs ComfyUI
# + addons. Pass --skip-tunnel if you'll wire networking manually.
#
# Required env vars (only if --pull-loras / --pull-checkpoint given):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#
# Phases (each phase is idempotent -- safe to re-run):
#   1. Verify GPU + disk space + Python
#   2. Clone ComfyUI to /workspace/ComfyUI
#   3. Install Python deps + public custom nodes
#   4. Install private addons (uploader + lora_cleaner)
#   5. Detect single vs dual GPU + write start_dual_comfy.sh
#   6. Start ComfyUI processes
#   7. (Optional) Pull LoRA / checkpoint from R2
#   8. (Optional) Install + configure cloudflared tunnel
#   9. Print fleet registration cheatsheet
# ===================================================================
set -euo pipefail

# ----- Config -----
REPO_URL="${REPO_URL:-https://github.com/liuyi530975719/wifemaker-comfy-addons}"
BRANCH="${BRANCH:-main}"
COMFY_DIR="${COMFY_DIR:-/workspace/ComfyUI}"
R2_ENDPOINT="${R2_ENDPOINT:-https://c8efd2af5d0b88632ab3d997fca8542b.r2.cloudflarestorage.com}"
R2_BUCKET="${R2_BUCKET:-bestyiever-loras}"
LOGS_DIR="${LOGS_DIR:-/workspace/logs}"
PORT_A=8190        # GPU 0
PORT_B=8189        # GPU 1
# vast.ai's caddy occupies 8188/8288/8384/1111 -- avoid these.

# ----- Args -----
TUNNEL_NAME=""
SUBDOMAINS=()           # N entries -- one per GPU
SUBDOMAIN_PREFIX=""     # if set, auto-gen N subdomains: <prefix>a.zone, <prefix>b.zone, ...
SUBDOMAIN_ZONE="bestyiever.vip"
PORT_START=8190
PULL_LORAS=()
PULL_CHECKPOINTS=()
SKIP_TUNNEL=false
SKIP_PULL=false
DRY_RUN=false
FORCE_GPUS=""           # override GPU count detection

while [ $# -gt 0 ]; do
  case "$1" in
    --tunnel-name)         TUNNEL_NAME="$2"; shift 2 ;;
    --subdomain|--subdomain-b)
      # back-compat: --subdomain x  --subdomain-b y  → append to SUBDOMAINS
      SUBDOMAINS+=("$2"); shift 2
      ;;
    --subdomains)
      # accept space-separated list after the flag, or repeated --subdomains entries
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        SUBDOMAINS+=("$1"); shift
      done
      ;;
    --subdomain-prefix)    SUBDOMAIN_PREFIX="$2"; shift 2 ;;
    --subdomain-zone)      SUBDOMAIN_ZONE="$2";   shift 2 ;;
    --port-start)          PORT_START="$2";       shift 2 ;;
    --port-a)              PORT_START="$2";       shift 2 ;;   # back-compat alias
    --port-b)              shift 2 ;;                          # ignored (auto-sequential now)
    --gpus)                FORCE_GPUS="$2";       shift 2 ;;
    --pull-loras)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        PULL_LORAS+=("$1"); shift
      done
      ;;
    --pull-checkpoint)
      shift
      while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
        PULL_CHECKPOINTS+=("$1"); shift
      done
      ;;
    --skip-tunnel) SKIP_TUNNEL=true; shift ;;
    --skip-pull)   SKIP_PULL=true;   shift ;;
    --dry-run)     DRY_RUN=true;     shift ;;
    --comfy-dir)   COMFY_DIR="$2";   shift 2 ;;
    --help|-h)
      sed -n '2,/^# ====/p' "$0" | sed 's/^# *//'
      exit 0
      ;;
    *) echo "warn: unknown arg: $1" >&2; shift ;;
  esac
done

# ----- Logging -----
C='\033[0;36m'; G='\033[0;32m'; Y='\033[0;33m'; R='\033[0;31m'; N='\033[0m'
phase() { echo -e "\n${C}=== Phase $1: $2 ===${N}"; }
ok()    { echo -e "${G}  [ok]${N} $*"; }
warn()  { echo -e "${Y}  [warn]${N} $*"; }
err()   { echo -e "${R}  [err]${N} $*" >&2; }
dryecho(){ $DRY_RUN && echo -e "${Y}  [dry-run]${N} would run: $*" || eval "$*"; }

# ============================================================ #
phase 1 "Verify GPU + disk + Python"
# ============================================================ #
if ! command -v nvidia-smi >/dev/null 2>&1; then
  err "nvidia-smi not found -- this script needs an NVIDIA GPU"
  exit 1
fi
GPU_COUNT=$(nvidia-smi --query-gpu=index --format=csv,noheader | wc -l)
ok "GPUs detected: $GPU_COUNT"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader | sed 's/^/    /'

# Disk space (need at least 60GB free for ComfyUI + base models)
DISK_AVAIL_GB=$(df -BG "$(dirname "$COMFY_DIR")" 2>/dev/null | tail -1 | awk '{print $4}' | tr -d 'G')
if [ -z "$DISK_AVAIL_GB" ] || [ "$DISK_AVAIL_GB" -lt 60 ]; then
  warn "free disk under 60GB ($DISK_AVAIL_GB GB) -- may run out during LoRA pull"
else
  ok "free disk: ${DISK_AVAIL_GB}GB"
fi

PYV=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
ok "Python: $PYV"
python3 -c "import torch; print(f'  torch: {torch.__version__}, cuda: {torch.cuda.is_available()}, devices: {torch.cuda.device_count()}, cc: {torch.cuda.get_device_capability(0) if torch.cuda.is_available() else None}')"

# Apply --gpus override or auto-detected count
if [ -n "$FORCE_GPUS" ]; then
  GPU_COUNT=$FORCE_GPUS
  ok "GPU count overridden to: $GPU_COUNT"
fi

# Build PORTS array: sequential from PORT_START
PORTS=()
for ((i=0; i<GPU_COUNT; i++)); do
  PORTS+=( $((PORT_START + i)) )
done
ok "ports planned: ${PORTS[*]}"

# Build SUBDOMAINS array if --subdomain-prefix was given
if [ ${#SUBDOMAINS[@]} -eq 0 ] && [ -n "$SUBDOMAIN_PREFIX" ]; then
  _letters=(a b c d e f g h i j k l m n o p q r s t u v w x y z)
  for ((i=0; i<GPU_COUNT; i++)); do
    SUBDOMAINS+=( "${SUBDOMAIN_PREFIX}${_letters[$i]}.${SUBDOMAIN_ZONE}" )
  done
  ok "subdomains auto-generated: ${SUBDOMAINS[*]}"
fi

# ============================================================ #
phase 2 "Clone ComfyUI"
# ============================================================ #
if [ -d "$COMFY_DIR/.git" ]; then
  ok "ComfyUI already cloned at $COMFY_DIR"
else
  dryecho "git clone https://github.com/comfyanonymous/ComfyUI.git '$COMFY_DIR'"
fi

# ============================================================ #
phase 3 "Install Python deps + public custom nodes"
# ============================================================ #
cd "$COMFY_DIR"

# Pin existing torch versions so requirements.txt doesn't downgrade them
python3 -c "import torch, torchvision, torchaudio; print(f'torch=={torch.__version__}\ntorchvision=={torchvision.__version__}\ntorchaudio=={torchaudio.__version__}')" > /tmp/torch_pin.txt
ok "pinned: $(cat /tmp/torch_pin.txt | xargs)"

dryecho "pip install -q -r requirements.txt -c /tmp/torch_pin.txt"

PUBLIC_NODES=(
  "https://github.com/ltdrdata/ComfyUI-Manager"
  "https://github.com/ltdrdata/ComfyUI-Impact-Pack"
  "https://github.com/ltdrdata/ComfyUI-Impact-Subpack"
  "https://github.com/ssitu/ComfyUI_UltimateSDUpscale"
  "https://github.com/Fannovel16/comfyui_controlnet_aux"
  "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite"
  "https://github.com/cubiq/ComfyUI_essentials"
)
mkdir -p "$COMFY_DIR/custom_nodes"
cd "$COMFY_DIR/custom_nodes"
for url in "${PUBLIC_NODES[@]}"; do
  name=$(basename "$url" .git)
  if [ -d "$name/.git" ]; then
    ok "$name already cloned"
  else
    dryecho "git clone --depth 1 '$url' '$name'"
  fi
  [ -f "$name/requirements.txt" ] && dryecho "pip install -q -r '$name/requirements.txt'" || true
done

# ============================================================ #
phase 4 "Install private addons (uploader + lora_cleaner)"
# ============================================================ #
dryecho "curl -fsSL '$REPO_URL/raw/$BRANCH/install.sh' | COMFY_DIR='$COMFY_DIR' bash"

# ============================================================ #
phase 5 "Write start script (N GPUs)"
# ============================================================ #
mkdir -p "$LOGS_DIR"

LAUNCHER=/workspace/start_all_comfy.sh
ok "writing $LAUNCHER for $GPU_COUNT GPU(s)"

# Build the launcher dynamically using printf (no quote-collision)
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -e'
  printf 'cd %s\n' "$COMFY_DIR"
  printf 'mkdir -p %s\n' "$LOGS_DIR"
  printf '%s\n' 'pkill -9 -f "main.py --listen" 2>/dev/null || true'
  printf '%s\n' 'sleep 2'
  printf '\n'
  for ((i=0; i<GPU_COUNT; i++)); do
    P=${PORTS[$i]}
    UDIR="$COMFY_DIR/user-gpu$i"
    LOG="$LOGS_DIR/comfy-gpu$i.log"
    printf 'mkdir -p %s\n' "$UDIR"
    printf 'CUDA_VISIBLE_DEVICES=%d nohup python main.py --listen 0.0.0.0 --highvram --port %d \\\n' "$i" "$P"
    printf '    --user-directory %s > %s 2>&1 &\n' "$UDIR" "$LOG"
    printf 'echo "GPU %d (port %d) started: PID $!"\n' "$i" "$P"
    printf '\n'
  done
  printf '%s\n' 'echo "Waiting 30s for ComfyUI to come up..."'
  printf '%s\n' 'sleep 30'
  printf '\n'
  printf '%s\n' 'echo "=== Port check ==="'
  for ((i=0; i<GPU_COUNT; i++)); do
    P=${PORTS[$i]}
    printf 'curl -sf -o /dev/null -w "  port %d HTTP %%{http_code}\\n" http://localhost:%d/system_stats || echo "  port %d NO RESP"\n' "$P" "$P" "$P"
  done
  printf '\n'
  printf '%s\n' 'echo "=== GPU memory ==="'
  printf '%s\n' 'nvidia-smi --query-gpu=index,memory.used,utilization.gpu --format=csv,noheader'
} > "$LAUNCHER"
chmod +x "$LAUNCHER"
LAUNCHER_LINES=$(wc -l < "$LAUNCHER")
ok "launcher written ($LAUNCHER_LINES lines)"

# ============================================================ #
phase 6 "Start ComfyUI"
# ============================================================ #
dryecho "bash /workspace/start_all_comfy.sh"

# ============================================================ #
phase 7 "Pull LoRA / checkpoint from R2"
# ============================================================ #
if [ "$SKIP_PULL" = true ] || ([ ${#PULL_LORAS[@]} -eq 0 ] && [ ${#PULL_CHECKPOINTS[@]} -eq 0 ]); then
  warn "skipping model pull (no --pull-loras / --pull-checkpoint, or --skip-pull set)"
else
  if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
    err "R2 credentials missing. Set R2_ACCESS_KEY_ID + R2_SECRET_ACCESS_KEY env vars."
    err "Continuing without pull -- you can run install.sh --pull-loras later."
  else
    if ! command -v rclone >/dev/null 2>&1; then
      dryecho "curl https://rclone.org/install.sh | sudo bash"
    fi
    export RCLONE_CONFIG_R2_TYPE=s3
    export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
    export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
    export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
    export RCLONE_CONFIG_R2_ENDPOINT="$R2_ENDPOINT"
    export RCLONE_CONFIG_R2_REGION=auto

    if [ ${#PULL_LORAS[@]} -gt 0 ]; then
      mkdir -p "$COMFY_DIR/models/loras"
      for g in "${PULL_LORAS[@]}"; do
        ok "pulling LoRAs matching: $g"
        dryecho "rclone copy 'r2:$R2_BUCKET/loras/' '$COMFY_DIR/models/loras/' --include '$g' --progress --transfers=8 --checkers=16 --multi-thread-streams=4"
      done
    fi
    if [ ${#PULL_CHECKPOINTS[@]} -gt 0 ]; then
      mkdir -p "$COMFY_DIR/models/checkpoints"
      for g in "${PULL_CHECKPOINTS[@]}"; do
        ok "pulling checkpoints matching: $g"
        dryecho "rclone copy 'r2:$R2_BUCKET/checkpoints/' '$COMFY_DIR/models/checkpoints/' --include '$g' --progress --transfers=4 --multi-thread-streams=8"
      done
    fi
    ok "models dir size now: $(du -sh $COMFY_DIR/models 2>/dev/null | cut -f1)"
  fi
fi

# ============================================================ #
phase 8 "CloudFlare Tunnel"
# ============================================================ #
# Three modes, auto-detected by which env var / arg is set:
#
#  A) TOKEN MODE  (recommended for automation)
#     - Pre-create the tunnel in CF dashboard or via API on ANY machine.
#     - Copy the tunnel token (long opaque string).
#     - Run with:  CF_TUNNEL_TOKEN=eyJ... deploy.sh ...
#     - Script just runs `cloudflared tunnel run --token <TOKEN>`. No
#       cert.pem needed, no interactive browser login. Fully scriptable.
#     - DNS routing must be configured in the dashboard separately
#       (Tunnel -> Public Hostname tab), OR pre-created via CF API.
#
#  B) CERT MODE  (one-time interactive setup on a "home base" machine)
#     - Run `cloudflared tunnel login` ONCE on any machine, get cert.pem.
#     - Stash that cert somewhere accessible (e.g. R2 bucket, scp).
#     - On new servers, pre-place it at /root/.cloudflared/cert.pem before
#       running deploy.sh. Script detects + uses it to create new tunnel
#       and DNS routes.
#
#  C) SKIP MODE
#     - --skip-tunnel, or no tunnel args provided.
#     - Phase prints instructions for manual setup later.
# ----------------------------------------------------------------

CLOUDFLARED="/usr/local/bin/cloudflared-mine"
install_cloudflared() {
  if [ -x "$CLOUDFLARED" ]; then return; fi
  ok "installing cloudflared"
  dryecho "wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 -O '$CLOUDFLARED'"
  dryecho "chmod +x '$CLOUDFLARED'"
}

write_config_file() {
  # Writes ~/.cloudflared/config.yml with $tid + N ingress rules (one per subdomain)
  local tid="$1"
  CONFIG_FILE=~/.cloudflared/config.yml
  mkdir -p ~/.cloudflared
  {
    echo "tunnel: $tid"
    echo "credentials-file: /root/.cloudflared/${tid}.json"
    echo "ingress:"
    for ((i=0; i<${#SUBDOMAINS[@]} && i<${#PORTS[@]}; i++)); do
      echo "  - hostname: ${SUBDOMAINS[$i]}"
      echo "    service: http://localhost:${PORTS[$i]}"
    done
    echo "  - service: http_status:404"
  } > "$CONFIG_FILE"
  ok "wrote tunnel config: $CONFIG_FILE (${#SUBDOMAINS[@]} hostnames)"
}

if [ "$SKIP_TUNNEL" = true ] || ([ ${#SUBDOMAINS[@]} -eq 0 ] && [ -z "${CF_TUNNEL_TOKEN:-}" ]); then
  # ---- Mode C: SKIP ----
  warn "skipping tunnel phase (no --subdomain, no CF_TUNNEL_TOKEN, or --skip-tunnel set)"
  warn "to wire networking later, either:"
  warn "  A) set env CF_TUNNEL_TOKEN + re-run this phase, OR"
  warn "  B) place ~/.cloudflared/cert.pem manually + re-run, OR"
  warn "  C) follow NEW_SERVER_RUNBOOK.md Phase 5"
elif [ -n "${CF_TUNNEL_TOKEN:-}" ]; then
  # ---- Mode A: TOKEN ----
  ok "using TOKEN mode (CF_TUNNEL_TOKEN is set, ${#CF_TUNNEL_TOKEN} chars)"
  install_cloudflared
  ok "starting tunnel via token (background, logs to $LOGS_DIR/tunnel.log)"
  dryecho "nohup $CLOUDFLARED tunnel run --token '$CF_TUNNEL_TOKEN' > '$LOGS_DIR/tunnel.log' 2>&1 &"
  sleep 3
  if $DRY_RUN; then
    warn "[dry-run] would tail tunnel.log here for sanity"
  else
    tail -5 "$LOGS_DIR/tunnel.log" 2>/dev/null || true
  fi
  warn "TOKEN MODE limitation: DNS routes (hostname -> tunnel) must be"
  warn "  configured separately in CF dashboard -> Zero Trust -> Networks ->"
  warn "  Tunnels -> <your-tunnel> -> Public Hostnames tab."
  for ((i=0; i<GPU_COUNT && i<${#SUBDOMAINS[@]}; i++)); do
    warn "  Add: hostname=${SUBDOMAINS[$i]} service=http://localhost:${PORTS[$i]}"
  done
elif [ -f "/root/.cloudflared/cert.pem" ]; then
  # ---- Mode B: CERT ----
  ok "using CERT mode (/root/.cloudflared/cert.pem found)"
  install_cloudflared
  if [ -z "$TUNNEL_NAME" ]; then
    err "CERT mode needs --tunnel-name <name>"
    exit 1
  fi
  # Idempotent create -- ignore if already exists
  dryecho "$CLOUDFLARED tunnel create '$TUNNEL_NAME' 2>/dev/null || true"
  for sd in "${SUBDOMAINS[@]}"; do
    dryecho "$CLOUDFLARED tunnel route dns '$TUNNEL_NAME' '$sd' 2>/dev/null || true"
  done
  TID=$(ls ~/.cloudflared/*.json 2>/dev/null | grep -v cert | head -1 | xargs -I{} basename {} .json)
  if [ -z "$TID" ] && ! $DRY_RUN; then
    err "tunnel credentials JSON not found after create -- something failed"
    exit 1
  fi
  write_config_file "${TID:-DRYRUN_TID}"
  dryecho "nohup $CLOUDFLARED tunnel run '$TUNNEL_NAME' > '$LOGS_DIR/tunnel.log' 2>&1 &"
  sleep 3
  if ! $DRY_RUN; then
    tail -5 "$LOGS_DIR/tunnel.log" 2>/dev/null || true
  fi
else
  err "tunnel args given but neither CF_TUNNEL_TOKEN nor /root/.cloudflared/cert.pem present"
  err "options:"
  err "  A) export CF_TUNNEL_TOKEN=<token>  (recommended, get from CF dashboard)"
  err "  B) copy cert.pem to /root/.cloudflared/ from a machine where you ran 'cloudflared tunnel login'"
  err "  C) re-run with --skip-tunnel and handle it manually"
  exit 1
fi

# ============================================================ #
phase 9 "Fleet registration cheatsheet"
# ============================================================ #
cat <<EOF_CHEAT

${C}========== NEXT MANUAL STEPS ==========${N}

1. CF Access (lock public access):
   https://one.dash.cloudflare.com -> Access -> Applications
$(for sd in "${SUBDOMAINS[@]}"; do echo "   Add domain: $sd"; done)
   Attach existing service-token policy (same as comfy.bestyiever.*)

2. Wifemaker -> Servers -> + Add server (one row per subdomain below):
   Auth:      servicetoken
   cfId:      <YOUR_CF_ACCESS_CLIENT_ID>
   cfSecret:  <YOUR_CF_ACCESS_CLIENT_SECRET>
$(for sd in "${SUBDOMAINS[@]}"; do echo "   - URL: https://$sd"; done)

3. Waifumaster -> /admin -> Servers tab -> + New server (one row per subdomain above)
   Tip: for high-VRAM cards (48GB+) bump max_concurrent to 5
        for 32GB cards (5090), max_concurrent 3
        for 16-24GB cards, max_concurrent 2

4. (Optional) verify endpoints from local:
$(for sd in "${SUBDOMAINS[@]}"; do echo "   curl.exe https://$sd/system_stats"; done)

5. (If models not pulled here) Use wifemaker Sync Local modal to push the
   models you want from another server. Or re-run install.sh with
   --pull-loras / --pull-checkpoint.

${G}Done.${N} ComfyUI is running on:
EOF_CHEAT
for ((i=0; i<GPU_COUNT; i++)); do
  echo "    localhost:${PORTS[$i]}  (GPU $i)"
done
echo
