#import "P7Scrobbler.h"
#import "P7Player.h"
#import "P7Blocks.h"
#import "P7LastFM.h"

NSString *const P7LastFMDidChangeNotification = @"P7LastFMDidChangeNotification";

static NSString *const kEnabledKey = @"P7LastFMEnabled";
static const NSUInteger kBatch = 50;

@implementation P7Scrobbler {
	dispatch_queue_t _network;       // calls to Last.fm, one at a time
	NSMutableArray *_queue;          // plays waiting to be sent
	BOOL _flushing;

	NSString *_trackID;              // song being followed
	NSTimeInterval _startedAt;       // when it started playing (unix time), 0 until it does
	NSTimeInterval _listened;        // seconds actually heard
	NSTimeInterval _lastTime;
	BOOL _scrobbled;
}

+ (instancetype)shared {
	static P7Scrobbler *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_network = dispatch_queue_create("com.szv.player7.lastfm", DISPATCH_QUEUE_SERIAL);
		_queue = [NSMutableArray arrayWithContentsOfFile:[self queuePath]] ?: [NSMutableArray new];
		_lastTime = -1;
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:@"P7LastFMStatus"];   // from when a server kept the account
	}
	return self;
}

- (void)start {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(playerChanged) name:P7PlayerDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(progress) name:P7PlayerProgressNotification object:nil];
	[nc addObserver:self selector:@selector(flush) name:UIApplicationDidBecomeActiveNotification object:nil];
	[self flush];
}

#pragma mark - State

- (NSDictionary *)status { return [[P7LastFM shared] responseForAction:nil body:nil error:NULL]; }
- (BOOL)configured { return [P7LastFM shared].available; }
- (BOOL)connected { return [self.status[@"connected"] boolValue]; }
- (NSString *)username { return self.status[@"username"]; }
- (NSUInteger)pendingCount { return _queue.count; }

- (BOOL)enabled {
	id value = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
	return value ? [value boolValue] : YES;
}

- (void)setEnabled:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kEnabledKey];
	[self changed];
}

- (BOOL)active {
	return self.connected && self.enabled;
}

- (void)changed {
	[[NSNotificationCenter defaultCenter] postNotificationName:P7LastFMDidChangeNotification object:self];
}

// A P7LastFM call off the main thread; the completion runs on the main thread.
- (void)perform:(NSString *)action body:(NSDictionary *)body completion:(void (^)(NSDictionary *result, NSError *error))completion {
	dispatch_async(_network, ^{
		NSError *error = nil;
		NSDictionary *result = [[P7LastFM shared] responseForAction:action body:body error:&error];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (completion) completion(result, error);
		});
	});
}

#pragma mark - Following the player

- (void)playerChanged {
	P7Track *track = [P7Player shared].currentTrack;
	if (![track.trackID isEqualToString:_trackID]) {
		_trackID = track.trackID;
		_startedAt = 0;
		_listened = 0;
		_lastTime = -1;
		_scrobbled = NO;
	}
	[self progress];
}

- (void)progress {
	P7Player *player = [P7Player shared];
	P7Track *track = player.currentTrack;
	if (!track || ![track.trackID isEqualToString:_trackID]) return;
	NSTimeInterval time = player.currentTime;
	if (!player.isPlaying || player.isBuffering) {
		_lastTime = time;
		return;
	}
	if (!_startedAt) {
		_startedAt = [[NSDate date] timeIntervalSince1970];
		[self sendNowPlaying:track];
	}
	// Repeat One starts the same song again: count it as a new play.
	if (_scrobbled && _lastTime > 30 && time < 3) {
		_startedAt = [[NSDate date] timeIntervalSince1970];
		_listened = 0;
		_scrobbled = NO;
		[self sendNowPlaying:track];
	}
	NSTimeInterval delta = time - _lastTime;
	if (_lastTime >= 0 && delta > 0 && delta < 2.5) _listened += delta;   // seeking doesn't count
	_lastTime = time;

	NSTimeInterval duration = player.duration > 0 ? player.duration : track.duration;
	if (!_scrobbled && duration >= 30 && _listened >= MIN(duration / 2, 240)) {
		_scrobbled = YES;
		[self enqueue:track duration:duration];
	}
}

- (NSDictionary *)playForTrack:(P7Track *)track duration:(NSTimeInterval)duration {
	return @{
		@"trackId": track.trackID ?: @"",
		@"title": track.title ?: @"",
		@"artist": track.artist ?: @"",
		@"mainArtist": [track stringForKey:@"mainArtist"] ?: @"",
		@"album": track.album ?: @"",
		@"duration": @((NSInteger)duration),
	};
}

- (void)sendNowPlaying:(P7Track *)track {
	if (![self active]) return;
	[self perform:@"nowplaying" body:[self playForTrack:track duration:track.duration] completion:nil];
}

#pragma mark - Queue

- (NSString *)queuePath {
	NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
	return [library stringByAppendingPathComponent:@"Scrobbles.plist"];
}

- (void)saveQueue {
	[_queue writeToFile:[self queuePath] atomically:YES];
}

- (void)enqueue:(P7Track *)track duration:(NSTimeInterval)duration {
	if (![self active]) return;
	NSMutableDictionary *play = [[self playForTrack:track duration:duration] mutableCopy];
	play[@"timestamp"] = @((long long)_startedAt);
	[_queue addObject:play];
	if (_queue.count > 2000) [_queue removeObjectsInRange:NSMakeRange(0, _queue.count - 2000)];
	[self saveQueue];
	[self changed];
	[self flush];
}

- (void)flush {
	if (_flushing || !_queue.count || ![self active]) return;
	_flushing = YES;
	NSArray *batch = [_queue subarrayWithRange:NSMakeRange(0, MIN(kBatch, _queue.count))];
	[self perform:@"scrobble" body:@{@"scrobbles": batch} completion:^(NSDictionary *result, NSError *error) {
		self->_flushing = NO;
		if (error) {
			NSLog(@"[Player7] scrobbling failed, %lu waiting: %@", (unsigned long)self->_queue.count, error.localizedDescription);
			if (!self.connected) [self changed];   // access was revoked on last.fm
			return;
		}
		[self->_queue removeObjectsInRange:NSMakeRange(0, MIN(batch.count, self->_queue.count))];
		[self saveQueue];
		[self changed];
		if (self->_queue.count) [self flush];
	}];
}

#pragma mark - Account

// Last.fm's login for apps: username and password, no web page to visit.
- (void)connectFrom:(UIViewController *)controller {
	[P7Alert loginWithTitle:@"Connect to Last.fm" message:@"Your password goes only to Last.fm." confirm:@"Connect" handler:^(NSString *username, NSString *password) {
		[self perform:@"connect" body:@{@"username": username ?: @"", @"password": password ?: @""} completion:^(NSDictionary *result, NSError *error) {
			if (error) {
				[P7Alert showError:error title:@"Couldn't Connect"];
				return;
			}
			[self changed];
			[self flush];
			[P7Alert showMessage:[NSString stringWithFormat:@"Scrobbling as %@.", self.username] title:@"Last.fm Connected"];
		}];
	}];
}

- (void)disconnect {
	[self perform:@"disconnect" body:nil completion:^(NSDictionary *result, NSError *error) {
		[self->_queue removeAllObjects];
		[self saveQueue];
		[self changed];
	}];
}

- (void)loveTrack:(P7Track *)track {
	NSMutableDictionary *body = [[self playForTrack:track duration:track.duration] mutableCopy];
	body[@"loved"] = @YES;
	[self perform:@"love" body:body completion:^(NSDictionary *result, NSError *error) {
		if (error) [P7Alert showError:error title:@"Couldn't Love"];
	}];
}

@end
