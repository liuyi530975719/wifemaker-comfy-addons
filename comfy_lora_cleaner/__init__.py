"""
comfy_lora_cleaner — companion ComfyUI addon for the anime studio.

Adds two HTTP endpoints to your ComfyUI server so the studio's "Clean non-SDXL
LoRAs" tool can:
  1) Inspect each LoRA's safetensors header to identify its base model.
  2) Delete the ones the user picks.

This is a SEPARATE custom_nodes folder from comfy_model_uploader so deploying
it doesn't risk breaking your existing uploader. Drop it in alongside the
uploader and restart ComfyUI once.

Endpoints:
  GET  /lora_cleaner/inspect?name=<file>            (single LoRA's metadata)
  POST /lora_cleaner/inspect_batch  body: {"names": [...]}  (bulk)
  POST /lora_cleaner/delete         body: {"type": "loras", "name": "..."}
       Returns: {ok: true, deleted: <abs_path>}
       Filename is sanitized — no path traversal allowed.
       Type must be in the safety allowlist (default: loras only).

The inspect endpoint returns:
  {
    name, sha256, size_bytes,
    base_model: "SDXL" | "SD15" | "SD2" | "PONY" | "ILLUSTRIOUS" | "NOOBAI" | "UNKNOWN",
    base_model_source: "metadata" | "tensor_dim" | "filename" | "size",
    metadata_fields: { ss_base_model_version, ss_sd_model_name, ss_v2, ... },
    tensor_dims: { te1: <int|null>, te2: <int|null>, unet_in: <int|null> }
  }
"""
import os
import json
import struct
import hashlib

import folder_paths
from server import PromptServer
from aiohttp import web

ADDON_VERSION = 1
ALLOWED_TYPES = {"loras"}     # only loras for now — extend if you want
                              # checkpoints/embeddings/etc. cleanup too

# --------------------------------------------------------------------------- #
# Small safetensors header reader. Format:
#   first 8 bytes: little-endian uint64 = JSON header length
#   next N bytes : UTF-8 JSON header
#   header has "__metadata__" key (string→string map) plus per-tensor entries
#   each tensor entry has: { dtype, shape, data_offsets }
# --------------------------------------------------------------------------- #
def _read_safetensors_header(path):
    try:
        with open(path, "rb") as f:
            head_len_bytes = f.read(8)
            if len(head_len_bytes) < 8:
                return None
            head_len = struct.unpack("<Q", head_len_bytes)[0]
            if head_len <= 0 or head_len > 100 * 1024 * 1024:
                return None
            head_json = f.read(head_len).decode("utf-8", errors="replace")
            return json.loads(head_json)
    except Exception:
        return None


def _file_sha256(path, max_bytes=None):
    """sha256 of file content. max_bytes lets you skip hashing huge files
    when only a partial signature is needed (we don't use that here — full
    hash for Civitai-grade verification).
    """
    h = hashlib.sha256()
    try:
        with open(path, "rb") as f:
            while True:
                chunk = f.read(1024 * 1024)
                if not chunk:
                    break
                h.update(chunk)
                if max_bytes and h.block_size and f.tell() >= max_bytes:
                    break
        return h.hexdigest()
    except Exception:
        return None


def _classify_from_metadata(meta):
    """Inspect the kohya-style __metadata__ block. Returns
    (base_model_label, source, raw_fields_subset) or (None, None, {})."""
    if not meta:
        return None, None, {}
    # kohya writes: ss_base_model_version, ss_sd_model_name, ss_v2 ("True"/"False")
    keep = {}
    for k in (
        "ss_base_model_version", "ss_sd_model_name", "ss_v2",
        "ss_network_module", "ss_network_dim", "ss_network_alpha",
        "modelspec.architecture", "modelspec.implementation",
        "modelspec.title", "modelspec.sai_model_spec",
    ):
        if k in meta:
            keep[k] = meta[k]
    bm = (meta.get("ss_base_model_version") or "").lower()
    arch = (meta.get("modelspec.architecture") or "").lower()
    if "sdxl" in bm or "sdxl" in arch:
        # SDXL family — try to pin a sub-flavor by ss_sd_model_name
        sdname = (meta.get("ss_sd_model_name") or "").lower()
        if "pony" in sdname:
            return "PONY", "metadata", keep
        if "illust" in sdname or "noobai" in sdname:
            return "ILLUSTRIOUS", "metadata", keep
        return "SDXL", "metadata", keep
    if "sd_v2" in bm or "v2" in (meta.get("ss_v2") or "").lower():
        return "SD2", "metadata", keep
    if "sd_v1" in bm or "sd1" in arch:
        return "SD15", "metadata", keep
    return None, None, keep


def _classify_from_tensor_dims(header):
    """Use tensor shapes as a fallback. SDXL LoRAs target both text_encoder
    (CLIP-L, 768-dim) AND text_encoder_2 (OpenCLIP-G, 1280-dim). SD1.5 LoRAs
    only have CLIP-L. SDXL UNet has 320-dim input vs SD1.5's 320-dim too,
    but the cross-attn dim is 2048 (SDXL) vs 768 (SD1.5)."""
    te_l = None
    te_g = None
    cross_attn = None
    if not isinstance(header, dict):
        return None, None, {}
    for key in header.keys():
        if key == "__metadata__":
            continue
        ent = header.get(key)
        if not isinstance(ent, dict):
            continue
        shape = ent.get("shape") or []
        if not shape:
            continue
        kl = key.lower()
        if "text_encoder_2" in kl or "_te2_" in kl or "_g_" in kl:
            te_g = max(te_g or 0, *shape)
        elif "text_encoder" in kl or "_te1_" in kl or "_l_" in kl:
            te_l = max(te_l or 0, *shape)
        if "cross" in kl and "attn" in kl:
            cross_attn = max(cross_attn or 0, *shape)
    dims = {"te1": te_l, "te2": te_g, "unet_cross_attn": cross_attn}
    if te_g and te_g >= 1280:
        return "SDXL", "tensor_dim", dims
    if te_l and te_l >= 700:
        # CLIP-L only (likely SD1.5)
        return "SD15", "tensor_dim", dims
    return None, None, dims


def _classify_from_filename(name):
    n = name.lower()
    if "pony" in n:
        return "PONY", "filename"
    if "illustrious" in n or "ill_" in n or "_ill." in n or "noobai" in n:
        return "ILLUSTRIOUS", "filename"
    if "sdxl" in n or "_xl" in n or "xl_" in n or "xlv" in n:
        return "SDXL", "filename"
    if "sd15" in n or "sd_15" in n or "sd1.5" in n:
        return "SD15", "filename"
    if "sd2" in n or "v2-" in n:
        return "SD2", "filename"
    return None, None


def _classify_from_size(size_bytes):
    if not size_bytes:
        return None, None
    mb = size_bytes / (1024 * 1024)
    # SDXL LoRAs are typically 100-400 MB; SD1.5 LoRAs are 10-150 MB.
    # This is fuzzy — use only as last resort.
    if mb >= 200:
        return "SDXL", "size"
    if mb < 50:
        return "SD15", "size"
    return None, None


def _resolve_lora_path(filename):
    """Look up the LoRA in folder_paths.get_full_path. Returns absolute path
    or None. Sanitize first — no traversal."""
    safe = os.path.basename(filename)
    if safe != filename:
        return None
    if "/" in safe or "\\" in safe or safe.startswith("."):
        return None
    return folder_paths.get_full_path("loras", safe)


def _inspect_one(filename):
    out = {
        "name": filename,
        "found": False,
        "size_bytes": 0,
        "sha256": None,
        "base_model": "UNKNOWN",
        "base_model_source": None,
        "metadata_fields": {},
        "tensor_dims": {},
        "abs_path": None,
    }
    abs_path = _resolve_lora_path(filename)
    if not abs_path or not os.path.isfile(abs_path):
        return out
    out["found"] = True
    out["abs_path"] = abs_path
    try:
        out["size_bytes"] = os.path.getsize(abs_path)
    except Exception:
        pass
    header = _read_safetensors_header(abs_path)
    meta = (header or {}).get("__metadata__") if isinstance(header, dict) else None
    bm, src, fields = _classify_from_metadata(meta)
    if bm:
        out["base_model"] = bm
        out["base_model_source"] = src
        out["metadata_fields"] = fields
    else:
        out["metadata_fields"] = fields or {}
        bm2, src2, dims = _classify_from_tensor_dims(header)
        out["tensor_dims"] = dims or {}
        if bm2:
            out["base_model"] = bm2
            out["base_model_source"] = src2
        else:
            bm3, src3 = _classify_from_filename(filename)
            if bm3:
                out["base_model"] = bm3
                out["base_model_source"] = src3
            else:
                bm4, src4 = _classify_from_size(out["size_bytes"])
                if bm4:
                    out["base_model"] = bm4
                    out["base_model_source"] = src4
    return out


# --------------------------------------------------------------------------- #
# Routes
# --------------------------------------------------------------------------- #
@PromptServer.instance.routes.get("/lora_cleaner/inspect")
async def _inspect_route(request):
    name = request.query.get("name", "")
    if not name:
        return web.json_response({"error": "name required"}, status=400)
    try:
        return web.json_response(_inspect_one(name))
    except Exception as e:
        return web.json_response({"error": str(e)}, status=500)


@PromptServer.instance.routes.post("/lora_cleaner/inspect_batch")
async def _inspect_batch_route(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "invalid json"}, status=400)
    names = body.get("names") or []
    if not isinstance(names, list):
        return web.json_response({"error": "names must be a list"}, status=400)
    results = []
    for n in names[:2000]:   # cap to avoid runaway
        try:
            results.append(_inspect_one(str(n)))
        except Exception as e:
            results.append({"name": n, "found": False, "error": str(e)})
    return web.json_response({"results": results})


@PromptServer.instance.routes.post("/lora_cleaner/delete")
async def _delete_route(request):
    try:
        body = await request.json()
    except Exception:
        return web.json_response({"error": "invalid json"}, status=400)
    type_ = (body.get("type") or "").strip().lower()
    name = (body.get("name") or "").strip()
    if type_ not in ALLOWED_TYPES:
        return web.json_response(
            {"error": f"type '{type_}' not in allowlist {sorted(ALLOWED_TYPES)}"},
            status=400)
    if not name:
        return web.json_response({"error": "name required"}, status=400)
    abs_path = _resolve_lora_path(name)
    if not abs_path or not os.path.isfile(abs_path):
        return web.json_response({"error": f"file not found: {name}"}, status=404)
    # One last belt-and-braces guard against escaping the loras root
    norm = os.path.normpath(abs_path)
    loras_roots = [os.path.normpath(p) for p in folder_paths.get_folder_paths("loras")]
    if not any(norm.startswith(r) for r in loras_roots):
        return web.json_response(
            {"error": "refused: file is outside known loras roots"}, status=403)
    try:
        os.remove(norm)
    except Exception as e:
        return web.json_response({"error": f"delete failed: {e}"}, status=500)
    # Best-effort cache invalidation so the deletion is visible to ComfyUI
    try:
        if hasattr(folder_paths, "filename_list_cache"):
            folder_paths.filename_list_cache.pop("loras", None)
    except Exception:
        pass
    return web.json_response({"ok": True, "deleted": norm})


@PromptServer.instance.routes.get("/lora_cleaner/info")
async def _info_route(request):
    return web.json_response({
        "addon": "comfy_lora_cleaner",
        "version": ADDON_VERSION,
        "endpoints": [
            "GET  /lora_cleaner/inspect?name=<file>",
            "POST /lora_cleaner/inspect_batch  body={names:[...]}",
            "POST /lora_cleaner/delete         body={type,name}",
            "GET  /lora_cleaner/info",
        ],
        "allowed_delete_types": sorted(ALLOWED_TYPES),
    })


# Required by ComfyUI custom_nodes loader (even though we don't add nodes)
NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}

print(f"[comfy_lora_cleaner] v{ADDON_VERSION} routes registered: True")
