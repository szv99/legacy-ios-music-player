#import "P7LockQueue.h"
#import "P7Player.h"
#import "P7ImageCache.h"
#import "P7API.h"
#import "P7Downloads.h"
#import <UIKit/UIKit.h>
#include <notify.h>

static const NSUInteger kUpcoming = 25;
static const NSInteger kCoverSize = 120;

@implementation P7LockQueue {
	NSString *_directory;
	NSString *_lastSignature;
	BOOL _scheduled;
	int _commandToken;
	NSMutableDictionary *_liked;     // trackID -> @YES/@NO set from the lock screen this session
	UIBackgroundTaskIdentifier _awake;
}

+ (instancetype)shared {
	static P7LockQueue *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

+ (void)start {
	[[self shared] start];
}

- (instancetype)init {
	if ((self = [super init])) {
		_awake = UIBackgroundTaskInvalid;
		_liked = [NSMutableDictionary new];
	}
	return self;
}

- (BOOL)isLiked:(P7Track *)track {
	NSNumber *override = track.trackID ? _liked[track.trackID] : nil;
	return override ? override.boolValue : track.inLibrary;
}

// Love on the lock screen = add to (or take out of) Songs, the app's liked library.
- (void)toggleLike:(P7Track *)track {
	if (!track.trackID) return;
	BOOL like = ![self isLiked:track];
	_liked[track.trackID] = @(like);
	_lastSignature = nil;
	[self scheduleWrite];
	[[P7API shared] setTrack:track inLibrary:like completion:^(NSError *error) {
		if (!error) return;
		[self->_liked removeObjectForKey:track.trackID];   // didn't stick; show the real state again
		self->_lastSignature = nil;
		[self scheduleWrite];
	}];
}

- (void)start {
	NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
	_directory = [library stringByAppendingPathComponent:@"Player7Lock"];
	[[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:NULL];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(scheduleWrite) name:P7PlayerDidChangeNotification object:nil];

	notify_register_dispatch("com.szv.player7.lockcommand", &_commandToken, dispatch_get_main_queue(), ^(int token) {
		[self runCommands];
	});
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(runCommands) name:UIApplicationDidBecomeActiveNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(stayAwakeIfPaused) name:P7PlayerDidChangeNotification object:nil];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(writePlaylists) name:P7LibraryDidChangeNotification object:nil];
	[self runCommands];
	[self writePlaylists];
	[self scheduleWrite];
}

// Commands the lock screen queued, in order: {command: play|move|remove, a, b}.
- (void)runCommands {
	NSString *path = [_directory stringByAppendingPathComponent:@"commands.plist"];
	NSString *taken = [_directory stringByAppendingPathComponent:@"commands.running.plist"];
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:taken error:NULL];
	if (![fm moveItemAtPath:path toPath:taken error:NULL]) return;   // atomic: the lock screen starts a new file
	NSArray *commands = [NSArray arrayWithContentsOfFile:taken];
	[fm removeItemAtPath:taken error:NULL];
	P7Player *player = [P7Player shared];
	for (NSDictionary *command in commands) {
		if (![command isKindOfClass:[NSDictionary class]]) continue;
		NSString *name = command[@"command"];
		NSInteger a = [command[@"a"] integerValue], b = [command[@"b"] integerValue];
		if ([name isEqualToString:@"play"]) [player playQueueIndex:a];
		else if ([name isEqualToString:@"move"]) [player moveQueueIndex:a toIndex:b];
		else if ([name isEqualToString:@"remove"]) [player removeQueueIndex:a];
		else if ([name isEqualToString:@"shuffle"]) player.shuffle = !player.shuffle;
		else if ([name isEqualToString:@"repeat"]) player.repeatMode = (player.repeatMode + 1) % 3;
		else if ([name isEqualToString:@"like"] && player.currentTrack) [self toggleLike:player.currentTrack];
		else if ([name isEqualToString:@"playlist"]) [self playPlaylist:command[@"s"]];
		else if ([name isEqualToString:@"refreshPlaylists"]) [self writePlaylists];
	}
}

// iOS suspends a paused audio app; stay reachable for the lock screen a few minutes longer.
- (void)stayAwakeIfPaused {
	UIApplication *app = [UIApplication sharedApplication];
	BOOL playing = [P7Player shared].isPlaying;
	if (playing && _awake != UIBackgroundTaskInvalid) {
		[app endBackgroundTask:_awake];
		_awake = UIBackgroundTaskInvalid;
	} else if (!playing && _awake == UIBackgroundTaskInvalid && [P7Player shared].currentTrack) {
		__weak P7LockQueue *weakSelf = self;
		_awake = [app beginBackgroundTaskWithExpirationHandler:^{
			P7LockQueue *strongSelf = weakSelf;
			if (!strongSelf) return;
			[app endBackgroundTask:strongSelf->_awake];
			strongSelf->_awake = UIBackgroundTaskInvalid;
		}];
	}
}

// Player changes come in bursts (track, state, progress of loading); write once per burst.
- (void)scheduleWrite {
	if (_scheduled) return;
	_scheduled = YES;
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		self->_scheduled = NO;
		[self write];
	});
}

- (NSString *)coverPathForTrack:(P7Track *)track {
	NSString *safe = [[track.coverKey ?: track.trackID componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"-"];
	return [_directory stringByAppendingPathComponent:[safe stringByAppendingPathExtension:@"jpg"]];
}

- (void)write {
	P7Player *player = [P7Player shared];
	NSArray *queue = player.queue;
	NSInteger current = player.currentIndex;
	NSMutableArray *items = [NSMutableArray new];
	NSMutableArray *ids = [NSMutableArray new];
	if (current != NSNotFound) {
		for (NSInteger i = current; i < (NSInteger)queue.count && items.count <= kUpcoming; i++) {
			P7Track *track = queue[i];
			NSString *coverPath = [self coverPathForTrack:track];
			[items addObject:@{@"index": @(i), @"id": track.trackID ?: @"", @"title": track.title ?: @"", @"artist": track.artist ?: @"",
			                   @"cover": coverPath, @"liked": @([self isLiked:track]), @"duration": @(track.duration)}];
			[ids addObject:track.trackID ?: @""];
			[self ensureCover:track path:coverPath];
		}
	}
	// Only rewrite when something the lock screen shows changed.
	NSString *signature = [NSString stringWithFormat:@"%ld|%d%ld|%@", (long)current, player.shuffle, (long)player.repeatMode, [ids componentsJoinedByString:@","]];
	if ([signature isEqualToString:_lastSignature]) return;
	_lastSignature = signature;
	[@{@"current": @(current == NSNotFound ? -1 : current), @"tracks": items, @"shuffle": @(player.shuffle), @"repeat": @(player.repeatMode)} writeToFile:[_directory stringByAppendingPathComponent:@"queue.plist"] atomically:YES];
	notify_post("com.szv.player7.queue");
	[self removeUnusedCoversKeeping:items];
}

// Covers pile up as the queue moves on; keep the folder small.
- (void)removeUnusedCoversKeeping:(NSArray *)items {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray *files = [fm contentsOfDirectoryAtPath:_directory error:NULL];
	if (files.count < 120) return;
	NSSet *keep = [NSSet setWithArray:[items valueForKey:@"cover"]];
	for (NSString *file in files) {
		NSString *path = [_directory stringByAppendingPathComponent:file];
		if ([file hasSuffix:@".jpg"] && ![file hasPrefix:@"pl-"] && ![keep containsObject:path]) [fm removeItemAtPath:path error:NULL];
	}
}

#pragma mark - Playlists for the lock screen

static NSString *const kShuffleAll = @"__shuffle_all__";

// playlists.plist: [{id, name, count, cover}], the library's playlists (or the offline ones).
- (void)writePlaylists {
	[[P7API shared] fetchPlaylistsWithCompletion:^(NSArray *playlists, NSError *error) {
		if (error || !playlists) playlists = [[P7Downloads shared] savedPlaylists];
		NSMutableArray *items = [NSMutableArray new];
		for (P7Playlist *playlist in playlists) {
			NSString *safe = [[playlist.coverKey ?: playlist.playlistID componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"-"];
			NSString *coverPath = [self->_directory stringByAppendingPathComponent:[@"pl-" stringByAppendingString:[safe stringByAppendingPathExtension:@"jpg"]]];
			[items addObject:@{@"id": playlist.playlistID ?: @"", @"name": playlist.name ?: @"", @"count": @(playlist.trackCount), @"cover": coverPath}];
			[self ensureCoverKey:playlist.coverKey path:coverPath notify:"com.szv.player7.playlists"];
		}
		[items writeToFile:[self->_directory stringByAppendingPathComponent:@"playlists.plist"] atomically:YES];
		notify_post("com.szv.player7.playlists");
	}];
}

- (void)playPlaylist:(NSString *)playlistID {
	if (!playlistID.length) return;
	P7Player *player = [P7Player shared];
	void (^play)(NSArray *) = ^(NSArray *tracks) {
		if (!tracks.count) return;
		if (player.shuffle || [playlistID isEqualToString:kShuffleAll]) [player shuffleTracks:tracks];
		else [player playTracks:tracks startIndex:0];
	};
	if ([playlistID isEqualToString:kShuffleAll]) {
		[[P7API shared] searchTracks:nil completion:^(NSArray *tracks, NSError *error) {
			play(tracks.count ? tracks : [[P7Downloads shared] downloadedTracks]);
		}];
		return;
	}
	[[P7API shared] fetchPlaylist:playlistID completion:^(P7Playlist *playlist, NSError *error) {
		NSArray *tracks = playlist.tracks;
		if (!tracks.count) {   // offline: the saved copy
			for (P7Playlist *saved in [[P7Downloads shared] savedPlaylists]) {
				if ([saved.playlistID isEqualToString:playlistID]) tracks = saved.tracks;
			}
		}
		play(tracks);
	}];
}

- (void)ensureCover:(P7Track *)track path:(NSString *)path {
	[self ensureCoverKey:track.coverKey path:path notify:"com.szv.player7.queue"];
}

- (void)ensureCoverKey:(NSString *)coverKey path:(NSString *)path notify:(const char *)notification {
	if ([[NSFileManager defaultManager] fileExistsAtPath:path] || !coverKey) return;
	[[P7ImageCache shared] coverForTrackID:coverKey size:kCoverSize completion:^(UIImage *image) {
		if (!image) return;
		[UIImageJPEGRepresentation(image, 0.8) writeToFile:path atomically:YES];
		notify_post(notification);   // the lock screen reloads to show the cover
	}];
}

@end
