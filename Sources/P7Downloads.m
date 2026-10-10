#import "P7Downloads.h"
#import "P7API.h"

NSString *const P7DownloadsDidChangeNotification = @"P7DownloadsDidChangeNotification";
NSString *const P7DownloadProgressNotification = @"P7DownloadProgressNotification";

static NSString *const kSessionIdentifier = @"com.szv.player7.downloads";

@interface P7Downloads () <NSURLSessionDownloadDelegate>
@end

@implementation P7Downloads {
	NSURLSession *_session;
	NSString *_root;
	NSMutableDictionary *_tracks;      // trackID -> track dictionary (+ "file", "addedAt")
	NSMutableDictionary *_playlists;   // playlistID -> playlist dictionary (+ "trackIds", no "tracks")
	NSMutableDictionary *_active;      // trackID -> track dictionary being downloaded
	NSMutableDictionary *_progress;    // trackID -> NSNumber
	void (^_backgroundCompletion)(void);
}

+ (instancetype)shared {
	static P7Downloads *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
		_root = [documents stringByAppendingPathComponent:@"Offline"];
		NSFileManager *fm = [NSFileManager defaultManager];
		for (NSString *sub in @[@"tracks", @"covers"]) {
			[fm createDirectoryAtPath:[_root stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:NULL];
		}
		[[NSURL fileURLWithPath:_root] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:NULL];

		NSDictionary *index = [NSDictionary dictionaryWithContentsOfFile:[self indexPath]];
		_tracks = [NSMutableDictionary dictionaryWithDictionary:index[@"tracks"] ?: @{}];
		_playlists = [NSMutableDictionary dictionaryWithDictionary:index[@"playlists"] ?: @{}];
		_active = [NSMutableDictionary new];
		_progress = [NSMutableDictionary new];

		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:kSessionIdentifier];
		configuration.HTTPMaximumConnectionsPerHost = 2;
		configuration.allowsCellularAccess = YES;
		_session = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];

		// Re-attach to downloads that kept running while the app was not alive.
		[_session getTasksWithCompletionHandler:^(NSArray *data, NSArray *upload, NSArray *downloads) {
			dispatch_async(dispatch_get_main_queue(), ^{
				for (NSURLSessionDownloadTask *task in downloads) {
					NSDictionary *track = [self trackFromTask:task];
					if (track) self->_active[track[@"id"]] = track;
				}
				if (downloads.count) [self postChange:nil];
			});
		}];
	}
	return self;
}

#pragma mark - Paths

- (NSString *)indexPath { return [_root stringByAppendingPathComponent:@"index.plist"]; }

- (NSString *)safeName:(NSString *)trackID {
	return [[trackID componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"-"];
}

- (NSString *)coverPathForTrackID:(NSString *)trackID {
	return [[_root stringByAppendingPathComponent:@"covers"] stringByAppendingPathComponent:[[self safeName:trackID] stringByAppendingPathExtension:@"img"]];
}

- (void)saveIndex {
	[@{@"tracks": _tracks, @"playlists": _playlists} writeToFile:[self indexPath] atomically:YES];
}

- (void)postChange:(NSString *)trackID {
	[[NSNotificationCenter defaultCenter] postNotificationName:P7DownloadsDidChangeNotification object:self userInfo:trackID ? @{@"trackID": trackID} : nil];
}

#pragma mark - Queries

- (BOOL)isDownloaded:(NSString *)trackID { return trackID && _tracks[trackID] != nil; }
- (BOOL)isDownloading:(NSString *)trackID { return trackID && _active[trackID] != nil; }
- (float)progressForTrackID:(NSString *)trackID { return [_progress[trackID] floatValue]; }
- (NSUInteger)activeDownloadCount { return _active.count; }
- (BOOL)isPlaylistSaved:(NSString *)playlistID { return playlistID && _playlists[playlistID] != nil; }

- (NSURL *)localURLForTrackID:(NSString *)trackID {
	NSString *file = _tracks[trackID][@"file"];
	if (!file) return nil;
	NSString *path = [[_root stringByAppendingPathComponent:@"tracks"] stringByAppendingPathComponent:file];
	return [[NSFileManager defaultManager] fileExistsAtPath:path] ? [NSURL fileURLWithPath:path] : nil;
}

- (NSData *)coverDataForTrackID:(NSString *)trackID {
	if (!trackID.length) return nil;
	return [NSData dataWithContentsOfFile:[self coverPathForTrackID:trackID]];
}

- (NSArray *)downloadedTracks {
	NSArray *sorted = [_tracks.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [b[@"addedAt"] compare:a[@"addedAt"]];
	}];
	return [P7Track itemsWithArray:sorted];
}

- (NSArray *)savedPlaylists {
	NSMutableArray *result = [NSMutableArray new];
	for (NSDictionary *entry in _playlists.allValues) {
		NSMutableDictionary *playlist = [entry mutableCopy];
		NSMutableArray *tracks = [NSMutableArray new];
		for (NSString *trackID in entry[@"trackIds"]) {
			NSDictionary *track = _tracks[trackID] ?: entry[@"trackData"][trackID];
			if (track) [tracks addObject:track];
		}
		playlist[@"tracks"] = tracks;
		playlist[@"trackCount"] = @(tracks.count);
		[playlist removeObjectForKey:@"trackData"];
		[result addObject:playlist];
	}
	[result sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
		return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];
	}];
	return [P7Playlist itemsWithArray:result];
}

- (long long)totalBytes {
	long long total = 0;
	NSString *dir = [_root stringByAppendingPathComponent:@"tracks"];
	for (NSString *file in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
		total += [[[NSFileManager defaultManager] attributesOfItemAtPath:[dir stringByAppendingPathComponent:file] error:NULL] fileSize];
	}
	return total;
}

#pragma mark - Downloading

- (NSDictionary *)trackFromTask:(NSURLSessionTask *)task {
	NSData *data = [task.taskDescription dataUsingEncoding:NSUTF8StringEncoding];
	id track = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
	return [track isKindOfClass:[NSDictionary class]] && track[@"id"] ? track : nil;
}

- (BOOL)startDownload:(P7Track *)track {
	NSString *trackID = track.trackID;
	NSURL *url = trackID ? [[P7API shared] streamURLForTrack:track] : nil;
	if (!url || _active[trackID]) return NO;
	NSURLSessionDownloadTask *task = [_session downloadTaskWithURL:url];
	NSData *json = [NSJSONSerialization dataWithJSONObject:track.raw options:0 error:NULL];
	task.taskDescription = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
	_active[trackID] = track.raw;
	_progress[trackID] = @0;
	[task resume];
	[self postChange:trackID];
	return YES;
}

- (void)downloadTracks:(NSArray *)tracks {
	for (P7Track *track in tracks) {
		if (!track.trackID || !track.available || _tracks[track.trackID]) continue;
		[self startDownload:track];
	}
	[self postChange:nil];
}

- (void)refreshTracks:(NSArray *)tracks {
	for (P7Track *track in tracks) {
		NSDictionary *entry = track.trackID ? _tracks[track.trackID] : nil;
		NSString *rev = [track stringForKey:@"audioRev"];
		// The old file keeps playing until the new one has fully arrived and replaces it.
		if (entry && rev.length && ![rev isEqualToString:entry[@"audioRev"] ?: @""]) [self startDownload:track];
	}
}

- (void)savePlaylist:(P7Playlist *)playlist {
	if (!playlist.playlistID) return;
	NSMutableDictionary *entry = [playlist.raw mutableCopy];
	[entry removeObjectForKey:@"tracks"];
	NSMutableArray *trackIDs = [NSMutableArray new];
	NSMutableDictionary *trackData = [NSMutableDictionary new];
	for (P7Track *track in playlist.tracks) {
		if (!track.trackID) continue;
		[trackIDs addObject:track.trackID];
		trackData[track.trackID] = track.raw;
	}
	entry[@"trackIds"] = trackIDs;
	entry[@"trackData"] = trackData; // lets the playlist show tracks that are not downloaded yet
	_playlists[playlist.playlistID] = entry;
	[self saveIndex];
	[self downloadTracks:playlist.tracks];
}

- (void)removeTrackID:(NSString *)trackID {
	if (!trackID) return;
	[self cancelTasksForTrackID:trackID];
	[_active removeObjectForKey:trackID];
	[_progress removeObjectForKey:trackID];
	NSString *file = _tracks[trackID][@"file"];
	if (file) {
		[[NSFileManager defaultManager] removeItemAtPath:[[_root stringByAppendingPathComponent:@"tracks"] stringByAppendingPathComponent:file] error:NULL];
	}
	[[NSFileManager defaultManager] removeItemAtPath:[self coverPathForTrackID:trackID] error:NULL];
	[_tracks removeObjectForKey:trackID];
	[self saveIndex];
	[self postChange:trackID];
}

- (void)removePlaylistID:(NSString *)playlistID {
	NSArray *trackIDs = _playlists[playlistID][@"trackIds"];
	[_playlists removeObjectForKey:playlistID];
	NSMutableSet *stillUsed = [NSMutableSet new];
	for (NSDictionary *entry in _playlists.allValues) [stillUsed addObjectsFromArray:entry[@"trackIds"]];
	for (NSString *trackID in trackIDs) {
		if (![stillUsed containsObject:trackID]) [self removeTrackID:trackID];
	}
	[self saveIndex];
	[self postChange:nil];
}

- (void)cancelAll {
	[_session getTasksWithCompletionHandler:^(NSArray *data, NSArray *upload, NSArray *downloads) {
		for (NSURLSessionTask *task in downloads) [task cancel];
	}];
	[_active removeAllObjects];
	[_progress removeAllObjects];
	[self postChange:nil];
}

- (void)cancelTasksForTrackID:(NSString *)trackID {
	[_session getTasksWithCompletionHandler:^(NSArray *data, NSArray *upload, NSArray *downloads) {
		for (NSURLSessionDownloadTask *task in downloads) {
			if ([[self trackFromTask:task][@"id"] isEqualToString:trackID]) [task cancel];
		}
	}];
}

- (void)fetchCoverForTrackID:(NSString *)trackID {
	NSURL *url = [[P7API shared] coverURLForTrackID:trackID size:600];
	if (!url) return;
	NSString *path = [self coverPathForTrackID:trackID];
	[[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		if (!error && [(NSHTTPURLResponse *)response statusCode] == 200 && data.length) [data writeToFile:path atomically:YES];
	}] resume];
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didWriteData:(int64_t)written totalBytesWritten:(int64_t)totalWritten totalBytesExpectedToWrite:(int64_t)expected {
	NSDictionary *track = [self trackFromTask:task];
	if (!track) return;
	long long total = expected > 0 ? expected : [track[@"size"] longLongValue];
	float progress = total > 0 ? (float)totalWritten / (float)total : 0;
	_progress[track[@"id"]] = @(progress);
	[[NSNotificationCenter defaultCenter] postNotificationName:P7DownloadProgressNotification object:self userInfo:@{@"trackID": track[@"id"], @"progress": @(progress)}];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didResumeAtOffset:(int64_t)offset expectedTotalBytes:(int64_t)expected {
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task didFinishDownloadingToURL:(NSURL *)location {
	NSDictionary *track = [self trackFromTask:task];
	NSInteger status = [(NSHTTPURLResponse *)task.response statusCode];
	if (!track || status != 200) return;

	NSString *trackID = track[@"id"];
	NSString *format = [track[@"format"] length] ? track[@"format"] : @"mp3";
	NSString *file = [[self safeName:trackID] stringByAppendingPathExtension:format];
	NSString *destination = [[_root stringByAppendingPathComponent:@"tracks"] stringByAppendingPathComponent:file];
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:destination error:NULL];
	if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destination] error:NULL]) return;

	NSMutableDictionary *entry = [track mutableCopy];
	entry[@"file"] = file;
	entry[@"addedAt"] = [NSDate date];
	_tracks[trackID] = entry;
	[self saveIndex];
	[self fetchCoverForTrackID:trackID];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
	NSDictionary *track = [self trackFromTask:task];
	if (!track) return;
	NSString *trackID = track[@"id"];
	[_active removeObjectForKey:trackID];
	[_progress removeObjectForKey:trackID];
	if (error && error.code != NSURLErrorCancelled) {
		NSLog(@"[Player7] download failed for %@: %@", trackID, error.localizedDescription);
	}
	[self postChange:trackID];
}

- (void)handleEventsForBackgroundURLSession:(NSString *)identifier completionHandler:(void (^)(void))completionHandler {
	_backgroundCompletion = [completionHandler copy];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
	if (_backgroundCompletion) {
		void (^completion)(void) = _backgroundCompletion;
		_backgroundCompletion = nil;
		completion();
	}
}

@end
