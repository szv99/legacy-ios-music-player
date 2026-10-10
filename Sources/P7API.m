#import "P7API.h"
#import "P7Settings.h"
#import "P7Downloads.h"
#import "P7LocalServer.h"

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
	}
	return self;
}

#pragma mark - URLs

// A Player7 server, or the app's own server on 127.0.0.1 for the other backends (see P7LocalServer.h).
- (NSURL *)URLForPath:(NSString *)path parameters:(NSDictionary *)parameters {
	P7Settings *settings = [P7Settings shared];
	if (!settings.isConfigured) return nil;
	BOOL remote = settings.backend == P7BackendServer;
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

- (NSURL *)streamURLForTrack:(P7Track *)track {
	return [self URLForPath:[NSString stringWithFormat:@"/api/tracks/%@/stream", P7Escape(track.trackID)] parameters:nil];
}

- (NSURL *)coverURLForTrackID:(NSString *)coverKey size:(NSInteger)size {
	if (!coverKey.length) return nil;
	NSArray *parts = [coverKey componentsSeparatedByString:@"|"];
	NSMutableDictionary *parameters = [@{@"size": @(size)} mutableCopy];
	if (parts.count > 1 && [parts[1] length]) parameters[@"v"] = parts[1];
	if (parts.count > 2 && [parts[2] isEqualToString:@"wide"]) parameters[@"wide"] = @"1";
	return [self URLForPath:[NSString stringWithFormat:@"/api/tracks/%@/cover", P7Escape(parts[0])] parameters:parameters];
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
				: [NSHTTPURLResponse localizedStringForStatusCode:status];
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
	NSURL *url = [self URLForPath:path parameters:parameters];
	return [self sendRequest:url ? [NSURLRequest requestWithURL:url] : [NSURLRequest new] completion:completion];
}

- (NSURLSessionDataTask *)POST:(NSString *)path body:(NSDictionary *)body completion:(P7JSONCompletion)completion {
	NSURL *url = [self URLForPath:path parameters:nil];
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
	return [self GET:@"/api/search" parameters:@{@"q": query ?: @"", @"source": source ?: @"youtube", @"full": @"1"} completion:^(id json, NSError *error) {
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
	[self GET:path parameters:nil completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Artist itemWithDictionary:json[@"artist"]], error);
	}];
}

- (void)fetchCollection:(NSString *)collectionID completion:(void (^)(P7Playlist *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/collections/%@", P7Escape(collectionID)];
	[self GET:path parameters:nil completion:^(id json, NSError *error) {
		completion(error ? nil : [P7Playlist itemWithDictionary:json[@"playlist"]], error);
	}];
}

- (void)fetchArtistsForTrack:(P7Track *)track completion:(void (^)(NSArray *, NSError *))completion {
	NSString *path = [NSString stringWithFormat:@"/api/tracks/%@/artists", P7Escape(track.trackID)];
	[self GET:path parameters:nil completion:^(id json, NSError *error) {
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
	[self POST:@"/api/library" body:@{@"trackId": track.trackID ?: @"", @"remove": @(!inLibrary)} completion:^(id json, NSError *error) {
		if (completion) completion(error);
	}];
}

- (void)prefetchTracks:(NSArray *)tracks {
	NSMutableArray *ids = [NSMutableArray new];
	for (P7Track *track in tracks) {
		if (track.trackID && !track.cached) [ids addObject:track.trackID];
	}
	if (!ids.count) return;
	[self POST:@"/api/prefetch" body:@{@"ids": ids} completion:^(id json, NSError *error) {}];
}

@end
