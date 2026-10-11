#import "P7Discord.h"
#import "P7HTTP.h"
#import "P7Player.h"
#import "P7Settings.h"
#import "P7LocalLibrary.h"
#import "P7API.h"

NSString *const P7DiscordDidChangeNotification = @"P7DiscordDidChangeNotification";

// The Discord application people approve on the sign-in page, where its name and icon show.
// Forks should create their own at discord.com/developers/applications, then turn on Public
// Client (OAuth2) and the Social SDK. Empty: no Discord in Settings.
static NSString *const kP7DiscordApplicationID = @"1249119754522857616";

static NSString *const kAPI = @"https://gaming-sdk.com/api/v9";
static NSString *const kScope = @"openid sdk.social_layer_presence";
static NSString *const kUsernameKey = @"P7DiscordUsername";
static NSString *const kEnabledKey = @"P7DiscordEnabled";
static NSString *const kSessionKey = @"P7DiscordSession";   // a status the app may have left behind
static const NSTimeInterval kRenewal = 10 * 60;              // Discord drops a status that isn't renewed

static NSString *P7FormEscape(NSString *string) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	});
	return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

@implementation P7Discord {
	dispatch_queue_t _queue;        // every request, one at a time
	NSString *_accessToken;         // _queue only, like _accessExpires and _session
	NSTimeInterval _accessExpires;
	NSString *_session;             // the status shown now
	NSString *_shown;               // "<track id>|<start>" of the status shown, or nil (main thread)
	NSTimeInterval _shownStart;
	NSTimer *_renewal;
	BOOL _updatePending;
	NSMutableDictionary *_artwork;  // track id -> cover URL the Player7 server knows, or NSNull (main thread)
	NSUInteger _signIn;            // bumped to cancel a sign-in in progress
}

+ (instancetype)shared {
	static P7Discord *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_queue = dispatch_queue_create("com.szv.player7.discord", DISPATCH_QUEUE_SERIAL);
		_artwork = [NSMutableDictionary new];
		_session = [[NSUserDefaults standardUserDefaults] stringForKey:kSessionKey];
		if (_session) _shown = @"left over";   // so the next update removes it unless music plays
	}
	return self;
}

- (void)start {
	if (!self.available) return;
	NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
	[nc addObserver:self selector:@selector(scheduleUpdate) name:P7PlayerDidChangeNotification object:nil];
	[nc addObserver:self selector:@selector(progress) name:P7PlayerProgressNotification object:nil];
	[self scheduleUpdate];
}

#pragma mark - State

- (BOOL)available { return kP7DiscordApplicationID.length > 0; }
- (NSString *)username { return [[NSUserDefaults standardUserDefaults] stringForKey:kUsernameKey]; }
- (BOOL)connected { return self.username.length > 0; }

- (BOOL)enabled {
	id value = [[NSUserDefaults standardUserDefaults] objectForKey:kEnabledKey];
	return value ? [value boolValue] : YES;
}

- (void)setEnabled:(BOOL)enabled {
	[[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kEnabledKey];
	[self changed];
	[self scheduleUpdate];
}

- (void)changed {
	[[NSNotificationCenter defaultCenter] postNotificationName:P7DiscordDidChangeNotification object:self];
}

#pragma mark - Requests (on _queue)

// JSON answer of gaming-sdk.com, or nil when there was none. status: 0 without an answer.
- (NSDictionary *)send:(NSString *)path form:(NSDictionary *)form json:(NSDictionary *)json status:(NSInteger *)status {
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[kAPI stringByAppendingString:path]]];
	request.timeoutInterval = 20;
	[request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
	if (form || json) request.HTTPMethod = @"POST";
	if (form) {
		NSMutableArray *pairs = [NSMutableArray new];
		[form enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
			[pairs addObject:[NSString stringWithFormat:@"%@=%@", P7FormEscape(key), P7FormEscape(value)]];
		}];
		[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
		request.HTTPBody = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
	} else {
		[request setValue:[@"Bearer " stringByAppendingString:_accessToken ?: @""] forHTTPHeaderField:@"Authorization"];
		if (json) {
			[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
			request.HTTPBody = [NSJSONSerialization dataWithJSONObject:json options:0 error:NULL];
		}
	}
	NSHTTPURLResponse *response = nil;
	NSData *data = [P7HTTP sendRequest:request response:&response error:NULL];
	if (status) *status = data ? response.statusCode : 0;
	id object = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
	return [object isKindOfClass:[NSDictionary class]] ? object : nil;
}

- (void)keepTokens:(NSDictionary *)json {
	_accessToken = json[@"access_token"];
	_accessExpires = [[NSDate date] timeIntervalSince1970] + ([json[@"expires_in"] doubleValue] ?: 3600);
	NSString *refresh = json[@"refresh_token"];
	if ([refresh isKindOfClass:[NSString class]] && refresh.length) [P7Settings shared].discordRefreshToken = refresh;
}

// A usable access token, renewed with the refresh token when it's about to run out.
- (BOOL)authorize {
	if (_accessToken && [[NSDate date] timeIntervalSince1970] + 300 < _accessExpires) return YES;
	NSString *refresh = [P7Settings shared].discordRefreshToken;
	if (!refresh.length) return NO;
	NSDictionary *json = [self send:@"/oauth2/token" form:@{@"grant_type": @"refresh_token", @"refresh_token": refresh, @"client_id": kP7DiscordApplicationID} json:nil status:NULL];
	if ([json[@"access_token"] isKindOfClass:[NSString class]]) {
		[self keepTokens:json];
		return YES;
	}
	if ([json[@"error"] isEqual:@"invalid_grant"]) {
		// The user removed the app from their Discord account.
		NSLog(@"[Player7] Discord access was revoked");
		dispatch_async(dispatch_get_main_queue(), ^{ [self forgetAccount]; });
	}
	return NO;
}

- (void)setSession:(NSString *)session {
	_session = session;
	NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
	session ? [defaults setObject:session forKey:kSessionKey] : [defaults removeObjectForKey:kSessionKey];
}

// activity nil: take the status down. renew: the same status again, so Discord keeps it.
// Anything else replaces it: Discord adds a second status rather than change the first.
- (void)sendActivity:(NSDictionary *)activity renew:(BOOL)renew {
	if (!activity && !_session) return;
	if (![self authorize]) return;
	if (_session && (!activity || !renew)) {
		[self send:@"/users/@me/headless-sessions/delete" form:nil json:@{@"token": _session} status:NULL];
		[self setSession:nil];
	}
	if (!activity) return;
	NSMutableDictionary *body = [@{@"activities": @[activity]} mutableCopy];
	if (_session) body[@"token"] = _session;
	NSInteger status = 0;
	NSDictionary *json = [self send:@"/users/@me/headless-sessions" form:nil json:body status:&status];
	if (status >= 400 && status < 500 && _session) {
		// Discord ended that status already; start a new one.
		[self setSession:nil];
		[body removeObjectForKey:@"token"];
		json = [self send:@"/users/@me/headless-sessions" form:nil json:body status:&status];
	}
	if ([json[@"token"] isKindOfClass:[NSString class]]) {
		[self setSession:json[@"token"]];
#ifdef DEBUG
		NSLog(@"[Player7] Discord status: %@ (%@)", activity[@"details"], activity[@"assets"][@"large_image"] ?: @"no cover");
#endif
	} else {
		NSLog(@"[Player7] Discord status failed (%ld): %@", (long)status, json[@"message"] ?: @"no answer");
	}
}

#pragma mark - Following the player

- (void)scheduleUpdate {
	if (![NSThread isMainThread]) {
		// The player reports some changes from AVFoundation's threads, whose run loops never fire the delay below.
		dispatch_async(dispatch_get_main_queue(), ^{ [self scheduleUpdate]; });
		return;
	}
	if (_updatePending) return;   // skipping through songs sends one update
	_updatePending = YES;
	[self performSelector:@selector(update) withObject:nil afterDelay:1];
}

// Seeking moves the progress bar on Discord, so it counts as a change.
- (void)progress {
	P7Player *player = [P7Player shared];
	if (!player.isPlaying || player.isBuffering || ![_shown isEqualToString:player.currentTrack.trackID]) return;
	NSTimeInterval start = [[NSDate date] timeIntervalSince1970] - player.currentTime;
	if (fabs(start - _shownStart) > 3) [self scheduleUpdate];
}

- (void)update {
	[self updateRenewing:NO];
}

- (void)renew {
	[self updateRenewing:YES];
}

- (void)updateRenewing:(BOOL)renew {
	_updatePending = NO;
	P7Player *player = [P7Player shared];
	P7Track *track = player.currentTrack;
	BOOL show = self.connected && self.enabled && track && player.isPlaying;
	NSTimeInterval start = [[NSDate date] timeIntervalSince1970] - player.currentTime;
	renew = renew && show && [_shown isEqualToString:track.trackID];
	if (!renew && show && [_shown isEqualToString:track.trackID] && fabs(start - _shownStart) <= 3) return;
	if (!show && !_shown) return;
	if (show && ![self artworkForTrack:track] && [self lookUpArtworkForTrack:track]) return;   // updates again once it's known

	if (renew) start = _shownStart;   // the same status, so the progress bar doesn't jump
	_shown = show ? track.trackID : nil;
	_shownStart = start;
	[_renewal invalidate];
	_renewal = show ? [NSTimer scheduledTimerWithTimeInterval:kRenewal target:self selector:@selector(renew) userInfo:nil repeats:NO] : nil;
	NSDictionary *activity = show ? [self activityForTrack:track start:start duration:player.duration] : nil;

	// Keep running long enough to take the status down after a pause.
	__block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
	task = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
		[[UIApplication sharedApplication] endBackgroundTask:task];
		task = UIBackgroundTaskInvalid;
	}];
	dispatch_async(_queue, ^{
		[self sendActivity:activity renew:renew];
		dispatch_async(dispatch_get_main_queue(), ^{
			if (task != UIBackgroundTaskInvalid) [[UIApplication sharedApplication] endBackgroundTask:task];
		});
	});
}

- (NSDictionary *)activityForTrack:(P7Track *)track start:(NSTimeInterval)start duration:(NSTimeInterval)duration {
	long long startMs = (long long)(start * 1000);
	NSMutableDictionary *timestamps = [@{@"start": @(startMs)} mutableCopy];
	if (duration > 0) timestamps[@"end"] = @(startMs + (long long)(duration * 1000));
	NSMutableDictionary *activity = [@{
		@"type": @2,                  // "Listening to"
		@"application_id": kP7DiscordApplicationID,
		@"platform": @"desktop",
		@"name": @"Player7",
		@"status_display_type": @2,   // the member list shows the song's title rather than "Player7"
		@"details": track.title ?: @"",
		@"state": track.artist ?: @"",
		@"timestamps": timestamps,
	} mutableCopy];
	NSString *artwork = [self artworkForTrack:track];
	if (artwork) {
		NSMutableDictionary *assets = [@{@"large_image": artwork} mutableCopy];
		if (track.album.length) assets[@"large_text"] = track.album;
		activity[@"assets"] = assets;
	}
	return activity;
}

// Discord fetches the cover itself, so it has to be on the web: never the app's or the server's copy.
- (NSString *)artworkForTrack:(P7Track *)track {
	NSString *url = [track stringForKey:@"artworkUrl"];
	if (!url.length) url = [[P7LocalLibrary shared] trackForID:track.trackID][@"coverUrl"];   // found on the phone
	if ([url isKindOfClass:[NSString class]] && [url hasPrefix:@"https://"]) return url;
	if ([track.trackID hasPrefix:@"yt-"]) return [NSString stringWithFormat:@"https://i.ytimg.com/vi/%@/mqdefault.jpg", [track.trackID substringFromIndex:3]];
	id known = _artwork[track.trackID];
	return [known isKindOfClass:[NSString class]] ? known : nil;
}

// Songs saved before the server sent artworkUrl: ask it once. NO when there's no one to ask.
- (BOOL)lookUpArtworkForTrack:(P7Track *)track {
	NSString *trackID = track.trackID;
	if (_artwork[trackID] || [trackID hasPrefix:@"ss-"] || ![P7Settings shared].serverURL.length) return NO;
	_artwork[trackID] = [NSNull null];
	NSString *path = [NSString stringWithFormat:@"/api/tracks/%@", [trackID stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLPathAllowedCharacterSet]]];
	[[P7API shared] GET:path parameters:nil remote:YES completion:^(id json, NSError *error) {
		NSString *url = [json isKindOfClass:[NSDictionary class]] ? json[@"track"][@"artworkUrl"] : nil;
		if ([url isKindOfClass:[NSString class]] && [url hasPrefix:@"https://"]) self->_artwork[trackID] = url;
		[self update];
	}];
	return YES;
}

#pragma mark - Linking

- (NSError *)errorWithMessage:(NSString *)message {
	return [NSError errorWithDomain:@"P7DiscordErrorDomain" code:0 userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (void)requestCode:(void (^)(NSDictionary *, NSError *))completion {
	dispatch_async(_queue, ^{
		NSInteger status = 0;
		NSDictionary *json = [self send:@"/oauth2/device/authorize" form:@{@"client_id": kP7DiscordApplicationID, @"scope": kScope} json:nil status:&status];
		NSDictionary *code = nil;
		NSError *error = nil;
		if ([json[@"device_code"] isKindOfClass:[NSString class]] && [json[@"user_code"] isKindOfClass:[NSString class]] && [json[@"verification_uri_complete"] isKindOfClass:[NSString class]]) {
			code = @{
				@"device": json[@"device_code"],
				@"code": json[@"user_code"],
				@"url": json[@"verification_uri_complete"],
				@"interval": @(MAX(5, [json[@"interval"] integerValue])),
				@"expires": @([[NSDate date] timeIntervalSince1970] + ([json[@"expires_in"] doubleValue] ?: 300)),
			};
		} else {
			NSLog(@"[Player7] Discord sign-in code failed (%ld): %@", (long)status, json);
			error = [self errorWithMessage:status ? @"Discord didn't give a sign-in code. Try again later." : @"Can't reach Discord. Check your connection."];
		}
		dispatch_async(dispatch_get_main_queue(), ^{ completion(code, error); });
	});
}

- (void)waitForApproval:(NSDictionary *)code completion:(void (^)(NSError *))completion {
	NSUInteger attempt = ++_signIn;
	[self poll:code interval:[code[@"interval"] doubleValue] attempt:attempt completion:completion];
}

- (void)stopWaiting {
	_signIn++;
}

- (void)poll:(NSDictionary *)code interval:(NSTimeInterval)interval attempt:(NSUInteger)attempt completion:(void (^)(NSError *))completion {
	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		if (attempt != self->_signIn) return;
		if ([[NSDate date] timeIntervalSince1970] > [code[@"expires"] doubleValue]) {
			completion([self errorWithMessage:@"The code expired."]);
			return;
		}
		dispatch_async(self->_queue, ^{
			NSDictionary *json = [self send:@"/oauth2/token" form:@{
				@"grant_type": @"urn:ietf:params:oauth:grant-type:device_code",
				@"device_code": code[@"device"],
				@"client_id": kP7DiscordApplicationID,
			} json:nil status:NULL];
			NSString *problem = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : nil;
			NSString *username = nil;
			if (!problem && [json[@"access_token"] isKindOfClass:[NSString class]]) {
				[self keepTokens:json];
				NSDictionary *me = [self send:@"/oauth2/@me" form:nil json:nil status:NULL];
				NSDictionary *user = [me[@"user"] isKindOfClass:[NSDictionary class]] ? me[@"user"] : nil;
				username = [user[@"global_name"] isKindOfClass:[NSString class]] ? user[@"global_name"] : user[@"username"];
				if (![username isKindOfClass:[NSString class]] || !username.length) username = @"Discord";
			}
			dispatch_async(dispatch_get_main_queue(), ^{
				if (attempt != self->_signIn) return;
				if (username) {
					[[NSUserDefaults standardUserDefaults] setObject:username forKey:kUsernameKey];
					[self changed];
					[self scheduleUpdate];
					completion(nil);
				} else if (!json || [problem isEqualToString:@"authorization_pending"]) {
					[self poll:code interval:interval attempt:attempt completion:completion];   // also after a dropped request
				} else if ([problem isEqualToString:@"slow_down"]) {
					[self poll:code interval:interval + 5 attempt:attempt completion:completion];
				} else if ([problem isEqualToString:@"access_denied"]) {
					completion([self errorWithMessage:@"The sign-in was declined."]);
				} else if ([problem isEqualToString:@"expired_token"]) {
					completion([self errorWithMessage:@"The code expired."]);
				} else {
					NSLog(@"[Player7] Discord sign-in failed: %@", json);
					completion([self errorWithMessage:@"Discord didn't accept the sign-in. Try again."]);
				}
			});
		});
	});
}

- (void)disconnect {
	_shown = nil;
	[_renewal invalidate];
	_renewal = nil;
	dispatch_async(_queue, ^{
		[self sendActivity:nil renew:NO];
		NSString *refresh = [P7Settings shared].discordRefreshToken;
		if (refresh.length) {
			[self send:@"/oauth2/token/revoke" form:@{@"token": refresh, @"token_type_hint": @"refresh_token", @"client_id": kP7DiscordApplicationID} json:nil status:NULL];
		}
		dispatch_async(dispatch_get_main_queue(), ^{ [self forgetAccount]; });
	});
}

- (void)forgetAccount {
	[P7Settings shared].discordRefreshToken = nil;
	[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUsernameKey];
	dispatch_async(_queue, ^{
		self->_accessToken = nil;
		[self setSession:nil];
	});
	[self changed];
}

@end
