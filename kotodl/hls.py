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


def download(playlist_url, referer, dest, progress=None, cancel=None, workers=8, retries=8):
    """Save the stream at `dest`. progress(done, total, nbytes) is called after each segment,
    nbytes counting only what this run fetched.

    A failed or stopped download leaves `dest`.part.ts behind, and the next call resumes it."""
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
            except Exception as e:
                if attempt == retries - 1:
                    raise
                # Back off, so a rate limit (429) gets time to lift instead of eating every retry.
                if cancel.wait(_retry_after(e) or min(2 ** attempt, 30)):
                    raise Cancelled
        if data.startswith(PNG_SIG):
            end = data.find(b"IEND")
            if end != -1:
                data = data[end + 8:]  # 'IEND' + CRC
        return data

    ts, mark = dest + ".part.ts", dest + ".part.ts.done"
    start, offset = _resume_point(ts, mark, len(segments))
    pool = ThreadPoolExecutor(workers)
    queue, pending = iter(segments[start:]), deque()

    def submit():
        segment = next(queue, None)
        if segment is not None:
            pending.append(pool.submit(fetch, segment))

    try:
        for _ in range(workers * 2):  # bounded window keeps memory flat
            submit()
        done, size = start, 0
        with open(ts, "r+b" if start else "wb") as out:
            out.truncate(offset)  # drop a segment half-written when the last run died
            out.seek(offset)
            while pending:
                data = pending.popleft().result()
                if cancel.is_set():
                    raise Cancelled
                out.write(data)
                out.flush()
                done += 1
                size += len(data)
                _write_mark(mark, done, len(segments), out.tell())
                if progress:
                    progress(done, len(segments), size)
                submit()
        _remux(ts, dest)
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
    os.remove(ts)
    os.remove(mark)


def _retry_after(error):
    """Seconds a 429/503 response asks us to wait, if it says."""
    response = getattr(error, "response", None)
    try:
        return min(float(response.headers.get("retry-after")), 60)
    except (AttributeError, TypeError, ValueError):
        return None


def _resume_point(ts, mark, total):
    """(segments, bytes) already saved by an earlier run of the same stream, else (0, 0)."""
    try:
        with open(mark) as f:
            done, count, offset = map(int, f.read().split())
    except (OSError, ValueError):
        return 0, 0
    if count != total or done > total or not os.path.exists(ts) or os.path.getsize(ts) < offset:
        return 0, 0
    return done, offset


def _write_mark(mark, done, total, offset):
    tmp = mark + ".tmp"
    with open(tmp, "w") as f:
        f.write(f"{done} {total} {offset}\n")
    os.replace(tmp, mark)


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
