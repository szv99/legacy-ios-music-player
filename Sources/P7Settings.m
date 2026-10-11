#import "P7Settings.h"
#import <Security/Security.h>

NSString *const P7SettingsDidChangeNotification = @"P7SettingsDidChangeNotification";

static NSString *const kBackendKey = @"P7Backend";
static NSString *const kServerURLKey = @"P7ServerURL";
static NSString *const kYouTubeOnServerKey = @"P7YouTubeOnServer";
static NSString *const kSubsonicURLKey = @"P7SubsonicURL";
static NSString *const kSubsonicUsernameKey = @"P7SubsonicUsername";
static NSString *const kSavePlayedSongsKey = @"P7SavePlayedSongs";
static NSString *const kKeychainService = @"com.szv.player7";
static NSString *const kTokenAccount = @"token";
static NSString *const kSubsonicPasswordAccount = @"subsonic-password";
static NSString *const kDiscordAccount = @"discord-refresh-token";

@implementation P7Settings

+ (instancetype)shared {
	static P7Settings *shared;
	static dispatch_once_t once;
	dispatch_once(&once, ^{ shared = [self new]; });
	return shared;
}

- (void)changed {
	[[NSNotificationCenter defaultCenter] postNotificationName:P7SettingsDidChangeNotification object:self];
}

+ (NSString *)normalizedURL:(NSString *)string {
	NSString *trimmed = [string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] ?: @"";
	while ([trimmed hasSuffix:@"/"]) trimmed = [trimmed substringToIndex:trimmed.length - 1];
	if (trimmed.length && [trimmed rangeOfString:@"://"].location == NSNotFound) {
		trimmed = [@"http://" stringByAppendingString:trimmed];
	}
	return trimmed;
}

#pragma mark - Backend

- (P7Backend)backend {
	id value = [[NSUserDefaults standardUserDefaults] objectForKey:kBackendKey];
	if (value) return [value integerValue];
	return self.serverURL.length ? P7BackendServer : P7BackendDevice;
}

- (void)setBackend:(P7Backend)backend {
	[[NSUserDefaults standardUserDefaults] setInteger:backend forKey:kBackendKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self changed];
}

- (BOOL)isConfigured {
	switch (self.backend) {
		case P7BackendDevice: return YES;
		case P7BackendServer: return self.serverURL.length > 0;
		case P7BackendSubsonic: return self.subsonicURL.length > 0 && self.subsonicUsername.length > 0;
	}
	return NO;
}

#pragma mark - Player7 server

- (NSString *)serverURL {
	return [[NSUserDefaults standardUserDefaults] stringForKey:kServerURLKey];
}

- (void)setServerURL:(NSString *)serverURL {
	[[NSUserDefaults standardUserDefaults] setObject:[P7Settings normalizedURL:serverURL] forKey:kServerURLKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self changed];
}

- (BOOL)youtubeOnServer {
	return [[NSUserDefaults standardUserDefaults] boolForKey:kYouTubeOnServerKey];
}

- (void)setYoutubeOnServer:(BOOL)youtubeOnServer {
	[[NSUserDefaults standardUserDefaults] setBool:youtubeOnServer forKey:kYouTubeOnServerKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self changed];
}

- (NSString *)token {
	return [self keychainStringForAccount:kTokenAccount];
}

- (void)setToken:(NSString *)token {
	[self setKeychainString:token forAccount:kTokenAccount];
	[self changed];
}

#pragma mark - Subsonic

- (NSString *)subsonicURL {
	return [[NSUserDefaults standardUserDefaults] stringForKey:kSubsonicURLKey];
}

- (void)setSubsonicURL:(NSString *)subsonicURL {
	[[NSUserDefaults standardUserDefaults] setObject:[P7Settings normalizedURL:subsonicURL] forKey:kSubsonicURLKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self changed];
}

- (NSString *)subsonicUsername {
	return [[NSUserDefaults standardUserDefaults] stringForKey:kSubsonicUsernameKey];
}

- (void)setSubsonicUsername:(NSString *)subsonicUsername {
	NSString *trimmed = [subsonicUsername stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	[[NSUserDefaults standardUserDefaults] setObject:trimmed ?: @"" forKey:kSubsonicUsernameKey];
	[[NSUserDefaults standardUserDefaults] synchronize];
	[self changed];
}

- (NSString *)subsonicPassword {
	return [self keychainStringForAccount:kSubsonicPasswordAccount];
}

- (void)setSubsonicPassword:(NSString *)subsonicPassword {
	[self setKeychainString:subsonicPassword forAccount:kSubsonicPasswordAccount];
	[self changed];
}

#pragma mark - Discord

- (NSString *)discordRefreshToken {
	return [self keychainStringForAccount:kDiscordAccount];
}

// Discord hands out a new refresh token with every access token, so this changes often.
- (void)setDiscordRefreshToken:(NSString *)discordRefreshToken {
	[self setKeychainString:discordRefreshToken forAccount:kDiscordAccount];
}

#pragma mark - Keychain

- (NSDictionary *)keychainQueryForAccount:(NSString *)account {
	return @{
		(__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
		(__bridge id)kSecAttrService: kKeychainService,
		(__bridge id)kSecAttrAccount: account,
	};
}

- (NSString *)keychainStringForAccount:(NSString *)account {
	NSMutableDictionary *query = [[self keychainQueryForAccount:account] mutableCopy];
	query[(__bridge id)kSecReturnData] = @YES;
	query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitOne;
	CFTypeRef result = NULL;
	if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result) return nil;
	NSData *data = (__bridge_transfer NSData *)result;
	return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

- (void)setKeychainString:(NSString *)string forAccount:(NSString *)account {
	SecItemDelete((__bridge CFDictionaryRef)[self keychainQueryForAccount:account]);
	if (string.length) {
		NSMutableDictionary *item = [[self keychainQueryForAccount:account] mutableCopy];
		item[(__bridge id)kSecValueData] = [string dataUsingEncoding:NSUTF8StringEncoding];
		item[(__bridge id)kSecAttrAccessible] = (__bridge id)kSecAttrAccessibleAfterFirstUnlock;
		SecItemAdd((__bridge CFDictionaryRef)item, NULL);
	}
}

#pragma mark - Played songs

- (BOOL)savePlayedSongs {
	id value = [[NSUserDefaults standardUserDefaults] objectForKey:kSavePlayedSongsKey];
	return value ? [value boolValue] : YES;
}

- (void)setSavePlayedSongs:(BOOL)savePlayedSongs {
	[[NSUserDefaults standardUserDefaults] setBool:savePlayedSongs forKey:kSavePlayedSongsKey];
}

@end
