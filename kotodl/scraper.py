"""Anikoto site access: anime info, episode list, and English-dub streams.

Flow (same as the upstream `anikoto` CLI):
  watch page -> /ajax/episode/list/<id> -> /ajax/server/list (dub servers)
  -> /ajax/server -> MegaPlay embed -> getSourcesNew (AES) -> signed master.m3u8

The player crypto helpers are reused from the `anikoto` package, so a player
change upstream only needs `pip install -U anikoto`.
"""
import logging
import queue
import re
import threading
from dataclasses import dataclass
from urllib.parse import parse_qs, urlencode, urljoin, urlsplit

import m3u8
from bs4 import BeautifulSoup
from curl_cffi import requests

# anikoto installs a colored root log handler on import; keep ours clean.
_root = logging.getLogger()
_handlers, _level = _root.handlers[:], _root.level
from anikoto.anikoto import clean_name, decrypt_source, player_parameters, signed_url  # noqa: E402

_root.handlers[:] = _handlers
_root.setLevel(_level)

__all__ = ["Anikoto", "Anime", "Episode", "Result", "SiteError", "Stream", "brief", "clean_name", "pick_variant"]

MIRRORS = ("anikoto.net", "anikoto.cz", "anikoto.tv", "anikoto.bz")
TIMEOUT = (15, 30)  # connect, read


class SiteError(Exception):
    """A failure worth showing to the user as-is."""


def brief(error):
    """An error as one short line: curl messages carry a prefix and a URL tail nobody needs."""
    text = re.sub(r"Failed to perform, |\s*See https://\S+ first for more details\.", "", str(error))
    return text.strip() or type(error).__name__


@dataclass
class Result:
    """A search hit, as listed on the search page."""
    title: str
    url: str           # watch page
    kind: str = ""     # TV, Movie, OVA, ...
    dub: str = ""      # dubbed episodes, e.g. "22" or "12/26" while still airing
    poster: str | None = None
    jp: str = ""       # romaji title, also matched against the query


def rank(query, result):
    """Lower is better: exact title, then prefix, then whole word, then substring, then the rest."""
    q = query.casefold().strip()

    def score(title):
        t = title.casefold()
        if t == q:
            return 0
        if t.startswith(q):
            return 1
        if re.search(rf"\b{re.escape(q)}\b", t):
            return 2
        return 3 if q in t else 4

    return min(score(result.title), score(result.jp or result.title)), len(result.title)


@dataclass
class Episode:
    num: str    # the site's episode number
    title: str
    ids: str    # opaque token for /ajax/server/list
    dub: bool


@dataclass
class Anime:
    title: str
    poster: str | None
    domain: str  # mirror that answered, e.g. https://anikoto.net
    episodes: list[Episode]


@dataclass
class Stream:
    referer: str
    variants: dict[int, str]  # height (0 = unknown) -> media playlist URL


def pick_variant(variants, height):
    """The tallest variant not above `height`, else the smallest. 0 means best."""
    if height <= 0:
        return variants[max(variants)]
    below = [h for h in variants if h <= height]
    return variants[max(below) if below else min(variants)]


class Anikoto:
    def __init__(self):
        self._local = threading.local()
        self._players = {}  # e1-player script URL -> (key, iv, secret, ttl)
        self.mirror = MIRRORS[0]  # last mirror that answered; searches start there

    @property
    def http(self):
        """One session per thread: curl_cffi sessions aren't thread-safe."""
        session = getattr(self._local, "session", None)
        if session is None:
            session = self._local.session = requests.Session(impersonate="chrome", timeout=TIMEOUT)
            session.headers["x-requested-with"] = "XMLHttpRequest"
        return session

    def _get(self, url, **kwargs):
        for attempt in range(2):  # flaky resolvers drop the odd DNS lookup; a second try usually lands
            try:
                r = self.http.get(url, **kwargs)
                break
            except (requests.exceptions.ConnectionError, requests.exceptions.Timeout):
                if attempt:
                    raise
        r.raise_for_status()
        return r

    def _open(self, url):
        """GET a site page, falling back to the other mirrors if the host is down."""
        parts = urlsplit(url if "://" in url else "https://" + url)
        hosts = [parts.netloc]
        if parts.netloc in MIRRORS:
            hosts += [h for h in (self.mirror, *MIRRORS) if h not in hosts]
        error = None
        for host in hosts:
            try:
                page = self.http.get(parts._replace(netloc=host).geturl())
            except (requests.exceptions.ConnectionError, requests.exceptions.Timeout) as e:
                error = e
                continue
            if page.status_code == 404:
                raise SiteError("Anime not found")
            page.raise_for_status()
            if host in MIRRORS:
                self.mirror = host
            return page
        raise SiteError(f"Can't reach {parts.netloc}") from error

    def search(self, query, pages=3):
        """Titles with an English dub matching `query`, best match first.
        The site's own order is loose, so the first few pages are fetched and re-ranked."""
        first = self._open(f"https://{self.mirror}/filter?" + urlencode({"keyword": query, "language[]": "dub"}))
        results = {}
        for n in range(1, pages + 1):
            page = first if n == 1 else self._get(f"{first.url}&page={n}")
            soup = BeautifulSoup(page.text, "html.parser")
            for item in soup.select("#list-items .item"):
                hit = _result(item)
                if hit:
                    results.setdefault(hit.url, hit)
            if not soup.select_one(f'.pagination a[href*="page={n + 1}"]'):
                break
        return sorted(results.values(), key=lambda r: rank(query, r))

    def anime(self, url):
        page = self._open(url)
        found = re.search(r"/anime/getinfo/(\d+)", page.text)
        if not found:
            raise SiteError("Not an Anikoto anime page")
        parts = urlsplit(page.url)
        domain = f"{parts.scheme}://{parts.netloc}"
        soup = BeautifulSoup(page.text, "html.parser")
        title = soup.select_one("h1.d-title")
        poster = soup.select_one("img[itemprop=image]")

        listing = self._get(f"{domain}/ajax/episode/list/{found[1]}", params={"vrf": ""}).json()["result"]
        episodes = []
        for li in BeautifulSoup(listing, "html.parser").find_all("li", {"data-html": "true"}):
            a = li.find("a")
            episodes.append(Episode(
                num=a.get("data-num") or str(len(episodes) + 1),
                title=li.get("title", "").strip(),
                ids=a["data-ids"],
                dub=a.get("data-dub") == "1",
            ))
        return Anime(
            title=title.get_text(strip=True) if title else "Anime",
            poster=poster.get("src") if poster else None,
            domain=domain,
            episodes=episodes,
        )

    def image(self, url):
        return self._get(url).content

    def dub_streams(self, anime, episode):
        """Yield a Stream per dub server, fastest first: servers resolve in parallel, so one
        stalled CDN doesn't hold up the rest. Raises if none resolve."""
        servers = self._get(f"{anime.domain}/ajax/server/list", params={"servers": episode.ids}).json()["result"]
        dub = BeautifulSoup(servers, "html.parser").select('div.type[data-type="dub"] li[data-link-id]')
        if not dub:
            raise SiteError("No dub server")
        results = queue.Queue()

        def resolve(name, link_id):
            try:
                results.put((name, self._megaplay(anime.domain, link_id), None))
            except Exception as e:
                results.put((name, None, e))

        for li in dub:  # daemon threads: a stalled lookup never delays quitting
            threading.Thread(target=resolve, args=(li.get_text(strip=True), li["data-link-id"]), daemon=True).start()
        errors = []
        for _ in dub:
            name, stream, error = results.get()
            if stream:
                yield stream
            else:
                errors.append(f"{name}: {brief(error)}")
        if len(errors) == len(dub):
            raise SiteError("; ".join(errors))

    def dub_stream(self, anime, episode, height=0):
        """The first server offering `height` (0 = any), else the first that resolved.
        Tokens expire in ~90s, so call this right before downloading."""
        fallback = None
        for stream in self.dub_streams(anime, episode):
            if height <= 0 or height in stream.variants:
                return stream
            fallback = fallback or stream
        return fallback

    def _player(self, script):
        if script not in self._players:
            self._players[script] = player_parameters(self._get(script).text)
        return self._players[script]

    def _megaplay(self, domain, link_id):
        embed = self._get(f"{domain}/ajax/server", params={"get": link_id}).json()["result"]["url"]
        soup = BeautifulSoup(self._get(embed, headers={"referer": f"{domain}/"}).text, "html.parser")
        player = soup.select_one("#megaplay-player[data-id]")
        script = next((s["src"] for s in soup.select("script[src]") if "e1-player" in s["src"]), None)
        if player is None or script is None:
            raise SiteError("Unsupported player")

        parts = urlsplit(embed)
        origin = f"{parts.scheme}://{parts.netloc}"
        params = {"id": player["data-id"]}
        cdn = parse_qs(parts.query).get("s")  # the embed forwards ?s= (CDN pick) to getSources
        if cdn:
            params["s"] = cdn[0]
        data = self._get(f"{origin}/stream/getSourcesNew", params=params, headers={"referer": embed}).json()

        if "enc" in data:
            key, iv, secret, ttl = self._player(urljoin(embed, script))
            master = signed_url(_file(decrypt_source(data["enc"], key, iv)), secret, ttl)
        else:
            master = _file(data.get("sources"))
        referer = origin + "/"
        return Stream(referer=referer, variants=self._variants(master, referer))

    def _variants(self, master, referer):
        playlist = m3u8.loads(self._get(master, headers={"referer": referer}).text, uri=master)
        if not playlist.is_variant:
            return {0: master}
        variants = {}
        for p in sorted(playlist.playlists, key=lambda p: p.stream_info.bandwidth or 0):
            res = p.stream_info.resolution
            variants[res[1] if res else 0] = p.absolute_uri  # highest bandwidth wins per height
        return variants


def _result(item):
    name = item.select_one("a.name")
    if name is None or not name.get("href"):
        return None

    def count(kind):
        span = item.select_one(f".ep-status.{kind} span")
        return span.get_text(strip=True) if span else ""

    dub, total = count("dub"), count("total")
    kind = item.select_one(".poster .meta .right")
    img = item.select_one(".poster img")
    return Result(
        title=name.get_text(strip=True),
        url=name["href"],
        kind=kind.get_text(strip=True) if kind else "",
        dub=f"{dub}/{total}" if dub and total and total != dub else dub,
        poster=img.get("src") if img else None,
        jp=name.get("data-jp", ""),
    )


def _file(source):
    if isinstance(source, list):
        source = next((s for s in source if isinstance(s, dict) and s.get("file")), None)
    if isinstance(source, dict):
        source = source.get("file")
    if not source:
        raise SiteError("No stream in player response")
    return source
