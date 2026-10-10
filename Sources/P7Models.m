#import "P7Models.h"

@implementation P7Item

+ (instancetype)itemWithDictionary:(NSDictionary *)dictionary {
	if (![dictionary isKindOfClass:[NSDictionary class]]) return nil;
	return [[self alloc] initWithDictionary:dictionary];
}

+ (NSArray *)itemsWithArray:(id)array {
	if (![array isKindOfClass:[NSArray class]]) return @[];
	NSMutableArray *items = [NSMutableArray arrayWithCapacity:[array count]];
	for (id object in array) {
		id item = [self itemWithDictionary:object];
		if (item) [items addObject:item];
	}
	return items;
}

- (instancetype)initWithDictionary:(NSDictionary *)dictionary {
	if ((self = [super init])) {
		_raw = [dictionary copy];
	}
	return self;
}

- (NSString *)stringForKey:(NSString *)key {
	id value = _raw[key];
	if ([value isKindOfClass:[NSString class]]) return value;
	if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
	return nil;
}

- (NSInteger)integerForKey:(NSString *)key {
	id value = _raw[key];
	if ([value respondsToSelector:@selector(integerValue)]) return [value integerValue];
	return 0;
}

- (BOOL)isEqual:(id)object {
	if (![object isKindOfClass:[self class]]) return NO;
	return [[self stringForKey:@"id"] isEqualToString:[object stringForKey:@"id"]];
}

- (NSUInteger)hash {
	return [[self stringForKey:@"id"] hash];
}

@end

@implementation P7Track

- (NSString *)trackID { return [self stringForKey:@"id"]; }
- (NSString *)title { return [self stringForKey:@"title"] ?: @"Unknown Title"; }
- (NSString *)artist { return [self stringForKey:@"artist"] ?: @"Unknown Artist"; }
- (NSString *)album { return [self stringForKey:@"album"]; }
- (NSString *)format { return [self stringForKey:@"format"] ?: @"mp3"; }
- (NSInteger)duration { return [self integerForKey:@"duration"]; }
- (long long)size { return [self.raw[@"size"] respondsToSelector:@selector(longLongValue)] ? [self.raw[@"size"] longLongValue] : 0; }
- (BOOL)available { return self.raw[@"available"] ? [self.raw[@"available"] boolValue] : YES; }
- (NSString *)source { return [self stringForKey:@"source"] ?: @"local"; }
- (BOOL)cached { return [self.raw[@"cached"] boolValue]; }
- (BOOL)inLibrary { return [self.raw[@"inLibrary"] boolValue]; }
- (NSString *)coverKey { return P7CoverKey(self.trackID, [self stringForKey:@"coverVersion"]); }
- (NSString *)albumID { return [self stringForKey:@"albumId"].length ? [self stringForKey:@"albumId"] : nil; }

@end

@implementation P7Playlist {
	NSArray *_tracks;
}

- (NSString *)playlistID { return [self stringForKey:@"id"]; }
- (NSString *)name { return [self stringForKey:@"name"] ?: @"Untitled Playlist"; }
- (NSString *)source { return [self stringForKey:@"source"] ?: @"local"; }
- (NSInteger)trackCount { return self.raw[@"trackCount"] ? [self integerForKey:@"trackCount"] : (NSInteger)self.tracks.count; }
- (NSInteger)duration { return [self integerForKey:@"duration"]; }
- (NSString *)coverTrackID { return [self stringForKey:@"coverTrackId"] ?: [self.tracks.firstObject trackID]; }
- (NSString *)owner { return [self stringForKey:@"owner"]; }
- (BOOL)canSync { return [self stringForKey:@"url"].length > 0; }
- (NSString *)kind { return [self stringForKey:@"kind"] ?: @"playlist"; }
- (NSString *)url { return [self stringForKey:@"url"]; }
- (BOOL)imported { return self.raw[@"imported"] ? [self.raw[@"imported"] boolValue] : YES; }
- (NSString *)coverKey {
	NSString *trackID = [self stringForKey:@"coverTrackId"];
	if (trackID) return P7CoverKey(trackID, [self stringForKey:@"coverVersion"]);
	return [self.tracks.firstObject coverKey];
}

- (NSArray *)tracks {
	if (!_tracks) _tracks = [P7Track itemsWithArray:self.raw[@"tracks"]];
	return _tracks;
}

@end

@implementation P7Entity

+ (instancetype)entityWithID:(NSString *)entityID name:(NSString *)name kind:(NSString *)kind {
	return [self itemWithDictionary:@{@"id": entityID ?: @"", @"name": name ?: @"", @"kind": kind ?: @"artist"}];
}

- (NSString *)entityID { return [self stringForKey:@"id"]; }
- (NSString *)kind { return [self stringForKey:@"kind"] ?: @"playlist"; }
- (NSString *)name { return [self stringForKey:@"name"] ?: @""; }
- (NSString *)subtitle { return [self stringForKey:@"subtitle"]; }
- (NSString *)source { return [self stringForKey:@"source"]; }
- (NSString *)url { return [self stringForKey:@"url"]; }
- (BOOL)isArtist { return [self.kind isEqualToString:@"artist"]; }
- (NSString *)coverKey {
	if (self.raw[@"hasCover"] && ![self.raw[@"hasCover"] boolValue]) return nil;
	return P7CoverKey(self.entityID, [self stringForKey:@"coverVersion"]);
}

@end

@implementation P7Section {
	NSArray *_tracks;
	NSArray *_items;
}

- (NSString *)title { return [self stringForKey:@"title"]; }
- (NSArray *)tracks {
	if (!_tracks) _tracks = [P7Track itemsWithArray:self.raw[@"tracks"]];
	return _tracks;
}
- (NSArray *)items {
	if (!_items) _items = [P7Entity itemsWithArray:self.raw[@"items"]];
	return _items;
}
- (P7Entity *)more { return [P7Entity itemWithDictionary:self.raw[@"more"]]; }

@end

@implementation P7Artist {
	NSArray *_sections;
}

- (NSString *)bannerKey { return [self stringForKey:@"bannerKey"]; }
- (BOOL)imported { return [self.raw[@"imported"] boolValue]; }
- (NSArray *)sections {
	if (!_sections) _sections = [P7Section itemsWithArray:self.raw[@"sections"]];
	return _sections;
}

@end

NSString *P7CoverKey(NSString *trackID, NSString *version) {
	if (!trackID.length) return nil;
	return version.length ? [NSString stringWithFormat:@"%@|%@", trackID, version] : trackID;
}

NSString *P7FormatDuration(NSInteger seconds) {
	if (seconds < 0) seconds = 0;
	if (seconds >= 3600) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(seconds / 3600), (long)(seconds / 60 % 60), (long)(seconds % 60)];
	return [NSString stringWithFormat:@"%ld:%02ld", (long)(seconds / 60), (long)(seconds % 60)];
}

NSString *P7FormatLongDuration(NSInteger seconds) {
	NSInteger minutes = (seconds + 30) / 60;
	if (minutes < 60) return [NSString stringWithFormat:@"%ld min", (long)minutes];
	return [NSString stringWithFormat:@"%ld hr %ld min", (long)(minutes / 60), (long)(minutes % 60)];
}

NSString *P7TrackCountString(NSInteger count) {
	return [NSString stringWithFormat:count == 1 ? @"%ld song" : @"%ld songs", (long)count];
}
