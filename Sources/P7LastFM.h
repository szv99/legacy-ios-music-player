#import <Foundation/Foundation.h>

// Last.fm straight from the phone, for "This iPhone": the in-app server answers the Player7
// server's /api/lastfm/* routes with it, so P7Scrobbler works the same with either.
// The user logs in once with their Last.fm username and password (auth.getMobileSession,
// sent only to Last.fm); the session key is kept in the keychain.
// The API key and secret come from the build (LASTFM_API_KEY and LASTFM_API_SECRET, see the
// Makefile). Without them, scrobbling needs a Player7 server.
@interface P7LastFM : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) BOOL available;   // this build has an API key

// Blocking, for the in-app server's threads. action: nil for the status, or connect,
// disconnect, nowplaying, scrobble, love (same bodies as the Player7 server).
- (NSDictionary *)responseForAction:(NSString *)action body:(NSDictionary *)body error:(NSError **)error;
@end
