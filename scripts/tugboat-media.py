#!/usr/bin/env python3
"""yt-dlp media jobs for Tugboat. Jobs are persisted for Quickshell polling."""
import argparse
import json
import os
import shutil
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "tugboat"
JOBS = ROOT / "media-jobs.json"


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
def public_formats(info):
    seen, out = set(), []
    for fmt in info.get("formats", []):
        height = fmt.get("height")
        if not height or height in seen: continue
        seen.add(height)
        out.append({"id": str(height), "label": f"{height}p"})
    return sorted(out, key=lambda x: int(x["id"]), reverse=True)[:6]
def check(_):
    error = dependency_error()
    emit({"ok": not bool(error), "error": error or ""})
def inspect(url):
    error = dependency_error()
    if error: emit({"ok": False, "error": error}); return
    import yt_dlp
    try:
        with yt_dlp.YoutubeDL({"quiet": True, "skip_download": True, "noplaylist": True}) as ydl:
            info = ydl.extract_info(url, download=False)
        if not info or info.get("extractor_key") == "Generic":
            emit({"ok": True, "media": False}); return
        emit({"ok": True, "media": True, "title": info.get("title", url), "formats": public_formats(info)})
    except Exception:
        # A regular HTTP URL should retain the existing aria2 path. Extraction
        # failures for a known service are surfaced only after a media choice.
        emit({"ok": True, "media": False})
def worker(job_id):
    import yt_dlp
    jobs = load_jobs(); job = jobs.get(job_id)
    if not job: return
    def update(status, **values):
        current = load_jobs(); item = current.get(job_id, {})
        item.update(values); item["status"] = status; item["updated"] = time.time()
        current[job_id] = item; save_jobs(current)
    def hook(data):
        state = data.get("status")
        if state == "downloading":
            update("active", downloaded=int(data.get("downloaded_bytes") or 0), total=int(data.get("total_bytes") or data.get("total_bytes_estimate") or 0), speed=int(data.get("speed") or 0), eta=int(data.get("eta") or 0), filename=data.get("filename") or job.get("filename", ""))
        elif state == "finished": update("processing", filename=data.get("filename") or job.get("filename", ""))
    fmt = job["format"]
    selector = "bestaudio/best" if fmt == "audio" else (f"bestvideo[height<={fmt}]+bestaudio/best[height<={fmt}]" if fmt.isdigit() else "bestvideo+bestaudio/best")
    options = {
        "format": selector, "noplaylist": True, "quiet": True,
        "outtmpl": str(Path(job["directory"]) / "%(title).200B.%(ext)s"),
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
    job = {"id": job_id, "url": args.url, "title": args.title or args.url, "format": args.format, "directory": os.path.expanduser(args.directory or "~/Downloads"), "status": "queued", "downloaded": 0, "total": 0, "speed": 0, "eta": 0, "created": time.time()}
    jobs = load_jobs(); jobs[job_id] = job; save_jobs(jobs)
    process = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), "worker", job_id], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    job["pid"] = process.pid; jobs[job_id] = job; save_jobs(jobs)
    emit({"ok": True, "id": job_id})
def status(_):
    items = []
    for item in load_jobs().values():
        filename = item.get("filename") or item.get("title") or item["url"]
        items.append({"gid": "yt:" + item["id"], "status": item.get("status", "queued"), "totalLength": str(item.get("total", 0)), "completedLength": str(item.get("downloaded", 0)), "downloadSpeed": str(item.get("speed", 0)), "files": [{"path": filename}], "media": True, "formatLabel": item.get("format", "best"), "errorMessage": item.get("error", "")})
    emit({"ok": True, "items": items})
def action(args):
    jobs = load_jobs(); job = jobs.get(args.id)
    if not job: emit({"ok": False, "error": "Media job not found"}); return
    try:
        pid = int(job.get("pid", 0)); group = os.getpgid(pid)
        if args.action == "pause": os.killpg(group, signal.SIGSTOP); job["status"] = "paused"
        elif args.action == "resume": os.killpg(group, signal.SIGCONT); job["status"] = "active"
        elif args.action == "remove":
            if pid: os.killpg(group, signal.SIGTERM)
            del jobs[args.id]; save_jobs(jobs); emit({"ok": True}); return
        jobs[args.id] = job; save_jobs(jobs); emit({"ok": True})
    except ProcessLookupError: emit({"ok": False, "error": "Media worker is no longer running"})
def main():
    parser = argparse.ArgumentParser(); sub = parser.add_subparsers(dest="cmd", required=True)
    x = sub.add_parser("inspect"); x.add_argument("url")
    x = sub.add_parser("start"); x.add_argument("url"); x.add_argument("--title"); x.add_argument("--format", default="best"); x.add_argument("--directory")
    sub.add_parser("status")
    sub.add_parser("check")
    x = sub.add_parser("action"); x.add_argument("action", choices=["pause", "resume", "remove"]); x.add_argument("id")
    x = sub.add_parser("worker"); x.add_argument("id")
    args = parser.parse_args(); {"inspect": inspect, "start": start, "status": status, "check": check, "action": action, "worker": worker}[args.cmd](args)
if __name__ == "__main__": main()
