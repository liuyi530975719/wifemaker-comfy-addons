
---

## 🚀 New ComfyUI Server -- one-line deploy

Spin up a fresh Linux+GPU box (vast.ai, Lambda, etc), SSH in, then:

```bash
curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/deploy.sh \
  | bash -s -- \
    --tunnel-name mynew5090 \
    --subdomain mynew5090a.bestyiever.vip \
    --subdomain-b mynew5090b.bestyiever.vip \
    --pull-loras '*' \
    --pull-checkpoint 'unholyDesireMixSinister_v80.safetensors'
```

9 phases, all idempotent:
1. Verify GPU + disk + Python
2. Clone ComfyUI to /workspace/ComfyUI
3. Install Python deps + 7 public custom nodes
4. Install private addons (uploader + lora_cleaner)
5. Write dual-GPU start script (auto-detected)
6. Start ComfyUI processes
7. Pull LoRAs / checkpoints from R2 (matching globs)
8. Set up Cloudflare Tunnel (interactive `tunnel login` step)
9. Print fleet-registration cheatsheet (CF Access + wifemaker + waifumaster)

Set R2 creds first if pulling models:

```bash
export R2_ACCESS_KEY_ID=...
export R2_SECRET_ACCESS_KEY=...
```

For details on each phase, see [NEW_SERVER_RUNBOOK.md](./NEW_SERVER_RUNBOOK.md).

---

# wifemaker-comfy-addons

Two custom-node packs that pair with [anime-comfyui-studio](https://github.com/liuyi530975719/wifemaker) to give every ComfyUI rig in your fleet:

| Addon | What it adds |
|---|---|
| `comfy_model_uploader/` | HTTP endpoints for **uploading models / LoRAs / VAEs** to the rig from the studio (chunked upload, model-list, folder-paths cache refresh, hot-restart) |
| `comfy_lora_cleaner/` | HTTP endpoints for **inspecting and deleting non-SDXL LoRAs** so SD1.5/SD2 leftovers don't fail your SDXL workflows |

Both are pure Python �?no compiled deps. They register routes via ComfyUI's `PromptServer.instance.routes`.

---

## One-line install on a fresh rig

```bash
curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/install.sh | bash
```

### With explicit ComfyUI dir

```bash
COMFY_DIR=/workspace/ComfyUI \
  curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/install.sh | bash
```

### After a normal `git clone`

```bash
git clone https://github.com/liuyi530975719/wifemaker-comfy-addons.git
cd wifemaker-comfy-addons
bash install.sh
```

The installer:
1. Auto-detects ComfyUI (looks at `/workspace/ComfyUI`, `~/ComfyUI`, `/opt/ComfyUI`, etc.)
2. Copies both addon folders into `<ComfyUI>/custom_nodes/`
3. Installs any `requirements.txt`
4. Prints restart instructions

After restart, verify each node is loaded:

```bash
curl -s http://localhost:8188/upload/model/info
curl -s http://localhost:8188/lora_cleaner/info
```

Both should return JSON.

---

## What gets registered

### `comfy_model_uploader` v4 endpoints

```
POST  /upload/model              # one-shot multipart upload (small files)
POST  /upload/model/chunk        # chunked upload (�?0 MB)
GET   /upload/model/chunk_status?upload_id=�?GET   /upload/model/info         # version + capabilities
GET   /upload/model/list?type=loras
POST  /upload/model/refresh      # clear folder_paths cache (no restart)
POST  /upload/model/restart      # hot-restart ComfyUI; logs to restart.log
GET   /upload/model/lora_meta    # safetensors header + SHA256/AutoV2
```

### `comfy_lora_cleaner` v1 endpoints

```
GET   /lora_cleaner/info
GET   /lora_cleaner/inspect?name=<file>
POST  /lora_cleaner/delete
POST  /lora_cleaner/scan
```

See each addon's own `README.txt` for full details.

---

## Restart behavior

Some rigs need a clean restart after install. The uploader's `/upload/model/restart` endpoint will do this for you remotely �?but the first time, you need to restart manually so ComfyUI registers the addons in the first place.

```bash
# systemd
sudo systemctl restart comfyui

# Docker
docker restart comfyui

# bare process (what most people have)
pkill -f "main.py --listen" && \
  cd <ComfyUI> && python main.py --listen 0.0.0.0 --port 8188 &
```

For the dual-GPU + vast.ai setup, just re-run `bash /workspace/start_dual_comfy.sh`.

---

## License

Personal use, no warranty. Don't redistribute without removing your service-token secrets.

---

## Fork checklist after pushing to your GitHub

1. Replace **all** `liuyi530975719` strings in `README.md` and `install.sh` with your GitHub username
2. (Optional) make the repo private �?but then the curl one-liner needs a PAT:
   ```bash
   curl -fsSL -H "Authorization: token $GITHUB_PAT" \
     https://raw.githubusercontent.com/<USER>/wifemaker-comfy-addons/main/install.sh | bash
   ```
3. Tag releases (`v1.0.0` etc.) so `BRANCH=v1.0.0 bash install.sh` pins to a known-good revision
