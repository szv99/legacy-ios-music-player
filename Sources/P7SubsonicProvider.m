#import "P7SubsonicProvider.h"
#import "P7HTTP.h"
#import "P7Settings.h"
#import <CommonCrypto/CommonDigest.h>

static NSString *const kTrackPrefix = @"ss-";
static NSString *const kAlbumPrefix = @"ss-al-";
static NSString *const kArtistPrefix = @"ss-ar-";
static NSString *const kPlaylistPrefix = @"ss-pl-";
static NSString *const kLinkPrefix = @"subsonic:";
static const NSUInteger kSongPage = 500;
static const NSUInteger kMaxSongs = 5000;
static const NSTimeInterval kSongsCacheSeconds = 300;

static NSString *P7SSEscape(NSString *string) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	});
	return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

static NSString *P7SSMD5(NSString *string) {
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_MD5_DIGEST_LENGTH];
	CC_MD5(data.bytes, (CC_LONG)data.length, digest);
	NSMutableString *hex = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
	for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
	return hex;
}

static NSString *P7SSHex(NSString *string) {
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	const unsigned char *bytes = data.bytes;
	NSMutableString *hex = [NSMutableString stringWithCapacity:data.length * 2];
	for (NSUInteger i = 0; i < data.length; i++) [hex appendFormat:@"%02x", bytes[i]];
	return hex;
}

static NSString *P7SSString(id value) {
	if ([value isKindOfClass:[NSString class]]) return value;
	if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
	return nil;
}

static NSArray *P7SSArray(id value) {
	if ([value isKindOfClass:[NSArray class]]) return value;
	if ([value isKindOfClass:[NSDictionary class]]) return @[value];   // some servers send a lone object
	return @[];
}

static NSDictionary *P7SSDict(id value) {
	return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

// Lowercase, no accents: what searches and name matching compare.
static NSString *P7SSFold(NSString *string) {
	return [string ?: @"" stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
}

@implementation P7SubsonicProvider {
	NSLock *_lock;
	NSMutableDictionary *_suffixes;          // song id -> original file suffix
	NSMutableDictionary *_covers;            // ss-… id -> coverArt id
	NSMutableSet *_passwordAuth;             // servers that don't take token auth (error 41)
	NSArray *_songs;                         // "Songs" tab, cached
	NSString *_songsKey;                     // server + user the cache is for
	NSTimeInterval _songsAt;
}

- (instancetype)init {
	if ((self = [super init])) {
		_lock = [NSLock new];
		_suffixes = [NSMutableDictionary new];
		_covers = [NSMutableDictionary new];
		_passwordAuth = [NSMutableSet new];
	}
	return self;
}

#pragma mark - Requests

- (NSString *)serverURL {
	return [P7Settings shared].subsonicURL ?: @"";
}

- (NSString *)authQueryForServer:(NSString *)server {
	P7Settings *settings = [P7Settings shared];
	NSString *user = settings.subsonicUsername ?: @"";
	NSString *password = settings.subsonicPassword ?: @"";
	[_lock lock];
	BOOL usePassword = [_passwordAuth containsObject:server];
	[_lock unlock];
	NSString *credentials;
	if (usePassword) {
		credentials = [NSString stringWithFormat:@"p=enc:%@", P7SSHex(password)];
	} else {
		NSString *salt = [NSString stringWithFormat:@"%08x%04x", arc4random(), arc4random_uniform(0x10000)];
		credentials = [NSString stringWithFormat:@"t=%@&s=%@", P7SSMD5([password stringByAppendingString:salt]), salt];
	}
	return [NSString stringWithFormat:@"u=%@&%@&v=1.13.0&c=Player7&f=json", P7SSEscape(user), credentials];
}

// params values: NSString / NSNumber, or an NSArray for a repeated key.
- (NSURL *)URLForMethod:(NSString *)method params:(NSDictionary *)params {
	NSString *server = [self serverURL];
	if (!server.length) return nil;
	NSMutableString *string = [NSMutableString stringWithFormat:@"%@/rest/%@.view?%@", server, method, [self authQueryForServer:server]];
	for (NSString *key in [params.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
		id value = params[key];
		for (id item in [value isKindOfClass:[NSArray class]] ? value : @[value]) {
			[string appendFormat:@"&%@=%@", P7SSEscape(key), P7SSEscape([item description])];
		}
	}
	return [NSURL URLWithString:string];
}

- (NSDictionary *)call:(NSString *)method params:(NSDictionary *)params error:(NSError **)error {
	P7Settings *settings = [P7Settings shared];
	if (![self serverURL].length || !settings.subsonicUsername.length) {
		if (error) *error = P7ProviderError(400, @"Set your Subsonic server address and username in Settings.");
		return nil;
	}
	for (NSUInteger attempt = 0; attempt < 2; attempt++) {
		NSString *server = [self serverURL];
		NSURL *url = [self URLForMethod:method params:params];
		if (!url) {
			if (error) *error = P7ProviderError(400, @"The Subsonic server address isn't valid.");
			return nil;
		}
		NSHTTPURLResponse *response = nil;
		NSError *networkError = nil;
		NSData *data = [P7HTTP GET:url response:&response error:&networkError];
		if (!data) {
			NSLog(@"[Player7] subsonic %@: %@", method, networkError.localizedDescription);
			if (error) *error = P7ProviderError(502, @"Can't reach the Subsonic server.");
			return nil;
		}
		id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
		NSDictionary *root = P7SSDict(P7SSDict(json)[@"subsonic-response"]);
		if (!root.count) {
			NSString *message = response.statusCode >= 400
				? [NSString stringWithFormat:@"The Subsonic server answered with an error (HTTP %ld). Check the address.", (long)response.statusCode]
				: @"That address doesn't look like a Subsonic server.";
			if (error) *error = P7ProviderError(502, message);
			return nil;
		}
		if ([root[@"status"] isEqual:@"ok"]) return root;

		NSDictionary *failure = P7SSDict(root[@"error"]);
		NSInteger code = [failure[@"code"] integerValue];
		NSString *serverMessage = P7SSString(failure[@"message"]);
		if (code == 41 && attempt == 0) {
			// Token authentication isn't supported (LDAP and the like): send the password instead.
			[_lock lock];
			[_passwordAuth addObject:server];
			[_lock unlock];
			continue;
		}
		NSInteger status = 502;
		NSString *message = serverMessage.length ? serverMessage : @"The Subsonic server reported an error.";
		switch (code) {
			case 10: status = 400; break;
			case 20: case 30: status = 400; message = @"This Subsonic server is too old for Player7."; break;
			case 40: status = 401; message = @"Wrong username or password."; break;
			case 50: status = 403; message = serverMessage.length ? serverMessage : @"Your account isn't allowed to do that."; break;
			case 70: status = 404; message = @"Not found on the Subsonic server."; break;
		}
		if (error) *error = P7ProviderError(status, message);
		return nil;
	}
	if (error) *error = P7ProviderError(502, @"The Subsonic server reported an error.");
	return nil;
}

#pragma mark - Caches

- (void)rememberSong:(NSDictionary *)song {
	NSString *songID = P7SSString(song[@"id"]);
	if (!songID) return;
	NSString *suffix = P7SSString(song[@"suffix"]);
	NSString *cover = P7SSString(song[@"coverArt"]);
	[_lock lock];
	if (suffix) _suffixes[songID] = suffix.lowercaseString;
	if (cover) _covers[[kTrackPrefix stringByAppendingString:songID]] = cover;
	[_lock unlock];
}

- (void)rememberCover:(NSString *)cover forID:(NSString *)itemID {
	if (!cover.length || !itemID.length) return;
	[_lock lock];
	_covers[itemID] = cover;
	[_lock unlock];
}

- (NSString *)cachedCoverForID:(NSString *)itemID {
	[_lock lock];
	NSString *cover = _covers[itemID];
	[_lock unlock];
	return cover;
}

- (void)forgetSongs {
	[_lock lock];
	_songs = nil;
	[_lock unlock];
}

#pragma mark - JSON shapes

- (NSString *)coverVersion:(NSString *)cover {
	return cover.length ? [P7SSMD5(cover) substringToIndex:8] : @"";
}

// Original suffix -> the format the app will get (and save the file as).
- (NSString *)playableFormatForSuffix:(NSString *)suffix {
	suffix = suffix.lowercaseString;
	if ([@[@"mp3", @"m4a", @"wav", @"aif", @"aiff"] containsObject:suffix]) return suffix;
	if ([@[@"mp4", @"aac", @"m4b"] containsObject:suffix]) return @"m4a";
	return nil;
}

- (NSDictionary *)trackFromSong:(NSDictionary *)song {
	[self rememberSong:song];
	NSString *songID = P7SSString(song[@"id"]) ?: @"";
	NSString *albumID = P7SSString(song[@"albumId"]);
	NSString *cover = P7SSString(song[@"coverArt"]);
	NSString *artist = P7SSString(song[@"displayArtist"]) ?: P7SSString(song[@"artist"]);
	return @{
		@"id": [kTrackPrefix stringByAppendingString:songID],
		@"title": P7SSString(song[@"title"]) ?: @"Unknown Title",
		@"artist": artist.length ? artist : @"Unknown Artist",
		@"album": P7SSString(song[@"album"]) ?: @"",
		@"duration": @([song[@"duration"] integerValue]),
		@"format": [self playableFormatForSuffix:P7SSString(song[@"suffix"])] ?: @"mp3",
		@"available": @YES,
		@"cached": @NO,
		@"audioRev": @"",
		@"source": @"subsonic",
		@"inLibrary": @(song[@"starred"] != nil),
		@"albumId": albumID.length ? [kAlbumPrefix stringByAppendingString:albumID] : @"",
		@"coverVersion": [self coverVersion:cover],
	};
}

- (NSArray *)tracksFromSongs:(NSArray *)songs {
	NSMutableArray *tracks = [NSMutableArray new];
	for (id song in songs) {
		if ([song isKindOfClass:[NSDictionary class]] && P7SSString(song[@"id"]) && ![song[@"isVideo"] boolValue]) {
			[tracks addObject:[self trackFromSong:song]];
		}
	}
	return tracks;
}

- (NSDictionary *)entityWithID:(NSString *)entityID kind:(NSString *)kind name:(NSString *)name subtitle:(NSString *)subtitle cover:(NSString *)cover link:(NSString *)link {
	[self rememberCover:cover forID:entityID];
	return @{
		@"id": entityID,
		@"kind": kind,
		@"name": name ?: @"",
		@"subtitle": subtitle ?: @"",
		@"source": @"subsonic",
		@"coverVersion": [self coverVersion:cover],
		@"hasCover": @(cover.length > 0),
		@"url": link ?: @"",
	};
}

- (NSDictionary *)artistEntity:(NSDictionary *)artist {
	NSString *artistID = P7SSString(artist[@"id"]) ?: @"";
	NSInteger albums = [artist[@"albumCount"] integerValue];
	NSString *subtitle = albums ? [NSString stringWithFormat:albums == 1 ? @"%ld album" : @"%ld albums", (long)albums] : @"Artist";
	return [self entityWithID:[kArtistPrefix stringByAppendingString:artistID] kind:@"artist" name:P7SSString(artist[@"name"])
	                 subtitle:subtitle cover:P7SSString(artist[@"coverArt"]) link:[kLinkPrefix stringByAppendingFormat:@"artist:%@", artistID]];
}

- (NSString *)albumLabel:(NSDictionary *)album {
	for (NSString *type in P7SSArray(album[@"releaseTypes"])) {
		NSString *lower = [P7SSString(type) lowercaseString];
		if ([lower isEqualToString:@"single"]) return @"Single";
		if ([lower isEqualToString:@"ep"]) return @"EP";
		if ([lower isEqualToString:@"compilation"]) return @"Compilation";
	}
	return [album[@"isCompilation"] boolValue] ? @"Compilation" : nil;
}

- (NSDictionary *)albumEntity:(NSDictionary *)album withArtist:(BOOL)withArtist {
	NSString *albumID = P7SSString(album[@"id"]) ?: @"";
	NSMutableArray *parts = [NSMutableArray new];
	NSString *artist = P7SSString(album[@"displayArtist"]) ?: P7SSString(album[@"artist"]);
	if (withArtist && artist.length) [parts addObject:artist];
	if ([album[@"year"] integerValue] > 0) [parts addObject:[album[@"year"] description]];
	NSString *label = [self albumLabel:album];
	if (label) [parts addObject:label];
	return [self entityWithID:[kAlbumPrefix stringByAppendingString:albumID] kind:@"album" name:P7SSString(album[@"name"]) ?: P7SSString(album[@"title"])
	                 subtitle:[parts componentsJoinedByString:@" · "] cover:P7SSString(album[@"coverArt"])
	                     link:[kLinkPrefix stringByAppendingFormat:@"album:%@", albumID]];
}

- (NSDictionary *)playlistEntity:(NSDictionary *)playlist {
	NSString *playlistID = P7SSString(playlist[@"id"]) ?: @"";
	NSMutableArray *parts = [NSMutableArray new];
	NSString *owner = P7SSString(playlist[@"owner"]);
	if (owner.length) [parts addObject:owner];
	NSInteger count = [playlist[@"songCount"] integerValue];
	if (count) [parts addObject:[NSString stringWithFormat:count == 1 ? @"%ld song" : @"%ld songs", (long)count]];
	return [self entityWithID:[kPlaylistPrefix stringByAppendingString:playlistID] kind:@"playlist" name:P7SSString(playlist[@"name"])
	                 subtitle:[parts componentsJoinedByString:@" · "] cover:P7SSString(playlist[@"coverArt"])
	                     link:[kLinkPrefix stringByAppendingFormat:@"playlist:%@", playlistID]];
}

// The Player7 playlist JSON (server/library.py public_playlist). tracks nil: a summary with the counts given.
- (NSDictionary *)playlistWithID:(NSString *)playlistID name:(NSString *)name kind:(NSString *)kind owner:(NSString *)owner
                           cover:(NSString *)cover imported:(BOOL)imported link:(NSString *)link
                          tracks:(NSArray *)tracks count:(NSInteger)count duration:(NSInteger)duration {
	[self rememberCover:cover forID:playlistID];
	NSMutableDictionary *playlist = [@{
		@"id": playlistID,
		@"name": name.length ? name : @"Untitled Playlist",
		@"source": @"subsonic",
		@"kind": kind,
		@"owner": owner ?: @"",
		@"url": link ?: @"",
		@"imported": @(imported),
	} mutableCopy];
	if (tracks) {
		count = tracks.count;
		duration = 0;
		for (NSDictionary *track in tracks) duration += [track[@"duration"] integerValue];
		playlist[@"tracks"] = tracks;
	}
	playlist[@"trackCount"] = @(count);
	playlist[@"duration"] = @(duration);
	if (cover.length) {
		playlist[@"coverTrackId"] = playlistID;
		playlist[@"coverVersion"] = [self coverVersion:cover];
	} else if ([tracks.firstObject isKindOfClass:[NSDictionary class]]) {
		playlist[@"coverTrackId"] = tracks.firstObject[@"id"];
		playlist[@"coverVersion"] = tracks.firstObject[@"coverVersion"] ?: @"";
	}
	return playlist;
}

#pragma mark - Collections

- (NSDictionary *)playlistJSON:(NSDictionary *)playlist tracks:(NSArray *)tracks {
	NSString *playlistID = P7SSString(playlist[@"id"]) ?: @"";
	return [self playlistWithID:[kPlaylistPrefix stringByAppendingString:playlistID] name:P7SSString(playlist[@"name"]) kind:@"playlist"
	                      owner:P7SSString(playlist[@"owner"]) cover:P7SSString(playlist[@"coverArt"]) imported:YES
	                       link:[kLinkPrefix stringByAppendingFormat:@"playlist:%@", playlistID] tracks:tracks
	                      count:[playlist[@"songCount"] integerValue] duration:[playlist[@"duration"] integerValue]];
}

- (NSDictionary *)albumJSON:(NSDictionary *)album tracks:(NSArray *)tracks {
	NSString *albumID = P7SSString(album[@"id"]) ?: @"";
	NSString *artist = P7SSString(album[@"displayArtist"]) ?: P7SSString(album[@"artist"]);
	return [self playlistWithID:[kAlbumPrefix stringByAppendingString:albumID] name:P7SSString(album[@"name"]) ?: P7SSString(album[@"title"]) kind:@"album"
	                      owner:artist cover:P7SSString(album[@"coverArt"]) imported:album[@"starred"] != nil
	                       link:[kLinkPrefix stringByAppendingFormat:@"album:%@", albumID] tracks:tracks
	                      count:[album[@"songCount"] integerValue] duration:[album[@"duration"] integerValue]];
}

- (NSDictionary *)fetchAlbum:(NSString *)albumID error:(NSError **)error {
	NSDictionary *root = [self call:@"getAlbum" params:@{@"id": albumID} error:error];
	return root ? P7SSDict(root[@"album"]) : nil;
}

- (NSDictionary *)fetchArtist:(NSString *)artistID error:(NSError **)error {
	NSDictionary *root = [self call:@"getArtist" params:@{@"id": artistID} error:error];
	return root ? P7SSDict(root[@"artist"]) : nil;
}

// Albums of an artist, newest first.
- (NSArray *)sortedAlbums:(NSDictionary *)artist {
	return [P7SSArray(artist[@"album"]) sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [@([P7SSDict(b)[@"year"] integerValue]) compare:@([P7SSDict(a)[@"year"] integerValue])];
	}];
}

// Songs of several albums, fetched a few at a time, in album order.
- (NSArray *)songsOfAlbums:(NSArray *)albums error:(NSError **)error {
	NSUInteger count = albums.count;
	NSMutableArray *results = [NSMutableArray arrayWithCapacity:count];
	for (NSUInteger i = 0; i < count; i++) [results addObject:[NSNull null]];
	__block NSError *firstError = nil;
	NSLock *lock = [NSLock new];
	dispatch_apply(count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
		NSError *albumError = nil;
		NSDictionary *album = [self fetchAlbum:P7SSString(P7SSDict(albums[index])[@"id"]) ?: @"" error:&albumError];
		[lock lock];
		if (album) results[index] = P7SSArray(album[@"song"]);
		else if (!firstError) firstError = albumError;
		[lock unlock];
	});
	NSMutableArray *songs = [NSMutableArray new];
	for (id list in results) if ([list isKindOfClass:[NSArray class]]) [songs addObjectsFromArray:list];
	if (!songs.count && firstError) {
		if (error) *error = firstError;
		return nil;
	}
	return songs;
}

// Artists that only appear on other people's albums (features, compilations) have no albums of
// their own; their songs are found by searching for the name.
- (NSArray *)songsCreditedTo:(NSDictionary *)artist {
	NSString *artistID = P7SSString(artist[@"id"]), *name = P7SSString(artist[@"name"]);
	if (!artistID.length || !name.length) return @[];
	NSDictionary *root = [self call:@"search3" params:@{@"query": name, @"artistCount": @0, @"albumCount": @0, @"songCount": @500} error:NULL];
	NSMutableArray *songs = [NSMutableArray new];
	for (NSDictionary *song in P7SSArray(P7SSDict(root[@"searchResult3"])[@"song"])) {
		BOOL credited = [P7SSString(P7SSDict(song)[@"artistId"]) isEqualToString:artistID];
		for (NSDictionary *ref in P7SSArray(P7SSDict(song)[@"artists"])) {
			if ([P7SSString(P7SSDict(ref)[@"id"]) isEqualToString:artistID]) credited = YES;
		}
		if (credited) [songs addObject:song];
	}
	return songs;
}

- (NSArray *)songsOfArtist:(NSDictionary *)artist error:(NSError **)error {
	NSArray *albums = [self sortedAlbums:artist];
	NSArray *songs = albums.count ? [self songsOfAlbums:albums error:error] : @[];
	if (!songs) return nil;
	return songs.count ? songs : [self songsCreditedTo:artist];
}

- (NSDictionary *)artistCollection:(NSString *)artistID error:(NSError **)error {
	NSDictionary *artist = [self fetchArtist:artistID error:error];
	if (!artist) return nil;
	NSArray *songs = [self songsOfArtist:artist error:error];
	if (!songs) return nil;
	return [self playlistWithID:[kArtistPrefix stringByAppendingString:artistID] name:P7SSString(artist[@"name"]) kind:@"artist" owner:@"Artist"
	                      cover:P7SSString(artist[@"coverArt"]) imported:artist[@"starred"] != nil
	                       link:[kLinkPrefix stringByAppendingFormat:@"artist:%@", artistID] tracks:[self tracksFromSongs:songs] count:0 duration:0];
}

// Album, playlist or all songs of an artist, with tracks.
- (NSDictionary *)collection:(NSString *)collectionID error:(NSError **)error {
	if ([collectionID hasPrefix:kPlaylistPrefix]) {
		NSDictionary *root = [self call:@"getPlaylist" params:@{@"id": [collectionID substringFromIndex:kPlaylistPrefix.length]} error:error];
		if (!root) return nil;
		NSDictionary *playlist = P7SSDict(root[@"playlist"]);
		return [self playlistJSON:playlist tracks:[self tracksFromSongs:P7SSArray(playlist[@"entry"])]];
	}
	if ([collectionID hasPrefix:kAlbumPrefix]) {
		NSDictionary *album = [self fetchAlbum:[collectionID substringFromIndex:kAlbumPrefix.length] error:error];
		return album ? [self albumJSON:album tracks:[self tracksFromSongs:P7SSArray(album[@"song"])]] : nil;
	}
	if ([collectionID hasPrefix:kArtistPrefix]) {
		return [self artistCollection:[collectionID substringFromIndex:kArtistPrefix.length] error:error];
	}
	if (error) *error = P7ProviderError(404, @"Playlist not found.");
	return nil;
}

// Playlists tab: the user's playlists plus starred albums and artists.
- (NSDictionary *)libraryPlaylists:(NSError **)error {
	NSDictionary *playlistsRoot = [self call:@"getPlaylists" params:nil error:error];
	if (!playlistsRoot) return nil;
	NSMutableArray *result = [NSMutableArray new];
	for (NSDictionary *playlist in P7SSArray(P7SSDict(playlistsRoot[@"playlists"])[@"playlist"])) {
		if ([playlist isKindOfClass:[NSDictionary class]] && P7SSString(playlist[@"id"])) [result addObject:[self playlistJSON:playlist tracks:nil]];
	}
	NSDictionary *starredRoot = [self call:@"getStarred2" params:nil error:NULL];
	NSDictionary *starred = P7SSDict(starredRoot[@"starred2"]);
	for (NSDictionary *album in P7SSArray(starred[@"album"])) {
		if ([album isKindOfClass:[NSDictionary class]] && P7SSString(album[@"id"])) [result addObject:[self albumJSON:album tracks:nil]];
	}
	// Artists only list albums; count their songs from those.
	NSArray *artists = P7SSArray(starred[@"artist"]);
	NSMutableArray *artistJSON = [NSMutableArray arrayWithCapacity:artists.count];
	for (NSUInteger i = 0; i < artists.count; i++) [artistJSON addObject:[NSNull null]];
	NSLock *lock = [NSLock new];
	dispatch_apply(artists.count, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(size_t index) {
		NSString *artistID = P7SSString(P7SSDict(artists[index])[@"id"]);
		NSDictionary *artist = artistID ? [self fetchArtist:artistID error:NULL] : nil;
		if (!artist.count) return;
		NSInteger songs = 0, duration = 0;
		NSArray *albums = P7SSArray(artist[@"album"]);
		for (NSDictionary *album in albums) {
			songs += [P7SSDict(album)[@"songCount"] integerValue];
			duration += [P7SSDict(album)[@"duration"] integerValue];
		}
		if (!albums.count) {
			for (NSDictionary *song in [self songsCreditedTo:artist]) {
				songs++;
				duration += [P7SSDict(song)[@"duration"] integerValue];
			}
		}
		NSDictionary *json = [self playlistWithID:[kArtistPrefix stringByAppendingString:artistID] name:P7SSString(artist[@"name"]) kind:@"artist"
		                                    owner:@"Artist" cover:P7SSString(artist[@"coverArt"]) imported:YES
		                                     link:[kLinkPrefix stringByAppendingFormat:@"artist:%@", artistID] tracks:nil count:songs duration:duration];
		[lock lock];
		artistJSON[index] = json;
		[lock unlock];
	});
	for (id json in artistJSON) if ([json isKindOfClass:[NSDictionary class]]) [result addObject:json];
	[result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
	}];
	return @{@"playlists": result};
}

#pragma mark - Songs

// Every song on the server (search3 with an empty query; album by album where that isn't supported).
- (NSArray *)allSongs:(NSError **)error {
	NSString *key = [NSString stringWithFormat:@"%@|%@", [self serverURL], [P7Settings shared].subsonicUsername];
	[_lock lock];
	NSArray *cached = [_songsKey isEqualToString:key] && [NSDate timeIntervalSinceReferenceDate] - _songsAt < kSongsCacheSeconds ? _songs : nil;
	[_lock unlock];
	if (cached) return cached;

	NSMutableArray *songs = [NSMutableArray new];
	while (songs.count < kMaxSongs) {
		NSDictionary *root = [self call:@"search3" params:@{@"query": @"", @"artistCount": @0, @"albumCount": @0,
		                                                    @"songCount": @(kSongPage), @"songOffset": @(songs.count)} error:error];
		if (!root) return nil;
		NSArray *page = P7SSArray(P7SSDict(root[@"searchResult3"])[@"song"]);
		[songs addObjectsFromArray:page];
		if (page.count < kSongPage) break;
	}
	if (!songs.count) {
		NSMutableArray *albums = [NSMutableArray new];
		while (albums.count < 1000) {
			NSDictionary *root = [self call:@"getAlbumList2" params:@{@"type": @"alphabeticalByName", @"size": @500, @"offset": @(albums.count)} error:error];
			if (!root) return nil;
			NSArray *page = P7SSArray(P7SSDict(root[@"albumList2"])[@"album"]);
			[albums addObjectsFromArray:page];
			if (page.count < 500) break;
		}
		NSArray *albumSongs = albums.count ? [self songsOfAlbums:albums error:error] : @[];
		if (!albumSongs) return nil;
		[songs addObjectsFromArray:albumSongs];
	}
	NSArray *tracks = [self tracksFromSongs:songs];
	if (tracks.count > kMaxSongs) tracks = [tracks subarrayWithRange:NSMakeRange(0, kMaxSongs)];
	tracks = [tracks sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"title"] localizedCaseInsensitiveCompare:b[@"title"]];
	}];
	[_lock lock];
	_songs = tracks;
	_songsKey = key;
	_songsAt = [NSDate timeIntervalSinceReferenceDate];
	[_lock unlock];
	return tracks;
}

- (NSDictionary *)songs:(NSString *)query error:(NSError **)error {
	NSArray *tracks = [self allSongs:error];
	if (!tracks) return nil;
	NSString *needle = P7SSFold([query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]);
	if (needle.length) {
		NSMutableArray *matches = [NSMutableArray new];
		for (NSDictionary *track in tracks) {
			NSString *text = P7SSFold([NSString stringWithFormat:@"%@ %@ %@", track[@"title"], track[@"artist"], track[@"album"]]);
			if ([text rangeOfString:needle].location != NSNotFound) [matches addObject:track];
		}
		tracks = matches;
	}
	return @{@"tracks": tracks};
}

- (NSDictionary *)songWithID:(NSString *)songID error:(NSError **)error {
	NSDictionary *root = [self call:@"getSong" params:@{@"id": songID} error:error];
	if (!root) return nil;
	NSDictionary *song = P7SSDict(root[@"song"]);
	[self rememberSong:song];
	return song;
}

#pragma mark - Search

- (BOOL)name:(NSString *)name matches:(NSString *)query {
	NSString *n = P7SSFold(name), *q = P7SSFold(query);
	if (!n.length || !q.length) return NO;
	return [n rangeOfString:q].location != NSNotFound || [q rangeOfString:n].location != NSNotFound;
}

- (NSDictionary *)search:(NSString *)query error:(NSError **)error {
	query = [query stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
	if (!query.length) return @{@"tracks": @[], @"artists": @[], @"albums": @[], @"playlists": @[]};
	NSDictionary *root = [self call:@"search3" params:@{@"query": query, @"artistCount": @10, @"albumCount": @6, @"songCount": @40} error:error];
	if (!root) return nil;
	NSDictionary *found = P7SSDict(root[@"searchResult3"]);
	NSMutableArray *artists = [NSMutableArray new];
	for (NSDictionary *artist in P7SSArray(found[@"artist"])) {
		if (artists.count < 3 && P7SSString(P7SSDict(artist)[@"id"]) && [self name:P7SSString(artist[@"name"]) matches:query]) {
			[artists addObject:[self artistEntity:artist]];
		}
	}
	NSMutableArray *albums = [NSMutableArray new];
	for (NSDictionary *album in P7SSArray(found[@"album"])) {
		if (albums.count < 6 && P7SSString(P7SSDict(album)[@"id"])) [albums addObject:[self albumEntity:album withArtist:YES]];
	}
	NSMutableArray *playlists = [NSMutableArray new];
	NSDictionary *playlistsRoot = [self call:@"getPlaylists" params:nil error:NULL];
	for (NSDictionary *playlist in P7SSArray(P7SSDict(playlistsRoot[@"playlists"])[@"playlist"])) {
		if (playlists.count < 6 && P7SSString(P7SSDict(playlist)[@"id"]) && [P7SSFold(P7SSString(playlist[@"name"])) rangeOfString:P7SSFold(query)].location != NSNotFound) {
			[playlists addObject:[self playlistEntity:playlist]];
		}
	}
	return @{@"tracks": [self tracksFromSongs:P7SSArray(found[@"song"])], @"artists": artists, @"albums": albums, @"playlists": playlists};
}

#pragma mark - Artists

- (NSDictionary *)artistPage:(NSString *)entityID error:(NSError **)error {
	if (![entityID hasPrefix:kArtistPrefix]) {
		if (error) *error = P7ProviderError(404, @"Unknown artist.");
		return nil;
	}
	NSString *artistID = [entityID substringFromIndex:kArtistPrefix.length];
	NSDictionary *artist = [self fetchArtist:artistID error:error];
	if (!artist) return nil;
	NSString *name = P7SSString(artist[@"name"]) ?: @"";
	NSArray *albums = [self sortedAlbums:artist];

	__block NSArray *topSongs = nil;
	__block NSArray *similar = nil;
	dispatch_group_t group = dispatch_group_create();
	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
	dispatch_group_async(group, queue, ^{
		NSDictionary *root = name.length ? [self call:@"getTopSongs" params:@{@"artist": name, @"count": @10} error:NULL] : nil;
		topSongs = P7SSArray(P7SSDict(root[@"topSongs"])[@"song"]);
	});
	dispatch_group_async(group, queue, ^{
		NSDictionary *root = [self call:@"getArtistInfo2" params:@{@"id": artistID, @"count": @8} error:NULL];
		similar = P7SSArray(P7SSDict(root[@"artistInfo2"])[@"similarArtist"]);
	});
	dispatch_group_wait(group, DISPATCH_TIME_FOREVER);

	if (!topSongs.count) {
		// No play statistics on this server: the newest songs instead.
		NSArray *songs = albums.count ? [self songsOfAlbums:[albums subarrayWithRange:NSMakeRange(0, MIN(2, albums.count))] error:NULL] : [self songsCreditedTo:artist];
		topSongs = songs.count > 10 ? [songs subarrayWithRange:NSMakeRange(0, 10)] : songs;
	}

	NSMutableArray *sections = [NSMutableArray new];
	NSArray *tracks = [self tracksFromSongs:topSongs ?: @[]];
	if (tracks.count) {
		NSDictionary *more = [self entityWithID:entityID kind:@"playlist" name:[NSString stringWithFormat:@"%@ – All Songs", name] subtitle:@""
		                                 cover:P7SSString(artist[@"coverArt"]) link:[kLinkPrefix stringByAppendingFormat:@"artist:%@", artistID]];
		[sections addObject:@{@"title": @"Top Songs", @"type": @"tracks", @"tracks": tracks, @"more": more}];
	}
	NSMutableArray *full = [NSMutableArray new], *singles = [NSMutableArray new];
	for (NSDictionary *album in albums) {
		if (!P7SSString(P7SSDict(album)[@"id"])) continue;
		NSString *label = [self albumLabel:album];
		BOOL single = [label isEqualToString:@"Single"] || [label isEqualToString:@"EP"];
		[(single ? singles : full) addObject:[self albumEntity:album withArtist:NO]];
	}
	if (full.count) [sections addObject:@{@"title": @"Albums", @"type": @"entities", @"items": full}];
	if (singles.count) [sections addObject:@{@"title": @"Singles & EPs", @"type": @"entities", @"items": singles}];
	NSMutableArray *related = [NSMutableArray new];
	for (NSDictionary *other in similar) {
		if (P7SSString(P7SSDict(other)[@"id"])) [related addObject:[self artistEntity:other]];
	}
	if (related.count) [sections addObject:@{@"title": @"Similar Artists", @"type": @"entities", @"items": related}];

	NSMutableDictionary *page = [[self artistEntity:artist] mutableCopy];
	if ([page[@"hasCover"] boolValue]) page[@"bannerKey"] = entityID;
	page[@"imported"] = @(artist[@"starred"] != nil);
	page[@"sections"] = sections;
	return page;
}

- (NSArray *)artistsOfTrack:(NSString *)trackID error:(NSError **)error {
	if (![trackID hasPrefix:kTrackPrefix]) {
		if (error) *error = P7ProviderError(404, @"Unknown song.");
		return nil;
	}
	NSDictionary *song = [self songWithID:[trackID substringFromIndex:kTrackPrefix.length] error:error];
	if (!song) return nil;
	NSMutableArray *refs = [NSMutableArray new];
	[refs addObjectsFromArray:P7SSArray(song[@"artists"])];
	if (!refs.count && P7SSString(song[@"artistId"])) [refs addObject:@{@"id": song[@"artistId"], @"name": P7SSString(song[@"artist"]) ?: @""}];
	[refs addObjectsFromArray:P7SSArray(song[@"albumArtists"])];
	if (!P7SSArray(song[@"albumArtists"]).count && P7SSString(song[@"albumId"])) {
		NSDictionary *album = [self fetchAlbum:song[@"albumId"] error:NULL];
		if (P7SSString(album[@"artistId"])) [refs addObject:@{@"id": album[@"artistId"], @"name": P7SSString(album[@"artist"]) ?: @""}];
	}
	NSMutableArray *artists = [NSMutableArray new];
	NSMutableSet *seen = [NSMutableSet new];
	for (NSDictionary *ref in refs) {
		NSString *artistID = P7SSString(P7SSDict(ref)[@"id"]);
		if (!artistID.length || [seen containsObject:artistID]) continue;
		[seen addObject:artistID];
		NSMutableDictionary *entity = [[self entityWithID:[kArtistPrefix stringByAppendingString:artistID] kind:@"artist" name:P7SSString(ref[@"name"])
		                                          subtitle:@"Artist" cover:P7SSString(ref[@"coverArt"]) link:[kLinkPrefix stringByAppendingFormat:@"artist:%@", artistID]] mutableCopy];
		entity[@"hasCover"] = @YES;   // the picture is looked up from the artist when asked for
		[artists addObject:entity];
	}
	if (!artists.count) {
		if (error) *error = P7ProviderError(404, @"This song has no artist on the server.");
		return nil;
	}
	return artists;
}

#pragma mark - Library

- (BOOL)setStarred:(BOOL)starred key:(NSString *)key value:(NSString *)value error:(NSError **)error {
	BOOL ok = [self call:starred ? @"star" : @"unstar" params:@{key: value} error:error] != nil;
	if (ok && [key isEqualToString:@"id"]) [self forgetSongs];
	return ok;
}

- (NSDictionary *)importLink:(NSString *)link error:(NSError **)error {
	NSArray *parts = [link hasPrefix:kLinkPrefix] ? [[link substringFromIndex:kLinkPrefix.length] componentsSeparatedByString:@":"] : nil;
	NSString *kind = parts.count == 2 ? parts[0] : nil;
	NSString *itemID = parts.count == 2 ? parts[1] : nil;
	if ([kind isEqualToString:@"song"] && itemID.length) {
		if (![self setStarred:YES key:@"id" value:itemID error:error]) return nil;
		return @{@"playlist": [NSNull null], @"imported": @1, @"background": @NO};
	}
	if ([kind isEqualToString:@"album"] && itemID.length) {
		if (![self setStarred:YES key:@"albumId" value:itemID error:error]) return nil;
		NSDictionary *playlist = [self collection:[kAlbumPrefix stringByAppendingString:itemID] error:error];
		return playlist ? @{@"playlist": playlist, @"imported": @1, @"background": @NO} : nil;
	}
	if ([kind isEqualToString:@"artist"] && itemID.length) {
		if (![self setStarred:YES key:@"artistId" value:itemID error:error]) return nil;
		NSDictionary *playlist = [self collection:[kArtistPrefix stringByAppendingString:itemID] error:error];
		return playlist ? @{@"playlist": playlist, @"imported": @1, @"background": @NO} : nil;
	}
	if ([kind isEqualToString:@"playlist"] && itemID.length) {
		// Playlists the account can see are already in the library.
		NSDictionary *playlist = [self collection:[kPlaylistPrefix stringByAppendingString:itemID] error:error];
		return playlist ? @{@"playlist": playlist, @"imported": @1, @"background": @NO} : nil;
	}
	if (error) *error = P7ProviderError(400, @"Import links aren't available with a Subsonic server. Search for the music instead.");
	return nil;
}

- (BOOL)removeFromLibrary:(NSString *)collectionID error:(NSError **)error {
	if ([collectionID hasPrefix:kPlaylistPrefix]) {
		return [self call:@"deletePlaylist" params:@{@"id": [collectionID substringFromIndex:kPlaylistPrefix.length]} error:error] != nil;
	}
	if ([collectionID hasPrefix:kAlbumPrefix]) {
		return [self setStarred:NO key:@"albumId" value:[collectionID substringFromIndex:kAlbumPrefix.length] error:error];
	}
	if ([collectionID hasPrefix:kArtistPrefix]) {
		return [self setStarred:NO key:@"artistId" value:[collectionID substringFromIndex:kArtistPrefix.length] error:error];
	}
	if (error) *error = P7ProviderError(404, @"Playlist not found.");
	return NO;
}

#pragma mark - P7Provider

- (id)responseForMethod:(NSString *)method parts:(NSArray *)parts query:(NSDictionary *)query body:(NSDictionary *)body error:(NSError **)error {
	NSUInteger count = parts.count;
	NSString *first = count ? parts[0] : @"";
	if (![method isEqualToString:@"POST"]) {
		if (count == 1 && [first isEqualToString:@"ping"]) {
			if (![self call:@"ping" params:nil error:error]) return nil;
			return @{@"ok": @YES, @"searchSources": @[@"subsonic"]};
		}
		if (count == 1 && [first isEqualToString:@"playlists"]) return [self libraryPlaylists:error];
		if (count == 2 && [first isEqualToString:@"playlists"]) {
			NSDictionary *playlist = [self collection:parts[1] error:error];
			return playlist ? @{@"playlist": playlist} : nil;
		}
		if (count == 1 && [first isEqualToString:@"tracks"]) return [self songs:P7SSString(query[@"q"]) error:error];
		if (count == 3 && [first isEqualToString:@"tracks"] && [parts[2] isEqualToString:@"artists"]) {
			NSArray *artists = [self artistsOfTrack:parts[1] error:error];
			return artists ? @{@"artists": artists} : nil;
		}
		if (count == 2 && [first isEqualToString:@"artists"]) {
			NSDictionary *artist = [self artistPage:parts[1] error:error];
			return artist ? @{@"artist": artist} : nil;
		}
		if (count == 2 && [first isEqualToString:@"collections"]) {
			NSDictionary *playlist = [self collection:parts[1] error:error];
			return playlist ? @{@"playlist": playlist} : nil;
		}
		if (count == 1 && [first isEqualToString:@"search"]) return [self search:P7SSString(query[@"q"]) error:error];
		if (count == 2 && [first isEqualToString:@"import"] && [parts[1] isEqualToString:@"status"]) {
			return @{@"running": @NO, @"message": @"", @"done": @0, @"total": @0};
		}
	} else {
		if (count == 1 && [first isEqualToString:@"import"]) return [self importLink:P7SSString(body[@"url"]) ?: @"" error:error];
		if (count == 3 && [first isEqualToString:@"playlists"] && [parts[2] isEqualToString:@"sync"]) {
			NSDictionary *playlist = [self collection:parts[1] error:error];
			return playlist ? @{@"playlist": playlist} : nil;
		}
		if (count == 3 && [first isEqualToString:@"playlists"] && [parts[2] isEqualToString:@"delete"]) {
			return [self removeFromLibrary:parts[1] error:error] ? @{@"ok": @YES} : nil;
		}
		if (count == 1 && [first isEqualToString:@"library"]) {
			NSString *trackID = P7SSString(body[@"trackId"]) ?: @"";
			if (![trackID hasPrefix:kTrackPrefix]) {
				if (error) *error = P7ProviderError(400, @"Unknown track.");
				return nil;
			}
			BOOL remove = [body[@"remove"] boolValue];
			return [self setStarred:!remove key:@"id" value:[trackID substringFromIndex:kTrackPrefix.length] error:error] ? @{@"ok": @YES} : nil;
		}
		if (count == 1 && [first isEqualToString:@"prefetch"]) return @{@"ok": @YES};
	}
	if (error) *error = P7ProviderError(404, @"Subsonic servers can't do this.");
	return nil;
}

- (NSURL *)audioURLForTrackID:(NSString *)trackID headers:(NSDictionary **)headers error:(NSError **)error {
	if (headers) *headers = nil;
	if (![trackID hasPrefix:kTrackPrefix] || [trackID hasPrefix:kAlbumPrefix] || [trackID hasPrefix:kArtistPrefix] || [trackID hasPrefix:kPlaylistPrefix]) {
		if (error) *error = P7ProviderError(404, @"Unknown track.");
		return nil;
	}
	NSString *songID = [trackID substringFromIndex:kTrackPrefix.length];
	[_lock lock];
	NSString *suffix = _suffixes[songID];
	[_lock unlock];
	if (!suffix) {
		NSDictionary *song = [self songWithID:songID error:error];
		if (!song) return nil;
		suffix = [P7SSString(song[@"suffix"]) lowercaseString] ?: @"";
	}
	NSDictionary *params = [self playableFormatForSuffix:suffix]
		? @{@"id": songID, @"format": @"raw"}
		// FLAC, Ogg, Opus, ... : iOS 7 can't play them, so the server converts to MP3.
		: @{@"id": songID, @"format": @"mp3", @"maxBitRate": @320, @"estimateContentLength": @"true"};
	NSURL *url = [self URLForMethod:@"stream" params:params];
	if (!url && error) *error = P7ProviderError(400, @"Set your Subsonic server address in Settings.");
	return url;
}

- (NSURL *)imageURLForID:(NSString *)itemID size:(NSInteger)size error:(NSError **)error {
	if ([itemID hasSuffix:@"-banner"]) itemID = [itemID substringToIndex:itemID.length - 7];
	NSString *cover = [self cachedCoverForID:itemID];
	if (!cover) {
		NSDictionary *item = nil;
		if ([itemID hasPrefix:kAlbumPrefix]) {
			item = [self fetchAlbum:[itemID substringFromIndex:kAlbumPrefix.length] error:error];
		} else if ([itemID hasPrefix:kArtistPrefix]) {
			item = [self fetchArtist:[itemID substringFromIndex:kArtistPrefix.length] error:error];
		} else if ([itemID hasPrefix:kPlaylistPrefix]) {
			NSDictionary *root = [self call:@"getPlaylist" params:@{@"id": [itemID substringFromIndex:kPlaylistPrefix.length]} error:error];
			item = P7SSDict(root[@"playlist"]);
		} else if ([itemID hasPrefix:kTrackPrefix]) {
			item = [self songWithID:[itemID substringFromIndex:kTrackPrefix.length] error:error];
		}
		if (!item) {
			if (error && !*error) *error = P7ProviderError(404, @"No cover.");
			return nil;
		}
		cover = P7SSString(item[@"coverArt"]);
		[self rememberCover:cover forID:itemID];
	}
	if (!cover.length) {
		if (error) *error = P7ProviderError(404, @"No cover.");
		return nil;
	}
	NSURL *url = [self URLForMethod:@"getCoverArt" params:@{@"id": cover, @"size": @(MAX(60, MIN(1200, size)))}];
	if (!url && error) *error = P7ProviderError(400, @"Set your Subsonic server address in Settings.");
	return url;
}

@end
