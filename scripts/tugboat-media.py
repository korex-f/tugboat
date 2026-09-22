#!/usr/bin/env python3
"""yt-dlp media jobs for Tugboat. Jobs are persisted for Quickshell polling."""
import argparse
import json
import os
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "tugboat"
JOBS = ROOT / "media-jobs.json"
CLOUD_STDERR_LIMIT = 16 * 1024
CLOUD_ERROR_LIMIT = 2048
CLOUD_TIMEOUT_SECONDS = 24 * 60 * 60


def emit(value): print(json.dumps(value, separators=(",", ":")))
def load_jobs():
    try: return json.loads(JOBS.read_text())
    except (OSError, json.JSONDecodeError): return {}
def save_jobs(jobs):
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    temporary = JOBS.with_suffix(".tmp")
    temporary.write_text(json.dumps(jobs)); temporary.replace(JOBS)
def dependency_error():
    try:
        import yt_dlp  # noqa: F401
    except ImportError:
        return "yt-dlp Python package is not installed. Install yt-dlp, then reopen Tugboat."
    if not shutil.which("ffmpeg"):
        return "ffmpeg is required for video/audio stream merging. Install ffmpeg, then reopen Tugboat."
    return None
def cloud_dependency_error():
    if not shutil.which("rclone"):
        return "Cloud folders require rclone. Install rclone, run 'rclone config', then add cloud:remote:path."
    return None
def cloud_timeout_seconds():
    try: return max(1, int(os.environ.get("TUGBOAT_CLOUD_TIMEOUT_SECONDS", CLOUD_TIMEOUT_SECONDS)))
    except ValueError: return CLOUD_TIMEOUT_SECONDS
def signal_job_groups(job, signum):
    delivered, groups = False, set()
    for value in (job.get("pid"), job.get("transferPgid")):
        try:
            group = os.getpgid(int(value or 0))
            if group not in groups:
                os.killpg(group, signum); groups.add(group)
            delivered = True
        except (ProcessLookupError, ValueError): pass
    return delivered
def stop_process_group(process):
    try: os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError: pass
    try: process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try: os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError: pass
        process.wait()
def bounded_error(data):
    text = bytes(data).decode("utf-8", "replace").strip()
    return text[:CLOUD_ERROR_LIMIT]
def public_formats(info):
    entries = info.get("entries") or []
    info = next((entry for entry in entries if entry), info)
    seen, out = set(), []
    for fmt in info.get("formats", []):
        height = fmt.get("height")
        if not height or height in seen: continue
        seen.add(height)
        out.append({"id": str(height), "label": f"{height}p"})
    return sorted(out, key=lambda x: int(x["id"]), reverse=True)[:6]

def playlist_details(info):
    entries = [entry for entry in (info.get("entries") or []) if entry]
    return bool(entries or info.get("_type") == "playlist"), len(entries)
def check(_):
    error = dependency_error()
    emit({"ok": not bool(error), "error": error or ""})
def is_media_site(url):
    from yt_dlp.extractor import gen_extractors
    return any(ie.IE_NAME.lower() != "generic" and ie.suitable(url) for ie in gen_extractors())
def inspect(url):
    error = dependency_error()
    if error: emit({"ok": False, "error": error}); return
    import yt_dlp
    recognised = is_media_site(url)
    try:
        with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True, "noplaylist": False}) as ydl:
            info = ydl.extract_info(url, download=False)
        if not info or info.get("extractor_key") == "Generic":
            emit({"ok": True, "media": False}); return
        playlist, entry_count = playlist_details(info)
        emit({"ok": True, "media": True, "title": info.get("title", url), "formats": public_formats(info), "playlist": playlist, "entryCount": entry_count})
    except Exception as exc:
        if recognised:
            emit({"ok": False, "error": "yt-dlp could not extract this media URL: " + str(exc)})
        else:
            emit({"ok": True, "media": False})
def worker(job_id):
    jobs = load_jobs(); job = jobs.get(job_id)
    if not job: return
    def update(status, **values):
        current = load_jobs(); item = current.get(job_id, {})
        item.update(values); item["status"] = status; item["updated"] = time.time()
        current[job_id] = item; save_jobs(current)
    if job.get("kind") == "cloud":
        process = None
        try:
            timeout = cloud_timeout_seconds()
            process = subprocess.Popen(
                ["rclone", "copy", job["source"], job["directory"], "--create-empty-src-dirs", "--stats=0", "--log-level=ERROR"],
                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True,
            )
            # rclone has its own session so a backend cannot outlive a timed-out
            # worker. Keep its PGID for pause/resume/remove as well.
            update("active", filename=job["source"], transferPgid=process.pid)
            captured, timed_out, overflowed, stderr_open = bytearray(), False, False, True
            deadline = time.monotonic() + timeout
            while stderr_open or process.poll() is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True; break
                readable, _, _ = select.select([process.stderr], [], [], min(0.25, remaining))
                if not readable: continue
                chunk = os.read(process.stderr.fileno(), 4096)
                if not chunk:
                    stderr_open = False; continue
                available = CLOUD_STDERR_LIMIT - len(captured)
                captured.extend(chunk[:max(0, available)])
                if len(chunk) > available:
                    overflowed = True; break
            if timed_out or overflowed:
                stop_process_group(process)
                reason = "Cloud copy timed out after " + str(timeout) + " seconds" if timed_out else "Cloud copy produced too much error output"
                detail = bounded_error(captured)
                update("error", error=(reason + (": " + detail if detail else ""))[:CLOUD_ERROR_LIMIT], speed=0, transferPgid=0)
            else:
                result = process.wait()
                message = bounded_error(captured)
                if result:
                    update("error", error=message or "rclone could not copy this cloud folder", speed=0, transferPgid=0)
                else:
                    update("complete", speed=0, transferPgid=0)
            process.stderr.close()
        except Exception as exc:
            if process and process.poll() is None: stop_process_group(process)
            if process and process.stderr: process.stderr.close()
            update("error", error=str(exc)[:CLOUD_ERROR_LIMIT], speed=0, transferPgid=0)
        return
    import yt_dlp
    def hook(data):
        state = data.get("status")
        if state == "downloading":
            update("active", downloaded=int(data.get("downloaded_bytes") or 0), total=int(data.get("total_bytes") or data.get("total_bytes_estimate") or 0), speed=int(data.get("speed") or 0), eta=int(data.get("eta") or 0), filename=data.get("filename") or job.get("filename", ""))
        elif state == "finished": update("processing", filename=data.get("filename") or job.get("filename", ""))
    fmt = job["format"]
    selector = "bestaudio/best" if fmt == "audio" else (f"bestvideo[height<={fmt}]+bestaudio/best[height<={fmt}]" if fmt.isdigit() else "bestvideo+bestaudio/best")
    playlist = bool(job.get("playlist"))
    filename_template = "%(playlist_title).200B/%(playlist_index)02d. %(title).200B.%(ext)s" if playlist else "%(title).200B.%(ext)s"
    options = {
        "format": selector, "noplaylist": not playlist, "quiet": True,
        "outtmpl": str(Path(job["directory"]) / filename_template),
        "progress_hooks": [hook], "merge_output_format": "mkv",
        # yt-dlp delegates media HTTP transfers to aria2c, retaining its
        # segmented downloader behaviour without changing Tugboat's RPC daemon.
        "external_downloader": {"default": "aria2c"},
        "external_downloader_args": {"aria2c": ["--file-allocation=none", "--summary-interval=0"]},
    }
    try:
        update("active")
        with yt_dlp.YoutubeDL(options) as ydl: ydl.download([job["url"]])
        update("complete", downloaded=job.get("total", job.get("downloaded", 0)), speed=0, eta=0)
    except Exception as exc:
        update("error", error=str(exc), speed=0)
def start(args):
    error = dependency_error()
    if error: emit({"ok": False, "error": error}); return
    job_id = uuid.uuid4().hex[:12]
    job = {"id": job_id, "url": args.url, "title": args.title or args.url, "format": args.format, "playlist": args.playlist, "directory": os.path.expanduser(args.directory or "~/Downloads"), "status": "queued", "downloaded": 0, "total": 0, "speed": 0, "eta": 0, "created": time.time()}
    jobs = load_jobs(); jobs[job_id] = job; save_jobs(jobs)
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", job_id], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    job["pid"] = process.pid; jobs[job_id] = job; save_jobs(jobs)
    emit({"ok": True, "id": job_id})
def start_cloud(args):
    error = cloud_dependency_error()
    if error: emit({"ok": False, "error": error}); return
    source = args.source.strip()
    if ":" not in source or source.startswith(":"):
        emit({"ok": False, "error": "Use a configured rclone path such as cloud:onedrive:Shared/Folder."}); return
    job_id = uuid.uuid4().hex[:12]
    job = {"id": job_id, "kind": "cloud", "source": source, "title": source, "directory": os.path.expanduser(args.directory or "~/Downloads"), "status": "queued", "downloaded": 0, "total": 0, "speed": 0, "eta": 0, "created": time.time()}
    jobs = load_jobs(); jobs[job_id] = job; save_jobs(jobs)
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", job_id], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    job["pid"] = process.pid; jobs[job_id] = job; save_jobs(jobs)
    emit({"ok": True, "id": job_id})
def status(_):
    items = []
    for item in load_jobs().values():
        filename = item.get("filename") or item.get("title") or item.get("url", item.get("source", ""))
        items.append({"gid": "yt:" + item["id"], "status": item.get("status", "queued"), "totalLength": str(item.get("total", 0)), "completedLength": str(item.get("downloaded", 0)), "downloadSpeed": str(item.get("speed", 0)), "files": [{"path": filename}], "media": item.get("kind") != "cloud", "cloud": item.get("kind") == "cloud", "formatLabel": item.get("format", "best"), "errorMessage": item.get("error", "")})
    emit({"ok": True, "items": items})
def action(args):
    jobs = load_jobs()
    if args.action == "resume-all":
        for job in jobs.values():
            if job.get("status") == "paused":
                if signal_job_groups(job, signal.SIGCONT): job["status"] = "active"
        save_jobs(jobs); emit({"ok": True}); return
    if args.action == "clear-finished":
        for job_id in list(jobs):
            if jobs[job_id].get("status") in ("complete", "error"):
                del jobs[job_id]
        save_jobs(jobs); emit({"ok": True}); return
    job = jobs.get(args.id)
    if not job: emit({"ok": False, "error": "Media job not found"}); return
    if args.action == "pause" and signal_job_groups(job, signal.SIGSTOP): job["status"] = "paused"
    elif args.action == "resume" and signal_job_groups(job, signal.SIGCONT): job["status"] = "active"
    elif args.action == "remove":
        signal_job_groups(job, signal.SIGTERM)
        del jobs[args.id]; save_jobs(jobs); emit({"ok": True}); return
    else: emit({"ok": False, "error": "Media worker is no longer running"}); return
    jobs[args.id] = job; save_jobs(jobs); emit({"ok": True})
def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="cmd", required=True)
    x = sub.add_parser("inspect"); x.add_argument("url")
    x = sub.add_parser("start"); x.add_argument("url"); x.add_argument("--title"); x.add_argument("--format", default="best"); x.add_argument("--playlist", action="store_true"); x.add_argument("--directory")
    x = sub.add_parser("cloud"); x.add_argument("source"); x.add_argument("--directory")
    sub.add_parser("status")
    sub.add_parser("check")
    x = sub.add_parser("action"); x.add_argument("action", choices=["pause", "resume", "remove", "resume-all", "clear-finished"]); x.add_argument("id", nargs="?")
    x = sub.add_parser("worker"); x.add_argument("id")
    args = parser.parse_args(); {"inspect": lambda value: inspect(value.url), "start": start, "cloud": start_cloud, "status": status, "check": check, "action": action, "worker": lambda value: worker(value.id)}[args.cmd](args)
if __name__ == "__main__": main()
