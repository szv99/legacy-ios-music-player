"""Minimal Spotify downloader built on librespot-python.

Public API:
    login_oauth()                 -> interactive OAuth; saves credentials
    download_ogg(spotify_id, out) -> fetches Ogg Vorbis (320k with Premium) to out
    is_logged_in()                -> bool
    get_track_meta(spotify_id)    -> {title, artists, duration_ms, isrc}

Credentials live at server/secrets/spotify_credentials.json
"""

from __future__ import annotations

import json
import os
import shutil
import threading
import webbrowser

from librespot.core import Session
from librespot.metadata import TrackId
from librespot.audio.decoders import AudioQuality, VorbisOnlyAudioQuality


HERE = os.path.dirname(os.path.abspath(__file__))
CRED_PATH = os.path.join(HERE, "secrets", "spotify_credentials.json")

_session_lock = threading.Lock()
_session = None  # type: Session | None


def _ensure_dir():
    os.makedirs(os.path.dirname(CRED_PATH), exist_ok=True)


def is_logged_in() -> bool:
    return os.path.exists(CRED_PATH)


def login_oauth(open_in_browser: bool = True) -> Session:
    """Interactive OAuth: prints the auth URL (and opens it) and blocks until done."""
    _ensure_dir()

    def _cb(url: str):
        print(f"\n[spotify-dl] Open this URL and log in with Spotify Premium:\n  {url}\n", flush=True)
        if open_in_browser:
            try:
                webbrowser.open(url)
            except Exception:
                pass

    builder = Session.Builder().oauth(_cb)
    sess = builder.create()

    # librespot writes credentials.json in the CWD after oauth succeeds; relocate it.
    for candidate in (
        os.path.join(os.getcwd(), "credentials.json"),
        os.path.join(HERE, "credentials.json"),
    ):
        if os.path.exists(candidate) and candidate != CRED_PATH:
            shutil.move(candidate, CRED_PATH)
            break
    try:
        os.chmod(CRED_PATH, 0o600)
    except OSError:
        pass
    return sess


def _get_session() -> Session:
    global _session
    with _session_lock:
        if _session is not None:
            return _session
        if not is_logged_in():
            raise RuntimeError("Not logged in. Run `python3 spotify_dl.py login` first.")
        _session = Session.Builder().stored_file(CRED_PATH).create()
        return _session


def download_ogg(spotify_id: str, out_path: str, prefer_premium: bool = True) -> str:
    """Stream raw Ogg Vorbis for the given track to out_path. Returns the path."""
    sess = _get_session()
    track_id = TrackId.from_uri(f"spotify:track:{spotify_id}")
    quality = AudioQuality.VERY_HIGH if prefer_premium else AudioQuality.HIGH
    stream = sess.content_feeder().load(
        track_id, VorbisOnlyAudioQuality(quality), False, None
    )
    inp = stream.input_stream.stream()
    with open(out_path, "wb") as f:
        while True:
            chunk = inp.read(64 * 1024)
            if not chunk:
                break
            f.write(chunk)
    return out_path


def get_track_meta(spotify_id: str):
    """Fetch track metadata via librespot's mercury channel."""
    sess = _get_session()
    track_id = TrackId.from_uri(f"spotify:track:{spotify_id}")
    track = sess.api().get_metadata_4_track(track_id)
    artists = [a.name for a in track.artist]
    return {
        "title": track.name,
        "artists": artists,
        "artist": ", ".join(artists),
        "duration_ms": track.duration,
        "duration": int(track.duration / 1000),
        "isrc": next((x.id for x in track.external_id if x.type == "isrc"), ""),
        "album": track.album.name if track.album else "",
    }


# --- CLI ----------------------------------------------------------------------

if __name__ == "__main__":
    import sys
    if len(sys.argv) < 2:
        print("usage: spotify_dl.py <login|meta|download> [spotify_id] [out.ogg]")
        sys.exit(0)
    cmd = sys.argv[1]
    if cmd == "login":
        login_oauth()
        print(f"[spotify-dl] Credentials saved to {CRED_PATH}")
    elif cmd == "meta":
        print(json.dumps(get_track_meta(sys.argv[2]), ensure_ascii=False, indent=2))
    elif cmd == "download":
        out = sys.argv[3] if len(sys.argv) > 3 else f"{sys.argv[2]}.ogg"
        download_ogg(sys.argv[2], out)
        print(f"wrote {out} ({os.path.getsize(out)} bytes)")
    else:
        print("unknown:", cmd)
