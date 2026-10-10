"""Browsing for the Player7 app: artist and channel pages, album / playlist previews,
search with artists, albums and playlists, and "go to artist" for a song.

Entities (artists, albums, playlists) share one JSON shape:
    {id, kind: artist|album|playlist, name, subtitle, source, coverVersion, hasCover, url}
Their pictures are served by /api/tracks/<id>/cover like song covers (see library.cover_url).
"""

import hashlib
import json
import re
import threading
import time
import unicodedata
from concurrent.futures import ThreadPoolExecutor

import library as lib

POOL = ThreadPoolExecutor(max_workers=8)


def fold(text):
    """Lowercase, no accents or punctuation: 'Młody West!' -> 'mlody west'."""
    text = (text or "").lower().replace("ł", "l")
    text = "".join(c for c in unicodedata.normalize("NFKD", text) if not unicodedata.combining(c))
    return re.sub(r"[^\w]+", " ", text).strip()


def name_matches(name, query):
    """Whether an artist result is what the user typed (or the start of it)."""
    n, q = fold(name), fold(query)
    if not n or not q:
        return False
    if n == q or q.startswith(n + " ") or (len(q) >= 2 and n.startswith(q)):
        return True
    return all(token in q.split() for token in n.split())


def compact_number(n):
    n = int(n or 0)
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".replace(".0M", "M")
    if n >= 10_000:
        return f"{n // 1000}K"
    if n >= 1000:
        return f"{n / 1000:.1f}K".replace(".0K", "K")
    return str(n)


def entity(entity_id, kind, name, subtitle="", source="", image="", url="", replace_image=True):
    lib.STORE.set_image(entity_id, image, replace=replace_image)
    image = lib.STORE.images.get(entity_id, "")
    return {"id": entity_id, "kind": kind, "name": name or "", "subtitle": subtitle or "", "source": source,
            "coverVersion": hashlib.md5(image.encode()).hexdigest()[:8] if image else "", "hasCover": bool(image), "url": url}


def tracks_section(title, tracks, more=None):
    lib.STORE.upsert_tracks(tracks)
    section = {"title": title, "type": "tracks", "tracks": [lib.public_track(lib.STORE.tracks[t["id"]]) for t in tracks]}
    if more:
        section["more"] = more
    return section


def entities_section(title, items):
    return {"title": title, "type": "entities", "items": items}


# ---------------------------------------------------------------------------
# Entities from Spotify and YouTube Music results


def sp_artist(a, subtitle="Artist"):
    return entity(f"sp-ar-{a['id']}", "artist", a.get("name"), subtitle, "spotify", lib.Spotify.best_image(a.get("images")),
                  f"https://open.spotify.com/artist/{a['id']}")


def sp_album(a, with_artist=True):
    kind = a.get("album_type") or "album"
    label = {"album": "Album", "compilation": "Compilation"}.get(kind) or ("EP" if (a.get("total_tracks") or 0) >= 4 else "Single")
    artists = ", ".join(x["name"] for x in a.get("artists") or [] if x.get("name")) if with_artist else ""
    subtitle = " · ".join(x for x in (artists, (a.get("release_date") or "")[:4], label) if x)
    return entity(f"sp-al-{a['id']}", "album", a.get("name"), subtitle, "spotify", lib.Spotify.best_image(a.get("images")),
                  f"https://open.spotify.com/album/{a['id']}")


def sp_playlist(p):
    owner = (p.get("owner") or {}).get("display_name") or ""
    count = ((p.get("tracks") or p.get("items") or {}).get("total")) or 0
    subtitle = " · ".join(x for x in (owner, f"{count} songs" if count else "") if x)
    return entity(f"sp-pl-{p['id']}", "playlist", p.get("name"), subtitle, "spotify", lib.Spotify.best_image(p.get("images")),
                  f"https://open.spotify.com/playlist/{p['id']}")


def yt_artist(a):
    first = (a.get("artists") or [{}])[0]
    channel_id = a.get("browseId") or first.get("id")
    name = a.get("artist") or a.get("title") or first.get("name")
    subtitle = f"{a['subscribers']} subscribers" if a.get("subscribers") else "Artist"
    return entity(f"yt-ch-{channel_id}", "artist", name, subtitle, "youtube", lib.best_thumbnail(a.get("thumbnails")),
                  f"https://music.youtube.com/channel/{channel_id}")


def yt_album(a, artist_name=""):
    artists = ", ".join(x["name"] for x in a.get("artists") or [] if x.get("name")) or artist_name
    subtitle = " · ".join(str(x) for x in (artists, a.get("year"), a.get("type") or "Album") if x)
    return entity(f"yt-al-{a['browseId']}", "album", a.get("title"), subtitle, "youtube", lib.best_thumbnail(a.get("thumbnails")),
                  f"https://music.youtube.com/browse/{a['browseId']}")


def yt_playlist(p):
    list_id = p["browseId"][2:] if p["browseId"].startswith("VL") else p["browseId"]
    count = p.get("itemCount")
    subtitle = " · ".join(str(x) for x in (p.get("author"), f"{count} songs" if count else "") if x)
    return entity(f"yt-pl-{list_id}", "playlist", p.get("title"), subtitle, "youtube", lib.best_thumbnail(p.get("thumbnails")),
                  f"https://music.youtube.com/playlist?list={list_id}")


def sc_artist(u, subtitle=None):
    followers = u.get("followers_count")
    subtitle = subtitle or (f"{compact_number(followers)} followers" if followers else "Artist")
    return entity(f"sc-us-{u['permalink']}", "artist", u.get("username"), subtitle, "soundcloud", lib.sc_artwork(u.get("avatar_url")),
                  u.get("permalink_url") or f"https://soundcloud.com/{u['permalink']}")


def sc_set(p):
    m = re.search(r"soundcloud\.com/([^/]+)/sets/([^/?#]+)", p.get("permalink_url") or "")
    if not m:
        return None
    owner = (p.get("user") or {}).get("username", "")
    count = p.get("track_count")
    year = (p.get("release_date") or p.get("created_at") or "")[:4] if p.get("is_album") else ""
    subtitle = " · ".join(str(x) for x in (owner, year, f"{count} songs" if count else "") if x)
    return entity(f"sc-pl-{m.group(1)}~{m.group(2)}", "album" if p.get("is_album") else "playlist", p.get("title"), subtitle, "soundcloud",
                  lib.sc_artwork(p.get("artwork_url") or (p.get("user") or {}).get("avatar_url")), p["permalink_url"])


# ---------------------------------------------------------------------------
# Search


_SEARCH = {}
_SEARCH_LOCK = threading.Lock()


def _items(data, key):
    return [i for i in ((data or {}).get(key) or {}).get("items") or [] if i and i.get("id")]


def search_all(source, query):
    """Songs plus matching artists, albums and playlists; cached for 10 minutes."""
    key = (source, fold(query))
    with _SEARCH_LOCK:
        hit = _SEARCH.get(key)
        if hit and time.time() - hit[0] < 600:
            return hit[1]
    tracks_job = POOL.submit(lib.cached_search, source, query)
    if source == "spotify":
        rest_job = POOL.submit(lib.SPOTIFY.api, "/search", {"q": query, "type": "artist,album,playlist", "limit": 8, "market": lib.SPOTIFY_MARKET})
    elif source == "soundcloud":
        rest_job = POOL.submit(lambda: {kind: lib.sc_api(f"/search/{kind}", q=query, limit=6).get("collection") or []
                                        for kind in ("users", "albums", "playlists_without_albums")})
    else:
        rest_job = POOL.submit(lambda: lib.ytmusic(auth=False).search(query, limit=20))
    tracks = tracks_job.result()
    try:
        rest = rest_job.result()
    except Exception as e:
        print(f"[search] {source} extras: {type(e).__name__}: {e}", flush=True)
        rest = None
    if source == "spotify":
        found = [a for a in _items(rest, "artists") if name_matches(a.get("name"), query)]
        # Same-name profiles with a handful of followers are almost never the one you want.
        followers = lambda a: (a.get("followers") or {}).get("total") or 0
        found.sort(key=followers, reverse=True)
        found = [a for i, a in enumerate(found) if i == 0 or followers(a) >= max(500, followers(found[0]) * 0.05)]
        artists = [sp_artist(a, f"{compact_number((a.get('followers') or {}).get('total'))} followers") for a in found]
        albums = [sp_album(a) for a in _items(rest, "albums")]
        playlists = [sp_playlist(p) for p in _items(rest, "playlists")]
    elif source == "soundcloud":
        rest = rest or {}
        found = [u for u in rest.get("users") or [] if u.get("permalink") and (name_matches(u.get("username"), query) or name_matches(u["permalink"], query))]
        found.sort(key=lambda u: u.get("followers_count") or 0, reverse=True)
        found = [u for i, u in enumerate(found) if i == 0 or (u.get("followers_count") or 0) >= max(100, (found[0].get("followers_count") or 0) * 0.05)]
        artists = [sc_artist(u) for u in found]
        albums = [e for e in (sc_set(p) for p in rest.get("albums") or []) if e]
        playlists = [e for e in (sc_set(p) for p in rest.get("playlists_without_albums") or []) if e]
    else:
        rest = rest or []
        artists = [yt_artist(r) for r in rest if r.get("resultType") == "artist"
                   and (r.get("browseId") or (r.get("artists") or [{}])[0].get("id"))
                   and name_matches(r.get("artist") or (r.get("artists") or [{}])[0].get("name"), query)]
        albums = [yt_album(r) for r in rest if r.get("resultType") == "album" and r.get("browseId")]
        playlists = [yt_playlist(r) for r in rest if r.get("resultType") == "playlist" and r.get("browseId")]
    unique = list({a["id"]: a for a in artists}.values())
    result = {"tracks": tracks, "artists": unique[:3], "albums": albums[:6], "playlists": playlists[:6]}
    with _SEARCH_LOCK:
        if len(_SEARCH) > 300:
            _SEARCH.clear()
        _SEARCH[key] = (time.time(), result)
    return result


# ---------------------------------------------------------------------------
# Artist pages


def artist_page(artist_id):
    if artist_id.startswith("sp-ar-"):
        page = spotify_artist_page(artist_id[6:])
    elif artist_id.startswith("yt-ch-"):
        page = youtube_artist_page(artist_id[6:])
    elif artist_id.startswith("sc-us-"):
        page = soundcloud_artist_page(artist_id[6:])
    else:
        raise lib.UserError("Unknown artist.")
    page["imported"] = artist_id in lib.STORE.playlists
    return page


def spotify_artist_page(aid):
    S = lib.SPOTIFY
    if not S.has_api:
        raise lib.UserError("Spotify artists need Spotify API keys in server/config.json.")
    info_job = POOL.submit(S.api, f"/artists/{aid}")
    top_job = POOL.submit(S.artist_top_tracks, aid)
    releases_job = POOL.submit(S.artist_releases, aid, "album,single,compilation")
    info, top, releases = info_job.result(), top_job.result(), releases_job.result()

    followers = (info.get("followers") or {}).get("total")
    genres = ", ".join(g.title() for g in (info.get("genres") or [])[:2])
    subtitle = " · ".join(x for x in (f"{compact_number(followers)} followers" if followers else "", genres) if x)
    page = sp_artist(info, subtitle)
    page["bannerKey"] = page["id"]
    sections = [tracks_section("Top Songs", top)] if top else []
    for group, title in (("album", "Albums"), ("single", "Singles & EPs"), ("compilation", "Compilations")):
        items = [sp_album(r, with_artist=False) for r in releases if (r.get("album_group") or r.get("album_type")) == group]
        if items:
            sections.append(entities_section(title, items))
    page["sections"] = sections
    return page


def youtube_artist_page(channel_id):
    page_id = f"yt-ch-{channel_id}"
    info = lib.youtube_artist_info(channel_id) or {}
    songs = info.get("songs") or {}
    uploads_job = None if songs.get("browseId") else POOL.submit(lib.youtube_uploads, channel_id, 100)
    avatar_job = None
    if not lib.STORE.images.get(page_id) and info.get("name"):
        avatar_job = POOL.submit(find_youtube_artist, info["name"], channel_id)

    def full_list(key):
        block = info.get(key) or {}
        if block.get("browseId") and block.get("params"):
            try:
                return lib.ytmusic(auth=False).get_artist_albums(block["browseId"], block["params"], limit=None)
            except Exception as e:
                print(f"[youtube] {key} of {channel_id}: {type(e).__name__}: {str(e)[:100]}", flush=True)
        return block.get("results") or []

    albums_job, singles_job = POOL.submit(full_list, "albums"), POOL.submit(full_list, "singles")
    name = info.get("name") or ""
    sections = []
    top = [t for t in (lib.track_from_ytmusic(i) for i in songs.get("results") or []) if t]
    if top:
        more = None
        if songs.get("browseId"):
            list_id = songs["browseId"][2:] if songs["browseId"].startswith("VL") else songs["browseId"]
            more = entity(f"yt-pl-{list_id}", "playlist", f"{name} – All Songs", "", "youtube",
                          url=f"https://music.youtube.com/playlist?list={list_id}")
        sections.append(tracks_section("Top Songs", top, more))
    for title, items in (("Albums", albums_job.result()), ("Singles & EPs", singles_job.result())):
        items = [yt_album(a, name) for a in items if a.get("browseId")]
        if items:
            sections.append(entities_section(title, items))
    videos = info.get("videos") or {}
    video_tracks = [t for t in (lib.track_from_ytmusic(v) for v in videos.get("results") or []) if t]
    if video_tracks:
        sections.append(tracks_section("Videos", video_tracks))
    if uploads_job:
        uploads_name, uploads = uploads_job.result()
        name = name or uploads_name or ""
        if uploads:
            sections.append(tracks_section("Uploads", uploads))
    related = [yt_artist(r) for r in (info.get("related") or {}).get("results") or [] if r.get("browseId")]
    if related:
        sections.append(entities_section("Fans Might Also Like", related))
    if not sections and not name:
        raise lib.UserError("This channel couldn't be loaded.")
    if avatar_job:
        avatar_job.result()

    lib.STORE.set_image(f"{page_id}-banner", lib.largest_thumbnail(info.get("thumbnails")), replace=False)
    lib.STORE.set_image(page_id, lib.best_thumbnail(info.get("thumbnails")), replace=False)
    subtitle = " · ".join(x for x in (f"{info['subscribers']} subscribers" if info.get("subscribers") else "",
                                      "" if songs.get("browseId") else "Channel") if x)
    page = entity(page_id, "artist", name, subtitle, "youtube", url=f"https://music.youtube.com/channel/{channel_id}")
    page["bannerKey"] = f"{page_id}-banner" if lib.STORE.images.get(f"{page_id}-banner") else page_id
    page["sections"] = sections
    return page


def soundcloud_artist_page(permalink):
    user = lib.sc_api("/resolve", url=f"https://soundcloud.com/{permalink}")
    if user.get("kind") != "user":
        raise lib.UserError("That isn't a SoundCloud profile.")
    uid = user["id"]
    jobs = {name: POOL.submit(lambda path=path, limit=limit: lib.sc_api(path, limit=limit).get("collection") or [])
            for name, path, limit in (("top", f"/users/{uid}/toptracks", 10), ("tracks", f"/users/{uid}/tracks", 50),
                                      ("albums", f"/users/{uid}/albums", 30), ("playlists", f"/users/{uid}/playlists_without_albums", 30),
                                      ("related", f"/users/{uid}/relatedartists", 10))}
    results = {}
    for name, job in jobs.items():
        try:
            results[name] = job.result()
        except Exception as e:
            print(f"[soundcloud] {name} of {permalink}: {e}", flush=True)
            results[name] = []
    sections = []
    top = [lib.track_from_soundcloud(t) for t in results["top"][:10] if t.get("id")]
    if top:
        sections.append(tracks_section("Popular", top))
    uploads = [lib.track_from_soundcloud(t) for t in results["tracks"] if t.get("id")]
    if uploads:
        sections.append(tracks_section("Tracks", uploads))
    for title, items in (("Albums", results["albums"]), ("Playlists", results["playlists"])):
        items = [e for e in (sc_set(p) for p in items) if e]
        if items:
            sections.append(entities_section(title, items))
    if user.get("likes_count"):
        likes = entity(f"sc-lk-{permalink}", "playlist", f"{user.get('username') or permalink} – Likes", f"{user['likes_count']} likes",
                       "soundcloud", lib.sc_artwork(user.get("avatar_url")), f"https://soundcloud.com/{permalink}/likes", replace_image=False)
        sections.append(entities_section("Likes", [likes]))
    related = [sc_artist(u) for u in results["related"] if u.get("permalink")]
    if related:
        sections.append(entities_section("Fans Also Like", related))

    followers, count = user.get("followers_count"), user.get("track_count")
    subtitle = " · ".join(x for x in (f"{compact_number(followers)} followers" if followers else "", f"{count} tracks" if count else "") if x)
    page = sc_artist(user, subtitle)
    visuals = ((user.get("visuals") or {}).get("visuals") or [{}])
    banner = visuals[0].get("visual_url") if visuals else None
    lib.STORE.set_image(f"{page['id']}-banner", banner)
    page["bannerKey"] = f"{page['id']}-banner" if banner else page["id"]
    page["sections"] = sections
    return page


_ARTIST_LOOKUPS = {}


def find_youtube_artist(name, channel_id=None):
    """YouTube Music artist with exactly this name (or this channel id); sets its avatar picture."""
    cache_key = (fold(name), channel_id)
    if cache_key in _ARTIST_LOOKUPS:
        return _ARTIST_LOOKUPS[cache_key]
    found = None
    try:
        for r in lib.ytmusic(auth=False).search(name, filter="artists", limit=5):
            if (channel_id and r.get("browseId") == channel_id) or (not channel_id and r.get("browseId") and fold(r.get("artist")) == fold(name)):
                found = yt_artist(r)
                break
    except Exception as e:
        print(f"[youtube] artist lookup {name}: {e}", flush=True)
    _ARTIST_LOOKUPS[cache_key] = found
    return found


def find_soundcloud_artist(name):
    try:
        for u in lib.sc_api("/search/users", q=name, limit=5).get("collection") or []:
            if u.get("permalink") and fold(u.get("username")) == fold(name):
                return sc_artist(u)
    except Exception as e:
        print(f"[soundcloud] artist lookup {name}: {e}", flush=True)
    return None


def find_spotify_artist(name):
    if not lib.SPOTIFY.has_api:
        return None
    try:
        for a in _items(lib.SPOTIFY.api("/search", {"q": name, "type": "artist", "limit": 5}), "artists"):
            if fold(a.get("name")) == fold(name):
                return sp_artist(a)
    except Exception as e:
        print(f"[spotify] artist lookup {name}: {e}", flush=True)
    return None


# ---------------------------------------------------------------------------
# Song -> artists


def split_artist_names(text):
    parts = re.split(r"\s*(?:,|&|\+|\bx\b|\bfeat\.?|\bft\.?|\bfeaturing\b|\bvs\.?)\s*", text or "", flags=re.I)
    return [p.strip() for p in parts if p and p.strip() and p.strip().lower() != "unknown artist"]


def track_artists(track_id):
    """Artists of a song, best first. For YouTube uploads that's the artist named in the title, then the channel."""
    track = lib.lookup_track(track_id)
    refs = list(track.get("artistRefs") or [])
    if track_id.startswith("sp-"):
        if not refs and lib.SPOTIFY.has_api:
            full = lib.Spotify.track_from_api(lib.SPOTIFY.api(f"/tracks/{track['spotifyId']}"))
            refs = full["artistRefs"]
            lib.STORE.upsert_tracks([{"id": track_id, "artistRefs": refs, "albumId": full["albumId"]}])
        return [entity(f"sp-ar-{r['id']}", "artist", r["name"], "Artist", "spotify", url=f"https://open.spotify.com/artist/{r['id']}")
                for r in refs]

    if track_id.startswith("sc-"):
        return soundcloud_track_artists(track_id, track, refs)

    video_id = track.get("youtubeId") or track_id[3:]
    if not refs:
        try:
            watch = lib.ytmusic(auth=False).get_watch_playlist(video_id, limit=1)
            first = next((t for t in watch.get("tracks") or [] if t.get("videoId") == video_id), None) or {}
            refs = [{"id": a["id"], "name": a["name"]} for a in first.get("artists") or [] if a.get("id") and a.get("name")]
        except Exception as e:
            print(f"[youtube] watch info {video_id}: {e}", flush=True)
        if not refs:
            proc = lib.run_ytdlp(["-J", "--skip-download", "--no-playlist", f"https://www.youtube.com/watch?v={video_id}"], timeout=90)
            if proc.returncode == 0:
                data = json.loads(proc.stdout)
                if data.get("channel_id"):
                    refs = [{"id": data["channel_id"], "name": data.get("channel") or data.get("uploader") or "Channel"}]
        if refs:
            lib.STORE.upsert_tracks([{"id": track_id, "artistRefs": refs}])

    known = {fold(r["name"]) for r in refs}
    missing = [n for n in split_artist_names(track.get("artist")) if fold(n) not in known][:3]
    lookups = [POOL.submit(lambda n=n: find_youtube_artist(n) or find_spotify_artist(n)) for n in missing]
    named = [a for a in (job.result() for job in lookups) if a]
    channels = [entity(f"yt-ch-{r['id']}", "artist", r["name"], "Channel" if named else "Artist", "youtube",
                       url=f"https://music.youtube.com/channel/{r['id']}") for r in refs]
    out = {}
    for a in named + channels:
        out.setdefault(a["id"], a)
    return list(out.values())


def soundcloud_track_artists(track_id, track, refs):
    """The artist named in the title ("Artist - Song") first, then whoever uploaded it."""
    if not refs or refs[0]["id"].isdigit():  # stored before profiles were linked by name
        data = lib.sc_api(f"/tracks/{track_id[3:]}")
        user = data.get("user") or {}
        refs = [{"id": user["permalink"], "name": user.get("username") or user["permalink"]}] if user.get("permalink") else []
        lib.STORE.upsert_tracks([{"id": track_id, "artistRefs": refs}])
    known = {fold(r["name"]) for r in refs}
    missing = [n for n in split_artist_names(track.get("artist")) if fold(n) not in known][:3]
    lookups = [POOL.submit(lambda n=n: find_soundcloud_artist(n) or find_spotify_artist(n)) for n in missing]
    named = [a for a in (job.result() for job in lookups) if a]
    uploaders = [entity(f"sc-us-{r['id']}", "artist", r["name"], "Channel" if named else "Artist", "soundcloud",
                        url=f"https://soundcloud.com/{r['id']}") for r in refs]
    out = {}
    for a in named + uploaders:
        out.setdefault(a["id"], a)
    return list(out.values())


# ---------------------------------------------------------------------------
# Album / playlist previews


def collection_page(collection_id):
    stored = lib.STORE.playlists.get(collection_id)
    if stored:
        return lib.public_playlist(stored, with_tracks=True)
    if not collection_id.startswith(lib.COLLECTION_PREFIXES):
        raise lib.UserError("Playlist not found.")
    playlist, tracks = lib.fetch_collection(collection_id)
    lib.STORE.upsert_tracks(tracks)
    return lib.public_playlist(playlist, with_tracks=True, tracks=[lib.STORE.tracks[t["id"]] for t in tracks])
