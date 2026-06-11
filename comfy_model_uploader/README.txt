comfy_model_uploader v4 — ComfyUI custom node
================================================

HTTP endpoints exposed under your ComfyUI server:

  POST /upload/model            one-shot multipart upload (small files)
  POST /upload/model/chunk      CHUNKED upload (≥20 MB → split client-side
                                into 20 MB chunks so Cloudflare's 100 MB body
                                cap doesn't stall multi-GB pushes)
  GET  /upload/model/chunk_status?upload_id=…
  GET  /upload/model/info       includes uploader_version + supports[]
  GET  /upload/model/list       existing filenames for a type
  POST /upload/model/refresh    clear folder_paths cache (no restart needed)
  POST /upload/model/restart    hot-restart ComfyUI; logs to restart.log
  GET  /upload/model/lora_meta  safetensors header + SHA256/AutoV2

INSTALL
-------
1. Copy the entire comfy_model_uploader/ folder to:
       <YourComfyUI>/custom_nodes/comfy_model_uploader/
2. Restart ComfyUI ONCE to load the addon.
3. Confirm in console:
       [comfy_model_uploader] routes registered: True
       (uploader_version=4, supports chunked_upload + restart_v2)
4. In the Studio's Upload modal click "Detect addon" — each rig should show
       ✓ v4 · ✓ chunked

For each rig (.com / .net / .us / .win / .cc / Local) repeat steps 1-4.

RESTART NOTES (Windows)
-----------------------
The /upload/model/restart endpoint kills the current ComfyUI process and
either:

  (a) Spawns a detached replacement directly (works on most setups), OR
  (b) Just exits — relies on a watchdog (run.py / pm2 / systemd / nssm) to
      respawn the process.

For the LOCAL rig managed by run.py, the bundled run.py is now a watchdog —
when ComfyUI exits, run.py respawns it within ~2 seconds (up to 8 times in
10 minutes; after that it gives up). Web server + cloudflared tunnel stay
running across the restart so the Studio doesn't disconnect.

For REMOTE rigs without a watchdog, the addon's own subprocess respawn does
the job. If a restart appears to hang, check
  <ComfyUI>/custom_nodes/comfy_model_uploader/restart.log
on that rig — every step is logged there.

SECURITY
--------
This addon does not add its own authentication. It inherits whatever auth
your ComfyUI server is already protected by — typically Cloudflare Access
with a service token in the Studio's server config. If your ComfyUI is
reachable without auth, this endpoint is too.

Allowed types are limited to ComfyUI model categories (loras, checkpoints,
vae, upscale_models, embeddings, controlnet, clip, clip_vision, diffusers,
hypernetworks, gligen, photomaker, style_models, unet) and filenames are
sanitized: no path traversal, no slashes in basename. Existing files are
NOT overwritten unless overwrite=1 is sent.

UPDATING
--------
Replace __init__.py with the newer version and either:
  • click the per-server ↻ Restart button in the Studio, OR
  • restart ComfyUI manually
The watchdog in run.py picks up the new code on next restart.
