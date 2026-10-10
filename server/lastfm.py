"""Last.fm scrobbling for the Player7 app.

The API key and secret live in config.json (lastfm_api_key, lastfm_api_secret); the user's
session key is stored in secrets/lastfm.json after they allow access on last.fm
(desktop auth flow: the password never passes through this server).

The app reports what it plays; songs are looked up in the library so Last.fm gets the
main artist ("Młody West", not "Młody West, Mata") and the album.
"""

import hashlib
import json
import os
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

import library as lib

API_URL = "https://ws.audioscrobbler.com/2.0/"
STATE_PATH = os.path.join(lib.ROOT, "secrets", "lastfm.json")
_LOCK = threading.Lock()


def _load_state():
    if os.path.exists(STATE_PATH):
        with open(STATE_PATH) as f:
            return json.load(f)
    return {}


def _save_state(state):
    os.makedirs(os.path.dirname(STATE_PATH), exist_ok=True)
    tmp = STATE_PATH + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
    os.chmod(tmp, 0o600)
    os.replace(tmp, STATE_PATH)


STATE = _load_state()


def _keys():
    key, secret = lib.CONFIG.get("lastfm_api_key"), lib.CONFIG.get("lastfm_api_secret")
    if not key or not secret:
        raise lib.UserError("Last.fm isn't set up on the server (add lastfm_api_key and lastfm_api_secret to config.json).")
    return key, secret


def _call(method, params=None, session=False):
    """Signed POST to the Last.fm API; returns the JSON answer."""
    key, secret = _keys()
    params = {k: str(v) for k, v in (params or {}).items() if v not in (None, "")}
    params.update(method=method, api_key=key)
    if session:
        if not STATE.get("session"):
            raise lib.UserError("Last.fm isn't connected.")
        params["sk"] = STATE["session"]
    params["api_sig"] = hashlib.md5(("".join(k + params[k] for k in sorted(params)) + secret).encode("utf-8")).hexdigest()
    params["format"] = "json"
    request = urllib.request.Request(API_URL, data=urllib.parse.urlencode(params).encode(), headers={"User-Agent": "Player7/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=20) as r:
            data = json.loads(r.read())
    except urllib.error.HTTPError as e:
        try:
            data = json.loads(e.read())
        except ValueError:
            raise lib.UserError(f"Last.fm error {e.code}.")
    if "error" in data:
        if data["error"] == 9:  # invalid session key: access was revoked on last.fm
            with _LOCK:
                STATE.pop("session", None)
                _save_state(STATE)
        raise lib.UserError(f"Last.fm: {data.get('message') or data['error']}")
    return data


# ---------------------------------------------------------------------------
# Account


def status():
    configured = bool(lib.CONFIG.get("lastfm_api_key") and lib.CONFIG.get("lastfm_api_secret"))
    return {"configured": configured, "connected": configured and bool(STATE.get("session")), "username": STATE.get("username", "")}


def connect():
    """Start connecting: returns the last.fm page where the user allows access."""
    key, _ = _keys()
    token = _call("auth.getToken")["token"]
    with _LOCK:
        STATE["pendingToken"] = token
        _save_state(STATE)
    return {"url": f"https://www.last.fm/api/auth/?api_key={key}&token={token}"}


def finish():
    """After the user allowed access on last.fm: swap the token for a session."""
    token = STATE.get("pendingToken")
    if not token:
        raise lib.UserError("Start connecting to Last.fm first.")
    try:
        session = _call("auth.getSession", {"token": token})["session"]
    except lib.UserError as e:
        if "not authorized" in str(e).lower() or "unauthorized" in str(e).lower():
            raise lib.UserError("Allow access on the Last.fm page first, then try again.")
        raise
    with _LOCK:
        STATE.update(session=session["key"], username=session["name"])
        STATE.pop("pendingToken", None)
        _save_state(STATE)
    return status()


def disconnect():
    with _LOCK:
        STATE.clear()
        _save_state(STATE)
    return status()


# ---------------------------------------------------------------------------
# Scrobbling


def _meta(item):
    """Artist / title / album for a reported play, preferring what the library knows."""
    track = lib.STORE.tracks.get(item.get("trackId") or "") or {}
    artist = track.get("artist") or item.get("artist") or ""
    artist = artist.split(", ")[0].replace(" - Topic", "").strip()
    title = track.get("title") or item.get("title") or ""
    album = track.get("album") or item.get("album") or ""
    duration = int(track.get("duration") or item.get("duration") or 0)
    if not artist or artist == "Unknown Artist" or not title:
        return None
    return {"artist": artist, "track": title, "album": album, "duration": duration or None}


def now_playing(item):
    meta = _meta(item)
    if meta and STATE.get("session"):
        _call("track.updateNowPlaying", meta, session=True)
    return {"ok": True}


def scrobble(items):
    """Batch scrobble (the app sends plays it queued, possibly while offline)."""
    accepted = ignored = 0
    plays = []
    for item in items:
        meta = _meta(item)
        timestamp = int(item.get("timestamp") or 0)
        # Last.fm only takes plays from the last two weeks.
        if meta and time.time() - 14 * 86400 < timestamp <= time.time() + 300:
            plays.append({**meta, "timestamp": timestamp})
        else:
            ignored += 1
    for i in range(0, len(plays), 50):
        params = {}
        for n, play in enumerate(plays[i:i + 50]):
            params.update({f"{k}[{n}]": v for k, v in play.items() if v not in (None, "")})
        result = _call("track.scrobble", params, session=True).get("scrobbles", {}).get("@attr", {})
        accepted += int(result.get("accepted") or 0)
        ignored += int(result.get("ignored") or 0)
    return {"accepted": accepted, "ignored": ignored}


def love(item, loved=True):
    meta = _meta(item)
    if not meta:
        raise lib.UserError("This song has no artist to send to Last.fm.")
    _call("track.love" if loved else "track.unlove", {"artist": meta["artist"], "track": meta["track"]}, session=True)
    return {"ok": True}
