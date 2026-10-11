#import "P7Player.h"
#import "P7API.h"
#import "P7Downloads.h"
#import "P7AudioCache.h"
#import "P7Settings.h"
#import "P7ImageCache.h"
#import "P7Blocks.h"
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>

NSString *const P7PlayerDidChangeNotification = @"P7PlayerDidChangeNotification";
NSString *const P7PlayerProgressNotification = @"P7PlayerProgressNotification";

static void *kItemContext = &kItemContext;
static void *kPlayerContext = &kPlayerContext;

@implementation P7Player {
	AVPlayer *_player;
	AVPlayerItem *_item;
	id _timeObserver;
	NSMutableArray *_queue;      // play order
	NSMutableArray *_original;   // order before shuffling
	NSInteger _index;
	BOOL _wantsToPlay;
	NSTimeInterval _pendingSeek;
	UIImage *_artwork;
	NSString *_artworkTrackID;
	NSUInteger _consecutiveFailures;
	BOOL _resumeAfterInterruption;
	NSTimer *_sleepTimer;
	NSUInteger _sleepSetting;   // changes with every timer change, so a fade-out in progress can tell it was cancelled
}

+ (instancetype)shared {
	static P7Player *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_queue = [NSMutableArray new];
		_original = [NSMutableArray new];
		_index = NSNotFound;
		_player = [AVPlayer new];
		[_player addObserver:self forKeyPath:@"rate" options:0 context:kPlayerContext];
		__weak P7Player *weakSelf = self;
		_timeObserver = [_player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.5, 600) queue:dispatch_get_main_queue() usingBlock:^(CMTime time) {
			[[NSNotificationCenter defaultCenter] postNotificationName:P7PlayerProgressNotification object:weakSelf];
		}];
	}
	return self;
}

#pragma mark - Setup

- (void)setUp {
	AVAudioSession *session = [AVAudioSession sharedInstance];
	[session setCategory:AVAudioSessionCategoryPlayback error:NULL];
	[session setActive:YES error:NULL];

	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(audioInterruption:) name:AVAudioSessionInterruptionNotification object:session];
	[nc addObserver:self selector:@selector(routeChange:) name:AVAudioSessionRouteChangeNotification object:session];
	[nc addObserver:self selector:@selector(itemDidEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:nil];
	[nc addObserver:self selector:@selector(itemFailedToEnd:) name:AVPlayerItemFailedToPlayToEndTimeNotification object:nil];

	[self setUpRemoteCommands];
	[self restoreState];
}

- (void)setUpRemoteCommands {
	[[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
	Class commandCenterClass = NSClassFromString(@"MPRemoteCommandCenter"); // iOS 7.1+
	if (!commandCenterClass) return;
	// iOS 7.1 doesn't keep block targets alive (crash on play/pause from the lock screen),
	// so the commands target this singleton, which lives as long as the app.
	MPRemoteCommandCenter *center = [commandCenterClass sharedCommandCenter];
	[center.playCommand addTarget:self action:@selector(remotePlay:)];
	[center.pauseCommand addTarget:self action:@selector(remotePause:)];
	[center.togglePlayPauseCommand addTarget:self action:@selector(remoteToggle:)];
	[center.nextTrackCommand addTarget:self action:@selector(remoteNext:)];
	[center.previousTrackCommand addTarget:self action:@selector(remotePrevious:)];
}

- (MPRemoteCommandHandlerStatus)remotePlay:(MPRemoteCommandEvent *)event {
	[self play];
	return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remotePause:(MPRemoteCommandEvent *)event {
	[self pause];
	return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remoteToggle:(MPRemoteCommandEvent *)event {
	[self togglePlayPause];
	return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remoteNext:(MPRemoteCommandEvent *)event {
	[self next];
	return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)remotePrevious:(MPRemoteCommandEvent *)event {
	[self previous];
	return MPRemoteCommandHandlerStatusSuccess;
}

#pragma mark - State

- (NSArray *)queue { return [_queue copy]; }
- (NSInteger)currentIndex { return _index; }
- (BOOL)isPlaying { return _wantsToPlay; }

- (P7Track *)currentTrack {
	return (_index != NSNotFound && _index < (NSInteger)_queue.count) ? _queue[_index] : nil;
}

- (BOOL)isBuffering {
	return _wantsToPlay && _player.rate == 0 && _item != nil;
}

- (NSTimeInterval)currentTime {
	if (_pendingSeek > 0) return _pendingSeek;
	NSTimeInterval time = CMTimeGetSeconds(_player.currentTime);
	return isfinite(time) ? time : 0;
}

- (NSTimeInterval)duration {
	NSTimeInterval duration = _item ? CMTimeGetSeconds(_item.duration) : NAN;
	if (isfinite(duration) && duration > 0) return duration;
	return self.currentTrack.duration;
}

- (void)postChange {
	[self updateNowPlayingInfo];
	[[NSNotificationCenter defaultCenter] postNotificationName:P7PlayerDidChangeNotification object:self];
}

#pragma mark - Queue

- (void)playTracks:(NSArray *)tracks startIndex:(NSInteger)index {
	if (!tracks.count) return;
	index = MAX(0, MIN(index, (NSInteger)tracks.count - 1));
	_original = [tracks mutableCopy];
	if (_shuffle) {
		_queue = [self shuffledArray:tracks first:tracks[index]];
		_index = 0;
	} else {
		_queue = [tracks mutableCopy];
		_index = index;
	}
	_consecutiveFailures = 0;
	[self loadCurrentAndPlay:YES];
}

- (void)shuffleTracks:(NSArray *)tracks {
	if (!tracks.count) return;
	_shuffle = YES;
	[self playTracks:tracks startIndex:arc4random_uniform((uint32_t)tracks.count)];
}

- (void)playQueueIndex:(NSInteger)index {
	if (index < 0 || index >= (NSInteger)_queue.count) return;
	_index = index;
	_consecutiveFailures = 0;
	[self loadCurrentAndPlay:YES];
}

- (void)playNext:(NSArray *)tracks {
	if (!tracks.count) return;
	if (!self.currentTrack) { [self playTracks:tracks startIndex:0]; return; }
	NSIndexSet *positions = [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(_index + 1, tracks.count)];
	[_queue insertObjects:tracks atIndexes:positions];
	NSUInteger originalIndex = [_original indexOfObjectIdenticalTo:self.currentTrack];
	if (originalIndex == NSNotFound) originalIndex = _original.count - 1;
	[_original insertObjects:tracks atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(originalIndex + 1, tracks.count)]];
	[self postChange];
}

- (void)addToQueue:(NSArray *)tracks {
	if (!tracks.count) return;
	if (!self.currentTrack) { [self playTracks:tracks startIndex:0]; return; }
	[_queue addObjectsFromArray:tracks];
	[_original addObjectsFromArray:tracks];
	[self postChange];
}

- (void)removeQueueIndex:(NSInteger)index {
	if (index < 0 || index >= (NSInteger)_queue.count || index == _index) return;
	P7Track *track = _queue[index];
	[_queue removeObjectAtIndex:index];
	NSUInteger originalIndex = [_original indexOfObjectIdenticalTo:track];
	if (originalIndex != NSNotFound) [_original removeObjectAtIndex:originalIndex];
	if (index < _index) _index--;
	[self postChange];
}

- (void)moveQueueIndex:(NSInteger)from toIndex:(NSInteger)to {
	if (from == to || from < 0 || to < 0 || from >= (NSInteger)_queue.count || to >= (NSInteger)_queue.count) return;
	P7Track *current = self.currentTrack;
	P7Track *track = _queue[from];
	[_queue removeObjectAtIndex:from];
	[_queue insertObject:track atIndex:to];
	_index = [_queue indexOfObjectIdenticalTo:current];
	if (!_shuffle) _original = [_queue mutableCopy];
	[self postChange];
}

- (NSMutableArray *)shuffledArray:(NSArray *)tracks first:(P7Track *)first {
	NSMutableArray *rest = [tracks mutableCopy];
	NSUInteger firstIndex = first ? [rest indexOfObjectIdenticalTo:first] : NSNotFound;
	if (firstIndex != NSNotFound) [rest removeObjectAtIndex:firstIndex];
	for (NSUInteger i = rest.count; i > 1; i--) {
		[rest exchangeObjectAtIndex:i - 1 withObjectAtIndex:arc4random_uniform((uint32_t)i)];
	}
	if (firstIndex != NSNotFound) [rest insertObject:first atIndex:0];
	return rest;
}

- (void)setShuffle:(BOOL)shuffle {
	if (_shuffle == shuffle) return;
	_shuffle = shuffle;
	P7Track *current = self.currentTrack;
	if (current) {
		if (shuffle) {
			_queue = [self shuffledArray:_queue first:current];
			_index = 0;
		} else {
			_queue = [_original mutableCopy];
			NSUInteger index = [_queue indexOfObjectIdenticalTo:current];
			_index = index == NSNotFound ? 0 : index;
		}
	}
	[self postChange];
}

- (void)setRepeatMode:(P7RepeatMode)repeatMode {
	_repeatMode = repeatMode;
	[self postChange];
}

#pragma mark - Loading

- (BOOL)canPlay:(P7Track *)track {
	return track.available || [[P7Downloads shared] isDownloaded:track.trackID];
}

// Offline download, then the automatic song cache, then the server stream.
- (NSURL *)URLForTrack:(P7Track *)track {
	return [[P7Downloads shared] localURLForTrackID:track.trackID]
		?: [[P7AudioCache shared] fileURLForTrackID:track.trackID]
		?: [[P7API shared] streamURLForTrack:track];
}

// Once the current song is playing, keep a copy of it and of the next one on the phone:
// as an Offline download (default) or in the size-limited song cache.
- (void)cacheAroundCurrent {
	NSMutableArray *tracks = [NSMutableArray new];
	if (self.currentTrack) [tracks addObject:self.currentTrack];
	if (_index != NSNotFound && _index + 1 < (NSInteger)_queue.count) [tracks addObject:_queue[_index + 1]];
	if ([P7Settings shared].savePlayedSongs) {
		[[P7Downloads shared] downloadTracks:tracks];
	} else {
		for (P7Track *track in tracks) [[P7AudioCache shared] cacheTrack:track];
	}
}

- (void)setItem:(AVPlayerItem *)item {
	if (_item) {
		[_item removeObserver:self forKeyPath:@"status" context:kItemContext];
		[_item removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:kItemContext];
	}
	_item = item;
	if (_item) {
		[_item addObserver:self forKeyPath:@"status" options:0 context:kItemContext];
		[_item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:0 context:kItemContext];
	}
	[_player replaceCurrentItemWithPlayerItem:_item];
}

- (void)loadCurrentAndPlay:(BOOL)play {
	// Skip tracks the server has not fetched yet and that are not stored offline.
	NSUInteger guard = 0;
	while (self.currentTrack && ![self canPlay:self.currentTrack] && guard++ < _queue.count) {
		_index = (_index + 1) % _queue.count;
	}
	P7Track *track = self.currentTrack;
	NSURL *url = track && [self canPlay:track] ? [self URLForTrack:track] : nil;
	if (!url) {
		[self setItem:nil];
		_wantsToPlay = NO;
		[self postChange];
		return;
	}

	_pendingSeek = 0;
	[[P7AudioCache shared] markPlayed:track.trackID];
	[self setItem:[AVPlayerItem playerItemWithURL:url]];
	_wantsToPlay = play;
	if (play) {
		[[AVAudioSession sharedInstance] setActive:YES error:NULL];
		[_player play];
	}
	[self loadArtworkForTrack:track];
	[self prefetchUpcoming];
	[self postChange];
	[self saveState];   // iOS may end the app in the background without asking
}

// Ask the server to fetch the next songs now, so they start instantly.
- (void)prefetchUpcoming {
	NSMutableArray *upcoming = [NSMutableArray new];
	for (NSInteger i = _index + 1; i < (NSInteger)_queue.count && upcoming.count < 3; i++) {
		P7Track *track = _queue[i];
		if (![[P7Downloads shared] isDownloaded:track.trackID]) [upcoming addObject:track];
	}
	[[P7API shared] prefetchTracks:upcoming];
}

- (void)loadArtworkForTrack:(P7Track *)track {
	if ([_artworkTrackID isEqualToString:track.trackID]) return;
	_artwork = nil;
	_artworkTrackID = track.trackID;
	[[P7ImageCache shared] coverForTrackID:track.coverKey size:600 completion:^(UIImage *image) {
		if (![self->_artworkTrackID isEqualToString:track.trackID]) return;
		self->_artwork = image;
		[self updateNowPlayingInfo];
	}];
}

#pragma mark - Transport

- (void)play {
	if (!_item) {
		if (self.currentTrack) {
			NSTimeInterval resumeAt = _pendingSeek;
			[self loadCurrentAndPlay:YES];
			if (resumeAt > 0) [self seekToTime:resumeAt];
		}
		return;
	}
	_wantsToPlay = YES;
	[[AVAudioSession sharedInstance] setActive:YES error:NULL];
	[_player play];
	[self postChange];
}

- (void)pause {
	_wantsToPlay = NO;
	[_player pause];
	[self postChange];
}

- (void)togglePlayPause {
	_wantsToPlay ? [self pause] : [self play];
}

- (void)next {
	[self advanceAutomatically:NO];
}

- (void)advanceAutomatically:(BOOL)automatic {
	if (!_queue.count) return;
	if (_index + 1 < (NSInteger)_queue.count) {
		_index++;
		[self loadCurrentAndPlay:automatic || _wantsToPlay];
	} else if (_repeatMode == P7RepeatAll) {
		_index = 0;
		[self loadCurrentAndPlay:YES];
	} else if (automatic) {
		// End of the queue: stop on the last track, rewound.
		_wantsToPlay = NO;
		[_player pause];
		[_player seekToTime:kCMTimeZero];
		[self postChange];
	} else {
		_index = 0;
		[self loadCurrentAndPlay:NO];
	}
}

- (void)previous {
	if (!_queue.count) return;
	if (self.currentTime > 3 || (_index == 0 && _repeatMode != P7RepeatAll)) {
		[self seekToTime:0];
		return;
	}
	_index = _index > 0 ? _index - 1 : (NSInteger)_queue.count - 1;
	[self loadCurrentAndPlay:_wantsToPlay];
}

- (void)seekToTime:(NSTimeInterval)time {
	if (!_item || _item.status != AVPlayerItemStatusReadyToPlay) {
		_pendingSeek = time;
		return;
	}
	_pendingSeek = 0;
	[_player seekToTime:CMTimeMakeWithSeconds(time, 600) completionHandler:^(BOOL finished) {
		[self updateNowPlayingInfo];
	}];
	[self postChange];
}

#pragma mark - Sleep timer

- (void)sleepAfter:(NSTimeInterval)seconds {
	_sleepSetting++;
	[_sleepTimer invalidate];
	_sleepTimer = nil;
	_sleepDate = nil;
	_sleepAtEndOfTrack = NO;
	if (seconds > 0) {
		_sleepDate = [NSDate dateWithTimeIntervalSinceNow:seconds];
		_sleepTimer = [NSTimer scheduledTimerWithTimeInterval:seconds target:self selector:@selector(sleepTimerFired) userInfo:nil repeats:NO];
	}
	[self postChange];
}

- (void)sleepAtEndOfCurrentTrack {
	[self sleepAfter:0];
	_sleepAtEndOfTrack = YES;
	[self postChange];
}

// Fade out over a few seconds instead of cutting the song off.
- (void)sleepTimerFired {
	_sleepTimer = nil;
	_sleepDate = nil;
	__block NSInteger step = 0;
	__weak P7Player *weakSelf = self;
	NSUInteger setting = _sleepSetting;
	void (^__block fade)(void) = nil;
	fade = ^{
		P7Player *player = weakSelf;
		if (!player) return;
		if (player->_sleepSetting != setting) {   // the timer was turned off or set again
			player->_player.volume = 1;
			fade = nil;
			return;
		}
		step++;
		player->_player.volume = MAX(0, 1 - step / 25.0);
		if (step < 25) {
			dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), fade);
		} else {
			fade = nil;
			[player pause];
			player->_player.volume = 1;
		}
	};
	fade();
}

#pragma mark - Notifications

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
	if (context == kItemContext) {
		if (object != _item) return;
		if ([keyPath isEqualToString:@"status"]) {
			if (_item.status == AVPlayerItemStatusReadyToPlay) {
				_consecutiveFailures = 0;
				if (_pendingSeek > 0) [self seekToTime:_pendingSeek];
				[self cacheAroundCurrent];
			} else if (_item.status == AVPlayerItemStatusFailed) {
				NSError *error = _item.error;
				NSLog(@"[Player7] failed to load %@: %@ (%@ %ld, %@)", self.currentTrack.title, error.localizedDescription, error.domain, (long)error.code, error.userInfo[NSUnderlyingErrorKey]);
				[self skipAfterFailure];
				return;
			}
		}
		[self postChange];
	} else if (context == kPlayerContext) {
		[self postChange];
	} else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void)skipAfterFailure {
	if (++_consecutiveFailures >= MIN(_queue.count, (NSUInteger)5)) {
		_wantsToPlay = NO;
		[self setItem:nil];   // so Play tries again
		[self postChange];
		NSString *title = _queue.count > 1 ? @"Couldn't Play These Songs" : @"Couldn't Play This Song";
		[P7Alert showMessage:@"Check your connection and try again. If it keeps happening, the songs may no longer be available." title:title];
		return;
	}
	[self advanceAutomatically:YES];
}

- (void)itemDidEnd:(NSNotification *)note {
	if (note.object != _item) return;
	if (_sleepAtEndOfTrack) {
		_sleepAtEndOfTrack = NO;
		_wantsToPlay = NO;
		[self advanceAutomatically:NO];   // move on to the next song, paused
		return;
	}
	if (_repeatMode == P7RepeatOne) {
		[_player seekToTime:kCMTimeZero];
		[_player play];
		return;
	}
	[self advanceAutomatically:YES];
}

- (void)itemFailedToEnd:(NSNotification *)note {
	if (note.object != _item) return;
	NSLog(@"[Player7] playback stopped: %@", [note.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey] localizedDescription]);
	[self skipAfterFailure];
}

- (void)audioInterruption:(NSNotification *)note {
	NSUInteger type = [note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];
	if (type == AVAudioSessionInterruptionTypeBegan) {
		_resumeAfterInterruption = _wantsToPlay;
		[self pause];
	} else {
		NSUInteger options = [note.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
		if (_resumeAfterInterruption && (options & AVAudioSessionInterruptionOptionShouldResume)) [self play];
		_resumeAfterInterruption = NO;
	}
}

- (void)routeChange:(NSNotification *)note {
	NSUInteger reason = [note.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
	if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable) {
		dispatch_async(dispatch_get_main_queue(), ^{ [self pause]; });
	}
}

#pragma mark - Lock screen

- (void)updateNowPlayingInfo {
	P7Track *track = self.currentTrack;
	MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
	if (!track) { center.nowPlayingInfo = nil; return; }
	NSMutableDictionary *info = [NSMutableDictionary dictionary];
	info[MPMediaItemPropertyTitle] = track.title;
	info[MPMediaItemPropertyArtist] = track.artist;
	if (track.album) info[MPMediaItemPropertyAlbumTitle] = track.album;
	info[MPMediaItemPropertyPlaybackDuration] = @(self.duration);
	info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(self.currentTime);
	info[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
	info[MPNowPlayingInfoPropertyPlaybackQueueIndex] = @(_index);
	info[MPNowPlayingInfoPropertyPlaybackQueueCount] = @(_queue.count);
	if (_artwork && [_artworkTrackID isEqualToString:track.trackID]) {
		info[MPMediaItemPropertyArtwork] = [[MPMediaItemArtwork alloc] initWithImage:_artwork];
	}
	center.nowPlayingInfo = info;
}

#pragma mark - Persistence

- (NSString *)statePath {
	NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
	return [library stringByAppendingPathComponent:@"Player7State.plist"];
}

- (void)saveState {
	NSMutableArray *queue = [NSMutableArray new];
	for (P7Track *track in _queue) [queue addObject:track.raw];
	NSMutableArray *original = [NSMutableArray new];
	for (P7Track *track in _original) [original addObject:@([_queue indexOfObjectIdenticalTo:track])];
	NSDictionary *state = @{
		@"queue": queue,
		@"original": original,
		@"index": @(_index == NSNotFound ? -1 : _index),
		@"time": @(self.currentTime),
		@"shuffle": @(_shuffle),
		@"repeat": @(_repeatMode),
	};
	[state writeToFile:[self statePath] atomically:YES];
}

- (void)restoreState {
	NSDictionary *state = [NSDictionary dictionaryWithContentsOfFile:[self statePath]];
	NSArray *queue = [P7Track itemsWithArray:state[@"queue"]];
	_shuffle = [state[@"shuffle"] boolValue];
	_repeatMode = [state[@"repeat"] integerValue];
	NSInteger index = [state[@"index"] integerValue];
	if (!queue.count || index < 0 || index >= (NSInteger)queue.count) return;

	_queue = [queue mutableCopy];
	_original = [NSMutableArray new];
	for (NSNumber *position in state[@"original"]) {
		NSInteger i = position.integerValue;
		if (i >= 0 && i < (NSInteger)queue.count) [_original addObject:queue[i]];
	}
	if (_original.count != queue.count) _original = [queue mutableCopy];
	_index = index;
	_pendingSeek = [state[@"time"] doubleValue];
	[self loadArtworkForTrack:self.currentTrack];
	[self postChange];
}

@end
