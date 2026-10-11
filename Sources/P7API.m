#import "P7API.h"
#import "P7Settings.h"
#import "P7Downloads.h"
#import "P7LocalServer.h"
#import "P7LocalLibrary.h"

NSString *const P7APIErrorDomain = @"P7APIErrorDomain";
NSString *const P7LibraryDidChangeNotification = @"P7LibraryDidChangeNotification";

static NSString *P7Escape(NSString *string) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	});
	return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

@implementation P7API {
	NSURLSession *_session;
	NSMutableDictionary *_inLibrary;   // track id -> @YES / @NO set since the track was loaded
}

+ (instancetype)shared {
	static P7API *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
		configuration.timeoutIntervalForRequest = 20;
		configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
		configuration.HTTPMaximumConnectionsPerHost = 4;
		_session = [NSURLSession sessionWithConfiguration:configuration];
		_inLibrary = [NSMutableDictionary new];
	}
	return self;
}

#pragma mark - URLs

// A Player7 server (remote), or the app's own server on 127.0.0.1 (see P7LocalServer.h).
- (NSURL *)URLForPath:(NSString *)path parameters:(NSDictionary *)parameters remote:(BOOL)remote {
	P7Settings *settings = [P7Settings shared];
	if (!remote && settings.backend == P7BackendSubsonic && !settings.isConfigured) return nil;
	NSString *base = remote ? settings.serverURL : [P7LocalServer shared].baseURL;
	if (!base.length) return nil;

	NSMutableDictionary *query = [NSMutableDictionary dictionaryWithDictionary:parameters ?: @{}];
	NSString *token = remote ? settings.token : [P7LocalServer shared].token;
	if (token.length) query[@"token"] = token;

	NSMutableString *string = [NSMutableString stringWithString:base];
	[string appendString:path];
	NSArray *keys = [query.allKeys sortedArrayUsingSelector:@selector(compare:)];
	for (NSUInteger i = 0; i < keys.count; i++) {
		NSString *key = keys[i];
		NSString *value = [query[key] description];
		[string appendFormat:@"%@%@=%@", i == 0 ? @"?" : @"&", P7Escape(key), P7Escape(value)];
	}
	return [NSURL URLWithString:string];
}

- (NSURL *)URLForPath:(NSString *)path parameters:(NSDictionary *)parameters {
	return [self URLForPath:path parameters:parameters remote:[self usesServer]];
}

- (BOOL)usesServer {
	return [P7Settings shared].backend == P7BackendServer;
}

// YouTube is searched and played on the phone, also with a Player7 server, unless Settings
// hand it to the server.
- (BOOL)youtubeOnPhone {
	P7Settings *settings = [P7Settings shared];
	return settings.backend != P7BackendServer || !settings.youtubeOnServer;
}

// Songs and pages are answered by whoever can: YouTube by the phone (see above), Subsonic by
// the app's server, and Spotify and SoundCloud by the Player7 server, whichever source is
// selected. So a queue keeps playing after switching sources.
- (BOOL)serverHandlesItem:(NSString *)itemID {
	P7Settings *settings = [P7Settings shared];
	if (!settings.serverURL.length || [itemID hasPrefix:@"ss-"]) return NO;
	return [itemID hasPrefix:@"yt-"] ? ![self youtubeOnPhone] : YES;
}

- (NSURL *)streamURLForTrack:(P7Track *)track {
	NSString *path = [NSString stringWithFormat:@"/api/tracks/%@/stream", P7Escape(track.trackID)];
	return [self URLForPath:path parameters:nil remote:[self serverHandlesItem:track.trackID]];
}

- (NSURL *)coverURLForTrackID:(NSString *)coverKey size:(NSInteger)size {
	if (!coverKey.length) return nil;
	NSArray *parts = [coverKey componentsSeparatedByString:@"|"];
	NSString *itemID = parts[0];
	NSMutableDictionary *parameters = [@{@"size": @(size)} mutableCopy];
	if (parts.count > 1 && [parts[1] length]) parameters[@"v"] = parts[1];
	if (parts.count > 2 && [parts[2] isEqualToString:@"wide"]) parameters[@"wide"] = @"1";
	// The server's own YouTube songs: the phone would have to look each one up just for its cover.
	BOOL remote = [self serverHandlesItem:itemID]
		|| ([self usesServer] && [itemID hasPrefix:@"yt-"] && ![[P7LocalLibrary shared] knowsID:itemID]);
	return [self URLForPath:[NSString stringWithFormat:@"/api/tracks/%@/cover", P7Escape(itemID)] parameters:parameters remote:remote];
}

#pragma mark - Requests

- (NSError *)errorWithMessage:(NSString *)message code:(NSInteger)code {
	return [NSError errorWithDomain:P7APIErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

- (NSURLSessionDataTask *)sendRequest:(NSURLRequest *)request completion:(P7JSONCompletion)completion {
	if (!request.URL) {
		completion(nil, [self errorWithMessage:@"Set the server address in Settings." code:-1]);
		return nil;
	}
	NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		id json = nil;
		if (!error && data.length) {
			json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
		}
		NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? [(NSHTTPURLResponse *)response statusCode] : 0;
		if (!error && status >= 400) {
			NSString *message = [json isKindOfClass:[NSDictionary class]] && [json[@"error"] isKindOfClass:[NSString class]]
				? json[@"error"]
				: [NSString stringWithFormat:@"The server answered with an error (%ld).", (long)status];
			error = [self errorWithMessage:message code:status];
		} else if (!error && !json) {
			error = [self errorWithMessage:@"The server sent an invalid response." code:-2];
		}
		dispatch_async(dispatch_get_main_queue(), ^{
			if (error.code == NSURLErrorCancelled && [error.domain isEqualToString:NSURLErrorDomain]) return;
			completion(error ? nil : json, error);
		});
	}];
	[task resume];
	return task;
}

- (NSURLSessionDataTask *)GET:(NSString *)path parameters:(NSDictionary *)parameters completion:(P7JSONCompletion)completion {
	return [self GET:path parameters:parameters remote:[self usesServer] completion:completion];
}

- (NSURLSessionDataTask *)GET:(NSString *)path parameters:(NSDictionary *)parameters remote:(BOOL)remote completion:(P7JSONCompletion)completion {
	NSURL *url = [self URLForPath:path parameters:parameters remote:remote];
	return [self sendRequest:url ? [NSURLRequest requestWithURL:url] : [NSURLRequest new] completion:completion];
}

- (NSURLSessionDataTask *)POST:(NSString *)path body:(NSDictionary *)body completion:(P7JSONCompletion)completion {
	return [self POST:path body:body remote:[self usesServer] completion:completion];
}

- (NSURLSessionDataTask *)POST:(NSString *)path body:(NSDictionary *)body remote:(BOOL)remote completion:(P7JSONCompletion)completion {
	NSURL *url = [self URLForPath:path parameters:nil remote:remote];
	NSMutableURLRequest *request = url ? [NSMutableURLRequest requestWithURL:url] : [NSMutableURLRequest new];
	request.HTTPMethod = @"POST";
	request.timeoutInterval = 120;
	[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:NULL];
	return [self sendRequest:request completion:completion];
}

#pragma mark - Endpoints

- (void)pingWithCompletion:(void (^)(NSError *))completion {
	[self GET:@"/api/ping" parameters:nil completion:^(id json, NSError *error) {
		completion(error);
	}];
}

- (void)fetchPlaylistsWithCompletion:(void (^)(NSArray *, NSError *))completion {
	[self GET:@"/api/playlists" parameters:nil completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Playlist itemsWithArray:json[@"playlists"]], error);
	}];
}

- (void)fetchPlaylist:(NSString *)playlistID completion:(void (^)(P7Playlist *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/playlists/%@", P7Escape(playlistID)];
	[self GET:path parameters:nil completion:^(id json, NSError *error) {
		P7Playlist *playlist = error ? nil : [P7Playlist itemWithDictionary:json[@"playlist"]];
		if (playlist) [[P7Downloads shared] refreshTracks:playlist.tracks];
		completion(playlist, error);
	}];
}

- (NSURLSessionDataTask *)searchTracks:(NSString *)query completion:(void (^)(NSArray *, NSError *))completion {
	return [self GET:@"/api/tracks" parameters:query.length ? @{@"q": query} : nil completion:^(id json, NSError *error) {
		NSArray *tracks = error ? nil : [P7Track itemsWithArray:json[@"tracks"]];
		if (tracks) [[P7Downloads shared] refreshTracks:tracks];
		completion(tracks, error);
	}];
}

- (NSURLSessionDataTask *)search:(NSString *)query source:(NSString *)source completion:(void (^)(NSDictionary *, NSError *))completion {
	source = source ?: @"youtube";
	// The server has no video search; YouTube Music follows the YouTube setting.
	BOOL onPhone = [source isEqualToString:@"youtube-videos"] || ([source isEqualToString:@"youtube"] && [self youtubeOnPhone]);
	NSDictionary *parameters = @{@"q": query ?: @"", @"source": source, @"full": @"1"};
	return [self GET:@"/api/search" parameters:parameters remote:[self usesServer] && !onPhone completion:^(id json, NSError *error) {
		if (error) {
			completion(nil, error);
			return;
		}
		completion(@{
			@"tracks": [P7Track itemsWithArray:json[@"tracks"]],
			@"artists": [P7Entity itemsWithArray:json[@"artists"]],
			@"albums": [P7Entity itemsWithArray:json[@"albums"]],
			@"playlists": [P7Entity itemsWithArray:json[@"playlists"]],
		}, nil);
	}];
}

- (void)fetchArtist:(NSString *)artistID completion:(void (^)(P7Artist *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/artists/%@", P7Escape(artistID)];
	[self GET:path parameters:nil remote:[self serverHandlesItem:artistID] completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Artist itemWithDictionary:json[@"artist"]], error);
	}];
}

- (void)fetchCollection:(NSString *)collectionID completion:(void (^)(P7Playlist *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/collections/%@", P7Escape(collectionID)];
	[self GET:path parameters:nil remote:[self serverHandlesItem:collectionID] completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Playlist itemWithDictionary:json[@"playlist"]], error);
	}];
}

- (void)fetchArtistsForTrack:(P7Track *)track completion:(void (^)(NSArray *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/tracks/%@/artists", P7Escape(track.trackID)];
	[self GET:path parameters:nil remote:[self serverHandlesItem:track.trackID] completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Entity itemsWithArray:json[@"artists"]], error);
	}];
}

- (void)importURL:(NSString *)url completion:(void (^)(P7Playlist *, BOOL, NSError *))completion {
	[self POST:@"/api/import" body:@{@"url": url ?: @""} completion:^(id json, NSError *error) {
		if (!error) [[NSNotificationCenter defaultCenter] postNotificationName:P7LibraryDidChangeNotification object:self];
		completion(error ? nil : [P7Playlist itemWithDictionary:json[@"playlist"]], [json[@"background"] boolValue], error);
	}];
}

- (void)fetchImportStatusWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
	[self GET:@"/api/import/status" parameters:nil completion:^(id json, NSError *error) {
		completion([json isKindOfClass:[NSDictionary class]] ? json : nil, error);
	}];
}

- (void)syncPlaylist:(NSString *)playlistID completion:(void (^)(P7Playlist *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/playlists/%@/sync", P7Escape(playlistID)];
	[self POST:path body:nil completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Playlist itemWithDictionary:json[@"playlist"]], error);
	}];
}

- (void)deletePlaylist:(NSString *)playlistID completion:(void (^)(NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/playlists/%@/delete", P7Escape(playlistID)];
	[self POST:path body:nil completion:^(id json, NSError *error) {
		if (!error) [[NSNotificationCenter defaultCenter] postNotificationName:P7LibraryDidChangeNotification object:self];
		completion(error);
	}];
}

- (void)setTrack:(P7Track *)track inLibrary:(BOOL)inLibrary completion:(void (^)(NSError *))completion {
	NSMutableDictionary *body = [@{@"trackId": track.trackID ?: @"", @"remove": @(!inLibrary)} mutableCopy];
	// A YouTube song found on the phone: the server doesn't know its title yet.
	NSDictionary *known = [self usesServer] ? [[P7LocalLibrary shared] trackForID:track.trackID] : nil;
	if (known) body[@"track"] = known;
	[self POST:@"/api/library" body:body completion:^(id json, NSError *error) {
		if (!error && track.trackID) {
			self->_inLibrary[track.trackID] = @(inLibrary);
			[[NSNotificationCenter defaultCenter] postNotificationName:P7LibraryDidChangeNotification object:self];
		}
		if (completion) completion(error);
	}];
}

- (BOOL)isTrackInLibrary:(P7Track *)track {
	NSNumber *known = track.trackID ? _inLibrary[track.trackID] : nil;
	return known ? known.boolValue : track.inLibrary;
}

- (void)prefetchTracks:(NSArray *)tracks {
	NSMutableArray *remote = [NSMutableArray new];
	NSMutableArray *local = [NSMutableArray new];
	for (P7Track *track in tracks) {
		if (track.trackID && !track.cached) [[self serverHandlesItem:track.trackID] ? remote : local addObject:track.trackID];
	}
	if (remote.count) [self POST:@"/api/prefetch" body:@{@"ids": remote} remote:YES completion:^(id json, NSError *error) {}];
	if (local.count) [self POST:@"/api/prefetch" body:@{@"ids": local} remote:NO completion:^(id json, NSError *error) {}];
}

@end
