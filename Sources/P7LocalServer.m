#import "P7LocalServer.h"
#import "P7HTTP.h"
#import "P7Settings.h"
#import "P7DeviceProvider.h"
#import "P7SubsonicProvider.h"
#import "P7FragmentedMP4.h"
#import <UIKit/UIKit.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

static NSString *const kTokenKey = @"P7LocalServerToken";
static const uint16_t kFirstPort = 47872;
static const long long kChunkBytes = 512 * 1024;   // audio is relayed in pieces this big,
static const long long kFirstChunkBytes = 64 * 1024; // except the first, so playback starts sooner on slow networks
static const NSUInteger kMaxHeaderBytes = 64 * 1024;
static const NSUInteger kMaxBodyBytes = 4 * 1024 * 1024;

NSError *P7ProviderError(NSInteger status, NSString *message) {
	return [NSError errorWithDomain:@"P7ProviderErrorDomain" code:status userInfo:@{NSLocalizedDescriptionKey: message ?: @"Something went wrong."}];
}

@interface P7LocalRequest : NSObject
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *path;
@property (nonatomic, copy) NSDictionary *query;
@property (nonatomic, copy) NSDictionary *headers;   // lowercased names
@property (nonatomic, copy) NSData *body;
@end

@implementation P7LocalRequest
@end

@implementation P7LocalServer {
	int _socket;
	uint16_t _port;
	dispatch_source_t _acceptSource;
	dispatch_queue_t _acceptQueue;
	NSCache *_remuxes;       // track id -> P7FragmentedMP4
	NSCache *_plainTracks;   // track id -> @YES for audio that is passed on as it is
	NSArray *_trackLocks;
}

+ (instancetype)shared {
	static P7LocalServer *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (instancetype)init {
	if ((self = [super init])) {
		_socket = -1;
		_acceptQueue = dispatch_queue_create("com.szv.player7.localserver", DISPATCH_QUEUE_SERIAL);
		_remuxes = [NSCache new];
		_remuxes.countLimit = 16;
		_plainTracks = [NSCache new];
		_plainTracks.countLimit = 500;
		NSMutableArray *locks = [NSMutableArray new];
		for (int i = 0; i < 16; i++) [locks addObject:[NSLock new]];
		_trackLocks = locks;
		NSString *token = [[NSUserDefaults standardUserDefaults] stringForKey:kTokenKey];
		if (!token.length) {
			token = [[[NSUUID UUID] UUIDString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
			[[NSUserDefaults standardUserDefaults] setObject:token forKey:kTokenKey];
		}
		_token = token;
	}
	return self;
}

// The selected source answers, except that YouTube items always go to the phone and Subsonic
// items to Subsonic, so a queue keeps playing after switching sources (see P7API).
- (id<P7Provider>)providerForItem:(NSString *)itemID {
	static P7DeviceProvider *device;
	static P7SubsonicProvider *subsonic;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		device = [P7DeviceProvider shared];
		subsonic = [P7SubsonicProvider new];
	});
	if ([itemID hasPrefix:@"yt-"]) return device;
	if ([itemID hasPrefix:@"ss-"]) return subsonic;
	return [P7Settings shared].backend == P7BackendSubsonic ? subsonic : device;
}

#pragma mark - Listening

- (NSString *)baseURL {
	@synchronized (self) {
		if (_socket < 0 && ![self start]) return nil;
		return [NSString stringWithFormat:@"http://127.0.0.1:%u", _port];
	}
}

- (BOOL)listenOnPort:(uint16_t)port {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return NO;
	int yes = 1;
	setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	address.sin_port = htons(port);
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 || listen(fd, 32) != 0) {
		close(fd);
		return NO;
	}
	fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);

	dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _acceptQueue);
	__weak P7LocalServer *weakSelf = self;
	dispatch_source_set_event_handler(source, ^{ [weakSelf acceptOn:fd]; });
	dispatch_source_set_cancel_handler(source, ^{ close(fd); });
	dispatch_resume(source);
	_socket = fd;
	_port = port;
	_acceptSource = source;
	return YES;
}

// Same port as before when possible: queued songs and running downloads still point at it.
- (BOOL)start {
	if (_port && [self listenOnPort:_port]) return YES;
	for (uint16_t port = kFirstPort; port < kFirstPort + 40; port++) {
		if ([self listenOnPort:port]) {
			NSLog(@"[Player7] local server on 127.0.0.1:%u", port);
			return YES;
		}
	}
	NSLog(@"[Player7] local server: no free port");
	return NO;
}

- (void)stop {
	if (_acceptSource) dispatch_source_cancel(_acceptSource);
	_acceptSource = nil;
	_socket = -1;
}

- (void)restartIfNeeded {
	dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
		uint16_t port;
		@synchronized (self) {
			if (self->_socket < 0) return;
			port = self->_port;
		}
		if ([self canConnectToPort:port]) return;
		@synchronized (self) {
			NSLog(@"[Player7] local server socket was closed while suspended; reopening");
			[self stop];
			[self start];
		}
	});
}

- (BOOL)canConnectToPort:(uint16_t)port {
	int fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) return NO;
	struct timeval timeout = {2, 0};
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
	struct sockaddr_in address;
	memset(&address, 0, sizeof(address));
	address.sin_len = sizeof(address);
	address.sin_family = AF_INET;
	address.sin_port = htons(port);
	address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	BOOL ok = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
	close(fd);
	return ok;
}

- (void)acceptOn:(int)listener {
	while (YES) {
		int client = accept(listener, NULL, NULL);
		if (client < 0) {
			if (errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR && errno != ECONNABORTED) {
				NSLog(@"[Player7] local server accept failed (%d); reopening", errno);
				dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
					@synchronized (self) {
						if (self->_socket != listener) return;
						[self stop];
						[self start];
					}
				});
			}
			return;
		}
		fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK);
		int yes = 1;
		setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
		struct timeval timeout = {60, 0};
		setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
		setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
		dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
			@autoreleasepool {
				[self handleClient:client];
			}
			close(client);
		});
	}
}

#pragma mark - Reading requests

- (P7LocalRequest *)readRequestFrom:(int)fd {
	NSMutableData *buffer = [NSMutableData new];
	NSData *separator = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
	NSRange end = NSMakeRange(NSNotFound, 0);
	uint8_t chunk[8192];
	while (end.location == NSNotFound) {
		ssize_t count = recv(fd, chunk, sizeof(chunk), 0);
		if (count <= 0 || buffer.length + count > kMaxHeaderBytes) return nil;
		[buffer appendBytes:chunk length:count];
		end = [buffer rangeOfData:separator options:0 range:NSMakeRange(0, buffer.length)];
	}
	NSString *head = [[NSString alloc] initWithData:[buffer subdataWithRange:NSMakeRange(0, end.location)] encoding:NSUTF8StringEncoding];
	NSArray *lines = [head componentsSeparatedByString:@"\r\n"];
	NSArray *requestLine = [lines.firstObject componentsSeparatedByString:@" "];
	if (requestLine.count < 2) return nil;

	P7LocalRequest *request = [P7LocalRequest new];
	request.method = [requestLine[0] uppercaseString];
	NSMutableDictionary *headers = [NSMutableDictionary new];
	for (NSString *line in [lines subarrayWithRange:NSMakeRange(1, lines.count - 1)]) {
		NSRange colon = [line rangeOfString:@":"];
		if (colon.location == NSNotFound) continue;
		NSString *name = [[line substringToIndex:colon.location] lowercaseString];
		headers[name] = [[line substringFromIndex:colon.location + 1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	}
	request.headers = headers;

	NSString *target = requestLine[1];
	NSRange question = [target rangeOfString:@"?"];
	request.path = question.location == NSNotFound ? target : [target substringToIndex:question.location];
	NSMutableDictionary *query = [NSMutableDictionary new];
	if (question.location != NSNotFound) {
		for (NSString *pair in [[target substringFromIndex:question.location + 1] componentsSeparatedByString:@"&"]) {
			NSRange equals = [pair rangeOfString:@"="];
			NSString *key = equals.location == NSNotFound ? pair : [pair substringToIndex:equals.location];
			NSString *value = equals.location == NSNotFound ? @"" : [pair substringFromIndex:equals.location + 1];
			key = [key stringByRemovingPercentEncoding] ?: key;
			value = [[value stringByReplacingOccurrencesOfString:@"+" withString:@" "] stringByRemovingPercentEncoding] ?: value;
			if (key.length) query[key] = value;
		}
	}
	request.query = query;

	NSUInteger length = (NSUInteger)MAX(0, [headers[@"content-length"] integerValue]);
	if (length > kMaxBodyBytes) return nil;
	NSMutableData *body = [[buffer subdataWithRange:NSMakeRange(NSMaxRange(end), buffer.length - NSMaxRange(end))] mutableCopy];
	while (body.length < length) {
		ssize_t count = recv(fd, chunk, MIN(sizeof(chunk), length - body.length), 0);
		if (count <= 0) return nil;
		[body appendBytes:chunk length:count];
	}
	request.body = body;
	return request;
}

#pragma mark - Writing responses

- (BOOL)write:(NSData *)data to:(int)fd {
	const uint8_t *bytes = data.bytes;
	NSUInteger sent = 0;
	while (sent < data.length) {
		ssize_t count = send(fd, bytes + sent, data.length - sent, 0);
		if (count <= 0) {
			if (count < 0 && errno == EINTR) continue;
			return NO;
		}
		sent += count;
	}
	return YES;
}

- (BOOL)sendStatus:(NSInteger)status headers:(NSDictionary *)headers to:(int)fd {
	NSMutableString *head = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld %@\r\n", (long)status, [NSHTTPURLResponse localizedStringForStatusCode:status]];
	[headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop) {
		[head appendFormat:@"%@: %@\r\n", name, value];
	}];
	[head appendString:@"Connection: close\r\n\r\n"];
	return [self write:[head dataUsingEncoding:NSUTF8StringEncoding] to:fd];
}

- (void)sendData:(NSData *)data status:(NSInteger)status type:(NSString *)type to:(int)fd head:(BOOL)head {
	if ([self sendStatus:status headers:@{@"Content-Type": type, @"Content-Length": @(data.length)} to:fd] && !head) {
		[self write:data to:fd];
	}
}

- (void)sendJSON:(id)object status:(NSInteger)status to:(int)fd head:(BOOL)head {
	NSData *data = [NSJSONSerialization isValidJSONObject:object] ? [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL] : nil;
	if (!data) {
		status = 500;
		data = [NSJSONSerialization dataWithJSONObject:@{@"error": @"The answer couldn't be read."} options:0 error:NULL];
	}
	[self sendData:data status:status type:@"application/json; charset=utf-8" to:fd head:head];
}

- (void)sendError:(NSError *)error to:(int)fd head:(BOOL)head {
	NSInteger status = error.code >= 400 && error.code < 600 ? error.code : 500;
	[self sendJSON:@{@"error": error.localizedDescription ?: @"Something went wrong."} status:status to:fd head:head];
}

#pragma mark - Routing

- (void)handleClient:(int)fd {
	P7LocalRequest *request = [self readRequestFrom:fd];
	if (!request) return;
	BOOL head = [request.method isEqualToString:@"HEAD"];
	if (![request.query[@"token"] isEqualToString:_token]) {
		[self sendJSON:@{@"error": @"Wrong token."} status:401 to:fd head:head];
		return;
	}
	if (![request.path hasPrefix:@"/api/"]) {
		[self sendJSON:@{@"error": @"no such route"} status:404 to:fd head:head];
		return;
	}
	NSMutableArray *parts = [NSMutableArray new];
	for (NSString *component in [[request.path substringFromIndex:5] componentsSeparatedByString:@"/"]) {
		if (component.length) [parts addObject:[component stringByRemovingPercentEncoding] ?: component];
	}
	NSMutableDictionary *query = [request.query mutableCopy];
	[query removeObjectForKey:@"token"];

	if (parts.count == 3 && [parts[0] isEqualToString:@"tracks"] && [parts[2] isEqualToString:@"stream"]) {
		[self sendAudioForTrackID:parts[1] request:request to:fd];
		return;
	}
	if (parts.count == 3 && [parts[0] isEqualToString:@"tracks"] && [parts[2] isEqualToString:@"cover"]) {
		[self sendCoverForID:parts[1] size:[query[@"size"] integerValue] wide:[query[@"wide"] isEqualToString:@"1"] to:fd head:head];
		return;
	}

	NSDictionary *body = @{};
	if (request.body.length) {
		id json = [NSJSONSerialization JSONObjectWithData:request.body options:0 error:NULL];
		if ([json isKindOfClass:[NSDictionary class]]) body = json;
	}
	NSError *error = nil;
	id<P7Provider> provider = [self providerForItem:parts.count > 1 ? parts[1] : nil];
	id response = [provider responseForMethod:request.method parts:parts query:query body:body error:&error];
	if (response) {
		[self sendJSON:response status:200 to:fd head:head];
	} else {
		[self sendError:error ?: P7ProviderError(500, nil) to:fd head:head];
	}
}

#pragma mark - Audio

// "bytes=a-b" / "bytes=a-": start and end (-1 when open). NO when absent or unsupported.
- (BOOL)parseRange:(NSString *)header start:(long long *)start end:(long long *)end {
	if (![header hasPrefix:@"bytes="]) return NO;
	NSArray *bounds = [[[header substringFromIndex:6] componentsSeparatedByString:@","].firstObject componentsSeparatedByString:@"-"];
	if (bounds.count != 2 || ![bounds[0] length]) return NO;
	*start = [bounds[0] longLongValue];
	*end = [bounds[1] length] ? [bounds[1] longLongValue] : -1;
	return *end < 0 || *end >= *start;
}

- (NSData *)fetch:(NSURL *)url headers:(NSDictionary *)headers range:(NSString *)range response:(NSHTTPURLResponse **)response {
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
	[headers enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
		[request setValue:value forHTTPHeaderField:name];
	}];
	[request setValue:range forHTTPHeaderField:@"Range"];
	return [P7HTTP sendRequest:request response:response error:NULL];
}

// The parts of a multipart/byteranges answer, in the order of `ranges` ([@[@start, @end], ...]); nil if one is missing.
- (NSArray *)partsOf:(NSData *)body type:(NSString *)type ranges:(NSArray *)ranges {
	NSRange marker = [type rangeOfString:@"boundary="];
	if (![type hasPrefix:@"multipart/byteranges"] || marker.location == NSNotFound) return nil;
	NSString *boundary = [[type substringFromIndex:NSMaxRange(marker)] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\" "]];
	NSData *separator = [[@"--" stringByAppendingString:boundary] dataUsingEncoding:NSASCIIStringEncoding];
	NSData *blankLine = [@"\r\n\r\n" dataUsingEncoding:NSASCIIStringEncoding];
	NSMutableDictionary *parts = [NSMutableDictionary new];   // start -> bytes
	NSUInteger at = 0;
	while (at < body.length) {
		NSRange found = [body rangeOfData:separator options:0 range:NSMakeRange(at, body.length - at)];
		if (found.location == NSNotFound) break;
		NSRange headEnd = [body rangeOfData:blankLine options:0 range:NSMakeRange(NSMaxRange(found), body.length - NSMaxRange(found))];
		if (headEnd.location == NSNotFound) break;
		NSString *head = [[NSString alloc] initWithData:[body subdataWithRange:NSMakeRange(NSMaxRange(found), headEnd.location - NSMaxRange(found))] encoding:NSASCIIStringEncoding];
		NSRange bytes = [head rangeOfString:@"Content-Range: bytes " options:NSCaseInsensitiveSearch];
		if (bytes.location == NSNotFound) break;
		NSScanner *scanner = [NSScanner scannerWithString:[head substringFromIndex:NSMaxRange(bytes)]];
		long long first = 0, last = -1;
		if (![scanner scanLongLong:&first] || ![scanner scanString:@"-" intoString:NULL] || ![scanner scanLongLong:&last] || last < first) break;
		NSUInteger start = NSMaxRange(headEnd);
		if (start + (NSUInteger)(last - first + 1) > body.length) break;
		parts[@(first)] = [body subdataWithRange:NSMakeRange(start, (NSUInteger)(last - first + 1))];
		at = start + (NSUInteger)(last - first + 1);
	}
	NSMutableArray *result = [NSMutableArray new];
	for (NSArray *range in ranges) {
		NSData *part = parts[range[0]];
		if ((long long)part.length != [range[1] longLongValue] - [range[0] longLongValue] + 1) return nil;
		[result addObject:part];
	}
	return result;
}

- (BOOL)isExpiredStatus:(NSInteger)status {
	return status == 403 || status == 404 || status == 410;
}

// The file size from "Content-Range: bytes 0-524287/3456789"; -1 when unknown.
- (long long)totalLengthOf:(NSHTTPURLResponse *)response {
	NSString *contentRange = response.allHeaderFields[@"Content-Range"];
	NSRange slash = [contentRange rangeOfString:@"/" options:NSBackwardsSearch];
	long long total = slash.location != NSNotFound ? [[contentRange substringFromIndex:slash.location + 1] longLongValue] : 0;
	return total > 0 ? total : -1;
}

// Asks the provider for a fresh URL after the old one stopped working.
- (NSURL *)renewAudioURLForTrackID:(NSString *)trackID headers:(NSDictionary **)headers {
	id<P7Provider> provider = [self providerForItem:trackID];
	if (![provider respondsToSelector:@selector(audioURLFailedForTrackID:)]) return nil;
	[provider audioURLFailedForTrackID:trackID];
	return [provider audioURLForTrackID:trackID headers:headers error:NULL];
}

// Sends the response head for bytes start...end of a file of `total` bytes. NO if the client is gone.
- (BOOL)sendAudioHeadFrom:(long long)start to:(long long)end total:(long long)total ranged:(BOOL)ranged type:(NSString *)type to:(int)fd {
	NSMutableDictionary *headers = [@{
		@"Content-Type": type ?: @"audio/mp4",
		@"Content-Length": @(end - start + 1),
		@"Accept-Ranges": @"bytes",
	} mutableCopy];
	if (ranged) headers[@"Content-Range"] = [NSString stringWithFormat:@"bytes %lld-%lld/%lld", start, end, total];
	return [self sendStatus:ranged ? 206 : 200 headers:headers to:fd];
}

- (void)sendAudioForTrackID:(NSString *)trackID request:(P7LocalRequest *)clientRequest to:(int)fd {
	BOOL head = [clientRequest.method isEqualToString:@"HEAD"];
	NSDictionary *headers = nil;
	NSError *error = nil;
	NSURL *url = [[self providerForItem:trackID] audioURLForTrackID:trackID headers:&headers error:&error];
	if (!url) {
		[self sendError:error ?: P7ProviderError(404, @"This song can't be played.") to:fd head:head];
		return;
	}
	if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
		[self sendStatus:302 headers:@{@"Location": url.absoluteString, @"Content-Length": @0} to:fd];
		return;
	}

	// Fetches parts of the original. Stream URLs expire after some hours, so a paused song
	// picks up with a new one. Called from several threads at once while a remux is prepared.
	NSObject *guard = [NSObject new];
	__block NSURL *source = url;
	__block NSDictionary *sourceHeaders = headers;
	__block NSHTTPURLResponse *lastResponse = nil;
	__block long long expectedTotal = -1;
	NSData *(^load)(NSString *, NSHTTPURLResponse **) = ^NSData *(NSString *range, NSHTTPURLResponse **answer) {
		NSURL *currentURL;
		NSDictionary *currentHeaders;
		@synchronized (guard) {
			currentURL = source;
			currentHeaders = sourceHeaders;
		}
		NSHTTPURLResponse *response = nil;
		NSData *data = [self fetch:currentURL headers:currentHeaders range:range response:&response];
		if ([self isExpiredStatus:response.statusCode]) {
			@synchronized (guard) {
				if (source == currentURL) {
					NSDictionary *renewedHeaders = nil;
					NSURL *renewed = [self renewAudioURLForTrackID:trackID headers:&renewedHeaders];
					if (renewed) {
						source = renewed;
						sourceHeaders = renewedHeaders;
					}
				}
				currentURL = source;
				currentHeaders = sourceHeaders;
			}
			data = [self fetch:currentURL headers:currentHeaders range:range response:&response];
		}
		long long total = [self totalLengthOf:response];
		*answer = response;
		@synchronized (guard) {
			lastResponse = response;
			if (expectedTotal > 0 && total > 0 && total != expectedTotal) return nil;   // a different file
		}
		return response.statusCode == 200 || response.statusCode == 206 ? data : nil;
	};
	P7RangeFetcher fetcher = ^NSData *(long long from, long long to) {
		NSHTTPURLResponse *response = nil;
		return load([NSString stringWithFormat:@"bytes=%lld-%lld", from, to], &response);
	};
	P7RangesFetcher rangesFetcher = ^NSArray *(NSArray *ranges) {
		NSMutableArray *specs = [NSMutableArray new];
		for (NSArray *range in ranges) [specs addObject:[NSString stringWithFormat:@"%@-%@", range[0], range[1]]];
		NSHTTPURLResponse *response = nil;
		NSData *body = load([@"bytes=" stringByAppendingString:[specs componentsJoinedByString:@","]], &response);
		return response.statusCode == 206 && body ? [self partsOf:body type:response.allHeaderFields[@"Content-Type"] ranges:ranges] : nil;
	};

	long long start = 0, end = -1;
	BOOL ranged = [self parseRange:clientRequest.headers[@"range"] start:&start end:&end];

	// YouTube's audio is a fragmented MP4, which the player gets as a regular one (see P7FragmentedMP4).
	NSLock *lock = _trackLocks[trackID.hash % _trackLocks.count];
	[lock lock];
	P7FragmentedMP4 *remux = [_remuxes objectForKey:trackID];
	if (!remux && ![_plainTracks objectForKey:trackID]) {
		NSData *fileHead = fetcher(0, kFirstChunkBytes - 1);
		long long total = [self totalLengthOf:lastResponse];
		if (fileHead && lastResponse.statusCode == 206 && total > 0 && [P7FragmentedMP4 isFragmented:fileHead]) {
			@synchronized (guard) {
				expectedTotal = total;
			}
			NSDate *started = [NSDate date];
			remux = [[P7FragmentedMP4 alloc] initWithHead:fileHead length:total fetcher:fetcher rangesFetcher:rangesFetcher];
			if (remux) [_remuxes setObject:remux forKey:trackID];
			NSLog(@"[Player7] %@ %@ in %.1f s", remux ? @"indexed" : @"couldn't index", trackID, -started.timeIntervalSinceNow);
		} else if (fileHead) {
			[_plainTracks setObject:@YES forKey:trackID];
		}
	}
	[lock unlock];
	if (remux) {
		@synchronized (guard) {
			expectedTotal = remux.originalLength;
		}
		long long total = remux.length;
		if (start >= total) {
			[self sendStatus:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lld", total], @"Content-Length": @0} to:fd];
			return;
		}
		if (end < 0 || end >= total) end = total - 1;
		if (![self sendAudioHeadFrom:start to:end total:total ranged:ranged type:@"audio/mp4" to:fd] || head) return;
		BOOL copied = [remux copyFrom:start to:end fetcher:fetcher firstChunk:kFirstChunkBytes chunk:kChunkBytes write:^BOOL(NSData *data) {
			return [self write:data to:fd];
		}];
		// A changed file (the new URL after an expiry points to another encoding): start over next time.
		if (!copied && lastResponse && [self totalLengthOf:lastResponse] != remux.originalLength) [_remuxes removeObjectForKey:trackID];
		return;
	}

	long long firstEnd = head ? start : (end >= 0 ? MIN(end, start + kFirstChunkBytes - 1) : start + kFirstChunkBytes - 1);
	NSData *data = fetcher(start, firstEnd);
	NSHTTPURLResponse *response = lastResponse;
	NSInteger status = response.statusCode;
	if (!data) {
		NSString *message = status ? [NSString stringWithFormat:@"The song couldn't be loaded (HTTP %ld).", (long)status] : @"The song couldn't be loaded.";
		[self sendJSON:@{@"error": message} status:502 to:fd head:head];
		return;
	}

	// 206: "Content-Range: bytes 0-524287/3456789". 200: the source ignored the range and sent the whole file.
	BOOL whole = status == 200;
	long long total = whole ? (long long)data.length : [self totalLengthOf:response];
	if (total <= 0) {
		[self sendJSON:@{@"error": @"The song's size is unknown."} status:502 to:fd head:head];
		return;
	}
	if (start >= total) {
		[self sendStatus:416 headers:@{@"Content-Range": [NSString stringWithFormat:@"bytes */%lld", total], @"Content-Length": @0} to:fd];
		return;
	}
	if (end < 0 || end >= total) end = total - 1;
	if (![self sendAudioHeadFrom:start to:end total:total ranged:ranged type:response.MIMEType to:fd] || head) return;

	if (whole) {
		[self write:[data subdataWithRange:NSMakeRange((NSUInteger)start, (NSUInteger)(end - start + 1))] to:fd];
		return;
	}
	@synchronized (guard) {
		expectedTotal = total;
	}
	long long position = start;
	while (YES) {
		NSUInteger usable = (NSUInteger)MIN((long long)data.length, end - position + 1);
		if (!usable || ![self write:[data subdataWithRange:NSMakeRange(0, usable)] to:fd]) return;
		position += usable;
		if (position > end) return;
		data = fetcher(position, MIN(end, position + kChunkBytes - 1));
		if (lastResponse.statusCode != 206) return;   // the player asks again from where it stopped
	}
}

#pragma mark - Covers

- (void)sendCoverForID:(NSString *)itemID size:(NSInteger)size wide:(BOOL)wide to:(int)fd head:(BOOL)head {
	size = MAX(60, MIN(1200, size ?: 300));
	NSError *error = nil;
	NSURL *url = [[self providerForItem:itemID] imageURLForID:itemID size:size error:&error];
	NSHTTPURLResponse *response = nil;
	NSData *data = url ? [P7HTTP GET:url response:&response error:NULL] : nil;
	UIImage *image = data && response.statusCode == 200 ? [UIImage imageWithData:data] : nil;
	NSData *jpeg = image ? [self jpegOf:image size:size wide:wide] : nil;
	if (!jpeg) {
		[self sendError:error ?: P7ProviderError(404, @"No cover.") to:fd head:head];
		return;
	}
	[self sendData:jpeg status:200 type:@"image/jpeg" to:fd head:head];
}

// YouTube's 4:3 video thumbnails put 16:9 pictures between black bars; the part without them.
- (CGRect)pictureIn:(UIImage *)image size:(CGSize)source {
	CGRect whole = CGRectMake(0, 0, source.width, source.height);
	if (!image.CGImage || fabs(source.width / source.height - 4.0 / 3.0) > 0.02) return whole;
	enum { width = 48, height = 36 };
	uint8_t pixels[width * height * 4];
	CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
	CGContextRef context = CGBitmapContextCreate(pixels, width, height, 8, width * 4, space, (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
	CGColorSpaceRelease(space);
	if (!context) return whole;
	CGContextDrawImage(context, CGRectMake(0, 0, width, height), image.CGImage);
	CGContextRelease(context);
	for (int y = 0; y < height; y++) {
		if (y >= 4 && y < height - 4) continue;   // the bars are the top and bottom eighth
		for (int x = 0; x < width; x++) {
			const uint8_t *pixel = pixels + (y * width + x) * 4;
			if (MAX(pixel[0], MAX(pixel[1], pixel[2])) > 24) return whole;
		}
	}
	CGFloat pictureHeight = source.width * 9 / 16;
	return CGRectMake(0, (source.height - pictureHeight) / 2, source.width, pictureHeight);
}

// Square covers are cropped to the middle; banners keep their shape and are scaled to `size` wide.
- (NSData *)jpegOf:(UIImage *)image size:(NSInteger)size wide:(BOOL)wide {
	CGSize source = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
	if (source.width < 1 || source.height < 1) return nil;
	CGSize target;
	CGRect drawn;
	if (wide) {
		target = CGSizeMake(size, MAX(1, round(size * source.height / source.width)));
		drawn = CGRectMake(0, 0, target.width, target.height);
	} else {
		CGRect picture = [self pictureIn:image size:source];
		CGFloat side = MIN(picture.size.width, picture.size.height);
		CGFloat scale = size / side;
		CGFloat left = picture.origin.x + (picture.size.width - side) / 2, top = picture.origin.y + (picture.size.height - side) / 2;
		target = CGSizeMake(size, size);
		drawn = CGRectMake(-left * scale, -top * scale, source.width * scale, source.height * scale);
	}
	UIGraphicsBeginImageContextWithOptions(target, YES, 1);
	[image drawInRect:drawn];
	UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
	UIGraphicsEndImageContext();
	return result ? UIImageJPEGRepresentation(result, 0.85) : nil;
}

@end
