# Anikoto Downloader

Bulk-download the English dub of an Anikoto series through a classic Windows 2000 style window.

Type an anime name (or paste a watch URL) and press **Search**. Results show each title's type, dubbed episode count and available resolutions; the best match is picked for you. Leave the episodes you want checked, pick a resolution and a folder, then press **Download**.

## Run

```bash
bin/pip install -r requirements.txt   # once
bin/python -m kotodl
```

Needs `ffmpeg` on `PATH` (segments are remuxed to `.mp4`).

## Install

Debian/Ubuntu: build and install a self-contained package (no Python needed at runtime), then launch **Anikoto Downloader** from the app menu or run `kotodl`:

```bash
packaging/build-deb.sh                      # -> dist/kotodl_1.0.0_amd64.deb
sudo apt install ./dist/kotodl_1.0.0_amd64.deb
```

CI (`.github/workflows/build.yml`) builds every push for Linux (`.deb`), Windows (`.zip`) and macOS (`.dmg`, Apple Silicon); grab them from the run's artifacts. Pushing a `v*` tag publishes them as a release. On Windows and macOS, install `ffmpeg` yourself and put it on `PATH`. The macOS app is unsigned, so open it with right-click → Open the first time.

## Notes

- Search only lists titles that have an English dub. It fetches the site's first three result pages and re-ranks them: exact, then prefix, then whole-word matches, English or romaji title.
- Resolutions are checked in the background for the top 12 results, and for any other result when you pick it.
- Any `anikoto.net/.cz/.tv/.bz` watch URL works, including `/ep-N` links. If that host is down, the other mirrors are tried.
- Files are saved as `<folder>/<Anime>/<Anime> - <ep> - <title>.mp4`. Files that already exist are skipped, so re-running resumes a batch.
- The resolution list is whatever the dub servers offer for that title. Some titles have only 1080p, others 480p/720p/1080p. You can start downloading before the check finishes.
- Right-click the list to check or uncheck episodes in bulk. Double-click a finished episode to play it.
- Stream decryption reuses the [`anikoto`](https://github.com/testingbetaversion/anikoto) package's helpers. When the player changes, run `bin/pip install -U anikoto`.
