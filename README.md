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

CI (`.github/workflows/build.yml`) builds every push for Linux (`.deb`), Windows (`.zip`), macOS (`.dmg`, Apple Silicon) and Android (`.apk`). Each push to `main` publishes them as a new GitHub release (`v1.0.<run number>`); pushing a `v*` tag releases under that tag instead. Other branches only keep them as run artifacts. On Windows and macOS, install `ffmpeg` yourself and put it on `PATH`. The macOS app is unsigned, so open it with right-click → Open the first time.

## Android

`mobile/` is the same downloader as a Flutter app: search, pick a title, check episodes, pick a resolution, **Download**. Grab `kotodl-<version>-android.apk` from the latest GitHub release and open it on the phone (allow installs from your browser or file manager when asked).

- On first launch it asks for storage access ("All files access" on Android 11+), then creates `Anikoto Downloader/` at the root of the phone's storage. Each anime gets its own folder: `Anikoto Downloader/<Anime>/<Anime> - <ep> - <title>.mp4`.
- Downloads keep running with the screen off; progress shows in a notification.
- Segments are remuxed to `.mp4` with Android's MediaMuxer, so there is no ffmpeg in the APK. If a phone can't remux a stream, the episode is kept as `.ts`, which video players still open.
- Tap a finished episode to play it, long-press any episode for details.

```bash
cd mobile
flutter test                                # offline: crypto, parsing, downloader, screens
flutter test --tags live --run-skipped      # against the real site; needs ffmpeg
```

To sign every release with the same key (so a new APK installs over the old one), add these repo secrets. Without them CI signs with a throwaway debug key, and users have to uninstall before updating.

```bash
keytool -genkeypair -v -keystore kotodl.jks -alias kotodl -keyalg RSA -keysize 2048 -validity 10000
base64 -w0 kotodl.jks   # -> ANDROID_KEYSTORE_BASE64
```

`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` (`kotodl`), `ANDROID_KEY_PASSWORD`.

## Notes

- Search only lists titles that have an English dub. It fetches the site's first three result pages and re-ranks them: exact, then prefix, then whole-word matches, English or romaji title.
- Resolutions are checked in the background for the top 12 results, and for any other result when you pick it.
- Any `anikoto.net/.cz/.tv/.bz` watch URL works, including `/ep-N` links. If that host is down, the other mirrors are tried.
- Files are saved as `<folder>/<Anime>/<Anime> - <ep> - <title>.mp4`. Files that already exist are skipped, so re-running resumes a batch.
- The resolution list is whatever the dub servers offer for that title. Some titles have only 1080p, others 480p/720p/1080p. You can start downloading before the check finishes.
- Right-click the list to check or uncheck episodes in bulk. Double-click a finished episode to play it.
- Stream decryption reuses the [`anikoto`](https://github.com/testingbetaversion/anikoto) package's helpers. When the player changes, run `bin/pip install -U anikoto`.
