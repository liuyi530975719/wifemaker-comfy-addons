"""
ComfyUI custom node v7: model upload (one-shot + chunked), URL-pull,
restart-with-watchdog-aware-strategy, refresh, file serve, Civitai proxy,
and safetensors metadata reader.

Endpoints under your ComfyUI server:

  POST /upload/model              one-shot multipart upload
  POST /upload/model/chunk        chunked upload (≥20 MB → split client-side
                                  into 20 MB chunks so Cloudflare's 100 MB
                                  body cap doesn't stall multi-GB pushes)
  GET  /upload/model/chunk_status?upload_id=…
  GET  /upload/model/info         configured target folders + uploader_version
  GET  /upload/model/list         existing filenames for a type
  POST /upload/model/refresh      clear folder_paths cache (no restart)
  POST /upload/model/restart      restart ComfyUI (watchdog-aware)
                                  Logs progress to comfy_model_uploader/restart.log
  GET  /upload/model/lora_meta    safetensors header + SHA256/AutoV2
  POST /upload/model/from_url     server-side URL download (Civitai sync)
  GET  /upload/model/from_url/status?job_id=…
  GET  /upload/model/serve        stream a file out (peer-pull source)
  GET  /upload/model/civitai/search   proxy Civitai API search past CORS

Auth: this addon doesn't add its own auth — inherits ComfyUI's protection
(Cloudflare Access + service token in the Studio's setup).
"""

import os
import sys
import json
import struct
import hashlib
import asyncio
import datetime
from aiohttp import web

try:
    from server import PromptServer
    import folder_paths
except Exception:
    PromptServer = None
    folder_paths = None

ALLOWED_TYPES = {
    "loras", "checkpoints", "vae", "upscale_models", "embeddings",
    "controlnet", "clip", "clip_vision", "diffusers", "hypernetworks",
    "gligen", "photomaker", "style_models", "unet",
}

CHUNK = 1024 * 1024  # 1 MiB streaming chunks for hashing/writing


def _safe_filename(name: str) -> str:
    name = (name or "").strip()
    name = os.path.basename(name)
    if not name or name in (".", ".."):
        return ""
    if "/" in name or "\\" in name:
        return ""
    return name


def _safe_subfolder(sub: str) -> str:
    if not sub:
        return ""
    parts = []
    for p in sub.replace("\\", "/").split("/"):
        p = p.strip()
        if not p or p in (".", ".."):
            continue
        if any(c in p for c in (":", "*", "?", "<", ">", "|", '"')):
            continue
        parts.append(p)
    return "/".join(parts)


def _resolve_dest_dir(target: str, subfolder: str):
    folders = folder_paths.get_folder_paths(target)
    if not folders:
        return None
    dest_dir = folders[0]
    if subfolder:
        dest_dir = os.path.join(dest_dir, subfolder)
    os.makedirs(dest_dir, exist_ok=True)
    return dest_dir


def _resolve_model_path(target: str, name: str):
    if folder_paths is None:
        return None
    try:
        p = folder_paths.get_full_path(target, name)
        if p and os.path.exists(p):
            return p
    except Exception:
        pass
    try:
        roots = folder_paths.get_folder_paths(target)
    except Exception:
        roots = []
    for root in roots:
        cand = os.path.join(root, name)
        if os.path.exists(cand):
            return cand
    return None


# ============================== ONE-SHOT UPLOAD ==============================

async def _upload_handler(request):
    if folder_paths is None:
        return web.json_response({"error": "folder_paths unavailable"}, status=500)
    reader = await request.multipart()
    target = None; filename = ""; subfolder = ""; overwrite = False; file_part = None
    while True:
        field = await reader.next()
        if field is None:
            break
        if field.name == "type":
            target = (await field.text()).strip().lower()
        elif field.name == "filename":
            filename = _safe_filename(await field.text())
        elif field.name == "subfolder":
            subfolder = _safe_subfolder(await field.text())
        elif field.name == "overwrite":
            overwrite = (await field.text()).strip() in ("1", "true", "yes", "on")
        elif field.name == "file":
            if not filename and field.filename:
                filename = _safe_filename(field.filename)
            file_part = field
            break
    if target not in ALLOWED_TYPES:
        return web.json_response({"error": f"invalid type {target!r}"}, status=400)
    if not filename:
        return web.json_response({"error": "missing or invalid filename"}, status=400)
    if file_part is None:
        return web.json_response({"error": "no file in request"}, status=400)
    dest_dir = _resolve_dest_dir(target, subfolder)
    if not dest_dir:
        return web.json_response({"error": f"no folder configured for type {target!r}"}, status=400)
    dest = os.path.join(dest_dir, filename)
    if os.path.exists(dest) and not overwrite:
        return web.json_response({"error": "file already exists", "path": dest,
                                   "size": os.path.getsize(dest), "hint": "send overwrite=1"},
                                  status=409)
    tmp = dest + ".part"
    bytes_written = 0
    try:
        with open(tmp, "wb") as f:
            while True:
                chunk = await file_part.read_chunk(CHUNK)
                if not chunk:
                    break
                f.write(chunk)
                bytes_written += len(chunk)
        os.replace(tmp, dest)
    except Exception as exc:
        try:
            if os.path.exists(tmp): os.remove(tmp)
        except Exception: pass
        return web.json_response({"error": f"write failed: {exc}", "wrote": bytes_written}, status=500)
    return web.json_response({"ok": True, "path": dest, "type": target, "subfolder": subfolder,
                               "filename": filename, "size": bytes_written})


# ============================== CHUNKED UPLOAD ==============================

_INFLIGHT_UPLOADS: dict = {}


async def _chunk_handler(request):
    if folder_paths is None:
        return web.json_response({"error": "folder_paths unavailable"}, status=500)
    reader = await request.multipart()
    fields = {"upload_id": "", "type": "", "filename": "", "subfolder": "",
              "overwrite": False, "chunk_index": 0, "chunk_total": 1, "total_size": 0}
    file_part = None
    while True:
        field = await reader.next()
        if field is None: break
        if field.name in ("upload_id", "type", "filename", "subfolder"):
            fields[field.name] = (await field.text()).strip()
        elif field.name == "overwrite":
            fields["overwrite"] = (await field.text()).strip() in ("1","true","yes","on")
        elif field.name == "chunk_index":
            try: fields["chunk_index"] = int(await field.text())
            except: pass
        elif field.name == "chunk_total":
            try: fields["chunk_total"] = int(await field.text())
            except: pass
        elif field.name == "total_size":
            try: fields["total_size"] = int(await field.text())
            except: pass
        elif field.name == "file":
            file_part = field
            break

    upload_id = fields["upload_id"]
    target    = fields["type"].lower()
    filename  = _safe_filename(fields["filename"])
    subfolder = _safe_subfolder(fields["subfolder"])
    chunk_i   = int(fields["chunk_index"])
    chunk_n   = int(fields["chunk_total"])
    overwrite = bool(fields["overwrite"])

    if not upload_id:                     return web.json_response({"error":"missing upload_id"}, status=400)
    if target not in ALLOWED_TYPES:       return web.json_response({"error":f"invalid type {target!r}"}, status=400)
    if not filename:                       return web.json_response({"error":"invalid filename"}, status=400)
    if file_part is None:                 return web.json_response({"error":"no file chunk in request"}, status=400)
    if chunk_n <= 0 or chunk_i < 0 or chunk_i >= chunk_n:
                                          return web.json_response({"error":"bad chunk_index/chunk_total"}, status=400)

    state = _INFLIGHT_UPLOADS.get(upload_id)
    if state is None:
        dest_dir = _resolve_dest_dir(target, subfolder)
        if not dest_dir: return web.json_response({"error": f"no folder configured for type {target!r}"}, status=400)
        dest = os.path.join(dest_dir, filename)
        if chunk_i == 0:
            if os.path.exists(dest) and not overwrite:
                return web.json_response({"error":"file already exists", "path": dest,
                                           "size": os.path.getsize(dest), "hint":"send overwrite=1"},
                                          status=409)
            tmp = dest + ".part"
            try:
                if os.path.exists(tmp): os.remove(tmp)
            except Exception: pass
        state = _INFLIGHT_UPLOADS[upload_id] = {
            "dest": dest, "tmp": dest + ".part", "target": target,
            "filename": filename, "subfolder": subfolder,
            "chunk_total": chunk_n, "received_bytes": 0, "received_chunks": 0,
            "next_chunk": 0, "overwrite": overwrite,
            "total_size": int(fields["total_size"] or 0),
        }

    if chunk_i != state["next_chunk"]:
        return web.json_response({"error": f"out-of-order: expected {state['next_chunk']}, got {chunk_i}",
                                   "next_chunk": state["next_chunk"], "received_bytes": state["received_bytes"]},
                                  status=409)

    bytes_written = 0
    try:
        with open(state["tmp"], "ab") as f:
            while True:
                buf = await file_part.read_chunk(CHUNK)
                if not buf: break
                f.write(buf)
                bytes_written += len(buf)
    except Exception as exc:
        return web.json_response({"error": f"write failed: {exc}",
                                   "received_bytes": state["received_bytes"],
                                   "next_chunk": state["next_chunk"]}, status=500)
    state["received_bytes"]  += bytes_written
    state["received_chunks"] += 1
    state["next_chunk"]       = chunk_i + 1

    if (chunk_i + 1) >= chunk_n:
        try: os.replace(state["tmp"], state["dest"])
        except Exception as exc:
            return web.json_response({"error": f"finalize failed: {exc}",
                                       "received_bytes": state["received_bytes"]}, status=500)
        final_size = os.path.getsize(state["dest"])
        _INFLIGHT_UPLOADS.pop(upload_id, None)
        return web.json_response({"ok": True, "finished": True,
                                   "path": state["dest"], "size": final_size,
                                   "type": target, "filename": filename, "subfolder": subfolder,
                                   "chunk_index": chunk_i, "chunk_total": chunk_n})
    return web.json_response({"ok": True, "finished": False,
                               "received_bytes": state["received_bytes"],
                               "received_chunks": state["received_chunks"],
                               "next_chunk": state["next_chunk"],
                               "chunk_index": chunk_i, "chunk_total": chunk_n})


async def _chunk_status_handler(request):
    upload_id = request.query.get("upload_id", "").strip()
    if not upload_id:
        return web.json_response({"error":"missing upload_id"}, status=400)
    state = _INFLIGHT_UPLOADS.get(upload_id)
    if not state:
        return web.json_response({"ok": True, "in_flight": False})
    return web.json_response({"ok": True, "in_flight": True,
                               "received_bytes": state["received_bytes"],
                               "received_chunks": state["received_chunks"],
                               "next_chunk": state["next_chunk"],
                               "chunk_total": state["chunk_total"],
                               "filename": state["filename"]})


# ============================== INFO + LIST ==============================

async def _info_handler(_request):
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    info = {}
    for t in sorted(ALLOWED_TYPES):
        try: info[t] = folder_paths.get_folder_paths(t)
        except Exception: info[t] = []
    return web.json_response({
        "ok": True, "uploader_version": 8, "folders": info,
        "supports": ["chunked_upload", "restart_v3", "from_url", "serve", "civitai_proxy", "watchdog_aware", "cleanup_partials", "from_url_jobs", "cleanup_outputs", "auto_cleanup", "addon_upload"],
        "uploader_version": 10,
    })


async def _list_handler(request):
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    target = request.query.get("type","").strip().lower()
    if target not in ALLOWED_TYPES:
        return web.json_response({"error":"invalid type"}, status=400)
    items = []
    try: items = folder_paths.get_filename_list(target)
    except Exception:
        folders = folder_paths.get_folder_paths(target)
        if folders and os.path.isdir(folders[0]):
            for root, _dirs, files in os.walk(folders[0]):
                rel = os.path.relpath(root, folders[0])
                for fn in files:
                    items.append(fn if rel in (".","") else os.path.join(rel, fn))
    return web.json_response({"ok": True, "type": target, "items": items})


# ============================== REFRESH + RESTART ==============================

async def _refresh_handler(_request):
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    cleared = []
    try:
        ch = getattr(folder_paths, "cache_helper", None)
        if ch is not None and hasattr(ch, "cache") and isinstance(ch.cache, dict):
            ch.cache.clear(); cleared.append("cache_helper")
    except Exception: pass
    try:
        flc = getattr(folder_paths, "filename_list_cache", None)
        if isinstance(flc, dict):
            flc.clear(); cleared.append("filename_list_cache")
    except Exception: pass
    counts = {}
    for t in sorted(ALLOWED_TYPES):
        try: counts[t] = len(folder_paths.get_filename_list(t))
        except Exception: counts[t] = -1
    return web.json_response({"ok": True, "cleared": cleared, "counts": counts})


def _restart_log_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "restart.log")

def _restart_log(msg: str):
    line = f"[{datetime.datetime.now().isoformat(timespec='seconds')}] {msg}\n"
    try:
        with open(_restart_log_path(), "a", encoding="utf-8") as f:
            f.write(line)
    except Exception: pass
    print(f"[comfy_model_uploader] {msg}", flush=True)


async def _restart_handler(_request):
    """Restart ComfyUI. Avoids the "CUDA out of memory" race that happens when
    a fresh child process tries to grab the GPU before the dying parent has
    released it.

    Three strategies:
    1. Watchdog-aware (preferred): if the env var COMFY_RESPAWN_BY is set
       (run.py / pm2 / systemd / nssm), just os._exit(0) — the watchdog will
       respawn after CUDA clears (it polls).
    2. Windows + no watchdog: spawn a tiny .bat helper that waits 5s, THEN
       launches the new ComfyUI. We exit immediately so the GPU isn't held
       during the wait window.
    3. POSIX + no watchdog: os.execv (in-place re-exec — kernel reclaims GPU
       as part of execve).
    """
    pid = os.getpid()
    argv = list(sys.argv)
    python = sys.executable
    cwd = os.getcwd()
    under_watchdog = bool(os.environ.get("COMFY_RESPAWN_BY") or os.environ.get("COMFY_KITCHEN_WATCHDOG"))
    _restart_log(f"restart requested. pid={pid} python={python!r} cwd={cwd!r} argv={argv!r} watchdog={under_watchdog}")

    async def _do_restart():
        await asyncio.sleep(0.3)
        # Free torch's GPU caches before exit so the new process has more headroom
        try:
            import torch
            if torch.cuda.is_available():
                torch.cuda.empty_cache()
                torch.cuda.synchronize()
                _restart_log("torch.cuda caches cleared + sync")
        except Exception as e:
            _restart_log(f"torch cleanup skipped: {e!r}")
        try:
            if under_watchdog:
                _restart_log("watchdog-aware exit; supervisor will respawn after CUDA clears")
                os._exit(0)
            elif os.name == "nt":
                import subprocess, tempfile
                _restart_log("spawning detached helper that waits 5s for CUDA to clear, then relaunches…")
                argv_quoted = " ".join(f'"{a}"' for a in argv)
                bat_lines = [
                    "@echo off",
                    "timeout /t 5 /nobreak > nul",
                    f'cd /d "{cwd}"',
                    f'"{python}" {argv_quoted}',
                ]
                helper = os.path.join(tempfile.gettempdir(), f"comfy_restart_{pid}.bat")
                with open(helper, "w", encoding="utf-8") as f:
                    f.write("\r\n".join(bat_lines))
                creationflags = (
                    getattr(subprocess, "DETACHED_PROCESS", 0x00000008)
                    | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0x00000200)
                    | getattr(subprocess, "CREATE_BREAKAWAY_FROM_JOB", 0x01000000)
                )
                subprocess.Popen(
                    ["cmd", "/c", helper],
                    cwd=cwd, env=dict(os.environ),
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    close_fds=True, creationflags=creationflags,
                )
                _restart_log(f"helper queued at {helper}; parent exiting now")
                os._exit(0)
            else:
                _restart_log("os.execv on POSIX")
                os.execv(python, [python] + argv)
        except Exception as exc:
            _restart_log(f"restart failed: {exc!r}; hard-exiting so a watchdog can restart")
            os._exit(0)

    asyncio.get_event_loop().create_task(_do_restart())
    return web.json_response({
        "ok": True, "message": "restart scheduled (~5s on Windows w/o watchdog)",
        "pid": pid, "argv": argv, "log": _restart_log_path(),
        "platform": "windows" if os.name == "nt" else "posix",
        "under_watchdog": under_watchdog,
    })


# ============================== LORA METADATA + HASH ==============================

def _read_safetensors_header(path: str):
    try:
        with open(path, "rb") as f:
            (n,) = struct.unpack("<Q", f.read(8))
            if n <= 0 or n > 100 * 1024 * 1024: return None
            header_bytes = f.read(n)
            header = json.loads(header_bytes.decode("utf-8", errors="replace"))
            return header.get("__metadata__", {}) or {}
    except Exception:
        return None


def _hash_files(path: str):
    h_full = hashlib.sha256(); h_body = hashlib.sha256()
    body_started = False; body_offset = 0
    try:
        with open(path, "rb") as f:
            head8 = f.read(8); h_full.update(head8)
            if len(head8) == 8:
                (n,) = struct.unpack("<Q", head8)
                rem = n
                while rem > 0:
                    chunk = f.read(min(CHUNK, rem))
                    if not chunk: break
                    h_full.update(chunk); rem -= len(chunk)
                body_started = True; body_offset = 8 + n
            while True:
                chunk = f.read(CHUNK)
                if not chunk: break
                h_full.update(chunk)
                if body_started: h_body.update(chunk)
    except Exception:
        return None
    return {"sha256": h_full.hexdigest(),
            "autov2": (h_body.hexdigest()[:10] if body_started else h_full.hexdigest()[:10]),
            "body_offset": body_offset}


_LORA_META_CACHE: dict = {}


def _extract_trigger_words(meta: dict):
    triggers = []; seen = set()
    try:
        raw = meta.get("ss_tag_frequency")
        if raw:
            tag_freq = json.loads(raw) if isinstance(raw, str) else raw
            agg = {}
            for _bucket, tags in tag_freq.items():
                if isinstance(tags, dict):
                    for t, c in tags.items():
                        agg[t] = agg.get(t, 0) + int(c or 0)
            for t, _c in sorted(agg.items(), key=lambda kv: -kv[1])[:20]:
                if t and t.lower() not in seen:
                    triggers.append(t); seen.add(t.lower())
    except Exception: pass
    try:
        raw = meta.get("ss_dataset_dirs")
        if raw:
            d = json.loads(raw) if isinstance(raw, str) else raw
            for k in (d or {}).keys():
                base = k.split("_", 1)[1] if ("_" in k and k.split("_", 1)[0].isdigit()) else k
                if base and base.lower() not in seen:
                    triggers.insert(0, base); seen.add(base.lower())
    except Exception: pass
    return triggers


async def _lora_meta_handler(request):
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    name = request.query.get("name","").strip()
    target = request.query.get("type","loras").strip().lower()
    if not name: return web.json_response({"error":"missing name"}, status=400)
    if target not in ALLOWED_TYPES: return web.json_response({"error":"invalid type"}, status=400)
    cache_key = f"{target}::{name}"
    if cache_key in _LORA_META_CACHE:
        return web.json_response(_LORA_META_CACHE[cache_key])
    path = _resolve_model_path(target, name)
    if not path:
        return web.json_response({"error": f"file not found: {name}"}, status=404)
    out = {"ok": True, "type": target, "name": name, "path": path,
           "size": os.path.getsize(path)}
    if path.lower().endswith(".safetensors"):
        meta = _read_safetensors_header(path) or {}
        out["metadata"] = meta
        out["triggers"] = _extract_trigger_words(meta)
    else:
        out["metadata"] = {}; out["triggers"] = []
    do_hash = request.query.get("hash","1").strip() not in ("0","false","no")
    if do_hash:
        size_cap_gb = 4
        force = request.query.get("force_hash","0").strip() in ("1","true","yes")
        if out["size"] > size_cap_gb * 1024**3 and not force:
            out["hash_skipped"] = f"file >{size_cap_gb} GB; pass force_hash=1"
        else:
            h = _hash_files(path)
            if h:
                out["sha256"] = h["sha256"]; out["autov2"] = h["autov2"]
    _LORA_META_CACHE[cache_key] = out
    return web.json_response(out)


# ============================== URL DOWNLOAD ==============================

_URL_DOWNLOADS: dict = {}


async def _from_url_handler(request):
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    try: body = await request.json()
    except Exception: return web.json_response({"error":"expected JSON body"}, status=400)
    url       = (body.get("url") or "").strip()
    target    = (body.get("type") or "").strip().lower()
    filename  = _safe_filename(body.get("filename") or "")
    subfolder = _safe_subfolder(body.get("subfolder") or "")
    overwrite = bool(body.get("overwrite"))
    api_key   = (body.get("api_key") or "").strip()
    job_id    = (body.get("job_id") or "").strip() or f"dl_{int(__import__('time').time()*1000)}"
    if not url or not url.lower().startswith(("http://","https://")):
        return web.json_response({"error":"url must be http(s)"}, status=400)
    if target not in ALLOWED_TYPES: return web.json_response({"error":f"invalid type {target!r}"}, status=400)
    if not filename: return web.json_response({"error":"missing filename"}, status=400)
    dest_dir = _resolve_dest_dir(target, subfolder)
    if not dest_dir: return web.json_response({"error":f"no folder configured for {target!r}"}, status=400)
    dest = os.path.join(dest_dir, filename)
    if os.path.exists(dest) and not overwrite:
        return web.json_response({"error":"file already exists","path":dest,
                                   "size":os.path.getsize(dest),"hint":"send overwrite=1"}, status=409)
    state = {"job_id":job_id,"url":url,"dest":dest,"tmp":dest+".part",
             "type":target,"filename":filename,"subfolder":subfolder,
             "downloaded":0,"total":0,"status":"queued","error":None,
             "started_at":__import__('time').time(),"finished_at":None}
    _URL_DOWNLOADS[job_id] = state

    async def _do_download():
        import aiohttp
        state["status"] = "running"
        is_civitai = "civitai.com" in url
        # Civitai-specific auth: prefer ?token=KEY in the URL over the Bearer
        # header — civitai.com 302-redirects to R2/CloudFront and aiohttp
        # forwards Authorization across domains by default, which the CDN
        # then rejects. Manually controlling redirects + dropping the header
        # when the host changes is the most robust fix.
        eff_url = url
        if api_key and is_civitai and "token=" not in url:
            sep = "&" if "?" in eff_url else "?"
            eff_url = f"{eff_url}{sep}token={api_key}"
        # Header is only useful for civitai.com itself (read scope on /api/v1).
        # We DO send it, but we also strip it when following redirects to a
        # different host so the CDN doesn't 401.
        initial_headers = {"User-Agent": "wifemaker-uploader/1.0"}
        if api_key and is_civitai:
            initial_headers["Authorization"] = f"Bearer {api_key}"
        # Optional cookie auth for creator-gated assets — some Civitai
        # creators require web session login even with an API key. The
        # caller can pass `civitai_cookie` in the body (the value of the
        # `__Secure-civitai-token` cookie from a logged-in browser).
        cookie_val = (body.get("civitai_cookie") or "").strip()
        if cookie_val and is_civitai:
            initial_headers["Cookie"] = f"__Secure-civitai-token={cookie_val}"
        # Caller-supplied request headers (used by wifemaker's /api/sync-relay
        # to forward CF-Access-Client-Id / -Secret when the TARGET pulls a
        # file from another CF-tunneled comfy server — without these the
        # source's tunnel returns 403). These are preserved on same-host
        # redirects but stripped on cross-host hops, same policy as
        # Authorization/Cookie above.
        extra_headers = body.get("headers") or {}
        if isinstance(extra_headers, dict):
            for k, v in extra_headers.items():
                if v in (None, ""): continue
                try: initial_headers[str(k)] = str(v)
                except Exception: pass
        try:
            from urllib.parse import urlparse
            timeout = aiohttp.ClientTimeout(total=None, connect=30, sock_read=600)
            connector = aiohttp.TCPConnector(force_close=True)
            async with aiohttp.ClientSession(timeout=timeout, connector=connector) as sess:
                cur_url = eff_url
                cur_headers = dict(initial_headers)
                cur_host = urlparse(cur_url).netloc
                # Manual redirect chain (max 8 hops). Auth headers are dropped
                # on cross-host redirects.
                final_resp = None
                for _hop in range(8):
                    resp = await sess.get(cur_url, headers=cur_headers,
                                           allow_redirects=False)
                    if resp.status in (301, 302, 303, 307, 308):
                        loc = resp.headers.get("Location") or ""
                        await resp.release()
                        if not loc:
                            raise RuntimeError(f"redirect with no Location at {cur_url}")
                        # Resolve relative URLs
                        from urllib.parse import urljoin
                        new_url = urljoin(cur_url, loc)
                        new_host = urlparse(new_url).netloc
                        if new_host != cur_host:
                            # Cross-host: drop Authorization + Cookie so the
                            # CDN doesn't 401. Keep User-Agent only.
                            cur_headers = {"User-Agent": initial_headers["User-Agent"]}
                            cur_host = new_host
                        cur_url = new_url
                        continue
                    final_resp = resp
                    break
                if final_resp is None:
                    raise RuntimeError("redirect loop")
                async with final_resp:
                    if final_resp.status >= 400:
                        body_snip = (await final_resp.text())[:300]
                        # Friendlier 401 message — usually means the asset is
                        # creator-locked (requires web login) rather than
                        # "your API key is wrong".
                        if final_resp.status == 401 and "creator" in body_snip.lower():
                            raise RuntimeError(
                                "HTTP 401: this Civitai model is creator-gated "
                                "(requires web session login, not just an API "
                                "key). Pass civitai_cookie={value of "
                                "__Secure-civitai-token from a logged-in browser} "
                                "to bypass, or pick a non-gated model.")
                        raise RuntimeError(f"HTTP {final_resp.status}: {body_snip}")
                    cl = final_resp.headers.get("Content-Length")
                    if cl: state["total"] = int(cl)
                    with open(state["tmp"], "wb") as f:
                        async for chunk in final_resp.content.iter_chunked(CHUNK):
                            f.write(chunk)
                            state["downloaded"] += len(chunk)
            os.replace(state["tmp"], state["dest"])
            state["total"] = os.path.getsize(state["dest"])
            state["status"] = "done"
        except Exception as exc:
            state["status"] = "error"; state["error"] = str(exc)
            try:
                if os.path.exists(state["tmp"]): os.remove(state["tmp"])
            except Exception: pass
        finally:
            state["finished_at"] = __import__('time').time()

    asyncio.get_event_loop().create_task(_do_download())
    return web.json_response({"ok": True, "job_id": job_id, "status": "queued"})


async def _from_url_status_handler(request):
    job_id = request.query.get("job_id","").strip()
    if not job_id: return web.json_response({"error":"missing job_id"}, status=400)
    state = _URL_DOWNLOADS.get(job_id)
    if not state: return web.json_response({"ok": True, "found": False})
    import time as _t
    return web.json_response({"ok": True, "found": True,
        "job_id": job_id, "status": state["status"],
        "downloaded": state["downloaded"], "total": state["total"],
        "filename": state["filename"], "type": state["type"], "error": state["error"],
        "elapsed_sec": round((_t.time() if state["finished_at"] is None else state["finished_at"]) - state["started_at"], 1)})


async def _serve_handler(request):
    """GET /upload/model/serve?type=<t>&name=<n>
    Streams a model file out. Used by wifemaker's /api/sync-relay to pull
    bytes from a source server into a target server.

    Why we don't just use web.FileResponse: aiohttp's FileResponse on Windows
    calls Win32 TransmitFile() via asyncio.proactor's sendfile, which BLOWS
    UP with [WinError 87: parameter is incorrect] for any file larger than
    ~2 GB (it's an asyncio.windows_events bug — the count int overflows).
    The exception fires AFTER headers are sent, so the client sees an EOF
    at byte 0 instead of a graceful 5xx. That's exactly what was killing
    the 3.8 GB checkpoint syncs.

    Fix: bypass FileResponse entirely. Use StreamResponse + manual chunked
    read on Windows (and for any file >= 1.5 GB elsewhere for safety).
    Small files still use FileResponse so we keep its Range / If-Modified
    handling on the common path."""
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    target = request.query.get("type","").strip().lower()
    name = request.query.get("name","").strip()
    if target not in ALLOWED_TYPES: return web.json_response({"error":"invalid type"}, status=400)
    safe_name = _safe_filename(name)
    if not safe_name: return web.json_response({"error":"invalid name"}, status=400)
    path = _resolve_model_path(target, safe_name)
    if not path: return web.json_response({"error":"not found"}, status=404)

    try: size = os.path.getsize(path)
    except Exception: size = 0

    # 2 GB threshold on Windows; 4 GB elsewhere (Linux sendfile is fine but
    # we hedge — the relay also benefits from explicit chunk pacing on huge
    # files because it lets us catch socket errors mid-stream).
    BIG = 2 * 1024 * 1024 * 1024 if os.name == "nt" else 4 * 1024 * 1024 * 1024
    if size < BIG:
        return web.FileResponse(path, headers={
            "Content-Disposition": f'attachment; filename="{safe_name}"',
        })

    # Manual stream for big files
    headers = {
        "Content-Type": "application/octet-stream",
        "Content-Length": str(size),
        "Content-Disposition": f'attachment; filename="{safe_name}"',
        "Cache-Control": "no-store",
    }
    resp = web.StreamResponse(status=200, reason="OK", headers=headers)
    resp.enable_chunked_encoding() if False else None  # explicit Content-Length, no chunked TE
    await resp.prepare(request)
    READ_CHUNK = 1024 * 1024  # 1 MB
    try:
        with open(path, "rb") as f:
            while True:
                buf = f.read(READ_CHUNK)
                if not buf: break
                await resp.write(buf)
        await resp.write_eof()
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        # Client gave up mid-stream — log + bail
        try:
            print(f"[comfy_model_uploader] /serve stream cancelled for {safe_name}", flush=True)
        except Exception: pass
    except Exception as e:
        try:
            print(f"[comfy_model_uploader] /serve stream error for {safe_name}: {e}", flush=True)
        except Exception: pass
    return resp


async def _civitai_search_handler(request):
    """Server-side Civitai search proxy. Avoids browser→Civitai CORS issues."""
    import aiohttp
    api_key = request.headers.get("X-Civitai-Key","").strip()
    qs = request.query_string
    target = f"https://civitai.com/api/v1/models?{qs}" if qs else "https://civitai.com/api/v1/models"
    headers = {"Accept":"application/json", "User-Agent":"comfy_model_uploader/7"}
    if api_key: headers["Authorization"] = f"Bearer {api_key}"
    try:
        timeout = aiohttp.ClientTimeout(total=30)
        async with aiohttp.ClientSession(timeout=timeout) as sess:
            async with sess.get(target, headers=headers) as resp:
                body = await resp.read()
                return web.Response(body=body, status=resp.status,
                                     headers={"Content-Type": resp.headers.get("Content-Type","application/json")})
    except Exception as exc:
        return web.json_response({"error": f"upstream: {exc}"}, status=502)


# ============================== REGISTRATION ==============================

async def _cleanup_partials_handler(request):
    """POST /upload/model/cleanup_partials [{type, min_age_min}]
    Deletes orphan .part files older than `min_age_min` minutes (default 10)
    from each configured model folder. Returns the list of files removed.
    Useful after a CF timeout / ComfyUI restart leaves dangling tmp files."""
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    try: body = await request.json()
    except Exception: body = {}
    only_type = (body.get("type") or "").strip().lower()
    try: min_age_min = max(0, int(body.get("min_age_min", 10)))
    except Exception: min_age_min = 10
    targets = [only_type] if only_type in ALLOWED_TYPES else sorted(ALLOWED_TYPES)
    import time as _t
    cutoff = _t.time() - (min_age_min * 60)
    active_tmps = {st.get("tmp") for st in _URL_DOWNLOADS.values()
                   if st.get("status") in ("queued","running")}
    removed = []
    failed = []
    for t in targets:
        try: roots = folder_paths.get_folder_paths(t)
        except Exception: roots = []
        for root in roots:
            if not (root and os.path.isdir(root)): continue
            for dirpath, _dirs, files in os.walk(root):
                for fn in files:
                    if not fn.endswith(".part"): continue
                    full = os.path.join(dirpath, fn)
                    if full in active_tmps: continue
                    try: mtime = os.path.getmtime(full)
                    except Exception: continue
                    if mtime > cutoff: continue
                    try:
                        sz = os.path.getsize(full)
                        os.remove(full)
                        removed.append({"path": full, "size": sz, "type": t,
                                         "age_min": round((_t.time()-mtime)/60, 1)})
                    except Exception as e:
                        failed.append({"path": full, "error": str(e)})
    return web.json_response({"ok": True, "removed": removed, "failed": failed,
                               "total_freed_bytes": sum(r["size"] for r in removed),
                               "min_age_min": min_age_min, "active_tmps_skipped": len(active_tmps)})


async def _cleanup_outputs_handler(request):
    """POST /upload/model/cleanup_outputs [{keep_last_n, min_age_min, dry_run, subdir}]
    Walks ComfyUI's output/ folder recursively, keeps the newest `keep_last_n`
    image files (default 100) plus anything younger than `min_age_min` minutes
    (default 30 — safety so freshly-generated images can still be fetched by
    the wifemaker/waifumaster client before deletion), and removes the rest.
    Returns a summary + first 20 deleted paths.

    Safe extensions only: .png .jpg .jpeg .webp .gif .mp4 .webm .json
    Dry-run mode (dry_run=true) reports what would be deleted without acting."""
    if folder_paths is None:
        return web.json_response({"error":"folder_paths unavailable"}, status=500)
    try: body = await request.json()
    except Exception: body = {}
    try: keep_last_n = max(0, int(body.get("keep_last_n", 100)))
    except Exception: keep_last_n = 100
    try: min_age_min = max(0, int(body.get("min_age_min", 30)))
    except Exception: min_age_min = 30
    dry_run = bool(body.get("dry_run", False))
    subdir_filter = (body.get("subdir") or "").strip()

    SAFE_EXTS = {".png", ".jpg", ".jpeg", ".webp", ".gif", ".mp4", ".webm",
                 ".json"}

    try:
        output_dir = folder_paths.get_output_directory()
    except Exception:
        return web.json_response({"error":"output_directory unavailable"}, status=500)

    if not (output_dir and os.path.isdir(output_dir)):
        return web.json_response({"error": f"output dir not found: {output_dir!r}"}, status=500)

    import time as _t
    cutoff_age = _t.time() - (min_age_min * 60)

    candidates = []
    for dirpath, _dirs, files in os.walk(output_dir):
        if subdir_filter and subdir_filter not in dirpath:
            continue
        for fn in files:
            ext = os.path.splitext(fn)[1].lower()
            if ext not in SAFE_EXTS: continue
            full = os.path.join(dirpath, fn)
            try:
                mtime = os.path.getmtime(full)
                size = os.path.getsize(full)
            except Exception:
                continue
            candidates.append((mtime, full, size))

    candidates.sort(key=lambda r: r[0], reverse=True)

    keep_set = set()
    for mtime, full, size in candidates[:keep_last_n]:
        keep_set.add(full)
    for mtime, full, size in candidates:
        if mtime > cutoff_age:
            keep_set.add(full)

    deletable = [(m, f, s) for (m, f, s) in candidates if f not in keep_set]

    removed = []
    failed = []
    total_freed = 0
    for mtime, full, size in deletable:
        rel = os.path.relpath(full, output_dir)
        if dry_run:
            removed.append({
                "path": rel, "size": size,
                "age_min": round((_t.time() - mtime) / 60, 1),
                "dry_run": True,
            })
            total_freed += size
        else:
            try:
                os.remove(full)
                removed.append({
                    "path": rel, "size": size,
                    "age_min": round((_t.time() - mtime) / 60, 1),
                })
                total_freed += size
            except Exception as e:
                failed.append({"path": rel, "error": str(e)})

    # Clean empty subdirs
    if not dry_run:
        for dirpath, dirs, files in os.walk(output_dir, topdown=False):
            if dirpath == output_dir: continue
            try:
                if not os.listdir(dirpath):
                    os.rmdir(dirpath)
            except Exception:
                pass

    return web.json_response({
        "ok": True,
        "output_dir": output_dir,
        "scanned": len(candidates),
        "kept": len(keep_set),
        "removed_count": len(removed),
        "failed_count": len(failed),
        "total_freed_bytes": total_freed,
        "total_freed_mb": round(total_freed / 1024 / 1024, 1),
        "removed_sample": removed[:20],
        "failed": failed[:20],
        "dry_run": dry_run,
        "policy": {
            "keep_last_n": keep_last_n,
            "min_age_min": min_age_min,
            "subdir_filter": subdir_filter,
        },
    })


# Background auto-cleanup. Runs every 6 hours; keeps last 100 + anything < 30min old.
_AUTO_CLEANUP_INTERVAL_SEC = 6 * 3600
_AUTO_CLEANUP_KEEP_LAST = 100
_AUTO_CLEANUP_MIN_AGE_MIN = 30


async def _auto_cleanup_loop():
    """Background task — periodically prunes output/ to keep last 100 images."""
    await asyncio.sleep(120)
    while True:
        try:
            if folder_paths is not None:
                output_dir = folder_paths.get_output_directory()
                if output_dir and os.path.isdir(output_dir):
                    import time as _t
                    cutoff = _t.time() - (_AUTO_CLEANUP_MIN_AGE_MIN * 60)
                    candidates = []
                    for dirpath, _dirs, files in os.walk(output_dir):
                        for fn in files:
                            ext = os.path.splitext(fn)[1].lower()
                            if ext not in {".png", ".jpg", ".jpeg", ".webp",
                                           ".gif", ".mp4", ".webm", ".json"}:
                                continue
                            full = os.path.join(dirpath, fn)
                            try: mtime = os.path.getmtime(full)
                            except Exception: continue
                            candidates.append((mtime, full))
                    candidates.sort(key=lambda r: r[0], reverse=True)
                    keep = set(f for _, f in candidates[:_AUTO_CLEANUP_KEEP_LAST])
                    keep.update(f for m, f in candidates if m > cutoff)
                    removed = 0
                    freed = 0
                    for _m, full in candidates:
                        if full in keep: continue
                        try:
                            sz = os.path.getsize(full)
                            os.remove(full)
                            removed += 1
                            freed += sz
                        except Exception: pass
                    if removed > 0:
                        print(f"[comfy_model_uploader] auto-cleanup: removed {removed} files, freed {freed/1024/1024:.1f}MB from {output_dir}", flush=True)
        except Exception as e:
            print(f"[comfy_model_uploader] auto-cleanup error: {e}", flush=True)
        await asyncio.sleep(_AUTO_CLEANUP_INTERVAL_SEC)


async def _from_url_jobs_handler(_request):
    """GET /upload/model/from_url/jobs → list every download job seen (running + finished)."""
    import time as _t
    out = []
    now = _t.time()
    for jid, st in list(_URL_DOWNLOADS.items()):
        out.append({
            "job_id": jid, "status": st["status"],
            "filename": st["filename"], "type": st["type"],
            "downloaded": st["downloaded"], "total": st["total"],
            "error": st["error"],
            "started_at": st["started_at"],
            "elapsed_sec": round((st["finished_at"] or now) - st["started_at"], 1),
        })
    return web.json_response({"ok": True, "jobs": out, "count": len(out)})


async def _addon_upload_handler(request):
    """POST /upload/addon (multipart)
    Fields:
      name       — addon folder name (must be safe; alpha/num/dash/underscore only)
      tarball    — the .tar.gz file content (the WHOLE addon dir, with __init__.py inside)
      restart    — "1" / "true" to auto-restart ComfyUI after extraction

    Behavior:
      • Extracts tarball into <ComfyUI>/custom_nodes/<name>/ (overwrites)
      • Creates a backup at custom_nodes/<name>.bak.<timestamp>/ first
      • Optionally schedules a watchdog-aware restart via _restart_handler
    Used by waifumaster admin's "Sync uploader to fleet" button — the
    dev-box edits the addon locally, tests on its own ComfyUI, then
    pushes the working version to every fleet server with one click."""
    if folder_paths is None:
        return web.json_response({"error": "folder_paths unavailable"}, status=500)
    try:
        comfy_root = os.path.dirname(os.path.dirname(os.path.abspath(folder_paths.__file__)))
    except Exception:
        return web.json_response({"error": "couldn't locate ComfyUI root"}, status=500)
    custom_nodes_dir = os.path.join(comfy_root, "custom_nodes")
    if not os.path.isdir(custom_nodes_dir):
        return web.json_response({"error": f"custom_nodes dir not found: {custom_nodes_dir}"}, status=500)

    reader = await request.multipart()
    name = ""
    tar_bytes = b""
    restart_after = False
    while True:
        field = await reader.next()
        if field is None: break
        if field.name == "name":
            name = (await field.text()).strip()
        elif field.name == "restart":
            restart_after = (await field.text()).strip() in ("1", "true", "yes", "on")
        elif field.name == "tarball":
            buf = b""
            while True:
                chunk = await field.read_chunk(CHUNK)
                if not chunk: break
                buf += chunk
            tar_bytes = buf
            break

    # Validate name — only safe chars to prevent path traversal
    import re as _re
    if not name or not _re.match(r'^[A-Za-z0-9_\-]+$', name):
        return web.json_response({"error": "invalid name (alphanumeric + dash + underscore only)"}, status=400)
    if not tar_bytes:
        return web.json_response({"error": "no tarball uploaded"}, status=400)

    import io as _io, tarfile as _tarfile, time as _t, shutil as _shutil
    target = os.path.join(custom_nodes_dir, name)
    backup = os.path.join(custom_nodes_dir, f"{name}.bak.{int(_t.time())}")

    # Extract to a tmp dir first, then atomic-rename
    tmp_extract = os.path.join(custom_nodes_dir, f".{name}.staging.{int(_t.time())}")
    try:
        os.makedirs(tmp_extract, exist_ok=True)
        with _tarfile.open(fileobj=_io.BytesIO(tar_bytes), mode="r:gz") as tf:
            # Sanity check — refuse if any member tries to escape via .. or absolute path
            for m in tf.getmembers():
                if m.name.startswith("/") or ".." in m.name.split("/"):
                    raise RuntimeError(f"refusing tarball member with traversal: {m.name}")
            tf.extractall(tmp_extract)
        # Tarball usually has the addon dir as the root, e.g. comfy_model_uploader/__init__.py.
        # Detect that and unwrap one level if needed so we end up with __init__.py directly under target.
        entries = os.listdir(tmp_extract)
        if len(entries) == 1 and os.path.isdir(os.path.join(tmp_extract, entries[0])):
            inner = os.path.join(tmp_extract, entries[0])
            if os.path.isfile(os.path.join(inner, "__init__.py")):
                # Move inner contents up to tmp_extract
                for sub in os.listdir(inner):
                    _shutil.move(os.path.join(inner, sub), os.path.join(tmp_extract, sub))
                os.rmdir(inner)
        if not os.path.isfile(os.path.join(tmp_extract, "__init__.py")):
            raise RuntimeError("tarball missing __init__.py at the top level")

        # Backup existing then swap
        if os.path.isdir(target):
            try: _shutil.rmtree(backup, ignore_errors=True)
            except Exception: pass
            os.rename(target, backup)
        os.rename(tmp_extract, target)
    except Exception as e:
        # Cleanup tmp on failure
        try: _shutil.rmtree(tmp_extract, ignore_errors=True)
        except Exception: pass
        return web.json_response({"error": f"extract failed: {e}", "name": name}, status=500)

    # Count installed files
    file_count = 0
    total_bytes = 0
    for dirpath, _dirs, files in os.walk(target):
        for fn in files:
            file_count += 1
            try: total_bytes += os.path.getsize(os.path.join(dirpath, fn))
            except Exception: pass

    resp = {
        "ok": True,
        "name": name,
        "path": target,
        "backup": backup if os.path.isdir(backup) else None,
        "files_installed": file_count,
        "total_bytes": total_bytes,
        "restart_scheduled": False,
    }

    if restart_after:
        # Reuse the existing restart machinery (same as _restart_handler)
        try:
            argv = list(sys.argv)
            pid = os.getpid()
            asyncio.get_event_loop().create_task(_schedule_restart(pid, argv))
            resp["restart_scheduled"] = True
        except Exception as e:
            resp["restart_error"] = str(e)

    return web.json_response(resp)


async def _schedule_restart(pid: int, argv):
    """Schedule a ComfyUI restart ~3 seconds out so the HTTP response can return first."""
    await asyncio.sleep(3)
    try:
        import platform
        if platform.system() == "Windows":
            os.execv(sys.executable, [sys.executable] + argv)
        else:
            os.execv(sys.executable, [sys.executable] + argv)
    except Exception as e:
        print(f"[comfy_model_uploader] addon-triggered restart failed: {e}", flush=True)


def _register_routes():
    if PromptServer is None or PromptServer.instance is None:
        return False
    routes = PromptServer.instance.routes
    routes.post("/upload/model")(_upload_handler)
    routes.post("/upload/model/chunk")(_chunk_handler)
    routes.get("/upload/model/chunk_status")(_chunk_status_handler)
    routes.get("/upload/model/info")(_info_handler)
    routes.get("/upload/model/list")(_list_handler)
    routes.post("/upload/model/refresh")(_refresh_handler)
    routes.post("/upload/model/restart")(_restart_handler)
    routes.get("/upload/model/lora_meta")(_lora_meta_handler)
    routes.post("/upload/model/from_url")(_from_url_handler)
    routes.get("/upload/model/from_url/status")(_from_url_status_handler)
    routes.get("/upload/model/from_url/jobs")(_from_url_jobs_handler)
    routes.post("/upload/model/cleanup_partials")(_cleanup_partials_handler)
    routes.post("/upload/model/cleanup_outputs")(_cleanup_outputs_handler)
    routes.get("/upload/model/serve")(_serve_handler)
    routes.get("/upload/model/civitai/search")(_civitai_search_handler)
    routes.post("/upload/addon")(_addon_upload_handler)

    # Kick off the background output-prune loop (keeps last 100 PNGs in output/)
    try:
        loop = asyncio.get_event_loop()
        loop.create_task(_auto_cleanup_loop())
        print("[comfy_model_uploader] auto-cleanup loop started (every 6h, keep last 100)", flush=True)
    except Exception as e:
        print(f"[comfy_model_uploader] couldn't start auto-cleanup loop: {e}", flush=True)
    return True


_registered = _register_routes()
print(f"[comfy_model_uploader] routes registered: {_registered} (uploader_version=10, supports chunked_upload + restart_v3 + from_url + serve + civitai_proxy + watchdog_aware + cleanup_partials + cleanup_outputs + auto_cleanup + addon_upload)")

NODE_CLASS_MAPPINGS = {}
NODE_DISPLAY_NAME_MAPPINGS = {}
