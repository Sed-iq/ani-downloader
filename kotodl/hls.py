"""Download one HLS media playlist to an .mp4: parallel segments, in-order write, ffmpeg remux."""
import os
import shutil
import subprocess
import threading
from collections import deque
from concurrent.futures import ThreadPoolExecutor

import m3u8
from curl_cffi import requests

PNG_SIG = b"\x89PNG\r\n\x1a\n"  # some CDNs disguise segments as images


class Cancelled(Exception):
    pass


def download(playlist_url, referer, dest, progress=None, cancel=None, workers=8, retries=3):
    """Save the stream at `dest`. progress(done, total, nbytes) is called after each segment."""
    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found")
    cancel = cancel or threading.Event()
    local = threading.local()

    def http():
        # curl_cffi sessions aren't thread-safe: one per worker.
        if not hasattr(local, "session"):
            local.session = requests.Session(impersonate="chrome", timeout=(15, 60))
            local.session.headers["referer"] = referer
        return local.session

    def get(url):
        r = http().get(url)
        r.raise_for_status()
        return r

    media = m3u8.loads(get(playlist_url).text, uri=playlist_url)
    if media.is_variant:
        best = max(media.playlists, key=lambda p: p.stream_info.bandwidth or 0)
        media = m3u8.loads(get(best.absolute_uri).text, uri=best.absolute_uri)
    if any(key and key.method not in (None, "NONE") for key in media.keys):
        raise RuntimeError("Encrypted stream not supported")
    segments = media.segments
    if not segments:
        raise RuntimeError("Empty playlist")

    def fetch(segment):
        for attempt in range(retries):
            if cancel.is_set():
                raise Cancelled
            try:
                data = get(segment.absolute_uri).content
                break
            except Exception:
                if attempt == retries - 1:
                    raise
        if data.startswith(PNG_SIG):
            end = data.find(b"IEND")
            if end != -1:
                data = data[end + 8:]  # 'IEND' + CRC
        return data

    ts = dest + ".part.ts"
    pool = ThreadPoolExecutor(workers)
    queue, pending = iter(segments), deque()

    def submit():
        segment = next(queue, None)
        if segment is not None:
            pending.append(pool.submit(fetch, segment))

    try:
        for _ in range(workers * 2):  # bounded window keeps memory flat
            submit()
        done = size = 0
        with open(ts, "wb") as out:
            while pending:
                data = pending.popleft().result()
                if cancel.is_set():
                    raise Cancelled
                out.write(data)
                done += 1
                size += len(data)
                if progress:
                    progress(done, len(segments), size)
                submit()
        _remux(ts, dest)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
        if os.path.exists(ts):
            os.remove(ts)


def _remux(src, dest):
    part = dest + ".part"
    result = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", src,
         "-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart", "-f", "mp4", part],
        capture_output=True, text=True,
    )
    if result.returncode:
        if os.path.exists(part):
            os.remove(part)
        lines = result.stderr.strip().splitlines()
        raise RuntimeError(lines[-1] if lines else "ffmpeg failed")
    os.replace(part, dest)
