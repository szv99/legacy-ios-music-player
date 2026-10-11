#import "P7LocalLibrary.h"
#import <CommonCrypto/CommonDigest.h>

static const NSUInteger kMaxLooseTracks = 3000;   // search results etc. that aren't in the library

NSString *P7ShortHash(NSString *string) {
	NSData *data = [string ?: @"" dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_MD5_DIGEST_LENGTH];
	CC_MD5(data.bytes, (CC_LONG)data.length, digest);
	return [NSString stringWithFormat:@"%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3]];
}

static BOOL P7IsEmpty(id value) {
	return !value || value == [NSNull null] || ([value isKindOfClass:[NSString class]] && ![value length]);
}

@implementation P7LocalLibrary {
	NSString *_directory;
	NSMutableDictionary *_tracks;      // id -> track
	NSMutableDictionary *_playlists;   // id -> playlist
	NSMutableArray *_added;            // track ids in "Songs"
	NSMutableDictionary *_images;      // entity id -> picture URL
	dispatch_queue_t _saveQueue;
	BOOL _saveScheduled;
}

+ (instancetype)shared {
	static P7LocalLibrary *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
		_directory = [support stringByAppendingPathComponent:@"Player7/Library"];
		[[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
		_tracks = [[self load:@"tracks.json"] mutableCopy] ?: [NSMutableDictionary new];
		_playlists = [[self load:@"playlists.json"] mutableCopy] ?: [NSMutableDictionary new];
		_added = [[self load:@"library.json"][@"added"] mutableCopy] ?: [NSMutableArray new];
		_images = [[self load:@"images.json"] mutableCopy] ?: [NSMutableDictionary new];
		_saveQueue = dispatch_queue_create("com.szv.player7.library", DISPATCH_QUEUE_SERIAL);
	}
	return self;
}

#pragma mark - Files

- (id)load:(NSString *)name {
	NSData *data = [NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:name]];
	id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : nil;
	return [json isKindOfClass:[NSDictionary class]] ? json : nil;
}

// Changes come in bursts (a search stores 30 songs); write once, a moment later.
- (void)scheduleSave {
	if (_saveScheduled) return;
	_saveScheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), _saveQueue, ^{
		NSDictionary *files;
		@synchronized (self) {
			self->_saveScheduled = NO;
			files = @{
				@"tracks.json": [self keptTracks],
				@"playlists.json": [self->_playlists copy],
				@"library.json": @{@"added": [self->_added copy]},
				@"images.json": [self->_images copy],
			};
		}
		[files enumerateKeysAndObjectsUsingBlock:^(NSString *name, id object, BOOL *stop) {
			NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
			[data writeToFile:[self->_directory stringByAppendingPathComponent:name] atomically:YES];
		}];
	});
}

// Only songs the library refers to are written to disk; the rest live until the app quits.
- (NSDictionary *)keptTracks {
	NSMutableDictionary *kept = [NSMutableDictionary new];
	for (NSString *trackID in [self libraryIDs]) {
		if (_tracks[trackID]) kept[trackID] = _tracks[trackID];
	}
	if (_tracks.count > kMaxLooseTracks + kept.count) {
		[_tracks removeAllObjects];
		[_tracks addEntriesFromDictionary:kept];
	}
	return kept;
}

#pragma mark - Tracks

- (NSDictionary *)trackForID:(NSString *)trackID {
	@synchronized (self) {
		return trackID ? [_tracks[trackID] copy] : nil;
	}
}

- (BOOL)knowsID:(NSString *)itemID {
	@synchronized (self) {
		return itemID && (_tracks[itemID] || _playlists[itemID] || _images[itemID]);
	}
}

- (void)upsertTracks:(NSArray *)tracks {
	@synchronized (self) {
		for (NSDictionary *track in tracks) {
			if (![track isKindOfClass:[NSDictionary class]] || P7IsEmpty(track[@"id"])) continue;
			NSMutableDictionary *merged = [_tracks[track[@"id"]] mutableCopy] ?: [NSMutableDictionary new];
			[track enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
				if (!P7IsEmpty(value)) merged[key] = value;
			}];
			_tracks[track[@"id"]] = merged;
		}
		[self scheduleSave];
	}
}

#pragma mark - Playlists

- (NSArray *)playlists {
	@synchronized (self) {
		return [_playlists.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
			return [a[@"name"] ?: @"" localizedCaseInsensitiveCompare:b[@"name"] ?: @""];
		}];
	}
}

- (NSDictionary *)playlistForID:(NSString *)playlistID {
	@synchronized (self) {
		return playlistID ? [_playlists[playlistID] copy] : nil;
	}
}

- (NSDictionary *)savePlaylist:(NSDictionary *)playlist tracks:(NSArray *)tracks {
	@synchronized (self) {
		[self upsertTracks:tracks];
		NSMutableDictionary *stored = [playlist mutableCopy];
		stored[@"trackIds"] = [tracks valueForKey:@"id"] ?: @[];
		stored[@"importedAt"] = @((long long)[[NSDate date] timeIntervalSince1970]);
		[stored removeObjectForKey:@"image"];
		if (!P7IsEmpty(playlist[@"image"])) [self setImage:playlist[@"image"] forID:playlist[@"id"] replace:YES];
		_playlists[stored[@"id"]] = stored;
		[self scheduleSave];
		return [stored copy];
	}
}

- (void)deletePlaylistID:(NSString *)playlistID {
	@synchronized (self) {
		if (!playlistID) return;
		[_playlists removeObjectForKey:playlistID];
		[self scheduleSave];
	}
}

- (NSArray *)tracksOfPlaylist:(NSDictionary *)playlist {
	@synchronized (self) {
		NSMutableArray *tracks = [NSMutableArray new];
		for (NSString *trackID in playlist[@"trackIds"]) {
			if (_tracks[trackID]) [tracks addObject:_tracks[trackID]];
		}
		return tracks;
	}
}

#pragma mark - Songs

- (BOOL)isAdded:(NSString *)trackID {
	@synchronized (self) {
		return trackID && [_added containsObject:trackID];
	}
}

- (void)setTrackID:(NSString *)trackID added:(BOOL)added {
	@synchronized (self) {
		if (!trackID) return;
		[_added removeObject:trackID];
		if (added) [_added addObject:trackID];
		[self scheduleSave];
	}
}

- (NSArray *)libraryIDs {
	NSMutableOrderedSet *ids = [NSMutableOrderedSet orderedSetWithArray:_added];
	for (NSDictionary *playlist in _playlists.allValues) [ids addObjectsFromArray:playlist[@"trackIds"] ?: @[]];
	return ids.array;
}

- (NSArray *)libraryTracks {
	@synchronized (self) {
		NSMutableArray *tracks = [NSMutableArray new];
		for (NSString *trackID in [self libraryIDs]) {
			if (_tracks[trackID]) [tracks addObject:_tracks[trackID]];
		}
		return tracks;
	}
}

#pragma mark - Pictures

- (NSString *)imageForID:(NSString *)entityID {
	@synchronized (self) {
		return entityID ? _images[entityID] : nil;
	}
}

- (void)setImage:(NSString *)url forID:(NSString *)entityID replace:(BOOL)replace {
	if (P7IsEmpty(url) || P7IsEmpty(entityID)) return;
	@synchronized (self) {
		if ((!replace && _images[entityID]) || [_images[entityID] isEqualToString:url]) return;
		_images[entityID] = url;
		[self scheduleSave];
	}
}

#pragma mark - Public JSON

- (NSString *)albumEntityID:(NSDictionary *)track {
	NSString *albumID = track[@"albumId"];
	if (P7IsEmpty(albumID)) return @"";
	return [albumID hasPrefix:@"yt-al-"] ? albumID : [@"yt-al-" stringByAppendingString:albumID];
}

- (NSDictionary *)publicTrack:(NSDictionary *)track {
	NSString *trackID = track[@"id"];
	return @{
		@"id": trackID ?: @"",
		@"title": P7IsEmpty(track[@"title"]) ? @"Unknown Title" : track[@"title"],
		@"artist": P7IsEmpty(track[@"artist"]) ? @"Unknown Artist" : track[@"artist"],
		@"album": P7IsEmpty(track[@"album"]) ? @"" : track[@"album"],
		@"duration": @([track[@"duration"] integerValue]),
		@"format": @"m4a",
		@"available": @YES,
		@"cached": @NO,
		@"audioRev": @"",
		@"source": P7IsEmpty(track[@"source"]) ? @"youtube" : track[@"source"],
		@"inLibrary": @([self isAdded:trackID]),
		@"albumId": [self albumEntityID:track],
		@"coverVersion": P7ShortHash(P7IsEmpty(track[@"coverUrl"]) ? @"" : track[@"coverUrl"]),
		@"artworkUrl": [track[@"coverUrl"] isKindOfClass:[NSString class]] && [track[@"coverUrl"] hasPrefix:@"https://"] ? track[@"coverUrl"] : @"",
	};
}

- (NSArray *)publicTracks:(NSArray *)tracks {
	NSMutableArray *result = [NSMutableArray new];
	for (NSDictionary *track in tracks) [result addObject:[self publicTrack:track]];
	return result;
}

- (NSDictionary *)publicPlaylist:(NSDictionary *)playlist withTracks:(BOOL)withTracks tracks:(NSArray *)tracks {
	NSString *playlistID = playlist[@"id"] ?: @"";
	if (!tracks) tracks = [self tracksOfPlaylist:playlist];
	if (!P7IsEmpty(playlist[@"image"])) [self setImage:playlist[@"image"] forID:playlistID replace:NO];
	NSString *image = [self imageForID:playlistID];
	NSDictionary *first = tracks.firstObject;
	NSString *coverID = image ? playlistID : first[@"id"];
	NSString *coverURL = image ?: (P7IsEmpty(first[@"coverUrl"]) ? @"" : first[@"coverUrl"]);
	NSInteger duration = 0;
	for (NSDictionary *track in tracks) duration += [track[@"duration"] integerValue];

	NSMutableDictionary *result = [@{
		@"id": playlistID,
		@"name": P7IsEmpty(playlist[@"name"]) ? @"Untitled Playlist" : playlist[@"name"],
		@"source": playlist[@"source"] ?: @"youtube",
		@"kind": playlist[@"kind"] ?: @"playlist",
		@"owner": playlist[@"owner"] ?: @"",
		@"trackCount": @(tracks.count),
		@"duration": @(duration),
		@"coverVersion": coverID ? P7ShortHash(coverURL) : @"",
		@"url": playlist[@"url"] ?: @"",
		@"imported": @([self playlistForID:playlistID] != nil),
	} mutableCopy];
	if (coverID) result[@"coverTrackId"] = coverID;
	if (withTracks) result[@"tracks"] = [self publicTracks:tracks];
	return result;
}

- (NSDictionary *)publicEntity:(NSDictionary *)entity {
	NSString *entityID = entity[@"id"] ?: @"";
	[self setImage:entity[@"image"] forID:entityID replace:YES];
	NSString *image = [self imageForID:entityID];
	return @{
		@"id": entityID,
		@"kind": entity[@"kind"] ?: @"playlist",
		@"name": entity[@"name"] ?: @"",
		@"subtitle": entity[@"subtitle"] ?: @"",
		@"source": entity[@"source"] ?: @"youtube",
		@"coverVersion": image ? P7ShortHash(image) : @"",
		@"hasCover": @(image != nil),
		@"url": entity[@"url"] ?: @"",
	};
}

@end
