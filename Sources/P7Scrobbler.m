#import "P7Scrobbler.h"
#import "P7Settings.h"
#import "P7Player.h"
#import "P7API.h"
#import "P7Blocks.h"

NSString *const P7LastFMDidChangeNotification = @"P7LastFMDidChangeNotification";

static NSString *const kStatusKey = @"P7LastFMStatus";
static NSString *const kEnabledKey = @"P7LastFMEnabled";
static const NSUInteger kBatch = 50;

@implementation P7Scrobbler {
	NSDictionary *_status;           // {configured, connected, username} as last seen from the server
	NSMutableArray *_queue;          // plays waiting to be sent
	BOOL _flushing;
	BOOL _awaitingAuth;              // the user went to last.fm to allow access

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
		_status = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kStatusKey];
		_queue = [NSMutableArray arrayWithContentsOfFile:[self queuePath]] ?: [NSMutableArray new];
		_lastTime = -1;
	}
	return self;
}

- (void)start {
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(playerChanged) name:P7PlayerDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(progress) name:P7PlayerProgressNotification object:nil];
	[nc addObserver:self selector:@selector(becameActive) name:UIApplicationDidBecomeActiveNotification object:nil];
	[nc addObserver:self selector:@selector(refreshStatus) name:P7SettingsDidChangeNotification object:nil];
	[self refreshStatus];
}

#pragma mark - State

- (BOOL)configured { return [_status[@"configured"] boolValue]; }
- (BOOL)connected { return [_status[@"connected"] boolValue]; }
- (NSString *)username { return _status[@"username"]; }
- (NSString *)via { return _status[@"via"]; }
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

- (void)setStatus:(NSDictionary *)status {
	if (![status isKindOfClass:[NSDictionary class]]) return;
	_status = status;
	[[NSUserDefaults standardUserDefaults] setObject:status forKey:kStatusKey];
	[self changed];
	[self flush];
}

- (void)refreshStatus {
	[[P7API shared] GET:@"/api/lastfm" parameters:nil completion:^(id json, NSError *error) {
		if (!error) [self setStatus:json];
	}];
}

- (void)becameActive {
	if (_awaitingAuth) {
		_awaitingAuth = NO;
		[self finishConnecting];
		return;
	}
	[self flush];
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
		@"album": track.album ?: @"",
		@"duration": @((NSInteger)duration),
	};
}

- (void)sendNowPlaying:(P7Track *)track {
	if (![self active]) return;
	[[P7API shared] POST:@"/api/lastfm/nowplaying" body:[self playForTrack:track duration:track.duration] completion:^(id json, NSError *error) {}];
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
	[[P7API shared] POST:@"/api/lastfm/scrobble" body:@{@"scrobbles": batch} completion:^(id json, NSError *error) {
		self->_flushing = NO;
		if (error) {
			NSLog(@"[Player7] scrobbling failed, %lu waiting: %@", (unsigned long)self->_queue.count, error.localizedDescription);
			if ([error.localizedDescription rangeOfString:@"isn't connected"].location != NSNotFound) [self refreshStatus];
			return;
		}
		[self->_queue removeObjectsInRange:NSMakeRange(0, MIN(batch.count, self->_queue.count))];
		[self saveQueue];
		[self changed];
		if (self->_queue.count) [self flush];
	}];
}

#pragma mark - Account

- (void)connectFrom:(UIViewController *)controller {
	[[P7API shared] POST:@"/api/lastfm/connect" body:nil completion:^(id json, NSError *error) {
		if (error) {
			[P7Alert showError:error title:@"Couldn't Connect"];
			return;
		}
		NSURL *url = [NSURL URLWithString:json[@"url"]];
		P7ActionSheet *sheet = [[P7ActionSheet alloc] initWithTitle:@"Allow Player7 to scrobble on Last.fm, then come back here."];
		[sheet addButton:@"Open Last.fm in Safari" handler:^{
			self->_awaitingAuth = YES;
			[[UIApplication sharedApplication] openURL:url];
		}];
		[sheet addButton:@"Copy Link (open on a computer)" handler:^{
			[UIPasteboard generalPasteboard].string = url.absoluteString;
			[P7Alert confirmWithTitle:@"Link Copied" message:@"Open it in a browser, allow access, then tap Done." confirm:@"Done" handler:^{
				[self finishConnecting];
			}];
		}];
		[sheet showFrom:controller];
	}];
}

- (void)finishConnecting {
	[[P7API shared] POST:@"/api/lastfm/finish" body:nil completion:^(id json, NSError *error) {
		if (error) {
			[P7Alert confirmWithTitle:@"Not Connected Yet" message:error.localizedDescription confirm:@"Try Again" handler:^{
				[self finishConnecting];
			}];
			return;
		}
		[self setStatus:json];
		[P7Alert showMessage:[NSString stringWithFormat:@"Scrobbling as %@.", self.username] title:@"Last.fm Connected"];
	}];
}

- (void)disconnect {
	[[P7API shared] POST:@"/api/lastfm/disconnect" body:nil completion:^(id json, NSError *error) {
		if (error) {
			[P7Alert showError:error title:@"Couldn't Disconnect"];
			return;
		}
		[self->_queue removeAllObjects];
		[self saveQueue];
		[self setStatus:json];
	}];
}

- (void)loveTrack:(P7Track *)track {
	NSMutableDictionary *body = [[self playForTrack:track duration:track.duration] mutableCopy];
	body[@"loved"] = @YES;
	[[P7API shared] POST:@"/api/lastfm/love" body:body completion:^(id json, NSError *error) {
		if (error) [P7Alert showError:error title:@"Couldn't Love"];
	}];
}

@end
