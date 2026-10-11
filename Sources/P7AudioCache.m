#import "P7AudioCache.h"
#import "P7API.h"
#import "P7Downloads.h"

NSString *const P7AudioCacheDidChangeNotification = @"P7AudioCacheDidChangeNotification";

static NSString *const kLimitKey = @"P7AudioCacheLimitBytes";
static const NSUInteger kMaxConcurrent = 2;

@implementation P7AudioCache {
	NSString *_directory;
	NSMutableDictionary *_index;     // trackID -> {file, size, lastPlayed}
	NSMutableDictionary *_active;    // trackID -> NSURLSessionDownloadTask
	NSMutableArray *_waiting;        // P7Track queued behind kMaxConcurrent
	NSURLSession *_session;
	NSString *_protectedTrackID;     // the song playing now is never evicted
}

+ (instancetype)shared {
	static P7AudioCache *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
		_directory = [caches stringByAppendingPathComponent:@"SongCache"];
		[[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
		_index = [NSMutableDictionary dictionaryWithContentsOfFile:[self indexPath]] ?: [NSMutableDictionary new];
		_active = [NSMutableDictionary new];
		_waiting = [NSMutableArray new];
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.timeoutIntervalForRequest = 60;
		configuration.HTTPMaximumConnectionsPerHost = kMaxConcurrent;
		_session = [NSURLSession sessionWithConfiguration:configuration delegate:nil delegateQueue:[NSOperationQueue mainQueue]];
		[self dropMissingFiles];
	}
	return self;
}

#pragma mark - Index

- (NSString *)indexPath { return [_directory stringByAppendingPathComponent:@"index.plist"]; }

- (void)saveIndex {
	[_index writeToFile:[self indexPath] atomically:YES];
}

- (NSString *)pathForFile:(NSString *)file {
	return [_directory stringByAppendingPathComponent:file];
}

// iOS may purge Caches when storage runs low; forget entries whose files are gone.
- (void)dropMissingFiles {
	NSFileManager *fm = [NSFileManager defaultManager];
	for (NSString *trackID in _index.allKeys) {
		if (![fm fileExistsAtPath:[self pathForFile:_index[trackID][@"file"]]]) [_index removeObjectForKey:trackID];
	}
	[self saveIndex];
}

- (unsigned long long)limitBytes {
	unsigned long long limit = [[[NSUserDefaults standardUserDefaults] objectForKey:kLimitKey] unsignedLongLongValue];
	// Older versions offered sizes in binary megabytes, which Settings showed as "1.07 GB".
	if (limit % (1024 * 1024) == 0) limit = limit / (1024 * 1024) * 1000 * 1000;
	return limit ?: 1000ull * 1000 * 1000;
}

- (void)setLimitBytes:(unsigned long long)limitBytes {
	[[NSUserDefaults standardUserDefaults] setObject:@(limitBytes) forKey:kLimitKey];
	[self evictToFit:0];
}

#pragma mark - Queries

- (BOOL)isCached:(NSString *)trackID {
	return trackID && _index[trackID] != nil;
}

- (NSURL *)fileURLForTrackID:(NSString *)trackID {
	NSDictionary *entry = trackID ? _index[trackID] : nil;
	if (!entry) return nil;
	NSString *path = [self pathForFile:entry[@"file"]];
	if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
		[_index removeObjectForKey:trackID];
		return nil;
	}
	return [NSURL fileURLWithPath:path];
}

- (unsigned long long)totalBytes {
	unsigned long long total = 0;
	for (NSDictionary *entry in _index.allValues) total += [entry[@"size"] unsignedLongLongValue];
	return total;
}

- (NSUInteger)count {
	return _index.count;
}

- (void)markPlayed:(NSString *)trackID {
	_protectedTrackID = trackID;
	NSMutableDictionary *entry = [_index[trackID] mutableCopy];
	if (!entry) return;
	entry[@"lastPlayed"] = [NSDate date];
	_index[trackID] = entry;
	[self saveIndex];
}

#pragma mark - Downloading

- (void)cacheTrack:(P7Track *)track {
	NSString *trackID = track.trackID;
	if (!trackID || _index[trackID] || _active[trackID]) return;
	if ([[P7Downloads shared] isDownloaded:trackID]) return;
	for (P7Track *queued in _waiting) if ([queued.trackID isEqualToString:trackID]) return;
	if (_active.count >= kMaxConcurrent) {
		[_waiting addObject:track];
		return;
	}
	NSURL *url = [[P7API shared] streamURLForTrack:track];
	if (!url) return;
	__weak P7AudioCache *weakSelf = self;
	NSURLSessionDownloadTask *task = [_session downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
		[weakSelf finishTrack:track location:location response:response error:error];
	}];
	_active[trackID] = task;
	[task resume];
}

// Runs on the main queue; the temporary file is only valid inside this call.
- (void)finishTrack:(P7Track *)track location:(NSURL *)location response:(NSURLResponse *)response error:(NSError *)error {
	NSString *trackID = track.trackID;
	[_active removeObjectForKey:trackID];
	NSInteger status = [(NSHTTPURLResponse *)response statusCode];
	if (!error && status == 200 && location) {
		NSString *safe = [[trackID componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"-"];
		NSString *file = [safe stringByAppendingPathExtension:track.format.length ? track.format : @"m4a"];
		NSString *destination = [self pathForFile:file];
		NSFileManager *fm = [NSFileManager defaultManager];
		[fm removeItemAtPath:destination error:NULL];
		if ([fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:NULL]) {
			unsigned long long size = [[fm attributesOfItemAtPath:destination error:NULL] fileSize];
			[self evictToFit:size];
			_index[trackID] = @{@"file": file, @"size": @(size), @"lastPlayed": [NSDate date]};
			[self saveIndex];
			[[NSNotificationCenter defaultCenter] postNotificationName:P7AudioCacheDidChangeNotification object:self userInfo:@{@"trackID": trackID}];
		}
	} else if (error.code != NSURLErrorCancelled) {
		NSLog(@"[Player7] caching %@ failed: %@", track.title, error.localizedDescription ?: @(status));
	}
	if (_waiting.count) {
		P7Track *next = _waiting.firstObject;
		[_waiting removeObjectAtIndex:0];
		[self cacheTrack:next];
	}
}

- (void)evictToFit:(unsigned long long)incoming {
	unsigned long long limit = self.limitBytes;
	unsigned long long total = [self totalBytes];
	if (total + incoming <= limit) return;
	NSArray *oldestFirst = [_index keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"lastPlayed"] compare:b[@"lastPlayed"]];
	}];
	for (NSString *trackID in oldestFirst) {
		if (total + incoming <= limit) break;
		if ([trackID isEqualToString:_protectedTrackID]) continue;
		total -= [_index[trackID][@"size"] unsignedLongLongValue];
		[[NSFileManager defaultManager] removeItemAtPath:[self pathForFile:_index[trackID][@"file"]] error:NULL];
		[_index removeObjectForKey:trackID];
	}
	[self saveIndex];
}

- (void)clear {
	for (NSURLSessionTask *task in _active.allValues) [task cancel];
	[_active removeAllObjects];
	[_waiting removeAllObjects];
	[_index removeAllObjects];
	[[NSFileManager defaultManager] removeItemAtPath:_directory error:NULL];
	[[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
	[self saveIndex];
	[[NSNotificationCenter defaultCenter] postNotificationName:P7AudioCacheDidChangeNotification object:self];
}

@end
