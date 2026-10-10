// Player7 YouTube extractor: YouTube Music search, browsing and audio streams, straight from the phone.
//
// Runs in JavaScriptCore on iOS 7 (P7Script.m), so this file must stay strict ES5: no let/const,
// arrow functions, template literals, classes, Promise, for-of, or ES6 builtins such as
// String.prototype.startsWith / includes, Array.prototype.find, Object.assign or Map.
//
// Host API (P7Script.m):
//   P7.http({url, method, headers, body, timeout, responseType}) -> {status, headers (lowercase keys), body}
//       synchronous, throws on network errors; responseType "hex" returns a binary body as hex
//   P7.log(message)
//   P7.get(key) / P7.set(key, value)    small persistent strings
//
// Every function returns the shapes of server/library.py (tracks) and server/browse.py (entities);
// the app turns them into its public JSON. Errors meant for the user are thrown as Error(message).
//
// YouTube changes often. This file can be updated without reinstalling the app (see kP7ExtractorUpdateURL
// in P7Script.m): bump `version` with every change.

var extractor = {version: "2026.10.10"};

(function () {
	"use strict";

	var MUSIC = "music.youtube.com";
	var WEB_UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15";
	var WEB_REMIX = {clientName: "WEB_REMIX", clientVersion: "1.20260707.12.00", number: 67, userAgent: WEB_UA};
	var WEB = {clientName: "WEB", clientVersion: "2.20260708.00.00", number: 1, userAgent: WEB_UA};

	// Player clients tried in order. They must return plain (unciphered) audio URLs that download without a
	// PO token and without running YouTube's player JavaScript (base.js is far beyond iOS 7's ES5 engine).
	// As of 2026-10, "visionos" does (it is yt-dlp's default client when no JS runtime is available);
	// "android_vr" still returns URLs, but googlevideo answers 403 past the first part of the file.
	var PLAYER_CLIENTS = [
		{name: "visionos", host: MUSIC, number: 101, context: {clientName: "VISIONOS", clientVersion: "1.02", deviceMake: "Apple", deviceModel: "RealityDevice17,1",
			osName: "visionOS", osVersion: "26.5.23O471",
			userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"}},
		{name: "android_vr", host: "www.youtube.com", number: 28, context: {clientName: "ANDROID_VR", clientVersion: "1.65.10", deviceMake: "Oculus", deviceModel: "Quest 3",
			androidSdkVersion: 32, osName: "Android", osVersion: "12L",
			userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip"}}
	];

	// AAC in MP4, which iOS 7 can play: 128k LC first, then 48k HE-AAC.
	var AUDIO_ITAGS = [140, 139];

	var SEARCH_SONGS = "EgWKAQIIAWoMEA4QChADEAQQCRAF";
	var SEARCH_VIDEOS = "EgWKAQIQAWoMEA4QChADEAQQCRAF";
	var CHANNEL_VIDEOS = "EgZ2aWRlb3PyBgQKAjoA";
	var WEB_SEARCH_VIDEOS = "EgIQAQ==";

	// ------------------------------------------------------------------
	// Small helpers

	function has(text, part) { return String(text || "").indexOf(part) !== -1; }
	function starts(text, prefix) { return String(text || "").slice(0, prefix.length) === prefix; }
	function trim(text) { return String(text || "").replace(/^\s+|\s+$/g, ""); }
	function now() { return Math.floor(new Date().getTime() / 1000); }

	function each(list, fn) {
		for (var i = 0; list && i < list.length; i++) fn(list[i], i);
	}

	function first(list, test) {
		for (var i = 0; list && i < list.length; i++) if (test(list[i])) return list[i];
		return null;
	}

	function extend(target, source) {
		for (var key in source) if (Object.prototype.hasOwnProperty.call(source, key)) target[key] = source[key];
		return target;
	}

	// Safe deep property access: get(obj, "a", 0, "b").
	function get(obj) {
		for (var i = 1; i < arguments.length; i++) {
			if (obj === null || obj === undefined) return undefined;
			obj = obj[arguments[i]];
		}
		return obj;
	}

	// Every value stored under `key` anywhere inside obj (YouTube nests the same renderers at varying depths).
	function findAll(obj, key, out) {
		out = out || [];
		if (!obj || typeof obj !== "object") return out;
		if (obj instanceof Array) {
			for (var i = 0; i < obj.length; i++) findAll(obj[i], key, out);
			return out;
		}
		for (var k in obj) {
			if (!Object.prototype.hasOwnProperty.call(obj, k)) continue;
			if (k === key) out.push(obj[k]);
			else findAll(obj[k], key, out);
		}
		return out;
	}

	function findOne(obj, key) {
		return findAll(obj, key)[0];
	}

	function runsText(text) {
		if (!text) return "";
		if (text.simpleText !== undefined) return text.simpleText;
		var out = "";
		each(text.runs, function (run) { out += run.text || ""; });
		return out;
	}

	function parseDuration(text) {
		var match = /^(\d+):(\d\d)(?::(\d\d))?$/.exec(trim(text));
		if (!match) return 0;
		var parts = [];
		for (var i = 1; i < match.length; i++) if (match[i] !== undefined) parts.push(parseInt(match[i], 10));
		var total = 0;
		for (var j = 0; j < parts.length; j++) total = total * 60 + parts[j];
		return total;
	}

	var ACCENTS = {"\u0105": "a", "\u00e1": "a", "\u00e0": "a", "\u00e2": "a", "\u00e4": "a", "\u00e3": "a", "\u00e5": "a", "\u0107": "c", "\u010d": "c", "\u00e7": "c", "\u010f": "d",
		"\u0119": "e", "\u00e9": "e", "\u00e8": "e", "\u00ea": "e", "\u00eb": "e", "\u011b": "e", "\u00ed": "i", "\u00ec": "i", "\u00ee": "i", "\u00ef": "i", "\u0142": "l", "\u0144": "n", "\u00f1": "n",
		"\u0148": "n", "\u00f3": "o", "\u00f2": "o", "\u00f4": "o", "\u00f6": "o", "\u00f5": "o", "\u00f8": "o", "\u0159": "r", "\u015b": "s", "\u0161": "s", "\u00df": "ss", "\u0165": "t", "\u00fa": "u",
		"\u00f9": "u", "\u00fb": "u", "\u00fc": "u", "\u016f": "u", "\u00fd": "y", "\u00ff": "y", "\u017a": "z", "\u017c": "z", "\u017e": "z"};

	// Lowercase, no accents or punctuation: "Młody West!" -> "mlody west" (browse.fold).
	function fold(text) {
		text = String(text || "").toLowerCase().replace(/[^\u0000-\u007f]/g, function (c) { return ACCENTS[c] !== undefined ? ACCENTS[c] : c; });
		return trim(text.replace(/[\s!-\/:-@\[-`{-~\u2010-\u2027\u00a0-\u00bf]+/g, " "));
	}

	// Whether an artist result is what the user typed, or the start of it (browse.name_matches).
	function nameMatches(name, query) {
		var n = fold(name), q = fold(query);
		if (!n || !q) return false;
		if (n === q || starts(q, n + " ") || (q.length >= 2 && starts(n, q))) return true;
		var words = q.split(" ");
		var all = true;
		each(n.split(" "), function (token) { if (words.indexOf(token) === -1) all = false; });
		return all;
	}

	// ------------------------------------------------------------------
	// InnerTube

	function visitorData() {
		return P7.get("visitorData") || "";
	}

	function post(host, endpoint, body, client) {
		var context = {hl: "en", gl: P7.get("region") || "US"};
		extend(context, client.context || {clientName: client.clientName, clientVersion: client.clientVersion});
		var visitor = visitorData();
		if (visitor) context.visitorData = visitor;
		var payload = extend({context: {client: context}}, body);
		var headers = {
			"Content-Type": "application/json",
			"User-Agent": context.userAgent || client.userAgent || WEB_UA,
			"Origin": "https://" + host,
			"X-YouTube-Client-Name": String(client.number),
			"X-YouTube-Client-Version": context.clientVersion
		};
		if (visitor) headers["X-Goog-Visitor-Id"] = visitor;
		var response = P7.http({url: "https://" + host + "/youtubei/v1/" + endpoint + "?prettyPrint=false", method: "POST", headers: headers, body: JSON.stringify(payload), timeout: 25});
		var json;
		try {
			json = JSON.parse(response.body);
		} catch (e) {
			throw new Error("YouTube sent an invalid answer (" + response.status + ").");
		}
		var fresh = get(json, "responseContext", "visitorData");
		if (fresh && fresh !== visitor) P7.set("visitorData", fresh);
		if (response.status >= 400) {
			var message = get(json, "error", "message") || ("YouTube answered " + response.status + ".");
			var error = new Error(response.status === 404 ? "Not found on YouTube." : message);
			error.status = response.status;
			throw error;
		}
		return json;
	}

	function music(endpoint, body) {
		return post(MUSIC, endpoint, body, WEB_REMIX);
	}

	// Player requests without a visitor id are often answered with "Sign in to confirm you're not a bot".
	function ensureVisitor() {
		if (!visitorData()) music("search", {query: "music", params: SEARCH_SONGS});
	}

	function browseAll(body, maxPages) {
		var pages = [music("browse", body)];
		var token = nextContinuation(pages[0]);
		while (token && pages.length < (maxPages || 60)) {
			var page = music("browse", {continuation: token});
			pages.push(page);
			token = nextContinuation(page);
		}
		return pages;
	}

	function nextContinuation(page) {
		var command = findOne(page, "continuationCommand");
		if (command && command.token) return command.token;
		var data = findOne(page, "nextContinuationData");
		return data && data.continuation;
	}

	// ------------------------------------------------------------------
	// Thumbnails

	function biggest(thumbnails) {
		var best = null;
		each(thumbnails, function (t) { if (!best || (t.width || 0) > (best.width || 0)) best = t; });
		return best ? best.url : "";
	}

	function thumbnailsOf(renderer) {
		return get(renderer, "thumbnail", "musicThumbnailRenderer", "thumbnail", "thumbnails")
			|| get(renderer, "thumbnailRenderer", "musicThumbnailRenderer", "thumbnail", "thumbnails")
			|| get(renderer, "thumbnail", "thumbnails")
			|| findOne(get(renderer, "thumbnail") || get(renderer, "thumbnailRenderer"), "thumbnails")
			|| [];
	}

	// YouTube Music pictures can be requested at any size: w60-h60 -> w544-h544 (library.best_thumbnail).
	function squareImage(thumbnails) {
		var url = biggest(thumbnails);
		if (!url) return "";
		if (starts(url, "//")) url = "https:" + url;
		return url.replace(/=w\d+-h\d+/, "=w544-h544").replace(/=s\d+(-|$)/, "=s544$1");
	}

	function coverFor(videoId, thumbnails) {
		var url = biggest(thumbnails);
		if (url && !has(url, "i.ytimg.com")) return squareImage(thumbnails);
		return "https://i.ytimg.com/vi/" + videoId + "/hqdefault.jpg";
	}

	// ------------------------------------------------------------------
	// Parsing list items

	var LABELS = {"Song": 1, "Video": 1, "Album": 1, "Single": 1, "EP": 1, "Artist": 1, "Playlist": 1, "Episode": 1, "Podcast": 1, "Profile": 1};

	function pageType(endpoint) {
		return get(endpoint, "browseEndpoint", "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") || "";
	}

	function isArtistRun(run) {
		var type = pageType(run.navigationEndpoint);
		return type === "MUSIC_PAGE_TYPE_ARTIST" || type === "MUSIC_PAGE_TYPE_USER_CHANNEL" || type === "MUSIC_PAGE_TYPE_UNKNOWN";
	}

	function isSeparator(text) {
		return /^\s*(,|&|and|x|\u00d7|\u2022|\u00b7)?\s*$/.test(text);
	}

	function isStat(text) {
		return /\d.*\b(views?|plays?|monthly|audience|subscribers?|listeners?|tracks?|songs?|episodes?|hours?|minutes?)\b/i.test(text) || /^\d{4}$/.test(trim(text));
	}

	// "Song • Daft Punk, Pharrell Williams • Random Access Memories • 4:09" -> label, artists, album, duration.
	function parseByline(runs) {
		var groups = [[]];
		each(runs, function (run) {
			if (/^\s*[\u2022\u00b7]\s*$/.test(run.text || "")) groups.push([]);
			else groups[groups.length - 1].push(run);
		});
		var out = {label: "", artists: [], album: null, duration: 0, year: "", stats: []};
		var sawContent = false;
		each(groups, function (group, index) {
			if (!group.length) return;
			var text = trim(runsText({runs: group}));
			if (!text) return;
			if (index === 0 && group.length === 1 && LABELS[text] && !group[0].navigationEndpoint) { out.label = text; return; }
			var album = first(group, function (run) { return pageType(run.navigationEndpoint) === "MUSIC_PAGE_TYPE_ALBUM"; });
			if (album) {
				out.album = {id: album.navigationEndpoint.browseEndpoint.browseId, name: album.text};
				return;
			}
			if (parseDuration(text)) { out.duration = parseDuration(text); return; }
			if (/^\d{4}$/.test(text)) { out.year = text; return; }
			var hasArtist = first(group, isArtistRun);
			if (hasArtist || (!sawContent && !isStat(text))) {
				sawContent = true;
				if (out.artists.length) return;
				each(group, function (run) {
					var name = trim(run.text);
					if (!name || isSeparator(run.text)) return;
					var id = isArtistRun(run) ? run.navigationEndpoint.browseEndpoint.browseId : "";
					out.artists.push({id: id, name: name});
				});
				return;
			}
			out.stats.push(text);
		});
		return out;
	}

	function watchEndpointIn(obj) {
		return findOne(obj, "watchEndpoint");
	}

	// musicResponsiveListItemRenderer / musicTwoRowItemRenderer / playlistPanelVideoRenderer -> a flat item.
	function parseItem(renderer, kind) {
		var title, bylineRuns = [], videoId = "", browse = null, duration = 0;
		if (kind === "list") {
			var columns = renderer.flexColumns || [];
			var titleText = get(columns[0], "musicResponsiveListItemFlexColumnRenderer", "text");
			title = runsText(titleText);
			for (var i = 1; i < columns.length; i++) {
				var runs = get(columns[i], "musicResponsiveListItemFlexColumnRenderer", "text", "runs") || [];
				if (!runs.length) continue;
				if (bylineRuns.length) bylineRuns.push({text: " \u2022 "});
				bylineRuns = bylineRuns.concat(runs);
			}
			each(renderer.fixedColumns, function (column) {
				duration = duration || parseDuration(runsText(get(column, "musicResponsiveListItemFixedColumnRenderer", "text")));
			});
			videoId = get(renderer, "playlistItemData", "videoId") || get(watchEndpointIn(renderer.overlay), "videoId")
				|| get(watchEndpointIn(titleText), "videoId") || "";
			browse = get(renderer, "navigationEndpoint", "browseEndpoint") || get(titleText, "runs", 0, "navigationEndpoint", "browseEndpoint");
		} else if (kind === "tworow") {
			title = runsText(renderer.title);
			bylineRuns = get(renderer, "subtitle", "runs") || [];
			videoId = get(renderer, "navigationEndpoint", "watchEndpoint", "videoId") || "";
			browse = get(renderer, "navigationEndpoint", "browseEndpoint") || get(renderer, "title", "runs", 0, "navigationEndpoint", "browseEndpoint");
		} else {
			title = runsText(renderer.title);
			bylineRuns = get(renderer, "longBylineText", "runs") || get(renderer, "shortBylineText", "runs") || [];
			videoId = renderer.videoId || "";
			duration = parseDuration(runsText(renderer.lengthText));
		}
		var byline = parseByline(bylineRuns);
		var videoType = findOne(renderer, "musicVideoType") || "";
		var type = browse ? (get(browse, "browseEndpointContextSupportedConfigs", "browseEndpointContextMusicConfig", "pageType") || "") : "";
		return {
			title: trim(title), videoId: videoId, videoType: videoType, browseId: browse ? browse.browseId : "", pageType: type,
			label: byline.label, artists: byline.artists, album: byline.album, duration: duration || byline.duration,
			year: byline.year, stats: byline.stats, thumbnails: thumbnailsOf(renderer)
		};
	}

	// "Artist - Song (Official Video)" -> ["Artist", "Song"] (library.split_video_title).
	function splitVideoTitle(title, channel) {
		var clean = trim(String(title || "").replace(/\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|teledysk|prod\.?)[^\)\]]*[\)\]]/gi, ""));
		channel = String(channel || "").replace(/\s*-\s*Topic$/, "");
		var at = clean.indexOf(" - ");
		if (at !== -1) return [trim(clean.slice(0, at)), trim(clean.slice(at + 3))];
		return [channel, clean];
	}

	function trackFromItem(item, defaults) {
		defaults = defaults || {};
		if (!item.videoId) return null;
		var artists = item.artists.length ? item.artists : (defaults.artists || []);
		var names = [];
		var refs = [];
		each(artists, function (a) {
			names.push(a.name);
			if (a.id && starts(a.id, "UC")) refs.push({id: a.id, name: a.name});
		});
		var artist = names.join(", ");
		var title = item.title;
		var videoType = item.videoType || defaults.videoType || "";
		if (videoType !== "MUSIC_VIDEO_TYPE_ATV" && videoType !== "MUSIC_VIDEO_TYPE_OMV" && has(title, " - ")) {
			var split = splitVideoTitle(title, artist);
			artist = split[0];
			title = split[1];
		}
		var album = item.album || defaults.album || null;
		return {
			id: "yt-" + item.videoId,
			title: title,
			artist: artist,
			album: album ? album.name : "",
			albumId: album && starts(album.id, "MPREb") ? album.id : "",
			duration: item.duration || 0,
			source: "youtube",
			youtubeId: item.videoId,
			coverUrl: defaults.coverUrl || coverFor(item.videoId, item.thumbnails),
			artistRefs: refs
		};
	}

	function tracksIn(obj, defaults) {
		var tracks = [];
		var seen = {};
		each(findAll(obj, "musicResponsiveListItemRenderer"), function (renderer) {
			var track = trackFromItem(parseItem(renderer, "list"), defaults);
			if (track && !seen[track.id]) {
				seen[track.id] = true;
				tracks.push(track);
			}
		});
		return tracks;
	}

	// ------------------------------------------------------------------
	// Entities (browse.yt_artist / yt_album / yt_playlist)

	function artistEntity(id, name, subtitle, image) {
		return {id: "yt-ch-" + id, kind: "artist", name: name || "", subtitle: subtitle || "Artist", source: "youtube", image: image || "",
			url: "https://music.youtube.com/channel/" + id};
	}

	function albumEntity(item, artistName) {
		var names = [];
		each(item.artists, function (a) { names.push(a.name); });
		var type = item.label && item.label !== "Album" ? item.label : "";
		var parts = [];
		each([names.join(", ") || artistName || "", item.year, type || "Album"], function (part) { if (part) parts.push(part); });
		return {id: "yt-al-" + item.browseId, kind: "album", name: item.title, subtitle: parts.join(" \u00b7 "), source: "youtube",
			image: squareImage(item.thumbnails), url: "https://music.youtube.com/browse/" + item.browseId};
	}

	function playlistEntity(item) {
		var listId = starts(item.browseId, "VL") ? item.browseId.slice(2) : item.browseId;
		var parts = [];
		var owner = item.artists.length ? item.artists[0].name : "";
		if (owner) parts.push(owner);
		var count = first(item.stats, function (s) { return /\b(songs?|tracks?)\b/i.test(s); });
		if (count) parts.push(count);
		return {id: "yt-pl-" + listId, kind: "playlist", name: item.title, subtitle: parts.join(" \u00b7 "), source: "youtube",
			image: squareImage(item.thumbnails), url: "https://music.youtube.com/playlist?list=" + listId};
	}

	function entityFromItem(item, artistName) {
		if (!item.browseId) return null;
		if (item.pageType === "MUSIC_PAGE_TYPE_ARTIST" || item.pageType === "MUSIC_PAGE_TYPE_USER_CHANNEL" || (starts(item.browseId, "UC") && item.label === "Artist")) {
			if (!starts(item.browseId, "UC")) return null;
			var subtitle = first(item.stats, function (s) { return /subscribers|audience|listeners/i.test(s); });
			return artistEntity(item.browseId, item.title, subtitle || "Artist", squareImage(item.thumbnails));
		}
		if (item.pageType === "MUSIC_PAGE_TYPE_ALBUM" || starts(item.browseId, "MPREb")) return albumEntity(item, artistName);
		if (item.pageType === "MUSIC_PAGE_TYPE_PLAYLIST" || starts(item.browseId, "VL")) return playlistEntity(item);
		return null;
	}

	// ------------------------------------------------------------------
	// Search

	// kind "videos": plain YouTube (www.youtube.com) videos instead of YouTube Music.
	extractor.search = function (query, kind) {
		query = trim(query);
		if (!query) return {tracks: [], artists: [], albums: [], playlists: []};
		if (kind === "videos") {
			var pages = [post("www.youtube.com", "search", {query: query, params: WEB_SEARCH_VIDEOS}, WEB)];
			var token = nextContinuation(pages[0]);
			if (token) pages.push(post("www.youtube.com", "search", {continuation: token}, WEB));
			return {tracks: webVideoTracks(pages).slice(0, 40), artists: [], albums: [], playlists: []};
		}
		var tracks = tracksIn(music("search", {query: query, params: SEARCH_SONGS}));
		if (tracks.length < 5) {
			var seen = {};
			each(tracks, function (t) { seen[t.id] = true; });
			each(tracksIn(music("search", {query: query, params: SEARCH_VIDEOS})).slice(0, 10), function (t) {
				if (!seen[t.id]) tracks.push(t);
			});
		}
		var artists = [], albums = [], playlists = [], seenEntities = {};
		var all;
		try {
			all = music("search", {query: query});
		} catch (e) {
			P7.log("search extras: " + e.message);
			all = null;
		}
		var renderers = [];
		each(findAll(all, "musicCardShelfRenderer"), function (card) {
			var browse = get(card, "title", "runs", 0, "navigationEndpoint", "browseEndpoint");
			if (!browse) return;
			renderers.push({
				title: runsText(card.title), videoId: "", browseId: browse.browseId, pageType: pageType({browseEndpoint: browse}),
				label: "", artists: [], album: null, year: "", stats: parseByline(get(card, "subtitle", "runs")).stats,
				thumbnails: thumbnailsOf(card)
			});
		});
		each(findAll(all, "musicResponsiveListItemRenderer"), function (r) { renderers.push(parseItem(r, "list")); });
		each(renderers, function (item) {
			var entity = entityFromItem(item);
			if (!entity || seenEntities[entity.id]) return;
			seenEntities[entity.id] = true;
			if (entity.kind === "artist" && nameMatches(entity.name, query)) artists.push(entity);
			else if (entity.kind === "album") albums.push(entity);
			else if (entity.kind === "playlist") playlists.push(entity);
		});
		return {tracks: tracks.slice(0, 30), artists: artists.slice(0, 3), albums: albums.slice(0, 6), playlists: playlists.slice(0, 6)};
	};

	// ------------------------------------------------------------------
	// Streams

	function audioFormat(streamingData) {
		var formats = (streamingData && streamingData.adaptiveFormats) || [];
		for (var i = 0; i < AUDIO_ITAGS.length; i++) {
			var match = first(formats, function (f) { return f.itag === AUDIO_ITAGS[i] && f.url; });
			if (match) return match;
		}
		return first(formats, function (f) { return f.url && starts(f.mimeType, "audio/mp4") && has(f.mimeType, "mp4a"); });
	}

	function expiryOf(url) {
		var match = /[?&]expire=(\d+)/.exec(url);
		return match ? parseInt(match[1], 10) : now() + 6 * 3600;
	}

	// googlevideo answers 403 for URLs it won't serve, sometimes only past the start of the file.
	function urlWorks(url, length, headers) {
		var offset = length > 200000 ? Math.floor(length / 2) : 0;
		var request = {url: url, method: "GET", headers: extend({"Range": "bytes=" + offset + "-" + (offset + 1)}, headers), timeout: 15};
		try {
			var status = P7.http(request).status;
			return status === 206 || status === 200;
		} catch (e) {
			return true; // a network hiccup isn't the URL's fault
		}
	}

	extractor.stream = function (videoId) {
		ensureVisitor();
		var reasons = [];
		var renewed = false;
		for (var i = 0; i < PLAYER_CLIENTS.length; i++) {
			var client = PLAYER_CLIENTS[i];
			var data;
			try {
				data = post(client.host, "player", {
					videoId: videoId,
					playbackContext: {contentPlaybackContext: {html5Preference: "HTML5_PREF_WANTS"}},
					contentCheckOk: true,
					racyCheckOk: true
				}, client);
			} catch (e) {
				reasons.push(client.name + ": " + e.message);
				continue;
			}
			var status = get(data, "playabilityStatus", "status");
			if (status !== "OK") {
				if (status === "LOGIN_REQUIRED" && !renewed) {
					// "Sign in to confirm you're not a bot": usually cured by a fresh visitor id.
					renewed = true;
					P7.set("visitorData", "");
					ensureVisitor();
					i--;
					continue;
				}
				reasons.push(client.name + ": " + (get(data, "playabilityStatus", "reason") || status));
				continue;
			}
			var format = audioFormat(data.streamingData);
			if (!format) {
				reasons.push(client.name + ": no AAC audio");
				continue;
			}
			var length = parseInt(format.contentLength || "0", 10) || 0;
			var headers = {"User-Agent": client.context.userAgent};
			if (!urlWorks(format.url, length, headers)) {
				reasons.push(client.name + ": refused");
				continue;
			}
			return {url: format.url, headers: headers, expires: expiryOf(format.url), mimeType: format.mimeType, contentLength: length, itag: format.itag,
				client: client.name};
		}
		P7.log("stream " + videoId + " failed: " + reasons.join("; "));
		var reason = reasons.length ? reasons[0].replace(/^[a-z_]+: /, "") : "";
		throw new Error(reason && !/^\d/.test(reason) ? "YouTube won't play this song: " + reason : "Couldn't load this song from YouTube.");
	};

	// ------------------------------------------------------------------
	// Single songs

	extractor.track = function (videoId) {
		var data = music("next", {videoId: videoId, isAudioOnly: true, enablePersistentPlaylistPanel: true});
		var renderer = first(findAll(data, "playlistPanelVideoRenderer"), function (r) { return r.videoId === videoId; });
		if (renderer) {
			var track = trackFromItem(parseItem(renderer, "panel"));
			if (track) return track;
		}
		var player = post(MUSIC, "player", {videoId: videoId, contentCheckOk: true, racyCheckOk: true}, PLAYER_CLIENTS[0]);
		var details = player.videoDetails;
		if (!details) throw new Error("This video couldn't be found.");
		var split = splitVideoTitle(details.title, details.author);
		return {
			id: "yt-" + videoId, title: split[1], artist: split[0], album: "", albumId: "", duration: parseInt(details.lengthSeconds || "0", 10),
			source: "youtube", youtubeId: videoId, coverUrl: "https://i.ytimg.com/vi/" + videoId + "/hqdefault.jpg",
			artistRefs: details.channelId ? [{id: details.channelId, name: String(details.author || "").replace(/\s*-\s*Topic$/, "")}] : []
		};
	};

	extractor.trackArtists = function (videoId) {
		var track = extractor.track(videoId);
		var out = [], seen = {};
		each(track.artistRefs, function (ref) {
			var id = "yt-ch-" + ref.id;
			if (seen[id]) return;
			seen[id] = true;
			out.push(artistEntity(ref.id, ref.name, "Artist", ""));
		});
		// Plain uploads: the artist is usually named in the title ("Artist - Song"), the channel is just the uploader.
		var named = trim(String(track.artist || "").split(/,|&| feat\.? | ft\.? /i)[0]);
		each(track.artistRefs, function (ref) { if (fold(ref.name) === fold(named)) named = ""; });
		if (named) {
			try {
				var found = extractor.search(named).artists;
				if (found.length && !seen[found[0].id]) {
					out.unshift(found[0]);
					each(out, function (a, i) { if (i > 0) a.subtitle = "Channel"; });
				}
			} catch (e) {
				P7.log("artist lookup: " + e.message);
			}
		}
		return out;
	};

	// ------------------------------------------------------------------
	// Playlists, albums, channels

	function headerOf(page) {
		return findOne(page, "musicResponsiveHeaderRenderer") || findOne(page, "musicDetailHeaderRenderer")
			|| findOne(page, "musicImmersiveHeaderRenderer") || findOne(page, "musicVisualHeaderRenderer") || {};
	}

	function playlistOwner(header) {
		var strapline = runsText(header.straplineTextOne);
		if (strapline) return strapline;
		var face = get(header, "facepile", "avatarStackViewModel", "text", "content");
		if (face) return face;
		var byline = parseByline(get(header, "subtitle", "runs"));
		return byline.artists.length ? byline.artists[0].name : "";
	}

	function youtubePlaylist(listId) {
		if (listId === "LM") throw new Error("Liked Music needs a YouTube login, which only the Player7 server supports.");
		var pages;
		try {
			pages = browseAll({browseId: "VL" + listId});
		} catch (e) {
			if (e.status === 404 || e.status === 400) throw new Error("This playlist couldn't be found (is it private?).");
			throw e;
		}
		var header = headerOf(pages[0]);
		var title = runsText(header.title);
		var tracks = [], seen = {};
		each(pages, function (page) {
			each(tracksIn(page), function (t) {
				if (!seen[t.id]) {
					seen[t.id] = true;
					tracks.push(t);
				}
			});
		});
		// YouTube Music leaves out some plain videos; when many are missing, read the playlist from YouTube itself.
		var expected = 0;
		var countMatch = /([\d,.]+)\s+(?:tracks|songs|videos)/i.exec(runsText(header.secondSubtitle) + " " + runsText(header.subtitle));
		if (countMatch) expected = parseInt(countMatch[1].replace(/[,.]/g, ""), 10) || 0;
		if (!title && !tracks.length) throw new Error("This playlist couldn't be loaded (is it private?).");
		if (expected && tracks.length < expected * 0.8) {
			try {
				var full = webPlaylistTracks(listId);
				if (full.length > tracks.length) {
					var known = {};
					each(tracks, function (t) { known[t.id] = t; });
					var merged = [];
					each(full, function (t) { merged.push(known[t.id] || t); });
					tracks = merged;
				}
			} catch (e) {
				P7.log("web playlist " + listId + ": " + e.message);
			}
		}
		var image = squareImage(thumbnailsOf(header));
		return {
			playlist: {id: "yt-pl-" + listId, name: title || listId, source: "youtube", kind: "playlist", owner: playlistOwner(header),
				url: "https://music.youtube.com/playlist?list=" + listId, image: image},
			tracks: tracks
		};
	}

	// Plain YouTube (www.youtube.com) playlist items: playlistVideoRenderer, newer lockupViewModel.
	function webVideoTracks(pages, channelName, channelId) {
		var tracks = [], seen = {};
		function add(videoId, title, channel, channelUC, duration) {
			if (!videoId || seen[videoId] || !duration) return;
			seen[videoId] = true;
			var split = splitVideoTitle(title, channel || channelName);
			var refId = channelUC || channelId;
			tracks.push({
				id: "yt-" + videoId, title: split[1], artist: split[0], album: "", albumId: "", duration: duration, source: "youtube",
				youtubeId: videoId, coverUrl: "https://i.ytimg.com/vi/" + videoId + "/hqdefault.jpg",
				artistRefs: refId ? [{id: refId, name: channel || channelName || ""}] : []
			});
		}
		each(pages, function (page) {
			each(findAll(page, "playlistVideoRenderer").concat(findAll(page, "videoRenderer")), function (r) {
				var byline = get(r, "shortBylineText", "runs", 0) || get(r, "ownerText", "runs", 0) || {};
				add(r.videoId, runsText(r.title), byline.text, get(byline, "navigationEndpoint", "browseEndpoint", "browseId"),
					parseInt(r.lengthSeconds || "0", 10) || parseDuration(runsText(r.lengthText)));
			});
			each(findAll(page, "lockupViewModel"), function (r) {
				if (r.contentType !== "LOCKUP_CONTENT_TYPE_VIDEO") return;
				var meta = get(r, "metadata", "lockupMetadataViewModel") || {};
				var badge = findOne(r.contentImage, "thumbnailBadgeViewModel");
				var rows = findAll(meta.metadata, "metadataParts");
				var channel = "";
				each(rows, function (parts) { if (!channel && parts[0]) channel = get(parts[0], "text", "content") || ""; });
				if (isStat(channel) || / ago$/.test(channel)) channel = ""; // channel pages list views and dates only
				add(r.contentId, get(meta, "title", "content"), channel, "", parseDuration(get(badge, "text") || ""));
			});
		});
		return tracks;
	}

	function webBrowseAll(body, maxPages) {
		var pages = [post("www.youtube.com", "browse", body, WEB)];
		var token = nextContinuation(pages[0]);
		while (token && pages.length < (maxPages || 40)) {
			var page = post("www.youtube.com", "browse", {continuation: token}, WEB);
			pages.push(page);
			token = nextContinuation(page);
		}
		return pages;
	}

	function webPlaylistTracks(listId) {
		return webVideoTracks(webBrowseAll({browseId: "VL" + listId}));
	}

	function album(browseId) {
		var page = music("browse", {browseId: browseId});
		var header = headerOf(page);
		var name = runsText(header.title);
		if (!name) throw new Error("This album couldn't be found.");
		var artists = parseByline(get(header, "straplineTextOne", "runs")).artists;
		if (!artists.length) artists = parseByline(get(header, "subtitle", "runs")).artists;
		var cover = squareImage(thumbnailsOf(header));
		var artistNames = [];
		each(artists, function (a) { artistNames.push(a.name); });
		var tracks = tracksIn(get(page, "contents", "twoColumnBrowseResultsRenderer", "secondaryContents") || page,
			{artists: artists, album: {id: browseId, name: name}, coverUrl: cover, videoType: "MUSIC_VIDEO_TYPE_ATV"});
		return {
			playlist: {id: "yt-al-" + browseId, name: name, source: "youtube", kind: "album", owner: artistNames.join(", "),
				url: "https://music.youtube.com/browse/" + browseId, image: cover},
			tracks: tracks
		};
	}

	function artistPage(channelId) {
		var page;
		try {
			page = music("browse", {browseId: channelId});
		} catch (e) {
			if (e.status === 404 || e.status === 400) throw new Error("This channel couldn't be found.");
			throw e;
		}
		return page;
	}

	function channelUploads(channelId, name, limit) {
		var pages = webBrowseAll({browseId: channelId, params: CHANNEL_VIDEOS}, Math.ceil((limit || 200) / 30));
		var channelName = name || runsText(get(findOne(pages[0], "pageHeaderViewModel"), "title")) || get(findOne(pages[0], "dynamicTextViewModel"), "text", "content") || "";
		return webVideoTracks(pages, channelName, channelId).slice(0, limit || 200);
	}

	function songsListOf(page) {
		var shelf = findOne(page, "musicShelfRenderer");
		var endpoint = get(shelf, "title", "runs", 0, "navigationEndpoint", "browseEndpoint") || get(shelf, "bottomEndpoint", "browseEndpoint");
		return endpoint && starts(endpoint.browseId, "VL") ? endpoint.browseId.slice(2) : "";
	}

	function channel(channelId) {
		var page = artistPage(channelId);
		var header = headerOf(page);
		var name = runsText(header.title);
		var listId = songsListOf(page);
		var tracks = [];
		if (listId) {
			try {
				tracks = youtubePlaylist(listId).tracks;
			} catch (e) {
				P7.log("artist songs " + channelId + ": " + e.message);
			}
		}
		if (!tracks.length) tracks = tracksIn(findOne(page, "musicShelfRenderer"));
		if (!tracks.length) tracks = channelUploads(channelId, name, 500);
		if (!tracks.length) throw new Error("This channel has no songs or videos.");
		return {
			playlist: {id: "yt-ch-" + channelId, name: name || "YouTube Channel", source: "youtube", kind: "artist",
				owner: listId ? "Artist" : "Channel", url: "https://music.youtube.com/channel/" + channelId, image: squareImage(thumbnailsOf(header))},
			tracks: tracks
		};
	}

	extractor.collection = function (id) {
		if (starts(id, "yt-pl-")) return youtubePlaylist(id.slice(6));
		if (starts(id, "yt-al-")) return album(id.slice(6));
		if (starts(id, "yt-ch-")) return channel(id.slice(6));
		throw new Error("Unknown playlist.");
	};

	// ------------------------------------------------------------------
	// Artist pages (browse.youtube_artist_page)

	function carouselTitle(shelf) {
		return trim(runsText(get(shelf, "header", "musicCarouselShelfBasicHeaderRenderer", "title")));
	}

	// The full list behind a carousel's "More" button (all albums / singles), else what the carousel shows.
	function carouselItems(shelf) {
		var more = get(shelf, "header", "musicCarouselShelfBasicHeaderRenderer", "moreContentButton", "buttonRenderer", "navigationEndpoint", "browseEndpoint");
		if (more && more.params && starts(more.browseId, "MPAD")) {
			try {
				var full = findAll(music("browse", {browseId: more.browseId, params: more.params}), "musicTwoRowItemRenderer");
				if (full.length) return full;
			} catch (e) {
				P7.log("discography: " + e.message);
			}
		}
		return findAll(shelf.contents, "musicTwoRowItemRenderer");
	}

	extractor.artist = function (id) {
		if (!starts(id, "yt-ch-")) throw new Error("Unknown artist.");
		var channelId = id.slice(6);
		var page = artistPage(channelId);
		var header = headerOf(page);
		var name = trim(runsText(header.title));
		var sections = [];
		var shelf = findOne(page, "musicShelfRenderer");
		var listId = songsListOf(page);
		var top = tracksIn(shelf);
		if (top.length) {
			var section = {title: "Top Songs", type: "tracks", tracks: top};
			if (listId) {
				section.more = {id: "yt-pl-" + listId, kind: "playlist", name: name + " \u2013 All Songs", subtitle: "", source: "youtube", image: "",
					url: "https://music.youtube.com/playlist?list=" + listId};
			}
			sections.push(section);
		}
		var related = [];
		each(findAll(page, "musicCarouselShelfRenderer"), function (carousel) {
			var title = carouselTitle(carousel);
			var lower = title.toLowerCase();
			if (lower === "albums" || lower === "singles & eps" || lower === "singles") {
				var albums = [];
				each(carouselItems(carousel), function (r) {
					var item = parseItem(r, "tworow");
					if (item.browseId && starts(item.browseId, "MPREb")) albums.push(albumEntity(item, name));
				});
				if (albums.length) sections.push({title: lower === "albums" ? "Albums" : "Singles & EPs", type: "entities", items: albums});
			} else if (lower === "videos") {
				var videos = [];
				each(findAll(carousel.contents, "musicTwoRowItemRenderer"), function (r) {
					var item = parseItem(r, "tworow");
					var track = trackFromItem(item, {videoType: "MUSIC_VIDEO_TYPE_OMV"});
					if (track) videos.push(track);
				});
				if (videos.length) sections.push({title: "Videos", type: "tracks", tracks: videos});
			} else if (lower === "fans might also like" || lower === "similar artists") {
				each(findAll(carousel.contents, "musicTwoRowItemRenderer"), function (r) {
					var entity = entityFromItem(parseItem(r, "tworow"));
					if (entity && entity.kind === "artist") related.push(entity);
				});
			}
		});
		if (!listId) {
			try {
				var uploads = channelUploads(channelId, name, 100);
				if (uploads.length) sections.push({title: "Uploads", type: "tracks", tracks: uploads});
			} catch (e) {
				P7.log("uploads " + channelId + ": " + e.message);
			}
		}
		if (related.length) sections.push({title: "Fans Might Also Like", type: "entities", items: related});
		if (!sections.length && !name) throw new Error("This channel couldn't be loaded.");

		var thumbnails = thumbnailsOf(header);
		var subscribers = runsText(get(header, "subscriptionButton", "subscribeButtonRenderer", "subscriberCountText"));
		var parts = [];
		if (subscribers) parts.push(subscribers + " subscribers");
		if (!listId) parts.push("Channel");
		return extend(artistEntity(channelId, name, parts.join(" \u00b7 "), squareImage(thumbnails)), {
			banner: biggest(thumbnails),
			sections: sections
		});
	};

	// ------------------------------------------------------------------
	// Links

	extractor.resolve = function (url) {
		url = trim(url);
		var match;
		if (!/(^|[\/.])(youtube\.com|youtu\.be)([\/?#]|$)/.test(url)) return null;
		if ((match = /music\.youtube\.com\/browse\/(MPREb_[A-Za-z0-9_-]+)/.exec(url))) return {collection: "yt-al-" + match[1]};
		var video = /(?:[?&]v=|youtu\.be\/|\/shorts\/|\/embed\/|\/live\/)([A-Za-z0-9_-]{11})/.exec(url);
		var list = /[?&]list=([A-Za-z0-9_-]+)/.exec(url);
		// Mixes ("RD…") are generated on the fly and can't be browsed; play the song itself.
		if (list && !(video && starts(list[1], "RD"))) return {collection: "yt-pl-" + list[1]};
		if (video) return {track: "yt-" + video[1]};
		if ((match = /youtube\.com\/channel\/(UC[A-Za-z0-9_-]{22})/.exec(url))) return {collection: "yt-ch-" + match[1]};
		if (/youtube\.com\/(@[^\/?#&]+|c\/[^\/?#&]+|user\/[^\/?#&]+)/.test(url)) {
			var target = url.replace(/^(https?:\/\/)?(www\.|m\.|music\.)?youtube\.com/, "https://www.youtube.com");
			if (!/^https?:/.test(target)) target = "https://" + target;
			var data = post("www.youtube.com", "navigation/resolve_url", {url: target}, WEB);
			var browseId = get(data, "endpoint", "browseEndpoint", "browseId");
			if (!browseId || !starts(browseId, "UC")) throw new Error("This YouTube channel could not be found.");
			return {collection: "yt-ch-" + browseId};
		}
		return null;
	};
})();
