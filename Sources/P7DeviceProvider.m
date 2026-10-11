#import "P7DeviceProvider.h"
#import "P7LocalLibrary.h"
#import "P7Script.h"

static NSString *const kCollectionPrefixes[] = {@"yt-pl-", @"yt-al-", @"yt-ch-"};

@implementation P7DeviceProvider {
	NSMutableDictionary *_streams;       // track id -> {url, headers, expires}
	NSMutableDictionary *_streamLocks;   // track id -> NSLock, so a song is looked up once at a time
	NSMutableDictionary *_collections;   // collection id -> {at, playlist, tracks}; previews are often imported right after
	NSCache *_searches;                  // query -> search result (10 minutes)
	dispatch_queue_t _prefetchQueue;
}

+ (instancetype)shared {
	static P7DeviceProvider *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_streams = [NSMutableDictionary new];
		_streamLocks = [NSMutableDictionary new];
		_collections = [NSMutableDictionary new];
		_searches = [NSCache new];
		_searches.countLimit = 100;
		_prefetchQueue = dispatch_queue_create("com.szv.player7.prefetch", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

- (P7LocalLibrary *)library {
	return [P7LocalLibrary shared];
}

#pragma mark - Script

- (id)script:(NSString *)function arguments:(NSArray *)arguments error:(NSError **)error {
	P7Script *script = [P7Script shared];
	if (![script hasFunction:function]) {
		if (error) *error = P7ProviderError(501, @"This isn't available on the iPhone yet.");
		return nil;
	}
	NSError *scriptError = nil;
	id result = [script call:function arguments:arguments error:&scriptError];
	if (scriptError) {
		NSLog(@"[Player7] extractor %@ failed: %@", function, scriptError.localizedDescription);
		if (error) *error = P7ProviderError(400, scriptError.localizedDescription);
		return nil;
	}
	return result;
}

- (NSDictionary *)dictionary:(id)value {
	return [value isKindOfClass:[NSDictionary class]] ? value : nil;
}

- (NSArray *)array:(id)value {
	return [value isKindOfClass:[NSArray class]] ? value : @[];
}

- (NSString *)videoIDForTrack:(NSDictionary *)track trackID:(NSString *)trackID {
	NSString *videoID = [track[@"youtubeId"] isKindOfClass:[NSString class]] ? track[@"youtubeId"] : nil;
	if (!videoID.length && [trackID hasPrefix:@"yt-"]) videoID = [trackID substringFromIndex:3];
	return videoID.length ? videoID : nil;
}

- (NSDictionary *)lookupTrack:(NSString *)trackID error:(NSError **)error {
	NSDictionary *track = [self.library trackForID:trackID];
	if (track) return track;
	if (![trackID hasPrefix:@"yt-"]) {
		if (error) *error = P7ProviderError(404, @"This song needs the Player7 server it came from.");
		return nil;
	}
	track = [self dictionary:[self script:@"track" arguments:@[[trackID substringFromIndex:3]] error:error]];
	if (track) [self.library upsertTracks:@[track]];
	return track;
}

#pragma mark - Collections

- (BOOL)isCollectionID:(NSString *)collectionID {
	for (NSUInteger i = 0; i < sizeof(kCollectionPrefixes) / sizeof(kCollectionPrefixes[0]); i++) {
		if ([collectionID hasPrefix:kCollectionPrefixes[i]] && collectionID.length > kCollectionPrefixes[i].length) return YES;
	}
	return NO;
}

// (playlist, tracks) of a YouTube playlist / album / artist.
- (NSDictionary *)fetchCollection:(NSString *)collectionID fresh:(BOOL)fresh error:(NSError **)error {
	@synchronized (_collections) {
		NSDictionary *hit = _collections[collectionID];
		if (hit && !fresh && [[NSDate date] timeIntervalSinceDate:hit[@"at"]] < 600) return hit;
	}
	if (![self isCollectionID:collectionID]) {
		if (error) *error = P7ProviderError(404, @"Playlist not found.");
		return nil;
	}
	NSDictionary *result = [self dictionary:[self script:@"collection" arguments:@[collectionID] error:error]];
	NSDictionary *playlist = [self dictionary:result[@"playlist"]];
	if (!playlist[@"id"]) {
		if (error && result) *error = P7ProviderError(502, @"This playlist couldn't be read.");
		return nil;
	}
	NSDictionary *entry = @{@"at": [NSDate date], @"playlist": playlist, @"tracks": [self array:result[@"tracks"]]};
	[self.library upsertTracks:entry[@"tracks"]];
	@synchronized (_collections) {
		if (_collections.count > 50) [_collections removeAllObjects];
		_collections[collectionID] = entry;
	}
	return entry;
}

- (NSDictionary *)collectionPage:(NSString *)collectionID error:(NSError **)error {
	NSDictionary *stored = [self.library playlistForID:collectionID];
	if (stored) return @{@"playlist": [self.library publicPlaylist:stored withTracks:YES tracks:nil]};
	NSDictionary *entry = [self fetchCollection:collectionID fresh:NO error:error];
	if (!entry) return nil;
	return @{@"playlist": [self.library publicPlaylist:entry[@"playlist"] withTracks:YES tracks:entry[@"tracks"]]};
}

- (NSDictionary *)importURL:(NSString *)url error:(NSError **)error {
	url = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
	if ([url hasPrefix:@"ytmusic"] || [url rangeOfString:@"music.youtube.com/library"].location != NSNotFound) {
		if (error) *error = P7ProviderError(400, @"Importing your YouTube Music library needs a Player7 server.");
		return nil;
	}
	if ([url rangeOfString:@"spotify.com"].location != NSNotFound || [url rangeOfString:@"soundcloud.com"].location != NSNotFound) {
		if (error) *error = P7ProviderError(400, @"Spotify and SoundCloud links need a Player7 server. On this iPhone, paste a YouTube or YouTube Music link.");
		return nil;
	}
	NSError *resolveError = nil;
	NSDictionary *target = [self dictionary:[self script:@"resolve" arguments:@[url] error:&resolveError]];
	if (resolveError.code == 501) {
		if (error) *error = resolveError;
		return nil;
	}
	NSString *collectionID = [target[@"collection"] isKindOfClass:[NSString class]] ? target[@"collection"] : nil;
	NSString *trackID = [target[@"track"] isKindOfClass:[NSString class]] ? target[@"track"] : nil;
	if (collectionID) {
		NSDictionary *entry = [self fetchCollection:collectionID fresh:NO error:error];
		if (!entry) return nil;
		NSDictionary *saved = [self.library savePlaylist:entry[@"playlist"] tracks:entry[@"tracks"]];
		return @{@"playlist": [self.library publicPlaylist:saved withTracks:YES tracks:nil], @"imported": @1, @"background": @NO};
	}
	if (trackID) {
		if (![self lookupTrack:trackID error:error]) return nil;
		[self.library setTrackID:trackID added:YES];
		return @{@"playlist": [NSNull null], @"imported": @1, @"background": @NO};
	}
	if (error) *error = resolveError ?: P7ProviderError(400, @"Paste a YouTube or YouTube Music link: playlist, album, channel or song.");
	return nil;
}

#pragma mark - Search and artists

// videos: plain YouTube videos instead of YouTube Music.
- (NSDictionary *)search:(NSString *)query videos:(BOOL)videos full:(BOOL)full error:(NSError **)error {
	NSString *key = [[query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
	if (!key.length) return @{@"tracks": @[], @"artists": @[], @"albums": @[], @"playlists": @[]};
	if (videos) key = [@"videos:" stringByAppendingString:key];
	NSDictionary *hit = [_searches objectForKey:key];
	NSDictionary *result = hit && [[NSDate date] timeIntervalSinceDate:hit[@"at"]] < 600 ? hit[@"result"] : nil;
	if (!result) {
		result = [self dictionary:[self script:@"search" arguments:@[query, videos ? @"videos" : @"songs"] error:error]];
		if (!result) return nil;
		[_searches setObject:@{@"at": [NSDate date], @"result": result} forKey:key];
	}
	NSArray *tracks = [self array:result[@"tracks"]];
	[self.library upsertTracks:tracks];
	NSMutableDictionary *answer = [@{@"tracks": [self.library publicTracks:tracks]} mutableCopy];
	if (full) {
		for (NSString *kind in @[@"artists", @"albums", @"playlists"]) {
			NSMutableArray *items = [NSMutableArray new];
			for (NSDictionary *entity in [self array:result[kind]]) {
				if ([self dictionary:entity][@"id"]) [items addObject:[self.library publicEntity:entity]];
			}
			answer[kind] = items;
		}
	}
	return answer;
}

- (NSDictionary *)artistPage:(NSString *)artistID error:(NSError **)error {
	NSDictionary *page = [self dictionary:[self script:@"artist" arguments:@[artistID] error:error]];
	if (!page) return nil;
	NSMutableDictionary *answer = [[self.library publicEntity:@{
		@"id": artistID, @"kind": @"artist", @"name": page[@"name"] ?: @"", @"subtitle": page[@"subtitle"] ?: @"",
		@"source": @"youtube", @"image": page[@"image"] ?: @"", @"url": page[@"url"] ?: @"",
	}] mutableCopy];
	NSString *bannerID = [artistID stringByAppendingString:@"-banner"];
	[self.library setImage:page[@"banner"] forID:bannerID replace:YES];
	answer[@"bannerKey"] = [self.library imageForID:bannerID] ? bannerID : artistID;

	NSMutableArray *sections = [NSMutableArray new];
	for (NSDictionary *section in [self array:page[@"sections"]]) {
		if (![self dictionary:section]) continue;
		NSMutableDictionary *out = [@{@"title": section[@"title"] ?: @"", @"type": section[@"type"] ?: @"tracks"} mutableCopy];
		if ([section[@"type"] isEqualToString:@"entities"]) {
			NSMutableArray *items = [NSMutableArray new];
			for (NSDictionary *entity in [self array:section[@"items"]]) {
				if ([self dictionary:entity][@"id"]) [items addObject:[self.library publicEntity:entity]];
			}
			out[@"items"] = items;
		} else {
			NSArray *tracks = [self array:section[@"tracks"]];
			[self.library upsertTracks:tracks];
			out[@"tracks"] = [self.library publicTracks:tracks];
			if ([self dictionary:section[@"more"]][@"id"]) out[@"more"] = [self.library publicEntity:section[@"more"]];
		}
		[sections addObject:out];
	}
	answer[@"sections"] = sections;
	answer[@"imported"] = @([self.library playlistForID:artistID] != nil);
	return answer;
}

- (NSArray *)artistsOfTrack:(NSString *)trackID error:(NSError **)error {
	NSDictionary *track = [self lookupTrack:trackID error:error];
	if (!track) return nil;
	NSString *videoID = [self videoIDForTrack:track trackID:trackID];
	NSArray *found = videoID && [[P7Script shared] hasFunction:@"trackArtists"] ? [self array:[self script:@"trackArtists" arguments:@[videoID] error:NULL]] : @[];
	NSMutableArray *artists = [NSMutableArray new];
	for (NSDictionary *entity in found) {
		if ([self dictionary:entity][@"id"]) [artists addObject:[self.library publicEntity:entity]];
	}
	if (!artists.count) {
		for (NSDictionary *ref in [self array:track[@"artistRefs"]]) {
			if (![self dictionary:ref][@"id"]) continue;
			[artists addObject:[self.library publicEntity:@{
				@"id": [@"yt-ch-" stringByAppendingString:ref[@"id"]], @"kind": @"artist", @"name": ref[@"name"] ?: @"",
				@"subtitle": @"Artist", @"source": @"youtube", @"url": [@"https://music.youtube.com/channel/" stringByAppendingString:ref[@"id"]],
			}]];
		}
	}
	return artists;
}

#pragma mark - Routes

- (id)responseForMethod:(NSString *)method parts:(NSArray *)parts query:(NSDictionary *)query body:(NSDictionary *)body error:(NSError **)error {
	P7LocalLibrary *library = self.library;
	NSString *first = parts.firstObject;
	BOOL post = [method isEqualToString:@"POST"];

	if (!post) {
		if ([parts isEqualToArray:@[@"ping"]]) return @{@"ok": @YES, @"searchSources": @[@"youtube", @"youtube-videos"]};
		if ([parts isEqualToArray:@[@"playlists"]]) {
			NSMutableArray *playlists = [NSMutableArray new];
			for (NSDictionary *playlist in [library playlists]) [playlists addObject:[library publicPlaylist:playlist withTracks:NO tracks:nil]];
			return @{@"playlists": playlists};
		}
		if (parts.count == 2 && [first isEqualToString:@"playlists"]) {
			NSDictionary *playlist = [library playlistForID:parts[1]];
			if (!playlist) {
				if (error) *error = P7ProviderError(404, @"Playlist not found.");
				return nil;
			}
			NSArray *trackIDs = [self array:playlist[@"trackIds"]];
			[self prefetchTrackIDs:[trackIDs subarrayWithRange:NSMakeRange(0, MIN(2, trackIDs.count))]];
			return @{@"playlist": [library publicPlaylist:playlist withTracks:YES tracks:nil]};
		}
		if ([parts isEqualToArray:@[@"tracks"]]) {
			NSString *filter = [query[@"q"] lowercaseString];
			NSMutableArray *tracks = [NSMutableArray new];
			for (NSDictionary *track in [library libraryTracks]) {
				NSString *text = [[NSString stringWithFormat:@"%@ %@ %@", track[@"title"] ?: @"", track[@"artist"] ?: @"", track[@"album"] ?: @""] lowercaseString];
				if (!filter.length || [text rangeOfString:filter].location != NSNotFound) [tracks addObject:track];
			}
			return @{@"tracks": [library publicTracks:tracks]};
		}
		if ([parts isEqualToArray:@[@"search"]]) {
			return [self search:query[@"q"] ?: @"" videos:[query[@"source"] isEqualToString:@"youtube-videos"] full:[query[@"full"] isEqualToString:@"1"] error:error];
		}
		if ([parts isEqualToArray:@[@"import", @"status"]]) return @{@"running": @NO, @"message": @"", @"done": @0, @"total": @0};
		if ([parts isEqualToArray:@[@"lastfm"]]) return @{@"configured": @NO, @"connected": @NO};
		if (parts.count == 2 && [first isEqualToString:@"artists"]) {
			NSDictionary *artist = [self artistPage:parts[1] error:error];
			return artist ? @{@"artist": artist} : nil;
		}
		if (parts.count == 2 && [first isEqualToString:@"collections"]) return [self collectionPage:parts[1] error:error];
		if (parts.count == 3 && [first isEqualToString:@"tracks"] && [parts[2] isEqualToString:@"artists"]) {
			NSArray *artists = [self artistsOfTrack:parts[1] error:error];
			return artists ? @{@"artists": artists} : nil;
		}
	} else {
		if ([parts isEqualToArray:@[@"import"]]) return [self importURL:[body[@"url"] description] error:error];
		if (parts.count == 3 && [first isEqualToString:@"playlists"] && [parts[2] isEqualToString:@"sync"]) {
			NSDictionary *stored = [library playlistForID:parts[1]];
			NSDictionary *entry = stored ? [self fetchCollection:parts[1] fresh:YES error:error] : nil;
			if (!stored && error) *error = P7ProviderError(400, @"This playlist can't be synced.");
			if (!entry) return nil;
			NSDictionary *saved = [library savePlaylist:entry[@"playlist"] tracks:entry[@"tracks"]];
			return @{@"playlist": [library publicPlaylist:saved withTracks:YES tracks:nil]};
		}
		if (parts.count == 3 && [first isEqualToString:@"playlists"] && [parts[2] isEqualToString:@"delete"]) {
			[library deletePlaylistID:parts[1]];
			return @{@"ok": @YES};
		}
		if ([parts isEqualToArray:@[@"library"]]) {
			NSString *trackID = [body[@"trackId"] isKindOfClass:[NSString class]] ? body[@"trackId"] : @"";
			if (![self lookupTrack:trackID error:error]) return nil;
			[library setTrackID:trackID added:![body[@"remove"] boolValue]];
			return @{@"ok": @YES};
		}
		if ([parts isEqualToArray:@[@"prefetch"]]) {
			[self prefetchTrackIDs:[self array:body[@"ids"]]];
			return @{@"ok": @YES};
		}
		if ([first isEqualToString:@"lastfm"]) {
			if (error) *error = P7ProviderError(400, @"Last.fm scrobbling needs a Player7 or Subsonic server.");
			return nil;
		}
	}
	if (error) *error = P7ProviderError(404, @"no such route");
	return nil;
}

#pragma mark - Audio

- (NSLock *)streamLockForTrackID:(NSString *)trackID {
	@synchronized (_streamLocks) {
		NSLock *lock = _streamLocks[trackID];
		if (!lock) _streamLocks[trackID] = lock = [NSLock new];
		return lock;
	}
}

- (NSURL *)audioURLForTrackID:(NSString *)trackID headers:(NSDictionary **)headers error:(NSError **)error {
	NSLock *lock = [self streamLockForTrackID:trackID];
	[lock lock];
	NSDictionary *stream = [self streamForTrackID:trackID error:error];
	[lock unlock];
	if (headers) *headers = stream[@"headers"];
	return stream ? [NSURL URLWithString:stream[@"url"]] : nil;
}

// {url, headers, expires}: the remembered one while it's good for 5 more minutes, else a new lookup.
- (NSDictionary *)streamForTrackID:(NSString *)trackID error:(NSError **)error {
	NSDictionary *stream;
	@synchronized (_streams) {
		stream = _streams[trackID];
	}
	if (stream && [stream[@"expires"] doubleValue] > [[NSDate date] timeIntervalSince1970] + 300) return stream;
	NSString *videoID = [self videoIDForTrack:[self.library trackForID:trackID] trackID:trackID];
	if (!videoID) {
		if (error) *error = P7ProviderError(404, @"This song needs the Player7 server it came from.");
		return nil;
	}
	NSDictionary *result = [self dictionary:[self script:@"stream" arguments:@[videoID] error:error]];
	if (![result[@"url"] isKindOfClass:[NSString class]]) {
		if (error && result) *error = P7ProviderError(502, @"No playable version of this song was found.");
		return nil;
	}
	double expires = [result[@"expires"] doubleValue] ?: [[NSDate date] timeIntervalSince1970] + 3600;
	stream = @{@"url": result[@"url"], @"headers": [self dictionary:result[@"headers"]] ?: @{}, @"expires": @(expires)};
	@synchronized (_streams) {
		_streams[trackID] = stream;
	}
	return stream;
}

- (void)audioURLFailedForTrackID:(NSString *)trackID {
	@synchronized (_streams) {
		[_streams removeObjectForKey:trackID];
	}
}

// Look the next songs up ahead of time, so they start right away.
- (void)prefetchTrackIDs:(NSArray *)trackIDs {
	for (NSString *trackID in [trackIDs subarrayWithRange:NSMakeRange(0, MIN(3, trackIDs.count))]) {
		if (![trackID isKindOfClass:[NSString class]]) continue;
		dispatch_async(_prefetchQueue, ^{
			[self audioURLForTrackID:trackID headers:NULL error:NULL];
		});
	}
}

#pragma mark - Pictures

- (NSURL *)imageURLForID:(NSString *)itemID size:(NSInteger)size error:(NSError **)error {
	NSString *url = [self.library imageForID:itemID];
	NSDictionary *playlist = url ? nil : [self.library playlistForID:itemID];
	if (playlist) url = [[self.library tracksOfPlaylist:playlist].firstObject objectForKey:@"coverUrl"];
	if (!url && ![itemID hasSuffix:@"-banner"] && ![self isCollectionID:itemID]) {
		NSDictionary *track = [self lookupTrack:itemID error:NULL];
		url = [track[@"coverUrl"] isKindOfClass:[NSString class]] ? track[@"coverUrl"] : nil;
		NSString *videoID = url.length ? nil : [self videoIDForTrack:track trackID:itemID];
		if (videoID) url = [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/hqdefault.jpg", videoID];
	}
	if (!url.length) {
		if (error) *error = P7ProviderError(404, @"No cover.");
		return nil;
	}
	return [NSURL URLWithString:url];
}

@end
