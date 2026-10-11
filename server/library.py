"""Library layer for the Player7 app: playlists, tracks, imports, search, audio cache.

Track ids:     sp-<spotifyTrackId> | yt-<youtubeVideoId> | sc-<soundcloudTrackId>
Playlist ids:  sp-pl-<id> | sp-al-<id> | sp-ar-<artistId> | yt-pl-<listId> | yt-al-<browseId> | yt-ch-<channelId>
               sc-lk-<user> (likes) | sc-us-<user> (uploads) | sc-pl-<user>~<set>

Audio is resolved lazily: Spotify tracks are matched on YouTube Music the first time
they are played or prefetched, downloaded with yt-dlp and cached as AAC .m4a so the
phone (iOS 7) can play and seek them.
"""

import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor

try:
    from curl_cffi import requests as cffi_requests  # type: ignore
    _HAS_CFFI = True
except ImportError:
    cffi_requests = None
    _HAS_CFFI = False

ROOT = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.join(ROOT, "data")
AUDIO_DIR = os.path.join(ROOT, "cache", "audio")
COVER_DIR = os.path.join(ROOT, "cache", "covers")
CONFIG_PATH = os.path.join(ROOT, "config.json")

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15"

for d in (DATA_DIR, AUDIO_DIR, COVER_DIR):
    os.makedirs(d, exist_ok=True)


def load_config():
    # Environment variables (handy for Docker) give the defaults; config.json overrides them.
    config = {
        "token": os.environ.get("PLAYER7_TOKEN", ""),
        "spotify_client_id": os.environ.get("SPOTIFY_CLIENT_ID", ""),
        "spotify_client_secret": os.environ.get("SPOTIFY_CLIENT_SECRET", ""),
        "spotify_market": os.environ.get("SPOTIFY_MARKET", ""),
        "youtube_proxy": os.environ.get("YOUTUBE_PROXY", ""),
        "lastfm_api_key": os.environ.get("LASTFM_API_KEY", ""),
        "lastfm_api_secret": os.environ.get("LASTFM_API_SECRET", ""),
        "ytmusic_auth": os.path.join(ROOT, "secrets", "ytmusic_browser.json"),
    }
    if os.path.exists(CONFIG_PATH):
        with open(CONFIG_PATH) as f:
            config.update({k: v for k, v in json.load(f).items() if v})
    return config


CONFIG = load_config()


class UserError(Exception):
    """Error whose message is meant for the app user."""


def http_get(url, headers=None, timeout=20, data=None):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9", **(headers or {})})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def cffi_get(url, headers=None, timeout=20):
    """Chrome-impersonated GET; falls back to urllib if curl_cffi is missing."""
    if _HAS_CFFI:
        r = cffi_requests.get(url, headers=headers or {}, timeout=timeout, impersonate="chrome124")
        if r.status_code >= 400:
            raise RuntimeError(f"cffi_get {r.status_code}: {r.text[:160]}")
        return r.content
    return http_get(url, headers=headers, timeout=timeout)


def cffi_post_json(url, body, headers=None, timeout=20):
    hdrs = {"Accept": "application/json", "Content-Type": "application/json", **(headers or {})}
    if _HAS_CFFI:
        r = cffi_requests.post(url, data=json.dumps(body), headers=hdrs, timeout=timeout, impersonate="chrome124")
        if r.status_code >= 400:
            raise RuntimeError(f"cffi_post {r.status_code}: {r.text[:160]}")
        return r.content
    return http_get(url, headers=hdrs, timeout=timeout, data=json.dumps(body).encode())


# ---------------------------------------------------------------------------
# Store


class Store:
    """JSON-file persistence for tracks, playlists and the user's added songs."""

    def __init__(self):
        self.lock = threading.RLock()
        self.tracks = self._load("tracks.json", {})
        self.playlists = self._load("playlists.json", {})
        self.added = self._load("library.json", {"added": []})["added"]
        self.images = self._load("images.json", {})  # artist / album / playlist id -> image URL
        self._images_timer = None

    def _load(self, name, default):
        path = os.path.join(DATA_DIR, name)
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
        return default

    def _save(self, name, obj):
        path = os.path.join(DATA_DIR, name)
        tmp = path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(obj, f, ensure_ascii=False)
        os.replace(tmp, path)

    def save(self):
        with self.lock:
            self._save("tracks.json", self.tracks)
            self._save("playlists.json", self.playlists)
            self._save("library.json", {"added": self.added})

    def set_image(self, entity_id, url, replace=True):
        if not url or (not replace and self.images.get(entity_id)) or self.images.get(entity_id) == url:
            return
        with self.lock:
            self.images[entity_id] = url
            # Search results set many at once: write the file once, shortly after.
            if not self._images_timer:
                self._images_timer = threading.Timer(2.0, self._save_images)
                self._images_timer.daemon = True
                self._images_timer.start()

    def _save_images(self):
        with self.lock:
            self._images_timer = None
            self._save("images.json", self.images)

    def upsert_tracks(self, tracks):
        with self.lock:
            for t in tracks:
                existing = self.tracks.get(t["id"], {})
                merged = {**existing, **{k: v for k, v in t.items() if v not in (None, "")}}
                self.tracks[t["id"]] = merged

    def save_playlist(self, playlist, tracks):
        with self.lock:
            self.upsert_tracks(tracks)
            playlist = dict(playlist)
            playlist["trackIds"] = [t["id"] for t in tracks]
            playlist["importedAt"] = int(time.time())
            self.playlists[playlist["id"]] = playlist
            self.save()
            return playlist

    def delete_playlist(self, playlist_id):
        with self.lock:
            self.playlists.pop(playlist_id, None)
            self.save()

    def add_to_library(self, track_id):
        with self.lock:
            if track_id not in self.added:
                self.added.append(track_id)
                self.save()

    def remove_from_library(self, track_id):
        with self.lock:
            if track_id in self.added:
                self.added.remove(track_id)
                self.save()

    def library_ids(self):
        with self.lock:
            ids = dict.fromkeys(self.added)
            for p in self.playlists.values():
                ids.update(dict.fromkeys(p["trackIds"]))
            return list(ids)


STORE = Store()


# ---------------------------------------------------------------------------
# Public JSON shapes for the app


def album_entity_id(t):
    album_id = t.get("albumId")
    if not album_id:
        return ""
    return f"yt-al-{album_id}" if album_id.startswith("MPREb") else f"sp-al-{album_id}"


def public_track(t):
    return {
        "id": t["id"],
        "title": t.get("title") or "Unknown Title",
        "artist": t.get("artist") or "Unknown Artist",
        "album": t.get("album") or "",
        "duration": int(t.get("duration") or 0),
        "format": "m4a",
        "available": True,
        "cached": os.path.exists(audio_path(t["id"])),
        # "hq" once a Spotify song has its final encode; the app then refreshes older offline copies.
        "audioRev": "hq" if os.path.exists(audio_path(t["id"]) + ".hq") else "",
        "source": t.get("source", "youtube"),
        "inLibrary": t["id"] in STORE.added,
        "albumId": album_entity_id(t),
        # Changes whenever the cover source changes, so the app knows to drop its cached copy.
        "coverVersion": hashlib.md5((t.get("coverUrl") or "").encode()).hexdigest()[:8],
    }


def public_playlist(p, with_tracks=False, tracks=None):
    """A stored playlist, or a preview of one (tracks passed in) that isn't in the library yet."""
    if tracks is None:
        tracks = [STORE.tracks[i] for i in p["trackIds"] if i in STORE.tracks]
    image = STORE.images.get(p["id"])  # artists and albums have their own picture
    cover_id = p["id"] if image else (tracks[0]["id"] if tracks else None)
    cover_url = image or (tracks[0].get("coverUrl") or "" if tracks else "")
    out = {
        "id": p["id"],
        "name": p.get("name") or "Untitled Playlist",
        "source": p.get("source", "local"),
        "kind": p.get("kind", "playlist"),
        "owner": p.get("owner", ""),
        "trackCount": len(tracks),
        "duration": sum(int(t.get("duration") or 0) for t in tracks),
        "coverTrackId": cover_id,
        "coverVersion": hashlib.md5(cover_url.encode()).hexdigest()[:8] if cover_id else "",
        "url": p.get("url", ""),
        "imported": p["id"] in STORE.playlists,
    }
    if with_tracks:
        out["tracks"] = [public_track(t) for t in tracks]
    return out


# ---------------------------------------------------------------------------
# Spotify


SPOTIFY_MARKET = CONFIG.get("spotify_market") or "PL"
SPOTIFY_URL_RE = re.compile(r"open\.spotify\.com/(?:intl-[a-z]+/)?(playlist|album|track|user|artist)/([A-Za-z0-9._-]+)")


class Spotify:
    """Spotify Web API (client credentials) with an embed-page fallback for playlists/albums."""

    def __init__(self, client_id, client_secret):
        self.client_id = client_id
        self.client_secret = client_secret
        self._token = None
        self._token_expiry = 0
        self._lock = threading.Lock()
        # Anonymous web-player flow (no user keys needed; works for >100-track playlists)
        self._anon_access = None
        self._anon_access_expiry = 0
        self._anon_client_token = None
        self._anon_client_token_expiry = 0
        self._anon_hashes = {}
        self._anon_hashes_expiry = 0
        self._anon_lock = threading.Lock()

    @property
    def has_api(self):
        return bool(self.client_id and self.client_secret)

    def token(self):
        with self._lock:
            if self._token and time.time() < self._token_expiry - 60:
                return self._token
            auth = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
            body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode()
            data = json.loads(http_get("https://accounts.spotify.com/api/token", {"Authorization": f"Basic {auth}", "Content-Type": "application/x-www-form-urlencoded"}, data=body))
            self._token = data["access_token"]
            self._token_expiry = time.time() + data.get("expires_in", 3600)
            return self._token

    def api(self, path_or_url, params=None):
        url = path_or_url if path_or_url.startswith("http") else "https://api.spotify.com/v1" + path_or_url
        if params:
            url += ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        return json.loads(http_get(url, {"Authorization": f"Bearer {self.token()}"}))

    def paged(self, path, params=None, key=None):
        page = self.api(path, params)
        if key:
            page = page[key]
        items = list(page.get("items") or [])
        while page.get("next"):
            page = self.api(page["next"])
            if key and key in page:
                page = page[key]
            items.extend(page.get("items") or [])
        return items

    @staticmethod
    def track_from_api(t, album=None):
        album = t.get("album") or album or {}
        images = album.get("images") or []
        cover = sorted(images, key=lambda i: i.get("width") or 0)
        cover = next((i["url"] for i in cover if (i.get("width") or 0) >= 300), images[0]["url"] if images else "")
        return {
            "id": f"sp-{t['id']}",
            "title": t.get("name"),
            "artist": ", ".join(a["name"] for a in t.get("artists") or []),
            "album": album.get("name", ""),
            "duration": int((t.get("duration_ms") or 0) / 1000),
            "source": "spotify",
            "spotifyId": t["id"],
            "coverUrl": cover,
            "artistRefs": [{"id": a["id"], "name": a["name"]} for a in t.get("artists") or [] if a.get("id")],
            "albumId": album.get("id") or "",
        }

    # ---- Anonymous web-player flow (no API keys) ---------------------------

    def _anon_access_token(self):
        with self._anon_lock:
            if self._anon_access and time.time() < self._anon_access_expiry - 60:
                return self._anon_access
            # any embed page carries an anon accessToken; use a stable track id
            html = cffi_get("https://open.spotify.com/embed/track/4uLU6hMCjMI75M1A2tKUQC").decode("utf-8", "replace")
            m = re.search(r'"accessToken":"([^"]+)"', html)
            exp = re.search(r'"accessTokenExpirationTimestampMs":(\d+)', html)
            if not m:
                raise UserError("Spotify anon token not found in embed page.")
            self._anon_access = m.group(1)
            self._anon_access_expiry = (int(exp.group(1)) / 1000.0) if exp else (time.time() + 3000)
            return self._anon_access

    def _anon_client_token_get(self):
        with self._anon_lock:
            if self._anon_client_token and time.time() < self._anon_client_token_expiry - 60:
                return self._anon_client_token
            body = {"client_data": {"client_version": "1.2.0", "client_id": "d8a5ed958d274c2e8ee717e6a4b0971d",
                                    "js_sdk_data": {"device_brand": "Apple", "device_model": "unknown",
                                                    "os": "macos", "os_version": "10.15.7",
                                                    "device_id": "aabbccddeeff0011", "device_type": "computer"}}}
            data = json.loads(cffi_post_json("https://clienttoken.spotify.com/v1/clienttoken", body))
            grant = data.get("granted_token") or {}
            self._anon_client_token = grant.get("token")
            self._anon_client_token_expiry = time.time() + int(grant.get("expires_after_seconds") or 1200)
            if not self._anon_client_token:
                raise UserError("Spotify client-token could not be obtained.")
            return self._anon_client_token

    def _anon_hash(self, operation):
        with self._anon_lock:
            if self._anon_hashes and time.time() < self._anon_hashes_expiry:
                return self._anon_hashes.get(operation)
            # scrape manifest -> web-player.<hash>.js -> list of (operation, "query", sha256Hash)
            html = cffi_get("https://open.spotify.com/").decode("utf-8", "replace")
            m = re.search(r'(https?://open\.spotifycdn\.com/cdn/build/web-player/web-player\.[a-z0-9]+\.js)', html)
            if not m:
                raise UserError("Spotify web-player bundle URL not found.")
            js = cffi_get(m.group(1)).decode("utf-8", "replace")
            pairs = re.findall(r'"(\w+)",\s*"query",\s*"([a-f0-9]{64})"', js)
            self._anon_hashes = {name: h for name, h in pairs}
            self._anon_hashes_expiry = time.time() + 86400
            return self._anon_hashes.get(operation)

    def _pathfinder(self, operation, variables):
        hash_ = self._anon_hash(operation)
        if not hash_:
            raise UserError(f"Spotify operation hash missing: {operation}")
        extensions = {"persistedQuery": {"version": 1, "sha256Hash": hash_}}
        qs = urllib.parse.urlencode({"operationName": operation,
                                     "variables": json.dumps(variables),
                                     "extensions": json.dumps(extensions)})
        url = f"https://api-partner.spotify.com/pathfinder/v1/query?{qs}"
        headers = {"Authorization": "Bearer " + self._anon_access_token(),
                   "client-token": self._anon_client_token_get(),
                   "accept": "application/json", "app-platform": "WebPlayer",
                   "spotify-app-version": "1.2.0"}
        for attempt in range(2):
            try:
                return json.loads(cffi_get(url, headers=headers))
            except RuntimeError as e:
                # token may have rotated; refresh once
                if attempt == 0 and ("401" in str(e) or "403" in str(e)):
                    self._anon_access = None
                    self._anon_client_token = None
                    continue
                raise

    def playlist_anon(self, pid):
        """Fetch a full playlist (>100 tracks) via the anonymous pathfinder API."""
        all_items = []
        total = None
        name = None
        owner = ""
        offset = 0
        while True:
            vars_ = {"uri": f"spotify:playlist:{pid}", "offset": offset, "limit": 100,
                     "enableWatchFeedEntrypoint": False}
            data = self._pathfinder("fetchPlaylist", vars_)
            pl = (((data or {}).get("data") or {}).get("playlistV2")) or {}
            if not pl:
                raise UserError("Spotify playlist not accessible (anon).")
            if name is None:
                name = pl.get("name") or ""
                owner = (((pl.get("ownerV2") or {}).get("data") or {}).get("name")) or ""
            content = pl.get("content") or {}
            items = content.get("items") or []
            if total is None:
                total = content.get("totalCount") or 0
            all_items.extend(items)
            offset += len(items)
            if not items or offset >= (total or 0):
                break
        tracks = []
        for it in all_items:
            data = (((it.get("itemV2") or {}).get("data")) or {})
            if (data.get("__typename") or "") != "TrackResponseWrapper" and not data.get("name"):
                continue
            uri = data.get("uri") or ""
            sid = uri.split(":")[-1]
            if not sid:
                continue
            artists = (((data.get("artists") or {}).get("items")) or [])
            artist = ", ".join(((a.get("profile") or {}).get("name") or "") for a in artists)
            album = ((data.get("albumOfTrack") or {}).get("name")) or ""
            cover_src = (((data.get("albumOfTrack") or {}).get("coverArt") or {}).get("sources")) or []
            cover = cover_src[-1]["url"] if cover_src else ""
            tracks.append({
                "id": f"sp-{sid}", "title": data.get("name") or "", "artist": artist,
                "album": album, "duration": int((data.get("trackDuration") or {}).get("totalMilliseconds", 0) / 1000),
                "source": "spotify", "spotifyId": sid, "coverUrl": cover,
            })
        playlist = {"id": f"sp-pl-{pid}", "name": name or "Spotify playlist", "source": "spotify",
                    "owner": owner, "url": f"https://open.spotify.com/playlist/{pid}"}
        return playlist, tracks

    def embed_entity(self, kind, sid):
        html = http_get(f"https://open.spotify.com/embed/{kind}/{sid}").decode("utf-8", "replace")
        m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.+?)</script>', html, re.S)
        if not m:
            raise UserError("Spotify page could not be read.")
        return json.loads(m.group(1))["props"]["pageProps"]["state"]["data"]["entity"]

    def playlist(self, pid):
        if self.has_api:
            meta = self.api(f"/playlists/{pid}", {"fields": "name,owner(id,display_name)"})
            items = self.paged(f"/playlists/{pid}/tracks", {"limit": 100, "additional_types": "track"})
            tracks = [self.track_from_api(i["track"]) for i in items if i.get("track") and i["track"].get("id")]
            playlist = {"id": f"sp-pl-{pid}", "name": meta["name"], "source": "spotify", "owner": meta["owner"].get("display_name", ""),
                        "ownerId": meta["owner"]["id"], "url": f"https://open.spotify.com/playlist/{pid}"}
            return playlist, tracks
        # No API keys: anonymous pathfinder flow (full playlist, no 100-track cap)
        try:
            return self.playlist_anon(pid)
        except Exception as e:
            # Fall back to the embed page (capped at ~100 tracks)
            entity = self.embed_entity("playlist", pid)
            playlist, tracks = self._from_embed(entity, f"sp-pl-{pid}", f"https://open.spotify.com/playlist/{pid}")
            playlist["partial_reason"] = f"anon pathfinder failed: {type(e).__name__}"
            return playlist, tracks

    def album(self, aid):
        if self.has_api:
            album = self.api(f"/albums/{aid}")
            items = self.paged(f"/albums/{aid}/tracks", {"limit": 50})
            tracks = [self.track_from_api(t, album) for t in items if t.get("id")]
            playlist = {"id": f"sp-al-{aid}", "name": album["name"], "source": "spotify", "kind": "album",
                        "owner": ", ".join(a["name"] for a in album.get("artists") or []), "url": f"https://open.spotify.com/album/{aid}"}
            return playlist, tracks
        entity = self.embed_entity("album", aid)
        return self._from_embed(entity, f"sp-al-{aid}", f"https://open.spotify.com/album/{aid}")

    def _from_embed(self, entity, playlist_id, url):
        cover = ((entity.get("coverArt") or {}).get("sources") or [{}])[0].get("url", "")
        tracks = []
        for t in entity.get("trackList") or []:
            sid = (t.get("uri") or "").split(":")[-1]
            if not sid:
                continue
            # The embed only has the playlist mosaic; each song's album art is looked up lazily (see spotify_cover).
            tracks.append({
                "id": f"sp-{sid}", "title": t.get("title"), "artist": (t.get("subtitle") or "").replace("\xa0", " "),
                "duration": int((t.get("duration") or 0) / 1000), "source": "spotify", "spotifyId": sid,
            })
        playlist = {"id": playlist_id, "name": entity.get("name") or entity.get("title"), "source": "spotify",
                    "owner": entity.get("subtitle", ""), "url": url, "partial": True}
        return playlist, tracks

    @staticmethod
    def best_image(images):
        images = sorted(images or [], key=lambda i: i.get("width") or 0)
        return images[-1]["url"] if images else ""

    def artist_top_tracks(self, aid):
        data = self.api(f"/artists/{aid}/top-tracks", {"market": SPOTIFY_MARKET})
        return [self.track_from_api(t) for t in data.get("tracks") or [] if t and t.get("id")]

    def artist_releases(self, aid, groups="album,single"):
        releases = self.paged(f"/artists/{aid}/albums", {"include_groups": groups, "limit": 50, "market": SPOTIFY_MARKET})
        return sorted([r for r in releases if r and r.get("id")], key=lambda r: r.get("release_date") or "", reverse=True)

    def albums_with_tracks(self, album_ids):
        albums = []
        for i in range(0, len(album_ids), 20):
            albums += [a for a in self.api("/albums", {"ids": ",".join(album_ids[i:i + 20]), "market": SPOTIFY_MARKET}).get("albums") or [] if a]
        for album in albums:
            page = album.get("tracks") or {}
            while page.get("next"):  # albums over 50 songs
                page = self.api(page["next"])
                album["tracks"]["items"] += page.get("items") or []
        return albums

    def artist_discography(self, aid):
        """Every song of an artist: top songs first, then albums and singles from newest to oldest."""
        info = self.api(f"/artists/{aid}")
        top = self.artist_top_tracks(aid)
        albums = self.albums_with_tracks([r["id"] for r in self.artist_releases(aid)])
        tracks, seen = [], set()
        for track in top + [self.track_from_api(t, album) for album in albums for t in (album.get("tracks") or {}).get("items") or [] if t.get("id")]:
            key = _norm(re.sub(r"\s*[\(\[](feat|ft|with|prod)[^\)\]]*[\)\]]", "", track["title"] or "", flags=re.I))
            if key in seen or track["id"] in seen:
                continue
            seen.update((key, track["id"]))
            tracks.append(track)
        playlist_id = f"sp-ar-{aid}"
        STORE.set_image(playlist_id, self.best_image(info.get("images")))
        playlist = {"id": playlist_id, "name": info.get("name") or "Spotify Artist", "source": "spotify", "kind": "artist",
                    "owner": "Artist", "url": f"https://open.spotify.com/artist/{aid}"}
        return playlist, tracks

    def user_playlists(self, user_id):
        if not self.has_api:
            raise UserError("Importing a whole Spotify profile needs Spotify API keys in server/config.json.")
        return [p for p in self.paged(f"/users/{user_id}/playlists", {"limit": 50}) if p]

    def search(self, query, limit=25):
        if not self.has_api:
            raise UserError("Spotify search needs Spotify API keys in server/config.json.")
        data = self.api("/search", {"q": query, "type": "track", "limit": limit})
        return [self.track_from_api(t) for t in data["tracks"]["items"] if t and t.get("id")]


SPOTIFY = Spotify(CONFIG.get("spotify_client_id"), CONFIG.get("spotify_client_secret"))


# ---------------------------------------------------------------------------
# YouTube / YouTube Music


YT_LIST_RE = re.compile(r"[?&]list=([A-Za-z0-9_-]+)")
YT_VIDEO_RE = re.compile(r"(?:v=|youtu\.be/|/shorts/)([A-Za-z0-9_-]{11})")


def _ytmusic(auth=True):
    from ytmusicapi import YTMusic
    path = CONFIG.get("ytmusic_auth")
    if auth and path and os.path.exists(path):
        return YTMusic(path)
    return YTMusic()


_YTM_LOCAL = threading.local()


def ytmusic(auth=True):
    """Per-thread YTMusic clients (the underlying requests session is not thread-safe)."""
    key = "auth" if auth else "anon"
    client = getattr(_YTM_LOCAL, key, None)
    if client is None:
        client = _ytmusic(auth)
        setattr(_YTM_LOCAL, key, client)
    return client


def has_ytmusic_auth():
    path = CONFIG.get("ytmusic_auth")
    return bool(path and os.path.exists(path))


def best_thumbnail(thumbnails):
    if not thumbnails:
        return ""
    url = sorted(thumbnails, key=lambda t: t.get("width") or 0)[-1]["url"]
    # YouTube Music thumbnails can be requested at any size: w60-h60 -> w544-h544.
    return re.sub(r"=w\d+-h\d+", "=w544-h544", url)


def track_from_ytmusic(item):
    vid = item.get("videoId")
    if not vid:
        return None
    artists = ", ".join(a["name"] for a in item.get("artists") or [] if a.get("name"))
    album = (item.get("album") or {}).get("name", "") if isinstance(item.get("album"), dict) else ""
    duration = item.get("duration_seconds")
    if not duration and item.get("duration"):
        parts = [int(p) for p in str(item["duration"]).split(":") if p.isdigit()]
        duration = sum(p * 60 ** i for i, p in enumerate(reversed(parts)))
    title = item.get("title")
    # For uploads this is the channel; for songs, the artists' channels.
    refs = [{"id": a["id"], "name": a["name"]} for a in item.get("artists") or [] if a.get("id") and a.get("name")]
    # Uploads that aren't official songs often carry the artist in the title: "Artist - Song".
    if item.get("videoType") not in ("MUSIC_VIDEO_TYPE_ATV", "MUSIC_VIDEO_TYPE_OMV") and " - " in (title or ""):
        artists, title = split_video_title(title, artists)
    album_id = (item.get("album") or {}).get("id") if isinstance(item.get("album"), dict) else None
    return {
        "id": f"yt-{vid}",
        "title": title,
        "artist": artists,
        "album": album,
        "duration": int(duration or 0),
        "source": "youtube",
        "youtubeId": vid,
        "coverUrl": best_thumbnail(item.get("thumbnails")) or f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
        "artistRefs": refs,
        "albumId": album_id or "",
    }


def split_video_title(title, channel):
    """'Artist - Song (Official Video)' -> ('Artist', 'Song')."""
    clean = re.sub(r"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|teledysk|prod\.?)[^\)\]]*[\)\]]", "", title or "", flags=re.I).strip()
    channel = re.sub(r"\s*-\s*Topic$", "", channel or "")
    if " - " in clean:
        artist, song = clean.split(" - ", 1)
        return artist.strip(), song.strip()
    return channel, clean


def track_from_ytdlp(entry, channel=None, channel_id=None):
    vid = entry.get("id")
    channel = channel or entry.get("channel") or entry.get("uploader")
    channel_id = channel_id or entry.get("channel_id")
    artist, title = split_video_title(entry.get("title"), channel)
    return {
        "id": f"yt-{vid}",
        "title": title,
        "artist": artist,
        "duration": int(entry.get("duration") or 0),
        "source": "youtube",
        "youtubeId": vid,
        "coverUrl": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
        "artistRefs": [{"id": channel_id, "name": channel}] if channel_id and channel else [],
    }


def run_ytdlp(args, timeout=300):
    """yt-dlp through the configured proxy first (YouTube blocks datacenter IPs), then directly."""
    proxy = CONFIG.get("youtube_proxy")
    routes = [["--proxy", proxy], []] if proxy else [[]]
    proc = None
    for route in routes:
        proc = subprocess.run(["yt-dlp", "--no-warnings", *route, *args], capture_output=True, text=True, timeout=timeout)
        if proc.returncode == 0:
            return proc
        print(f"[yt-dlp] {'proxy' if route else 'direct'} failed: {proc.stderr.strip()[-160:]}", flush=True)
    return proc


def youtube_playlist(list_id):
    """Playlist through YouTube Music (better metadata), falling back to yt-dlp."""
    try:
        data = ytmusic(auth=has_ytmusic_auth()).get_playlist(list_id, limit=None)
        tracks = [t for t in (track_from_ytmusic(i) for i in data.get("tracks") or []) if t]
        title = data.get("title") or list_id
        owner = (data.get("author") or {}).get("name", "") if isinstance(data.get("author"), dict) else ""
        expected = int(str(data.get("trackCount") or 0).replace(",", "") or 0)
        if expected and len(tracks) < expected * 0.8:
            # YouTube Music hides plain videos; take the full list from YouTube and keep the richer metadata.
            known = {t["id"]: t for t in tracks}
            full = youtube_playlist_ytdlp(list_id)
            tracks = [known.get(t["id"], t) for t in full] if len(full) > len(tracks) else tracks
    except UserError:
        raise
    except Exception:
        proc = run_ytdlp(["--flat-playlist", "-J", f"https://www.youtube.com/playlist?list={list_id}"])
        if proc.returncode != 0:
            raise UserError("YouTube playlist could not be read (is it private?).")
        data = json.loads(proc.stdout)
        tracks = [track_from_ytdlp(e) for e in data.get("entries") or [] if e and e.get("id")]
        title, owner = data.get("title") or list_id, data.get("uploader") or ""
    playlist = {"id": f"yt-pl-{list_id}", "name": title, "source": "youtube", "owner": owner,
                "url": f"https://music.youtube.com/playlist?list={list_id}"}
    return playlist, tracks


def youtube_playlist_ytdlp(list_id):
    proc = run_ytdlp(["--flat-playlist", "-J", f"https://www.youtube.com/playlist?list={list_id}"])
    if proc.returncode != 0:
        return []
    data = json.loads(proc.stdout)
    return [track_from_ytdlp(e) for e in data.get("entries") or [] if e and e.get("id") and e.get("duration")]


YT_CHANNEL_RE = re.compile(r"youtube\.com/channel/(UC[A-Za-z0-9_-]{22})")
YT_HANDLE_RE = re.compile(r"youtube\.com/(@[^/?#&]+|c/[^/?#&]+|user/[^/?#&]+)")
YT_ALBUM_RE = re.compile(r"music\.youtube\.com/browse/(MPREb_[A-Za-z0-9_-]+)")


def largest_thumbnail(thumbnails):
    return sorted(thumbnails or [], key=lambda t: t.get("width") or 0)[-1]["url"] if thumbnails else ""


def youtube_album(browse_id):
    data = ytmusic(auth=False).get_album(browse_id)
    cover = best_thumbnail(data.get("thumbnails"))
    artists = [a for a in data.get("artists") or [] if a.get("name")]
    tracks = []
    for item in data.get("tracks") or []:
        track = track_from_ytmusic({**item, "artists": item.get("artists") or artists, "album": {"name": data.get("title"), "id": browse_id}})
        if track:
            track["coverUrl"] = cover or track["coverUrl"]
            tracks.append(track)
    playlist_id = f"yt-al-{browse_id}"
    STORE.set_image(playlist_id, cover)
    playlist = {"id": playlist_id, "name": data.get("title") or "Album", "source": "youtube", "kind": "album",
                "owner": ", ".join(a["name"] for a in artists), "url": f"https://music.youtube.com/browse/{browse_id}"}
    return playlist, tracks


_CHANNEL_IDS = {}


def resolve_channel_id(url):
    """@handle, /c/ and /user/ links -> UC… channel id."""
    if url in _CHANNEL_IDS:
        return _CHANNEL_IDS[url]
    proc = run_ytdlp(["--flat-playlist", "-J", "--playlist-end", "1", "--", url], timeout=90)
    channel_id = json.loads(proc.stdout).get("channel_id") if proc.returncode == 0 else None
    if not (channel_id or "").startswith("UC"):
        raise UserError("This YouTube channel could not be found.")
    _CHANNEL_IDS[url] = channel_id
    return channel_id


def youtube_artist_info(channel_id):
    """The channel's YouTube Music page (songs, albums, videos); None when it can't be read."""
    try:
        return ytmusic(auth=False).get_artist(channel_id)
    except Exception as e:
        print(f"[youtube] artist page {channel_id}: {type(e).__name__}: {str(e)[:120]}", flush=True)
        return None


def youtube_uploads(channel_id, limit=200):
    """A channel's uploaded videos (no Shorts). Returns (channel name, tracks)."""
    proc = run_ytdlp(["--flat-playlist", "-J", "--playlist-end", str(limit), f"https://www.youtube.com/channel/{channel_id}/videos"])
    if proc.returncode != 0:
        return None, []
    data = json.loads(proc.stdout)
    name = data.get("channel") or data.get("uploader") or ""
    thumbs = {t.get("id"): t.get("url") for t in data.get("thumbnails") or []}
    STORE.set_image(f"yt-ch-{channel_id}", thumbs.get("avatar_uncropped"), replace=False)
    STORE.set_image(f"yt-ch-{channel_id}-banner", thumbs.get("banner_uncropped"), replace=False)
    tracks = [track_from_ytdlp(e, name, channel_id) for e in data.get("entries") or [] if e and e.get("id") and e.get("duration")]
    return name, tracks


def youtube_channel(channel_id):
    """All songs of a YouTube Music artist, or a plain channel's uploads."""
    info = youtube_artist_info(channel_id) or {}
    songs = info.get("songs") or {}
    name, tracks = info.get("name"), []
    if songs.get("browseId"):
        data = ytmusic(auth=False).get_playlist(songs["browseId"], limit=None)
        tracks = [t for t in (track_from_ytmusic(i) for i in data.get("tracks") or []) if t]
    if not tracks:
        uploads_name, tracks = youtube_uploads(channel_id, limit=500)
        name = name or uploads_name
    if not tracks:
        raise UserError("This channel has no songs or videos.")
    playlist_id = f"yt-ch-{channel_id}"
    STORE.set_image(playlist_id, best_thumbnail(info.get("thumbnails")), replace=False)
    playlist = {"id": playlist_id, "name": name or "YouTube Channel", "source": "youtube", "kind": "artist",
                "owner": "Artist" if songs.get("browseId") else "Channel", "url": f"https://music.youtube.com/channel/{channel_id}"}
    return playlist, tracks


def ytmusic_liked():
    data = ytmusic(auth=True).get_liked_songs(limit=None)
    tracks = [t for t in (track_from_ytmusic(i) for i in data.get("tracks") or []) if t]
    return {"id": "yt-pl-LM", "name": "Liked Music", "source": "youtube", "owner": "YouTube Music", "url": "https://music.youtube.com/playlist?list=LM"}, tracks


_SEARCH_CACHE = {}
_SEARCH_CACHE_LOCK = threading.Lock()


def cached_search(source, query):
    """Search with a 10 minute in-memory cache; returns track dicts."""
    key = (source, query.strip().lower())
    with _SEARCH_CACHE_LOCK:
        hit = _SEARCH_CACHE.get(key)
        if hit and time.time() - hit[0] < 600:
            return hit[1]
    if source == "spotify":
        tracks = SPOTIFY.search(query, limit=30)
    elif source == "soundcloud":
        tracks = search_soundcloud(query, limit=30)
    else:
        tracks = search_youtube(query, limit=30)
    with _SEARCH_CACHE_LOCK:
        if len(_SEARCH_CACHE) > 300:
            _SEARCH_CACHE.clear()
        _SEARCH_CACHE[key] = (time.time(), tracks)
    return tracks


MATCHER = ThreadPoolExecutor(max_workers=2)
_MATCH_PENDING = set()


def warm_playlist(playlist, count=40):
    """Match the first songs of a playlist on YouTube in the background, so the first play starts faster."""
    if spotify_audio_available():
        prefetch(playlist.get("trackIds", [])[:2])  # Spotify audio needs no matching; just get the first songs ready
        return
    for track_id in playlist.get("trackIds", [])[:count]:
        track = STORE.tracks.get(track_id) or {}
        if track.get("youtubeId") or track_id in _MATCH_PENDING:
            continue
        _MATCH_PENDING.add(track_id)
        MATCHER.submit(_match_one, track_id)


def _match_one(track_id):
    try:
        track = STORE.tracks.get(track_id)
        if track and not track.get("youtubeId"):
            vid = match_on_youtube(track)
            if vid:
                STORE.upsert_tracks([{"id": track_id, "youtubeId": vid}])
    except Exception as e:
        print(f"[match] {track_id}: {e}", flush=True)
    finally:
        _MATCH_PENDING.discard(track_id)
        if not _MATCH_PENDING:
            STORE.save()


def search_youtube(query, limit=25):
    results = ytmusic(auth=False).search(query, filter="songs", limit=limit)
    tracks = [t for t in (track_from_ytmusic(r) for r in results) if t]
    if len(tracks) < 5:
        videos = ytmusic(auth=False).search(query, filter="videos", limit=10)
        tracks += [t for t in (track_from_ytmusic(r) for r in videos) if t]
    return tracks[:limit]


def _norm(text):
    text = (text or "").lower()
    text = re.sub(r"[^\w\s]", " ", text, flags=re.UNICODE)
    return re.sub(r"\s+", " ", text).strip()


def _match_score(candidate, title, artist, duration):
    """Title and artist must match; duration only breaks ties. Higher is better."""
    cand_title = _norm(candidate.get("title"))
    cand_artists = _norm(" ".join(a.get("name", "") for a in candidate.get("artists") or []))
    want_title = _norm(re.sub(r"\s*[\(\[].*?[\)\]]", "", title or ""))  # drop "(feat. …)" etc.
    title_tokens = [t for t in want_title.split() if len(t) > 1] or want_title.split()
    artist_tokens = [t for t in _norm(artist).split() if len(t) > 1]
    if not title_tokens:
        return -1
    title_hits = sum(1 for t in title_tokens if t in cand_title)
    if title_hits / len(title_tokens) < 0.6:
        return -1  # a different song, however close the length
    score = 100 * title_hits / len(title_tokens)
    if artist_tokens:
        score += 40 * sum(1 for t in artist_tokens if t in cand_artists or t in cand_title) / len(artist_tokens)
    have = candidate.get("duration_seconds") or 0
    if duration and have:
        diff = abs(have - duration)
        score += 30 if diff <= 3 else 15 if diff <= 10 else -40 if diff > 30 else 0
    for bad in ("karaoke", "cover", "nightcore", "sped up", "slowed", "remix", "mashup", "type beat", "instrumental"):
        if bad in cand_title and bad not in _norm(title):
            score -= 60
    return score


def match_on_youtube(track):
    """Find the YouTube Music song for a Spotify track by title + artist, then length."""
    query = f"{track.get('artist', '')} {track.get('title', '')}".strip()
    duration = int(track.get("duration") or 0)
    best, best_score = None, 0
    for search_filter in ("songs", "videos"):
        for candidate in ytmusic(auth=False).search(query, filter=search_filter, limit=8):
            if not candidate.get("videoId"):
                continue
            score = _match_score(candidate, track.get("title"), track.get("artist"), duration)
            if search_filter == "songs":
                score += 10  # official audio beats uploads
            if score > best_score:
                best, best_score = candidate["videoId"], score
        if best_score >= 150:
            break
    return best


# ---------------------------------------------------------------------------
# SoundCloud (the public web API, with the client id yt-dlp keeps up to date)


SC_URL_RE = re.compile(r"soundcloud\.com/([^/?#\s]+)(?:/([^/?#\s]+))?(?:/([^/?#\s]+))?")
SC_API = "https://api-v2.soundcloud.com"
SC_CLIENT_CACHE = os.path.expanduser("~/.cache/yt-dlp/soundcloud/client_id.json")
_SC_CLIENT = {"id": None}


def soundcloud_client_id(refresh=False):
    if _SC_CLIENT["id"] and not refresh:
        return _SC_CLIENT["id"]
    if refresh or not os.path.exists(SC_CLIENT_CACHE):
        # yt-dlp finds a fresh client id on soundcloud.com and caches it.
        if os.path.exists(SC_CLIENT_CACHE):
            os.remove(SC_CLIENT_CACHE)
        run_ytdlp(["--flat-playlist", "-J", "--playlist-end", "1", "https://soundcloud.com/soundcloud"], timeout=90)
    try:
        with open(SC_CLIENT_CACHE) as f:
            _SC_CLIENT["id"] = json.load(f)["data"]
    except (OSError, ValueError, KeyError):
        raise UserError("SoundCloud couldn't be reached.")
    return _SC_CLIENT["id"]


def sc_api(path_or_url, **query):
    url = path_or_url if path_or_url.startswith("http") else SC_API + path_or_url
    for attempt in range(2):
        params = {**query, "client_id": soundcloud_client_id(refresh=attempt == 1)}
        full = url + ("&" if "?" in url else "?") + urllib.parse.urlencode(params)
        try:
            return json.loads(http_get(full))
        except urllib.error.HTTPError as e:
            if e.code in (401, 403) and attempt == 0:
                continue  # the client id expired
            if e.code == 404:
                raise UserError("Not found on SoundCloud (is it private?).")
            raise


def sc_paged(path, **query):
    page = sc_api(path, limit=200, linked_partitioning=1, **query)
    items = list(page.get("collection") or [])
    while page.get("next_href"):
        page = sc_api(page["next_href"])
        items += page.get("collection") or []
    return items


def sc_artwork(url):
    return (url or "").replace("-large.", "-t500x500.")


def track_from_soundcloud(t):
    user = t.get("user") or {}
    title = t.get("title") or ""
    artist = (t.get("publisher_metadata") or {}).get("artist") or user.get("username") or ""
    if " - " in title:  # "Artist - Song" is the usual SoundCloud naming
        artist, title = split_video_title(title, artist)
    return {
        "id": f"sc-{t['id']}",
        "title": title,
        "artist": artist,
        "duration": int((t.get("duration") or t.get("full_duration") or 0) / 1000),
        "source": "soundcloud",
        "soundcloudUrl": t.get("permalink_url") or "",
        "coverUrl": sc_artwork(t.get("artwork_url") or user.get("avatar_url")),
        "artistRefs": [{"id": user.get("permalink") or str(user["id"]), "name": user.get("username") or ""}] if user.get("id") else [],
        # Go+ songs only stream a 30 second preview; those are played from YouTube / Spotify instead.
        "scPreview": t.get("policy") == "SNIP",
    }


def sc_full_tracks(tracks):
    """Sets list some songs by id only; fill those in (50 per request)."""
    missing = [str(t["id"]) for t in tracks if not t.get("title")]
    full = {}
    for i in range(0, len(missing), 50):
        for t in sc_api("/tracks", ids=",".join(missing[i:i + 50])) or []:
            full[t["id"]] = t
    return [full.get(t["id"], t) for t in tracks if t.get("title") or t["id"] in full]


def soundcloud_collection(kind, key):
    """sc-lk (a user's liked songs, without liked playlists), sc-us (uploads), sc-pl (a set)."""
    if kind == "pl":
        user, _, set_name = key.partition("~")
        url = f"https://soundcloud.com/{user}/sets/{set_name}"
        data = sc_api("/resolve", url=url)
        tracks = sc_full_tracks(data.get("tracks") or [])
        name, owner = data.get("title") or set_name, (data.get("user") or {}).get("username", "")
        image = sc_artwork(data.get("artwork_url"))
    else:
        user = sc_api("/resolve", url=f"https://soundcloud.com/{key}")
        if user.get("kind") != "user":
            raise UserError("That isn't a SoundCloud profile.")
        if kind == "lk":
            tracks = [item["track"] for item in sc_paged(f"/users/{user['id']}/likes") if item.get("track")]
            url, name = f"https://soundcloud.com/{key}/likes", f"{user.get('permalink') or key} – Likes"
        else:
            tracks = sc_paged(f"/users/{user['id']}/tracks")
            url, name = f"https://soundcloud.com/{key}/tracks", user.get("username") or key
        owner, image = user.get("username") or key, sc_artwork(user.get("avatar_url"))
    playlist_id = f"sc-{kind}-{key}"
    STORE.set_image(playlist_id, image, replace=False)
    playlist = {"id": playlist_id, "name": name, "source": "soundcloud", "kind": "playlist", "owner": owner, "url": url}
    return playlist, [track_from_soundcloud(t) for t in tracks if t.get("id")]


def soundcloud_collection_id(url):
    """soundcloud.com/<user>[/likes|/tracks|/sets/<set>] -> collection id; None for a single song."""
    if urllib.parse.urlparse(url).netloc == "on.soundcloud.com":  # short share links
        url = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": UA}), timeout=15).geturl()
    m = SC_URL_RE.search(url)
    if not m:
        return None
    user, second, third = m.groups()
    if second == "likes":
        return f"sc-lk-{user}"
    if second == "sets" and third:
        return f"sc-pl-{user}~{third}"
    if second in (None, "tracks", "popular-tracks"):
        return f"sc-us-{user}"
    return None


def search_soundcloud(query, limit=30):
    data = sc_api("/search/tracks", q=query, limit=limit)
    return [track_from_soundcloud(t) for t in data.get("collection") or [] if t.get("id")]


def soundcloud_track(url):
    return track_from_soundcloud(sc_api("/resolve", url=url))


# ---------------------------------------------------------------------------
# Imports


IMPORT_STATUS = {"running": False, "message": "", "done": 0, "total": 0}

COLLECTION_PREFIXES = ("sp-pl-", "sp-al-", "sp-ar-", "yt-pl-", "yt-al-", "yt-ch-", "sc-lk-", "sc-us-", "sc-pl-")
_COLLECTIONS = {}  # id -> (fetched at, playlist, tracks); previews are often imported right after


def fetch_collection(collection_id, fresh=False):
    """Playlist / album / artist / channel from Spotify or YouTube, as (playlist, tracks)."""
    hit = _COLLECTIONS.get(collection_id)
    if hit and not fresh and time.time() - hit[0] < 600:
        return hit[1], hit[2]
    prefix, key = collection_id[:6], collection_id[6:]
    if prefix == "sp-pl-":
        playlist, tracks = SPOTIFY.playlist(key)
    elif prefix == "sp-al-":
        playlist, tracks = SPOTIFY.album(key)
    elif prefix == "sp-ar-":
        if not SPOTIFY.has_api:
            raise UserError("Spotify artists need Spotify API keys in server/config.json.")
        playlist, tracks = SPOTIFY.artist_discography(key)
    elif prefix == "yt-pl-":
        playlist, tracks = ytmusic_liked() if key == "LM" else youtube_playlist(key)
    elif prefix == "yt-al-":
        playlist, tracks = youtube_album(key)
    elif prefix == "yt-ch-":
        playlist, tracks = youtube_channel(key)
    elif prefix.startswith("sc-"):
        playlist, tracks = soundcloud_collection(prefix[3:5], key)
    else:
        raise UserError("Unknown playlist.")
    if len(_COLLECTIONS) > 100:
        _COLLECTIONS.clear()
    _COLLECTIONS[collection_id] = (time.time(), playlist, tracks)
    return playlist, tracks


def collection_id_for_url(url):
    if "soundcloud.com" in url:
        return soundcloud_collection_id(url)
    m = SPOTIFY_URL_RE.search(url)
    if m:
        prefix = {"playlist": "sp-pl-", "album": "sp-al-", "artist": "sp-ar-"}.get(m.group(1))
        return prefix + m.group(2) if prefix else None
    if "youtube.com" not in url and "youtu.be" not in url:
        return None
    m = YT_ALBUM_RE.search(url)
    if m:
        return "yt-al-" + m.group(1)
    m = YT_LIST_RE.search(url)
    if m:
        return "yt-pl-" + m.group(1)
    m = YT_CHANNEL_RE.search(url)
    if m:
        return "yt-ch-" + m.group(1)
    if YT_HANDLE_RE.search(url):
        return "yt-ch-" + resolve_channel_id(url)
    return None


def import_url(url, fresh=False):
    """Import a playlist/album/artist/profile URL. Returns (primary playlist, imported count)."""
    url = (url or "").strip()
    if url in ("ytmusic", "ytmusic:library", "youtube music") or url.startswith("https://music.youtube.com/library"):
        if not has_ytmusic_auth():
            raise UserError("YouTube Music login is not set up on the server.")
        start_background(import_ytmusic_library)
        return None, 0

    collection_id = collection_id_for_url(url)
    if collection_id:
        playlist, tracks = fetch_collection(collection_id, fresh=fresh)
        return STORE.save_playlist(playlist, tracks), 1

    m = SPOTIFY_URL_RE.search(url)
    if m:
        kind, sid = m.groups()
        if kind == "user":
            playlists = SPOTIFY.user_playlists(sid)
            start_background(lambda: import_spotify_playlists([p["id"] for p in playlists]))
            return None, len(playlists)
        if kind == "track" and SPOTIFY.has_api:
            track = Spotify.track_from_api(SPOTIFY.api(f"/tracks/{sid}"))
            STORE.upsert_tracks([track])
            STORE.add_to_library(track["id"])
            return None, 1
        raise UserError("This Spotify link type isn't supported.")

    if "soundcloud.com" in url:
        track = soundcloud_track(url)
        STORE.upsert_tracks([track])
        STORE.add_to_library(track["id"])
        STORE.save()
        return None, 1

    m = YT_VIDEO_RE.search(url)
    if m:
        vid = m.group(1)
        proc = run_ytdlp(["-J", "--no-playlist", f"https://www.youtube.com/watch?v={vid}"], timeout=90)
        if proc.returncode != 0:
            raise UserError("YouTube video could not be read.")
        track = track_from_ytdlp(json.loads(proc.stdout))
        STORE.upsert_tracks([track])
        STORE.add_to_library(track["id"])
        STORE.save()
        return None, 1

    raise UserError("Paste a Spotify, YouTube or SoundCloud playlist, album, artist or profile link.")


def start_background(job):
    if IMPORT_STATUS["running"]:
        raise UserError("Another import is still running.")

    def run():
        IMPORT_STATUS.update(running=True, message="Importing…", done=0, total=0)
        try:
            job()
            IMPORT_STATUS["message"] = "Import finished"
        except Exception as e:
            IMPORT_STATUS["message"] = f"Import failed: {e}"
        finally:
            IMPORT_STATUS["running"] = False

    threading.Thread(target=run, daemon=True).start()


def import_spotify_playlists(playlist_ids):
    IMPORT_STATUS["total"] = len(playlist_ids)
    for pid in playlist_ids:
        try:
            playlist, tracks = SPOTIFY.playlist(pid)
            STORE.save_playlist(playlist, tracks)
        except Exception as e:
            print(f"[import] spotify {pid} failed: {e}", flush=True)
        IMPORT_STATUS["done"] += 1


def import_ytmusic_library():
    yt = ytmusic(auth=True)
    library = yt.get_library_playlists(limit=None)
    IMPORT_STATUS["total"] = len(library)
    for item in library:
        pid = item.get("playlistId")
        try:
            if pid == "LM":
                playlist, tracks = ytmusic_liked()
            elif pid and not pid.startswith("LRYR"):  # skip auto-generated yearly recaps
                playlist, tracks = youtube_playlist(pid)
            else:
                IMPORT_STATUS["done"] += 1
                continue
            STORE.save_playlist(playlist, tracks)
        except Exception as e:
            print(f"[import] ytmusic {pid} failed: {e}", flush=True)
        IMPORT_STATUS["done"] += 1


def sync_playlist(playlist_id):
    playlist = STORE.playlists.get(playlist_id)
    if not playlist or not playlist.get("url"):
        raise UserError("This playlist can't be synced.")
    if playlist_id == "yt-pl-LM":
        p, tracks = ytmusic_liked()
        return STORE.save_playlist(p, tracks)
    result, _ = import_url(playlist["url"], fresh=True)
    return result or playlist


# ---------------------------------------------------------------------------
# Audio cache


def audio_path(track_id):
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", track_id)
    return os.path.join(AUDIO_DIR, f"{safe}.m4a")


_AUDIO_LOCKS = {}
_AUDIO_LOCKS_GUARD = threading.Lock()
_DOWNLOAD_SLOTS = threading.Semaphore(3)


def lookup_track(track_id):
    track = STORE.tracks.get(track_id)
    if track:
        return track
    if track_id.startswith("yt-"):
        track = {"id": track_id, "youtubeId": track_id[3:], "source": "youtube", "coverUrl": f"https://i.ytimg.com/vi/{track_id[3:]}/hqdefault.jpg"}
    elif track_id.startswith("sp-") and SPOTIFY.has_api:
        track = Spotify.track_from_api(SPOTIFY.api(f"/tracks/{track_id[3:]}"))
    elif track_id.startswith("sc-") and track_id[3:].isdigit():
        track = track_from_soundcloud(sc_api(f"/tracks/{track_id[3:]}"))
    else:
        raise UserError("Unknown track.")
    STORE.upsert_tracks([track])
    return STORE.tracks[track_id]


try:
    import spotify_dl as _sdl  # librespot: real Spotify audio for Spotify tracks (needs a Premium login on the server)
except Exception:
    _sdl = None


def _warm_spotify_session():
    # Logging in to librespot takes ~5 s; do it at startup instead of on the first play.
    # Spotify's servers sometimes refuse the first connection, so try a few times.
    for attempt in range(5):
        try:
            if _sdl and _sdl.is_logged_in():
                _sdl._get_session()
            return
        except Exception as e:
            print(f"[audio] librespot login failed (attempt {attempt + 1}): {e}", flush=True)
            time.sleep(5 * (attempt + 1))


threading.Thread(target=_warm_spotify_session, daemon=True).start()


def spotify_audio_available():
    try:
        return bool(_sdl and _sdl.is_logged_in())
    except Exception:
        return False


# librespot's session is a single connection: concurrent downloads break it ("Bad file descriptor").
_SPOTIFY_LOCK = threading.Lock()

# librespot has no timeouts: on a dead connection a download waits forever, and every later
# Spotify song would queue up behind it. A download that stops growing for this long is abandoned.
_SPOTIFY_STALL_SECONDS = 20


def _download_ogg_watched(spotify_id, ogg):
    failure = []

    def run():
        try:
            _sdl.download_ogg(spotify_id, ogg)
        except Exception as e:
            failure.append(e)

    worker = threading.Thread(target=run, daemon=True)
    worker.start()
    size, stalled = -1, 0
    while worker.is_alive():
        worker.join(1)
        current = os.path.getsize(ogg) if os.path.exists(ogg) else 0
        stalled = stalled + 1 if current == size else 0
        size = current
        if stalled >= _SPOTIFY_STALL_SECONDS:
            raise RuntimeError("librespot stopped responding")
    if failure:
        raise failure[0]


def _download_ogg(spotify_id, ogg):
    """One librespot download at a time; a dead connection gets a fresh session and one retry."""
    with _SPOTIFY_LOCK:
        for attempt in range(2):
            try:
                _download_ogg_watched(spotify_id, ogg)
                if os.path.getsize(ogg) > 10000:
                    return
                raise RuntimeError("empty download")
            except Exception as e:
                message = str(e)
                if "alternative track" in message or attempt == 1:
                    raise  # not available on Spotify for this account/region
                print(f"[audio] librespot error ({message}); reconnecting", flush=True)
                _sdl.reset_session()
                if os.path.exists(ogg):
                    os.remove(ogg)  # an abandoned download may still be writing to the old file


def _encode_aac(src, out_path, coder):
    """Ogg -> AAC 256 .m4a. 1 dB of headroom: loud masters decode slightly above 0 dBFS and would clip on the phone."""
    tmp_out = out_path + f".{coder}.tmp.m4a"
    conv = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-vn", "-af", "volume=-1dB",
                           "-c:a", "aac", "-aac_coder", coder, "-b:a", "256k", "-movflags", "+faststart", tmp_out],
                          capture_output=True, text=True, timeout=900)
    if conv.returncode != 0:
        raise UserError(f"Conversion failed: {conv.stderr.strip()[-200:]}")
    os.replace(tmp_out, out_path)
    marker = out_path + ".hq"
    if coder == "twoloop":
        open(marker, "w").close()
    elif os.path.exists(marker):
        os.remove(marker)


_HQ_ENCODER = ThreadPoolExecutor(max_workers=1)


def download_spotify_audio(spotify_id, out_path, urgent=False):
    """Spotify Ogg 320 via librespot -> AAC 256 .m4a.

    The best AAC coder (twoloop) takes ~12 s per song, the fast one ~4 s but sounds worse.
    Prefetched songs get the best one; a song someone is waiting for is encoded fast first
    and quietly replaced with the better encode a little later.
    """
    tmpdir = tempfile.mkdtemp(prefix="p7s_")
    keep = False
    try:
        ogg = os.path.join(tmpdir, "src.ogg")
        _download_ogg(spotify_id, ogg)
        _encode_aac(ogg, out_path, "fast" if urgent else "twoloop")
        if urgent:
            keep = True
            _HQ_ENCODER.submit(_upgrade_encode, ogg, out_path, tmpdir)
    finally:
        if not keep:
            shutil.rmtree(tmpdir, ignore_errors=True)


def _upgrade_encode(ogg, out_path, tmpdir):
    try:
        _encode_aac(ogg, out_path, "twoloop")
    except Exception as e:
        print(f"[audio] high quality encode of {os.path.basename(out_path)} failed: {e}", flush=True)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def ensure_audio(track_id, urgent=False):
    """Download + convert the track if needed; returns the cached .m4a path. `urgent`: someone is waiting to play it."""
    path = audio_path(track_id)
    if os.path.exists(path):
        return path
    with _AUDIO_LOCKS_GUARD:
        lock = _AUDIO_LOCKS.setdefault(track_id, threading.Lock())
    with lock:
        if os.path.exists(path):
            return path
        track = lookup_track(track_id)
        if track.get("spotifyId") and spotify_audio_available():
            try:
                with _DOWNLOAD_SLOTS:
                    download_spotify_audio(track["spotifyId"], path, urgent=urgent)
                return path
            except Exception as e:
                print(f"[audio] librespot failed for {track_id}, using YouTube: {e}", flush=True)
        if track.get("soundcloudUrl") and not track.get("scPreview"):
            try:
                with _DOWNLOAD_SLOTS:
                    download_audio(None, path, url=track["soundcloudUrl"])
                return path
            except UserError as e:
                print(f"[audio] SoundCloud failed for {track_id}, looking elsewhere: {str(e)[:120]}", flush=True)
        vid = track.get("youtubeId")
        if not vid:
            vid = match_on_youtube(track)
            if not vid:
                raise UserError("Couldn't find this song on YouTube.")
            STORE.upsert_tracks([{"id": track_id, "youtubeId": vid}])
            STORE.save()
        try:
            with _DOWNLOAD_SLOTS:
                download_audio(vid, path)
            return path
        except UserError as e:
            spotify_id = None if track.get("spotifyId") or not spotify_audio_available() else match_on_spotify(track)
            if not spotify_id:
                raise
            print(f"[audio] YouTube failed for {track_id} ({str(e)[:80]}); playing Spotify {spotify_id}", flush=True)
            with _DOWNLOAD_SLOTS:
                download_spotify_audio(spotify_id, path, urgent=urgent)
            return path


def match_on_spotify(track):
    """The same song on Spotify by title + artist (+ length when known); None unless it's a confident match."""
    if not SPOTIFY.has_api or not track.get("title"):
        return None
    duration = int(track.get("duration") or 0)
    best, best_score = None, 0
    try:
        candidates = SPOTIFY.search(f"{track.get('artist', '')} {track['title']}".strip(), limit=8)
    except Exception as e:
        print(f"[match] spotify search failed: {e}", flush=True)
        return None
    for c in candidates:
        score = _match_score({"title": c["title"], "artists": [{"name": c["artist"]}], "duration_seconds": c["duration"]},
                             track.get("title"), track.get("artist"), duration)
        if score > best_score:
            best, best_score = c, score
    return best["spotifyId"] if best and best_score >= (150 if duration else 135) else None


def download_audio(video_id, out_path, url=None):
    """YouTube video (or any yt-dlp URL, e.g. SoundCloud) -> AAC .m4a."""
    url = url or f"https://www.youtube.com/watch?v={video_id}"
    tmpdir = tempfile.mkdtemp(prefix="p7_")
    try:
        # YouTube sometimes answers 403 for a moment; a second attempt usually goes through.
        for attempt in range(3):
            # SoundCloud: AAC when offered, else MP3 128 (better than its 64k Opus stream).
            formats = "bestaudio[ext=m4a]/bestaudio[acodec=mp3]/bestaudio/best" if "soundcloud.com" in url else "140/bestaudio[ext=m4a]/bestaudio/best"
            proc = run_ytdlp(["-f", formats, "--no-playlist", "--retries", "3", "--fragment-retries", "3",
                              "-o", os.path.join(tmpdir, "src.%(ext)s"), "--", url], timeout=600)
            src = next((os.path.join(tmpdir, n) for n in os.listdir(tmpdir) if n.startswith("src.") and not n.endswith(".part")), None)
            if proc.returncode == 0 and src:
                break
            time.sleep(1.5 * (attempt + 1))
        if proc.returncode != 0 or not src:
            raise UserError(f"Download failed: {proc.stderr.strip()[-200:]}")
        tmp_out = os.path.join(tmpdir, "out.m4a")
        codec = ["-c:a", "copy"] if src.endswith(".m4a") else ["-c:a", "aac", "-b:a", "192k"]
        conv = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-vn", *codec,
                               "-movflags", "+faststart", tmp_out], capture_output=True, text=True, timeout=600)
        if conv.returncode != 0:
            raise UserError(f"Conversion failed: {conv.stderr.strip()[-200:]}")
        shutil.move(tmp_out, out_path)
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


PREFETCH = ThreadPoolExecutor(max_workers=2)


def upgrade_cached_spotify_audio():
    """Songs cached before the high quality encode existed get re-made, one at a time, in the background."""
    time.sleep(30)  # let startup (and the Spotify login) settle first
    if not spotify_audio_available():
        return
    names = sorted(n for n in os.listdir(AUDIO_DIR) if n.startswith("sp-") and n.endswith(".m4a") and not os.path.exists(os.path.join(AUDIO_DIR, n + ".hq")))
    if names:
        print(f"[audio] re-encoding {len(names)} cached Spotify songs in high quality", flush=True)
    for name in names:
        track_id = name[:-4]
        track = STORE.tracks.get(track_id) or {}
        spotify_id = track.get("spotifyId") or track_id[3:]
        with _AUDIO_LOCKS_GUARD:
            lock = _AUDIO_LOCKS.setdefault(track_id, threading.Lock())
        try:
            with lock, _DOWNLOAD_SLOTS:
                download_spotify_audio(spotify_id, audio_path(track_id))
        except Exception as e:
            print(f"[audio] re-encode {track_id} skipped: {e}", flush=True)
            if "audio key" in str(e):
                time.sleep(600)  # Spotify is throttling downloads; back off for a while
        # Slowly: many downloads in a row look like bulk ripping to Spotify.
        time.sleep(40)


threading.Thread(target=upgrade_cached_spotify_audio, daemon=True).start()


def prefetch(track_ids):
    for track_id in track_ids[:5]:
        if not os.path.exists(audio_path(track_id)):
            PREFETCH.submit(_safe_ensure, track_id)


def _safe_ensure(track_id):
    try:
        ensure_audio(track_id)
    except Exception as e:
        print(f"[prefetch] {track_id}: {e}", flush=True)


# ---------------------------------------------------------------------------
# Covers


def spotify_cover(spotify_id):
    """Album art for a Spotify track via the public oEmbed endpoint (no API keys needed)."""
    try:
        data = json.loads(http_get(f"https://open.spotify.com/oembed?url=https://open.spotify.com/track/{spotify_id}"))
    except Exception:
        return ""
    url = data.get("thumbnail_url") or ""
    # ab67616d00001e02 = 300px; ab67616d0000b273 = 640px of the same image.
    return url.replace("ab67616d00001e02", "ab67616d0000b273")


def cover_path(item_id, size, url, wide=False):
    safe = re.sub(r"[^A-Za-z0-9_-]", "_", item_id)
    version = hashlib.md5(url.encode()).hexdigest()[:6]
    return os.path.join(COVER_DIR, f"{safe}_{size}{'w' if wide else ''}_{version}.jpg")


def is_entity_id(item_id):
    """Artists, albums and playlists (as opposed to songs) have their own pictures."""
    return item_id in STORE.images or (item_id not in STORE.tracks and item_id.startswith(COLLECTION_PREFIXES) and len(item_id) > 14)


def cover_url(item_id):
    if is_entity_id(item_id):
        url = STORE.images.get(item_id)
        if not url and item_id in STORE.playlists:
            first = next((STORE.tracks[i] for i in STORE.playlists[item_id]["trackIds"] if i in STORE.tracks), {})
            url = first.get("coverUrl")
        if not url:
            raise UserError("No cover.")
        return url
    track = lookup_track(item_id)
    url = track.get("coverUrl")
    if (not url or "mosaic.scdn.co" in url) and track.get("spotifyId"):
        url = spotify_cover(track["spotifyId"])
        if url:
            STORE.upsert_tracks([{"id": item_id, "coverUrl": url}])
            STORE.save()
    if not url or "mosaic.scdn.co" in url:
        raise UserError("No cover.")
    return url


def ensure_cover(item_id, size, wide=False):
    """Square JPEG of the cover (or, for banners, scaled to `size` wide)."""
    size = max(60, min(1200, int(size or 300)))
    url = cover_url(item_id)
    path = cover_path(item_id, size, url, wide)
    if os.path.exists(path):
        return path
    tmpdir = tempfile.mkdtemp(prefix="p7c_")
    try:
        src = os.path.join(tmpdir, "src")
        with open(src, "wb") as f:
            f.write(http_get(url))
        crop = "crop='min(iw,ih)':'min(iw,ih)'"
        scale = f"scale={size}:-2" if wide else f"{crop},scale={size}:{size}"
        proc = subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", src, "-vf", scale,
                               "-q:v", "3", os.path.join(tmpdir, "out.jpg")], capture_output=True, timeout=60)
        if proc.returncode != 0:
            raise UserError("Cover conversion failed.")
        shutil.move(os.path.join(tmpdir, "out.jpg"), path)
        return path
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
