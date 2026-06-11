comfy_lora_cleaner — companion addon for the anime-comfyui-studio
==================================================================

Adds three HTTP endpoints to your ComfyUI server so the studio's
"🧹 Clean non-SDXL LoRAs" tool can identify and delete the wrong-base-model
LoRAs across all your rigs.

INSTALL
-------
1. Copy this entire `comfy_lora_cleaner/` folder into:
       <YourComfyUI>/custom_nodes/comfy_lora_cleaner/
2. Restart ComfyUI ONCE to load the addon.
3. Console should print:
       [comfy_lora_cleaner] v1 routes registered: True
4. Verify with:
       curl https://<server>/lora_cleaner/info
   Should return JSON with the version + endpoint list.

Repeat for every rig (.com / .net / .us / .win / .cc / Local).

ENDPOINTS
---------
GET  /lora_cleaner/inspect?name=<file>
       Returns { name, found, size_bytes, base_model, base_model_source,
                 metadata_fields, tensor_dims, abs_path }
       base_model is one of:
         SDXL | PONY | ILLUSTRIOUS | NOOBAI | SD15 | SD2 | UNKNOWN
       base_model_source tells you HOW we identified it:
         metadata     — kohya ss_base_model_version field
         tensor_dim   — text_encoder_2 found in tensor names
         filename     — guessed from filename (least reliable)
         size         — guessed from file size

POST /lora_cleaner/inspect_batch
       body: {"names": ["lora1.safetensors", ...]}
       returns: {"results": [...]}    (up to 2000 entries per call)

POST /lora_cleaner/delete
       body: {"type": "loras", "name": "filename.safetensors"}
       returns: {"ok": true, "deleted": "<abs_path>"}
       Refuses anything outside the known loras roots. Filename is
       sanitized — no path traversal, no slashes.

GET  /lora_cleaner/info
       Returns version + endpoint list + allowed delete types.

SAFETY
------
* DELETE only works on `type: "loras"` — checkpoints and other model
  folders are deliberately NOT in the allowlist. Edit `ALLOWED_TYPES`
  in __init__.py if you want to extend it.
* Filenames are sanitized via os.path.basename + slash check before
  resolution.
* The resolved absolute path is verified to be inside one of
  folder_paths.get_folder_paths("loras") before deletion. Any path
  escaping that root is refused (HTTP 403).
* This addon does NOT add its own authentication. It inherits whatever
  ComfyUI is already protected by — your existing Cloudflare Access
  service token, etc.

DEPENDENCIES
------------
None beyond what ComfyUI already ships with (folder_paths, server, aiohttp).
No new pip installs.
