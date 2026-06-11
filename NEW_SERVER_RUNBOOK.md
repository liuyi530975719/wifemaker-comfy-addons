# 新 ComfyUI Server 接入 Fleet 一键 Runbook

从租机器到 wifemaker 能推模型 + waifumaster 能抽卡，总共 7 个 phase。

---

## Phase 0 — 租机器（人工）

vast.ai / Lambda Labs / 哪都行：

- **GPU**: 5090 / 4090 / 3090 (≥24GB VRAM)
- **Disk**: ≥ **80 GB**（SDXL + LoRA 全集 ~50GB，留 30GB 工作空间）
- **CUDA**: ≥ 12.4（5090 Blackwell 需要 12.6+，PyTorch cu128 OK）
- **开放端口**: 8189-8200（避开 vast.ai caddy 占用的 8188/8288/8384/1111）
- **镜像**: `pytorch/pytorch:2.6.0-cuda12.4-cudnn9-devel` 或自带 ComfyUI 的模板

SSH 进去后 `df -h /` 必须 ≥ 60GB 可用。否则换机器。

---

## Phase 1 — ComfyUI 主体（5 分钟）

```bash
# 1) 进 /workspace（一般是大盘所在）
cd /workspace
df -h .  # 确认 ≥ 60G

# 2) 克隆 ComfyUI
git clone https://github.com/comfyanonymous/ComfyUI.git
cd ComfyUI

# 3) 验证 torch 已经 Blackwell-ready (5090 需要 cc=(12,0))
python -c "import torch; print('torch:', torch.__version__, '| cc:', torch.cuda.get_device_capability(0), '| GPU:', torch.cuda.get_device_name(0))"

# 期望: torch >= 2.6, cc=(12,0) 或 (8,9) 等，GPU 名字对得上

# 4) 装 ComfyUI 依赖（保护现有 torch 不被升级）
python -c "import torch, torchvision, torchaudio; print(f'torch=={torch.__version__}\ntorchvision=={torchvision.__version__}\ntorchaudio=={torchaudio.__version__}')" > /tmp/torch_pin.txt
pip install -r requirements.txt -c /tmp/torch_pin.txt
```

---

## Phase 2 — 公共 custom nodes（5 分钟）

```bash
cd /workspace/ComfyUI/custom_nodes

for pack in \
    "https://github.com/ltdrdata/ComfyUI-Manager" \
    "https://github.com/ltdrdata/ComfyUI-Impact-Pack" \
    "https://github.com/ltdrdata/ComfyUI-Impact-Subpack" \
    "https://github.com/ssitu/ComfyUI_UltimateSDUpscale" \
    "https://github.com/Fannovel16/comfyui_controlnet_aux" \
    "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite" \
    "https://github.com/cubiq/ComfyUI_essentials"
do
    name=$(basename "$pack" .git)
    git clone --depth 1 "$pack" "$name" 2>/dev/null || true
    [ -f "$name/requirements.txt" ] && pip install -q -r "$name/requirements.txt"
done
```

---

## Phase 3 — 私有 addons（1 行）

```bash
curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/install.sh | bash
```

自动装 `comfy_model_uploader` + `comfy_lora_cleaner` 到 `/workspace/ComfyUI/custom_nodes/`。

---

## Phase 4 — 启动 ComfyUI

### 单 GPU

```bash
cd /workspace/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8190 > /workspace/comfy.log 2>&1 &
```

### 双 GPU（每张独立进程）

```bash
cat > /workspace/start_dual_comfy.sh << 'EOF'
#!/usr/bin/env bash
set -e
cd /workspace/ComfyUI
mkdir -p /workspace/logs /workspace/ComfyUI/user-gpu0 /workspace/ComfyUI/user-gpu1
pkill -9 -f "main.py --listen" 2>/dev/null || true
sleep 2
CUDA_VISIBLE_DEVICES=0 nohup python main.py --listen 0.0.0.0 --port 8190 \
    --user-directory /workspace/ComfyUI/user-gpu0 > /workspace/logs/comfy-gpu0.log 2>&1 &
CUDA_VISIBLE_DEVICES=1 nohup python main.py --listen 0.0.0.0 --port 8189 \
    --user-directory /workspace/ComfyUI/user-gpu1 > /workspace/logs/comfy-gpu1.log 2>&1 &
sleep 30
echo "=== ports ==="
curl -sf -o /dev/null -w "8190 HTTP %{http_code}\n" http://localhost:8190/system_stats
curl -sf -o /dev/null -w "8189 HTTP %{http_code}\n" http://localhost:8189/system_stats
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader
EOF
chmod +x /workspace/start_dual_comfy.sh
bash /workspace/start_dual_comfy.sh
```

### 端口避坑

| 用 | 不要用（vast.ai 占用） |
|---|---|
| 8189, 8190, 8191… 高位 | 8188, 8288, 8384, 1111 |

启动后验证四个 endpoint：

```bash
sleep 30
for p in 8190 8189; do
  curl -sf http://localhost:$p/upload/model/info | head -c 100
  echo
  curl -sf http://localhost:$p/lora_cleaner/info | head -c 100
  echo
done
```

四个都返回 JSON 才算 OK。

---

## Phase 5 — CloudFlare Tunnel

```bash
# 装 cloudflared（vast 自带的版本可能旧，独立装）
wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
    -O /usr/local/bin/cloudflared-mine
chmod +x /usr/local/bin/cloudflared-mine

# 登录 CF（命令会输出 URL，复制到本地浏览器开，选 bestyiever.vip 那个 zone）
/usr/local/bin/cloudflared-mine tunnel login

# 创建 tunnel（名字自取，例如 vast5090dual / lambdaA100 等）
TNAME=$(hostname -s)-tunnel
/usr/local/bin/cloudflared-mine tunnel create $TNAME

# 创建 DNS 路由（替换子域名）
SUB_A=mynewmachine-a.bestyiever.vip
SUB_B=mynewmachine-b.bestyiever.vip
/usr/local/bin/cloudflared-mine tunnel route dns $TNAME $SUB_A
# 单 GPU 只配 SUB_A 就行；双 GPU 加 SUB_B
/usr/local/bin/cloudflared-mine tunnel route dns $TNAME $SUB_B

# 配置文件
TID=$(ls ~/.cloudflared/*.json | head -1 | xargs basename -s .json)
cat > ~/.cloudflared/config.yml << EOF
tunnel: $TID
credentials-file: /root/.cloudflared/${TID}.json
ingress:
  - hostname: $SUB_A
    service: http://localhost:8190
  - hostname: $SUB_B
    service: http://localhost:8189
  - service: http_status:404
EOF

# 后台跑
nohup /usr/local/bin/cloudflared-mine tunnel run $TNAME > /workspace/logs/tunnel.log 2>&1 &
sleep 5
tail -10 /workspace/logs/tunnel.log
# 期望: 4 个 "Registered tunnel connection" 行
```

---

## Phase 6 — CF Access 锁住公网

⚠️ **没做这一步前 vast 上的 5090 是公网完全开放的**，任何人都能用你的卡。

到 [https://one.dash.cloudflare.com](https://one.dash.cloudflare.com) → bestyiever account → **Access → Applications**：

1. 找到已有的 `comfy fleet` application（覆盖 `comfy.bestyiever.*` 那个）
2. 点开 → **Application Domains → + Add domain**
3. 加 `mynewmachine-a.bestyiever.vip` 和 `mynewmachine-b.bestyiever.vip`
4. Save — 它自动继承现有 service token policy

30 秒生效后验证（本地 PowerShell）：

```powershell
# 不带 token 应该 302/403
curl.exe -s -o NUL -w "%{http_code}`n" https://mynewmachine-a.bestyiever.vip/system_stats

# 带 token 应该 200
curl.exe -s -o NUL -w "%{http_code}`n" `
  -H "CF-Access-Client-Id: <YOUR_CF_ACCESS_CLIENT_ID>" `
  -H "CF-Access-Client-Secret: <YOUR_CF_ACCESS_CLIENT_SECRET>" `
  https://mynewmachine-a.bestyiever.vip/system_stats
```

第一行 403，第二行 200 = 配置正确。

---

## Phase 7 — 接入 fleet

### Wifemaker

[Servers] modal → **+ Add server** 两条：

| Name | URL | Auth | cfId | cfSecret |
|---|---|---|---|---|
| MyNew-A | `https://mynewmachine-a.bestyiever.vip` | servicetoken | `<YOUR_CF_ACCESS_CLIENT_ID>` | `<YOUR_CF_ACCESS_CLIENT_SECRET>` |
| MyNew-B | `https://mynewmachine-b.bestyiever.vip` | servicetoken | (同上) | (同上) |

保存 → **Test all** → 应该全绿 + 列出 model/LoRA。

### Waifumaster

`/admin` → Servers tab → + New server ×2：

| Name | URL | Auth | Max concurrent |
|---|---|---|---|
| MyNew-A | `mynewmachine-a.bestyiever.vip` | servicetoken | 3 |
| MyNew-B | `mynewmachine-b.bestyiever.vip` | servicetoken | 3 |

保存 → Probe → 绿灯。

---

## Phase 8 — 推首个模型

Wifemaker [🔁 Sync Local] modal：

1. Source 选有 SDXL base 的现有 server（比如 CN5090）
2. Type = `checkpoints`
3. Re-scan
4. 在 grid 里勾选你常用的 SDXL base（`unholyDesireMixSinister_v80.safetensors` 等）
5. ⤓ Sync N selected pairs → 等 2-5 分钟（chunked upload）
6. 再切 Type = `loras` 推 character LoRA

完事。waifumaster 抽卡时 fleet scheduler 会自动用上新 server。

---

## 常见坑

| 症状 | 原因 | 修 |
|---|---|---|
| `Port 8188 in use` | vast.ai caddy 占了 | 换 8190/8189 |
| `Could not acquire lock on database` | 双进程共享 `user/comfyui.db` | `--user-directory` 给每个进程独立目录 |
| install.sh `line 103 EOF` | PowerShell `Set-Content` 把 LF 改成 CRLF 或破坏 UTF-8 | install.sh 必须纯 ASCII + LF（已经修了） |
| wifemaker "Failed to fetch" | 浏览器直连 CF Access 被 CORS 拦 | 已加 `/api/comfy-proxy/` backend proxy（必须从 `http://localhost:5500/...` 而不是 file://） |
| ComfyUI `(IMPORT FAILED)` 私有 addon | repo 里的 `__init__.py` 文件被截断 | 重新 `cp outputs/comfy_model_uploader/__init__.py` 然后 push |

