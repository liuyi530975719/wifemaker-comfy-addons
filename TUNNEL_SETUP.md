# Cloudflare Tunnel — 3 Modes for `deploy.sh` Phase 8

`deploy.sh` supports 3 ways to wire up the tunnel. Pick the one that fits your level of automation needs.

---

## 🟢 Mode A — TOKEN (recommended for fully automated deploys)

**Best for:** spinning up many machines quickly without per-machine interactive setup.

### One-time setup

1. Go to [Cloudflare Zero Trust → Networks → Tunnels](https://one.dash.cloudflare.com/?to=/:account/networks/tunnels)
2. Click **+ Create a tunnel** → choose **Cloudflared**
3. Give it a name (e.g. `vast5090dual` or `mynew5090`)
4. **Copy the token** that's displayed under "Install and run a connector"
   ```
   eyJhIjoi...very-long-string...XYZ
   ```
   It looks like a JWT. Save it — you'll need it for `deploy.sh`.
5. In the **Public Hostname** tab of that tunnel, click **+ Add a public hostname**:
   - Subdomain: `mynew5090a`
   - Domain: `bestyiever.vip` (your zone)
   - Service: `HTTP` `localhost:8190`
   - Save
6. Repeat for `mynew5090b` → `localhost:8189` (if dual GPU)

### Per-machine deploy

```bash
export CF_TUNNEL_TOKEN='eyJhIjoi...XYZ'
export R2_ACCESS_KEY_ID=...
export R2_SECRET_ACCESS_KEY=...

curl -fsSL https://raw.githubusercontent.com/liuyi530975719/wifemaker-comfy-addons/main/deploy.sh \
  | bash -s -- \
    --subdomain mynew5090a.bestyiever.vip \
    --subdomain-b mynew5090b.bestyiever.vip \
    --pull-loras '*'
```

✅ Fully non-interactive — Phase 8 will start `cloudflared tunnel run --token $TOKEN` and exit cleanly.

⚠️ Each tunnel can only run on ONE machine at a time. If you want to deploy 5 machines, create 5 separate tunnels.

---

## 🟡 Mode B — CERT (semi-automated, after one-time browser login)

**Best for:** when you want each machine to create its own tunnel programmatically.

### One-time setup

1. On any machine (your laptop, an existing comfy server), run:
   ```bash
   cloudflared tunnel login
   ```
2. Browser opens → log in to Cloudflare → pick your zone (`bestyiever.vip`) → authorize
3. This writes `~/.cloudflared/cert.pem`
4. Copy `cert.pem` somewhere you can retrieve later:
   - Upload to R2: `rclone copy ~/.cloudflared/cert.pem r2:bestyiever-loras/cf/`
   - Or save in 1Password / secret store

### Per-machine deploy

1. SSH into new machine
2. Pull cert.pem first:
   ```bash
   mkdir -p /root/.cloudflared
   rclone copy r2:bestyiever-loras/cf/cert.pem /root/.cloudflared/
   ```
3. Run `deploy.sh` with tunnel args:
   ```bash
   curl -fsSL https://.../deploy.sh | bash -s -- \
     --tunnel-name mynew5090 \
     --subdomain mynew5090a.bestyiever.vip \
     --subdomain-b mynew5090b.bestyiever.vip
   ```

Phase 8 detects `cert.pem`, creates a new tunnel called `mynew5090`, sets up DNS routes for the subdomains, writes config.yml, and starts the tunnel.

✅ Automated DNS + tunnel creation
⚠️ Requires distributing cert.pem (sensitive — treat it like an SSH key)

---

## ⚪ Mode C — SKIP (do it later)

**Best for:** when you're not sure of subdomain naming yet, or want to test ComfyUI locally first.

```bash
curl -fsSL https://.../deploy.sh | bash -s -- --skip-tunnel
```

Phase 8 prints what to do later. Set up the tunnel manually following [NEW_SERVER_RUNBOOK.md Phase 5](./NEW_SERVER_RUNBOOK.md#phase-5--cloudflare-tunnel).

---

## After tunnel is up — Phase 9 cheatsheet still applies

Tunnel running ≠ done. You still need:

1. **CF Access policy** to lock down the subdomain (otherwise public)
2. **Wifemaker servers list** — add the new endpoint with service token
3. **Waifumaster fleet** — same in admin panel
4. (Optional) **First model push** — wifemaker Sync Local modal, OR rerun deploy.sh with `--pull-loras`

deploy.sh's Phase 9 prints all the URLs and arg shapes you need.

---

## Quick comparison

| Mode | Cert.pem needed | DNS auto-created | Interactive browser step | Best for |
|---|---|---|---|---|
| A. TOKEN | ❌ | ❌ (do in dashboard once) | ❌ | Mass deployment, no extra files |
| B. CERT | ✅ | ✅ | ❌ on new machine (yes on home base, one time) | Fully programmatic per-machine |
| C. SKIP | — | — | — | Test mode, manual networking later |
