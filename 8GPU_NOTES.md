# 8x GPU vast.ai 部署经验笔记

## 这次失败原因

**单台 8x 5090 共享 ComfyUI 进程**有几个隐藏问题：

1. **vast.ai 预装的 `comfy_aimdo` addon**做 Dynamic VRAM streaming，5090 32GB 显存完全不需要 → 每 step 多花 6 秒 host↔device 传输
   - **修法**: ComfyUI 启动加 `--highvram`，绕过 staging
2. **8 进程共享 disk** → 159GB LoRA 池被 8 个 ComfyUI 同时随机读，I/O 争抢
3. **8 进程共享 output 目录**（默认 `/workspace/ComfyUI/output/`）→ 跨 process 文件查找潜在 race
4. **/view race condition**：comfy 报 "executed" 完成后 SaveImage 写盘还需几百 ms，waifumaster pregen poll 太快 → 抓到 HTTP 400 (file not found)，重试后才有
   - 表现：vast 上失败率 60%，老 fleet 几乎 0
5. **scheduler 任务分发偏向 vast** → vast 因为 "in_flight 表面少" 被疯狂派任务，老 fleet 反而饿死

## 下次方案：8 张卡 = 8 台独立 vast 实例

不要租 1 台 8 卡的，**租 8 台 1 卡的**：

```
机器 A (1x 5090) ─→ vast8a.bestyiever.vip (本来就有的设置)
机器 B (1x 5090) ─→ vast8b.bestyiever.vip
...
```

优点：
- ✅ 独立进程 + 独立 output 目录 → 无 race
- ✅ 独立网卡 → tunnel 带宽不抢
- ✅ 部署用现成 deploy.sh 单 GPU 模式（已验证 vistapro6000、vast5090A 都跑通了）
- ✅ 单台死了不影响其他 7 台
- ⚠️ vast.ai 1 卡机器价格相同但要 8 次开通流程

## 复用资源（这次留下的）

### CF Tunnel：8 个 vast8a-h 都已经建好，可以复用！

8 个 CF tunnel token（从 vast8a 到 vast8h）已经在 CF dashboard 存着。下次每租一台新机器：
1. 用对应字母 (a/b/c/d/e/f/g/h) 的 token：`CF_TUNNEL_TOKEN='eyJh...'`
2. 跑 deploy.sh：`--subdomain vast8X.bestyiever.vip --pull-loras '*'`
3. 完事

8 个 token 我现在不在这里贴（已经在你 CF dashboard 里）。

⚠️ 这次会话里这些 token 被贴在聊天历史里了 — **建议你下次用之前到 CF dashboard 给每个 tunnel rotate token**。

### R2 LoRA 池

`bestyiever-loras/loras/` 上 3,564 个文件 / 159GB，CF 出流量免费 → 下次 8 台机器各拉一份 0 成本。每台部署时：
```bash
curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/install.sh \
  | bash -s -- --pull-loras '*'
```

### Fleet 注册

这次 waifumaster 上 8 条 vast8gpu-a..h 已经删了，要新建 8 条照旧。或者下次再用 backend API 批量添加（之前的 chrome.js 脚本能复用）。

## 关键启动参数（每台 1 卡机器都用）

```bash
# 在 vast SSH 跑这一条
export CF_TUNNEL_TOKEN='<那台对应的 token，从 CF dashboard 复制>'
export R2_ACCESS_KEY_ID=<your R2 key>
export R2_SECRET_ACCESS_KEY=<your R2 secret>

curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/deploy.sh \
  | bash -s -- \
    --subdomain vast8X.bestyiever.vip \
    --pull-loras '*' \
    --pull-checkpoint 'unholyDesireMixSinister_v80.safetensors'

# 然后在 ComfyUI 启动器里加 --highvram（这次遗漏了！下次部署前先确认）
sed -i 's/--listen 0.0.0.0 --port/--listen 0.0.0.0 --highvram --port/g' /workspace/start_*.sh
bash /workspace/start_*.sh
```

## TODO: deploy.sh 改进

应该把 `--highvram` 加到 deploy.sh 生成的启动器里作为默认。让我下次顺手加上。
