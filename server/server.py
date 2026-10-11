#!/usr/bin/env python3
"""Mini audio server for ios7-player.

Endpoints:
  GET /meta?url=<spotify|youtube>              -> JSON {title, artist, duration, source}
  GET /search?q=<query>&n=<limit>              -> JSON [{id, title, artist, duration, url}]
  GET /track?url=<spotify|youtube>&fmt=mp3|aiff|m4a[&br=192]
                                               -> audio stream (default mp3 192kbps)

Player7 app API (library.py), every call takes ?token= when a token is configured:
  GET  /api/ping
  GET  /api/playlists                          -> {playlists: [...]}
  GET  /api/playlists/<id>                     -> {playlist: {..., tracks: [...]}}
  POST /api/playlists/<id>/sync                -> re-import from Spotify/YouTube
  POST /api/playlists/<id>/delete
  GET  /api/tracks[?q=]                        -> {tracks: [...]} library songs
  GET  /api/tracks/<id>/stream                 -> cached AAC .m4a, supports Range
  GET  /api/tracks/<id>/cover?size=N           -> square jpeg
  GET  /api/search?q=&source=spotify|youtube   -> {tracks: [...]}
  POST /api/import {url}                       -> {playlist} (profiles/YT Music library run in background)
  GET  /api/import/status
  POST /api/library {trackId, remove?, track?} -> add/remove a song in "Songs" (track: details of a YouTube song found on the phone)
  POST /api/prefetch {ids: [...]}              -> warm the audio cache
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# Always run inside server/.venv (it has ytmusicapi), even when started with a plain `python3 server.py`.
_VENV_PYTHON = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".venv", "bin", "python")
if os.path.exists(_VENV_PYTHON) and os.path.realpath(sys.prefix) != os.path.realpath(os.path.join(os.path.dirname(_VENV_PYTHON), "..")):
    os.execv(_VENV_PYTHON, [_VENV_PYTHON, os.path.abspath(__file__), *sys.argv[1:]])
# Prefer the yt-dlp installed next to this Python (pip keeps it current) over an older system one.
os.environ["PATH"] = os.path.dirname(sys.executable) + os.pathsep + os.environ.get("PATH", "")

import library as lib
import browse
import lastfm
try:
    import spotify_dl as sdl
    _HAS_LIBRESPOT = True
except Exception:
    sdl = None
    _HAS_LIBRESPOT = False

HOST = "0.0.0.0"
PORT = int(os.environ.get("PORT", "8787"))

SPOTIFY_TRACK_RE = re.compile(r"open\.spotify\.com/(?:intl-[a-z]+/)?track/([A-Za-z0-9]+)")
YT_URL_RE = re.compile(r"(youtube\.com|youtu\.be|music\.youtube\.com)")

UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Safari/605.1.15"


def http_get(url, timeout=15):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept-Language": "en-US,en;q=0.9"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read().decode("utf-8", errors="replace")


def spotify_meta(track_id):
    """Scrape title + artist from Spotify embed page (no auth)."""
    html = http_get(f"https://open.spotify.com/embed/track/{track_id}")
    m = re.search(r'<script id="__NEXT_DATA__"[^>]*>(.+?)</script>', html, re.S)
    if not m:
        raise RuntimeError("spotify embed: no __NEXT_DATA__")
    data = json.loads(m.group(1))
    entity = data["props"]["pageProps"]["state"]["data"]["entity"]
    title = entity.get("title") or entity.get("name") or ""
    artists = entity.get("artists") or []
    artist = ", ".join(a.get("name", "") for a in artists) if artists else entity.get("subtitle", "")
    duration_ms = entity.get("duration", 0) or 0
    return {
        "title": title,
        "artist": artist,
        "duration": int(duration_ms / 1000) if duration_ms else 0,
        "source": "spotify",
        "spotify_id": track_id,
    }


def ytdlp_json(args):
    """Run yt-dlp -J; return parsed JSON (dict or list)."""
    proc = subprocess.run(
        ["yt-dlp", "-J", "--no-warnings", "--no-playlist", "--", *args],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp failed: {proc.stderr.strip()[:300]}")
    return json.loads(proc.stdout)


def yt_search(query, n=1):
    data = ytdlp_json([f"ytsearch{n}:{query}"])
    entries = data.get("entries", []) or []
    out = []
    for e in entries:
        out.append({
            "id": e.get("id"),
            "title": e.get("title"),
            "artist": e.get("uploader") or e.get("channel") or "",
            "duration": e.get("duration") or 0,
            "url": f"https://www.youtube.com/watch?v={e.get('id')}",
        })
    return out


def yt_meta(url):
    d = ytdlp_json([url])
    return {
        "title": d.get("title"),
        "artist": d.get("uploader") or d.get("channel") or "",
        "duration": d.get("duration") or 0,
        "source": "youtube",
        "youtube_id": d.get("id"),
    }


def _norm_text(s):
    s = (s or "").lower()
    s = re.sub(r"[\(\[].*?[\)\]]", " ", s)  # drop parentheticals (remix, feat, etc.)
    s = re.sub(r"[^\w\s]", " ", s, flags=re.UNICODE)
    return re.sub(r"\s+", " ", s).strip()


def _score_candidate(hit, want_title, want_artist, want_dur):
    """Higher = better. Duration match dominates; title/artist tokens matter next."""
    cand_title = _norm_text(hit.get("title"))
    cand_artist = _norm_text(hit.get("artist"))
    w_title = _norm_text(want_title)
    w_artist = _norm_text(want_artist)
    cand_dur = int(hit.get("duration") or 0)

    score = 0.0
    # duration proximity (within 3s = perfect, 10s = ok, >30s = -heavy)
    if want_dur > 0 and cand_dur > 0:
        delta = abs(cand_dur - want_dur)
        if delta <= 3: score += 100
        elif delta <= 10: score += 60
        elif delta <= 20: score += 20
        elif delta > 40: score -= 150

    haystack = cand_title + " " + cand_artist
    # artist tokens (strongest signal for niche tracks)
    for tok in w_artist.split():
        if len(tok) >= 2 and tok in haystack:
            score += 25
    # title tokens
    for tok in w_title.split():
        if len(tok) >= 2 and tok in haystack:
            score += 10

    # penalties
    bad = ["karaoke", "cover by", "nightcore", "sped up", "slowed", "8d audio",
           "reaction", "tutorial", "lesson", "guitar cover", "piano cover", "remix"]
    for b in bad:
        if b in haystack: score -= 30

    # bonuses
    good = ["official audio", "official video", "official music video", "topic"]
    for g in good:
        if g in haystack: score += 15
    # YouTube "Artist - Topic" auto-channels are reliable
    if " - topic" in cand_artist or cand_artist.endswith("topic"):
        score += 40

    return score


def best_yt_for_spotify(meta):
    """Try several YouTube queries and return the best match for a Spotify track."""
    title = meta.get("title") or ""
    artist = meta.get("artist") or ""
    dur = int(meta.get("duration") or 0)
    first_artist = (artist.split(",")[0] or "").strip()

    queries = [
        f'"{first_artist}" "{title}"',
        f'{first_artist} {title}',
        f'{artist} {title} audio',
        f'{first_artist} {title} official',
    ]

    seen = {}
    for q in queries:
        try:
            hits = yt_search(q, n=5)
        except Exception:
            continue
        for h in hits:
            vid = h.get("id")
            if not vid or vid in seen:
                continue
            seen[vid] = h

    if not seen:
        return None, []

    scored = [(h, _score_candidate(h, title, first_artist, dur)) for h in seen.values()]
    scored.sort(key=lambda x: -x[1])
    best = scored[0][0]
    return best, scored


def resolve_source(url):
    """Return (youtube_url, meta_dict). Spotify -> search on YouTube with duration verification."""
    if SPOTIFY_TRACK_RE.search(url):
        tid = SPOTIFY_TRACK_RE.search(url).group(1)
        meta = spotify_meta(tid)
        best, scored = best_yt_for_spotify(meta)
        if not best:
            raise RuntimeError("no youtube match for spotify track")
        meta["youtube_id"] = best["id"]
        meta["match_score"] = scored[0][1] if scored else 0
        meta["match_title"] = best.get("title")
        meta["match_duration"] = best.get("duration")
        return best["url"], meta
    if YT_URL_RE.search(url):
        return url, yt_meta(url)
    raise RuntimeError("unsupported url (need spotify track or youtube)")


def transcode_cmd(src_path, fmt, bitrate, out_path=None):
    """Build ffmpeg command. For m4a, output must be a seekable file."""
    base = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-i", src_path, "-vn", "-map_metadata", "0"]
    if fmt == "mp3":
        return base + ["-c:a", "libmp3lame", "-b:a", f"{bitrate}k", "-f", "mp3", "pipe:1"], "audio/mpeg", True
    if fmt == "aiff":
        return base + ["-c:a", "pcm_s16be", "-f", "aiff", "pipe:1"], "audio/aiff", True
    if fmt == "m4a":
        return base + ["-c:a", "aac", "-b:a", f"{bitrate}k", "-movflags", "+faststart", "-f", "ipod", out_path], "audio/mp4", False
    if fmt == "wav":
        return base + ["-c:a", "pcm_s16le", "-f", "wav", "pipe:1"], "audio/wav", True
    raise ValueError(f"unknown fmt: {fmt}")


def safe_filename(s, maxlen=120):
    s = re.sub(r"[\\/:*?\"<>|\x00-\x1f]", "_", s or "").strip()
    return (s[:maxlen] or "track").rstrip(". ")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        line = re.sub(r"token=[^&\s\"]+", "token=***", fmt % args)  # keep the token out of logs
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), line))

    def _json(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def _err(self, status, msg):
        self._json(status, {"error": msg})

    # ---- Player7 app API ------------------------------------------------

    def _api_authorized(self, qs):
        token = lib.CONFIG.get("token")
        return not token or (qs.get("token") or [""])[0] == token

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        except ValueError:
            return {}

    def _api(self, method, route, qs):
        if not self._api_authorized(qs):
            return self._err(401, "Wrong token.")
        parts = [urllib.parse.unquote(p) for p in route.split("/")[2:]]  # after /api/
        try:
            if method in ("GET", "HEAD"):
                return self._api_get(parts, qs, head=method == "HEAD")
            return self._api_post(parts, self._read_json())
        except lib.UserError as e:
            return self._err(400, str(e))
        except Exception as e:
            sys.stderr.write(f"[api] {route}: {type(e).__name__}: {e}\n")
            try:
                return self._err(500, f"{type(e).__name__}: {e}")
            except Exception:
                pass

    def _api_get(self, parts, qs, head=False):
        q = lambda key, default="": (qs.get(key) or [default])[0]
        if parts == ["ping"]:
            return self._json(200, {"ok": True, "spotifyApi": lib.SPOTIFY.has_api, "youtubeMusicLogin": lib.has_ytmusic_auth()})
        if parts == ["playlists"]:
            playlists = sorted(lib.STORE.playlists.values(), key=lambda p: (p.get("name") or "").lower())
            return self._json(200, {"playlists": [lib.public_playlist(p) for p in playlists]})
        if len(parts) == 2 and parts[0] == "playlists":
            playlist = lib.STORE.playlists.get(parts[1])
            if not playlist:
                return self._err(404, "Playlist not found.")
            lib.warm_playlist(playlist)
            return self._json(200, {"playlist": lib.public_playlist(playlist, with_tracks=True)})
        if parts == ["tracks"]:
            query = q("q").lower()
            tracks = [lib.STORE.tracks[i] for i in lib.STORE.library_ids() if i in lib.STORE.tracks]
            if query:
                tracks = [t for t in tracks if query in f"{t.get('title', '')} {t.get('artist', '')} {t.get('album', '')}".lower()]
            return self._json(200, {"tracks": [lib.public_track(t) for t in tracks]})
        if len(parts) == 3 and parts[0] == "tracks" and parts[2] == "stream":
            return self._send_file(lib.ensure_audio(parts[1], urgent=True), "audio/mp4", head=head)
        if len(parts) == 3 and parts[0] == "tracks" and parts[2] == "cover":
            return self._send_file(lib.ensure_cover(parts[1], q("size", "300"), wide=q("wide") == "1"), "image/jpeg", head=head, cache=True)
        if len(parts) == 3 and parts[0] == "tracks" and parts[2] == "artists":
            return self._json(200, {"artists": browse.track_artists(parts[1])})
        if len(parts) == 2 and parts[0] == "artists":
            return self._json(200, {"artist": browse.artist_page(parts[1])})
        if len(parts) == 2 and parts[0] == "collections":
            return self._json(200, {"playlist": browse.collection_page(parts[1])})
        if parts == ["search"]:
            query, source = q("q").strip(), q("source") if q("source") in ("spotify", "soundcloud") else "youtube"
            if not query:
                return self._json(200, {"tracks": [], "artists": [], "albums": [], "playlists": []})
            if q("full") == "1":
                result = dict(browse.search_all(source, query))
            else:
                result = {"tracks": lib.cached_search(source, query)}
            lib.STORE.upsert_tracks(result["tracks"])
            result["tracks"] = [lib.public_track(lib.STORE.tracks[t["id"]]) for t in result["tracks"]]
            return self._json(200, result)
        if parts == ["import", "status"]:
            return self._json(200, lib.IMPORT_STATUS)
        if parts == ["lastfm"]:
            return self._json(200, lastfm.status())
        return self._err(404, "no such route")

    def _api_post(self, parts, body):
        if parts == ["import"]:
            playlist, count = lib.import_url(body.get("url"))
            if playlist:
                return self._json(200, {"playlist": lib.public_playlist(playlist, with_tracks=True), "imported": count})
            return self._json(200, {"playlist": None, "imported": count, "background": lib.IMPORT_STATUS["running"]})
        if len(parts) == 3 and parts[0] == "playlists" and parts[2] == "sync":
            playlist = lib.sync_playlist(parts[1])
            return self._json(200, {"playlist": lib.public_playlist(playlist, with_tracks=True)})
        if len(parts) == 3 and parts[0] == "playlists" and parts[2] == "delete":
            lib.STORE.delete_playlist(parts[1])
            return self._json(200, {"ok": True})
        if parts == ["library"]:
            track_id = body.get("trackId") or ""
            lib.remember_phone_track(track_id, body.get("track"))
            lib.lookup_track(track_id)
            if body.get("remove"):
                lib.STORE.remove_from_library(track_id)
            else:
                lib.STORE.add_to_library(track_id)
            return self._json(200, {"ok": True})
        if len(parts) == 2 and parts[0] == "lastfm":
            action = parts[1]
            if action == "connect":
                return self._json(200, lastfm.connect())
            if action == "finish":
                return self._json(200, lastfm.finish())
            if action == "disconnect":
                return self._json(200, lastfm.disconnect())
            if action == "nowplaying":
                return self._json(200, lastfm.now_playing(body))
            if action == "scrobble":
                return self._json(200, lastfm.scrobble([i for i in body.get("scrobbles") or [] if isinstance(i, dict)]))
            if action == "love":
                return self._json(200, lastfm.love(body, loved=body.get("loved", True)))
        if parts == ["prefetch"]:
            lib.prefetch([i for i in body.get("ids") or [] if isinstance(i, str)])
            return self._json(200, {"ok": True})
        return self._err(404, "no such route")

    def _send_file(self, path, mime, head=False, cache=False):
        """Serve a file with HTTP Range support (AVPlayer needs it to seek)."""
        size = os.path.getsize(path)
        start, end = 0, size - 1
        status = 200
        range_header = self.headers.get("Range")
        if range_header:
            m = re.match(r"bytes=(\d*)-(\d*)", range_header)
            if m:
                if m.group(1):
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else size - 1
                elif m.group(2):
                    start = max(0, size - int(m.group(2)))
                end = min(end, size - 1)
                if start > end:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.end_headers()
                    return
                status = 206
        self.send_response(status)
        self.send_header("Content-Type", mime)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        if cache:
            self.send_header("Cache-Control", "public, max-age=604800")
        self.end_headers()
        if head:
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = end - start + 1
            while remaining > 0:
                chunk = f.read(min(64 * 1024, remaining))
                if not chunk:
                    break
                try:
                    self.wfile.write(chunk)
                except (BrokenPipeError, ConnectionResetError):
                    return
                remaining -= len(chunk)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        if route.startswith("/api/"):
            return self._api("POST", route, urllib.parse.parse_qs(parsed.query))
        return self._err(404, "no such route")

    def do_HEAD(self):
        parsed = urllib.parse.urlparse(self.path)
        route = parsed.path.rstrip("/") or "/"
        if route.startswith("/api/"):
            return self._api("HEAD", route, urllib.parse.parse_qs(parsed.query))
        self.send_response(405)
        self.end_headers()

    # ---- original endpoints ---------------------------------------------

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        qs = urllib.parse.parse_qs(parsed.query)
        route = parsed.path.rstrip("/") or "/"

        if route.startswith("/api/"):
            return self._api("GET", route, qs)

        try:
            if route == "/" or route == "/health":
                return self._json(200, {"ok": True, "service": "ios7-player-server"})

            # Everything below requires the token (if one is configured)
            if not self._api_authorized(qs):
                return self._err(401, "Wrong or missing token.")

            if route == "/meta":
                url = (qs.get("url") or [""])[0]
                if not url:
                    return self._err(400, "missing url")
                if SPOTIFY_TRACK_RE.search(url):
                    tid = SPOTIFY_TRACK_RE.search(url).group(1)
                    return self._json(200, spotify_meta(tid))
                if YT_URL_RE.search(url):
                    return self._json(200, yt_meta(url))
                return self._err(400, "unsupported url")

            if route == "/search":
                q = (qs.get("q") or [""])[0]
                if not q:
                    return self._err(400, "missing q")
                n = max(1, min(10, int((qs.get("n") or ["5"])[0])))
                return self._json(200, yt_search(q, n=n))

            if route == "/track":
                url = (qs.get("url") or [""])[0]
                if not url:
                    return self._err(400, "missing url")
                fmt = (qs.get("fmt") or ["m4a"])[0].lower()
                try:
                    bitrate = max(64, min(320, int((qs.get("br") or ["256"])[0])))
                except ValueError:
                    bitrate = 192
                force_source = (qs.get("source") or [""])[0].lower()  # "spotify" | "youtube" | ""

                # Spotify URL + librespot logged in -> direct Ogg 320 (unless force=youtube)
                sp_m = SPOTIFY_TRACK_RE.search(url)
                if sp_m and force_source != "youtube" and _HAS_LIBRESPOT and sdl.is_logged_in():
                    try:
                        return self._stream_from_spotify(sp_m.group(1), fmt, bitrate)
                    except Exception as e:
                        sys.stderr.write(f"[track] librespot failed, falling back to YT: {type(e).__name__}: {e}\n")

                yt_url, meta = resolve_source(url)
                return self._stream_track(yt_url, meta, fmt, bitrate)

            return self._err(404, "no such route")

        except Exception as e:
            try:
                return self._err(500, f"{type(e).__name__}: {e}")
            except Exception:
                pass

    def _stream_from_spotify(self, spotify_id, fmt, bitrate):
        """Download Ogg Vorbis via librespot-python then transcode and stream."""
        tmpdir = tempfile.mkdtemp(prefix="ios7sp_")
        try:
            try:
                meta = sdl.get_track_meta(spotify_id)
            except Exception:
                meta = {}
            meta["source"] = "spotify"
            meta["spotify_id"] = spotify_id

            ogg_path = os.path.join(tmpdir, "src.ogg")
            sdl.download_ogg(spotify_id, ogg_path)

            return self._stream_prepared(tmpdir, ogg_path, meta, fmt, bitrate)
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)

    def _stream_prepared(self, tmpdir, src_path, meta, fmt, bitrate):
        """Shared tail: transcode src_path (any input) and stream to the client."""
        out_path = os.path.join(tmpdir, f"out.{fmt}")
        cmd, mime, pipeable = transcode_cmd(src_path, fmt, bitrate, out_path=out_path)
        fname = safe_filename(f"{meta.get('artist','')} - {meta.get('title','')}".strip(" -")) + f".{fmt}"

        def send_headers(content_length=None):
            self.send_response(200)
            self.send_header("Content-Type", mime)
            self.send_header("Content-Disposition", f'inline; filename="{fname}"')
            self.send_header("X-Title", urllib.parse.quote(meta.get("title") or ""))
            self.send_header("X-Artist", urllib.parse.quote(meta.get("artist") or ""))
            self.send_header("X-Duration", str(meta.get("duration") or 0))
            self.send_header("X-Source", meta.get("source") or "")
            self.send_header("Access-Control-Allow-Origin", "*")
            if content_length is not None:
                self.send_header("Content-Length", str(content_length))
                self.send_header("Accept-Ranges", "bytes")
            else:
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()

        if pipeable:
            send_headers()
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                while True:
                    chunk = proc.stdout.read(64 * 1024)
                    if not chunk:
                        break
                    try:
                        size = b"%X\r\n" % len(chunk)
                        self.wfile.write(size + chunk + b"\r\n")
                    except (BrokenPipeError, ConnectionResetError):
                        proc.kill()
                        return
                try:
                    self.wfile.write(b"0\r\n\r\n")
                except Exception:
                    pass
                proc.wait(timeout=10)
            finally:
                if proc.poll() is None:
                    proc.kill()
        else:
            proc = subprocess.run(cmd, capture_output=True, timeout=300)
            if proc.returncode != 0 or not os.path.exists(out_path):
                return self._err(500, f"transcode failed: {proc.stderr.decode(errors='replace').strip()[:300]}")
            size = os.path.getsize(out_path)
            send_headers(content_length=size)
            with open(out_path, "rb") as f:
                while True:
                    chunk = f.read(64 * 1024)
                    if not chunk:
                        break
                    try:
                        self.wfile.write(chunk)
                    except (BrokenPipeError, ConnectionResetError):
                        return

    def _stream_track(self, yt_url, meta, fmt, bitrate):
        tmpdir = tempfile.mkdtemp(prefix="ios7srv_")
        src_tmpl = os.path.join(tmpdir, "src.%(ext)s")
        try:
            dl = subprocess.run(
                ["yt-dlp", "-f", "bestaudio/best", "--no-playlist", "--no-warnings",
                 "-o", src_tmpl, "--", yt_url],
                capture_output=True, text=True, timeout=300,
            )
            if dl.returncode != 0:
                return self._err(502, f"yt-dlp download failed: {dl.stderr.strip()[:300]}")

            src = None
            for name in os.listdir(tmpdir):
                if name.startswith("src."):
                    src = os.path.join(tmpdir, name)
                    break
            if not src:
                return self._err(500, "download produced no file")

            out_path = os.path.join(tmpdir, f"out.{fmt}")
            cmd, mime, pipeable = transcode_cmd(src, fmt, bitrate, out_path=out_path)
            fname = safe_filename(f"{meta.get('artist','')} - {meta.get('title','')}".strip(" -")) + f".{fmt}"

            headers_sent = False

            def send_headers(content_length=None):
                self.send_response(200)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Disposition", f'inline; filename="{fname}"')
                self.send_header("X-Title", urllib.parse.quote(meta.get("title") or ""))
                self.send_header("X-Artist", urllib.parse.quote(meta.get("artist") or ""))
                self.send_header("X-Duration", str(meta.get("duration") or 0))
                self.send_header("X-Source", meta.get("source") or "")
                self.send_header("Access-Control-Allow-Origin", "*")
                if content_length is not None:
                    self.send_header("Content-Length", str(content_length))
                    self.send_header("Accept-Ranges", "bytes")
                else:
                    self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()

            if pipeable:
                send_headers()
                headers_sent = True
                proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    while True:
                        chunk = proc.stdout.read(64 * 1024)
                        if not chunk:
                            break
                        try:
                            size = b"%X\r\n" % len(chunk)
                            self.wfile.write(size + chunk + b"\r\n")
                        except (BrokenPipeError, ConnectionResetError):
                            proc.kill()
                            return
                    try:
                        self.wfile.write(b"0\r\n\r\n")
                    except Exception:
                        pass
                    proc.wait(timeout=10)
                finally:
                    if proc.poll() is None:
                        proc.kill()
            else:
                proc = subprocess.run(cmd, capture_output=True, timeout=300)
                if proc.returncode != 0 or not os.path.exists(out_path):
                    return self._err(500, f"transcode failed: {proc.stderr.decode(errors='replace').strip()[:300]}")
                size = os.path.getsize(out_path)
                send_headers(content_length=size)
                headers_sent = True
                with open(out_path, "rb") as f:
                    while True:
                        chunk = f.read(64 * 1024)
                        if not chunk:
                            break
                        try:
                            self.wfile.write(chunk)
                        except (BrokenPipeError, ConnectionResetError):
                            return
        finally:
            shutil.rmtree(tmpdir, ignore_errors=True)


def lan_address():
    """This computer's address on the local network (what to type into the app)."""
    import socket
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.connect(("10.255.255.255", 1))  # no packet is sent; this only picks the outgoing interface
        return s.getsockname()[0]
    except OSError:
        return "127.0.0.1"
    finally:
        s.close()


def main():
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"ios7-player server on http://{HOST}:{PORT}", flush=True)
    print(f"In the app, open Settings and set Address to:  http://{lan_address()}:{PORT}", flush=True)
    if not lib.CONFIG.get("token"):
        print("WARNING: no token set, so anyone who can reach this port can use the server. "
              "Set PLAYER7_TOKEN (or \"token\" in config.json) and enter the same token in the app.", flush=True)
    print("endpoints: /meta /search /track   (fmt=mp3|aiff|m4a|wav, br=64..320)", flush=True)
    print(f"app api:   /api/*   spotify api: {'yes' if lib.SPOTIFY.has_api else 'no (embed fallback)'}, "
          f"youtube music login: {'yes' if lib.has_ytmusic_auth() else 'no'}", flush=True)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
