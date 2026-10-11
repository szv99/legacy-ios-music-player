#import "P7LastFM.h"
#import "P7HTTP.h"
#import "P7Provider.h"
#import "P7Settings.h"
#import "P7LocalLibrary.h"
#import <CommonCrypto/CommonDigest.h>

#ifndef P7_LASTFM_API_KEY
#define P7_LASTFM_API_KEY ""
#define P7_LASTFM_API_SECRET ""
#endif

static NSString *const kAPI = @"https://ws.audioscrobbler.com/2.0/";
static NSString *const kUsernameKey = @"P7LastFMUsername";

static NSString *P7FormEscape(NSString *string) {
	static NSCharacterSet *allowed;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		allowed = [NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
	});
	return [string stringByAddingPercentEncodingWithAllowedCharacters:allowed];
}

static NSString *P7MD5(NSString *string) {
	NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
	unsigned char digest[CC_MD5_DIGEST_LENGTH];
	CC_MD5(data.bytes, (CC_LONG)data.length, digest);
	NSMutableString *hex = [NSMutableString new];
	for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
	return hex;
}

@implementation P7LastFM

+ (instancetype)shared {
	static P7LastFM *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (NSString *)key { return @P7_LASTFM_API_KEY; }
- (NSString *)secret { return @P7_LASTFM_API_SECRET; }
- (BOOL)available { return self.key.length && self.secret.length; }

- (NSDictionary *)status {
	NSString *username = [[NSUserDefaults standardUserDefaults] stringForKey:kUsernameKey];
	BOOL connected = self.available && [P7Settings shared].lastFMSession.length && username.length;
	return @{@"configured": @(self.available), @"connected": @(connected), @"username": connected ? username : @"", @"login": @"password"};
}

// A signed call; the JSON answer, or nil with *error set (Last.fm's own message when there is one).
- (NSDictionary *)call:(NSString *)method parameters:(NSDictionary *)parameters session:(BOOL)session error:(NSError **)error {
	NSMutableDictionary *all = [NSMutableDictionary new];
	[parameters enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop) {
		NSString *text = [value description];
		if (text.length) all[name] = text;
	}];
	all[@"method"] = method;
	all[@"api_key"] = self.key;
	if (session) {
		NSString *sessionKey = [P7Settings shared].lastFMSession;
		if (!sessionKey.length) {
			if (error) *error = P7ProviderError(400, @"Last.fm isn't connected.");
			return nil;
		}
		all[@"sk"] = sessionKey;
	}
	NSMutableString *signature = [NSMutableString new];
	for (NSString *name in [all.allKeys sortedArrayUsingSelector:@selector(compare:)]) [signature appendFormat:@"%@%@", name, all[name]];
	[signature appendString:self.secret];
	all[@"api_sig"] = P7MD5(signature);
	all[@"format"] = @"json";

	NSMutableArray *pairs = [NSMutableArray new];
	[all enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSString *value, BOOL *stop) {
		[pairs addObject:[NSString stringWithFormat:@"%@=%@", P7FormEscape(name), P7FormEscape(value)]];
	}];
	NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAPI]];
	request.HTTPMethod = @"POST";
	request.timeoutInterval = 20;
	[request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
	request.HTTPBody = [[pairs componentsJoinedByString:@"&"] dataUsingEncoding:NSUTF8StringEncoding];
	NSData *data = [P7HTTP sendRequest:request response:NULL error:NULL];
	id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
	if (![json isKindOfClass:[NSDictionary class]]) {
		if (error) *error = P7ProviderError(502, data ? @"Last.fm sent an invalid answer." : @"Can't reach Last.fm.");
		return nil;
	}
	if (json[@"error"]) {
		NSInteger code = [json[@"error"] integerValue];
		if (code == 9) {   // invalid session key: access was revoked on last.fm
			[P7Settings shared].lastFMSession = nil;
			if (error) *error = P7ProviderError(400, @"Last.fm isn't connected.");
			return nil;
		}
		NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : @"Last.fm refused the request.";
		if (code == 4) message = @"Wrong username or password.";
		if (error) *error = P7ProviderError(400, message);
		return nil;
	}
	return json;
}

// Artist, track, album and duration for a play, or nil without an artist. The library's
// linked artists tell which part of "A, B" is the main artist ("Tyler, The Creator" stays whole).
- (NSDictionary *)metadataFor:(NSDictionary *)play {
	if (![play isKindOfClass:[NSDictionary class]]) return nil;
	NSDictionary *known = [play[@"trackId"] isKindOfClass:[NSString class]] ? [[P7LocalLibrary shared] trackForID:play[@"trackId"]] : nil;
	NSString *artist = [play[@"artist"] isKindOfClass:[NSString class]] ? play[@"artist"] : @"";
	NSDictionary *main = [known[@"artistRefs"] isKindOfClass:[NSArray class]] ? [known[@"artistRefs"] firstObject] : nil;
	NSString *mainName = [main isKindOfClass:[NSDictionary class]] && [main[@"name"] isKindOfClass:[NSString class]] ? main[@"name"] : nil;
	if (mainName.length && ([artist isEqualToString:mainName] || [artist hasPrefix:[mainName stringByAppendingString:@", "]])) artist = mainName;
	artist = [[artist stringByReplacingOccurrencesOfString:@" - Topic" withString:@""] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
	NSString *title = [play[@"title"] isKindOfClass:[NSString class]] ? play[@"title"] : @"";
	if (!artist.length || [artist isEqualToString:@"Unknown Artist"] || !title.length) return nil;
	NSMutableDictionary *metadata = [@{@"artist": artist, @"track": title} mutableCopy];
	if ([play[@"album"] isKindOfClass:[NSString class]] && [play[@"album"] length]) metadata[@"album"] = play[@"album"];
	if ([play[@"duration"] integerValue] > 0) metadata[@"duration"] = @([play[@"duration"] integerValue]);
	return metadata;
}

- (NSDictionary *)responseForAction:(NSString *)action body:(NSDictionary *)body error:(NSError **)error {
	if (!self.available) {
		if (error) *error = P7ProviderError(400, @"This build has no Last.fm API key. Scrobbling needs a Player7 server.");
		return action ? nil : self.status;
	}
	if (!action || [action isEqualToString:@"finish"]) return self.status;

	if ([action isEqualToString:@"connect"]) {
		NSString *username = [body[@"username"] isKindOfClass:[NSString class]] ? [body[@"username"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] : @"";
		NSString *password = [body[@"password"] isKindOfClass:[NSString class]] ? body[@"password"] : @"";
		if (!username.length || !password.length) {
			if (error) *error = P7ProviderError(400, @"Enter your Last.fm username and password.");
			return nil;
		}
		NSDictionary *json = [self call:@"auth.getMobileSession" parameters:@{@"username": username, @"password": password} session:NO error:error];
		NSDictionary *session = [json[@"session"] isKindOfClass:[NSDictionary class]] ? json[@"session"] : nil;
		if (![session[@"key"] isKindOfClass:[NSString class]]) {
			if (json && error) *error = P7ProviderError(502, @"Last.fm didn't confirm the login.");
			return nil;
		}
		[P7Settings shared].lastFMSession = session[@"key"];
		[[NSUserDefaults standardUserDefaults] setObject:[session[@"name"] description] ?: username forKey:kUsernameKey];
		return self.status;
	}
	if ([action isEqualToString:@"disconnect"]) {
		[P7Settings shared].lastFMSession = nil;
		[[NSUserDefaults standardUserDefaults] removeObjectForKey:kUsernameKey];
		return self.status;
	}
	if ([action isEqualToString:@"nowplaying"]) {
		NSDictionary *metadata = [self metadataFor:body];
		if (metadata && ![self call:@"track.updateNowPlaying" parameters:metadata session:YES error:error]) return nil;
		return @{@"ok": @YES};
	}
	if ([action isEqualToString:@"love"]) {
		NSDictionary *metadata = [self metadataFor:body];
		if (!metadata) {
			if (error) *error = P7ProviderError(400, @"This song has no artist to send to Last.fm.");
			return nil;
		}
		NSString *method = body[@"loved"] && ![body[@"loved"] boolValue] ? @"track.unlove" : @"track.love";
		return [self call:method parameters:@{@"artist": metadata[@"artist"], @"track": metadata[@"track"]} session:YES error:error] ? @{@"ok": @YES} : nil;
	}
	if ([action isEqualToString:@"scrobble"]) {
		// Last.fm only takes plays from the last two weeks, 50 at a time.
		NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
		NSMutableArray *plays = [NSMutableArray new];
		NSInteger ignored = 0;
		for (NSDictionary *play in [body[@"scrobbles"] isKindOfClass:[NSArray class]] ? body[@"scrobbles"] : @[]) {
			NSDictionary *metadata = [self metadataFor:play];
			long long timestamp = [play isKindOfClass:[NSDictionary class]] ? [play[@"timestamp"] longLongValue] : 0;
			if (!metadata || timestamp < now - 14 * 86400 || timestamp > now + 300) {
				ignored++;
				continue;
			}
			NSMutableDictionary *entry = [metadata mutableCopy];
			entry[@"timestamp"] = @(timestamp);
			[plays addObject:entry];
		}
		NSInteger accepted = 0;
		for (NSUInteger start = 0; start < plays.count; start += 50) {
			NSMutableDictionary *parameters = [NSMutableDictionary new];
			NSArray *batch = [plays subarrayWithRange:NSMakeRange(start, MIN(50, plays.count - start))];
			[batch enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger n, BOOL *stop) {
				[entry enumerateKeysAndObjectsUsingBlock:^(NSString *name, id value, BOOL *stop2) {
					parameters[[NSString stringWithFormat:@"%@[%lu]", name, (unsigned long)n]] = value;
				}];
			}];
			NSDictionary *json = [self call:@"track.scrobble" parameters:parameters session:YES error:error];
			if (!json) return nil;
			NSDictionary *counts = [json[@"scrobbles"] isKindOfClass:[NSDictionary class]] ? json[@"scrobbles"][@"@attr"] : nil;
			accepted += [counts[@"accepted"] integerValue];
			ignored += [counts[@"ignored"] integerValue];
		}
		return @{@"accepted": @(accepted), @"ignored": @(ignored)};
	}
	if (error) *error = P7ProviderError(404, @"This isn't available on the iPhone.");
	return nil;
}

@end
